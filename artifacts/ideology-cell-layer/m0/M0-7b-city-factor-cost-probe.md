# M0-7b city-factor cost probe — findings

| 项目 | 内容 |
|---|---|
| 里程碑 | [M0](../22-cell-program-cap-removal-plan-v3.md) §14.1 / §15.2 task 7 |
| 日期 | 2026-10-26，Asia/Hong_Kong |
| 探针 | `Project/project-keynes/tests/ideology/ideology_cell_layer_m0_city_factor_probe.gd` |
| 日志 | `city_factor_probe.log` / `city_factor_probe.stderr.log` |
| 机器 | i9-13900K / 127.6 GB / debug DLL `1d0eba7a…` |
| 结论 | **§14.1 的 `covered_cells × 156` 模型不完整**；真正的冷建主导项是 `地图格数 × 155` 次 int32 写 |

## 1. 动机

§14.1（M0 修订后）引入 `covered_cells × 156`，但**没有每格成本常数**，所以 B7 的「单国 1000 格」仍然只是一个乘积符号，不是预算数字。

`refresh_city_modifier_factors` 没有对外可调用的入口：它只在 `capture_country_epoch`（`economy_runtime.cpp:5530`）内部运行。因此探针走真实 epoch open，并从 DETAIL 报告读运行时已经埋好的 `epoch_begin_city_factor_ms`（`economy_runtime_diagnostics.cpp:1654`）。

## 2. 夹具与作用域

- 真实 `ModifierCatalog`（`load_default().compile_native_catalog()`），非合成。
- 真实 `configure_economy`，需要 `scripts/economy/economy_catalog.gd` 编译的 country IR（用 modifier catalog 会失败于 `country_tax_catalog_empty`）。
- 每个被覆盖格插入一条 GROUP scope 的 `economy.city.birth_factor` 行——该 stat 在 `_city_factor_stat_ids_scratch` 里（`economy_runtime.cpp:7003`），所以会进入 `collect_scope_ids` 的答案。
- 每档 3 次重复取中位数；报告噪声底。

### 2.1 有效性门禁（重要）

首版探针在 `covered=8` 时给出 `0.375 ms`、`covered=512` 时 `0.401 ms`——一条几乎水平的曲线，看起来像「每格成本 ~0」。为了避免把仪器噪声当成结论，加了三条门禁：

| 门禁 | 目的 |
|---|---|
| 断言待覆盖格的行**实际可读**（`evaluate_modifier_stat != 1.0`） | 防止行根本没提交成功，测到一个空循环 |
| 断言 `epoch_active` 或 `epoch_begin_city_factor_ms > 0` | 防止 epoch 没开，读数恒为初始值 |
| 计算**同一 N 内 3 次重复的极差**作为噪声底 | 防止把抖动当斜率 |

三条都通过后才输出数字。这一层是必要的：没有它，第一版会输出 `per_query = 0.3 ns`（比一个 CPU 周期还快），而那个数会被当成真实的每查询成本写进预算。

## 3. 结果

### 3.1 覆盖率对照（地图固定 2048 格）

| covered | 中位数 ms | 3 次重复 |
|---:|---:|---|
| 8 | 0.398 | 0.4034 / 0.3526 / 0.3980 |
| 32 | 0.530 | 0.5297 / 0.4346 / 0.8289 |
| 128 | 0.432 | 0.4316 / 0.3326 / 0.4435 |
| 512 | 0.363 | 0.3627 / 0.3459 / 0.4674 |

`d_ms = -0.035`（首次）/ `+0.062`（24 次运行）跨 `d_cells = 504`，噪声底 `0.148–0.394`。

**斜率不可分辨。** 64 倍的覆盖变化没有产生可测的耗时变化。

### 3.2 地图规模对照（覆盖率固定 32）

| map_cells | 中位数 ms | 3 次重复 |
|---:|---:|---|
| 512 | 0.180 | 0.1850 / 0.1751 / 0.1804 |
| 2048 | 0.418 | 0.3738 / 0.4420 / 0.4181 |
| 8192 | 1.790 | 1.6423 / 1.7903 / 2.2995 |

`d_ms = 1.610` 对应 `d_map = 7680` → **`per_map_cell ≈ 0.00021 ms`**。

信号 1.610 ms 是噪声底（最大 0.394 ms）的 4 倍，单调递增。**这一项是确定的。**

## 4. 为什么成本由地图决定

`refresh_city_modifier_factors`（`economy_runtime.cpp:6980`）在看 `collect_scope_ids` 之前，先执行：

```cpp
const bool shared_changed = !_epoch_city_factor_valid || !shape_valid ||
    shared_birth != _city_factor_shared_birth_q16 ||
    shared_needs != _city_factor_shared_needs_q16 ||
    shared_goods != _city_factor_shared_goods_q16;
if (shared_changed) {
    _epoch_cell_birth_factor_q16.assign(cells, shared_birth);
    _epoch_cell_need_consumption_factor_q16.resize(cells * need_count);
    _epoch_cell_good_consumption_factor_q16.resize(cells * good_count);
    for (size_t cell = 0; cell < cells; ++cell) paint_shared(cell);   // :7061
}
```

`paint_shared`（`:7048-7056`）每格写 `1 + need + good = 1 + 20 + 134 = 155` 个 int32。
2048 格 = **317,440 次写**；8192 格 = 1,269,760 次写。

而 `shared_changed` **每个 epoch 都为真**：`clear_epoch_metrics()`（`economy_runtime_epoch.cpp:894`）在 `start_epoch` 早期就被调用，它重置 `_city_factor_shared_*`，所以下一次比较必然不等。

这不是 bug，是当前设计的一个结构性成本：为了让「共享行」在每格都有物化副本，每 epoch 重画一遍全矩阵。

## 5. 对方案 §14.1 的修正（已落地）

正确模型（**经 M0-7c 真实世界实测收窄**）：

```
shared 行变化的那一次 : ≈ max(covered_cells × 156 次查询, map_cells × 155 次写)
稳态（shared 不变）   : ≈ covered_cells × 156 次查询   （map 项不出现）
```

| 场景 | 覆盖率项 | 地图项 | 主导 |
|---|---:|---:|---|
| 小国 32/6400 格 | 4,992 | 992,000 | **地图**（仅在 shared 变化那次） |
| 单国 1000/6400 | 156,000 | 992,000 | 同上 |
| 单国全国 6400/6400 | 998,400 | 992,000 | 相当 |
| 64 国 × 12 卡全国覆盖 | 63.9M | 1.0M | **覆盖率** |

### 5.1 收窄依据：真实世界实测差 139 倍

M0-7c 在真实生产世界（60×40 = 2400 格、正式多国开局、无理念卡）上测得稳态
`epoch_begin_city_factor_ms` = **0.003 ms**。

本探针在同一量级地图（2048 格）上测得 **0.418 ms**。

差 **139 倍**。原因：本探针为了让 `collect_scope_ids` 有内容，往每个被覆盖格插入了 GROUP scope 的 `economy.city.birth_factor` 行；每插一次都让 `shared_changed` 为真，于是每次都重画全矩阵。真实世界开局没有理念卡，`shared_changed` 为假，走 `else` 分支只重画 `_city_factor_dirty_cells`（空）。

**所以 `map_cells × 155` 是「shared 行变化那一次」的成本，不是每 epoch 的成本。** 本报告 §3.2 的地图斜率测量是正确的——它确实测到了重绘——但不能被读成稳态成本。这一点在 M0-7b 原始结论里没有说清，由 M0-7c 纠正。

**绝对毫秒数（0.00021 ms/格）只对「shared 变化」这一情形有效**，不可用于稳态预算。


## 6. 对本迁移的三个直接含义

### 6.1 「取消 cap 会不会变慢」的答案变了

慢的部分**早已存在且与 cap 无关**。小国在 32 格时代就在付 `map_cells × 155` 的重绘成本；取消 cap 只是让它开始付 `covered_cells × 156`——而在小国上后者仍小于前者。

### 6.2 M1 若只优化覆盖率项，会测不出改善

如果 M1 按 §14.1 的原模型做预算，并在小国上验收，会看到「优化前后无差异」并误判优化无效。**必须先按 §5 的两项模型建立基线，再谈改善。**

### 6.3 真正的降本手段是消除全矩阵重绘

shared 行只在 GLOBAL/ENTITY(0) 变化时需要更新；当前每 epoch 无条件重画。让它「发布一次、按版本失效」就能把 `map_cells × 155` 降到接近 0。

**这是独立于本迁移的优化**，但它会显著改变 §14.3 的所有门槛数值，因此必须在 M1 定预算之前决定：是把它纳入 M1 范围，还是先按现状测门槛再单独优化。

已登记为进度清单的 M1 前置决策项。

## 7. 局限（必须随结论一起引用）

- **探针用的是合成 bootstrap**（每格 1 个 `gathering_ground` 建筑、1000 人口、`forager|default` 签名、全图同签名）。真实世界有 400 种建筑类型、20 个 need、134 个 good 的稀疏分布，**绝对毫秒数不可外推**。
- 只测了 debug DLL。release 会显著更快，比例关系未必相同。
- `epoch_begin_city_factor_ms` 是运行时自己的埋点，包含 `refresh_city_modifier_factors` 与 `refresh_city_output_modifier_factors` 两段（`economy_runtime.cpp:5530-5532`），**未分离**。§5 的 155 次写只属于前者；后者的 `covered × 134` 混在同一读数里。
- 未测 `_building_factor_refresh_ms`（另一个已知成本点）。
- **没有测出 B7/B8/B9 的 p95/p99、峰值内存、slice 数**——这些需要真实规模世界夹具，本探针不能提供。
