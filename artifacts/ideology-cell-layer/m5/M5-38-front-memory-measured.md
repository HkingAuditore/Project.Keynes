# M5-38 front 内存实测 + 验证脚本抓到首次真实漂移

| 项目 | 内容 |
|---|---|
| 里程碑 | [§18.3](22-cell-program-cap-removal-plan-v3.md) 峰值内存 |
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **front 内存有数字了**（140,912 字节 / 1600 格 × 2 stat）；**验证脚本抓到首次真实漂移** |

## 1. 加的是什么

`get_derived_cell_layer_report()` 新增四个字段：

| 字段 | 含义 |
|---|---|
| `contribution_count` | (stat, cell) 条目数 |
| `contribution_bytes` | `sizeof(DerivedCellContribution)` |
| `bytes_per_contribution` | 4（cell id）+ `contribution_bytes` |
| `front_row_overhead_bytes` | 每行 `sizeof(DerivedCellStatRow)` |
| `front_bytes` | 合计 |

**为什么按结构算而不是采样堆**：堆计数会让数字依赖分配器行为，而这道门禁问的是
「front 本身有多大」。按结构算是确定性的。**并且报告里写明「这是 front 的字节数，不是进程 RSS」**，
免得 140 KB 被读成「整个迁移只要 140 KB」。

## 2. 实测（B7，1600 格单国）

```
[B7] front memory: contributions=3200 bytes/contrib=44 row_overhead=112 total=140912 bytes
=== B7 wide territory: 27 checks, 0 failures ===
```

| 项 | 值 |
|---|---|
| contributions | **3200** = 1600 格 × **2 个 stat**（`public_hygiene_l1` 有两条命令）|
| `sizeof(DerivedCellContribution)` | **40**（不是我以为的 32——`uint32` 后的 padding）|
| bytes/contribution | 44 |
| 行开销 | 112（2 行 × 56）|
| **front 合计** | **140,912 字节 ≈ 138 KB** |

### 我在这条上差点又靠猜

第一版断言写 `contribs == 1600`，实测 3200 就失败了。
**原因不是代码错，是我忘了那张卡有两个 stat。**
断言改为 3200 并写明理由（也顺带解释了 B7 别处 `front cells=3200` 的来源）。

**同一个数字在两个地方出现，必须能互相解释**——现在是了。

### 断言用的是不变量，不是魔数

```gdscript
front_bytes == contribs * per + row_oh
```

四个量都来自运行时自己报告。钉一个绝对数字会在任何布局变化时失效，且不说明记账对不对。
另加一条上限（< 1 MB）防止「每格每 stat 意外存了不该存的东西」。

## 3. 验证脚本抓到首次真实漂移（这才是本轮的重点）

加完内存字段、重建 DLL 后立刻跑校验：

```
VERIFY FAILED (1):
  - the documents claim debug=['e8cbfded758a7da8'] but the file is 0d8c31d669d5007f
```

**从脚本被创建到第一次抓到真问题，只隔了一次代码改动。**

这正是 M5-35 建它的理由——上一轮同类漂移是**靠人手工读二进制**才发现的。

处置：重建 release（`83cf8c0483377eab`）、更新三处记录。

## 4. 顺带补上验证脚本的一个盲区

方案的 §18.5 证据表是这一行：

```
| 18.4 | debug/release 构建… | debug `e8cbfded…`、release `ed583385…`；… |
```

它的首列是 `18.4`，不是 `debug`，所以原来的判定规则**看不见它**——而它正是当前身份声明。

已加第二条规则：**一行里同时出现 debug、release 和两个哈希，就是当前声明**（不管首列是什么）。
历史哈希计数因此从 12 降到 10——那 2 个被正确重新归类。

## 5. 最终验证

```
=== fixtures (debug) ===    11 个全 OK（B7 已升到 27）
=== fixtures (release) ===
B5 9/0、B7 27/0、B11 9/0、oracle 19/0、x1b 142/0、content 67/0、x9b 22/0
debug build restored (0d8c31d669d5007f)
VERIFY OK
```

## 6. 当前身份

| DLL | SHA256 前 16 |
|---|---|
| debug | **`0d8c31d669d5007f`** |
| release | **`83cf8c0483377eab`** |

## 7. 局限（§18.3 这条仍是「部分」）

| 项 | 状态 |
|---|---|
| **front** 字节数 | ✅ 有数字 |
| **candidate / retained / scratch** | ⬜ 无证据 |
| **分配次数** | ⬜ 无证据 |
| **backlog** | ⬜ 无证据 |

所以 §18.3 的内存条目从「未测」改为「**部分**」，不是「已测」。

## 8. 交付物

| 文件 | 说明 |
|---|---|
| `gdext/src/world_ext_modifier.cpp` | 报告新增 5 个内存字段 |
| `Project/project-keynes/tests/ideology/ideology_b7_wide_territory_test.gd` | 4 条内存断言（含不变量 + 上限），27 checks |
| `Project/project-keynes/tools/ideology/verify_delivery.py` | 配对行判定 + B7 期望 27 |
| `docs/cpp-dots-runtime/native-ideology-runtime.md` | 字段说明 |
