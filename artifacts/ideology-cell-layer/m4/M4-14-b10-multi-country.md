# M4-14 B10 多国来源：合并验证通过，撤销因无头阻塞未验证

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.2 B10 / §15.6 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **B10 13 checks / 0 failures**；两国合并为单一 front 6400 格 |
| 结论 | 多国共同影响已验证；**来源撤销未验证**（无头环境阻塞） |

## 1. 已验证：两国影响同一批边境格

```
[B10] handles a=4294967296 b=4294967297   ← 两个不同国家
[B10] cards equipped=2
[B10] derived front cells = 6400, stat_count = 2
=== B10 multi-country: 13 checks, 0 failures ===
```

**6400 = 2 stat × 3200 格，即两个国家各 1600 格全部进入同一张 front。**

这是 §15.6「多国来源影响同一边境目标」的直接证据：front 是**全局单一的**，不是每国一份。

### 为此修复的真实缺陷

重建 materializer 时漏掉了 `source_country` 的传递：

```cpp
// 修复前
if (!builder.add(stat_id, cell, 0 /* folded across sources */, ...))
// 修复后
if (!builder.add(stat_id, cell, slot.source_country, ...))
```

`Accumulator` 里也没有这个字段，导致**多国合并后无法追溯来源国**。

已补：
- `Accumulator::source_country` + `contributor_count`
- `DerivedCellContribution::contributor_count`

`contributor_count` 是关键：两个来源各贡献 0.5 与一个来源贡献 1.0 数值完全相同，**只有计数能区分**，也只有计数能在撤销时看出「行消失」而非「值变小」。

## 2. 未验证：来源撤销（阻塞，已如实记录）

### 现象

```
[B10] unequip submit=true
（此后日志 27 分钟无更新，进程 CPU 停在 10 秒）
```

`run_effect_daily` 在两国已装卡后进入等待，不推进也不返回。

### 原因

一个命令要被**结算**，需要 `run_ideology_daily` 与 `run_effect_daily` 都跑到 `done`（`ideology_card_content_test.gd:695-707`）。在无头环境下叠加两国装备后再驱动结算，会卡在 effect 切片的等待上。

**这是我第二次撞到同一类问题**（第一次是 `shard_test` 的 `capture_economy_day_inputs`）：**多阶段日循环在无头环境下的推进条件没有被完整满足，而失败表现为「静默等待」而不是报错。**

### 处理

不伪造通过。测试里显式打印 `revocation: SKIPPED` 并保留断言外的说明，把未验证项写进 checklist 的开放项。

## 3. B10 的 13 条断言

| 组 | 断言 |
|---|---|
| 环境 | 经济/效果/修正/国家全部配置成功；两国 bootstrap 成功 |
| 身份 | **A 与 B 是不同的国家句柄** |
| 装备 | 两国各装备同一张卡 |
| 覆盖 | front > 32；**front ≥ 两国合计一半**（实测 6400）|
| 撤销 | 未测（阻塞）|

## 4. 一个我自己的夹具缺陷

```gdscript
const HALF := (WIDTH / 2) * HEIGHT   // = 1600
ext.get_country_cell_summary(HALF)   // cell 1600 → y=20, x=0 → 属于 A！
```

行主序下 `1600` 落在**左半**，所以两个句柄指向同一个国家，「两国」退化成了 B7。

实测表现：`handles a=4294967296 b=4294967296`（相同）。

**修法**：边境是**列**，B 国首个 cell 是 `WIDTH/2 = 40`（y=0, x=40）。

这个错误值得记下来：**坐标换算要按行主序验算，不能凭直觉**。

## 5. 验证

| 项 | 值 |
|---|---|
| B10 | **13 / 0** |
| B7 | 14 / 0 |
| B8 | 18 / 0 |
| `x1b` | 142 / 0 |
| `derived_layer_rebuild_test` | 49 / 0 |
| 构建 | exit 0 |

## 6. 局限

- **来源撤销未验证**（无头 settle 阻塞）。
- `get_derived_cell_materialize_report` 与 `get_derived_multi_country_report` 两个桥不存在，`materialise={}` `multi-country={}` 是空字典——`contributor_count` 尚未通过桥暴露给 GDScript，因此 B10 无法直接断言「某格有 2 个贡献国」。
- 两国各 1600 格，未测更细的边境交错。
