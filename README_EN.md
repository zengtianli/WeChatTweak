# WeChatTweak

[中文](README.md) | **English**

[![GitHub](https://img.shields.io/badge/GitHub-black?logo=github&logoColor=white)](https://github.com/zengtianli/WeChatTweak)
[![Upstream](https://img.shields.io/badge/Upstream-sunnyyoung-blue?logo=github&logoColor=white)](https://github.com/sunnyyoung/WeChatTweak)
[![License](https://img.shields.io/badge/License-AGPL--3.0-green)](LICENSE)

A command-line tool for modifying the WeChat client on macOS.

> **English** — Upstream [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) (13.8k★) stopped
> at **February 2026** and does not cover WeChat 4.x, which moved the message logic out of the main binary into
> `Contents/Resources/wechat.dylib`. **This fork does**: it locates the 4.x patch points, verifies the original
> bytes before writing anything, and re-signs the bundle **keeping its entitlements** (a bare
> `codesign --deep --sign -` strips them, and WeChat then refuses to launch on any machine with SIP on).
> Anti-recall + auto-updater block for selected WeChat builds through `270100` (4.x patches: arm64).
> Prefer a GUI? → **[Unrevoke](https://github.com/zengtianli/WeChatUnrevoke)**.

---

## 🖥 Want a graphical interface? → [Unrevoke](https://github.com/zengtianli/WeChatUnrevoke)

With the command-line edition, you check the build number, choose the subcommand, and remember to run it again after every WeChat update.
**[Unrevoke](https://github.com/zengtianli/WeChatUnrevoke)** is the graphical frontend for this engine: automatic version detection, one button,
automatic patch reapplication after WeChat updates, and one-click recovery on errors. It bundles the `wechattweak` built from this repository,
and uses this repository's `config.json` patch database (so the installed app can retrieve support for newly added WeChat versions without an app update).

[Download v1.0](https://github.com/zengtianli/WeChatUnrevoke/releases/latest) · Also AGPL-3.0

---

> **How this fork relates to upstream**: upstream [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)
> (13.8k★, 1.6k forks) **has had no commits since February 2026**, while WeChat 4.x moved all recall logic into
> `Contents/Resources/wechat.dylib`, invalidating every patch location it knew. This fork picks up from 4.1.10 (build 268880),
> now covering selected builds through **build 270100 (4.1.15)** (not every intervening build; the 4.x patches target arm64), and adds:
>
> - Patching **a specified target dylib** (the 4.x logic is no longer in the main executable)
> - **Original-byte verification before writing**: a wrong version produces an error instead of a blind write that damages WeChat
> - Re-signing that **preserves entitlements**: stripping them prevents WeChat from launching on machines with SIP enabled (the cause of the reports in upstream issue #1038)
> - Blocking WeChat's built-in automatic updater by default (otherwise, the next full-bundle replacement erases the patches; this has happened four times)

## Features

| Feature | Description | WeChat 3.8.x | WeChat 4.x (listed builds through 270100) |
| --- | --- | :---: | :---: |
| **Anti-recall (silent variant)** | Recalled messages remain unchanged in the chat, with no notice | ✓ | ✓ (current release) |
| **Anti-recall (keep-notice variant)** | Keeps the message **and** the “The other party recalled a message” notice | ✓ | ⚠️ (`--variant keeptip`: notices in **private chats**; **group chats** remain silent) |
| **Block automatic updates** | Stops updates from reverting patches (WeChat replaces the entire bundle; it has silently erased patches four times, and `defaults write` cannot disable it) | ✓ | ✓ (included in `patch` by default; disable with `--no-block-update`) |
| **Multiple client instances** | Sign into multiple accounts at once | ✓ | — (no byte patch for 4.x; duplicate the App) |

> **WeChat 4.x has two anti-recall variants; select one with `--variant` when patching**:
> - **`--variant silent` (default)**: blocks recall at the upstream parser. The message stays, but no “The other party recalled a message” notice appears.
> - **`--variant keeptip`**: keeps the message **and** the recall notice. In contrast to the silent variant, it lets parsing run so the notice can render, but rewrites `newmsgid`, which identifies the message to delete, to 0 when it is stored in the structure. Downstream deletion by `newmsgid` then finds no target, leaving the message and the normal notice. This approach (`str x0`→`str xzr`) comes from the `revoke-tip` mode in the reference implementation [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall).
>
> The `keeptip` variant was **tested on a real device with build 269136 (4.1.11)**: recalled messages remain with notices in **private chats**; in **group chats**, messages remain but there is still no notice (the same behavior as the silent variant). The underlying conflict is that `newmsgid` controls both “which message to delete” and “which message the group-chat notice appears below.” Zeroing it preserves the message but prevents native group-notice insertion (private-chat notices do not depend on newmsgid). Group notices require preserving the real newmsgid and blocking the downstream deletion call instead. That call uses virtual dispatch and cannot be located statically; finding it dynamically with lldb is a separate engineering task (see the end of the [keep-notice variant](#留提示变体--variant-keeptip) section). In issue [#1038](https://github.com/sunnyyoung/WeChatTweak/issues/1038), wuliyc reported similar behavior on 4.1.11 without specifying whether it concerned private or group chats.
>
> Running multiple WeChat 4.x instances still requires duplicating the entire App bundle.

## Supported versions

The tool matches **build numbers** (`CFBundleVersion`, the number printed by `wechattweak versions`), not marketing version numbers.

Compatibility currently targets the **latest stable release on the official WeChat website**. The official installer was checked on 2026-09-24 and is **4.1.15 (build 270100)**, for which Apple Silicon (arm64) patches are available. Builds 269631 (website edition) and 269602 (App Store edition) of 4.1.13 are also listed. For other builds not yet listed, update to this release from the [WeChat website](https://mac.weixin.qq.com/) and reapply the patch; configurations for previously supported builds are retained. Even if the website and App Store editions both display 4.1.13, check their build numbers separately: their addresses are not interchangeable.

The sample for build 270100 is the installer downloaded on 2026-09-24 from the [official download link](https://dldir1.qq.com/weixin/Universal/Mac/WeChatMac.dmg) (released 2026-09-18), SHA-256 `b73319ea3ef7f5f2f6f1403b0bed87ac75b5f5b70f0951ea61bad2d9449857f8`. The sample used to locate build 269631 came from the [official Tencent installer](https://dldir1.qq.com/weixin/Universal/Mac/xWeChatMac_universal_4.1.13.63_269631.dmg), with SHA-256 `b247b2cc9dd2122024d6facf9f3c464f2564f106266851d439853bacc7013de9`. GUI users can refresh the patch database by quitting and reopening WeChatUnrevoke while online; this configuration update does not require reinstalling the GUI. WeChat upgrades remove the patch, so re-enable and check protection after upgrading.

| Build | WeChat version | Anti-recall | Block automatic updates |
| --- | --- | :---: | :---: |
| 270100 | 4.1.15 website edition, arm64 | ✓ (keeptip writing, diagnostics, signature verification, and restoration verified on a copy of the official installer; real-chat recall testing remains for the user) | ✓ (original bytes checked at 8 locations; post-write diagnostics passed) |
| 269631 | 4.1.13.63 website edition, arm64 | ✓ (default keeptip writing, diagnostics, and restoration verified on a pristine copy; real-chat recall testing remains for the user) | ✓ (original bytes checked at 8 locations; post-write diagnostics passed) |
| 269627 | 4.1.13 | ✓ (patched locally; locations found by `tools/locate_revoke.py`) | ✓ (`tools/locate_update.py`, 8 locations) |
| 269626 | 4.1.13 | ✓ (tested locally) | — (superseded by 269627; not included) |
| 269602 | 4.1.13 App Store edition, arm64 | ✓ (original bytes checked for both `silent` and `keeptip`; real-chat recall testing remains for the user) | Not applicable: the App Store edition has no in-app updater (the App Store updates it), so `patch` skips this step; turn off App Store automatic updates to keep the patch. Also supports `multiInstance` (verified by launching same-bundle-id copies in parallel) |
| 269579 | 4.1.13 | ✓ | ✓ |
| 269136 | 4.1.11 | ✓ (tested locally) | ✓ |
| 25 other builds within 268575 ~ 269624 | 4.1.10 ~ 4.1.13 | ✓ (synced from fzlzjerry/wechat-antirecall by `tools/sync_ref.py`; patching still checks the `expected` bytes) | ✓ (synced in the same way) |
| 268880 | 4.1.10 | ✓ | — (the CLI locates methods by name when patching and reports an error only if it cannot find them) |
| 34371 / 32288 / 32281 / 31960 / 31927 | 3.8.x | ✓ | ✓ (original upstream support) |

Run `wechattweak versions` first to see whether your build is listed. If not, see [Adding a version](#新增一个版本) below.

<a id="安装--使用"></a>

## Installation & usage

### WeChat 4.x — Homebrew (easiest)

```bash
brew install zengtianli/tap/wechattweak
sudo wechattweak patch      # 防撤回 + 顺手挡住微信自动更新
wechattweak doctor          # 体检
sudo wechattweak restore    # 想还原
```

This installs a prebuilt universal binary; Xcode is not required. Uninstall any same-named package from another source first
(the binary names conflict):

```bash
brew uninstall sunnyyoung/tap/wechattweak || brew uninstall wechattweak
```

The patch database (`config.json`) is fetched from this repository's `master` branch at runtime, so when a new WeChat version is added,
**you do not need to upgrade this formula**.

### WeChat 4.x (build from source)

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

# 想还原：把每个补丁点写回原始字节并重签名（微信恢复原样，自动更新也一并恢复）
.build/release/wechattweak restore

# 给脚本/GUI 用：同一趟检查的机器可读版本，overall 字段就是最终判决
.build/release/wechattweak doctor --json
```

> **Safety boundary of `restore`**: restoration writes back `expected[0]` and accepts both already-patched and already-original
> bytes, making repeated runs idempotent. Bytes that are neither original nor written by this tool (for example, changes by another tool) cause
> `expectedMismatch` and the write is refused. **The config entries for the five old 3.8.x builds have no `expected` field**,
> so there is no original value to restore. These are rejected as a whole **before any changes**, rather than partially restored (reinstall WeChat instead).

> **`doctor --json` is the GUI contract**: `overall` is one of `protected` / `partial` / `unprotected` /
> `unsupportedBuild` / `brokenBundle` / `mixed`; the verdict is computed only here.
> Consumers such as [Unrevoke](https://github.com/zengtianli/WeChatUnrevoke) **decode the result without deriving it again**:
> two separate implementations would disagree as soon as this file changes.

> **The commands are the same with SIP on or off; the difference is how success is assessed** (`doctor` gives the appropriate verdict using `csrutil status`):
> - **SIP enabled** (most Macs): the system enforces entitlement checks. If a bundle loses its entitlements (as this tool did before 2026-09-02), WeChat is killed on launch. The `Entitlements` line in `doctor` must show `app-sandbox ✓, application-identifier ✓`; if it says `NONE`, reinstall WeChat and patch it again. Use this tool's default entitlement-preserving re-signing; do not manually run `codesign --remove-sign` or a bare `--deep --sign -`.
> - **SIP disabled**: damaged bundles can still launch, so “WeChat opens” proves nothing. Check the same `Entitlements` line, and verify on a copy of the original dmg before advising someone whose machine has SIP enabled.

> **Choose one of two mutually exclusive variants**: `--variant silent` (default) keeps messages without notices; `--variant keeptip` keeps messages and the “The other party recalled a message” notice. To switch, simply patch again using the other `--variant` (original-byte checks and idempotency make repeated patching safe). `keeptip` requires a `revoke-keeptip` patch location. Included builds: 269136 (tested on a real device), 269579/269626 (4.1.13, keeptip located using the same-generation signature `+0x7a0`), and 269110/269111 (derived from the geometric relationship `+0x794`, **not verified on a real device**). **For unlisted 4.x builds, you do not have to wait for me to add them**; choose either route:

```bash
# 路 1：让工具自己扫签名算出补丁点（不改 config.json）
.build/release/wechattweak patch --variant keeptip --auto-locate

# 路 2：先把补丁点固化进 config.json，再正常打
python3 tools/locate_revoke.py --append && swift build -c release
```

Both routes verify the original bytes before writing. A wrong address produces `expectedMismatch` and refuses the write instead of damaging WeChat.

Patching automatically re-signs the bundle: first the modified `wechat.dylib`, then the entire App with `--deep`, while **preserving the original entitlements of every component** (WeChat uses App Sandbox + Hardened Runtime; sandbox, camera, microphone, and app-group entitlements must all remain). It also injects two `com.apple.security.cs.*` keys so ad-hoc signing works. After signing, it compares every entitlement and fails if any are missing. See the header of `Sources/WeChatTweak/Resigner.swift` for details.

### WeChat 3.8.x (upstream Homebrew; 3.8.x only)

```bash
brew install sunnyyoung/tap/wechattweak
wechattweak patch
```

> ⚠️ **Test after installation**: have someone send you a message and recall it, then confirm the message remains. Only an actual received recall can verify that anti-recall works.
>
> **To restore**: download WeChat again from the [official website](https://mac.weixin.qq.com/) and install it over the existing copy.

## How it works

Recall is not a local action: after the other person recalls a message, the server pushes a `revokemsg` command to your client. The client's `parseRevokeXML` (in `wechat.dylib`) parses it, then deletes the local message and inserts a recall notice. **The message is already on your machine**; recall tells the client to delete it afterward.

The patch changes a branch instruction near this function's entry:

```
488319c: bl   0x4431b58      ; 判断这是不是要执行的撤回，结果放 w0
48831a0: cbz  w0, 0x488339c   ; w0==0 才跳过删除；正常 w0≠0 → 往下执行删消息
```

It changes `cbz w0, X` (`E00F0034`, conditional branch) to `b X` (`7F000014`, unconditional branch) with the same target, so the **deletion logic is always skipped**. Recall commands are still received and parsed, but the actual message-deletion code is never reached: the message behaves as if it had never been recalled.

Both `cbz` and `b` are fixed-width 4-byte instructions with the same target offset. This is an **in-place, equal-length replacement** that changes only 4 bytes without altering the binary layout. It adds no notice-rendering code and merely removes the deletion action, so anti-recall is **silent**: the message stays and no notice appears.

The patch location is uniquely identified across the entire arm64 slice using the geometry of `parseRevokeXML` (an entry `stp` prologue, `cbz w0` at `entry+0x270`, and `str x0,[x19,#newmsgid]` at a fixed distance; encodings vary by generation, as described in [Adding a version](#新增一个版本)). Disassembly and original bytes are checked individually. The reverse-engineering method draws on [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall).

## Why the current release is silent

The `cbz` at `0x48a03b0` guards the recall message's **XML parsing branch**. Reverse engineering confirmed that the containing function is `MessageSystemExtInfo::TryParseMessageXML`, and the `cbz` tests whether this msgType is `revokemsg`. Replacing `cbz` with `b` makes the parser **skip the entire revokemsg branch**, so neither `newmsgid` (the local message to delete) nor `replacemsg` (the recall-notice text) is parsed from the XML.

The downstream code that deletes a local message by `newmsgid` and inserts a notice from `replacemsg` consequently receives no input; neither action occurs. Keeping the message without a notice is therefore **a consequence of skipping parsing**: notices are not disabled separately; their input is cut off at the start.

In other words, silence is a tradeoff of **this particular patch location**, not a fundamental limitation. Preserving parsing while blocking only downstream deletion can keep both the message and the notice (see the next section).

<a id="留提示变体--variant-keeptip"></a>

## Keep-notice variant (`--variant keeptip`)

Apply this variant with `.build/release/wechattweak patch --variant keeptip`: **the message remains, along with the “The other party recalled a message” notice**.

The approach is the opposite of the silent patch: leave parsing intact and **invalidate newmsgid**. In recall XML, `newmsgid` specifies the local message to delete and `replacemsg` contains the notice text. The parser `TryParseMessageXML` (entry `0x48a0140`) stores the parsed `newmsgid` into the structure at `0x48a0b44`:

```
0x48a0b44: str  x0,  [x19, #0x168]   ; 60B600F9  把 newmsgid 存进结构体（要删的目标）
```

For 269136, the keep-notice variant makes two equal-length byte changes:

| Patch location | Original bytes → new bytes | Effect |
|---|---|---|
| `0x48a03b0` (`cbz w0`) | `E00F0034` → `E00F0034` (restore; also accepts `7F000014` on machines with the silent patch) | Parsing runs normally, allowing notices to render |
| `0x48a0b44` (`str x0,[x19,#0x168]`) | `60B600F9` → `7FB600F9` (`str xzr`) | Stored `newmsgid` = **0**; downstream deletion by id=0 finds no target → deletion fails and the message remains |

The parsed recall notice is inserted normally, while deletion misses its target because `newmsgid` is zero. This `str x0`→`str xzr` approach comes from the `revoke-tip` mode in [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall). That project also offers `--runtime-tip` to inject custom notice text at runtime; this fork does not include it and uses only byte patches with the default notice.

> **Correction to an earlier assessment**: earlier reverse-engineering notes assumed that keeping notices required locating and NOPing the downstream local-message deletion call. That work was shelved because the call's receiving side lay beyond virtual dispatch/chained fixups and was difficult to locate statically. **That approach was mistaken**: there is no need to locate the deletion call; zeroing `newmsgid` where it enters the structure makes deletion miss its target. The `revoke-tip` implementation from fzlzjerry provided the correct reference.
>
> **Status**: the byte patch is implemented and was tested on a real device with build 269136 (4.1.11). **Private chats** retain messages and show notices; **group chats** retain messages without notices, as with silent mode. (Static verification: after patching, `0x48a03b0` = `cbz w0` and `0x48a0b44` = `str xzr`, structurally identical byte for byte to fzlzjerry's `revoke-tip` patch for 269110.)
>
> **Why group chats show no notice**: throughout the revoke module (`0x48a0140..0x48ad700`), only `0x48a0b44` writes the newmsgid field `[x19,#0x168]`, shared by private and group chats. Private-chat notice insertion does not depend on newmsgid, so it still works. Group-chat rendering uses newmsgid to choose the message below which to attach the notice; zeroing it also disables that insertion, leaving group chats silent. This downstream consumer uses virtual dispatch/chained fixups, so a separate group-notice patch location cannot be identified statically with byte patching alone.
>
> **Runtime injection (fzlzjerry `--runtime-tip`) does not fix group chats either.** Inspection of its `Runtime.mm` confirms that its hook only **rewrites the replaceMsg notice text** after parsing, still zeroes newmsgid, and relies on WeChat's **native** code to insert the notice. There is no independent insertion call anywhere (zero objc_msgSend/selector). It reaches the same newmsgid=0 state as this byte patch, so native group insertion still does not trigger. **The actual solution** is to preserve the real newmsgid so native notices can be inserted and anchored in both private and group chats, then NOP the downstream deletion call. That virtually dispatched call cannot be located statically; it requires dynamic lldb investigation (trigger a real group-chat recall, break on the WCDB deletion primitive, and inspect the backtrace). This is a separate task requiring real-device testing and is not included in this fork.

<a id="新增一个版本"></a>

## Adding a version

A WeChat update changes the build number and all addresses. The patch locations' geometric features remain stable across versions, however, so **manual reverse engineering is unnecessary**: run the automatic locator:

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

**Automatic-update patch locations do not use byte signatures**: the WeChat 4.x updater is the Objective-C class `XAppUpdateManager`. The locator parses `__objc_classlist → class_ro_t → 方法表` and obtains IMPs by method name. It writes `ret` at the entry of `startUpdater` / `checkForUpdates:` / `startBackgroundUpdatesCheck:` / `enableAutoUpdate:`, changes the getters `automaticallyDownloadsUpdates` / `canCheckForUpdate` to `mov w0,#0; ret`, and changes setters to `ret` (the approach in fzlzjerry/wechat-antirecall's MAINTAINING.md). After finding a name, it checks the entry-instruction shape (function prologue / `ldrb w0,[x0,#f]; ret` / `strb w2,[x0,#f]`); a matching name with unexpected code is rejected. Class and method names live in the `update` section of `signatures.json` (SSOT), with the same data built into the CLI (`UpdateLocator.swift`). For a 4.x build whose config lacks `update`, `patch` locates it on demand and reports an error if it fails, rather than silently proceeding.

The locator searches for this signature and requires **exactly one match in the whole slice**: at the `parseRevokeXML` entry `E`, `E+0x270` is `cbz w0`, and `E+0x270+delta` is `str <Xt>,[x19,#newmsgid]` (originally `str x0`, or `str xzr` if keeptip is already installed; both are accepted).

Every few versions, WeChat recompiles this function, changing the `cbz` branch distance, the `newmsgid` field offset, and the distance `delta` between the two locations together. Each such change defines a generation. **Three generations are known**, summarized from the full fzlzjerry/wechat-antirecall `patches.json` and built into both locator implementations. **Run the locator on a new build first; manual work is needed only if all three generations fail to match**:

| Generation | WeChat builds | Original `cbz` bytes → silent patch | newmsgid field | keeptip location = silent location + | `str x0` → `str xzr` |
|---|---|---|---|---|---|
| Three | 269574 ~ 269626 (4.1.13) | `40100034` → `82000014` | `[x19,#0x1c8]` | `0x7a0` | `60E600F9` → `7FE600F9` |
| Two | 269332 ~ 269341 (4.1.12) | `40100034` → `82000014` | `[x19,#0x198]` | `0x7a0` | `60CE00F9` → `7FCE00F9` |
| One | ≤ 269136 (4.1.10 / 4.1.11) | `E00F0034` → `7F000014` | `[x19,#0x168]` | `0x794` | `60B600F9` → `7FB600F9` |

The signature's **two anchors are exactly the patch locations for the two variants**, so the locator outputs both `revoke` and `revoke-keeptip` targets in one pass (generation one shown here):

| Variant | Patch VA | `expected` | `asm` |
|---|---|---|---|
| `revoke` (silent) | `E+0x270` | `E00F0034` | `7F000014` |
| `revoke-keeptip` | `E+0x270` (restore cbz) | `E00F0034` or `7F000014` | `E00F0034` |
| `revoke-keeptip` | `E+0xA04` | `60B600F9` | `7FB600F9` |

Thus, keeptip location = silent location `+ delta`, a constant across builds within a generation. The CLI also implements this derivation: when config lacks `revoke-keeptip`, `patch --variant keeptip --auto-locate` scans the same signatures and computes the location directly (Swift implementation: `Sources/WeChatTweak/RevokeLocator.swift`). **An unlisted keeptip location for a build no longer leaves you waiting for someone to add data**.

At the first anchor, both locators (Python and the built-in CLI implementation) **accept the original `cbz` and the already-patched silent `b`**, with generation-specific encodings. Otherwise, machines that have already run `--variant silent`—exactly those whose users may want to switch to keeptip—would fail to match the signature.

After obtaining the entry: run `swift build -c release` → confirm with `wechattweak versions` → patch and test a real recall. By default, `versions`/`patch` **read this repository's local `config.json`** (first in cwd, then by searching upward from the executable). Versions added with `--append` therefore take effect directly without `-c`; the remote source is used only if no local file is found.

> If the locator reports zero or multiple matches, the build has recompiled `parseRevokeXML` into a new generation. Extract the slice with `lipo -thin arm64`, manually review its geometry, and add the new generation's five parameters to `GENERATIONS` in `tools/locate_revoke.py` and `signatures` in `RevokeLocator.swift` (both must stay synchronized). The easiest reference is fzlzjerry/wechat-antirecall's `patches.json`: if it already includes a neighboring build, read the new encodings from that entry (this is how 269579 was identified on 2026-08-28). Manual fallback: patch location = entry `E + 0x270`; replace that `cbz w0` with an equal-length `b` to the same target.

## FAQ

- **WeChat crashes or will not open after patching (multiple reports from 269579 onward, #1038)**: versions before 2026-09-02 stripped all entitlements during re-signing (sandbox, camera, microphone, app-group, and Team ID). AMFI then killed WeChat on Macs with SIP enabled; the maintainer's SIP-disabled machine concealed the problem. **Fixed**: original entitlements are now preserved per component, and `cs.disable-library-validation` / `cs.allow-unsigned-executable-memory` are injected (the same approach as fzlzjerry/wechat-antirecall). Every entitlement is compared after re-signing; any loss causes an error rather than a success report. **Bundles damaged by old versions cannot be recovered** because their entitlements have been removed from the files. Reinstall WeChat from <https://mac.weixin.qq.com>, pull the latest code, run `swift build -c release`, and patch again.
- **`WeChat is still running`**: WeChat takes a few seconds to exit after ⌘Q, and its helper processes exit a few seconds after the main process. Wait until `pgrep -fl WeChat.app/Contents/MacOS` returns no output before patching.
- **Anti-recall stops working after a while**: WeChat's automatic updater has almost certainly replaced the entire App (check whether the build number changed with `wechattweak versions`). Versions before 2026-09-03 did not block updates; `defaults write com.tencent.xinWeChat SUEnableAutomaticChecks -bool NO` also failed because WeChat resets it on every launch. `patch` now blocks updater entry points by default; apply it again. To upgrade WeChat later, download the dmg from <https://mac.weixin.qq.com>, install it over the existing copy, and reapply the patch.
- **What to do with SIP enabled or disabled**: run `wechattweak doctor` first. The commands are identical but the assessment differs; see [Installation & usage](#安装--使用) above. If SIP is enabled and the `Entitlements` line says `NONE`, reinstall WeChat.

- **`Unsupported version`**: your build is not in `config.json`. First run `python3 tools/sync_ref.py` (the reference implementation probably already includes it); otherwise run `python3 tools/locate_revoke.py --append`, followed by `swift build`. If a local entry has been added but the error persists, confirm you are using the binary built from this repository (local config is preferred by default; `-c` is unnecessary).
- **`config.json has no revoke-keeptip patch point for WeChat build XXXXXX yet`**: **your version is not inherently unsupported**; its keeptip location simply has not been listed (early entries were manually collected from issue comments and included only the silent location). keeptip location = silent location `+ delta` (`0x794` / `0x7a0` by generation), which can be computed automatically. Add `--auto-locate` to scan immediately, or first run `python3 tools/locate_revoke.py --append && swift build -c release` to persist it in config.
- **Even `sudo` reports `You don't have permission to save "wechat.dylib"`**: macOS 14+ **App Management** protection is blocking the operation; `sudo` does not bypass it. In System Settings → Privacy & Security → **App Management**, enable your terminal (Terminal/iTerm/VS Code), quit and reopen it, then patch again. See [`docs/user-blockers.md`](docs/user-blockers.md).

## References

- [Implementing recall interception in the macOS WeChat client](https://blog.sunnyyoung.net/wei-xin-macos-ke-hu-duan-lan-jie-che-hui-gong-neng-shi-jian/) (upstream author)
- [fzlzjerry/wechat-antirecall](https://github.com/fzlzjerry/wechat-antirecall) (reverse-engineering reference for WeChat 4.x anti-recall)
- Upstream project: [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak)

## License

[AGPL-3.0](LICENSE) (retained from upstream).
