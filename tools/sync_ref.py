#!/usr/bin/env python3
"""
sync_ref.py — 从参考实现 fzlzjerry/wechat-antirecall 的 patches.json 同步防撤回补丁点进本仓库 config.json。

为什么：微信几乎每周发热修，参考实现一般当天就收录新构建号；自己每次手工逆向 / 手抄是重复劳动。
本脚本只搬 `revoke`（静默）和 `revoke-tip`（→ 本仓库叫 `revoke-keeptip`）两个 target，
不搬 update / multiInstance / runtime-tip（本 fork 不支持这些机制）。

安全阀：
- 只新增本仓库没有的构建号，从不覆盖已有条目。
- 若本机 /Applications/WeChat.app 的构建号在本次新增里，逐字节对本机 wechat.dylib 校验 `expected`，
  不匹配就整次放弃（exit 2）—— 参考数据错了不能带进仓库。其他构建号本机无法校验，靠 patch 时的
  expected 门兜底（打错构建号会拒写）。
- 远端拉不到 / JSON 结构不对 → 非零退出，不在空集上报绿。

用法：
    python3 tools/sync_ref.py            # 同步并写 config.json
    python3 tools/sync_ref.py --dry-run  # 只打印会新增什么
"""
import argparse
import json
import os
import plistlib
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate_revoke as L  # noqa: E402  Mach-O 工具函数复用，不另写一份

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "config.json")
REF_URL = "https://raw.githubusercontent.com/fzlzjerry/wechat-antirecall/main/patches.json"
ID_MAP = {"revoke": "revoke", "revoke-tip": "revoke-keeptip"}
DYLIB_REL = "Contents/Resources/wechat.dylib"


def fetch(url, attempts=3):
    """raw.githubusercontent 偶发 IncompleteRead / 超时，重试 3 次后仍失败才放弃。"""
    last = None
    for i in range(attempts):
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                return json.loads(r.read().decode("utf-8"))
        except (OSError, ValueError) as e:  # IncompleteRead/URLError 是 OSError 子类；坏 JSON 是 ValueError
            last = e
            print("  fetch 第 %d 次失败：%s" % (i + 1, e), file=sys.stderr)
    sys.exit("拉取参考 patches.json 失败（%d 次）：%s" % (attempts, last))


def local_build(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return str(plistlib.load(f).get("CFBundleVersion"))
    except FileNotFoundError:
        return None


def verify_against_dylib(dylib_path, targets):
    """逐条检查 expected 里至少有一个变体等于本机 dylib 上的实际字节。返回不匹配列表。"""
    sl, _ = L.arm64_slice(L.read_bytes(dylib_path))
    segs = L.parse_segments(sl)
    bad = []
    for t in targets:
        for e in t["entries"]:
            if e["arch"] != "arm64":
                continue
            va = int(e["addr"], 16)
            fo = None
            for vmaddr, _vmsize, fileoff, filesize in segs:
                if vmaddr <= va < vmaddr + filesize:
                    fo = fileoff + (va - vmaddr)
                    break
            if fo is None:
                bad.append((t["identifier"], e["addr"], "VA 不在任何段内"))
                continue
            actual = sl[fo:fo + len(e["asm"]) // 2].hex().upper()
            exp = e["expected"] if isinstance(e["expected"], list) else [e["expected"]]
            ok = actual in [x.upper() for x in exp] or actual == e["asm"].upper()
            if not ok:
                bad.append((t["identifier"], e["addr"], "本机 %s ≠ expected %s" % (actual, "/".join(exp))))
    return bad


def convert(ref_entry):
    """参考实现的一条 version → 本仓库格式；没有 revoke 就返回 None。"""
    targets = []
    for t in ref_entry.get("targets", []):
        ident = ID_MAP.get(t.get("identifier"))
        if not ident:
            continue
        entries = [{"arch": e["arch"], "addr": e["addr"], "expected": e["expected"], "asm": e["asm"]}
                   for e in t["entries"]]
        targets.append({"identifier": ident, "binary": t.get("binary", DYLIB_REL), "entries": entries})
    if not any(t["identifier"] == "revoke" for t in targets):
        return None
    return {"version": str(ref_entry["version"]), "targets": targets,
            "source": "fzlzjerry/wechat-antirecall patches.json"}


def main():
    ap = argparse.ArgumentParser(description="从 fzlzjerry/wechat-antirecall 同步防撤回补丁点进 config.json")
    ap.add_argument("--url", default=REF_URL)
    ap.add_argument("--config", default=CONFIG)
    ap.add_argument("--app", default="/Applications/WeChat.app")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ref = fetch(args.url)
    if not isinstance(ref, list) or not ref or "version" not in ref[0]:
        sys.exit("参考 patches.json 结构不是预期的 [{version, targets}] 列表，拒绝继续")
    cfg = json.load(open(args.config, encoding="utf-8"))
    have = {str(c["version"]) for c in cfg}

    new = []
    for r in ref:
        if str(r["version"]) in have:
            continue
        conv = convert(r)
        if conv:
            new.append(conv)
    if not new:
        print("参考实现没有本仓库缺的构建号（本仓库 %d 个，参考 %d 个）。" % (len(cfg), len(ref)))
        return

    build = local_build(args.app)
    mine = next((n for n in new if n["version"] == build), None)
    if mine:
        bad = verify_against_dylib(os.path.join(args.app, DYLIB_REL), mine["targets"])
        if bad:
            for b in bad:
                print("  ✗", *b)
            sys.exit(2)
        print("本机构建 %s 在新增里，已逐字节校验 expected 通过。" % build)
    else:
        print("本机构建 %s 不在新增里，新增条目仅能靠 patch 时的 expected 门兜底。" % build)

    new.sort(key=lambda n: int(n["version"]), reverse=True)
    for n in new:
        ids = ",".join(t["identifier"] for t in n["targets"])
        print("  + %s  [%s]" % (n["version"], ids))
    if args.dry_run:
        print("(dry-run，未写 %s)" % os.path.relpath(args.config, ROOT))
        return
    merged = sorted(new + cfg, key=lambda c: int(c["version"]), reverse=True)
    with open(args.config, "w", encoding="utf-8") as f:
        json.dump(merged, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("已写入 %d 条到 %s，记得 swift build -c release。" % (len(new), os.path.relpath(args.config, ROOT)))


if __name__ == "__main__":
    main()
