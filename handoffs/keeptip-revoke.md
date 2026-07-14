# 留提示防撤回（4.1.11 / 269136）— 逆向记录

目标：让 4.x 防撤回从「静默」升级为「留消息 + 显示撤回提示」（issue #1038，wuliyc 称可行但未给地址）。

## 结论（4 路并行逆向 + 合成复核，高置信）

**补丁块 `0x48a03b4..0x48a05ac` 不是「删消息+提示」，而是撤回 XML 解析器。** 具体：
- 补丁点所在函数 = `MessageSystemExtInfo::TryParseMessageXML`（入口 `0x48a0140`）。混淆常量三路独立解出同名：`"revokemsg"` / `"message_system_extinfo.cc"` / `"TryParseMessageXML"` / 错误日志 `"revokemsg_node is empty"`。
- `0x48a03ac` 谓词 = 判 msgType 是否 `"revokemsg"`；`0x48a03b0` 的 `cbz w0,0x48a05ac` 据此分支。
- 块内 8 条 call = 7 条 XML getter/isEmpty/日志 + 1 条 `std::string` free（`0x48a05a4`→__stubs），**无一删消息**。
- 成功解析路径 `0x48a0a04..` 把 `newmsgid`/`revoketime`/`session`/`replacemsg` 抽进结构体 `x19`（`+0x168`/`+0x188` 等）。
- 撤回**提示文本 = 服务器下发的 `replacemsg` 字段**（本地化串「你撤回了一条消息」@`0x8fd628e` 代码 xref=0，佐证）。

**因此**：静默补丁（`cbz→b`）= 跳过整段 revokemsg 解析 → 下游拿不到 `newmsgid`/`replacemsg` → 删消息 + 插提示一起不发生。要「留消息+提示」= ① 恢复 `cbz` 让解析照跑；② 到**下游 consumer** NOP 掉「按 newmsgid 删本地消息」的调用。

**下游删除调用的 VA 静态四路均未定位**（不在解析函数内）。合成诚实标 `unresolved`，未编造地址。

## 已确认字节
- `0x48a03b0`：原始 `E00F0034`（`cbz w0,0x48a05ac`），本机现为 `7F000014`（`b`，已被静默补丁改）。VA==文件偏移。

## config.json「留提示」变体骨架（step2 待定，勿上机）
```jsonc
{
  "version": "269136",
  "targets": [{
    "identifier": "revoke-keeptip",
    "binary": "Contents/Resources/wechat.dylib",
    "entries": [
      // step1: 恢复 cbz 让解析照跑。expected 兼容出厂 E00F0034 与已补丁 7F000014
      { "arch": "arm64", "addr": "48a03b0", "expected": ["E00F0034","7F000014"], "asm": "E00F0034" },
      // step2: NOP 下游「删本地消息」调用。VA 未定位，占位，禁上机
      { "arch": "arm64", "addr": "<TBD-downstream-delete-VA>", "expected": "<TBD>", "asm": "1F2003D5" }
    ]
  }]
}
```
注：现 `config.json` 的 `expected` 是单字符串；step1 用了数组。若 `Config.swift`/`Patcher.swift` 不吃数组，需先确认（`Config.Entry.expected` 已是 `[Data]`，应支持）。keep-tip 变体与现有 `revoke`（全跳过）**二选一**，勿同启。

## 下一步（按性价比）
1. **[主推] 等 wuliyc 回复**要下游删除调用的函数/原字节/改法 —— 草稿见 `handoffs/wuliyc-reply-draft.md`（需用户去 issue #1038 发）。
2. **lldb 动态定位**（需用户配合）：微信开着，在 `0x48a0a04`（newmsgid 入 x19）下断，收真撤回时跟 `newmsgid` 被哪个下游函数消费；对本地消息表 SQLite DELETE / 消息管理器删除方法下断，栈顶帧即删除调用 VA → 读原 4 字节填 step2。
3. 上机顺序：先只加 step1（恢复 cbz）验「撤回时消息保留且出现提示」= 证明解析链完好；再叠 step2 NOP。
4. 文档已纠正（README / docs 不再宣称「4.x 只能静默」，且改准「删除在下游、非块内」）。

## 停止线
同一障碍试 ≥3 次无进展 → 停、记这里、回报，禁盲猜连环改字节。补丁致微信起不来 → 官网重装覆盖回滚。

## 验证（最终必须用户做）
退微信 → `swift build -c release` → `sudo .build/release/wechattweak patch`（keep-tip 变体）→ 重开 → 找人发消息再撤回 → 确认「消息还在 **且** 显示撤回提示」。无符号纯字节补丁，除实收撤回无别的地面真值。
