# Simulation Computation Pipelines

本文按游戏机制整理当前计算链路、算法概要、C++/DOTS 化状态、输入输出和性能风险。它用于回答两个问题：

- 某个机制现在到底跑在 C++、DataCore 还是 GDScript？
- 继续推进 total C++/DOTS 化时，下一步应该迁移哪一段？

## 状态总览

| 机制 | 当前状态 | 主要 C++ 入口 | GDScript 仍负责 |
| --- | --- | --- | --- |
| Season refresh | 部分 C++/gdext | stage 2 / B+ path 相关 helper | 日历/轨道相位调度、慢变量刷新、atlas queue。 |
| Climate Pass-A | C++ hot-loop | `run_climate_pass_a`, `run_climate_pass_a_thread` | knobs 构造、fallback、round 管理。 |
| Climate Pass-B | 部分 C++ / DataCore 写路径 | pass-b helper / system schedule 节点 | 部分 sparse/dirty orchestration、A/B ground-truth。 |
| Ocean water | C++ | `run_ocean_water_pass`, SIMD/thread variants | dispatch gate、fallback、slice wrapper。 |
| Ocean land | C++ | `run_ocean_land_pass`, thread variants | dispatch gate、fallback、baseline/cache 管理。 |
| Wind / air mass | C++ | `run_wind_air_mass_pass`, `run_wind_surface_pass`, `run_wind_field_pass` | terrain-aware knobs、stage orchestration。 |
| Transpiration | C++ compute + GDScript orchestration | `run_transpiration_pass` | donor table/dirty sync、slice state、fallback apply。 |
| Sea ice daily | C++ | `run_sea_ice_daily_pass` 等 native helper | terrain flip policy、job wrapper、atlas upload。 |
| Weather field | C++ sub-passes | `run_weather_field_solve_pass`, distribute/summary/stage-b helpers | begin/commit state machine、front object compatibility。 |
| Weather fronts | 部分 DOTS/packed | native snapshots / packed fronts | object layer、UI/debug、spawn/advect orchestration 部分保留。 |
| Ocean currents physical | C++ kernels + GDScript stage machine | `run_slp_field_pass`, `run_wind_field_pass`, `run_psi_solver_pass`, upwelling/raster helpers | `_phys_stage` 状态机、pixel commit、fallback。 |
| Enum atlas upload | C++ cached patch + GDScript GPU upload | cached patch/raster helpers | Image/ImageTexture/RID upload。 |
| Dynamic visual atlas | 部分 C++ patch/stride | raster/patch helpers | smooth prep、dirty queue、GPU upload。 |
| Debug data overlay bake | C++ pixel fan-out + GDScript 采样/GPU upload（ImageTexture/PackedByteArray 持久化复用，day-dirty + skip_day 节流） | `encode_overlay_atlas` | `DataOverlayBaker.bake` 逐通道 per-cell 采样、`tex.update`、stats、fallback。详见本文 "Debug Data Overlay bake" 节。 |
| Native daily sim | Probe/partial | `run_native_daily_tick`, `run_native_sim_tick` | active gate、legacy authority fallback。 |

## Season refresh

主要入口：

- `simulation/systems/season_refresh_system.gd`
- `simulation/sus/jobs/season_refresh_job.gd`
- `map_generator.gd` season helper
- `DCWorldExt` 中日历/路径相关 helper

链路：

1. scheduler 触发 `season_refresh`。
2. GDScript stage machine 推进日历/轨道相位和相关缓存。
3. B+ path 可走 `gdext`，日志中会出现 `b_plus_path=gdext`。
4. 末尾可能排队 atlas/visual 更新。

`season_phase` 在当前 runtime 中只表示年内轨道相位，用于计算太阳直射点、日照和昼长；它不再作为独立的季节魔法因子直接改变温度、湿度、降水或风向。`refresh_seasonal()` 也不再执行旧的按季节重置湿度/雨影/风向逻辑，只保留慢层与 atlas 边界维护。

性能特征：

- 当前通常很低，例如 `avg=0.03ms` 到 `0.06ms`。
- 不是主要 hot path，但它产生的 season phase 会驱动 climate/weather/ocean 输入。

风险：

- 如果 season phase 与 climate round 锁相位不一致，会导致验证日志里的 phase 差异。
- 不应为了极低耗时再做复杂线程化。

## Climate daily round

主要入口：

- `simulation/systems/climate_daily_system.gd`
- `map_generator.gd` 中 climate helper
- `gdext/src/world_ext.cpp` climate/ocean/wind/transpiration pass

调度形态：

`refresh_climate_daily` 是一个跨 sub-stage 的 round。它可能在多个 tick 内推进，也可能在 native fast path 下单 tick 完成多个子段。

典型 stage：

1. Pass-A：基础温度、纬度、海拔、太阳几何、日照/昼长、热惯性。
2. Pass-B：平滑/扩散/湿度等后续修正。
3. Ocean water：海洋热输运。
4. Ocean land：陆地邻域/异常传播。
5. Wind / air mass：风与气团热输运。
6. Sea ice hook / ice bake。
7. Transpiration。
8. Integrity diagnostics。

视觉层约束：

- `shaders/include/climate_season.gdshaderinc` 的温度偏移与 `DCClimateMath` / `dc_insolation_*` 同源：日照年均值、当前日照和高纬受限相对差使用同一公式。
- `true_insolation_enabled` 只保留为旧材质/旧 UI 参数兼容；shader 统一入口不再切回 legacy 独立余弦季节温度项。
- 植被色相仍可使用 `hemi_phase()` 做纯视觉年内 tint，但它不参与温度、湿度、降水或风场计算。

### Climate Pass-A

C++ 入口：

- `run_climate_pass_a(cp_struct, phase, season_phase)`
- `run_climate_pass_a_thread(...)`

输入：

- temperature/elevation/latitude/neighbors/terrain/water/solar geometry and thermal-inertia knobs。
- 部分 scalar 来自 `ClimateProfile`。

输出：

- `cell_temp_baseline`（runtime baseline = radiative + 热惯性积分；A 修复 2026-06，原来写 `cell_temp` 已下放给 `wind_surface` 合成阶段）
- `cell_ocean_thermal_anomaly` / `cell_local_thermal_anomaly`（在 pass_a 末尾清零，开启新一日的累加；wind_surface 末端用这两个 + `cell_air_mass_temp_anomaly` 与 baseline 合成回 `cell_temp`）
- thermal/insolation/moisture base 相关 slots
- dirty mask / DataCore writes 视具体路径而定

性能：

- 设计目标是 C++ scalar tight-loop。
- 日志中 `climate path=data_core dc=data_core` 表示 DataCore 路径，而不是纯 GDScript。

排查：

- 如果 `largest=refresh_climate_daily/pass_a/native_or_gd path=data_core` 出现 spike，需要看 stage breakdown 内 A 的细分和是否有 `cpp_taken_over=true` 等诊断。
- `path=data_core` 不是失败；要看是否有 fallback reason 或 native method missing。

#### Async parity（plan §async-stage-2，2026-06-14）

`pk_async_climate::_async_pass_a_kernel_pure` 是 `run_climate_pass_a` 的纯
`std::vector` 镜像（worker thread 跑、零 Godot API）：
- 算法逐行 1:1 (run_climate_pass_a line 2293-2417 的 run_range lambda body)
- 24 个 input field + 16 个 output field（与 sync 路径末尾 16 个 `_flush_slot_to_map`
  一一对应）
- 复用现有 `dc_insolation_now` / `dc_insolation_annual_mean` / `dc_clamp01f` 等
  inline helper（它们已是 pure function，worker 安全）
- pass_a cell-local 无邻居依赖，分 in/out buffer 不影响 bit-equal

A-B 验证 hot key：游戏运行时按 `V` 键触发
`MapGenerator.run_async_climate_round_bench("pass_a")`：跑一次 sync
`_climate_pass_a` 拿 16 字段参考，再跑 async path（`passes_mask=0x01`），对比
全部 16 输出字段是否 bit-equal，print `[async/bench pass_a] === A-B verification ===`
报告（total_diff_count_f32 / total_diff_count_u8 应为 0）。

### Climate Pass-B

入口：

- `simulation/climate/pass_b.gd`
- `climate_daily_system.gd`
- `map_generator.gd` pass-b helper
- C++ system schedule / pass-b 相关 helper

职责：

- 基于 Pass-A 结果进行后续气候平滑、湿度、异常修正。
- 通过 `write_f32_indexed` / dense 写回 DataCore，减少单点 setter。
- **A 修复（2026-06）**：原来直接覆盖 `cell_temp = clamp(snapshot + d_albedo + d_coastal + d_landform)`；现在累加到 `cell_local_thermal_anomaly` slot，由 `wind_surface` 末端合成。海冰反照率反馈 (`sea_ice_albedo_cooling`) 也对应累加为水域 cell 的负 local anomaly，不再就地改 cell_temp。`cell_moisture` 写权不变。

风险：

- sparse runtime 如果触发，但 C++ 仍跑全图，结果应保持等价。
- Pass-B 仍是未来 total C++ 化的重点候选之一，特别是 GDScript sparse apply 或 dirty sync 变成窗口 spike 时。

## Ocean water / land

主要入口：

- `simulation/ocean/water_pass.gd`
- `simulation/ocean/land_pass.gd`
- `map_generator.gd::run_ocean_water_pass_slice`
- `DCWorldExt::run_ocean_water_pass`
- `DCWorldExt::run_ocean_land_pass`

Ocean water 算法概要：

- 读取 water cells、ocean current、baseline temperature、transport anomaly。
- 沿 ocean current / 邻接方向做 advect/mix。
- 生成或更新 temperature transport anomaly。

Ocean land 算法概要：

- 读取邻居 anomaly、baseline fallback、terrain/water mask。
- 对非水格应用邻域异常传播和衰减。
- 更新 land temperature / anomaly。

数据契约：

- C++ 读取 C++ slot 或 knobs PackedArray。
- **A 修复（2026-06）**：ocean_water / ocean_land **不再写 `cell_temp`**——它们的洋流 advect & 邻接渗透结果累加到 `cell_ocean_thermal_anomaly` slot，由 `wind_surface` 末端的合成阶段统一发布回 `cell_temp`。`cell_temperature_transport_anomaly` 这条独立的低通 anomaly（由 `dc_stabilize_tta` 维护）保持不变，供 weather field reader / pass_b coastal-leak 消费。
- 如果 GDScript fallback 后下一个 C++ stage 依赖结果，需要 `refresh_slots_from_map()`。

风险：

- ocean current slot stale 会导致 advect 方向退化。
- baseline fallback 错误会造成 temp clamp 后永久卡 0。
- 如果 slice path 与 full path 混用，要保证未处理区间不会读到半新半旧异常。

## Wind / air mass

主要入口：

- `simulation/climate/wind_heat_transport.gd`
- `map_generator.gd::run_wind_air_mass_pass_native`
- `map_baker.gd` physical wind field stage
- `DCWorldExt::run_wind_air_mass_pass`
- `DCWorldExt::run_wind_surface_pass`
- `DCWorldExt::run_wind_field_pass`

职责：

- climate daily 中的气团/热输运。
- ocean currents physical chain 中的 wind vector / wind speed field。
- terrain-aware wind、纬度背景风带、SLP 压力梯度/科氏偏转、天气尺度波动、山脉绕流、沿海热力压差响应等计算。
- SLP 压力梯度在方向合成前先归一化：`-∇slp` 决定高压到低压/地转偏转方向，梯度幅度只控制压力项权重和风速增强，避免弱梯度数值被纬向背景风带完全压制。

输出：

- `cell_wind_x`
- `cell_wind_y`
- `cell_wind_speed`
- `cell_air_mass_temp_anomaly`（air-mass pass 唯一输出；surface pass 在累加邻接 anomaly 后也把 air anomaly 写回这个 slot）
- `cell_temp` — **A 修复（2026-06）：climate-daily 链条中 `wind_surface` 是唯一写者**。末端公式：
  `cell_temp[i] = clamp(cell_temp_baseline[i] + cell_ocean_thermal_anomaly[i] + cell_local_thermal_anomaly[i] + air_anom_after_advect[i], 0, 1)`。
  baseline / ocean_anom / local_anom 分别由 pass_a / ocean_water+ocean_land / pass_b 写入；air_anom 由 wind_air_mass 注入、wind_surface 在邻接平流后更新。

数据契约：

- `cell_wind_x/y` 是单位方向向量，不存速度。
- `cell_wind_speed` 是物理化强度，weather field、wind heat transport、surface injection、PSI/upwelling 都应读它做强度权重。
- `wind_field_buffer` / vector atlas 的 BA 通道是渲染速度向量：`dir * clamp(wind_speed / 1.7, 0, 1)`。shader 对 BA 求 `length()` 得到的是归一化风速，不是恒定 1 的方向模长。
- `run_wind_air_mass_pass` / `_wind_air_mass_pass` 只发布
  `cell_air_mass_temp_anomaly`。它们不再直接覆盖 `cell_temp`；后续
  `run_wind_surface_pass` / `_wind_surface_pass` 是 **climate-daily 链条中 `cell_temp` 唯一的写者**
  （A 修复 2026-06），通过 baseline + ocean_anom + local_anom + air_anom 的合成把全部贡献汇总成单点写。
  排查局部温度 ping-pong 时先确认 pass_a / pass_b / ocean_* 都没再获得 `cell_temp` 写权。

风险：

- wind field 既被 climate/weather 使用，也被 ocean physical chain 使用。不要把单位方向 `cell_wind_x/y` 当作风速；否则天气平流、降水 carryover、风向 overlay 和 shader 都会表现为全图恒定强风。
- `path=gdscript` 需要看是 wind stage fallback，还是只是 early report 默认值。

## Transpiration

主要入口：

- `simulation/biology/transpiration_pass.gd`
- `climate_daily_system.gd::_run_transpiration_pass_slice`
- `map_generator.gd::run_transpiration_pass_native`
- `DCWorldExt::run_transpiration_pass`

算法概要：

- 根据植被、水分、donor/outflow/self rate 计算水分再分配。
- C++ 部分负责主要 compute/apply。
- GDScript 负责 donor table、round state、dirty sync 和 fallback。

日志字段：

```text
transp gdext wall=0.35 native=0.029 call=... compute=... apply=... flush=... refresh=... sync=...
```

解释：

- `native` / `compute` 很低时，说明 C++ 算法本体不是瓶颈。
- `sync`、`refresh`、`write`、`mark` 变高时，问题在边界同步或 dirty。
- `largest=...transp/apply path=gdscript_sliced 28ms` 可能是旧窗口 spike，不一定代表当前 tick 仍在 GDScript compute。

风险：

- GDScript sliced apply 的旧路径仍可能进入统计窗口。
- 如果 C++ pass 已发布，caller 应避免重复 dense/indexed 写。

### Async parity（plan §async-stage-1，2026-06-14）

Stage 1 落地的异步 climate round 框架已经把 transpiration 移植成 pure
`std::vector` kernel（`pk_async_climate::_async_transp_kernel_pure`），
跑在长驻 worker thread 上，主线程只 kick + poll。算法本体逐行 1:1 镜像
`run_transpiration_pass`：

- 输入：`landform`(U8) / `vegetation`(U8) / `moisture`(F32) per cell + 静态
  `neighbor_indices`(I32) + `donor_table`(F32) + scalar `outflow_rate`/`self_rate`
- 输出：`moisture` per cell + `dirty_indices/values` 列表
- 误差：bit-equal（同样 float32 顺序计算，无 reduction reorder）

A-B 验证 hot key：在游戏运行时按 `B` 键触发
`MapGenerator.run_async_climate_round_bench("transp")`，会跑一次 sync
`run_transpiration_pass_native` 拿参考结果，然后跑 async path，对比 moisture
是否 bit-equal，print `[async/bench transp]` 报告（diff_count 应为 0）。

Stage 2（plan §async-stage-2，2026-06-14）扩展：
- pass_a pure kernel 已移植（`_async_pass_a_kernel_pure`，16 字段输出）
- pass_b pure kernel 已移植（`_async_pass_b_kernel_pure`，写 moisture + local_thermal_anomaly + 海冰反照率尾循环）
- ocean_water + ocean_land pure kernel 已移植（`_async_ocean_water_kernel_pure` / `_async_ocean_land_kernel_pure`，写 ocean_thermal_anomaly + work scratch buffer ocean_tta_inout）
- wind_air + wind_surface pure kernel 已移植（`_async_wind_air_kernel_pure` / `_async_wind_surface_kernel_pure`，wind_surface 是 climate round 唯一写 cell_temp 的 pass）
- sea_ice pure kernel 已移植（`_async_sea_ice_kernel_pure`，输出 sea_ice_frac + terrain + flip events list）
- kick `passes_mask` (int) 控制 worker 跑哪些 pass：bit 0=pass_a, 1=pass_b, 2=ocean_water, 3=ocean_land, 4=wind_air, 5=wind_surface, 6=sea_ice, 7=transp
- A-B 验证 hot key `V` 触发 pass_a bench（`run_async_climate_round_bench("pass_a")`）
- Stage 2 范围内每个 pass 单独验证 bit-equal；round 模式（mask=0xFF）的数据流
  整合在 Stage 3 处理（pass_a → transp 的 moisture 传递；ocean_water → ocean_land
  的 work.ocean_tta_inout 共享；wind_air → wind_surface 的 air_anom 传递）

Stage 1+2 完成范围：**全部 8 个 climate pass 都已实装 pure std::vector kernel**。

Stage 3（plan §async-stage-3，2026-06-14）GDScript orchestration 整合：
- `climate_daily_system.gd::run_slice` 顶部加 async 分支：`cp.use_climate_round_async=true` +
  `ext.has_method("async_climate_round_kick/poll")` 时走 worker 模式
- 状态机：`_round_active=false` → kick → `_async_round_kicked=true` → poll →
  完成 → `_finalize_round()` 走原逻辑（埋点 / breakdown / annual log）
- `_build_async_kick_input` 一次性 dump 全部 22 个 PackedArray 输入字段 + ~40 个 scalar
- `_handle_async_sea_ice_flips` 在 poll 完成时调 `map.mark_all_climate_dirty()`
  让 atlas pipeline 在下个 stride 看到 terrain 翻转
- Worker 内 round-internal data flow：每 pass 跑完后 `std::memcpy(in.field, out.field, n*sizeof(float))`
  让后续 pass 读到 fresh 值（pass_a 写 moisture/snow_cover/temp_baseline →
  pass_b 读；pass_b 写 moisture/local_thermal_anomaly → 后续读；ocean_water 写
  ocean_thermal_anomaly → ocean_land 读；wind_air 写 air_mass_temp_anomaly →
  wind_surface 读；wind_surface 写 cell_temp → sea_ice 读 cell_temperature_arr）

切换方式：把 ClimateProfile 资源里的 `use_climate_round_async` 翻到 true，restart
游戏即可。**dev 期建议先用 KEY_B / KEY_V 跑 bench 验证 bit-equal**，再翻开本 flag。

#### Stage 3 字段名修复（2026-06-14）

**关键教训：** `_build_async_kick_input` 里所有 `cp.xxx` 字段名必须与 sync 路径里
inline 构造的 knobs dict **逐字对照**——不能凭直觉命名。Stage 3 落地时发现一批
字段名拼错，导致 daily round 异步路径的输出偏离 sync 路径：

| 错误命名（已修） | 正确命名（sync 用） | 出现位置 |
|---|---|---|
| `cp.snow_cool` | `cp.snow_albedo_cooling` | pass_b |
| `cp.veg_cool` | `cp.vegetation_cooling` | pass_b |
| `cp.diurnal_amp` | `cp.landform_diurnal_amp` | pass_b |
| `cp.evap_gain` | `cp.evaporation_gain` | pass_b |
| `cp.rs_threshold/factor/lookback` | `cp.rain_shadow_*` | pass_b |
| `cp.t_freeze` | `cp.sea_ice_form_threshold` | pass_b |
| `cp.coupling_gain` | `cp.ocean_moisture_coupling_gain` | pass_b |
| `cp.coast_leak` | `_last_cfg.COASTAL_HEAT_LEAK`（**不在 cp**） | pass_b, ocean_land |
| `cp.sea_ice_k_freeze` | `cp.sea_ice_freeze_rate` | sea_ice |
| `cp.sea_ice_k_melt` | `cp.sea_ice_melt_rate` | sea_ice |
| `cp.sea_ice_t_form` | `cp.sea_ice_form_threshold` | sea_ice |
| `cp.sea_ice_t_melt` | `cp.sea_ice_melt_threshold` | sea_ice |
| `cp.sea_ice_threshold` | `cp.sea_ice_terrain_threshold` | sea_ice |
| `cp.sea_ice_hysteresis` | `cp.sea_ice_terrain_hysteresis` | sea_ice |
| `_last_cfg.WIND_HEAT_ADVECT_STEPS` | `_last_cfg.OCEAN_HEAT_ADVECT_STEPS` | ocean_water |
| 缺少 | `cp.sea_ice_neighbor_contagion` | sea_ice |
| 缺少 | `cp.sea_ice_solar_gate_enabled` | sea_ice |
| 缺少 | `cp.sea_ice_freeze_insol_low/high` | sea_ice |
| 缺少 | `cp.sea_ice_solar_melt_start/gain` | sea_ice |
| 缺少 | `cp.sea_ice_daily_delta_cap` | sea_ice |
| 缺少 | `_last_cfg.OCEAN_CURRENT_ICE_DELAY` | sea_ice |
| 缺少 | `_last_cfg.enable_ocean_heat_transport` | sea_ice |
| 缺少 | `generator._consume_sea_ice_dt_days()` | sea_ice（必须 mirror sync 的 stride 补偿） |
| 缺少 | TTA 4 个 scalar（source_cap/blend_rate/decay_rate/zero_current_decay） | ocean_water/ocean_land |
| 缺少 | climate_anomaly 阈值 shift（sea_ice t_form/t_melt） | sea_ice |

**还有：** `thermal_inertia_*` 和 `thermal_daily_delta_cap` / `snowpack_cover_*` /
`insol_dev_*` 这些 scalar **不能**读 `cp.xxx`！sync 路径在 `_climate_pass_a::cp_struct`
里**故意没传**这些字段（map_generator.gd:6818-6830 只传 11 个 scalar），C++ 端走
内部默认值（0.24/0.07/0.09/0.16/0.085/0.03/0.25/-1/1.5）。`climate_profile.gd` 里
的 @export 0.35/0.15 等是给 **GDScript fallback** 用，C++ 路径不读。**async daily
round 要跟 sync 生产路径 bit-equal，绝不能读 cp.thermal_inertia_***。

bench helper（`run_async_climate_round_bench` in `map_generator.gd`）跟实际
`_build_async_kick_input` 共享同一份契约：bench 用 hardcoded scalar mirror sync 的
默认值；`_build_async_kick_input` 用同样的 hardcoded（避免 climate_profile.gd 的
@export 默认值跟 C++ 内部默认值不一致导致 diff）。

bench 互斥保护：`run_async_climate_round_bench` 入口临时关 `use_climate_round_async`
flag，bench 完成后恢复——避免 daily round async 路径跟 bench 都用同一个 global
worker singleton 互相污染（`worker_compute_us=1700` 而非 ≈1400 即是症状）。

#### Stage 3 sea_ice independent job 互斥（2026-06-14）

SUS scheduler 注册了 `sea_ice_daily` 独立 job（`SeaIceDailySystem`，priority=115），
跟 `refresh_climate_daily` 平行跑。它调 `generator.run_climate_pass_slice("sea_ice")`
路由到 sync `_apply_sea_ice_daily_pass`。

`use_climate_round_async=true` 时 worker 内部 sea_ice pass 也跑——**两边同时存在
就会**：
- 每 tick 调两次 `_consume_sea_ice_dt_days()`，第二次拿到的 dt_days 偏移（已实测
  `[sea_ice/dt] call#2 ... call#2` 同 tick 出现）。
- terrain 翻转两遍——sync 翻一次写 `_slots[cell_terrain]`，async worker 也翻一次写
  output 然后 poll 时再写 slot，结果取决于谁先 mark dirty。

解决：`SeaIceDailySystem::_enabled_from_profile` 检查 `cp.use_climate_round_async`，
true 时 return false（job 整个 short-circuit）。回退路径（async flag false）走原
独立 job。

## Sea ice daily

主要入口：

- `simulation/systems/sea_ice_daily_system.gd`
- `simulation/sea_ice/daily_pass.gd`
- `map_generator.gd` sea ice helper
- `DCWorldExt` sea ice pass

算法概要：

- 根据温度、水体、纬度/季节、邻域和阈值更新 `sea_ice_frac`。
- 可触发 terrain flip 或 ice bake。
- 结果影响 climate、render atlas 和 ocean physical mask。

输出：

- `cell_sea_ice_frac`
- terrain/water mask 相关字段，视 `apply_terrain_flips` 而定。

风险：

- C++ 写了 `sea_ice_frac` 但 terrain flip 没同步，会让后续 pass 对 water/ice 判断不一致。
- atlas upload 是另一条 GPU 路径，海冰计算快不代表海冰可视化立即完成。

## Weather field / fronts

主要入口：

- `weather/weather_system.gd`
- `weather/field_solver.gd`
- `simulation/sus/jobs/weather_refresh_job.gd`
- `simulation/systems/weather_system.gd`
- `DCWorldExt::run_weather_field_solve_pass`
- weather distribute / summary / stage-b native helpers

Stage-A 链路：

1. begin：准备 field snapshot、fronts、cell budget。
2. solve：计算 vapor/cloud/precip/instability/convergence 等 field。
3. commit：写回 DataCore/HexCell/weather arrays。
4. summary：把 cell field 汇总成 fronts。

Stage-B 链路：

- 根据 field/fronts 更新 albedo、vegetation dynamics、feedback、snow/soil/water balance 等。

Merged native 路径：

- `weather_refresh_job.gd` 中存在 merged transaction gate。
- 成功时 field/distribute/summary/stage-b 可在一个 SUS slice 中完成。
- fallback 时回到 begin/solve/commit/stage-b staged path。

输出：

- weather cell components：vapor、cloud、precip、instability、intensity 等。
- environment components：snow_cover、snowpack、soil moisture、water balance 等。
- fronts packed snapshot / object compatibility layer。
- transition components：`weather_type`、`weather_prev_type`、
  `weather_target_type`、`weather_transition_alpha`。当 alpha 到达 1.0 时，
  native 与 fallback commit 都必须提交为稳定态：`type=target`、
  `prev_type=target`、`alpha=0`，避免 CSV 中长期出现 `alpha=1` 或
  `prev_type` 滞后造成的假 transition。稳定格（`prev_type == target_type`
  或 display 已等于 target）不得继续累加 alpha；否则 CSV 会把没有实际天气
  切换的格子统计为 transitioning。

风险：

- weather fronts 数量低，但对象层复杂；不应盲目 SIMD。
- field solve 是 hot-loop，适合 C++。
- GDScript object unpack 仍可能造成 commit/sync 长尾。
- `weather_field_slice_cells()` 的配置上限与当前 2400-cell 地图规模对齐；
  profile 可在 `100..2400` 间调度 field solve cell budget。若切片过小，
  天气场会长期处于同一 field phase，看起来像生成/消失频率异常。

## Ocean currents physical chain

主要入口：

- `simulation/sus/jobs/ocean_currents_job.gd`
- `rendering/map_baker.gd`
- `DCWorldExt::run_slp_field_pass`
- `DCWorldExt::run_wind_field_pass`
- `DCWorldExt::run_psi_solver_pass`
- upwelling/raster/native helpers

Cadence contract:
- One tick is one game day. `OceanCurrentsJob` keeps the registered SUS policy
  always-on so the job can enter every day.
- Each day starts with a lightweight C++ wind prepass:
  `MapBaker.run_daily_wind_field_update()` calls `run_slp_field_pass` and
  `run_wind_field_pass`, publishing `cell_slp`, `cell_wind_x/y`, and
  `cell_wind_speed` back to the C++ slots / `MapData` mirror.
- The prepass uses `SusTickContext.day_index` as C++ `sim_day`. `main.gd`
  forwards the `day_changed(day_idx)` signal value rather than re-reading the
  final `WorldClock.day_index()`, so catch-up ticks still advance wind one day
  at a time.
- `wind_circulation_period_ticks` is not used to slow this daily wind prepass;
  `MapGenerator` configures `wind_period_ticks=1`. Deliberately changing that
  value means accepting non-daily wind evolution.
- The heavier ocean chain remains sliced: `PSI -> upwelling -> raster -> GPU
  commit` is gated inside the job by the internal continuous slice policy and
  by `ocean_currents_period_ticks` / `ocean_currents_slice_count`.
- When a slow ocean round starts after a successful daily wind prepass,
  `prime_physical_solve_from_current_wind()` starts the physical stage machine
  at `PSI_INIT` so SLP/wind are not recomputed in the same tick.

Stage 概览：

| Stage | 典型名称 | C++ 化状态 |
| --- | --- | --- |
| 1 | SLP field | `run_slp_field_pass`，可 `published_to_slot=true`。 |
| 2 | Wind field | `run_wind_field_pass`。C++ 内综合纬向环流、归一化 SLP 压力梯度方向、科氏偏转、天气尺度波/涡、沿海热力压差响应和地形摩擦；输出单位方向 + `cell_wind_speed`。 |
| 3-4 | PSI solver | `run_psi_solver_pass`，可发布 `cell_ocean_current_x/y`。 |
| 5-6 | Upwelling / currents apply | C++ helper + GDScript state machine。 |
| 7 | Wind/ocean raster | `gdext_raster` / pixel slices。 |
| 8 | Pixel commit | GDScript/Godot image/atlas commit。 |

`ocean_currents_job.gd` 维护 `_phys_stage`，每次 `run_slice()` 推进一个 stage 或 pixel range。日志可能出现：

```text
largest=ocean_currents/ocean_pixel_slice/pixels_49536_50048 path=gdext_raster 1.07ms
psi_path=gdscript
```

解释：

- `path=gdext_raster` 表示 pixel raster slice 使用 C++ raster path。
- `psi_path=gdscript` 如果出现在 PSI stage 执行前，可能只是默认/上一阶段报告；需要看后续 `stage_psi_path=gdext` 或 `published=true`。
- SLP/PSI `published_to_slot=true` 表示 C++ 已把输出写入 slot，GDScript caller 应跳过重复 array copy。

风险：

- 物理 stage 和 pixel raster 是两类工作；前者影响模拟，后者影响可视化。
- pixel upload 可被 budget skip，但 physical solve 长期 skip 会造成 ocean/wind 冻结。

## Atlas upload

### Enum atlas

入口：

- `simulation/systems/enum_atlas_upload_system.gd`
- `simulation/sus/jobs/enum_atlas_upload_job.gd`
- atlas encoder / map baker helper

职责：

- cover/vegetation/enum 等离散 atlas dirty patch。
- C++ cached patch 可减少 CPU packing。
- Godot `Image` / `ImageTexture` upload 仍在 GDScript/Godot 对象层。

日志：

```text
enum_atlas_upload axis= path=cpp_cached_patch elapsed=0.01 patch=0.42 img=0.00 upload=1.39 dirty=1411px/6cells cache=true
```

解释：

- `patch` 是 patch 构造或 C++ cached patch 成本。
- `upload` 是 GPU texture update 成本。
- `dirty=1411px/6cells` 表示 dirty cell 少但像素覆盖可能大。

### Dynamic visual atlas

入口：

- `simulation/systems/dynamic_visual_atlas_upload_system.gd`

职责：

- smooth prep、dilate、collect、stride commit。
- dynamic smooth atlas / ice state texture 等。

风险：

- `frame_budget_exhausted` 可导致上传滞后，但不一定影响模拟权威。
- `_cpp_stride_in_progress` 表示 C++/patch stride 跨 tick 推进中。

## Native daily / EnvironmentRuntime

主要入口：

- `DCWorldExt::run_native_daily_tick`
- `DCWorldExt::run_native_sim_tick`
- `EnvironmentRuntime`
- `native_daily_sim_job.gd`
- `native_environment_runtime_system.gd`

状态：

- 当前是 probe/partial 接管能力，不是所有 legacy SUS 的完全替代。
- active gate 不应只看 C++ 方法存在，还要看 schema、fronts、schedule graph、fallback 差异报告。

迁移方向：

- 把 job graph、read/write masks、stride policy、front packed snapshot、dirty lists 继续下移到 C++。
- GDScript fast tick 最终只调用 `run_native_sim_tick(ctx)` 并消费结构化 report。

## Debug Data Overlay bake

主要入口：

- GDScript orchestration：`main.gd::_refresh_overlay_data` → `scripts/rendering/data_overlay_baker.gd::DataOverlayBaker.bake`
- C++ pixel fan-out：`gdext/src/world_ext.cpp::DCWorldExt::encode_overlay_atlas`
- 触发：`_on_day_changed` 顶部置 `_overlay_dirty=true`；fast tick 末尾消费。
- 不属于 SUS scheduler job，不计入 `sus/render/ui`，但同步阻塞主线程。

当前状态：**混合 C++/GDScript**（debug-overlay-perf v2，2026-06-12）。18 个 overlay mode 的 per-cell 采样（含 `latitude_buffer` / `atan2` / 非 schema 字段）留在 GDScript（仅 ~n_cells 次，分支重、零 bit-divergence 风险）；O(n_pixels) 的内层像素 fan-out（典型 ~62 万次写）+ buffer 清零下沉 `encode_overlay_atlas`。ext 缺失 / 旧 DLL / SoA 未建 / C++ 返回 fallback 时透明回退到 GDScript fan-out（`gdscript_fanout` / `gdscript_fanout_soa`）。

输入 / 输出：

| 项 | 来源 | 备注 |
| --- | --- | --- |
| cell SoA / facade 值 | `DCViewAdapter`（World 优先，Cell 兜底） | 与 info_panel 同一 adapter 实例避免 drift。 |
| `world.cell_pixel_lists` | MapBaker | 每 cell 覆盖像素 idx 列表（GDScript Dict fan-out 兜底用）。 |
| `world.cell_first_px_arr` / `cell_px_count_arr` / `flat_px_indices_arr` | MapBaker `_ensure_world_cell_pixel_csr` | 持久 SoA pixel CSR（按 `cell.index` 索引，整图一次性构建）；`encode_overlay_atlas` 零拷贝复用。 |
| `world.latitude_buffer` | MapBaker | CLIMATE_ZONE 通道用真实 ny。 |
| `world_ext: DCWorldExt` | main `get_data_core_world_ext()` | 提供 `encode_overlay_atlas`；缺失/旧 DLL 时透明回退。 |
| `existing_tex: ImageTexture` | main `_overlay_tex` 持久化 | size 匹配走 `update(img)`，不匹配 fallback 新建。 |
| `existing_buf: PackedByteArray` | main `_overlay_buf` 持久化 | 复用，避免每帧 2.4MB resize。 |
| `texture` + `buf` + `path` | 返回值 | caller 缓存复用；`path` ∈ {gdext_fanout, gdscript_fanout, gdscript_fanout_soa}。 |

关键性能契约（debug-overlay-perf v1 + v2）：

- **必须**持久化 `_overlay_tex` 跨调用。直接 `ImageTexture.create_from_image()` 每帧重建会触发 GPU 资源销毁 + VRAM 重分配，单次 5-15ms。
- **必须**让 buf 跨调用复用。每帧 `PackedByteArray.resize(N*4)` 触发 GC 抖动。
- **必须**用 dirty + skip_day 双 gate 节流。x20 倍速下 day_changed 每秒可触发 20-40 次；跳日帧 climate/weather 字段不变，重 bake 无意义。
- **应当**走 `encode_overlay_atlas`：cpp_path 下 GDScript 不再做 O(n_pixels) 内层像素写，buffer 清零由 C++ memset 承担；GDScript 仅清零用于兜底路径。

C++ fan-out 协议（debug-overlay-perf v2，2026-06-12，已实现）：

- GDScript 端 per-cell 采样产出三组 per-cell（按 `cell.index`）数组：`cell_r` / `cell_g`（RGBA8 的 R/G byte）+ `cell_valid`（0/1）。B 恒 0、有效 cell A=255。
- `encode_overlay_atlas` 复用 `world.cell_first_px_arr` / `cell_px_count_arr` / `flat_px_indices_arr`（整图 flat，first/count 直接索引，与 4 张视觉 atlas 共用语义），把每个有效 cell 的 `(R,G,0,255)` 扇出写到它覆盖的全部像素，并 `memset` 清零。
- 该 pass 不读 `_slots` / 不要求 `_bound`：overlay 数据全部由 GDScript 预采样喂入，地图刚生成 / climate slot 未绑定也能工作。
- bit-equal 由 `_fanout_cell_bytes_soa`（GDScript 等价兜底）保证；C++ 返回 `fallback=true`（仅参数非法）时调用它。

诊断字段：

- `main.get_overlay_last_bake_ms()` 暴露最近一次 bake 耗时；> 5ms 应警觉。
- `main.get_overlay_bake_path()` 暴露 fan-out 路径，确认 C++ 是否生效（应为 `gdext_fanout`）。
- `_overlay_stats` 内部含 `count / invalid_count / near_zero_count / buckets`，DebugConsole Telemetry 读取。

## 后续迁移优先级

1. 消除仍会进入 `largest` 的 GDScript sliced apply，例如 transp/apply、weather commit object unpack、Pass-B sparse apply。
2. 对所有已发布 slot 的 C++ pass，确认 caller 不再重复 unpack/copy。
3. 把临时 knobs PackedArray 输入补成 schema slot，减少每 tick packing。
4. 将 ocean physical stage 状态机中可纯数据化的部分移入 C++ schedule graph。
5. 保留 GDScript object/UI/debug 层，但确保它们只读已发布 snapshot，不参与 hot-loop authority。
6. **Debug overlay bake**（已落地 v2）：pixel fan-out 已下沉 `encode_overlay_atlas`。后续可选项是把热门连续通道（TEMPERATURE/HUMIDITY/PRECIPITATION）的 per-cell 采样也搬到 C++（直读 schema slot），进一步消除 GDScript 的 ~n_cells 次 Dictionary 采样；收益边际，仅在长时间停留 Debug 通道时有意义。

## Climate / weather / ocean stability notes

This section records the current runtime contract for the climate stability
work landed from `docs/plans/climate-weather-ocean-stability-plan.md`.

### Weather field diagnostics and cold precipitation

- `main.gd` tile-data samples must carry `sample["weather"]` separately from
  `sample["climate"]`. CSV weather fields such as `weather_dirty_count`,
  `active_weather_ratio`, `field_commit_path`, and convergence diagnostics are
  authored by the weather breakdown, not by the climate daily breakdown.
- `WeatherSystem` passes cold-precipitation knobs into the field solve path:
  `cold_precip_as_blizzard` and `snow_classification_margin`. Both GDScript
  classification and `DCWorldExt::run_weather_field_solve_pass` use the same
  guard so meaningful precipitation below the snow band becomes `BLIZZARD`
  instead of cold `RAIN`.
- Field precipitation now has a shared high-tail stability step in both
  `weather/field_solver.gd` and `DCWorldExt::run_weather_field_solve_pass`.
  `ClimateProfile` owns the tuning knobs:
  `weather_wet_terrain_precip_damping`, `weather_lake_precip_damping`,
  `weather_lake_evap_scale`,
  `weather_extreme_precip_soft_cap`, and
  `weather_extreme_precip_softness`. The damping is applied after
  `precip_raw / precip_floor / cloud_water_rain` are merged and clamped, before
  cloud-water and vapor sinks consume the rain amount. `weather_lake_evap_scale`
  is applied earlier at the evaporation source so lakes do not behave like open
  ocean vapor pumps before the lake precipitation damping tail step. Keep these
  positions synchronized across native and fallback paths.
- `MapData.weather_classification_temp_arr` and
  `MapData.weather_classification_moisture_arr` are recorder-only diagnostic
  mirrors of the field solver read snapshot. They are not DataCore schema
  slots. Use them to compare weather classification input against current
  `temp_arr` / `moisture_arr` when investigating cold rain or warm blizzard
  reports.
- `DCWorldExt::run_weather_field_commit_pass` reports convergence refresh
  data only for ticks where `refresh_convergence=true`. A flat convergence
  array on other ticks is expected cadence behavior, not a stale-write bug.

### Ocean current vector limits

- `PhysicalCirculationSolver.psi_to_ocean_current()` and
  `DCWorldExt::run_psi_solver_pass` apply the same final vector-magnitude
  clamp after response blending. `ocean_current_scale` controls PSI-gradient
  conversion; `ocean_current_max_magnitude` controls the final vector length.
- Current defaults keep the physical field below the old near-unit plateau:
  `ocean_psi_source_scale=0.08`, `ocean_current_scale=0.16`,
  `ocean_current_max_magnitude=0.65`, `ocean_thermal_current_weight=0.12`,
  `ocean_density_cold_weight=0.22`, and `ocean_density_ice_weight=0.12`.
  These are profile knobs, so existing saved resources may still override them.
- Per-component safety clamping may still exist as a guard, but the expected
  physical limit is the vector magnitude, not independent `x/y` saturation.
  Water-cell current magnitudes should therefore be bounded by
  `ocean_current_max_magnitude` in normal runs.
- `run_psi_solver_pass` reports `ocean_current_preclamp_p95`,
  `ocean_current_preclamp_max`, `ocean_current_clamp_count`,
  `ocean_current_clamp_ratio`, and `ocean_current_max_magnitude`. The same
  fields are cached by `MapBaker`, forwarded through `OceanCurrentsJob`, and
  exported by `TileDataRecorder` as `phys_ocean_current_*` columns.

### Ocean physical / visual split

- `OceanCurrentsJob` owns two internal state machines. The physical authority
  round advances SLP, wind, PSI, currents, and upwelling. The visual round
  rasterizes and commits the pixel atlas from the latest published fields.
- A visual raster or pending visual commit must not keep the physical round
  alive. Physical solves can finish and start again while a visual raster is
  still catching up.
- With `ocean_visual_rebake_drop_stale=true`, a stale visual raster may be
  dropped and restarted from the newest physical snapshot. This preserves
  simulation authority at the cost of a temporarily stale atlas.

### Temperature transport anomaly state

- `cell_temperature_transport_anomaly` and
  `MapData.temperature_transport_anomaly_arr` are the authoritative low-pass
  TTA state. No schema change is required for the current plan.
- Ocean water and land paths no longer treat TTA as a scratch value that is
  reset to zero each round. The source anomaly is capped by
  `temperature_transport_anomaly_source_cap`, blended by
  `temperature_transport_anomaly_blend_rate`, and decayed by either
  `temperature_transport_anomaly_decay_rate` or
  `temperature_transport_anomaly_zero_current_decay`.
- Native scalar, SIMD, and threaded ocean water/land variants must use the same
  TTA knobs as the GDScript fallback path so A/B checks compare formulas rather
  than different stabilization policies.
- Runtime temperature values at exactly `0.0` are valid frozen-cell readings.
  Climate/ocean/wind paths must only fall back to geometric baseline when a
  temperature is NaN or infinite; using `temp > 0.0` as a validity check creates
  discontinuous jumps near the lower clamp.
