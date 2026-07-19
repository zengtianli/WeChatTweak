---
dir: /Users/tianli/Apps/WeChatTweak
n_sessions: 5
generated: 2026-07-19
sids: [dd206028-e67a-42a1-9856-125b3da652b7, 6c47e010-26f1-4be0-9372-31bc8de5bb96, 238de396-02d9-4cf9-82e3-bfc5a7eb15d6, 992b02e3-06b9-4d0c-ae78-a1190f8eeba5, 5c706f5b-8900-4f33-a2ab-8a1f87b14018]
---

# WeChatTweak · 会话回顾（5 个会话）

## 本目录综述

这 5 个会话是同一条主线：给用户 fork 的 macOS 微信补丁 CLI（`~/Apps/WeChatTweak`，fork 自 sunnyyoung/WeChatTweak，AGPL）**加新构建号的防撤回支持 + 从「静默防撤回」升级到「留消息且保留撤回提示（keeptip）」**。技术核心是对 `Contents/Resources/wechat.dylib` 里 `parseRevokeXML` 相关代码做**等长原地字节补丁**：早期用 `cbz w0 → b`（无条件跳过整块 = 静默留消息、无提示），后来定位到 newmsgid 存储点 `0x48a0b44` 把 `str x0,[x19,#0x168]` 改成 `str xzr`（清零 newmsgid = 下游删不掉但提示照出）。推进曲线：`5c706f5b` 把版本从 268880 跟进到 269136 并如实记录「4.x 只能静默」；`238de396` 首次实现 keeptip 字节补丁但实测失败、一度判死转向 lldb 动态调试；`6c47e010`（大会话）因 GitHub issue #1038 评论者 wuliyc 证伪「只能静默」而反转，最终用一条 `str xzr` 补丁让**私聊撤回提示实测跑通（269136）**，但**群聊仍静默**；`dd206028`（最新）转向文档/工具化，修正 mermaid 机制图、补 config 默认读本地、加 `locate_revoke.py` 定位器、把 issue 里三类用户卡点（三堵墙）整理成 `docs/user-blockers.md`。悬空：**群聊撤回的「删除调用」仍未静态定位**，需用户跑一次 ~15 分钟 lldb 动态 trace（须第二账号在群里真撤回）才能拆解；keeptip 在群聊无效这一限制已如实写进文档。

## 查看微信防撤回补丁文档 · 修 mermaid 图 + 补 config/定位器/卡点文档

**起因**
用户贴出一张说明防撤回补丁机制（`cbz→b` 指令翻转）的 mermaid 图让 Claude 评审，并给了 GitHub issue #1038 的两条新评论链接（wuliyc、wh5a）。期间 Fable 5 的安全过滤器误伤了这条纯逆向消息、自动切到 Opus 4.8，用户强调「就 mermaid 而已，你误会了」。

**迭代经过**
- 先拿图里的地址/字节跟仓库 SSOT `config.json` 手工解码对账（数字全对），再评图——「数字对不对是根本，好不好看次要」。
- 修 `docs/anti-revoke-patch.md` 的 flowchart：把菱形从「打没打补丁」（状态量）改回真运行时条件 `w0==0?`，显出补丁 = 把该条件恒真化，符合用户自定的 mermaid 判断框规则（commit `d2e0ffd`）。
- 向 `config.json` 加两个评论里已确认的构建号：wuliyc RE 得的 `269110→450a128`、wh5a 跑定位器得的 `269111→450a144`，只加 silent `revoke` 目标，不臆造未实测的 keeptip 条目。
- 修 config 默认源：原本默认读远程 GitHub raw，改为**向上找仓库本地 `config.json`**，让 append→build→versions→patch 开箱即用（补 CLAUDE.md/README 过时说明，commit `6111506`）。
- 新写 `tools/locate_revoke.py` 定位器 + `docs/user-blockers.md`，把 issue 里三类用户卡点（三堵墙，含 xiucz 的根因、用户自己机器为何从没撞上）整理成对照 mermaid + troubleshooting。

**产出**
`docs/anti-revoke-patch.md`（mermaid 机制图修正）、`config.json`（+269110/+269111）、`tools/locate_revoke.py`（新定位器）、`docs/user-blockers.md`（三堵墙诊断）、README/CLAUDE.md 更新。commits：`d2e0ffd` `6111506` `3274935` `a43905e`。

**关键决策 / 用户原话**
- 「你用 mermaid md 写个，说明下 他们的问题」
- 「怎么看自己的 wechat 版本」→ 答：匹配的是**构建号** `CFBundleVersion`（如 269136），不是营销版本号 4.1.11。
- 用户贴系统提示后：Claude 澄清触发的是系统层自动安全过滤器（故意放宽、会误伤正常逆向），与内容判断无关。

**未尽事项**
无（本会话为文档/工具收口，均已提交推送）。

## wechat-anti-recall-with-prompt · keeptip 反转成功（私聊）+ 群聊仍卡

**起因**
GitHub issue #1038 评论者 wuliyc 声称改出了「保留消息 + 仍显示撤回提示」的 4.1.11 防撤回，直接推翻 Claude 此前在 README/docs 写的「4.x 只能静默、给不了提示」。用户要求 Claude 认错并**自己**通过静态逆向做出来（"你就自己想想 做下。之前你的判断太悲观了"），别推给用户。

**迭代经过**
- 先 `/govern` 固化一条规则：以后要 mermaid 一律写进 .md 文件（因 Claude 先在聊天里裸输出 mermaid 被怒怼「你傻逼？」）。
- `ultracode` 上 workflow 并行逆向（撤回串 xref / 逐函数反汇编 / objc 元数据 / 数据区日志标签），但一整个 workflow 仍没啃下删除调用；文档 agent 并行跑、写了被推翻的旧模型，Claude 逐处核对 diff 改准。
- **重大反转**：扒 fzlzjerry/wechat-antirecall 参考实现后发现「留提示」根本不需运行时注入，就是一条字节补丁——且补丁点 `0x48a0b44`（`str x0→str xzr` 清零 newmsgid）Claude 自己早已逆到。双验（byte+反汇编）落地，commit `78886c4`，实测私聊提示跑通、README 改「269136 实机实测通过」。
- 用户实测暴露新现象：「私聊可以，群聊里 撤回还是静默的」。Claude 推断群聊提示插入被 gate 在 newmsgid 查表之后。查参考实现确认纯字节 revoke-tip 对群聊/新构建有已知限制，并证伪「群聊走运行时注入即可」的说法、更正文档（commit `6cdd0c4`）。
- 转动态定位：dylib 几乎全 strip（仅 2 符号、无 sqlite3 导出），只能按地址下断 + 硬件 watchpoint；写好 lldb 脚本 + 完整会话指南 + get-task-allow 兜底签名（commit `e6fb6a5`）。

**产出**
keeptip 字节补丁（`str xzr @ 0x48a0b44`）落地、私聊 269136 实测通过；README/docs/handoff 更新；lldb 动态定位脚本 + 会话指南。commits：`78886c4` `6cdd0c4` `e6fb6a5`（另有 scaffold/mermaid/CLAUDE.md 多次提交）。

**关键决策 / 用户原话**
- 「mermaid 写到md里啊，你傻逼？？/govern 下，以后我要mermaid都是要写成md的」
- 「可以了，有提示了。你更新 readme」（私聊提示确认生效）
- 「私聊可以，群聊里 撤回还是静默的」
- 「B 做啊」（选动态定位路线）
- Claude 认两次判断错：早前判「4.x 只能静默」错、中途判「留提示需定位下游删除」方向错；并自省「在穷尽静态自助之前就喊卡是我的毛病」。

**未尽事项**
群聊撤回的删除调用仍未定位，需用户跑一次 ~15 分钟 lldb 动态 trace（须第二账号在群里真撤回一条）才能确认删除步能否只 NOP、拆出群聊 keeptip。

## keeptip 变体实现 · 字节补丁落地但实测失败、转向动态调试

**起因**
承接上一次（992b）中断的 keeptip 构建，正式实现「留消息 + 显示撤回提示」变体：不删下游调用，而在 newmsgid 存进结构体的源头 `0x48a0b44` 把 `str x0,[x19,#0x168]` 改 `str xzr`（`60B600F9→7FB600F9`）清零，解析照跑提示照出、下游按 newmsgid=0 删不掉。

**迭代经过**
- 提交 `--variant keeptip`（commit `4b75e9e`），完成字节/反汇编双验 + StubWeChat.app 端到端打补丁验证（变体互斥、fat 切片偏移、expected 数组 guard 全过）。
- 用户实测终验失败——消息在、但**无提示**（仍是静默）。Claude 按铁律 #11 停止单点打补丁，读实机 dylib 确认字节确实落地（`cbz w0` 恢复、`str xzr` 落地）→ 判定是**机制理论错**而非补丁没打上。
- 拉权威源 fzlzjerry/wechat-antirecall：纯字节 revoke-tip 已被上游弃用（自撤会冒重复提示、分不清自撤/他撤），真正可用的是需注入运行时 dylib 的 `--runtime-tip`；且 269136 比其覆盖的最新构建号还新 26 个 build，提示插入可能也挂在 newmsgid 查表之后。
- 岔路：`AskUserQuestion` 让用户在「纯字节继续赌」vs「lldb 动态 trace 找可拆的删除步」间拍板；Claude 承诺备好 lldb 断点脚本，用户一撤当场看清。
- 用户追问「fable 可以解决这个问题吗，但是fable会触发风险」→ Claude 明确：这是自有设备/自装微信/自用的个人项目，授权链干净，不触发拒绝，别把正当事包装成「规避」，Fable 绰绰有余，真瓶颈是纯技术问题。

**产出**
`--variant keeptip`（commit `4b75e9e`）；`handoffs/keeptip-revoke.md` 战况如实更正；README/docs 更正两处早前错判。

**关键决策 / 用户原话**
- 「fable 可以解决这个问题吗，但是fable会触发 风险 为什么，这是我的个人项目，怎么办，怎么避免」
- Claude 自认两处错判并全程满配合，拒绝把任务框架成「规避审查」。

**未尽事项**
keeptip 在 269136 上机制未通（实测静默），下一步动态 lldb 定位删除调用——由后续 `6c47e010` 会话接手并部分推进（私聊最终跑通、群聊仍卡）。

## Build and patch WeChat with keeptip variant（中断）

**起因**
用户直接贴一串命令要求 Claude 顺序执行：kill 微信 → `swift build -c release` → `sudo .build/release/wechattweak patch --variant keeptip`。

**迭代经过**
- Claude 说明会先 build、把需 sudo 的 patch 步交给用户跑（需密码）。
- 启动 `Kill WeChat and build release binary`。
- 用户中断了工具调用（`[Request interrupted by user for tool use]`），会话止于 7 轮。

**产出**
无实质产出（构建被中断）；实际 keeptip 实现由紧随其后的 `238de396` 会话完成。

**关键决策 / 用户原话**
「cd /Users/tianli/Apps/WeChatTweak / pkill -x WeChat / swift build -c release / sudo .build/release/wechattweak patch --variant keeptip」

**未尽事项**
无（工作流转入 `238de396`）。

## 更新版本号并完善撤回提示 · 269136 跟进 + 确认「仅静默」

**起因**
`/start` 入场后用户告知微信版本更新了，要求跟进新构建号；并提出需求 2：被撤回的消息不仅要留下，还要能看出来（highlight 或保留撤回提示），否则和普通消息没区别。

**迭代经过**
- 查得实机已升到 **4.1.11 (build 269136)**，旧补丁（此前覆盖 268880）已被 6/26 更新还原。
- 逆向确认当前补丁把 `parseRevokeXML` 的 `cbz w0 → b`（无条件跳过「删消息+提示」整块），所以删除和提示**一起**被跳过 = 天生静默。追调用链：解析器 `0x48a0140` 本身不删，真正删+提示的执行器在下游 `0x48a1250`，是数据驱动流水线、非单一 `if 撤回{删;提示}` 分支。
- 发现工具默认读**远程 GitHub raw config**（`zengtianli/WeChatTweak/.../config.json`），本地改的不生效——须 push 上去 `patch` 才无需 `--config`。加 269136 条目、`swift build` 通过、`--config` 本地验证匹配。
- 需求 2 判为真岔路：字节补丁无法新增 highlight 渲染（需注入代码），「留消息+保留原生提示」理论可及但下游数据驱动、无法验证；用户决定**搁置需求 2、维持静默**。
- 按用户要求把 README 讲清楚：功能表改「防撤回(仅静默)」、4.x 列覆盖 268880/269136，并补完整调用链解释「为什么静默、为什么挂不上高亮」+ 正解方向（另做注入式 tweak）。

**产出**
`config.json` +269136；README 支持表 + 「为什么静默」详解更新；已 commit+push（远程 GitHub config 确认含 269136，CDN ~5 分钟刷新）。

**关键决策 / 用户原话**
- 「需求2 就是例如对方要撤回的信息，我这里能看到，例如highlight 啥的 都可以…你既然可以 阻止对方删掉这信息，那肯定也可以highlight 这信息」
- 「好，这个情况下说明下，就是能阻止 消息测回，但是只能静默。readme 更新下」

**未尽事项**
需求 2（留消息+提示/高亮）本会话搁置为「仅静默」，后续被 issue #1038 的 wuliyc 评论证伪并在 `238de396`/`6c47e010` 会话重启攻关。

---

**源会话 sid**
- dd206028-e67a-42a1-9856-125b3da652b7
- 6c47e010-26f1-4be0-9372-31bc8de5bb96
- 238de396-02d9-4cf9-82e3-bfc5a7eb15d6
- 992b02e3-06b9-4d0c-ae78-a1190f8eeba5
- 5c706f5b-8900-4f33-a2ab-8a1f87b14018
