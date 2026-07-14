# 留提示防撤回（4.1.11 / 269136）— 已实现且实机实测通过

目标：让 4.x 防撤回从「静默」升级为「留消息 + 显示撤回提示」（issue #1038）。**已实现为 `--variant keeptip`，269136 实机实测有提示。**

## ✅ 2026-07-14 最终实测结论：keeptip 纯字节补丁在 269136 上 = 留消息 + 有提示

用户实机测撤回：`--variant keeptip` 生效，撤回后消息保留、且显示「对方撤回了一条消息」提示。

> 注：本会话中途一度记为「实测失败/仍静默」，那是早一轮测试的结论；用户随后复测确认**有提示**，以最终实测为准，纯字节路线成立。fzlzjerry 弃用纯字节 `revoke-tip` 是因为它分不清自撤/他撤可能冒重复提示（体验取舍），并非纯字节在本 build 给不了提示。

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
