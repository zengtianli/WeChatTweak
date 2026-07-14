# WeChatTweak

[![GitHub](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/zengtianli/WeChatTweak)
[![Upstream](https://img.shields.io/badge/Upstream-sunnyyoung-blue?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![License](https://img.shields.io/badge/License-AGPL--3.0-green)](LICENSE)

一个用于修改 macOS 微信客户端的命令行工具。

> **本 fork 的改动**：在 [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) 基础上，**新增微信 4.1.10（build 268880）的防撤回支持**。上游只覆盖到微信 3.8.x（消息逻辑还在主程序里）；微信 4.x 把撤回逻辑整体搬进了 `Contents/Resources/wechat.dylib`，本 fork 相应地支持按目标 dylib 打补丁，并加了写入前的原始字节校验（打错版本会直接报错，不会盲写把微信弄坏）。

## 功能

| 功能 | 说明 | 微信 3.8.x | 微信 4.x (268880 / 269136) |
| --- | --- | :---: | :---: |
| **防撤回（静默变体）** | 别人撤回的消息原样留在聊天里，不弹提示 | ✓ | ✓（当前发布版） |
| **防撤回（留提示变体）** | 消息留着 **且** 仍显示「对方撤回了一条消息」提示 | ✓ | ⚠️（`--variant keeptip`：**私聊**有提示；**群聊**仍静默无提示） |
| **阻止自动更新** | 拦住自动升级，避免升级把补丁还原 | ✓ | — |
| **客户端多开** | 同时登录多个账号 | ✓ | —（4.x 无字节补丁，需复制 App） |

> **微信 4.x 上有两种防撤回变体，打补丁时用 `--variant` 选**：
> - **`--variant silent`（默认）**：撤回被拦在最上游的解析器，消息留着，但不弹「对方撤回了一条消息」提示。
> - **`--variant keeptip`**：消息留着 **且** 仍显示撤回提示。做法与静默相反——让解析器照跑（提示才会渲染），只把「要删哪条」的 `newmsgid` 在写入结构体那一刻改写为 0，于是下游按 `newmsgid` 删本地消息时找不到目标、删不掉，消息保留而提示照常。这条思路（改 `str x0`→`str xzr`）来自参考实现 [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall) 的 `revoke-tip` 模式。
>
> `keeptip` 变体在 **build 269136（4.1.11）实机实测**：**私聊**撤回后消息保留且显示提示；**群聊**撤回消息虽保留、但仍无提示（表现同静默变体）。根本矛盾：`newmsgid` 同时控制「删哪条消息」和「群聊提示插到哪条下面」——清零它虽保住了消息，却也让群聊提示的原生插入不再触发（私聊提示不依赖 newmsgid，故照出）。群聊要出提示，必须保留真 newmsgid、转而在下游掐掉那次删除调用；该删除调用经虚派发分发、静态定位不到，需动态（lldb）定位，属独立工程（见[「留提示」变体](#留提示变体--variant-keeptip)末尾）。issue [#1038](https://github.com/sunnyyoung/WeChatTweak/issues/1038) 中 wuliyc 报告过在 4.1.11 上的同类效果（未说明群/私聊范围）。
>
> 微信 4.x 目前也只做了防撤回：多开只能整包复制 App，阻止更新的补丁点尚未纳入本 fork。

## 支持的版本

工具按 **构建号**（`CFBundleVersion`，即 `wechattweak versions` 打印的数字）匹配，不是营销版本号。

| 构建号 | 微信版本 | 防撤回 |
| --- | --- | :---: |
| 269136 | 4.1.11 | ✓ |
| 268880 | 4.1.10 | ✓ |
| 34371 / 32288 / 32281 / 31960 / 31927 | 3.8.x | ✓ |

先跑 `wechattweak versions` 看你的构建号在不在表里。不在 → 见下方[新增版本](#新增一个版本)。

## 安装 & 使用

### 微信 4.x（从源码构建 —— 上游 brew 包不含 4.x 支持）

```bash
# 1. 克隆本 fork
git clone https://github.com/zengtianli/WeChatTweak.git
cd WeChatTweak

# 2. 编译
swift build -c release

# 3. 退出微信（打补丁时微信在运行会触发签名失效崩溃）
pkill -x WeChat

# 4. 确认版本被支持
.build/release/wechattweak versions

# 5. 打补丁（微信在 /Applications 下、由 root 拥有，需 sudo）
sudo .build/release/wechattweak patch                    # 默认 = 静默变体（留消息、无提示）
# 或：留消息 + 仍显示撤回提示
sudo .build/release/wechattweak patch --variant keeptip

# 6. 重新打开微信
```

> **两个变体二选一，互斥**：`--variant silent`（默认）留消息不弹提示；`--variant keeptip` 留消息且保留「对方撤回了一条消息」提示。想在两者间切换，直接用另一个 `--variant` 重打即可（补丁带原始字节校验 + 幂等，重复打安全）。`keeptip` 仅对定义了 `revoke-keeptip` 补丁点的 4.x 构建号可用（当前 269136），其它版本用 `--variant keeptip` 会报错提示不可用。

打补丁会自动重签名（先单独签被改的 `wechat.dylib`，再 `--deep` 签整个 App），避免运行到被改代码时报 `Code Signature Invalid`。

### 微信 3.8.x（上游 Homebrew）

```bash
brew install sunnyyoung/tap/wechattweak
wechattweak patch
```

> ⚠️ **安装后请实测**：找个人给你发条消息再撤回，确认消息还在。防撤回是否真正生效，只有实际收撤回才能验证。
>
> **想还原**：从 [官网](https://mac.weixin.qq.com/) 重新下载安装微信覆盖即可。

## 原理

撤回不是本地行为——对方点撤回后，服务器给你的客户端推一条 `revokemsg` 指令，客户端的 `parseRevokeXML`（在 `wechat.dylib` 里）解析它，然后执行「删掉本地这条消息 + 插入撤回提示」。**消息本来已经在你本地了**，撤回是事后叫客户端去删它。

补丁改的是这个函数入口处的一条分支指令：

```
488319c: bl   0x4431b58      ; 判断这是不是要执行的撤回，结果放 w0
48831a0: cbz  w0, 0x488339c   ; w0==0 才跳过删除；正常 w0≠0 → 往下执行删消息
```

把 `cbz w0, X`（`E00F0034`，条件跳转）改成 `b X`（`7F000014`，无条件跳转），跳转目标不变，于是**无论如何都跳过删除逻辑**。撤回指令照收照解析，但真正删消息的代码永远走不到——消息就跟没被撤过一样。

`cbz` 和 `b` 都是 4 字节定长指令、目标偏移相同，所以这是一次**原地等长替换**，只翻 4 个字节，不改动二进制布局。因为没有新增「显示提示」的代码、只是删掉了删除动作，所以是**静默**防撤回：消息留下、且什么提示都不弹。

补丁点通过 `parseRevokeXML` 的几何特征在整个 arm64 切片里唯一定位（入口 `stp` 序言 + `entry+0x270` 的 `cbz w0` + `entry+0xA04` 的 `str x0,[x19,#0x168]`），并经反汇编与原始字节逐一核对。逆向方法参考了 [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall)。

## 为什么当前发布版是「静默」的

`0x48a03b0` 的 `cbz` 守着撤回消息的 **XML 解析分支**——经逆向确认，补丁点所在函数是 `MessageSystemExtInfo::TryParseMessageXML`，`cbz` 处判断「这条 msgType 是不是 `revokemsg`」。当前补丁把 `cbz` 改成 `b`，等于让解析器**直接跳过整个 revokemsg 分支**：撤回 XML 里的 `newmsgid`（要删哪条本地消息）、`replacemsg`（撤回提示文本）根本没被解析出来。

下游真正「按 `newmsgid` 删本地消息」和「用 `replacemsg` 插撤回提示」的代码因此都拿不到输入，两件事一起不发生。所以消息留下、且不弹提示，**是跳过解析的连带结果**：提示不是被单独「关掉」，而是它的输入在最上游就被截断了。

换句话说，静默只是**当前这个补丁点**的取舍，不是机制上限——保留解析、只在下游掐掉删除动作，就能留消息又保提示（见下节）。

## 「留提示」变体（`--variant keeptip`）

用 `sudo .build/release/wechattweak patch --variant keeptip` 打这个变体：**消息保留、且仍显示「对方撤回了一条消息」提示**。

思路与静默补丁相反——不拦解析，而是**让 newmsgid 失效**。撤回 XML 里的 `newmsgid` 决定「删本地哪条消息」，`replacemsg` 是提示文本。解析器 `TryParseMessageXML`（入口 `0x48a0140`）在 `0x48a0b44` 处把解析出的 `newmsgid` 存进结构体：

```
0x48a0b44: str  x0,  [x19, #0x168]   ; 60B600F9  把 newmsgid 存进结构体（要删的目标）
```

留提示变体对 269136 做两处等长字节改动：

| 补丁点 | 原字节 → 新字节 | 效果 |
|---|---|---|
| `0x48a03b0`（`cbz w0`） | `E00F0034` → `E00F0034`（恢复，兼容已打静默补丁的机器 `7F000014`） | 解析照跑，提示得以渲染 |
| `0x48a0b44`（`str x0,[x19,#0x168]`） | `60B600F9` → `7FB600F9`（`str xzr`） | 存进的 `newmsgid` = **0**，下游按 id=0 删本地消息时找不到目标 → 删不掉，消息保留 |

于是解析产生的撤回提示照常插入，而删除动作因为 `newmsgid` 被清零而落空。这条 `str x0`→`str xzr` 的做法来自参考实现 [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall) 的 `revoke-tip` 模式（该项目另有 `--runtime-tip` 用运行时注入自定义提示文案，本 fork 未纳入，只做纯字节补丁的默认提示）。

> **修正早前判断**：更早的逆向记录一度以为「留提示 = 定位并 NOP 掉下游那条删本地消息的调用」，并因该调用位于虚派发/chained-fixup 之外的接收侧、静态难以定位而搁置。这是**方向错了**——正确做法不需要找到那条删除调用，只要在 `newmsgid` 存入结构体的源头把它清零，删除自然落空。参考 fzlzjerry 的 `revoke-tip` 才对上。
>
> **状态**：字节补丁已实现，build 269136（4.1.11）实机实测——**私聊**消息保留且有提示；**群聊**消息保留但无提示（同静默）。（静态复核：打补丁后 `0x48a03b0` = `cbz w0`、`0x48a0b44` = `str xzr`，与 fzlzjerry `revoke-tip` 对 269110 的补丁逐字节同构。）
>
> **群聊为什么没提示**：整个 revoke 模块（`0x48a0140..0x48ad700`）里写 newmsgid 字段 `[x19,#0x168]` 的只有 `0x48a0b44` 一处，私聊群聊共用它。私聊的提示插入不依赖 newmsgid、照出；群聊的提示渲染依赖 newmsgid（决定挂在哪条下面），被我们清零后连带失效 → 群聊静默。这个下游消费者经虚派发/chained-fixup 分发，纯字节补丁静态定位不到独立的「群聊提示」点。
>
> **注意：运行时注入（fzlzjerry `--runtime-tip`）也解决不了群聊。** 读其 `Runtime.mm` 源码确认：它的 hook 只在解析后**改写 replaceMsg 提示文本**、仍把 newmsgid 清零，靠微信**原生**代码插入提示——全程无任何独立插入调用（零 objc_msgSend/selector）。它落在和本字节补丁相同的 newmsgid=0 状态，群聊原生插入同样不触发。**真正的解法**是保留真 newmsgid（让原生提示对群/私都插入并锚定），转而在下游 NOP 掉那次删除调用；该删除调用经虚派发分发、静态定位不到，需 lldb 动态定位（触发一次真群聊撤回、断在 WCDB 删除原语看 backtrace），属需实机配合的独立工程，本 fork 暂未纳入。

## 新增一个版本

微信一更新，构建号变、地址全变，需要重新定位补丁点：

1. 从目标微信取 `Contents/Resources/wechat.dylib`，`lipo -thin arm64` 抽出 arm64 切片。
2. 按上面的几何特征搜 `parseRevokeXML` 入口 `E`（三条 `stp` 序言，且 `E+0x270` 是 `E00F0034`、`E+0xA04` 是 `60B600F9`），确认唯一命中。
3. 防撤回补丁点 = `E + 0x270`，原字节 `E00F0034` → 写 `7F000014`。
4. 把 `{ version, targets:[{ identifier:"revoke", binary:"Contents/Resources/wechat.dylib", entries:[{arch,addr,expected,asm}] }] }` 加进 `config.json`。
5. `swift build -c release`，`wechattweak versions` 确认，打补丁后实测撤回。

## 参考

- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)（上游作者）
- [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall)（微信 4.x 防撤回逆向方法参考）
- 上游项目：[sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)

## License

[AGPL-3.0](LICENSE)（沿用上游）。
