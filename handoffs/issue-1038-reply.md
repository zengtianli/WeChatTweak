# issue #1038 回复草稿 — 269579+ 打补丁后微信闪退（2026-09-02）

> 状态：修复已 push（commit 见 git log）。下面这段是准备贴到 sunnyyoung/WeChatTweak#1038 的回复，发前请用户过目。
> 历史草稿（`--variant keeptip` 在 269110/269111 报不可用）已过时，删。

---

> 2026-09-02 实际贴出的是下面这版简短说明（用户要求「简单说明就行」），已通过 gh api PATCH 覆盖原长文。

@783283 @kimibear 闪退已修，抱歉。原因是重签名把微信的 entitlements（沙盒等）抹掉了，SIP 开启的机器上系统直接杀进程；我机器 SIP 关着所以没发现。已改成保留 entitlements 重签，master 已更新。

被老版本打过的包救不回来，按这个走一遍：

```bash
# 1. 去 https://mac.weixin.qq.com 重装微信
# 2. 更新并重编
cd WeChatTweak && git pull && swift build -c release
# 3. 完全退出微信后打补丁（4.1.13 起不用 sudo）
.build/release/wechattweak patch --variant keeptip
```

我这边没法真机验证 SIP 开启的情况，打完能正常打开请回一句；还闪退就贴 `~/Library/Logs/DiagnosticReports/WeChat-*.ips` 前 30 行。
