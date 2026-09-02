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
```

子命令只有两个：`versions`、`patch`（见 `Sources/WeChatTweak/main.swift`）。

## 项目结构

```
Sources/WeChatTweak/
  main.swift      # ArgumentParser 入口 + Versions/Patch 两个子命令
  Command.swift   # 高层编排：读版本、逐 target 打补丁、重签名（先签 dylib 再 --deep 签整包）
  Config.swift    # config.json 解码（version/targets/entries；arch/addr/asm/expected 十六进制）
  Patcher.swift   # Mach-O 定位 VA→文件偏移 + 原始字节校验 + 等长写入
config.json       # 补丁数据 SSOT（每个构建号一组 targets/entries）
Makefile          # swift build 通用二进制
```

## 开发注意事项

- **打补丁必先退出微信**（`pkill -x WeChat`）：运行中打补丁触发签名失效崩溃。
- **补丁是原地等长替换**：`asm` 字节数必须等于被替换指令长度（防撤回 4 字节 `cbz`→`b`），不改二进制布局。
- **写入前必过 `expected` 字节校验**：打错微信版本会 `expectedMismatch` 报错拒写。新增版本时 `expected` 填目标处原始字节（可列多个变体，如 pristine + 已打补丁）。
- **新增微信版本 = 改 `config.json`**（不改 Swift 代码）：第一动作 `python3 tools/locate_revoke.py --append && swift build -c release`。定位器按「代」扫签名（三代内置，见 README「新增一个版本」的代表），同代热修直接命中；三代都不中才是真重编译，先看 fzlzjerry/wechat-antirecall `patches.json` 有没有相邻构建号的条目再人工逆向，新一代必须**同时**加进 `tools/locate_revoke.py` GENERATIONS 与 `RevokeLocator.swift` signatures。加完 → 重编译 → 实测撤回。
- **微信自动更新会静默还原补丁**（2026-06-26、08-28、09-01 三次实证）：用户报「防撤回没了」第一动作查 `CFBundleVersion` 是否变了，别先怀疑补丁逻辑。4.1.13 起 Sparkle 以当前用户身份写包，`/Applications/WeChat.app` 归用户所有，**打补丁不再需要 sudo**。
- **验证只能靠实收撤回**：防撤回是否生效，必须找人发消息再撤回实测（README 已强调），符号被剥离、无法静态确认。
- **微信 4.x 只做了防撤回**：多开需整包复制 App，阻止更新的补丁点尚未纳入本 fork。
- **重签名逻辑在 Command.swift**：改补丁流程注意先单独签被改的 dylib，再 `--deep` 签整个 App。
