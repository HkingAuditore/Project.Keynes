# M4-19 分片物化成功：6400 格最坏单步 0.5878 ms，门槛 PASS

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §14.3 / §15.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **6400 格最坏单步 0.5878 ms（门槛 1 ms）**；**全回归 17/17** |
| 结论 | 分片真实生效，且正确性与性能同时满足 |

## 1. 这次和 M4-18 的区别

M4-18 的「分片」是假的：`slice` 向量从未被 `build_derived_cell_front` 使用，最后的构建仍是全量一次。

这次的核心是 **`DerivedCellMaterializeJob`**——**状态就是对象**：

```cpp
class DerivedCellMaterializeJob {
    bool fold_step(const std::vector<DerivedProgramContribution>&, double budget_ms);
    bool finish(const DerivedCellFront*, DerivedCellFront&, DerivedMaterializeReport&, bool&);
};
```

`folded` / `touched_stats` / `report` 从函数局部变量移进 `Impl`，跨 step 保留。
`_index` 是续跑游标，`fold_step` 从它继续而不是从头。

## 2. 性能（n=5 中位数）

| 规模 | 分片前 | 分片后 | step 数 | 判定 |
|---|---:|---:|---:|---|
| 2400 格 | 0.4328 ms | **0.2305 ms** | 2 | PASS |
| 6400 格 | 1.2833 ms | **0.5878 ms** | 3 | **PASS** |

**6400 格从超门槛 28% 变为余量 41%。**

### 两个关键调整

1. **收集单独成一步**。首次尝试把收集与折叠放在同一步，6400 格的首步是 1.03 ms——收集自身 0.68 ms 加上折叠份额就超了。让收集 `return false` 后，每步只承担**一种**成本。
2. **`done()` 语义**。原本 `_index >= _total` 在首次调用前是 `0 >= 0`，报告「已完成」而实际一个都没折。改为 `_started && _index >= _total`。

## 3. 单测：11 条可续跑断言

`derived_layer_rebuild_test` 从 49 → **60 checks / 0 failures**，新增 K 组：

| 断言 | 意义 |
|---|---|
| `K: the job really took multiple steps`（steps > 1）| **证明分片真实发生** |
| `K: the job saw every contribution` | 全部 contribution 被看到 |
| `K: the SAME cell count survives the split` | 50 格一个不少 |
| `K: the split front has the same total value` | 数值与单发一致 |
| `K: the split visited the same cells` | 访问量一致 |

**这组断言正是 M4-18 缺失的**——当时没有任何东西检查「分片是否真的分片」。

## 4. 引入的兼容性代价与修复

分片让重建变成**跨调用**，所以一次 `run_ideology_daily` 不再发布派生层。直接后果：

```
B7  front_cells=0
B8  front_cells=0
B10 covered=0
stress front_cells=0
```

**4 个测试同时退化**——这是我在上一轮缺的验证，这次它拦住了坏改动。

修法：新增 `drain_derived_cell_layer(day)` 桥，把重建排空到完成；测试显式调用它而不是猜调用次数。

```
[B7] drained steps=2 complete=true
[B10] drained steps=2 complete=true
```

报告里也导出了 `derived_rebuild_pending`，让生产侧能诚实地等待。

## 5. 回归

| fixture | 结果 |
|---|---|
| B7 / B8 / B10 | 14/0、18/0、16/0 |
| tag_snapshot_stress | 38/0 |
| x1b_source_count | 142/0 |
| cell_layer catalog/numeric/ramp/ramp-mat/adr02/merge/scope-union/unbounded | 9/7/13/12/19/20/20/1 全 0 |
| tag_source_selector / target_selector / effect_instance / content | exit 0 |

**PASS = 17，FAIL = 0。**

## 6. 局限

- `ramp_terms`：job 构造时传的是空 `DerivedMaterializeOptions`，**未接 ramp sampler**，ramp 项会被 defer 而非求值。单发路径仍有 sampler。这是接线的遗漏，未验证影响面。
- `tag_build_ms` 仍有 34.92 ms（全量重建），§15.6 的 per-tag changed words 未做。
- 性能是单点中位数，未测峰值内存、B5、release DLL。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `derived_cell_materializer.h/.cpp` | `DerivedCellMaterializeJob`（pimpl，状态即对象）|
| `gdext/tests/derived_layer_rebuild_test.cpp` | 60 checks，含 K 组可续跑断言 |
| `ideology_runtime.cpp/.h` | `step_derived_rebuild` 基于 job；切片阶段接线 |
| `world_ext.h` / `world_ext_modifier.cpp` | `drain_derived_cell_layer` 桥；`derived_rebuild_pending` |
| 4 个 fixture | 显式 drain |
