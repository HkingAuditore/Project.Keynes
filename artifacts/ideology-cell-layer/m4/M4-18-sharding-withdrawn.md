# M4-18 分片物化：我的实现是假的（必须撤回声明）

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.3 / §15.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **分片未真正生效**；性能改善来自别处，判定作废 |
| 结论 | 必须撤回上一轮「0.6306 ms PASS」的声明 |

## 1. 我做错了什么

我实现了 `step_derived_rebuild`，并报告 6400 格从 1.2833 ms 降到 0.6306 ms。

**实际上分片没有生效。** 核心代码：

```cpp
std::vector<DerivedProgramContribution> slice;
while (_derived_rebuild_index < _derived_rebuild_accumulator.size()) {
    slice.push_back(_derived_rebuild_accumulator[_derived_rebuild_index]);
    ++_derived_rebuild_index;
    if (elapsed_ms(started) >= DERIVED_REBUILD_STEP_BUDGET_MS) break;
}
...
build_derived_cell_front(_derived_rebuild_accumulator, ...);   // ← 用的是全集，不是 slice
```

**`slice` 从未被使用。** 循环只是把时间花在死拷贝上，最后的构建仍然是**全量一次做完**。

那个 0.6306 ms 是「全量构建 + 若干次无用拷贝」的耗时，不是分片后的单步成本。数值变小是因为我同时把 `+=` 改成了 `max()`——**字段语义变了，读数自然不同**，与分片无关。

## 2. 这造成了什么后果

### 2.1 B10 从 16/0 退化到 16/1

```
[B10] derived front cells=3200 stat_count=2    ← 之前是 6400
[B10] countries=[4294967296]                   ← 只有第一个国家
```

分片路径装出来的 front **只包含第一个国家**。

### 2.2 诊断数据（这一步是对的）

```
rows=2  ideas=2  delta_a=1600  delta_b=1600  collect=3200
```

**收集完全正确**：两国各 1600 个 contribution，合计 3200。问题在折叠/安装阶段。

`build_derived_cell_front` 收到 3200 个 contribution（每国 1600 格 × 1 contribution），
应该产出 2 stat × 3200 格 = 6400 行，实际只产出 3200 行且只含国家 A。

**这说明 `DerivedCellFront` 的 stat 行被后写的国家覆盖了** —— 与我重建 materializer 时
`builder.add` 的 `_row()` 逻辑有关，不是分片造成的。

### 2.3 但我不能确定

因为单发路径（`rebuild_derived_cell_layer`）在 M4-15 时能产出 6400。区别在于：
- 单发路径：`std::vector<DerivedProgramContribution> derived;` 局部变量
- 分片路径：`_derived_rebuild_accumulator` 成员变量

**两者内容应当相同（`collect=3200` 证明收集量一致）**，但折出来的行数不同。

## 3. 我现在的判断

**我不应该继续叠代码。** 已经连续两轮在这里出错：

| 轮次 | 我的声明 | 实际 |
|---|---|---|
| M4-16 | `rebuild_ms` 3.52 ms，门槛 FAIL | 读错累积字段 |
| M4-17 | 更正为 collect+materialise 拆分 | 拆分正确 |
| **M4-18** | 分片后 0.6306 ms PASS | **分片是假的** |

**模式是同一个：我用一个未经验证的数字支撑结论。**

## 4. 必须撤回的声明

| 声明 | 状态 |
|---|---|
| 「6400 格 materialise 降至 0.6306 ms」 | **撤回**（字段语义变了，不是分片效果）|
| 「分片物化已完成」 | **撤回**（`slice` 从未被使用）|
| 「§14.3 门槛 PASS」 | **撤回**（未验证）|

**仍然成立的是 M4-17 的拆分数据**（collect / materialise 分别计时），因为那两个字段的计算是独立的、可复核的。

## 5. B10 的退化是真缺陷

`front cells=3200`、`countries=[A]` 是实际观测，需要修。但**根因在折叠/安装，不在分片**。

## 6. 下一步（正确定义）

1. **先让 B10 回到 16/0**：查清为什么 3200 个 contribution 只折出 3200 行而非 6400 行；
2. **再谈分片**：真正的分片需要把 `builder` 状态跨 step 保留（`DerivedCellFrontBuilder` 不是可续跑的），这是一个设计问题，不是接线问题；
3. **不要再用单一读数支撑门槛判定**——两次都错在这里。

## 7. 教训

**「我加了一个循环」不等于「分片生效」。** 我应该在写完后立即验证 `slice` 被使用、
以及 6400 格仍产出 6400 行——而不是看到一个更小的耗时数字就宣布成功。
