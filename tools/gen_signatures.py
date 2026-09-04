#!/usr/bin/env python3
"""
gen_signatures.py — 从 signatures.json（SSOT）生成 Sources/WeChatTweak/Signatures.generated.swift。

signatures.json 改了必须重跑本脚本；`swift test` 里的 SignaturesSyncTests 会校验生成物与 JSON 一致，
不一致直接红。用 --check 只比对不写（CI / 提交前门）。
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "signatures.json")
DST = os.path.join(ROOT, "Sources", "WeChatTweak", "Signatures.generated.swift")


def render(doc):
    lines = [
        "// GENERATED FILE — do not edit. Source of truth: signatures.json (repo root).",
        "// Regenerate: python3 tools/gen_signatures.py   (SignaturesSyncTests fails if stale)",
        "",
        "extension RevokeLocator {",
        "    static let offCbz: UInt64 = %s" % doc["off_cbz"],
        "    static let signatures: [Signature] = [",
    ]
    for g in doc["generations"]:
        lines.append('        Signature(name: "%s", builds: "%s", cbzHex: "%s", branchHex: "%s", delta: %s, strX0Hex: "%s", strXzrHex: "%s", field: %s),'
                     % (g["name"], g["builds"], g["cbz"], g["b"], g["delta"], g["str_x0"], g["str_xzr"], g["field"]))
    lines += ["    ]", "}", ""]
    u = doc["update"]
    lines += [
        "extension UpdateLocator {",
        '    static let className = "%s"' % u["class"],
        "    static let retMethods: [String] = [%s]" % ", ".join('"%s"' % m for m in u["ret_methods"]),
        "    static let zeroAccessors: [(getter: String, setter: String)] = [",
    ]
    for a in u["zero_accessors"]:
        lines.append('        (getter: "%s", setter: "%s"),' % (a["getter"], a["setter"]))
    lines += [
        "    ]",
        '    static let retHex = "%s"' % u["ret"],
        '    static let movW0ZeroHex = "%s"' % u["mov_w0_0"],
        "}",
        "",
    ]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比对，不写文件；不一致 exit 1")
    args = ap.parse_args()
    doc = json.load(open(SRC, encoding="utf-8"))
    out = render(doc)
    if args.check:
        cur = open(DST, encoding="utf-8").read() if os.path.exists(DST) else ""
        if cur != out:
            sys.exit("Signatures.generated.swift 与 signatures.json 不一致，跑 python3 tools/gen_signatures.py")
        print("in sync")
        return
    with open(DST, "w", encoding="utf-8") as f:
        f.write(out)
    print("wrote", os.path.relpath(DST, ROOT))


if __name__ == "__main__":
    main()
