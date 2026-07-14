# 群聊撤回提示：lldb 动态定位「删本地消息」调用（会话指南）

目标：找到微信 4.x 收到撤回后按 `newmsgid` 删本地消息的**下游调用 VA**，之后字节补丁 NOP 它 →
保留真 newmsgid（私聊+群聊原生提示都能插入并锚定）+ 消息不被删 = **群聊也留消息且有提示**。

背景：纯字节 keeptip / fzlzjerry runtime-tip 都清零 newmsgid，导致群聊提示的原生插入不触发（详见 [[keeptip-revoke]]）。
唯一出路是保留真 newmsgid、改为掐掉删除；删除调用在虚派发接收侧、静态 3 次未定位，只能动态抓。

预计 ~15 分钟。需要**另一个微信账号**（或找个人）在**群里**发消息再撤回来触发接收侧删除路径。

---

## 前提

- 本机微信 = build 269136，当前已打 keeptip（cbz=E00F0034 / 0x48a0b44=str xzr）。**保持这个状态即可，不用改。**
- 脚本：`/Users/tianli/Apps/WeChatTweak/tools/hunt_delete.py`（地址针对 269136 写死）。

## 步骤

### 1. 确认微信在运行、拿到 pid
```bash
pgrep -x WeChat
```

### 2. attach lldb（微信是 adhoc 签名、无 hardened runtime，sudo 一般可直接 attach）
```bash
sudo lldb
(lldb) process attach --name WeChat
```
- 若报 `attach failed: not permitted` / `unable to attach`：走下面的「附录 A：加 get-task-allow 重签」，然后重试本步。

### 3. 导入脚本（会自动布防断点）
```
(lldb) command script import /Users/tianli/Apps/WeChatTweak/tools/hunt_delete.py
```
看到 `[hunt] 已布防：断点 @ 0x...` 即成功。它已在解析器写 newmsgid 的下一条指令下断。

### 4. 让 lldb 放开微信继续跑
```
(lldb) c
```

### 5. 触发：用【另一个账号】在【和你共处的群】里发一条消息，然后**撤回它**
- 你这台设备收到撤回 → 命中断点 → 脚本把真 newmsgid 写回 + 设读 watchpoint + 自动继续 →
  删除逻辑读 newmsgid 时 watchpoint 命中，lldb 停下并自动打印 `bt`。

### 6. 每次停下，复制**完整 `bt` 输出**，然后继续
```
(lldb) bt          # 若没自动打印就手敲
(lldb) c
```
- 可能停好几次（提示渲染也会读 newmsgid，属噪音，我来筛）。撤回**一次**通常够；
  停 3~5 次、或 `c` 后不再停（回到正常）就可以了。

### 7. 把所有 `bt` 原文发给我
- 我会把每帧地址减去 `wechat.dylib` base，换算成模块内 VA，挑出删除调用点，给出要 NOP 的地址+字节。
- 顺带告诉我：**写回 newmsgid 后，那条撤回在群里是否出现了「XX 撤回了一条消息」提示**（验证 newmsgid-gated 理论；出现=理论坐实，NOP 删除即可两头都好）。

### 8. 收尾
```
(lldb) detach
(lldb) quit
```
测试消息因为 newmsgid 被写回会被真的删掉（正常，是测试消息）。微信本身不受影响。

---

## 我拿到 bt 之后做什么
1. 定位删除调用 VA（模块内偏移），确认是单一 `bl`/`blr` 调用点。
2. 判断能否等长 NOP（`1F2003D5`）而不破坏别的删除路径；必要时改用注入 hook 只拦撤回驱动的删除。
3. 加 config.json `revoke-keeptip` 的第 3 条 entry（NOP 删除）或新变体；先在 dylib 副本静态验证，再你实机实测私聊+群聊。
4. 已知副作用待定：无条件 NOP 删除会让**你自己的撤回**也不删本地消息（可接受则简单；否则后续加自撤/他撤判别，参考 fzlzjerry 的 `tipIndicatesSelfRecall`）。

## 若 watchpoint 没命中 / 抓不到
- 备选：撤回**私聊**消息（删除路径大概率同一处，更易触发），对比 bt。
- 备选：在断点停下时手敲 `watchpoint set expression -w read -s 8 -- <addr>`（addr 见 `[hunt]` 打印），再 `c`。
- 仍不行 → 回报，我改用「断解析器 wrapper 返回 + 单步跟 newmsgid 消费」的更细方案。

---

## 附录 A：加 get-task-allow 重签（仅当第 2 步 attach 被拒时）
```bash
cat > /tmp/gta.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
EOF
pkill -x WeChat
sudo codesign -f -s - --entitlements /tmp/gta.plist /Applications/WeChat.app/Contents/MacOS/WeChat
# 重开微信后回到步骤 1。dylib 不必重签（补丁已签过）；若微信启动报签名错，
# 再跑一次本 fork 的 `sudo .build/release/wechattweak patch --variant keeptip` 重签整包。
```
> 注：加 get-task-allow 只为让 lldb 能 attach，是临时调试措施；定位完成后可用官网重装或重打补丁还原。
