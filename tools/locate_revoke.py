#!/usr/bin/env python3
"""
locate_revoke.py — 自动定位微信 4.x 防撤回补丁点，为任意构建号生成 config.json 条目。

背景：撤回补丁点每个构建号地址都变，但几何特征在同一「代」内不变——
`parseRevokeXML` 入口 E 满足：E+0x270 处是 `cbz w0`、再往后固定距离处是
`str x0,[x19,#newmsgid]`。扫这组签名（两个锚点同时命中且全片唯一）即可定位。
微信每次重编译该函数会换一代签名（cbz 跳转距离 / newmsgid 字段偏移变），
已知三代见 GENERATIONS（数据来源：fzlzjerry/wechat-antirecall patches.json 全量归纳，
本机 269626 实测属第三代）。新构建若三代都不中 → 需人工抽切片复核并新增一代。
silent 补丁点 VA = E+0x270，`cbz w0,SKIP` → `b SKIP`（等长，编码见各代）。
keeptip 变体多一个点（就是签名的第二个锚点，白送），`str x0` → `str xzr` 清零 newmsgid。
两个 target 一起输出：`revoke`(静默) 和 `revoke-keeptip`(留提示)。

用法：
    python3 tools/locate_revoke.py                      # 默认 /Applications/WeChat.app
    python3 tools/locate_revoke.py -a /path/WeChat.app  # 指定 App
    python3 tools/locate_revoke.py --append             # 定位后直接追加进 config.json（若该 version 不存在）

只读分析，不改微信二进制。--append 只改本仓库的 config.json。
"""
import argparse
import json
import os
import plistlib
import struct
import sys

# --- 几何签名（按「代」列表；同一代内跨构建号不变）---
OFF_CBZ = 0x270                            # 补丁点相对函数入口 E 的偏移（三代恒定）
STR_RT_MASK = 0xFFFFFFE0                   # 掩掉 str 的 Rt（低 5 位）：原始 x0 与已打补丁的 xzr 都命中


def _le_word(hexbe):
    """config.json 里的字节串（大端书写，如 E00F0034）→ 小端 32 位指令字。"""
    return struct.unpack("<I", bytes.fromhex(hexbe))[0]


# 每代：cbz 原字节 / 静默写入字节(b) / cbz→str 距离 / str x0 原字节 / str xzr 写入字节 / 覆盖的微信版本
GENERATIONS = [
    {"name": "4.1.13 (269574+)",   "cbz": "40100034", "b": "82000014", "delta": 0x7A0, "str_x0": "60E600F9", "str_xzr": "7FE600F9", "field": 0x1C8},
    {"name": "4.1.12 (269332–269341)", "cbz": "40100034", "b": "82000014", "delta": 0x7A0, "str_x0": "60CE00F9", "str_xzr": "7FCE00F9", "field": 0x198},
    {"name": "4.1.10–4.1.11 (≤269136)", "cbz": "E00F0034", "b": "7F000014", "delta": 0x794, "str_x0": "60B600F9", "str_xzr": "7FB600F9", "field": 0x168},
]
for _g in GENERATIONS:
    _g["cbz_word"] = _le_word(_g["cbz"])
    _g["b_word"] = _le_word(_g["b"])
    _g["str_masked"] = _le_word(_g["str_x0"]) & STR_RT_MASK
    # 自洽：b 与 cbz 跳转目标一致（cbz imm19<<2 == b imm26<<2），str xzr 只差 Rt
    assert ((_g["cbz_word"] >> 5) & 0x7FFFF) == (_g["b_word"] & 0x3FFFFFF), _g["name"]
    assert (_le_word(_g["str_xzr"]) & STR_RT_MASK) == _g["str_masked"] and (_le_word(_g["str_xzr"]) & 0x1F) == 31, _g["name"]

# STP 序言（可选加固校验）：入口 E 的前三条应为 stp ...,[sp,#imm]
# stp (signed offset / pre-index) 高位特征：位[31:22] 匹配 10_1010_01xx。这里只做弱校验。
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFEBE
LC_SEGMENT_64 = 0x19
CPU_TYPE_ARM64 = 0x0100000C


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def arm64_slice(data):
    """返回 (slice_bytes, slice_file_offset)。fat → 抽 arm64；thin → 原样。"""
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        nfat = struct.unpack(">I", data[4:8])[0]
        for i in range(nfat):
            base = 8 + i * 20  # fat_arch: cputype cpusub offset size align (big-endian)
            cputype, _cpusub, offset, size, _align = struct.unpack(">iIIII", data[base:base + 20])
            if (cputype & 0xFFFFFFFF) == CPU_TYPE_ARM64:
                return data[offset:offset + size], offset
        raise SystemExit("错误：fat 二进制里没有 arm64 切片")
    # thin
    m = struct.unpack("<I", data[:4])[0]
    if m != MH_MAGIC_64:
        raise SystemExit("错误：不是 64 位 Mach-O（magic=0x%08x）" % m)
    return data, 0


def parse_segments(sl):
    """解析 thin slice 的 LC_SEGMENT_64，返回 [(vmaddr, vmsize, fileoff, filesize)]。"""
    magic, _cput, _cpus, _ft, ncmds, _sz, _fl, _rz = struct.unpack("<IiiIIIII", sl[:32])
    if magic != MH_MAGIC_64:
        raise SystemExit("切片不是 64 位 Mach-O")
    segs = []
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", sl[off:off + 8])
        if cmd == LC_SEGMENT_64:
            vmaddr, vmsize, fileoff, filesize = struct.unpack("<QQQQ", sl[off + 24:off + 24 + 32])
            segs.append((vmaddr, vmsize, fileoff, filesize))
        off += cmdsize
    return segs


def fileoff_to_va(segs, fo):
    for vmaddr, vmsize, fileoff, filesize in segs:
        if fileoff <= fo < fileoff + filesize:
            return vmaddr + (fo - fileoff)
    return None


def is_stp_prologue(sl, e):
    """弱校验：入口 E 的第一条是否像 stp（位[31:25] == 0b1010100 的一类）。"""
    if e < 0 or e + 4 > len(sl):
        return False
    w = struct.unpack("<I", sl[e:e + 4])[0]
    # STP 家族 opcode 高位：0b10_1_0100_x（LDP/STP variants）；只作提示不作硬判据。
    return (w >> 25) & 0x3F == 0b101001 or (w >> 22) & 0x3FF in (0b1010100110, 0b1010100010, 0b1010100100)


def locate(sl):
    """在 arm64 切片里扫所有代的签名，返回 [(补丁点文件偏移, 代)]。"""
    hits = []
    n = len(sl)
    # 锚点 1 同时认原始 `cbz w0` 和已打静默补丁的 `b`——否则已经跑过
    # `--variant silent` 的机器（想换 keeptip 的正是这批人）会扫不到签名。
    anchors = {}
    for g in GENERATIONS:
        anchors.setdefault(g["cbz_word"], []).append(g)
        anchors.setdefault(g["b_word"], []).append(g)
    for i in range(0, n - 3, 4):
        word = struct.unpack_from("<I", sl, i)[0]
        gens = anchors.get(word)
        if not gens:
            continue
        for g in gens:
            j = i + g["delta"]
            if j + 4 <= n:
                str_word = struct.unpack_from("<I", sl, j)[0]
                if (str_word & STR_RT_MASK) == g["str_masked"]:
                    hits.append((i, g))
    return hits


def wechat_build(app_path):
    plist = os.path.join(app_path, "Contents", "Info.plist")
    if not os.path.exists(plist):
        return None
    with open(plist, "rb") as f:
        return plistlib.load(f).get("CFBundleVersion")


def main():
    ap = argparse.ArgumentParser(description="自动定位微信防撤回补丁点并生成 config.json 条目")
    ap.add_argument("-a", "--app", default="/Applications/WeChat.app", help="WeChat.app 路径")
    ap.add_argument("-d", "--dylib", help="直接指定 wechat.dylib（覆盖 --app 推断）")
    ap.add_argument("--append", action="store_true", help="定位后把条目追加进 ./config.json")
    ap.add_argument("--config", default="config.json", help="config.json 路径（配合 --append）")
    args = ap.parse_args()

    dylib = args.dylib or os.path.join(args.app, "Contents", "Resources", "wechat.dylib")
    if not os.path.exists(dylib):
        raise SystemExit("找不到 dylib：%s" % dylib)

    build = wechat_build(args.app) if not args.dylib else None

    data = read_bytes(dylib)
    sl, _slice_off = arm64_slice(data)
    segs = parse_segments(sl)
    hits = locate(sl)

    if not hits:
        raise SystemExit("未命中签名（已试 %d 代：%s）——该构建重编译了 parseRevokeXML，需人工抽切片复核并在 GENERATIONS 新增一代。"
                         % (len(GENERATIONS), " / ".join(g["name"] for g in GENERATIONS)))
    if len(hits) > 1:
        vas = ["%s@%s" % (hex(fileoff_to_va(segs, h)), g["name"]) for h, g in hits]
        raise SystemExit("命中 %d 处（%s），签名不唯一，需加固校验后再定位。" % (len(hits), ", ".join(vas)))

    fo, gen = hits[0]
    PATCH_ASM, STR_X0_HEX, STR_XZR_HEX, DELTA = gen["b"], gen["str_x0"], gen["str_xzr"], gen["delta"]
    va = fileoff_to_va(segs, fo)
    if va is None:
        raise SystemExit("命中偏移 0x%x 不在任何段内，异常。" % fo)
    entry_e = va - OFF_CBZ
    stp_ok = is_stp_prologue(sl, fo - OFF_CBZ)

    va_tip = va + DELTA
    str_word = struct.unpack("<I", sl[fo + DELTA:fo + DELTA + 4])[0]
    str_hex = format(struct.unpack(">I", struct.pack("<I", str_word))[0], "08X")
    str_state = {STR_X0_HEX: "原始 str x0", STR_XZR_HEX: "已打 keeptip 补丁 (str xzr)"}.get(str_hex, "非常规 Rt=%d" % (str_word & 0x1F))

    print("===== 定位结果 =====")
    print("微信构建号 (CFBundleVersion): %s" % (build or "未知（用 --app 指向 App 可自动读取）"))
    print("命中签名代:                   %s（newmsgid 字段 [x19,#0x%x]）" % (gen["name"], gen["field"]))
    print("parseRevokeXML 入口 E:        0x%x" % entry_e)
    print("silent 补丁点 VA (E+0x270):   0x%x  原字节 %s → 写 %s" % (va, gen["cbz"], PATCH_ASM))
    print("keeptip 补丁点 VA (E+0x%x):  0x%x  当前字节 %s（%s）" % (OFF_CBZ + DELTA, va_tip, str_hex, str_state))
    print("入口 stp 序言弱校验:          %s" % ("通过" if stp_ok else "未匹配（仅提示，不影响双点签名唯一命中）"))
    print()

    silent_target = {
        "identifier": "revoke",
        "binary": "Contents/Resources/wechat.dylib",
        "entries": [{
            "arch": "arm64",
            "addr": format(va, "x"),
            "expected": gen["cbz"],
            "asm": PATCH_ASM,
        }],
    }
    # keeptip：把 cbz 恢复原样（接受 pristine 或已打过 silent 的机器），再清零 newmsgid。
    keeptip_target = {
        "identifier": "revoke-keeptip",
        "binary": "Contents/Resources/wechat.dylib",
        "entries": [
            {
                "arch": "arm64",
                "addr": format(va, "x"),
                "expected": [gen["cbz"], PATCH_ASM],
                "asm": gen["cbz"],
            },
            {
                "arch": "arm64",
                "addr": format(va_tip, "x"),
                "expected": STR_X0_HEX,
                "asm": STR_XZR_HEX,
            },
        ],
    }
    block = {
        "version": build or "REPLACE_WITH_BUILD",
        "targets": [silent_target, keeptip_target],
    }
    print("===== 可粘贴进 config.json 的条目 =====")
    print(json.dumps(block, ensure_ascii=False, indent=2))

    if args.append:
        if not build:
            raise SystemExit("--append 需要能读到构建号；请用 --app 指向 WeChat.app。")
        cfg = json.load(open(args.config, encoding="utf-8"))
        if any(str(b.get("version")) == str(build) for b in cfg):
            print("\n[append] config.json 已含 version %s，跳过。" % build)
        else:
            cfg.insert(0, block)
            with open(args.config, "w", encoding="utf-8") as f:
                json.dump(cfg, f, ensure_ascii=False, indent=2)
                f.write("\n")
            print("\n[append] 已把 version %s 追加进 %s。" % (build, args.config))


if __name__ == "__main__":
    main()
