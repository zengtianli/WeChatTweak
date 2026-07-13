# WeChatTweak

[![GitHub](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/zengtianli/WeChatTweak)
[![Upstream](https://img.shields.io/badge/Upstream-sunnyyoung-blue?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![License](https://img.shields.io/badge/License-AGPL--3.0-green)](LICENSE)

一个用于修改 macOS 微信客户端的命令行工具。

> **本 fork 的改动**：在 [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) 基础上，**新增微信 4.1.10（build 268880）的防撤回支持**。上游只覆盖到微信 3.8.x（消息逻辑还在主程序里）；微信 4.x 把撤回逻辑整体搬进了 `Contents/Resources/wechat.dylib`，本 fork 相应地支持按目标 dylib 打补丁，并加了写入前的原始字节校验（打错版本会直接报错，不会盲写把微信弄坏）。

## 功能

| 功能 | 说明 | 微信 3.8.x | 微信 4.x (268880 / 269136) |
| --- | --- | :---: | :---: |
| **防撤回（仅静默）** | 别人撤回的消息原样留在聊天里 | ✓ | ✓ |
| **阻止自动更新** | 拦住自动升级，避免升级把补丁还原 | ✓ | — |
| **客户端多开** | 同时登录多个账号 | ✓ | —（4.x 无字节补丁，需复制 App） |

> **微信 4.x 的防撤回只能是「静默」的**：撤回被拦住、消息照常留着，但**不会显示「对方撤回了一条消息」提示，也无法把这条消息高亮/标记**——被撤回的消息看起来和普通消息一模一样。想要「留消息 + 有提示/标记」需要注入式实现（见下方[为什么是「静默」](#为什么是静默而给不了撤回提示)），本 fork 的纯字节补丁做不到。
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

## 为什么是「静默」而给不了「撤回提示」

有人想要「消息保留 **且** 仍显示『对方撤回了一条消息』提示」，或者把被撤回的消息**高亮/标记**出来。这两个本 fork 都做不到，原因在机制：

被打补丁的那个函数（`cbz` 所在，4.1.11 为 `0x48a03b0`）是**消息 XML 解析器**。完整调用链是：

```
消息分发 → 解析器(补丁点) → 调用者 → 执行器(把撤回字段拷进消息对象) → 更下游 删原消息 + 插「撤回了一条消息」提示
```

补丁把 `cbz` 改成 `b`，是在**最上游的解析器**里让客户端「当没看见这条撤回」——撤回字段根本没被解析，下游那条「删除 + 提示」的流水线整条不触发。所以消息留下、且既不删也不弹提示，**天然就是静默的**；提示不是被「关掉」，而是压根没被触发。也正因为代码没走到任何「这是一条撤回」的判断点，**没有地方能挂高亮**。

两点硬限制：

- **高亮/自定义标记做不到**：字节补丁只能翻转/抹掉已有分支，不能**新增**「把这条消息染色」的渲染代码——那段代码二进制里不存在。加标记必须**注入代码**（dylib 注入 + hook / method swizzle），本工具是纯字节补丁、无注入能力。
- **「留消息 + 保留原生撤回提示」理论上是字节补丁可及**（换补丁点：不拦解析、只 NOP 掉下游的「删消息」调用），但下游删除是**数据驱动的流水线**、不是一个能一刀切的分支，且符号被剥离、**必须真收到一条撤回才能验证**，风险和工作量都远大于本补丁点，暂未纳入。

想要「留消息 + 有提示/标记」，正解是另做一个**注入式** tweak，而不是在这个字节补丁工具里凑。

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
