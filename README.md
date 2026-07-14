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
| **防撤回（留提示变体）** | 消息留着 **且** 仍显示「对方撤回了一条消息」提示 | ✓ | 🚧 开发中（逆向定位补丁点中） |
| **阻止自动更新** | 拦住自动升级，避免升级把补丁还原 | ✓ | — |
| **客户端多开** | 同时登录多个账号 | ✓ | —（4.x 无字节补丁，需复制 App） |

> **当前发布版在微信 4.x 上是「静默」防撤回**：撤回被拦在最上游的解析器，消息照常留着，但不弹「对方撤回了一条消息」提示——这是本 fork 目前已实现并可用的行为。
>
> **「留消息 + 仍显示撤回提示」在技术上可行，且已有人做到**（见 [issue #1038](https://github.com/sunnyyoung/WeChatTweak/issues/1038)，wuliyc 在 4.1.11 上实现了消息保留 + 撤回提示照常）。本 fork 正在逆向定位对应的补丁点（换一种做法：不拦解析、让撤回处理块照跑，只 NOP 掉其中「删本地消息」那一条调用）。**此变体尚未实现、未验证**，进度见下方[「留提示」变体的思路](#留提示变体的思路)。
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
sudo .build/release/wechattweak patch

# 6. 重新打开微信
```

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

## 「留提示」变体的思路

「消息保留 **且** 仍显示『对方撤回了一条消息』提示」**技术上可行、且已有人做到**：见 [issue #1038](https://github.com/sunnyyoung/WeChatTweak/issues/1038)，wuliyc 在 4.1.11（build 269136）上实现了消息保留 + 撤回提示照常。

本 fork 已对 269136 的 `wechat.dylib` 做了逆向，思路与当前静默补丁相反，分两步：

```
静默变体：cbz → b，跳过撤回 XML 解析 → 下游删除+提示都拿不到输入
留提示变体：① 恢复 cbz，让解析照跑（下游拿到 newmsgid + replacemsg）
            ② 到下游 NOP 掉「按 newmsgid 删本地消息」那一次调用，保留插提示
```

**关键（逆向已确认，修正早前判断）**：那条「删本地消息」的调用**不在** `TryParseMessageXML` 解析函数（入口 `0x48a0140`）内——解析函数只负责把 `newmsgid`/`replacemsg` 抽进结构体；真正的删除发生在**消费这个结构体的下游函数**里。删除调用的精确 VA 目前**静态逆向尚未定位**，需要 lldb 动态断点（收到真撤回时跟 `newmsgid` 的消费栈）或参考 wuliyc 的具体字节来确定。

> **状态：逆向进行中，尚未实现、尚未验证。** 已确认「补丁块 = XML 解析器、删除在下游」；下游删除调用的补丁点待定位。当前发布版仍只有静默变体。若要「留消息 + 有提示」，也可另做**注入式** tweak（dylib 注入 + hook / method swizzle），是独立于字节补丁的实现路径。

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
