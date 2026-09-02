# CLAUDE.md · WeChatTweak

> 📋 会话回顾：handoffs/sessions-recap.md（5 会话 merge,截至 2026-07-19;/start 从此接最新进度,源会话已退役）

> 全局铁律/凭证/偏好见 `~/.claude/CLAUDE.md`；`~/Apps` 子公司约束见 `~/Apps/CLAUDE.md`。此处只放本 app 特有导航，不复述。

## 这是什么

macOS 微信客户端补丁 CLI，**Swift Package**（非 Python）。fork 自 [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)，本 fork 新增**微信 4.x 防撤回**支持。纯字节补丁工具，无代码注入。

- 上游只覆盖到微信 3.8.x（撤回逻辑在主程序 `Contents/MacOS/WeChat`）。
- 微信 4.x 把撤回逻辑搬进 `Contents/Resources/wechat.dylib`，本 fork 按目标 dylib 打补丁 + 写入前原始字节校验（打错版本报错拒写，不盲写弄坏微信）。
- 防撤回原理：把 `parseRevokeXML` 里的 `cbz w0, X`（条件跳转）改成 `b X`（无条件跳转），撤回照收照解析但永远走不到删消息代码。**只能静默**（消息留下、无「对方撤回」提示、无法高亮），机制原因见 README「为什么是静默」节。

## Quick Reference

| 项目 | 值 |
|---|---|
| 语言 / 类型 | Swift 6.0 · SwiftPM executable（`swift-tools-version:6.0`, macOS 12+） |
| 产物 | `wechattweak`（CLI） |
| 唯一依赖 | apple/swift-argument-parser ≥1.6.0 |
| 补丁数据 SSOT | `config.json`（按 `CFBundleVersion` 构建号匹配，非营销版本号） |
| 默认 config 源 | **本地优先**：先找 cwd 再从可执行文件向上找 `config.json`（源码编译流程开箱即用，`locate_revoke.py --append` 加的版本立即生效）；本地找不到才回退远程 raw URL；可 `-c <路径或URL>` 覆盖 |
| 上游 remote | https://github.com/zengtianli/WeChatTweak |
| License | AGPL-3.0（沿用上游） |

## 常用命令

```bash
# 编译（Makefile 出通用二进制 arm64+x86_64；日常调试用 debug 更快）
swift build -c release            # 产物 .build/release/wechattweak
make build                        # 通用二进制 + cp 到 ./wechattweak

# 看当前微信构建号 + 支持列表
.build/release/wechattweak versions

# 打补丁（微信在 /Applications 由 root 拥有，需 sudo；先 pkill -x WeChat）
sudo .build/release/wechattweak patch

make clean                        # rm -rf .build && rm -f wechattweak

# 测试（11 例：定位器/Patcher/签名表同步）
swift test

# 微信发版后的补丁点补齐，按顺序：同步参考实现 → 自己定位 → 人工
python3 tools/sync_ref.py --dry-run && python3 tools/sync_ref.py    # 从 fzlzjerry patches.json 搬 revoke/revoke-tip
python3 tools/locate_revoke.py --append                             # 参考实现还没收录时，按 signatures.json 各代签名扫
python3 tools/gen_signatures.py [--check]                           # 改了 signatures.json 后重新生成 Swift 表
```

子命令只有两个：`versions`、`patch`（见 `Sources/WeChatTweak/main.swift`）。

## 项目结构

```
Sources/WeChatTweak/
  main.swift      # ArgumentParser 入口 + Versions/Patch 两个子命令
  Command.swift   # 高层编排：读版本、逐 target 打补丁、重签名（先签 dylib 再 --deep 签整包）
  Config.swift    # config.json 解码（version/targets/entries；arch/addr/asm/expected 十六进制）
  Patcher.swift   # Mach-O 定位 VA→文件偏移 + 原始字节校验 + 等长写入
  RevokeLocator.swift            # --auto-locate：按签名代扫 dylib
  Signatures.generated.swift     # 生成物，禁手改（源 = signatures.json）
Tests/WeChatTweakTests/          # XCTest：合成 Mach-O fixture + 定位器/Patcher/签名同步
config.json       # 补丁数据 SSOT（每个构建号一组 targets/entries）
signatures.json   # 几何签名各代 SSOT（Python 定位器直接读，Swift 由 tools/gen_signatures.py 派生）
tools/sync_ref.py       # 从 fzlzjerry/wechat-antirecall 同步补丁点（只搬 revoke 两类，本机构建逐字节校验）
tools/locate_revoke.py  # 自主定位器（参考实现落后时的兜底）
tools/_archive/         # hunt_delete.py：群聊留提示的 lldb 调查，已放弃
Makefile          # swift build 通用二进制
```

## 开发注意事项

- **打补丁必先退出微信**（`pkill -x WeChat`）：运行中打补丁触发签名失效崩溃。
- **补丁是原地等长替换**：`asm` 字节数必须等于被替换指令长度（防撤回 4 字节 `cbz`→`b`），不改二进制布局。
- **写入前必过 `expected` 字节校验**：打错微信版本会 `expectedMismatch` 报错拒写。新增版本时 `expected` 填目标处原始字节（可列多个变体，如 pristine + 已打补丁）。
- **新增微信版本 = 改 `config.json`**（不改 Swift 代码）：第一动作 `python3 tools/sync_ref.py`（参考实现多半已收录），没收录再 `python3 tools/locate_revoke.py --append`，然后 `swift build -c release`。定位器按「代」扫签名（三代内置，见 README「新增一个版本」的代表），同代热修直接命中；三代都不中才是真重编译，先看 fzlzjerry/wechat-antirecall `patches.json` 有没有相邻构建号的条目再人工逆向，新一代只加进 `signatures.json` 一处，跑 `tools/gen_signatures.py` 派生 Swift 表（`swift test` 拦漏生成）。加完 → 重编译 → 实测撤回。
- **微信自动更新会静默还原补丁**（2026-06-26、08-28、09-01 三次实证）：用户报「防撤回没了」第一动作查 `CFBundleVersion` 是否变了，别先怀疑补丁逻辑。2026-09-02 已 `defaults write com.tencent.xinWeChat SUAutomaticallyUpdate/SUEnableAutomaticChecks -bool NO`（Sparkle 原本每 300 秒查一次），**是否真挡得住要等下一次微信发版才知道**；挡不住就移植 fzlzjerry 的 `update` 补丁目标。4.1.13 起 Sparkle 以当前用户身份写包，`/Applications/WeChat.app` 归用户所有，**打补丁不再需要 sudo**。
- **验证只能靠实收撤回**：防撤回是否生效，必须找人发消息再撤回实测（README 已强调），符号被剥离、无法静态确认。
- **微信 4.x 只做了防撤回**：多开需整包复制 App，阻止更新的补丁点尚未纳入本 fork。
- **重签名逻辑在 `Resigner.swift`**（2026-09-02 重写）：快照全包 entitlements → 签 dylib → `--deep --preserve-metadata=identifier,flags,runtime` 签整包 → 逐组件恢复原 entitlements + 注入 2 个 `cs.*` 键 → 比对 → `--verify --deep --strict`。**禁回退到 `--remove-sign` + 裸 `--deep --sign -`**：那会抹光沙盒/Team-ID entitlements，SIP 开启的机器上微信直接闪退（#1038 269579 多人实证）。
- ⚠️ **本机 SIP 是关闭的**（enableMacosAI 内核扩展需要），**签名 / entitlements / AMFI 类问题在本机永远复现不出来**——「本机能跑」不构成签名正确的证据。签名改动的验收 = 对原厂 dmg 副本跑 patch 后逐组件比对 entitlements（`Tests` 里没法覆盖 codesign，本轮是手工脚本；原厂 dmg：<https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac.dmg>），真机验证只能靠 issue 里的用户反馈。
- **打补丁前工具自检微信是否在运行**（`pgrep -f <app>/Contents/MacOS/`），在跑就拒绝；⌘Q/pkill 后微信要几秒才退干净。
