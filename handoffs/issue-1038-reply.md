# issue #1038 回复 — 269579+ 打补丁后微信闪退（2026-09-02）

> 已贴上游的是【简单版】（评论 5513041305，2026-09-02 编辑替换）。【完整版】留档，有人追问细节时贴。
> 修复 commit `4178aab`。

## 简单版（已贴）

@783283 @kimibear 闪退原因找到了，是重签名把微信的 entitlements（沙盒等）抹掉了，SIP 开启的机器上系统直接把微信杀掉。已修，push 到 master。

被打坏的包救不回来，按下面走一遍：

1. 去 https://mac.weixin.qq.com 重装微信
2. `git pull && swift build -c release`
3. 完全退出微信（等几秒，`pgrep -x WeChat` 没输出）
4. `.build/release/wechattweak patch --variant keeptip`（4.1.13 起不用 sudo）

我这边机器 SIP 是关的，验证不了闪退，麻烦打完回一句能不能正常打开。仍闪退的话贴 `~/Library/Logs/DiagnosticReports/WeChat-*.ips` 前 30 行。

## 完整版（留档）

@783283 @kimibear 闪退的根因找到了，已修，抱歉。

**原因**：微信 4.x 主程序是 App Sandbox + Hardened Runtime，entitlements 里带腾讯 Team ID（`com.apple.application-identifier = 5A4RE8SF68.…`）。本仓库之前的重签名流程是 `codesign --remove-sign` 再裸 `--deep --sign -`，这会把整个包（主程序 + 全部 helper / appex，共 225 个代码对象）的 entitlements 全部抹掉——沙盒、相机、麦克风、app-group 一个不剩。SIP 开启的 Mac 上 AMFI 直接把微信杀掉，表现就是闪退。补丁字节本身没打错（两位的输出里地址、字节都对）。我自己的机器 SIP 是关的，AMFI 不强制这些检查，所以一直没复现出来，这是我的问题。

**修复**（已 push 到 master，commit `4178aab`）：重签名改为

1. 先快照包内每个代码对象的 entitlements；
2. 签被改的 `wechat.dylib`，再 `--deep --preserve-metadata=identifier,flags,runtime` 签整包（不保留 `requirements`，它绑定原厂 Developer ID 会让嵌套代码对父包无效）；
3. 逐组件恢复原 entitlements，并注入 `com.apple.security.cs.disable-library-validation`（重签后框架没有 Team ID，主程序 entitlements 仍写着腾讯 Team ID，不加这个加载第一个框架就报 different Team IDs）和 `com.apple.security.cs.allow-unsigned-executable-memory`（登录时 `wechat.dylib` 会跳进 mmap 的 RX 匿名页，Hardened Runtime 默认拒绝，`allow-jit` 只覆盖 MAP_JIT）；
4. 签完逐项比对，丢任何一项直接报错，不会把一个残缺的包报成成功；
5. `codesign --verify --deep --strict`。

方案与 fzlzjerry/wechat-antirecall 一致，他们那边多用户验证过。我用官方 dmg 的原厂 269579 包完整跑了一遍：175 个组件 entitlements 与「原厂 + 2 个注入键」逐项一致，主程序保留 Hardened Runtime，verify 通过。

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
