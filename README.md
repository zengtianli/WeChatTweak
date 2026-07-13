# WeChatTweak

[![GitHub](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/zengtianli/WeChatTweak)
[![Upstream](https://img.shields.io/badge/Upstream-sunnyyoung-blue?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![License](https://img.shields.io/badge/License-AGPL--3.0-green)](LICENSE)

一个用于修改 macOS 微信客户端的命令行工具。

> **本 fork 的改动**：在 [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) 基础上，**新增微信 4.1.10（build 268880）的防撤回支持**。上游只覆盖到微信 3.8.x（消息逻辑还在主程序里）；微信 4.x 把撤回逻辑整体搬进了 `Contents/Resources/wechat.dylib`，本 fork 相应地支持按目标 dylib 打补丁，并加了写入前的原始字节校验（打错版本会直接报错，不会盲写把微信弄坏）。

## 功能

| 功能 | 说明 | 微信 3.8.x | 微信 4.1.10 (268880) |
| --- | --- | :---: | :---: |
| **防撤回** | 别人撤回的消息原样留在聊天里，且不显示「对方撤回了一条消息」提示 | ✓ | ✓ |
| **阻止自动更新** | 拦住自动升级，避免升级把补丁还原 | ✓ | — |
| **客户端多开** | 同时登录多个账号 | ✓ | —（4.x 无字节补丁，需复制 App） |

> 微信 4.x 目前只做了**防撤回**。多开在 4.x 上没有可打补丁的开关（只能整包复制 App），阻止更新的补丁点尚未纳入本 fork。

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

有人想要「消息保留 **且** 仍显示『对方撤回了一条消息』」。这个补丁做不到，原因在机制：

被打补丁的那个函数（`0x…03b0` 处 `cbz` 所在）是**消息 XML 解析器**——它把服务器推来的 `revokemsg` 内容解析进消息结构体，`revoked` / `chat_id` / `createtime` 等字段都在这里落。真正「删本地消息 + 插撤回提示」的动作在**下游另一个消费这个结构体的函数**里。补丁把 `cbz` 改成 `b`，等于让解析器**跳过撤回字段的解析**，下游拿不到撤回内容 → 既不删消息、也不插提示，于是天然是静默的。

要「保留消息 + 保留提示」，得改的不是这里，而是下游那个执行函数——只 NOP 掉它的「删消息」调用、保留它的「插提示」调用。那个函数目前未定位、符号被剥离、且**必须真收到一条撤回才能验证**，风险和工作量都远大于本补丁点。本工具是等长字节补丁、无代码注入，不覆盖这一层；带提示的防撤回通常需要注入 dylib / method swizzle 另做。

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
