#!/usr/bin/env python3
"""
locate_update.py — 定位微信 4.x「屏蔽自动更新」补丁点（config.json 里的 `update` target）。

为什么需要它：微信 Sparkle 自动更新会整包换掉 WeChat.app，防撤回补丁随之消失（2026-06-26 / 08-28 / 09-01 /
09-03 四次实证）。`defaults write SUEnableAutomaticChecks NO` 挡不住——`-[XAppUpdateManager startUpdater]`
每次启动都会调 `setAutomaticallyChecksForUpdates:` 把它改回来。唯一可靠的办法是把更新入口本身钉死。

定位法（来源：fzlzjerry/wechat-antirecall MAINTAINING.md §屏蔽更新）：更新逻辑在 wechat.dylib 的 ObjC 类
`XAppUpdateManager` 里。解析 `__objc_classlist` → class_t → class_ro_t → 方法表，按方法名取 IMP：
  · 4 个触发方法入口写 `ret`：startUpdater / checkForUpdates: / startBackgroundUpdatesCheck: / enableAutoUpdate:
  · 2 对强制更新开关访问器：getter（`ldrb w0,[x0,#f]; ret`）改成 `mov w0,#0; ret`，setter（`strb w2,[x0,#f]`）改成 `ret`
方法名 / 类名的 SSOT 在仓库根 signatures.json 的 "update" 段（Swift 侧 UpdateLocator 用同一张表，由
tools/gen_signatures.py 派生）。按名取到 IMP 后还要过入口指令形态校验，形态不对就拒绝生成——按名字找到
但代码长得不一样，说明微信改了实现，得人工看。

269579 / 269627 两个构建按此法得到的 8 个地址与参考实现 patches.json 逐一相同（本脚本写成前先手工验证过）。

用法：
    python3 tools/locate_update.py                 # 打印本机微信的 update target（JSON）
    python3 tools/locate_update.py --append        # 追加进 config.json 里本机构建号的条目（需先有 revoke 条目）
    python3 tools/locate_update.py --dylib <path>  # 指定任意 wechat.dylib（做交叉核对用）
退出码：0 成功 / 已一致；1 定位失败；2 config.json 里没有该构建号；3 config 已有 update 且与定位结果不同（不覆盖）。
"""
import argparse
import json
import os
import plistlib
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate_revoke as L  # noqa: E402  复用 Mach-O 切片 / 段解析，不另写一份

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "config.json")
SIGNATURES_JSON = os.path.join(ROOT, "signatures.json")
DYLIB_REL = "Contents/Resources/wechat.dylib"

RET_WORD = 0xD65F03C0       # ret
MOV_W0_0_WORD = 0x52800000  # mov w0, #0
LDRB_W0_X0_MASK, LDRB_W0_X0 = 0xFFC003FF, 0x39400000   # ldrb w0,[x0,#imm12]
STRB_W2_X0_MASK, STRB_W2_X0 = 0xFFC003FF, 0x39000002   # strb w2,[x0,#imm12]


def load_rules(path=SIGNATURES_JSON):
    doc = json.load(open(path, encoding="utf-8"))
    u = doc["update"]
    # 自洽：ret / mov 字节串必须就是我们硬编码的指令字
    assert struct.unpack("<I", bytes.fromhex(u["ret"]))[0] == RET_WORD, u["ret"]
    assert struct.unpack("<I", bytes.fromhex(u["mov_w0_0"]))[0] == MOV_W0_0_WORD, u["mov_w0_0"]
    return u


# ---------- Mach-O / ObjC 元数据 ----------

class Image:
    def __init__(self, sl):
        self.sl = sl
        self.segs = L.parse_segments(sl)
        self.sects = self._parse_sections(sl)

    @staticmethod
    def _parse_sections(sl):
        ncmds = struct.unpack("<I", sl[16:20])[0]
        out = []
        off = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack("<II", sl[off:off + 8])
            if cmd == L.LC_SEGMENT_64:
                nsects = struct.unpack("<I", sl[off + 64:off + 68])[0]
                for i in range(nsects):
                    q = off + 72 + 80 * i
                    sectname = sl[q:q + 16].rstrip(b"\0").decode()
                    segname = sl[q + 16:q + 32].rstrip(b"\0").decode()
                    addr, size = struct.unpack("<QQ", sl[q + 32:q + 48])
                    fileoff = struct.unpack("<I", sl[q + 48:q + 52])[0]
                    out.append((segname, sectname, addr, size, fileoff))
            off += cmdsize
        return out

    def off(self, va, n=1):
        for vmaddr, _vmsize, fileoff, filesize in self.segs:
            if vmaddr <= va and va + n <= vmaddr + filesize:
                return fileoff + (va - vmaddr)
        raise SystemExit("VA 0x%x 不在任何段的文件映射内" % va)

    def word(self, va):
        o = self.off(va, 4)
        return struct.unpack_from("<I", self.sl, o)[0]

    def ptr(self, va):
        """读 8 字节指针。dyld chained fixups 把 rebase 目标编码在低 36 位（高位是链表 next / bind 标记），
        遇到高位非零就取低 36 位；解出来的值必须落在某个段里，否则报错而不是继续瞎读。"""
        v = struct.unpack_from("<Q", self.sl, self.off(va, 8))[0]
        if v == 0:
            return 0
        if v >> 36:
            v &= (1 << 36) - 1
        for vmaddr, vmsize, _fo, _fs in self.segs:
            if vmaddr <= v < vmaddr + vmsize:
                return v
        raise SystemExit("指针 0x%x（读自 0x%x）不在任何段内，chained-fixup 解码假设可能不再成立" % (v, va))

    def cstr(self, va, maxlen=512):
        o = self.off(va)
        end = self.sl.find(b"\0", o, o + maxlen)
        if end < 0:
            raise SystemExit("0x%x 处没有以 NUL 结尾的字符串" % va)
        return self.sl[o:end].decode("utf-8", errors="replace")

    def hexbytes(self, va, n):
        o = self.off(va, n)
        return self.sl[o:o + n].hex().upper()

    def find_class(self, name):
        lists = [s for s in self.sects if s[1] == "__objc_classlist"]
        if not lists:
            raise SystemExit("二进制里没有 __objc_classlist 段，不是含 ObjC 元数据的 Mach-O")
        found = []
        for _seg, _sect, addr, size, _fo in lists:
            for i in range(size // 8):
                try:
                    cls = self.ptr(addr + 8 * i)
                    ro = self.ptr(cls + 32) & ~7
                    if self.cstr(self.ptr(ro + 24)) == name:
                        found.append(cls)
                except SystemExit:
                    continue  # 个别（Swift）类元数据布局不同，跳过不影响按名找
        if not found:
            raise SystemExit("没找到 ObjC 类 %s —— 微信改名/搬走了更新器，需要人工重新逆向并更新 signatures.json" % name)
        if len(found) > 1:
            raise SystemExit("找到 %d 个同名类 %s，拒绝猜" % (len(found), name))
        return found[0]

    def method_list(self, ml):
        """返回 [(selector, imp_va)]。支持 relative（12 字节/项，2020+ 的默认）与 absolute（24 字节/项）两种方法表。"""
        if ml == 0:
            return []
        ef = self.word(ml)
        count = self.word(ml + 4)
        relative = bool(ef & 0x80000000)
        direct_sel = bool(ef & 0x40000000)   # 选择子偏移直接指向字符串而非 selref
        entsize = ef & 0xFFFC
        if count > 100000 or entsize < 12:
            raise SystemExit("方法表 0x%x 形态异常（entsize=%d count=%d）" % (ml, entsize, count))
        out = []
        for i in range(count):
            e = ml + 8 + i * entsize
            if relative:
                n_off, _t_off, i_off = struct.unpack_from("<iii", self.sl, self.off(e, 12))
                sel_va = e + n_off
                sel = self.cstr(sel_va) if direct_sel else self.cstr(self.ptr(sel_va))
                imp = e + 8 + i_off
            else:
                sel = self.cstr(self.ptr(e))
                imp = self.ptr(e + 16)
            out.append((sel, imp))
        return out

    def methods_of(self, cls):
        """实例方法 + 类方法合并成 {selector: imp}，同名时实例方法优先。"""
        ro = self.ptr(cls + 32) & ~7
        inst = self.method_list(self.ptr(ro + 32))
        meta = self.ptr(cls)  # isa → metaclass
        meta_ro = self.ptr(meta + 32) & ~7
        clsm = self.method_list(self.ptr(meta_ro + 32))
        d = {}
        for sel, imp in clsm + inst:  # inst 后写，覆盖同名类方法
            d[sel] = imp
        return d


# ---------- 入口指令形态校验 + 生成条目 ----------

def is_prologue(w):
    """函数入口第一条应是 stp（pre-index 或 signed offset）/ sub sp,sp,#imm / pacibsp。"""
    return (w & 0xFFC00000) in (0xA9800000, 0xA9000000) or (w & 0xFF0003FF) == 0xD10003FF or w == 0xD503237F


def build_target(img, rules):
    """按 signatures.json 的规则生成 update target；返回 (target_dict, rows)。rows 供打印：(名字, VA, 现字节, 状态)。"""
    cls = img.find_class(rules["class"])
    methods = img.methods_of(cls)
    wanted = list(rules["ret_methods"]) + [n for a in rules["zero_accessors"] for n in (a["getter"], a["setter"])]
    missing = [n for n in wanted if n not in methods]
    if missing:
        raise SystemExit("类 %s 缺方法：%s（有 %d 个方法）" % (rules["class"], ", ".join(missing), len(methods)))

    ret_hex, mov_hex = rules["ret"], rules["mov_w0_0"]
    entries, rows = [], []

    def add(name, va, expected_hex, asm_hex, state):
        entries.append({"arch": "arm64", "addr": "%x" % va, "expected": expected_hex, "asm": asm_hex})
        rows.append((name, va, img.hexbytes(va, len(asm_hex) // 2), state))

    for name in rules["ret_methods"]:
        va = methods[name]
        w = img.word(va)
        if w == RET_WORD:
            add(name, va, ret_hex, ret_hex, "already patched")
        elif is_prologue(w):
            add(name, va, img.hexbytes(va, 4), ret_hex, "pristine")
        else:
            raise SystemExit("%s @0x%x 入口是 %s，不是函数序言——微信改了实现，拒绝生成" % (name, va, img.hexbytes(va, 4)))

    for a in rules["zero_accessors"]:
        g, s = methods[a["getter"]], methods[a["setter"]]
        g0, g1, s0 = img.word(g), img.word(g + 4), img.word(s)
        g_field = s_field = None
        if g0 == MOV_W0_0_WORD and g1 == RET_WORD:
            add(a["getter"], g, mov_hex + ret_hex, mov_hex + ret_hex, "already patched")
        elif (g0 & LDRB_W0_X0_MASK) == LDRB_W0_X0 and g1 == RET_WORD:
            g_field = (g0 >> 10) & 0xFFF
            add(a["getter"], g, img.hexbytes(g, 8), mov_hex + ret_hex, "pristine (field 0x%x)" % g_field)
        else:
            raise SystemExit("%s @0x%x 是 %s，不是 `ldrb w0,[x0,#f]; ret`——拒绝生成" % (a["getter"], g, img.hexbytes(g, 8)))
        if s0 == RET_WORD:
            add(a["setter"], s, ret_hex, ret_hex, "already patched")
        elif (s0 & STRB_W2_X0_MASK) == STRB_W2_X0:
            s_field = (s0 >> 10) & 0xFFF
            add(a["setter"], s, img.hexbytes(s, 4), ret_hex, "pristine (field 0x%x)" % s_field)
        else:
            raise SystemExit("%s @0x%x 是 %s，不是 `strb w2,[x0,#f]`——拒绝生成" % (a["setter"], s, img.hexbytes(s, 4)))
        if g_field is not None and s_field is not None and g_field != s_field:
            raise SystemExit("%s 读字段 0x%x 而 %s 写字段 0x%x，不是同一对访问器" % (a["getter"], g_field, a["setter"], s_field))

    return {"identifier": "update", "binary": DYLIB_REL, "entries": entries}, rows


def wechat_build(app):
    plist = os.path.join(app, "Contents", "Info.plist")
    if not os.path.exists(plist):
        return None
    with open(plist, "rb") as f:
        return str(plistlib.load(f).get("CFBundleVersion"))


def main():
    ap = argparse.ArgumentParser(description="定位微信 4.x 屏蔽自动更新补丁点，生成 config.json 的 update target")
    ap.add_argument("-a", "--app", default="/Applications/WeChat.app")
    ap.add_argument("--dylib", help="直接指定 wechat.dylib（默认取 --app 下的）")
    ap.add_argument("--config", default=CONFIG)
    ap.add_argument("--version", help="写入 config 的构建号（默认读 --app 的 CFBundleVersion）")
    ap.add_argument("--append", action="store_true", help="追加进 config.json 对应构建号（须已有 revoke 条目）")
    args = ap.parse_args()

    dylib = args.dylib or os.path.join(args.app, DYLIB_REL)
    if not os.path.exists(dylib):
        sys.exit("找不到 %s" % dylib)
    build = args.version or wechat_build(args.app)
    rules = load_rules()

    sl, _ = L.arm64_slice(L.read_bytes(dylib))
    target, rows = build_target(Image(sl), rules)

    print("构建 %s · %s · 类 %s" % (build, dylib, rules["class"]))
    for name, va, cur, state in rows:
        print("  %-36s 0x%-8x %-18s %s" % (name, va, cur, state))

    if not args.append:
        print(json.dumps(target, ensure_ascii=False, indent=2))
        return

    if not build:
        sys.exit("--append 需要知道构建号：给 --version 或有效的 --app")
    cfg = json.load(open(args.config, encoding="utf-8"))
    entry = next((c for c in cfg if str(c["version"]) == str(build)), None)
    if entry is None:
        print("config.json 里没有构建号 %s 的条目；先 python3 tools/sync_ref.py 或 python3 tools/locate_revoke.py --append 加防撤回条目" % build)
        sys.exit(2)
    existing = next((t for t in entry["targets"] if t["identifier"] == "update"), None)
    if existing is not None:
        if existing == target:
            print("config.json 里 %s 已有相同的 update target，无需改动。" % build)
            return
        print("config.json 里 %s 已有 update target 但与本次定位不同，不覆盖。现有：\n%s" % (build, json.dumps(existing, indent=2)))
        sys.exit(3)
    entry["targets"].append(target)
    with open(args.config, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("[append] 已把 update target 追加进 config.json 的 %s。记得 swift build -c release。" % build)


if __name__ == "__main__":
    main()
