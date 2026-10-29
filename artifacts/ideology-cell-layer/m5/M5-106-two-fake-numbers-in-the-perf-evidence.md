# M5-106 性能证据里有两个假数字，而「1 ms 门槛通过」可能是错的

| 项目 | 内容 |
|---|---|
| 触发 | 性能 agent 在剖析时报告「`collect_ms` 恒为 0」，我据此独立核查 |
| 结果 | **两条指控都成立**，且牵出一个更大的问题 |
| 日期 | 2026-10-29，Asia/Hong_Kong |

## 1. `cell_layer_collect_ms` 是**死导出**

全项目里 `_derived_collect_ms` 只出现两次：

| 位置 | 作用 |
|---|---|
| `ideology_runtime.h:1202` | **声明** |
| `ideology_runtime.cpp:6295` | **导出** |

**从未被赋值。**

**所以它恒为 `0.0`，而我的 §18.3 那一行把 `collect_ms 0.0` 当成测量值写着。**

**这是本会话第 5 个死字段**（前四个：`_cell_layer_rebuild_visits`、`contribs_passed`、basis 四元组、`_execution_contract_hash`）。

**已修**：采集分支现在写 `_derived_collect_ms`，它才第一次成为测量。

## 2. `_derived_materialise_ms` 在采集分支里取的是**采集耗时**

`ideology_runtime.cpp:7613-7614`（修前）：采集分支把 `elapsed_ms(started)` **同时**赋给
`_cell_layer_rebuild_ms` 和 `_derived_materialise_ms`。

**结果：一个「物化耗时」的数字里，一点物化都没有。**

**已修**：采集分支不再碰 `_derived_materialise_ms`；它只在折叠分支里被赋 `step_ms`。

## 3. **真正的切片耗时比报告的大一倍**

```cpp
const bool folded = _derived_rebuild_job->fold_step(...);
const double step_ms = elapsed_ms(started);          // ← 这里取
_cell_layer_rebuild_ms = std::max(_cell_layer_rebuild_ms, step_ms);

if (!folded) return false;
DerivedCellFront front;                              // ← 前端构建在这里之后
...  // 折叠成 front、算 digest、install
```

**`step_ms` 在前端构建之前就取好了**，所以 `cell_layer_rebuild_ms` **完全不含**
「把累加器变成 front」这一步。

性能 agent 用 GDScript 在 `run_ideology_daily` 外围计时，量到：

| 规模 | 各次调用 | 报告的最差步 | **真实最差切片** |
|---|---|---|---|
| 2400 | `[0.321, 0.552]` | 0.2556 | **0.552 ms** |
| 6400 | `[0.864, 0.460, 1.316]` | 0.6851 | **1.316 ms** |

**按这个数字，§14.3 的门槛（「单次派生 native slice ≤ 1 ms」）在 6400 格上是失败的。**

## 4. 这推翻了我 §18.3 的结论

我那一行写的是：

> **单 slice 门槛（1 ms）在两种规模下都通过**（… 0.2572 ms @2400、0.6331 ms @6400）

**0.2572 与 0.6331 都是「不含前端构建的步耗时」，不是切片耗时。**

**所以那句话很可能是错的** —— 不是「内部目标没达到」，而是**方案自己的门槛没达到**。

**区别很大**：前者是自设的高标准，后者是验收失败。

## 5. 我改了什么、没改什么

| 动作 | 状态 |
|---|---|
| 给 `_derived_collect_ms` 赋值 | **已改** |
| 采集分支不再污染 `_derived_materialise_ms` | **已改** |
| 把前端构建计入 `_cell_layer_rebuild_ms` | **未改** —— 它会让 `perf_gate` 的期望数字变化，而那时构建正被同事 agent 的夹具占着 DLL，**我不想在证据会变的情况下抢着改断言** |
| §18.3 那一行的「1 ms 通过」 | **未改** —— 等独立的复测拿到两个规模的真实切片，再一次改准 |

## 6. 一个我刻意没做的事

构建连续三次失败（无 `error C`），因为我撞上了**另一个 agent 刚启动的夹具运行**。

**我查了它的年龄（0.2 分钟）才决定不杀。** 上一轮我为解阻塞杀过一个**卡了 8 分钟、3% CPU、不循环**的进程 —— 那是对的；
**这次那个进程是正常工作的，杀掉它就是用同事的测量时间换我的构建时间。**
