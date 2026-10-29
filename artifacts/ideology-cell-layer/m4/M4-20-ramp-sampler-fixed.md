# M4-20 修复分片路径的 ramp 缺陷：job 现在真正求值 metric ramp

| 项目 | 内容 |
|---|---|
| 里程碑 | [M4](../22-cell-program-cap-removal-plan-v3.md) §15.5 / §14.3 |
| 日期 | 2026-10-27，Asia/Hong_Kong |
| 结果 | **job 接上 ramp sampler**；单测 **67 / 0**；全回归 **17 / 17** |
| 结论 | M4-19 遗留的真实回归已修 |

## 1. 缺陷是什么

M4-19 的 job 构造：

```cpp
new DerivedCellMaterializeJob(..., DerivedMaterializeOptions{})   // 空 options
```

单发路径在 `ideology_runtime.cpp:6980` 装有 `options.ramp_sampler = &sampler`，而 job 传的是空结构。

**后果：分片路径上每一个 ramp 项都被 defer 而非求值** —— 24 个 kind-12 ramp 卡会「贡献 0」而没有任何报错。

## 2. 为什么不能直接复用单发路径的 sampler

单发路径的 sampler 是**按引用捕获局部变量的 lambda**：

```cpp
sampler = [this, &country_metric_cache, &ramp_samples_taken, ...](...) { ... };
```

`&country_metric_cache` 等是函数栈上的局部变量。job 跨 step 存活，捕获悬空引用就是未定义行为。

**所以采样状态必须是成员。**

## 3. 修法

新增成员 + 一个幂等的构建函数：

```cpp
std::unordered_map<uint64_t, double> _derived_ramp_country_cache;
std::vector<int64_t> _derived_ramp_metric_scratch;
int32_t _derived_ramp_samples_taken = 0;
int32_t _derived_ramp_samples_memoised = 0;
DerivedRampSampler _derived_ramp_sampler;
void ensure_derived_ramp_sampler();
```

lambda 改为捕获 `this`，状态全部来自成员。job 构造时：

```cpp
DerivedMaterializeOptions job_options;
_derived_ramp_country_cache.clear();
if (_economy_runtime != nullptr) {
    ensure_derived_ramp_sampler();
    job_options.ramp_sampler = &_derived_ramp_sampler;
}
```

报告也导出了 `ramp_samples_taken` / `ramp_samples_memoised`，让「求值 vs defer」可观测。

## 4. 验证：为什么不靠 GDScript 夹具

我先在 B7 里加了一个 metric-ramp 子夹具（`salt_monopoly`），结果：

```
[B7] ramp card: locations=[0] levels=[0] front=0 seen=0 derived=0
```

**卡没被装备**，三个 ramp 计数器全为 0——那是夹具问题，不是产品缺陷，且无法区分「未装备」与「被 defer」。

所以在**内核层**验证，绕开装备流程：

新增 `L` 组 7 条断言（`derived_layer_rebuild_test` 60 → **67 checks**）：

| 断言 | 意义 |
|---|---|
| `L: NO ramp term is deferred when a sampler is supplied` | **直接钉住本轮的缺陷** |
| `L: every cell evaluated its ramp`（== 3）| 逐格求值 |
| `L: cell 2 magnitude` / `L: cell 6 magnitude` | **不同格得到不同幅度**，证明不是常量折叠 |
| `L: the sharded ramp build succeeds` | 零预算多步下仍正确 |

零预算（`fold_step({program}, 0.0)`）是刻意的：**续跑路径正是 options 丢失的地方**。

## 5. 回归

| fixture | 结果 |
|---|---|
| B7 / B8 / B10 | 14/0、18/0、16/0 |
| x1b_source_count | 142/0 |
| tag_snapshot_stress | 38/0 |
| cell_layer catalog/numeric/ramp/ramp-mat/adr02/merge/scope-union/unbounded | 9/7/13/12/19/20/20/1 全 0 |
| tag_source_selector / target_selector / effect_instance / content | exit 0 |

**PASS = 17，FAIL = 0。**

`x1b` 的 `_settle_ideology` 也加了 `drain_derived_cell_layer(day)`，让它读到的层是完整的。

## 6. 局限

- **端到端（真实 epoch 下 24 个 ramp 卡的数值）仍未验证**：B7 的 metric-ramp 子夹具没装备成功，`locations=[0]`；需要查清那个子夹具为何装备失败。
- 内核层已证明 job 会求值 ramp，但「生产链路上某张 ramp 卡真的产生非零贡献」没有直接证据。
- `tag_build_ms` 仍 34.92 ms（全量重建）。
- 峰值内存、B5、release DLL 未测。

## 7. 交付物

| 文件 | 说明 |
|---|---|
| `ideology_runtime.h/.cpp` | 5 个 ramp 成员 + `ensure_derived_ramp_sampler()` + job 接线 + 计数器导出 |
| `derived_layer_rebuild_test.cpp` | 67 checks，含 L 组 ramp 断言 |
| `ideology_b7_wide_territory_test.gd` | ramp 子夹具与诊断（未成功，如实保留）|
| `ideology_x1b_source_count_test.gd` | 每日 drain |
