#!/usr/bin/env python3
"""
locate_revoke.py — 自动定位微信 4.x 防撤回补丁点，为任意构建号生成 config.json 条目。

背景：撤回补丁点每个构建号地址都变，但几何特征跨版本不变——
`parseRevokeXML` 入口 E 满足：E+0x270 处是 `cbz w0`(E00F0034)、
E+0xA04 处是 `str x0,[x19,#0x168]`(60B600F9)。扫这组签名即可唯一定位。
补丁点 VA = E+0x270，`expected`=E00F0034、`asm`=7F000014 恒定。

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

# --- 几何签名（跨版本不变）---
CBZ_W0 = bytes.fromhex("E00F0034")        # E+0x270: cbz w0, SKIP（补丁点原字节）
# E+0xA04: str <Xt>,[x19,#0x168]。原始 Xt=x0(60B600F9)；keeptip 变体把它改成 xzr(7FB600F9)。
# 只认「[x19,#0x168] 的 str」这部分（掩掉目标寄存器 Rt=低 5 位），两种状态都命中。
STR_NEWMSGID_MASKED = 0xF900B660          # str ?,[x19,#0x168]，Rt 位已清零
STR_RT_MASK = 0xFFFFFFE0                   # 掩掉 Rt（低 5 位）
PATCH_ASM = "7F000014"                     # b SKIP（写入字节）
OFF_CBZ = 0x270                            # 补丁点相对函数入口 E 的偏移
OFF_STR = 0xA04                            # newmsgid 存储相对 E 的偏移
DELTA = OFF_STR - OFF_CBZ                  # 0x794：补丁点 → newmsgid 存储

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
    """在 arm64 切片里扫签名，返回所有命中的补丁点文件偏移列表。"""
    hits = []
    idx = 0
    n = len(sl)
    while True:
        i = sl.find(CBZ_W0, idx)
        if i == -1:
            break
        idx = i + 4
        if i % 4 != 0:
            continue  # 指令 4 字节对齐
        j = i + DELTA
        if j + 4 <= n:
            word = struct.unpack("<I", sl[j:j + 4])[0]
            if (word & STR_RT_MASK) == STR_NEWMSGID_MASKED:
                hits.append(i)
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
        raise SystemExit("未命中签名——该构建可能改了 parseRevokeXML 布局，需人工复核几何特征。")
    if len(hits) > 1:
        vas = [hex(fileoff_to_va(segs, h)) for h in hits]
        raise SystemExit("命中 %d 处（%s），签名不唯一，需加固校验后再定位。" % (len(hits), ", ".join(vas)))

    fo = hits[0]
    va = fileoff_to_va(segs, fo)
    if va is None:
        raise SystemExit("命中偏移 0x%x 不在任何段内，异常。" % fo)
    entry_e = va - OFF_CBZ
    stp_ok = is_stp_prologue(sl, fo - OFF_CBZ)

    print("===== 定位结果 =====")
    print("微信构建号 (CFBundleVersion): %s" % (build or "未知（用 --app 指向 App 可自动读取）"))
    print("parseRevokeXML 入口 E:        0x%x" % entry_e)
    print("补丁点 VA (E+0x270):          0x%x" % va)
    print("入口 stp 序言弱校验:          %s" % ("通过" if stp_ok else "未匹配（仅提示，不影响双点签名唯一命中）"))
    print()

    entry = {
        "arch": "arm64",
        "addr": format(va, "x"),
        "expected": "E00F0034",
        "asm": PATCH_ASM,
    }
    block = {
        "version": build or "REPLACE_WITH_BUILD",
        "targets": [{
            "identifier": "revoke",
            "binary": "Contents/Resources/wechat.dylib",
            "entries": [entry],
        }],
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
