# issue #1038 里大家到底卡在哪

「版本和我不一样」的用户，在打补丁流程上会依次撞三堵墙。下图把每个人卡的位置画在同一条链上——注意**三堵墙是三个不同的问题**，别混为一谈。

```mermaid
flowchart TD
    U["用户装的微信构建号 ≠ 维护者的 269136<br/>例：xiucz 269111 / wuliyc 269110 / Air2018 269111"] --> Q1{"你的构建号<br/>已经在 config.json 里?"}

    Q1 -->|"否（269110/269111 原本没有）"| W1["🧱 墙1 · 版本墙<br/>patch 报 Unsupported version"]
    W1 --> F1A["旧办法：人肉逆向找 addr<br/>要会读 ARM64 汇编 → 多数人卡死在这"]
    W1 --> F1B["新办法：python3 tools/locate_revoke.py --append<br/>自动扫不变签名算出 addr、写进【本地】config.json"]

    Q1 -->|"是"| Q2
    F1B --> Q2{"patch 真正读到的 config<br/>里有你的构建号吗?"}

    Q2 -->|"否 · 旧默认拉【远程 master】<br/>看不见你本地刚加的版本"| W2["🧱 墙2 · 路径墙<br/>本地加了也没用，仍报 Unsupported<br/>（commit 6111506 修的就是它）"]
    Q2 -->|"是 · 修复后默认【本地优先】<br/>读到 --append 加的条目"| M["✅ 版本匹配、addr 命中"]

    M --> Q3{"sudo 能写进<br/>Resources/wechat.dylib 吗?"}
    Q3 -->|"能"| OK["✅ 打补丁成功 → 重签名 → 防撤回生效"]
    Q3 -->|"不能"| W3["🧱 墙3 · 写入墙<br/>You don't have permission to save…<br/>xiucz 现在卡这，尚未解决"]

    style W1 fill:#f8d7da,stroke:#c00
    style W2 fill:#f8d7da,stroke:#c00
    style W3 fill:#f8d7da,stroke:#c00
    style F1B fill:#cce5ff,stroke:#004085
    style M fill:#d4edda,stroke:#28a745
    style OK fill:#d4edda,stroke:#28a745
```

## 三堵墙对照（差在哪、谁碰上、解没解）

| | 墙1 · 版本墙 | 墙2 · 路径墙 | 墙3 · 写入墙 |
|---|---|---|---|
| **报什么** | `Unsupported version` | `Unsupported version`（同报错、不同根因） | `You don't have permission to save "wechat.dylib"` |
| **根因** | 你的构建号地址全变、config 里没有它 | patch 默认去读**远程 master**，看不见你**本地** `--append` 加的版本 | sudo 下仍写不进 `/Applications` 里的 dylib（macOS 保护 / 文件标志之类） |
| **发生时机** | 一开始就撞（版本对不上） | 加了本地条目、以为该好了，却还报同样的错 | 版本已匹配、addr 已命中，倒在最后写入 |
| **谁碰上** | 所有非 269136 用户（xiucz/wuliyc/Air2018…） | 任何按 README「本地加条目」流程走的人 | xiucz（269111，版本已对） |
| **解了吗** | ✅ `locate_revoke.py` 自动定位，无需会汇编 | ✅ commit 6111506 改默认**本地优先**读 config | ❌ 独立问题，写入权限层，尚未定位根因 |

## 一句话总结

- 墙1、墙2 是**同一句报错的两个不同原因**，最容易被搅混——「我明明把地址加进去了怎么还 Unsupported」= 墙2，不是你 addr 抄错。两墙现在都通了。
- 墙3 是**另一层**（文件写入权限），跟版本、跟 config 路径都无关；xiucz 现在就卡这，需要单独查。

> 数据来源：269136 = 维护者构建（config.json）；269110 addr=450a128（wuliyc 逆向）、269111 addr=450a144（wh5a 跑 locate_revoke.py 所得），均见 issue #1038 评论。写入墙报错文本引自 xiucz 评论 5010657440。
