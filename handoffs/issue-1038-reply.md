# issue #1038 回复草稿 — `--variant keeptip` 在 269110/269111 报不可用

> 状态：草稿，**未发布**。发之前自己再读一遍，确认 fork 里 `b32f482` 已推上去（已推）。
> 前身 `wuliyc-reply-draft.md`（向 wuliyc 索取改法）已作废——那些信息后来自己逆出来了，见 `docs/anti-revoke-patch.md`。

---

## 回复正文（可直接贴）

报错 `The keeptip variant is not available for WeChat build 269111` 不是你的版本做不了，是我 `config.json` 里那条数据缺了一半，已修（`b32f482`）。

**原因**：`keeptip` 需要两个补丁点，而 269110/269111 的条目当时是从本 issue 的评论里手工收录的，评论只报了静默那一个地址：

| 变体 | 补丁点 | 原字节 → 写入 |
|---|---|---|
| `silent` | `E+0x270` | `E00F0034` (`cbz w0`) → `7F000014` (`b`) |
| `keeptip` | `E+0x270` | `E00F0034` 或 `7F000014` → `E00F0034`（还原 `cbz`，让解析照跑、提示才会渲染） |
| `keeptip` | `E+0xA04` | `60B600F9` (`str x0,[x19,#0x168]`) → `7FB600F9` (`str xzr`)，把 `newmsgid` 清零 |

`E` = `parseRevokeXML` 入口。**两个补丁点的距离 `0x794` 跨构建号恒定**，而 `tools/locate_revoke.py` 的定位签名本来就同时要求这两处特征成立——也就是说它扫出静默点时，keeptip 点已经确定了，只是之前脚本没把它打印出来。现在一次输出两个 target：

```bash
python3 tools/locate_revoke.py            # 只打印，可直接粘进 config.json
python3 tools/locate_revoke.py --append   # 直接追加进本仓库 config.json
swift build -c release
sudo .build/release/wechattweak patch --variant keeptip
```

**两点需要说清楚**：

1. 269136 是我本机实测过的；**269110/269111 的 keeptip 地址是按 `+0x794` 推导的，我手上没有这两个版本的 dylib，没能实机验证**。打补丁前有原始字节校验，地址不对会直接报 `expectedMismatch` 拒绝写入，不会把微信弄坏。你打成功或打失败都麻烦回一句，我好把它转成实测确认。
2. `keeptip` 在 269136 上的实测结论：**私聊撤回有提示，群聊撤回仍然静默（消息在、无提示）**。因为 `newmsgid` 同时决定「删哪条消息」和「群聊提示插到哪条下面」，清零它保住了消息也掐掉了群聊提示。群聊要出提示得保留真 `newmsgid`、改为掐掉下游那次删除调用，那条调用走虚派发、静态定位不到，需要 lldb 动态跟，属独立工程，还没做。

fork：https://github.com/zengtianli/WeChatTweak

---

## 未尽事项

- 等 269110/269111 用户回报实测结果 → 把 README 里「推导未验证」改成实测结论。
- 群聊 keeptip 仍卡在下游删除调用的动态定位（见 `handoffs/group-delete-hunt.md`）。
