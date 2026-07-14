# 留提示防撤回（4.1.11 / 269136）— 已实现且实机实测通过

目标：让 4.x 防撤回从「静默」升级为「留消息 + 显示撤回提示」（issue #1038）。**已实现为 `--variant keeptip`，269136 实机实测有提示。**

## 2026-07-14 实测结论：keeptip 在 269136 上 = 私聊有提示 / 群聊仍静默

- **私聊**：`--variant keeptip` 生效，消息保留 + 显示撤回提示。
- **群聊**：撤回消息保留，但**无提示**（表现同静默变体）。

**群聊无提示根因（静态已定性）**：整个 revoke 模块 `0x48a0140..0x48ad700` 内写 newmsgid 字段 `[x19,#0x168]` 的**只有 `0x48a0b44` 一处**（另 `[sp,#0x168]` 两处是栈变量无关），私聊群聊共用。私聊提示插入不依赖 newmsgid → 照出；群聊提示渲染依赖 newmsgid（决定挂哪条下面）→ 被清零后连带失效 → 静默。下游 consumer 经虚派发/chained-fixup 分发，静态无独立「群聊提示」补丁点（与前 3 路逆向撞的是同一堵墙，按停止线不再盲啃）。

**群聊出提示的可行路径**：见下节「群聊深挖」。silent + keeptip(私聊) 两个字节变体可靠可用。

## 群聊深挖（2026-07-14，读 fzlzjerry Runtime.mm 源码核实）

**结论：fzlzjerry 的 `--runtime-tip` 对群聊同样无效，纯字节/文本改写这条路给不了群聊提示。已放弃移植。**

读 `Runtime.mm:1259-1327` `hookedParseRevokeXML`（原生解析后运行）确认其真实机制：
- 全文件**零** `objc_msgSend`/selector/vtable/独立插入调用——它**不自己插提示行**。
- 别人撤回分支：`*newMsgId=0`（保消息）+ `replaceMsg->assign(renderRevokeTip(...))` **只改写 replaceMsg 文本**，靠**微信原生代码**把这条 replaceMsg 当提示插入。
- 自己撤回分支：`*newMsgId=realNewMsgId` 恢复真值 → 微信正常删除（原生「你撤回了一条消息」）。**这行证明 newmsgid 直接控制删除**。

因此 fzlzjerry 落在和我们字节 keeptip **完全相同的 newmsgid=0 状态**，只是提示文本不同；既然 keeptip 群聊不出提示（原生插入未触发），fzlzjerry 依赖同一原生插入、群聊必然也不出。**airtight，无需降级实验。**

**根本矛盾（bind）**：newmsgid 同时控制①删除 ②群聊提示的插入/锚定。
- newmsgid=0 → 不删（消息保留 ✓）但群聊提示不插入（✗）。
- newmsgid=真 → 群聊提示插入且锚定（✓）但消息被删（✗）。
- 私聊提示不依赖 newmsgid，故 newmsgid=0 时私聊照出。

**唯一能同时满足群聊「保消息+有提示」的路 = 解耦删除与提示**：保留真 newmsgid（让原生提示对群/私都插入并锚定），转而在**下游掐掉那次删除调用**。而那条删除调用正是前 3 路静态逆向撞墙的虚派发接收侧——**只能动态定位**（lldb 断在 WCDB 删除原语 / sqlite3_prepare 抓 DELETE + backtrace，用户触发一次真群聊撤回）。找到后 NOP 它（保 newmsgid 真值）→ 私聊+群聊都留消息+有提示。属需用户配合的动态 RE 工程，结果不保证。

**替代**：注入 dylib、hook 那条删除函数跳过删除（等价于 NOP，但更稳健）——同样需先动态定位删除函数。

---
（以下为实现记录）

## 结论（机制已定位、代码已实现、静态已复核）

**留提示 = 把 newmsgid 清零让删除落空，不是「NOP 下游删除调用」。**
- `TryParseMessageXML`（入口 `0x48a0140`）在 `0x48a0b44` 处把解析出的 `newmsgid` 存进结构体：`str x0,[x19,#0x168]`（`60B600F9`）。
- 改成 `str xzr,...`（`7FB600F9`）→ 存进去的 newmsgid = 0 → 下游按 id=0 删本地消息找不到目标 → 删不掉；`replacemsg` 提示照常插入。
- 这条 `str x0`→`str xzr` 来自参考实现 **fzlzjerry/wechat-antirecall 的 `revoke-tip` 模式**（H2 网查捞到）。它另有 `--runtime-tip` 用注入 dylib 自定义提示文案，本 fork 未纳入。

**修正两次错判**：
1. 早前 README/commit 说「4.x 只能静默、给不了提示」——错，能。
2. 中途以为「留提示 = 静态定位并 NOP 掉下游删除调用」，因该调用在虚派发/chained-fixup 接收侧、静态难定位而搁置——方向错了。正确做法不需要找删除调用，源头清零 newmsgid 即可。

## 已确认字节（arm64 切片，VA==文件偏移，objdump 双验）
- `0x48a03b0`：`cbz w0,0x48a05ac`（`E00F0034`）；静默补丁改为 `b`（`7F000014`）。
- `0x48a0b44`：`str x0,[x19,#0x168]`（`60B600F9`）；留提示补丁改为 `str xzr`（`7FB600F9`）。

## 实现（已落地）
- `config.json` 269136 新增 `revoke-keeptip` target：
  - `{addr:48a03b0, expected:[E00F0034,7F000014], asm:E00F0034}`（恢复 cbz，兼容干净机与已静默补丁机）
  - `{addr:48a0b44, expected:60B600F9, asm:7FB600F9}`（清零 newmsgid）
- `main.swift`：`patch` 加 `--variant silent|keeptip`（默认 silent，向后兼容）+ `PatchVariant` 枚举。
- `Command.swift`：`patch(...variant:)` 按变体互斥选择 `revoke` / `revoke-keeptip`，其它 target（更新器/多开）不受影响；keeptip 但无 `revoke-keeptip` target → `keeptipUnavailable` 报错。
- `Patcher.swift` 未改（`expected:[Data]` 数组匹配 + `current==patch` 幂等跳过，已够用）。

## 已验证（静态 end-to-end）
在 StubWeChat.app（真 dylib 副本，CFBundleVersion=269136）上真跑：
- `patch --variant keeptip` → 只打 revoke-keeptip；`0x48a03b0`:`7F000014→E00F0034`、`0x48a0b44`:`60B600F9→7FB600F9`；重抽 arm64 切片 objdump 确认 = `cbz w0` / `str xzr`。
- `patch --variant silent` → 只打 revoke（`E00F0034→7F000014`）。互斥选择 + fat 切片偏移定位 + expected 数组 guard 全对。

## 实收撤回终验：✅ 已通过（2026-07-14 用户实机）
退微信 → `swift build -c release` → `sudo .build/release/wechattweak patch --variant keeptip` → 重开 → 找人发消息再撤回 → 「消息还在 **且** 显示撤回提示」= 确认。README 已去掉「待实测」标注。
- 切回静默：`patch --variant silent`（互斥、幂等）。
- 回滚：官网重装微信覆盖。

## 停止线
同一障碍试 ≥3 次无进展 → 停、记这里、回报。补丁致微信起不来 → 官网重装覆盖回滚。
