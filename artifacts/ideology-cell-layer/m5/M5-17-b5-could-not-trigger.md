# M5-17 B5 空闲门禁：夹具建了，但**无法触发重建**，断言是空洞的

| 项目 | 内容 |
|---|---|
| 里程碑 | [§14 B5](22-cell-program-cap-removal-plan-v3.md)「30 天无相关变化 → 零物化、零安装、零层版本推进」|
| 日期 | 2026-10-28，Asia/Hong_Kong |
| 结果 | **未能验证** —— 夹具里重建从未发生，所以「空闲没做事」不可能被区分 |
| 状态 | 开放，未声称通过 |

## 1. 建了什么

`tests/ideology/ideology_b5_idle_test.gd`：20×20 单国世界，装备 ramp 卡，按 §14 B5 的定义断言：

1. `layer_generation` 在 30 天空闲中不动
2. `cell_layer_rebuild_steps` 不增长
3. `derived_rebuild_pending` 保持 false
4. 层仍安装、仍覆盖（空闲不等于拆掉）

设计里还有一条**负向对照**：先做一次真正改变内容的事，generation 必须动。
没有对照的话，「generation 没变」在一个重建从未发生的夹具上也会「通过」，那证明不了任何事。

## 2. 两次失败的对照，都是我自己写错

| 版本 | 对照做法 | 结果 | 原因 |
|---|---|---|---|
| v1 | 重开 epoch（同一批输入）| gen 1 → 1 | **内容相同 → 不安装、不 bump 是正确行为**（§I13）。用 epoch 变化做对照本身是错的 |
| v2 | 改 metric 57 的 override | gen 1 → 1 | 见下 |

## 3. 真正的发现：这个夹具里重建从未发生

v2 的诊断输出：

```
[B5] add BEFORE override = 0.14991760253906
[B5] add AFTER  override = 0.14991760253906
report = { "installed": true, "layer_generation": 1, "cell_count": 400,
           "stat_ids": [6], "sample_day": 0, "epoch_id": 0 }
```

| 观察 | 含义 |
|---|---|
| override **之前** `derived_add` 已经是 0.1499 | 内容没被我改变，所以 generation 不动是**正确的** |
| **`epoch_id: 0`、`sample_day: 0` 从不变化** | 即使我调了 `begin_or_reuse_economy_input_epoch(1, …)`，front 仍停在 epoch 0 |
| `derived_add` = 0.1499 = 饱和值 `15 × 655 / Q16` | **metric 57 在我 override 之前就已经 ≥ 15**，不是 0 |

结论：**这个夹具里 `step_derived_rebuild` 没有跑过第二次**。于是：

- 「30 天空闲没 bump generation」→ 因为重建一次都没再发生，**断言恒真，不可信**
- 「steps 不增长」→ 实测 `16 → 14 → 15`，**这个计数器不是累积的**，也不能用
- metric 57 已有非零值 → 说明 `country.extractive_cell_count` 在我的 bootstrap 世界里不是 0，
  这本身需要单独确认（我也还没确认它是不是被别的东西填了）

## 4. 为什么这不能算「通过」

**一个在「重建从不发生」的夹具上通过的断言，和在「重建每天发生但内容相同」的夹具上通过，是两件不同的事。**

B5 要证明的是后者。前者是空洞的。

## 5. 需要先解决的前置问题

| # | 问题 | 为什么挡路 |
|---|---|---|
| 1 | `begin_or_reuse_economy_input_epoch(1, …)` 之后 front 的 `epoch_id` 仍是 0 | 说明 epoch 变化没有传到派生层，重建的触发条件在这个夹具里不成立 |
| 2 | `cell_layer_rebuild_steps` 递减（16 → 14）| 它不是累积计数；要么改成累积，要么改用别的量 |
| 3 | `country.extractive_cell_count` 在 bootstrap 世界里的初值未知 | 决定「内容是否变化」的基线，必须先测出来 |
| 4 | **需要一个「内容确实改变且重建确实发生」的对照** | 否则 B5 无法与「从未重建」区分 |

第 4 项是本质的：**没有这个对照，B5 的门禁是假门禁。**

## 6. 顺带确认的好消息

诊断里 `derived_add = 0.14991760253906` = `15 × 655 / 65536`，正是 M5-14 修复后
ramp 卡在 metric ≥ 15 时的正确饱和值。**数值路径是对的**，问题只在 B5 的夹具与对照。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `tests/ideology/ideology_b5_idle_test.gd` | 8 checks / **2 失败**；它是**未通过的诊断**，不是证据 |

## 8. 诚实的结论

**B5 仍未验证。** 我有的是：
- 一份能构造世界并装备卡片的夹具；
- 一份证明「这个夹具里重建从未发生」的诊断。

我**没有**「空闲日不做物化」的证据。`§18.3` 的 B5 条目保持未达成。
