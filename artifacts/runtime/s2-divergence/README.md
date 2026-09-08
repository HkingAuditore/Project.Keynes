# S2：Climate SHADOW 对拍分叉矩阵

第一份可信的 Climate 对拍数据。S1 之前比较器在数学上不可能通过（两侧哈希函数、
字段集、framing 全不同），所以此前所有 parity 数字都无意义。

## 复现命令

```powershell
$godot = & .\tools\runtime\Resolve-GodotBin.ps1
& $godot --headless --path Project/project-keynes -s tests/climate_parity_probe.gd -- days=30 seed=20260906 label=60x40
```

## 产物

| 文件 | 内容 |
| --- | --- |
| `divergence-matrix-60x40.csv` | stage × canonical 字段矩阵（本次的关键决策产出） |
| `parity-30d-60x40.csv` | 逐日一行：是否比较、是否相等、首差异字段/cell/值 |
| `parity-30d-60x40.json` | 完整报告，含 stage 聚合、被排除字段及其原因 |
| `probe-30d-60x40.log` | probe 完整 stdout |

## 运行参数与结果

固定 60×40（2400 cell）、seed 20260906、30 日。`compared_days=30`、`matched_days=0`、
`forced_days=30`。33 个 canonical 字段中 30 个可比，3 个显式排除并记录了原因。

## stage 级读数

| stage | 可比字段 | 分叉字段 | 首次分叉日 |
| --- | --- | --- | --- |
| PASS_A | 4 | 4 | 1 |
| WIND_AIR | 1 | 1 | 1 |
| SEA_ICE | 2 | 2 | 1 |
| TRANSPIRATION | 1 | 1 | 1 |
| VEGETATION_DYNAMICS | 6 | 6 | 1 |
| CLIMATE_FEEDBACK | 1 | 1 | 1 |
| WEATHER | 7 | 7 | 1 |
| RUNTIME_HYDROLOGY | 7 | 7 | 1 |
| STAGE_B_AFTER_HYDROLOGY | 1 | 1 | 1 |

`PASS_B`、`OCEAN_WATER`、`OCEAN_LAND`、`WIND_SURFACE`、`ALBEDO` 五个 stage 只改写
`temperature`，没有自己的输出字段，因此不单独成行；它们的误差并入 `CLIMATE_FEEDBACK`
的 `temperature`。

## 对 S3 的结论

1. **没有任何 stage 已经等价，14 个 stage 全部需要提取。**"仅 PASS_A 落实"的说法只
   对"用了共享公式层"成立；PASS_A 的四个输出字段仍然第 1 天就分叉，因为共享层只有
   insolation/albedo 一类标量 helper，stage 级算法仍是 worker 自己的一份简化实现。
   因此 S3 不是"补 13 个 stage"，而是"把 14 个 stage 全部改成生产与 worker 共用"。

2. **提取顺序按误差量级而非按 stage 序号。**同为第 1 天分叉，量级差三个数量级：

   - `river_discharge` max_delta 98.4、`river_storage` 15.2、`runoff` 1.10
     —— worker 的 hydrology 占位实现连量纲都不同，属于重写而非对齐。
   - `vapor`/`cloud_cover`/`weather_type` 全 cell 分叉且 delta 达满量程，WEATHER
     stage 同样是重写。
   - `temperature_365d_ema` max_delta 5.5e-3、`temperature_30d_ema` 8.7e-3
     —— PASS_A 的 EMA 已经接近，差的是输入温度与 dt 语义。

   `RUNTIME_HYDROLOGY`（7 字段，量级最离谱）与 `WEATHER`（7 字段，全 cell）是最大
   的两块，合计 14 个可比字段中的 14/30；先做这两个能消掉近一半分叉字段。

3. **`snow_cover`/`snowpack` 只有 4026/72000 个 cell 分叉，`vegetation_heat_stress`
   只有 870 个。**这类"少数 cell 分叉"是条件分支差异（阈值、is_water 判定）而不是
   公式差异，成本远低于全 cell 分叉的字段。

4. **`vegetation_growth_streak` 第 7 天才分叉**，是唯一撑过 6 天的字段：它是整数
   streak，只有在 vitality 判定翻转时才体现上游误差。它证明矩阵的"撑几天"维度是
   有效的，不是所有字段都在第 1 天塌掉。

## 两个必须先解决的表示差异

以下字段被排除在哈希之外，不是容差问题而是两侧存的不是同一个量，S3 需要先决定
以哪一侧为准：

- `weather_transition`：worker 存 `uint8`，`weather_transition_alpha_arr` 是
  `PackedFloat32Array` 的 0..1 混合系数。
- `vegetation_succession_candidate`：worker 存布尔候选标志，
  `vegetation_regen_score_arr` 是连续再生分数。
- `riparian_moisture`：`map_data.gd` 根本没有声明这个数组，生产侧无参照值。

## 本步顺带修掉的两个断点

1. **reference barrier 在生产配置下完全失效（原文档未记录）。**
   `_runtime_climate_reference_ready_for_day()` 只认 `ClimateDailySystem`，而生产走
   native_daily 路径时 `_refresh_climate_daily_job` 永远是 null、
   `_last_climate_breakdown` 永远是空字典，两个条件都不成立，函数恒返回 false。
   后果是 capture 一直入 ring、reference 一次都没发布过：即使比较器修好，worker 也
   拿不到任何可消费帧。现按 owner 分派，native 路径用
   `_native_daily_climate_round_generation` 作为"轮次已到不可变边界"的证明。

2. **catalog hash 丢掉了全部标量 knob。**`_runtime_climate_hash_append()` 的兜底分支
   用 `String(value)`，而 Godot 的 String 构造器拒绝裸 int/float/bool 实参，抛错后
   `hashing.update` 不执行——abi、width、height、cells 以及所有标量系数都没进哈希。
   改为 `str(value)`。

## 一个必须知道的度量前提

对拍失败时 worker 会 `discard_plan()`，`committed_day` 不推进，于是它会用同一天反复
去取 ring 里越来越新的帧，永远取不到 —— **只有第 1 天可测**。为了拿到 30 日矩阵，
新增了诊断开关 `set_runtime_climate_parity_forcing(true)`：分叉日仍记 mismatch，但
提交后把可比字段覆盖为生产参照值，使每一天都成为独立的一步比较。它只是测量模式，
不改变 worker 的非权威性质；`forced_days=30` 记录了它被用了多少次。
