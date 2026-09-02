# issue #1038 回复草稿 — 269579+ 打补丁后微信闪退（2026-09-02）

> 状态：修复已 push（commit 见 git log）。下面这段是准备贴到 sunnyyoung/WeChatTweak#1038 的回复，发前请用户过目。
> 历史草稿（`--variant keeptip` 在 269110/269111 报不可用）已过时，删。

---

@783283 @kimibear 闪退的根因找到了，已修，抱歉。

**原因**：微信 4.x 主程序是 App Sandbox + Hardened Runtime，entitlements 里带腾讯 Team ID。本仓库之前的重签名流程是 `codesign --remove-sign` 再裸 `--deep --sign -`，这会把整个包（主程序 + 全部 helper/appex）的 entitlements 全部抹掉——沙盒、相机、麦克风、app-group 一个不剩。SIP 开启的 Mac 上 AMFI 直接把微信杀掉，表现就是闪退。我自己的机器 SIP 是关的，所以一直没复现出来，这是我的问题。

**修复**（已 push 到 master）：重签名改为逐组件保留原厂 entitlements，并注入 `com.apple.security.cs.disable-library-validation` / `com.apple.security.cs.allow-unsigned-executable-memory` 两个键（与 fzlzjerry/wechat-antirecall 同一方案，他们那边多用户验证过），签完逐项比对，丢任何一项直接报错。我用官方 dmg 的原厂 269579 包跑了一遍：175 个组件 entitlements 与原厂一致，`codesign --verify --deep --strict` 通过。

**怎么恢复**（已经被老版本打过的包救不回来，entitlements 已经从文件里删掉了）：

```bash
# 1. 重装微信：去 https://mac.weixin.qq.com 下 dmg 覆盖安装（装完可能自动升到 269626，两个构建号都已支持）
# 2. 更新本仓库并重编
cd WeChatTweak && git pull && swift build -c release
# 3. 完全退出微信（⌘Q 后等几秒，`pgrep -x WeChat` 没输出才算退干净；现在工具会自检，在跑就拒绝）
# 4. 打补丁 —— 4.1.13 起先【不加 sudo】，包归当前用户所有；报 permission denied 再加
.build/release/wechattweak patch --variant keeptip      # 或不带 --variant 用静默
```

**顺便**：config 已同步 fzlzjerry 的全部 4.x 构建号（268575 ~ 269626 共 35 个），以后微信热修后 `python3 tools/sync_ref.py && swift build -c release` 就能跟上；本仓库 issues 也已打开，可以直接去 zengtianli/WeChatTweak 报。

我这边没有 SIP 开启的机器，**修复是否彻底需要你们实测**：重装 + 打完后微信能正常打开、能登录，请回一句；若仍闪退，请贴 `~/Library/Logs/DiagnosticReports/` 里最新的 `WeChat-*.ips` 前 30 行（`Exception Type` / `Termination Reason` 那几行最关键）和 `sw_vers` 输出。
