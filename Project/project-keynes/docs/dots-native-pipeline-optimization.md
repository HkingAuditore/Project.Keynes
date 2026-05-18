# DOTS Native Pipeline Optimization

## 默认运行模式

本项目的默认 `ClimateProfile` 已切到 `native-normal`：

- `use_data_core = true`
- `use_data_core_weather = true`
- `use_data_core_climate = true`
- `use_world_view_adapter = true`
- `use_soa_pipeline = true`
- `use_sparse_climate = true`
- `use_gdext_slp_field = true`
- `use_gdext_psi_solver = true`
- `use_gdext_stage_b_combined = true`
- `use_gdext_weather_refresh_daily = true`
- `use_gdext_enum_atlas_pack = true`
- `use_partial_atlas_upload = true`
- `sim_strict_budget_enabled = false`
- `sim_frame_budget_ms = 2.0`
- `sim_budget_warn_ms = 2.0`

`earth_like.tres` 原本已覆盖开启关键 native flags；脚本默认值同步后，新建 profile 不再意外退回 legacy/AoS 路径。

## 调度策略

`SUS` 不再把 normal profile 固定为 1ms strict：

- strict profile：每个非上传 job 每 tick 最多 1 个 slice，用于回归和极端保守验证。
- native-normal profile：`refresh_climate_daily` / `weather_refresh` 可在一个 tick 内连续推进多个 slice，由 `sim_frame_budget_ms` 兜底。
- 上传、季节刷新、洋流仍保持单 slice，避免 GPU upload 或 solver 阶段集中造成主线程尖峰。

## Weather 合并事务

`WeatherRefreshJob` 在满足以下条件时启用合并事务：

- `ClimateProfile.use_gdext_weather_refresh_daily == true`
- `DCWorldExt` 已绑定
- `run_weather_field_solve_pass`、`run_weather_distribute_pass`、`run_weather_summary_fronts_pass`、`run_stage_b_pass` 均存在

启用后，weather 不再按 `begin -> solve -> commit` 跨多个 SUS tick，而是直接走现有 `refresh_daily_stage_a + refresh_daily_stage_b` 同 tick路径；其中 field / distribute / summary / stage_b 仍各自使用已验证的 C++ 子 pass，并保留原 GDScript fallback。

### 2026-05-18 修正：合并 gate 探测开销

历史实现 `_gdext_method_argc_ok` 每个 SUS slice 调用 4 次 `get_method_list()`
（遍历整个 DCWorldExt 方法表 + 字符串比对）。这是 `weather_refresh`
`unattributed=2.5~2.6ms` 的核心来源之一。同时被检查的 4 个子方法名
`run_weather_field_solve_pass` 等 **未通过 `ClassDB::bind_method` 注册**
（只是 C++ 内部 helper），所以 gate 实际永远返回 false——付出诊断成本却拿不到收益。

修正：
1. Gate 改为**一次性 has_method 探测 + 永久缓存**（`_merged_native_gate_probed`），
   每个 job 实例只付一次开销。
2. 探测目标改为**唯一已 bind 的一体化入口** `run_weather_refresh_daily_pass`。
3. 只在 generator 暴露 GDScript facade `refresh_weather_daily()` 后才激活
   合并模式——facade 负责打包 17+ 项 PackedArray knobs。当前 facade 未实现，
   gate 保持 false 但不再付每帧 4× `get_method_list` 成本。
4. `weather_refresh_job._publish_job_timing` 增加 `prelude_ms` 字段，instrument
   `run_slice` 入口的 getter 调用 + `has_method` 链耗时，便于后续定位 unattributed。

## Season Refresh hot-loop 优化（2026-05-18）

`season_refresh stage_3_river/4_veg/5_shrub/6_mangrove/7_glacier/8_swamp/11_feedback`
等 stage 由 `_apply_*` / `_consume_feedback_buffers` 实现，单 cell 工作量极小，
但每个 stage **首行调用 `map.all_cells()`** —— 该函数返回 `_cells.values()`，
即每调一次新建 Array 并复制 2400 个 HexCell 引用。日志中
`stage_11_feedback max=6.14ms` / `stage_3_ms=1.27ms` 的主要构成不是算法计算，
而是这层隐式 Array 复制。

修复：在以下 hot loop 统一改用 `map.iter_cells()`（直接返回底层 `_cell_array` 引用，
零复制），当 `has_indices()` false 时 fallback 到 `all_cells()`：

- `_apply_river_ecology`（stage_3）
- `_apply_vegetation_feedback`（stage_4 fallback；micro 路径已用 iter_cells）
- `_run_season_stage4_micro`（stage_4 micro，主路径）
- `_apply_shrubland_pass`（stage_5）
- `_apply_mangrove_pass`（stage_6）
- `_apply_swamp_pass`（stage_8）
- `_apply_glacier_pass`（stage_7）
- `_apply_rain_shadow_per_cell`（stage_1 fallback）
- `_seasonal_redecide_terrain`（stage_2 fallback）
- `_consume_feedback_buffers`（stage_11）

注意：项目中 `map.all_cells()` 还有 50+ 次调用在 generate（一次性）、debug、
统计等冷路径上，那些保留原状不动。

## 验证流程

每次改动 native pipeline 后建议按以下顺序验证：

1. 启动默认地图，观察一次性 path-decision 日志：`weather/native-daily`、`stage_b/combined`、`slp_field`、`psi_solver`。
2. 跑 30 tick，确认：
   - `refresh_climate_daily` 没有长期 `frame_budget_exhausted`。
   - `weather_refresh` 不再长期停在 `weather_begin/weather_solve/weather_commit` 三段跨日状态。
   - `ocean_currents` 的 `stage_slp_path/stage_psi_path` 为 C++ 或有明确 fallback reason。
3. 跑 90/300 tick，比较：
   - `SUS total_p95`
   - `over_1ms/over_budget count`
   - `largest_slice_job/stage`
   - `refresh_climate_daily dirty_ratio/visited_ratio/path`
4. 若出现数值漂移或渲染异常，逐个关闭对应 flag 回退：
   - weather：`use_gdext_weather_refresh_daily`
   - stage_b：`use_gdext_stage_b_combined`
   - ocean：`use_gdext_slp_field` / `use_gdext_psi_solver`
   - climate sparse：`use_sparse_climate`

## 目标指标

基于 2400 cells：

- normal profile 下 `SUS total_p95 <= 2.0ms`。
- `weather_refresh` 稳态 p95 尽量 `<= 0.8ms`。
- `refresh_climate_daily` round 目标 1–2 个 fast tick 完成。
- `ocean_currents` p95 目标 `<= 1.5ms`，若仍高于该值，优先查看 SLP/PSI fallback reason。
