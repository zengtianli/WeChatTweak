# 屏蔽微信自动更新 + doctor 体检 + SIP 开/关双口径（2026-09-03）

> 触发：用户「wechat 撤回无效了」+「针对 SIP 开关分别有办法操作」+「那就关闭自动更新？搞来搞去的」。

## 现场诊断（本轮命令输出）

| 项 | 值 |
|---|---|
| 构建号 | 269626 → **269627**（又被静默更新，第四次） |
| 包状态 | 原厂全新签名（Tencent Developer ID，主程序 17 个 entitlements 完好）→ 更新是整包替换 |
| `SUAutomaticallyUpdate` / `SUEnableAutomaticChecks` | 0 / **1**（09-02 写的 NO 被改回；`SULastCheckTime` 每 300 s 前进） |
| 参考实现 fzlzjerry patches.json | 最新只到 269624，无 269626/269627 |

结论：defaults 方案**失败**（实证）。`-[XAppUpdateManager startUpdater]` 每次启动调 `setAutomaticallyChecksForUpdates:`，用户偏好写了也白写。唯一可靠的是把更新入口钉死在二进制里。

## 做了什么

1. **撤回补丁数据**：`sync_ref.py` 拉进 269624；`locate_revoke.py --append` 定位 269627（gen3，silent `0x49abb4c`，keeptip `0x49ac2ec`）。
2. **屏蔽更新定位器**（新）：`tools/locate_update.py` + `Sources/WeChatTweak/UpdateLocator.swift`，走 ObjC 元数据 `__objc_classlist → XAppUpdateManager → class_ro_t → 方法表（relative/absolute 都支持，chained-fixup 指针取低 36 位）` 按名取 8 个 IMP，再过入口形态校验。规则 SSOT 在 `signatures.json` 的 `update` 段，`gen_signatures.py` 派生 Swift 常量。
   - 验证：269579（回收站原厂副本）定位结果与参考实现 8 处逐地址、逐字节相同；269627 的 8 处与「参考 269624 平移 -0x3FE0」+ 选择器引用（sparkleUpdater / setAutomaticallyChecksForUpdates: / setCanCheckForUpdate: …）三方一致。
3. **`sync_ref.py`** 现在也搬 `update`，并给已有构建号补缺的 `update`（本轮补了 26 条）。config 现 37 条，27 条带 `update`（269626 无：已被替代、手头没那份 dylib；268880 无：CLI 打补丁时现场定位）。
4. **CLI**：`patch` 新增 `--block-update/--no-block-update`，**默认开**；config 缺 `update` 的 4.x 构建自动走 `UpdateLocator`，找不到报错 `updateUnavailable`（不静默跳过）。3.x 沿用上游 6 个独立 target。
5. **`doctor` 子命令**（新，`Doctor.swift`）：构建号 / config 匹配 / SIP / 是否在跑 / 是否可写（sudo）/ 签名 authority / 主程序 entitlements（sandbox、application-identifier、disable-library-validation）/ 嵌套 app·appex·xpc 计数 / Sparkle 三键 / 三个 target 的补丁状态（`Patcher.inspect` 只读）→ 按 SIP 开/关给结论和下一步命令。
6. **Patcher** 重构出 `slices()` / `fileOffset()` / `inspect()`，`patch` 行为与报错文案不变（4 个旧测试原样过）。
7. 测试 15 → **23**：`ObjCFixture`（合成含 ObjC 元数据的 Mach-O）+ `UpdateLocatorTests` 7 例（relative/absolute/direct-selector/chained、打完再定位=already patched、缺方法、类名不对、入口形态不对、访问器字段不配）+ `SignaturesSyncTests` 补 update 规则同步校验。
8. 本机 269627 实打：`patch --variant keeptip` → keeptip 1 处 + update 8 处写入，重签名恢复 22 个 entitlements 档案，`--verify --deep --strict` OK；`doctor` 复检 ✅；`env -u TZ open -a WeChat` 重开。

## 怎么验证「挡住了」

- `defaults read com.tencent.xinWeChat SULastCheckTime` 在微信运行 ≥10 分钟后**不再前进**（原每 300 s 一次）。
- 微信「设置 → 关于/检查更新」点了无反应或不再弹升级。
- 反证：`patch --no-block-update` 重打后 `SULastCheckTime` 恢复前进。

## 未闭环

- 防撤回本身仍只能**实收撤回**验证（符号已剥离）。
- 屏蔽更新的长期效果要等微信下一次发版；若仍被更新，看 `wechat.dylib` 里是否新增了不经 `XAppUpdateManager` 的通道（fzlzjerry 提到 4.1.10 另有 `SPUUpdater` 直连通道，本补丁不覆盖）。
- 269626 的 `update` 条目缺失（无 dylib 可定位）；如果有人还停在 269626，CLI 会现场定位。
