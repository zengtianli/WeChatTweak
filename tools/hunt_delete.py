"""
hunt_delete.py — lldb 脚本：动态定位微信 4.x 撤回「删本地消息」的调用点。

目标：找到那条在收到撤回后、按 newmsgid 删除本地消息的下游调用的 VA，
以便字节补丁 NOP 它（保留真 newmsgid → 私聊+群聊都留消息且出提示）。

原理：
- 解析器把真 newmsgid 从 [x19+0x188] 读进 x0，本该在 0x48a0b44 存入 [x19+0x168]；
  keeptip 补丁把这条改成了 str xzr（写 0），所以下游按 id=0 找不到消息、删除不触发。
- 本脚本在 0x48a0b48（那条 str 的下一条，x0 仍=真 newmsgid）下断，把真 newmsgid
  写回 [x19+0x168]，让删除照常触发；同时对 [x19+0x168] 设「读」硬件 watchpoint。
- 删除逻辑必须读 newmsgid 才知道删哪条 → watchpoint 命中 → bt 顶部若干帧里
  落在 wechat.dylib 内的那个就是删除调用点。把 bt 全部发回给我，我据此定位 NOP 点。

用法（见 handoffs/group-delete-hunt.md 完整步骤）：
    (lldb) command script import /Users/tianli/Apps/WeChatTweak/tools/hunt_delete.py
    然后用另一个账号在群里撤回一条消息 → 每次停下 copy `bt` 输出。

只读分析用，不改二进制。newmsgid 被临时写回后，那条测试消息会被真的删除（正常，是测试消息）。
"""

import lldb

DYLIB = "wechat.dylib"
# 269136 专用文件 VA（__TEXT vmaddr==0，故文件 VA == 模块内偏移）
STORE_NEXT = 0x48A0B48   # `str xzr,[x19,#0x168]`(0x48a0b44) 的下一条；此刻 x0 仍 = 真 newmsgid
FIELD_OFF = 0x168        # newmsgid 在 x19 结构体内的偏移


def _wechat_base(target):
    for m in target.module_iter():
        if DYLIB in str(m.GetFileSpec()):
            return m.GetObjectFileHeaderAddress().GetLoadAddress(target)
    return None


def bp_cb(frame, bp_loc, internal_dict):
    """断在 str 的下一条：写回真 newmsgid，设读 watchpoint，自动继续。"""
    thread = frame.GetThread()
    process = thread.GetProcess()
    target = process.GetTarget()

    x0 = frame.FindRegister("x0").GetValueAsUnsigned()    # 真 newmsgid
    x19 = frame.FindRegister("x19").GetValueAsUnsigned()  # 结构体基址
    addr = x19 + FIELD_OFF

    # 1) 把真 newmsgid 写回 [x19+0x168]，让下游删除真的发生
    err = lldb.SBError()
    process.WriteMemory(addr, x0.to_bytes(8, "little"), err)
    if err.Fail():
        print("[hunt] 写回 newmsgid 失败: %s" % err.GetCString())
        return False

    # 2) 对该字段设「读」硬件 watchpoint —— 删除逻辑读它时命中
    werr = lldb.SBError()
    wp = target.WatchAddress(addr, 8, True, False, werr)  # (addr,size,read=True,write=False)
    if wp is None or not wp.IsValid():
        # 某些 lldb 版本参数序为 (addr,size,read,modify)；再试一次 access 型
        werr2 = lldb.SBError()
        wp = target.WatchAddress(addr, 8, True, True, werr2)
    if wp is not None and wp.IsValid():
        wid = wp.GetID()
        print("[hunt] newmsgid 已写回 0x%x @ struct+0x168 (0x%x); 读 watchpoint id=%d 已设。"
              % (x0, addr, wid))
        print("[hunt] 现在每次停下请执行 `bt` 并把输出发回；然后 `c` 继续。")
        # 命中时自动打印 bt（仍会停下，等你 copy 后手动 c）
        ci = target.GetDebugger().GetCommandInterpreter()
        res = lldb.SBCommandReturnObject()
        ci.HandleCommand('watchpoint command add -o "frame info; bt" %d' % wid, res)
    else:
        print("[hunt] watchpoint 设置失败: %s" % werr.GetCString())
        print("[hunt] 手动兜底：`watchpoint set expression -w read -s 8 -- 0x%x` 然后 c" % addr)

    return False  # 自动继续，让删除路径去读 newmsgid


def _arm(debugger):
    target = debugger.GetSelectedTarget()
    if not target or not target.IsValid():
        print("[hunt] 没有 target —— 先 attach 到 WeChat 再 import 本脚本。")
        return
    base = _wechat_base(target)
    if base is None:
        print("[hunt] 未找到 wechat.dylib —— 确认已 attach 到运行中的微信。")
        return
    addr = base + STORE_NEXT
    bp = target.BreakpointCreateByAddress(addr)
    bp.SetScriptCallbackFunction("hunt_delete.bp_cb")
    print("[hunt] 已布防：断点 @ 0x%x  (wechat.dylib base 0x%x + 0x%x)" % (addr, base, STORE_NEXT))
    print("[hunt] 现在用【另一个账号】在【群聊】里发一条消息再撤回。命中后按提示 `bt`。")
    print("[hunt] 提示：所有 bt 输出发回给我；帧地址我会自动换算成 wechat.dylib 内 VA（减 base 0x%x）。" % base)


def __lldb_init_module(debugger, internal_dict):
    _arm(debugger)
