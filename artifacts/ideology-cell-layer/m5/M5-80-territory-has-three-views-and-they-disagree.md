# M5-80 领土有**两个视图**，它们会分歧 —— 48 次认领被接受，而「最宽国家」仍是 1

| 项目 | 内容 |
|---|---|
| 触发 | 复盘 `ideology_d4_multi_cell_country_test` 的唯一失败 + 读 `sync_country_territory_to_map()` 的实现 |
| 事实 | **认领生效了，但被读的那个视图不跟着变** |
| 日期 | 2026-10-28，Asia/Hong_Kong |

## 1. 实测

我自己的探针（`ideology_d4_multi_cell_country_test.gd`）打出：

```
[d4] claim attempts: accepted=48 rejected=22
[d4] FAIL E: a real generated world now has a country ABOVE the old 32 cap
     widest=1 above_old_cap=0 (was 1 / 0)
```

**48 次认领被接受，最宽的国家仍然是 1 格。**

拒绝的 22 次是 `country_claim_target_not_unowned`（`country_runtime.cpp:3186`）——**目标必须是「无主」**，
所以只能认领相邻的无主格，不能抢别国的。

## 2. 为什么：领土有两个**互不同步**的视图

| 视图 | 谁写 | 谁读 |
|---|---|---|
| **国家 CSR** | 认领命令（`rebuild_cell_csr()` 从 CSR 偏移重算 `territory_count`，`country_runtime.cpp:3886-3899`）| `cell_country_snapshot()` |
| **地图槽位** `cell_country_slot` | **`sync_country_territory_to_map()`**（`world_ext_country.cpp:1880-1910`）| 地图 / 渲染 |
| **经济领土平面** | 经济侧自己的链路 | **`get_country_territory_counts()`**、`get_economy_territory_plane()` |

**`sync_country_territory_to_map()` 做的是「runtime → 地图」**：

```cpp
const PackedInt32Array snapshot = runtime->cell_country_snapshot();
write_i32_range(slot, 0, snapshot);
_flush_slot_to_map(slot);
```

**它不碰经济平面。** 而 `get_country_territory_counts()` 读的正是**经济快照**。

## 2.5 ⚠️ 更正：真正的原因是**三道闸**，不是「三个视图分歧」

我写上面那段时只查了 `sync_country_territory_to_map()` 的实现，结论**不够准**。
随后一个夹具把路径走通了，实测出**三道各自独立的闸**，缺一道就看不到变化：

| # | 闸 | 缺了会怎样 | 证据 |
|---|---|---|---|
| **1** | **认领要提交**：`COMMAND_TRANSFER_TERRITORY = 3` 经 `submit_country_commands`，再由 `run_country_slice` 提交 | 归属列不变 | `country_runtime.cpp:3172-3210`、`:3815 rebuild_cell_csr()`、`:3886-3915` |
| **2** | **读的是副本**：`get_country_cell_summary()` 服务 `country_query_runtime()`，**只有 `capture_country_runtime_snapshot()` 发布后才更新** | **已提交的认领不可见** ← **这才是 D4「48 次接受仍 widest=1」的原因** | 实测：加上这一步后 `widest` 立刻变 2 |
| **3** | **经济平面是冻结的 epoch**：`get_country_territory_counts()` 读 `_epoch_cell_country`，只在 **epoch 开启时**由 `capture_country_epoch()` 冻结（`economy_runtime_epoch.cpp:917`） | **认领 + sync 之后仍是 `widest=1`** | 只有 `run_economy_slice(day 0)` → `(day 1)` 之后才变 **44** |

**关键**：派生层的 kind-12 目标选择器读的是**同一个 epoch 平面**
（`economy_runtime_family_buff.cpp:2450-2537`），所以**第 3 道闸是派生层能不能看见这片领土的前提**。

**所以准确的说法不是「三个视图分歧，是潜在缺陷」，而是**：

> **两个不同时刻的冻结快照，唯一的调和方式是开一个新 epoch。**
> **认领一直是对的，是读者读的是旧 epoch。**

## 3. 所以这是一处**语义陷阱**（而不是我先前说的缺陷）

**同一个事实（谁拥有哪些格）有三个视图，而最常被测试读的那个是滞后的。**

后果：

| 后果 | 说明 |
|---|---|
| 认领看似无效 | 48 次接受、计数不变——**开发者会以为是认领失败** |
| 派生层覆盖与领土计数**可能不一致** | 层跟 CSR 走，计数跟经济走 → **两者对不上时报错方向会误导** |
| 本方案的 `>32 生产样例`**因此拿不到** | 不是生成器只给 1 格，而是**给了也看不见** |

**注意这条比我上一轮的结论更准确**：M5-79 说「真实地图每国 1 格」，那是**初始**状态的事实；
而这里说的是**即使认领，`widest` 也不会变**。**两条都要成立才能解释现状。**

## 4. 修复方向（我没有动）

| 方向 | 说明 |
|---|---|
| **A. 让 `get_country_territory_counts()` 读 CSR** | 一处改动，但它会改变所有依赖「经济快照」语义的调用者 |
| **B. 认领后自动同步三个视图** | 在认领命令里串起 CSR → 地图 → 经济平面；改动在命令侧 |
| **C. 只加一个「三者一致性」报告字段** | 不改变语义，先让分歧**可见**。最小风险 |

**C 是我倾向的第一步**——本项目已经五次出现「读一个字段，以为是另一个」的坑
（`_cell_layer_rebuild_visits`、`contribs_passed`、basis 四项、`rebuild_skips`、`command.source_id`），
**先让分歧可观测，再决定改哪个语义**。

## 5. 与本方案判据的关系

方案要求「首个正确 >32 生产样例」。**在三个视图互不同步的前提下，这个样例不可达**——
不是因为地块层有问题，而是因为**没有可信的「国家有多少格」这个输入**。

**所以 §18 的 14/12/2 里那条阻塞的准确描述应该是**：

> 「>32 生产样例」受阻于**领土视图分歧**（认领已生效但计数视图滞后），
> 叠加**初始地图每国 1 格**；两者都在领土/经济链，不在理念地块层。

**这比「被外部阻塞」具体得多，也指出了真正的下一步。**
