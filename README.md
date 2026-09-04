# WeChatTweak

[![GitHub](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/zengtianli/WeChatTweak)
[![Upstream](https://img.shields.io/badge/Upstream-sunnyyoung-blue?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![License](https://img.shields.io/badge/License-AGPL--3.0-green)](LICENSE)

一个用于修改 macOS 微信客户端的命令行工具。

> **本 fork 的改动**：在 [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) 基础上，**新增微信 4.1.10（build 268880）的防撤回支持**。上游只覆盖到微信 3.8.x（消息逻辑还在主程序里）；微信 4.x 把撤回逻辑整体搬进了 `Contents/Resources/wechat.dylib`，本 fork 相应地支持按目标 dylib 打补丁，并加了写入前的原始字节校验（打错版本会直接报错，不会盲写把微信弄坏）。

## 功能

| 功能 | 说明 | 微信 3.8.x | 微信 4.x (268880 → 269627) |
| --- | --- | :---: | :---: |
| **防撤回（静默变体）** | 别人撤回的消息原样留在聊天里，不弹提示 | ✓ | ✓（当前发布版） |
| **防撤回（留提示变体）** | 消息留着 **且** 仍显示「对方撤回了一条消息」提示 | ✓ | ⚠️（`--variant keeptip`：**私聊**有提示；**群聊**仍静默无提示） |
| **阻止自动更新** | 拦住自动升级，避免升级把补丁还原（微信更新是整包替换，四次把补丁静默抹掉；`defaults write` 关不掉） | ✓ | ✓（`patch` 默认同时打；`--no-block-update` 关） |
| **客户端多开** | 同时登录多个账号 | ✓ | —（4.x 无字节补丁，需复制 App） |

> **微信 4.x 上有两种防撤回变体，打补丁时用 `--variant` 选**：
> - **`--variant silent`（默认）**：撤回被拦在最上游的解析器，消息留着，但不弹「对方撤回了一条消息」提示。
> - **`--variant keeptip`**：消息留着 **且** 仍显示撤回提示。做法与静默相反——让解析器照跑（提示才会渲染），只把「要删哪条」的 `newmsgid` 在写入结构体那一刻改写为 0，于是下游按 `newmsgid` 删本地消息时找不到目标、删不掉，消息保留而提示照常。这条思路（改 `str x0`→`str xzr`）来自参考实现 [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall) 的 `revoke-tip` 模式。
>
> `keeptip` 变体在 **build 269136（4.1.11）实机实测**：**私聊**撤回后消息保留且显示提示；**群聊**撤回消息虽保留、但仍无提示（表现同静默变体）。根本矛盾：`newmsgid` 同时控制「删哪条消息」和「群聊提示插到哪条下面」——清零它虽保住了消息，却也让群聊提示的原生插入不再触发（私聊提示不依赖 newmsgid，故照出）。群聊要出提示，必须保留真 newmsgid、转而在下游掐掉那次删除调用；该删除调用经虚派发分发、静态定位不到，需动态（lldb）定位，属独立工程（见[「留提示」变体](#留提示变体--variant-keeptip)末尾）。issue [#1038](https://github.com/sunnyyoung/WeChatTweak/issues/1038) 中 wuliyc 报告过在 4.1.11 上的同类效果（未说明群/私聊范围）。
>
> 微信 4.x 的多开仍只能整包复制 App。

## 支持的版本

工具按 **构建号**（`CFBundleVersion`，即 `wechattweak versions` 打印的数字）匹配，不是营销版本号。

| 构建号 | 微信版本 | 防撤回 | 阻止自动更新 |
| --- | --- | :---: | :---: |
| 269627 | 4.1.13 | ✓（本机已打，补丁点由 `tools/locate_revoke.py` 定位） | ✓（`tools/locate_update.py` 定位，8 处） |
| 269626 | 4.1.13 | ✓（本机实测） | —（该构建已被 269627 替代，未收录） |
| 269579 | 4.1.13 | ✓ | ✓ |
| 269136 | 4.1.11 | ✓（本机实测） | ✓ |
| 268575 ~ 269624 另 25 个构建号 | 4.1.10 ~ 4.1.13 | ✓（`tools/sync_ref.py` 自 fzlzjerry/wechat-antirecall 同步，打补丁时仍过 `expected` 字节门） | ✓（同上同步） |
| 268880 | 4.1.10 | ✓ | —（打补丁时 CLI 会现场按方法名定位，找不到才报错） |
| 34371 / 32288 / 32281 / 31960 / 31927 | 3.8.x | ✓ | ✓（上游原有） |

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

# 4. 体检（只读）：构建号是否支持、SIP 开关、签名/entitlements 是否完好、要不要 sudo、各补丁点状态，
#    最后一行直接给出这台机器该跑的命令
.build/release/wechattweak doctor

# 5. 打补丁。先不加 sudo：微信 4.1.13 起由 Sparkle 以当前用户身份更新，/Applications/WeChat.app 归你所有；
#    报 permission denied（老版本或用 root 装的包）再前面加 sudo。
#    默认同时打「阻止自动更新」（不打的话微信下次更新会把补丁连包换掉）；确要保留更新加 --no-block-update
.build/release/wechattweak patch                    # 默认 = 静默变体（留消息、无提示）
# 或：留消息 + 仍显示撤回提示
.build/release/wechattweak patch --variant keeptip

# 6. 重新打开微信；再跑一次 doctor 应看到 ✅
```

> **SIP 开着和关着，操作命令一样，差别在「怎么判断打好了」**（`doctor` 会按 `csrutil status` 分别给结论）：
> - **SIP 开启**（绝大多数 Mac）：系统强制校验 entitlements。包一旦被抹掉 entitlements（2026-09-02 前的本工具会这样），微信启动即被杀。`doctor` 的 `Entitlements` 行必须是 `app-sandbox ✓, application-identifier ✓`；显示 `NONE` 就只能重装微信再打。打补丁必须用本工具默认的保留-entitlements 重签名，别手动 `codesign --remove-sign` / 裸 `--deep --sign -`。
> - **SIP 关闭**：坏包也照样能开，所以「微信打得开」不构成任何证据，同样只看 `Entitlements` 行；给别人（SIP 开的机器）出主意前先在原厂 dmg 副本上验。

> **两个变体二选一，互斥**：`--variant silent`（默认）留消息不弹提示；`--variant keeptip` 留消息且保留「对方撤回了一条消息」提示。想在两者间切换，直接用另一个 `--variant` 重打即可（补丁带原始字节校验 + 幂等，重复打安全）。`keeptip` 需要一个 `revoke-keeptip` 补丁点。已收录：269136（实机实测）、269579/269626（4.1.13，keeptip 点由同代签名 `+0x7a0` 定位）、269110/269111（由几何关系 `+0x794` 推导，**未经实机验证**）。**没收录的 4.x 构建号不用等我加**，两条路二选一：

```bash
# 路 1：让工具自己扫签名算出补丁点（不改 config.json）
.build/release/wechattweak patch --variant keeptip --auto-locate

# 路 2：先把补丁点固化进 config.json，再正常打
python3 tools/locate_revoke.py --append && swift build -c release
```

两条路都过写入前的原始字节校验：地址不对直接报 `expectedMismatch` 拒写，不会弄坏微信。

打补丁会自动重签名：先单独签被改的 `wechat.dylib`，再 `--deep` 签整个 App，并**逐组件保留原厂 entitlements**（微信是 App Sandbox + Hardened Runtime，沙盒/相机/麦克风/app-group 一项都不能丢）+ 注入两个 `com.apple.security.cs.*` 键让 ad-hoc 身份跑得起来；签完逐项比对，丢一项就报错。细节见 `Sources/WeChatTweak/Resigner.swift` 文件头。

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

补丁点通过 `parseRevokeXML` 的几何特征在整个 arm64 切片里唯一定位（入口 `stp` 序言 + `entry+0x270` 的 `cbz w0` + 固定距离外的 `str x0,[x19,#newmsgid]`；具体编码分「代」，见[新增一个版本](#新增一个版本)），并经反汇编与原始字节逐一核对。逆向方法参考了 [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall)。

## 为什么当前发布版是「静默」的

`0x48a03b0` 的 `cbz` 守着撤回消息的 **XML 解析分支**——经逆向确认，补丁点所在函数是 `MessageSystemExtInfo::TryParseMessageXML`，`cbz` 处判断「这条 msgType 是不是 `revokemsg`」。当前补丁把 `cbz` 改成 `b`，等于让解析器**直接跳过整个 revokemsg 分支**：撤回 XML 里的 `newmsgid`（要删哪条本地消息）、`replacemsg`（撤回提示文本）根本没被解析出来。

下游真正「按 `newmsgid` 删本地消息」和「用 `replacemsg` 插撤回提示」的代码因此都拿不到输入，两件事一起不发生。所以消息留下、且不弹提示，**是跳过解析的连带结果**：提示不是被单独「关掉」，而是它的输入在最上游就被截断了。

换句话说，静默只是**当前这个补丁点**的取舍，不是机制上限——保留解析、只在下游掐掉删除动作，就能留消息又保提示（见下节）。

## 「留提示」变体（`--variant keeptip`）

用 `.build/release/wechattweak patch --variant keeptip` 打这个变体：**消息保留、且仍显示「对方撤回了一条消息」提示**。

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

微信一更新，构建号变、地址全变。但补丁点的几何特征跨版本不变，所以**不用再人肉逆向**——跑自动定位器即可：

```bash
# 路 0：参考实现多半已收录 —— 直接同步（revoke / revoke-keeptip / update 三个 target；已有构建号缺 update 也会补）
python3 tools/sync_ref.py --dry-run && python3 tools/sync_ref.py

# 对当前 /Applications/WeChat.app 自动定位防撤回点，打印可粘贴的 config.json 条目
python3 tools/locate_revoke.py

# 定位后直接把条目追加进本仓库 config.json（该构建号不存在时才加）
python3 tools/locate_revoke.py --append

# 再定位「阻止自动更新」的 8 处并追加进同一条目（走 ObjC 方法表，见下）
python3 tools/locate_update.py --append

# 也可指定 App 或直接指定 dylib
python3 tools/locate_revoke.py -a /path/to/WeChat.app
python3 tools/locate_revoke.py -d /path/to/wechat.dylib
python3 tools/locate_update.py --dylib /path/to/wechat.dylib --version 2696xx
```

**阻止自动更新的补丁点不靠字节签名**：微信 4.x 的更新器是 Objective-C 类 `XAppUpdateManager`，定位器解析 `__objc_classlist → class_ro_t → 方法表`，按方法名取 IMP——`startUpdater` / `checkForUpdates:` / `startBackgroundUpdatesCheck:` / `enableAutoUpdate:` 入口写 `ret`，`automaticallyDownloadsUpdates` / `canCheckForUpdate` 的 getter 改 `mov w0,#0; ret`、setter 改 `ret`（fzlzjerry/wechat-antirecall MAINTAINING.md 的方案）。按名找到后还要过入口指令形态校验（函数序言 / `ldrb w0,[x0,#f]; ret` / `strb w2,[x0,#f]`），名字对代码不对就拒绝生成。类名/方法名在 `signatures.json` 的 `update` 段（SSOT），CLI 内建同一份（`UpdateLocator.swift`）：config 缺 `update` 的 4.x 构建，`patch` 会现场定位，定位不到报错而非静默放行。

定位器扫的是这组签名并要求**全片唯一命中**：`parseRevokeXML` 入口 `E` 满足 `E+0x270` 是 `cbz w0`、`E+0x270+delta` 是 `str <Xt>,[x19,#newmsgid]`（原始 `str x0`；已装 keeptip 变体则为 `str xzr`，两者都认）。

微信每隔几个版本会重编译这个函数，`cbz` 跳转距离、`newmsgid` 字段偏移、两点距离 `delta` 会一起变——每变一次算一「代」。**已知三代**（由 fzlzjerry/wechat-antirecall 全量 `patches.json` 归纳，定位器两份实现都内置这张表；**新构建先跑定位器，三代都不中才需要人工**）：

| 代 | 微信构建 | `cbz` 原字节 → 静默写入 | newmsgid 字段 | keeptip 点 = 静默点 + | `str x0` → `str xzr` |
|---|---|---|---|---|---|
| 三 | 269574 ~ 269626（4.1.13） | `40100034` → `82000014` | `[x19,#0x1c8]` | `0x7a0` | `60E600F9` → `7FE600F9` |
| 二 | 269332 ~ 269341（4.1.12） | `40100034` → `82000014` | `[x19,#0x198]` | `0x7a0` | `60CE00F9` → `7FCE00F9` |
| 一 | ≤ 269136（4.1.10 / 4.1.11） | `E00F0034` → `7F000014` | `[x19,#0x168]` | `0x794` | `60B600F9` → `7FB600F9` |

签名的**两个锚点正好就是两个变体的补丁点**，所以定位器一次输出 `revoke` 和 `revoke-keeptip` 两个 target（以第一代为例）：

| 变体 | 补丁点 VA | `expected` | `asm` |
|---|---|---|---|
| `revoke`（静默） | `E+0x270` | `E00F0034` | `7F000014` |
| `revoke-keeptip` | `E+0x270`（还原 cbz） | `E00F0034` 或 `7F000014` | `E00F0034` |
| `revoke-keeptip` | `E+0xA04` | `60B600F9` | `7FB600F9` |

即 keeptip 点 = 静默点 `+ delta`，同一代内跨构建号恒定。这条推导也内建进了 CLI：`patch --variant keeptip --auto-locate` 在 config 缺 `revoke-keeptip` 时直接扫同一组签名算出补丁点（Swift 实现见 `Sources/WeChatTweak/RevokeLocator.swift`），所以**「这个构建号没收录 keeptip」不再是个需要等人补数据的死路**。

两个定位器（Python 的和 CLI 内建的）在第一个锚点上**同时接受原始 `cbz` 和已打静默补丁的 `b`**（每代各自的编码）——否则跑过 `--variant silent` 的机器（想换 keeptip 的正是这批人）会扫不到签名。

拿到条目后：`swift build -c release` → `wechattweak versions` 确认 → 打补丁后实测撤回。`versions`/`patch` **默认就读本仓库的本地 `config.json`**（先 cwd 再从可执行文件向上找），所以 `--append` 加进去的版本直接生效，不用再 `-c`；本地找不到才回退远程。

> 若定位器报「命中 0 处」或「命中多处」，说明该构建把 `parseRevokeXML` 重编译成了新的一代，需人工用 `lipo -thin arm64` 抽切片后复核几何特征，把新一代的五个参数加进 `tools/locate_revoke.py` 的 `GENERATIONS` 和 `RevokeLocator.swift` 的 `signatures`（两处必须同步）。最省力的线索是 fzlzjerry/wechat-antirecall 的 `patches.json`：它若已收录相邻构建号，新一代的编码可直接从那一条读出（2026-08-28 的 269579 就是这么定的）。手工兜底：补丁点 = 入口 `E + 0x270`，把那条 `cbz w0` 等长改成同目标的 `b`。

## 常见问题

- **打完补丁微信闪退 / 打不开（269579 起多人报告，#1038）**：2026-09-02 之前的版本重签名时把整个包的 entitlements 全抹掉了（沙盒、相机、麦克风、app-group、Team ID 全没），SIP 开启的 Mac 上 AMFI 直接把微信杀掉；维护者机器 SIP 关闭所以没发现。**已修**：现在逐组件保留原厂 entitlements 并注入 `cs.disable-library-validation` / `cs.allow-unsigned-executable-memory` 两个键（与 fzlzjerry/wechat-antirecall 同方案），重签名后逐项比对，丢一项就报错拒绝宣称成功。**已被老版本打坏的包救不回来**（entitlements 已从文件里删掉）：去 <https://mac.weixin.qq.com> 重装微信，拉最新代码 `swift build -c release`，再打一次。
- **`WeChat is still running`**：⌘Q 后微信要几秒才真正退出，且 helper 进程比主进程晚几秒；`pgrep -fl WeChat.app/Contents/MacOS` 没输出了再打。
- **防撤回用着用着又没了**：几乎一定是微信自动更新把整个 App 换了（`wechattweak versions` 看构建号是否变了）。2026-09-03 前的版本没有阻止更新，`defaults write com.tencent.xinWeChat SUEnableAutomaticChecks -bool NO` 也没用（微信每次启动把它改回来）。现在 `patch` 默认把更新入口钉死；重新打一次即可。之后想升级微信：去 <https://mac.weixin.qq.com> 下 dmg 覆盖安装，再打一次补丁。
- **SIP 开着 / 关着分别怎么办**：先 `wechattweak doctor`。命令一样，判据不同——见上方[安装 & 使用](#安装--使用)里的说明；SIP 开的机器 `Entitlements` 行是 `NONE` 就必须重装微信。

- **`Unsupported version`**：你的构建号不在 `config.json`。先 `python3 tools/sync_ref.py`（参考实现多半已收录），没有再 `python3 tools/locate_revoke.py --append`，然后 `swift build`。若加了本地条目仍报错，确认用的是本仓库编译出的二进制（默认已本地优先读 config，不必 `-c`）。
- **`config.json has no revoke-keeptip patch point for WeChat build XXXXXX yet`**：**不是你的版本做不了**，是这个构建号的 keeptip 补丁点还没被收录（早期条目从 issue 评论手工收录，只带了静默那一个点）。keeptip 点 = 静默点 `+ delta`（按代 `0x794` / `0x7a0`），可自动算出：加 `--auto-locate` 让工具当场扫，或先 `python3 tools/locate_revoke.py --append && swift build -c release` 固化进 config。
- **`sudo` 都报 `You don't have permission to save "wechat.dylib"`**：macOS 14+ 的 **App Management** 保护在拦（不认 `sudo`）。系统设置 → 隐私与安全性 → **App 管理**，打开你所用终端（Terminal/iTerm/VS Code）的开关，退出重开终端再打补丁。详见 [`docs/user-blockers.md`](docs/user-blockers.md)。

## 参考

- [微信 macOS 客户端拦截撤回功能实践](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/)（上游作者）
- [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall)（微信 4.x 防撤回逆向方法参考）
- 上游项目：[sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)

## License

[AGPL-3.0](LICENSE)（沿用上游）。
