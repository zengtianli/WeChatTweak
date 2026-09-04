# issue #1038 通告草稿（GUI 发布）· 待用户点头后发

**发到**：<https://github.com/sunnyyoung/WeChatTweak/issues/1038>（本人开的帖，42 条回复，16 个陌生人参与）
**为什么发这里**：fork 不进 GitHub 搜索结果，这个帖子是现有 62 star 的**全部**来源。
**发法**：`gh issue comment 1038 -R sunnyyoung/WeChatTweak -F ~/Apps/vendor/WeChatTweak/handoffs/issue-1038-gui-announce.md --body-file` 之前先把下面分隔线以上的说明删掉，或直接复制正文粘贴。

---

补充一个东西：给这个 fork 做了图形界面 **Unrevoke**，不用开终端了。

<https://github.com/zengtianli/Unrevoke>

命令行版一直有三个门槛：自己去表里查构建号、自己判断该跑哪条子命令、微信每次更新后记得再跑一遍。
这个 app 就是这三件事的答案：

- **自己认版本**，直接告诉你这台机器上的微信在不在收录范围内
- **只有一个按钮**，按钮上写的字就是按下去会发生的事
- **微信更新后自己把补丁打回去**（整包替换式更新会把补丁抹掉，已经发生过四次）
- **一键还原**，写回原始字节并重签，微信恢复原样、自动更新一起恢复
- 出错说人话：版本没收录 / 字节对不上 / entitlements 掉了 / 微信还开着，各有一句解释和一条出路

内嵌的就是本 fork 编出来的 `wechattweak`，补丁库也是本 fork 的 `config.json` ——
**所以新的微信版本被收录后，装着的 app 自己就能拿到，不用更新 app。**

覆盖到 build 269627。macOS 15+，universal（Apple Silicon / Intel 都能跑）。
AGPL-3.0，和引擎一致。

两点先说清楚：

1. **没有签名公证**，macOS 默认不让打开。装到 /Applications 后跑一次
   `xattr -dr com.apple.quarantine /Applications/Unrevoke.app`，或者右键 → 打开。
   自己编译也行，一共一千行左右 Swift。
2. **群聊仍然只保留消息、不出撤回提示**，私聊两样都有。原因在引擎 README 里写了
   （`newmsgid` 同时管「删哪条」和「群聊提示插在哪」，清零它保住消息也丢了提示）。

引擎那边这次也补了两个命令：`restore`（一键还原）和 `doctor --json`（机器可读的体检结果）。
