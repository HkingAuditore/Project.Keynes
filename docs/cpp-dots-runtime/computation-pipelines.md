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
| Runtime hydrology | C++ full-map pass + weather job stage | `run_runtime_hydrology_pass` | `weather_refresh` stage 编排、ClimateProfile knobs、后续慢频视觉重烘策略。 |
| Weather fronts | 部分 DOTS/packed | native snapshots / packed fronts | object layer、UI/debug、spawn/advect orchestration 部分保留。 |
| Ocean currents physical | C++ kernels + GDScript stage machine | `run_slp_field_pass`, `run_wind_field_pass`, `run_psi_solver_pass`, upwelling/raster helpers | `_phys_stage` 状态机、pixel commit、fallback。 |
| Enum atlas upload | C++ cached patch + GDScript GPU upload | cached patch/raster helpers | Image/ImageTexture/RID upload。 |
| Dynamic visual atlas | 部分 C++ patch/stride | raster/patch helpers | smooth prep、dirty queue、GPU upload。 |
| Debug data overlay bake | C++ pixel fan-out + GDScript 采样/GPU upload（ImageTexture/PackedByteArray 持久化复用，day-dirty + skip_day 节流） | `encode_overlay_atlas` | `DataOverlayBaker.bake` 逐通道 per-cell 采样、`tex.update`、stats、fallback。详见本文 "Debug Data Overlay bake" 节。 |
| Native world generation base + post-base + publish（生成期） | **ACTIVE 默认（dots-total-cpp 2026-06-18，唯一路径，无 GDScript fallback）**：C++ base SoA generation + C++ post-base 地貌/生态/河流处理；bind 后 C++ slot publish | `run_native_world_generate_base_pass`, `run_native_world_generate_post_base_pass`, `run_native_world_generate_pass`, `start_native_generation`, `run_native_generation_slice`, `finish_native_generation` | 发送请求、校验、装配 HexCell/MapData；native 失败硬中止 push_error。 |
| Native daily sim | Probe/partial | `run_native_daily_tick`, `run_native_sim_tick` | active gate、legacy authority fallback。 |
| Temp baseline year bake（生成期） | C++ 权威 + GDScript fallback | `run_temp_baseline_year_bake` | `cell_lat_norm` 几何量烘焙、ext 未就绪时 fallback。 |

> `cell_temp_baseline_year`（海冰 + 显示温度的运行期年 baseline）权威计算已收回 C++，见下文 "Temp baseline year bake" 节。注意它与 pass_a 每日写的运行期 `cell_temp_baseline`（辐射 + 热惯性积分）是两个不同字段。

## Native world generation base + post-base + publish（生成期）

主要入口：

- `DCWorldExt::run_native_world_generate_base_pass`（无 bind 的 C++ base SoA 生成结果包）
- `DCWorldExt::run_native_world_generate_post_base_pass`（无 bind 的 C++ post-base SoA 结果包）
- `DCWorldExt::run_native_world_generate_pass`（单调用生成期 publish）
- `DCWorldExt::start_native_generation` / `run_native_generation_slice` / `finish_native_generation`（同一 publish pass 的切片 API 外壳）
- `map_generator.gd::_generate_cells_native_base`（ACTIVE 编排：发 cfg/profile 请求，接收 PackedArray 结果并装配 `MapData`）
- `map_generator.gd::_publish_native_generation_from_slots`（bind 后 publish：`DCWorldExt.bind_map_data` + `configure_native_world` 后调用）

**迁移状态（dots-total-cpp 2026-06-18 完成）**：`native_generation_mode` 默认 `ACTIVE(2)`。经逐字段 A/B parity（seed=10086，base+post_base 全字段 `mismatch=0`）+ 运行期同 seed 地形直方图一致验证后，**GDScript 生成实现已删除，C++ 是唯一生成路径，无 GDScript fallback**。

`MapGenerator.generate()` 调 `_generate_cells_native_base(cfg, seed)`，后者经 `_ensure_generation_world_ext()` 拿到（必要时临时实例化）未绑定的 `DCWorldExt`，调用 `run_native_world_generate_base_pass(seed, cfg, profile)`，由 C++ 直接生成基础地图 SoA 结果包：cube 坐标、elevation、moisture/base_moisture、初始 temperature、terrain/is_water、lat/temp_year、landform/vegetation/cover 等 PackedArrays。随后 `run_native_world_generate_post_base_pass(seed, cfg, profile, base_res)` 在 C++ 内完成 Priority-Flood 水文修正、湖盆筛选、parent graph flow accumulation 河流，并输出 `has_river_arr / river_downstream_arr / river_flow_arr` 供 Baker 追踪主流/支流和可变河宽；之后继续完成河岸/植被反馈、过渡生态、地标和水体变种。GDScript（`_assemble_native_generation_map`）只负责校验返回数组尺寸并装配成 `MapData`/`HexCell`。**若 ext 缺失、方法缺失或结果非法，`_generate_cells_native_base` 返回 null，`generate()` 硬中止并 `push_error`（旧 `_generate_cells` fallback 已删除）。**

bind 后仍保留 `run_native_world_generate_pass` publish 层：在 `MapData.init_soa_from_bake()` 和 `bake_lat_temp_year_lut()` 后，`DCWorldExt` 读取已绑定的 `cell_lat_norm`、`cell_elevation`、`cell_terrain` 等 slot，以 C++ SAME_SOURCE 公式重算并发布初始 runtime 字段。这一层用于 slot/MapData 同步和窄 fallback，不再代表完整基础生成算法。

输出 slot：

- `cell_temp_baseline_year`：`pk_lat_temp_bell((ny - 0.5) * 2)`。
- `cell_temp` / `cell_temp_baseline` / `cell_temp_30d` / `cell_temp_365d` / `cell_thermal_energy`：`pk_compute_temperature(ny, elevation)` 冷启动值。
- `cell_temp_anomaly`：0。
- `cell_ema_initialized`：1。
- `cell_is_water`：由 `pk_is_water_terrain(cell_terrain)` 派生。

发布契约：C++ 写 slot 后逐项 `_flush_slot_to_map` 回 `MapData`，返回 `path=gdext`、`published_to_slot=true`、`published_slots`、`n_cells`、`compute_ms`、`flush_ms`、`elapsed_ms`。GDScript wrapper 成功后调用 `flush_pending_mark_dirty_all()`，并重绑 GDScript `DCWorld`，避免 C++ flush 后 `MapData` PackedArray reseat 而 DataCore GDScript world 仍持有旧引用。

Fallback（仅指 bind 后的 republish 层 `run_native_world_generate_pass`，**不是基础生成**）：未 bind、缺 slot、slot dtype/size 不匹配时返回 `path=gdscript_fallback`、`fallback=true`、`fallback_reason`。此时保留 `map.bake_lat_temp_year_lut()` 与既有 SoA 值（来自 C++ 基础生成），并继续调用专用 `run_temp_baseline_year_bake` 作为更窄的 C++ baseline fallback。注意：基础生成（base+post_base）本身已无 GDScript fallback，失败即硬中止。

## Runtime hydrology

主要入口：

- `DCWorldExt::run_runtime_hydrology_pass`
- `map_generator.gd::run_hydrology_discharge_pass_native`
- `WeatherRefreshJob.run_slice()` 的 `hydrology_discharge` stage

链路：天气场 commit 后，`weather_refresh` 在 stage-b 前可选运行 `hydrology_discharge`。C++ pass 读取 `cell_hydro_parent` 静态排水拓扑，以及 `cell_weather_precip`、`cell_snowpack`、`cell_soil_moisture`、`cell_water_balance_30d`、`cell_vegetation_vitality` 等运行期状态；先计算本地产流、入渗、地下水基流，再用 parent graph 做上游到下游路由。输出 `cell_river_discharge`、`cell_river_discharge_30d`、`cell_river_storage`、`cell_groundwater_storage`、`cell_surface_runoff`，并回写 `cell_soil_moisture` 和 `cell_water_balance_30d`。

调度原因：它读取当天已提交的 `weather_precip`，所以不放在 `refresh_climate_daily`；它又会影响 stage-b 的植被动态与反馈，所以放在 `weather_summary` 之后、`refresh_daily_stage_b` 之前。默认 `ClimateProfile.runtime_hydrology_enabled=false`，关闭时保留静态生成期河流行为。

返回 report：`path=gdext`、`published_to_slot=true`、`native_ms`、`compute_ms`、`flush_ms`、`refresh_ms`、`n_cells`、`water_budget_error`、`river_discharge_p95`、`river_discharge_max`、`flood_candidate_count`。若 slot 缺失或 size 不匹配，返回 `published_to_slot=false` 和 `fallback_reason`，旧静态河流仍可继续显示。

## Temp baseline year bake（生成期 cell_temp_baseline_year）

主要入口：

- `DCWorldExt::run_temp_baseline_year_bake`（C++ 权威）
- `map_generator.gd::_bake_temp_baseline_year_native`（窄兜底：native generation publish 失败后调一次）
- `map_data.gd::bake_lat_temp_year_lut`（GDScript fallback + 几何量 `cell_lat_norm` 烘焙）

背景：`cell_temp_baseline_year`（每 cell 年均纬度温度钟形）是海冰判定与显示温度的运行期 baseline，被 C++ pass_a（`TEMP_YEAR_BASE`）、GDScript pass-A fallback、`climate_daily_system`、debug overlay 共同消费。它原本由 GDScript `bake_lat_temp_year_lut` 就地 `pow(cos(lat·π/2), exp)` 烤出来再经 `refresh_slots_from_map` 推给 slot——仿真量的权威落在 GDScript，逼着 GDScript / C++ / Shader 三处镜像同一条 `lat_temp_bell`。

链路（temp-baseline-authority-2026-06 之后）：

1. 生成期 `bake_lat_temp_year_lut` 烤 `cell_lat_norm`（依赖地图几何 `cube_row_norm`，权威留在 GDScript），并用 `DCClimateMath.lat_temp_bell_from_ny` 填一份 `temp_baseline_year` 作为 **fallback**。
2. `_data_core_world_ext` bind + `configure_native_world` 完成后，首选 `run_native_world_generate_pass` 发布包含 `cell_temp_baseline_year` 在内的生成期初始仿真 slots。
3. 若 native generation publish 失败，`_bake_temp_baseline_year_native` 把 `cell_lat_norm_arr` 作为 `lat_norm` knob 传入 `run_temp_baseline_year_bake`，只补 `cell_temp_baseline_year` 这一个字段。
4. C++ 用唯一实现 `pk_lat_temp_bell` 算 `temp = clamp01(bell((ny-0.5)·2))` 写满 `cell_temp_baseline_year` slot，`_flush_slot_to_map` 回 `MapData.temp_baseline_year_arr`，返回 `path=gdext / published_to_slot=true / n_cells / elapsed_ms`。
5. ext 未编译 / 未 bind / 缺 slot / 缺 knob → 返回 `fallback=true`，保留步骤 1 的 GDScript 值。

I/O：

- 输入：`knobs["lat_norm"]`（`PackedFloat32Array`，ny∈[0,1]）。走 knob 而非 slot，因为本 pass 在 `cell_lat_norm` slot refresh 之前调用。
- 输出：`cell_temp_baseline_year` slot + `MapData.temp_baseline_year_arr`（flush 同步）。

权威：C++ slot（ext 可用时）；GDScript `lat_temp_bell` 仅作 fallback 与纯 GDScript 生成期 `_compute_temperature` / 地形决策使用。公式跨语言仍是 SAME_SOURCE 镜像（`DCClimateMath.lat_temp_bell` ↔ `pk_lat_temp_bell` ↔ shader `lat_temp_bell`），改指数须三处同步并重编 gdext。

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
transp/native breakdown source=current diagnostic_wall_ms=0.35 refresh_ms=... native_call_ms=... native_ms=0.029 native_compute_ms=... native_apply_ms=... native_flush_ms=... sync_total_ms=... sync_write_ms=... sync_mark_ms=... dirty_count=...
```

解释：

- `native_ms` / `native_compute_ms` 很低时，说明 C++ 算法本体不是瓶颈。
- `sync_total_ms`、`refresh_ms`、`sync_write_ms`、`sync_mark_ms` 变高时，问题在边界同步或 dirty。
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

#### Stage 3 真异步修复（2026-06-14 真机验证后）

桌面 desktop 跑出来 SUS budget `largest=refresh_climate_daily/async_round_done/pass_count=8`
12ms 看起来好；移动端真机（Adreno 830）跑出来 `34ms`，**比 sync 旧路径还慢**。

**根因：** SUS scheduler 在同 tick 内**反复调 `run_slice` 直到 done=true 或 budget exhausted**
（`sus_scheduler_ext.cpp:558` 的 `while(true)` 循环）。

之前 async 路径 kick 完报 `done=false progress_ratio=0.0`，下一秒 SUS 立刻 re-entry
调 `run_slice` → 进入 poll 分支 → worker 还在跑 → `poll_result.is_empty()` →
再 return partial → SUS 又 re-entry → ... 直到 worker 完成 poll 拿到结果。

效果是**主线程 busy-wait 在一个 SUS slice 里 30+ms**。worker 跑得快，但主线程跟它
绑在同一 SUS tick 里转完，atlas / weather / ocean 完全拿不到 budget → 视觉冻结。

修复：kick 完返回 `done=true progress_ratio=1.0`，让 SUS **不**同 tick re-entry。
下一 tick `should_run` 因 `_round_active=true` 仍返回 true，那时 worker 已经在后台
跑完，poll 直接拿结果。Worker thread 才真的 **off-thread** 跟主线程并行。

代价：climate round 跨 2-3 个 tick（kick → idle → poll），每 tick 占主线程 ~0.5ms。
实际 climate 视觉延迟从"每秒一轮"变成"每 2-3 秒一轮"——可接受，因 climate 状态本身
是 game-day 量级，2-3 tick 不可见。

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
- Earth-like 默认值降低 `sea_ice_freeze_rate` / `sea_ice_neighbor_contagion`，
  同时提高太阳融化响应并收紧 `sea_ice_daily_delta_cap`，用来减弱暖季残冰和
  海冰边界的突变扩散；这些都是 `ClimateProfile` profile knob。

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
- 雪盖入口同时受 `snowpack_*`、`snowline_*` 和
  `ClimateProfile.snow_accum_days_req` 控制。`MapGenerator` 将该值注入
  `WeatherSystem.configure_weather_field()`，GDScript fallback、resident knobs 和
  `DCWorldExt::run_weather_distribute_pass` 的 `snow_accum_days_req` 必须保持同源。
- 陆地雪盖 / 雪线 floor / 洪涝覆盖物的 water gate 必须同时读取
  `LandformType.is_water(cell.landform)` 和 terrain water 语义
  (`OCEAN/COAST/LAKE/REEF/SEA_ICE/KELP`)。原因是 sea-ice daily pass 会把
  `cell_terrain` 翻成 `SEA_ICE`，而 landform 可能在同一 tick 或 fallback
  路径中滞后；此时 `SEA_ICE`/`LAKE` 仍必须按水体处理，不得获得陆地
  snowpack、snow_cover 或 FLOODING cover。C++ `run_weather_distribute_pass`
  必须 mirror 这个组合谓词。

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

### 半真实大气模型（2026-06-19）

> ⚠ **历史调参演进（19a/b/c）**：本节记录 2026-06-19 三次 CSV 标定的演进过程，其中相当
> 一部分参数与机制已被 **2026-06-20 根因重构**替换（carryover→EMA、去纬度门/季节分类、
> vapor_precip_sink / vapor_transport_gain / precip_rh 重新标定）。**当前真实状态以本节末
> 「根因重构（2026-06-20）」小节为准**；下面 19a/b/c 仅作演进参考、不要据此改代码。

目标：内陆形成随风移动的雨云带、各类天气由温度/风场/洋流/地形自然涌现分布（不再硬编码
纬度/季节）。改动同时落在 GDScript hot-loop (`field_solver.gd::run_slice`) 与 C++ 镜像
(`DCWorldExt::run_weather_field_solve_pass`)，两边公式必须逐行一致。

水汽动态化（让 vapor 成为随风搬运的预报量，而非静态气候湿度场的平滑版）：

- `vapor_memory` 对静态 `base_m`(气候湿度)的锚定由 `0.18 → 0.06`，vapor 主要由
  跨日 `prev_vapor` + 上风平流决定，parcel 随风迁移深入内陆。
- `weather_ocean_evap_gain 0.20 → 0.55`：海洋成为强水汽源，喂给上风平流。
- `weather_land_evapotranspiration_gain 0.70 → 0.85`：内陆植被/土壤水汽再循环。
- `weather_vapor_precip_sink 0.95 → 0.70`：下雨不再抽干整层水汽，下风格继承水汽 →
  雨带向内陆推进（与 `weather_field_solver_test` 早已配置/验证的 0.70 对齐）。
- `weather_precip_carryover_max 0.02 → 0.08`：降水跨日/跨格随风延续。
- carryover/平流接力门槛与 RH 触发阈解耦：`relative_humidity >= max(0.45, rh_threshold-0.12)`，
  `vapor_floor_factor=(rh-0.45)/0.40`，让随风迁移的雨带进入略干下风格后仍维持一段。
- `weather_precip_rh_threshold 0.68 → 0.60`：降水触发门槛适度下调。
- `weather_field_advect_steps` 上限 `2 → 4`、默认 `3`：同日上风采样更远。
- 凝结云水 `cloud_water` 随风从上风格平流（`lerp(self, upstream, wind_mag*0.7)`），
  与既有 `precip` 沿风 carryover 配合 → 云团整体随风飘动，而非原格生灭。

天气类型分类重排（`_classify_field_weather_core` / `wf_classify_field_weather_at`）：

- 引入 `lat_signed ∈ [-1,1]`（地图顶部=北半球<0）与 `season_idx`→`local_summer`
  的半球感知季节强度（南半球季节相反）。
- 判定顺序：BLIZZARD → STORM → MONSOON → RAIN → FOG → HEATWAVE → DROUGHT → CLEAR。
- STORM：中低纬 (`lat_abs<0.70`)，夏季降低门槛 (`inst/precip` 随 `local_summer` 插值)，
  暖海核心阈值相对旧版只降不升（保证既有 STORM 用例仍成立）。
- MONSOON：低纬 (`lat_abs<0.42`) + `local_summer>0.5` + `precip>0.06`。
- FOG 紧接 RAIN 且 precip 阈值衔接（`precip<0.030` vs RAIN 的 `>0.030`），不再被判定顺序饿死。
- HEATWAVE：副热带 (`lat_abs<0.62`) + 夏季 + 高温干燥；DROUGHT：持续干燥（暖/寒流偏置）。

parity 检查点（改任一侧务必同步另一侧）：`vapor_memory` 锚定系数、`cloud_water`
上风平流、carryover RH gate / vapor_floor_factor、分类阈值与判定顺序、以及
`climate_profile.gd` / `weather_system.gd` 默认值与 C++ knob fallback 默认值。

### 海面降水抑制 + 类型阈值标定（2026-06-19b 调参）

首版改完后实测（CSV）发现海面 96% 在降水、且 STORM/MONSOON/HEATWAVE/DROUGHT 全为 0%
（全图过湿）。据此二次标定：

- **海面降水抑制**：海洋仍是强水汽源（`surface_vapor_source` 不变，内陆雨带不削弱），
  但海面**降水**按 instability 门控——平静/冷洋面只保留 `1-ocean_precip_suppression`（≈15%）
  几乎不降水，强对流暖洋面（`instability` 高，热带风暴带/ITCZ）保留全量。公式：
  `ocean_conv=clamp((instability-0.45)/0.45,0,1); precip *= lerp(1-suppression, 1, ocean_conv)`。
  作用在 `precip` 最终值上（覆盖 `precip_raw` 与 `cloud_water_rain` 两条来源），
  替代原先只乘 `precip_raw` 的写法。GDScript 与 C++ 镜像一致。
- **类型阈值按实测场范围下调**（land inst p95≈0.67 / precip p95≈0.089 / temp p95≈0.69）：
  STORM gate `inst 0.70→0.62..0.54、precip 0.105→0.090..0.062`（随 local_summer 插值）；
  warm_ocean_core `inst>0.70 precip>0.07 cloud>0.28`；MONSOON `precip>0.055`；
  HEATWAVE `temp>0.66 vapor<0.30 cloud<0.18`；DROUGHT `vapor<0.22 cloud<0.12 temp>0.45`。
  目的是让 STORM/MONSOON/HEATWAVE/DROUGHT 在对应纬度/季节真正可达，不再被 RAIN/CLEAR 垄断。

### 第三次标定（2026-06-19c，依据 CSV 实测分布）

首两版后实测仍偏雨：海面 60% 在降水、STORM/MONSOON/HEATWAVE/DROUGHT 仍 ~0%。逐项归因：
- 海面 `ocean_an(tta)` 实测几乎全 ≈0，但 `instability` 普遍 ~0.47 → 用 instability 门控海面降水
  几乎无效。改为 **`ocean_drive = max(clamp(ocean_an/0.16), clamp((instability-0.74)/0.18))`**：
  仅暖洋流异常或极强对流(ITCZ 级)放开海面降水，其余海面 `precip *= 1-ocean_precip_suppression`。
- STORM：中纬风暴带候选(inst>0.54 & precip>0.062)确实存在却全被季节门(winter gate 0.62/0.090)挡掉。
  门改为弱季节依赖：`inst 0.56→0.50、precip 0.068→0.056`（风暴非夏季独有）。
- HEATWAVE：实测最热陆地恰最湿(hot 格 vapor p50≈0.42)，`vapor<0.30` 永不可达。
  改为以"高温(temp>0.70)+少云(cloud<0.30)+无降水"为准，去掉强制低 vapor。
- DROUGHT：即便 vapor<0.22 的格 cloud 仍 p50≈0.27（冷格低 vapor 但高 RH）。改以
  `cloud<0.22 & precip<0.020 & temp>0.48 & vapor<0.34` 为主（低云暖区）。

离线回代验证（用上一轮 CSV 场值套新逻辑）：RAIN 38%→~24%、CLEAR 49%→~67%、
STORM 0→2~3%、FOG 0.1%→~4.7%(冷洋面海雾)、BLIZZARD 13%→~1.4%、DROUGHT/HEATWAVE 由 0 转正。

### 根因重构（2026-06-20）：降水惯性化 + 打破水汽稳态 + 去纬度门（**当前真实状态**）

针对"天气逐 tick 横跳/不连续 + 海量永雨永旱 + 纬向直线条带"的根因重构，三阶段落地。
GDScript (`field_solver.gd::run_slice`) 与 C++ (`run_weather_field_solve_pass`) 仍双份镜像。

**阶段1 — 降水惯性化（消除横跳/不连续）**：
- `precip` 改为带时间状态的 EMA：`precip = lerp(prev_precip, precip_target, weather_precip_inertia)`
  （`weather_precip_inertia` 默认 `0.30`，新增 ClimateProfile knob）；`precip < 0.003` 归零。
- **删除**脉冲放大三件套：carryover `precip_floor` 跨日叠加、`precip_cls` 拖尾、
  `precip_gate`/`fog_cloud_gate` 分类滞回。时间连续性统一由 EMA 提供，分类回归**单阈值**。
- `precip_target = max(precip_raw, cloud_water_rain)`（不再叠加 carryover floor）；
  云水降水消耗率 `0.42 → 0.22`，削弱"积累-暴耗"自激振荡。

**阶段2 — 打破水汽稳态（消除永雨永旱）**：
- `weather_vapor_transport_gain 0.92 → 0.75`：vapor 不再被平流摊平锁成稳态，本地蒸发-降水收支更主导。
- `weather_vapor_precip_sink 0.70 → 0.85`：下雨更快耗尽本地水汽 → "雨→变干→再积累"松弛循环。
- `weather_precip_rh_threshold 0.60 → 0.70`：凝结只在真正高湿(RH>0.70)发生，拉开干湿对比、还原晴空。
- `weather_ocean_precip_suppression 0.85 → 0.95`：静洋面压到阈下，降水集中到 convergence /
  frontogenesis / 暖流异常 的空间强迫带（`ocean_drive = max(ocean_an/0.16, (inst-0.90)/0.10,
  (conv-0.38)/0.16, fronto/0.16)`），其余洋面转晴。`vapor_memory` 锚定保持 `0.18`（19a 的 0.06 未采用）。

**阶段3 — 去纬度门 + 做减法**：
- 分类 `_classify_field_weather_core` / `wf_classify_field_weather_at` **删除 `lat_norm` /
  `lat_signed` / `season_idx` / `local_summer`**：类型边界由温度/湿度等弯曲物理场涌现，消除沿纬线的
  直线天气带。签名简化为 `(temp, vapor, cloud, precip, instability, ocean_an, wind_speed, temp_anom)`。
- 判定顺序：BLIZZARD → STORM → MONSOON → RAIN → FOG → HEATWAVE → DROUGHT → CLEAR。关键阈值：
  `meaningful_precip = precip>0.030 或 (precip>0.022 & cloud>0.22 & vapor>0.28)`；
  STORM `warm(temp>0.55) & humid(vapor>0.28) & ((inst>0.55 & precip>0.060) | warm_ocean_core)`；
  MONSOON `warm & vapor>0.40 & precip>0.055 & cloud>0.45`；FOG `vapor>0.34 & cloud>0.14 &
  precip<0.030 & temp<0.55`；HEATWAVE `hot(temp>0.64) & temp_anom>门 & cloud<0.38 & precip<0.025`；
  DROUGHT `cloud<0.22 & precip<0.020 & temp>0.48 & vapor<0.34`。
- 清理 `lat_norm` 僵尸链（`cell_lat_norm` knob、`LATN` 指针、`soa_lat_norm` 等）与死代码
  （GDScript `_run_weather_field_gdscript_loop_inplace`、cell 版 `_classify_field_weather`）。
- `field_precip_decay` / `field_precip_carryover_max` 已成**僵尸 knob**（C++/GDScript hot-loop 均
  不再读），仅 ClimateProfile/knobs 链路尚存传递，待后续删除。

**parity 检查点**（改任一侧务必同步另一侧）：`vapor_memory` 锚定系数、`vapor_transport_gain`、
precip EMA(`weather_precip_inertia`)、`ocean_drive` 海面抑制、`precip_rh` 阈、分类阈值与判定顺序、
以及 `climate_profile.gd` / `weather_system.gd` 默认值与 C++ knob fallback 默认值。







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
  `MapBaker.run_daily_wind_field_update(map, world, cfg, hex_size, season_phase,
  sim_day, stage)` calls `run_slp_field_pass` and/or `run_wind_field_pass`,
  publishing `cell_slp`, `cell_wind_x/y`, and `cell_wind_speed` back to the C++
  slots / `MapData` mirror.
- 2-tick SLP/wind split (`plan/daily-wind-stage-split`, profile flag
  `ClimateProfile.daily_wind_split_passes`, default `true`): the `stage`
  argument selects which kernels run this tick — `"slp"`, `"wind"`, or `"both"`.
  `OceanCurrentsJob` alternates by game-day parity (`day_index % 2`): even days
  run SLP only (~3ms), odd days run wind only (~1ms). The first prepass after a
  reset (and any cold start where `map.slp_arr` size is stale) runs `"both"` as a
  safety net so wind never reads an empty/old SLP. This drops the single-tick SUS
  peak from ~5ms (SLP+wind together) to ~3ms, freeing budget for the starved
  atlas upload. Each kernel still refreshes daily-but-staggered; at 20–50x the
  every-other-day cadence is imperceptible. Set the flag `false` to restore the
  merged every-day path (regression / low-speed precision).
- The prepass report splits the two kernels for attribution: `slp_ms` /
  `wind_ms` plus `slp_stage_name=daily_wind_slp` / `wind_stage_name=
  daily_wind_wind`, `slp_ran` / `wind_ran`, `stage_requested`, and
  `dominant_stage` / `dominant_stage_ms`. `path` reflects the stage actually run
  (`gdext_daily_wind`, `gdext_daily_wind_slp`, or `gdext_daily_wind_wind`). The
  ocean job surfaces these on the slice report (and `substage=dominant_stage` on
  wind-only days) so the scheduler log attributes the budget to SLP vs wind
  without changing the kernels. See `scheduling-and-job-graph.md` for the report
  shape.
- SLP-internal instrumentation: `run_slp_field_pass` returns `slp_passA_ms`
  (per-cell baseline build), `slp_passB_ms` (6-neighbor smoothing), `slp_norm_ms`
  (recenter + p95 sort + scale), and `slp_marshall_ms` (prev-blend + recenter +
  delta + slot publish). `elapsed_ms` (= `slp_ms`) excludes the trailing
  diagnostic-stats sort, matching historical behaviour. These flow through the
  prepass report and the ocean breakdown so the `daily_wind/slp_internal` log
  line shows where the SLP cost lands.
- Latitude LUT (`plan/slp-lat-lut`): passA's baseline used to call
  `dc_insolation_now` (~9 transcendentals) and `dc_insolation_annual_mean`
  (a 16-sample annual integral, ~144 transcendentals) plus `base_lat`/`s_lat`
  trig **per cell** — ~155 transcendentals × `n_cells` (~1M for 6400 cells) every
  pass. All of these are functions of latitude `ny` only (the annual mean is even
  season-independent), so `run_slp_field_pass` now precomputes `base_lat(ny)` and
  `solar_heat(ny)` into a `slp_lat_lut_bins`-entry LUT (default 1024, clamp
  16–8192) once per pass and the cell loop does a single linear interpolation.
  Only the genuinely per-cell `synoptic` term (uses cell index `i`) keeps its two
  transcendentals. This drops passA from ~2.9ms to a few tenths of a ms. Set
  `slp_lat_lut_bins=8192` for a near-exact A/B reference; interp error at 1024
  bins (~0.18° latitude) is far below the natural day-to-day `slp_delta_p95`.
- 让天气流动 phase 1 (2026-06-21) — mobile low-pressure systems: `run_slp_field_pass`
  adds an optional `mobile_low` term to each cell's SLP — `N` Gaussian low-pressure
  centers `−amp·exp(−r²/2σ²)` whose normalized centers drift west→east (mid-latitude
  westerly steering), wrap in x once per `slp_mobile_low_period_days`, with a slow
  latitude wobble. Centers are hashed deterministically from `(world_seed, j)` and
  precomputed **outside** the cell loop; the hot loop only evaluates the Gaussian
  falloff, reusing the C-feature `cell_pos_x`-normalized coords + bounds. Knobs (from
  `ClimateProfile` via `map_baker`): `slp_mobile_low_count` (default 3, clamp 0–8),
  `slp_mobile_low_amp` (default 0.10), `slp_mobile_low_sigma` (default 0.16 of map
  width), `slp_mobile_low_period_days` (default 38). `count=0` / `amp=0` / missing
  knob / missing `cell_pos_x` slot all degrade to off (backward compatible with old
  DLLs). Purpose: inject a **moving convergence source** so the existing downstream
  chain (wind reads the SLP gradient → convergence → `cloud_source`/frontogenesis →
  cloud-water advection) carries rain bands across the map and breaks the steady-state
  permanent-rain / permanent-drought pattern, without touching the bit-equal vapor
  mirror. C++-only: the SLP GDScript fallback has already diverged (no synoptic/moist
  terms) and production always runs the gdext path. `mobile_low` flows through Pass B
  smoothing, p95 normalization, and the `prev_slp` inertia like any other SLP term.
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

### Cell-index 间接寻址（province-ID indirection，唯一动态视觉路径）

plan: *cell-index atlas indirection*。把"hex 内恒定"的视觉 atlas 改为
**静态 cell 索引图 + per-cell LUT** 间接寻址，让 shader 自己做 pixel→cell 解析，
把 fan-out 目标从 `n_pix`（~62 万）压到 `n_cells`（~2400），消除每日数 MB 的
per-pixel GPU 上传。

`cell_indirection_active()` 现在恒为 true。旧 per-pixel dynamic/ecology/smooth/ice atlas
不再作为 A/B fallback；bake / upload / render 都走 `map_index_atlas + enum_lut + dyn_lut + eco_lut`。

数据结构（`WorldData`）：

| 字段 | 格式 / 滤波 | 内容 | 更新频率 |
| --- | --- | --- | --- |
| `map_index_atlas`（`WorldData.enum_atlas_tex`） | RGBA8 / **NEAREST** / derived_size | R=biome；G/B=cell.index 低/高字节；`0xFFFF`=map 外哨兵；A=保留 | `bake_world` + biome dirty |
| `enum_lut_tex` | RGB8 / NEAREST / lut_dims | per-cell biome/veg/cover | daily 全量重烘（~0.1-0.3ms） |
| `dyn_lut_tex` | RGBA8 / NEAREST / lut_dims | per-cell temp/wet/snow/(ice\|vitality) | daily |
| `eco_lut_tex` | RGBA8 / NEAREST / lut_dims | per-cell foliage/stress/transition/growth | daily |
| `weather_lut_tex` | RGBA8 / NEAREST / lut_dims | per-cell R=weather_type / G=intensity / B=cloud / A=precip | daily（软依赖：天气未就绪时整段 0 → 无云） |
| `lut_dims` | Vector2i | `(min(n_cells,2048), ceil(n_cells/lut_w))` | bake_world |

入口：

- 烘焙：`map_baker.gd::_encode_enum_atlas` 产出 map-index atlas；`bake_cell_luts` 产出四张 LUT（enum/dyn/eco/weather）。
- daily 刷新：`map_baker.gd::refresh_cell_luts_daily`，由
  `dynamic_visual_atlas_upload_system.gd::tick` 每 stride 调用一次（flag 开时该 tick
  跑完 LUT 重烘即 **early-return**，整段 4-phase / C++ `run_atlas_pipeline_step` 逐像素
  上传被跳过，见下方"单一间接寻址路径"）。stride 节奏由 `StridePolicy` 控制，刷新频率
  与旧路径等价。
- **编码权威路径**：map-index atlas 由 GDScript baker 在 `_encode_enum_atlas` 里一次 fan-out；
  独立 `encode_cell_index_tex` 已退役。LUT 仍优先走 C++：
  - `DCWorldExt::encode_cell_luts(opts)`：读 8 个 SoA slot（temp/moist/snow/vit/sea_ice/
    terrain/vegetation/cover）→ per-cell enum/dyn/eco LUT（scalar tight loop，n_cells≈2400）。
    另读 4 个 weather slot（`cell_weather_type/intensity/cloud/precip`）→ weather LUT；weather slot
    **软依赖**：未初始化（size < n_cells）时该段全 0（云不显示），enum/dyn/eco 仍正常、不整张回退 GDScript。
    复用 `pk_atlas_sig_dynamic` / `pk_atlas_sig_ecology`（与 fan-out 编码器同一公式 → bit-equivalent）。
    eco `transition_age` 由 `AtlasPipelineState::lut_prev_veg/lut_prev_vit/lut_transition_age`
    自维护（与 4-phase pipeline 的 eco 状态相互独立；`cache_valid=false` / 首帧 / `invalidate_atlas_csr_cache`
    后冷启归零）。返回 `path`/`elapsed_ms`/`published_to_slot=false`（LUT 是渲染产物，不进 slot）。
- shader：`shaders/include/cell_indirect.gdshaderinc`（`decode_cell_index` / `cell_lut_uv`
  / `sample_dyn_lut_smooth` / `sample_eco_lut_smooth`），由 `world_map.gdshader` SETUP 消费。
  `weather_overlay.gdshader` 内联同款 `decode_cell_index`/`cell_lut_uv`（避免引入 dyn/eco 依赖），
  在 `sample_field_weather` 经 cell-index 间接寻址读 `weather_lut` 逐格驱动云分布（4-tap 双线性
  柔化 intensity/cloud/precip，type 取中心 cell）；旧 `weather_front_*[]` 椭圆云通路已删除。
- 绑定：`hex_renderer.gd::_apply_uniforms`（`map_index_atlas` + enum/dyn/eco LUT + `lut_dims`）；
  `weather_lut` + `lut_dims` 由 `_weather_layer.setup` 绑给 weather_overlay 材质。

shader 路径（`world_map.gdshader` fragment SETUP）：

- **enum**（Stage B）：`enum_lut[decode_cell_index(uv)]`；邻域 biome 直接采 `map_index_atlas.r`。
- **dyn/eco/ice**（Stage C）：desktop 4-tap 双线性（在索引图 bilinear footprint 上取
  4 个 cell 的 LUT 值按子像素权重混合，补回跨 cell 边界平滑，替代旧 CPU box-blur 的 LINEAR
  消边）；mobile 三档退单点 NEAREST（接受轻微 hex 阶梯，省 fetch）。海冰随 `dyn_lut.a` 一并迁移。
- **scalar 退役**（Stage D）：moisture 取 `dyn_lut.g`、latitude 用 `uv.y` 解析重建；
  `scalar_atlas` 不再生成、绑定或采样。旧 `flow` 河流 SDF 视觉层退化为 0。

**单一间接寻址路径（2026-06-18）**：贴图按"是否被间接寻址替代"分两类处理：

- **保留贴图（各自独立更新路径，与退役的 DVA 逐像素动态 atlas 路径无关）**——
  注意它们**并非都"静态"**，只是其更新通道不是间接寻址要替代的那条：
  - `map_index_atlas`：**biome 变化时更新 R 通道**。veg/cover 不再写入 per-pixel atlas，
    由 `enum_lut` 提供。主 shader
    中心 enum 读已走 `enum_lut`，但 `shore_common` / `water` / `weather_overlay` 在邻居
    偏移 UV **逐像素采样邻居 biome**，仍需整张 per-pixel atlas，故保留。
  - `scalar_atlas` 已退役：shader 中性化 `flow=0`，moisture/latitude 由 LUT/uv 取代。
  - `vector_atlas` 已退役：`world_map` 使用中性零向量，`weather_overlay` 风向走 axis-only 近似（云分布另经 `weather_lut` 逐格驱动）。
  `scalar_atlas` / `vector_atlas` 不再生成、绑定或采样。

**洋流/风场逐像素视觉退役（`ocean_current_visual_enabled`，2026-06-18）**：
`DCFeatureFlags.ocean_current_visual_active()` 恒为 false。`vector_atlas` 的逐像素光栅、
encode、GPU 上传和 shader fetch 均被删除；只保留 per-cell 风/洋流求解。
  1. `map_baker.gd::_bake_initial_vector_buffers` 清空像素 buffer 提前返回
     （per-cell solve 已在前一行 `_bake_initial_physical_circulation` / 物理 solve 写入 `HexCell`）；
     `bake_world` / 延迟物理 / `rebake_ocean_currents` 都直接保持 `vector_atlas_tex=null`；
     `commit_ocean_buffers` 跳过 `vector_atlas_tex` 重建/更新（防御性，正常走不到）。
  2. `ocean_currents_job.gd` 强制 `_phys_need_visual=false` → 求解完成即 `round_done`，
     跳过 stage 7 `WIND_RASTER` + pixel slices + `commit_ocean_buffers`；per-cell SLP/风/洋流
     solve（上方 stages + `run_daily_wind_field_update` daily_wind prepass）照常跑。
  3. 着色器侧：`world_map` 固定 `vects=vec4(0.5)`，`weather_overlay` 风向回退 axis-only 漂移（云分布走 `weather_lut`）。
- **动态逐像素 atlas 已退役（不烤、不每日刷新）**：`dynamic_cell_atlas` /
  `dyn_atlas_smooth` / `ecology_visual_atlas` / `ice_state_atlas` 已被 `dyn_lut` / `eco_lut`
  （海冰走 `dyn_lut.a`）完全替代，flag 开时无任何 shader 消费者。收敛在两个 choke point：
  1. `map_baker.gd` 的 4 个 `rebake_*`（`rebake_dynamic_cell_atlas_only` /
     `rebake_ecology_visual_atlas_only` / `rebake_dyn_atlas_smooth` / `rebake_ice_state_atlas`）
     在 `cell_indirection_active()` 时返回 `_indirection_skip_atlas_report()`（no-op）。
     覆盖 `bake_world` 初始烘 + `SeaIceAtlasUploadSystem|Job` 顺带重烘 + DVA `_tick_oneshot`。
  2. `dynamic_visual_atlas_upload_system.gd::tick` flag 开时跑完 `refresh_cell_luts_daily`
     立即 early-return，跳过 C++ `run_atlas_pipeline_step` 与 4-phase 逐像素上传。
  这 4 张贴图的 `*_tex` 保持 null，`hex_renderer` 不再绑定对应 shader parameter；
  省每日 GPU 上传 + 4 张 derived RGBA8 显存。`hex_renderer` 的旧 per-pixel 海冰探针已退役。

旧 per-pixel 编码器代码仍可能作为历史 fallback 残留，但当前运行路径不再触达。

**`sea_ice_tex`（R8）退役开关（`sea_ice_atlas_enabled`，2026-06-16）**：与 cell-indirection 正交。
`sea_ice_tex` 是**已死贴图**——任何着色器都不 `texture()` 它（主海冰视觉由水路径 shader 按
水温/纬度/水深派生，indirection 开时走 `dyn_lut.a`），运行时 `SeaIceAtlasUploadSystem|Job`
早已不注册（`map_generator` 两条路径都 `_sea_ice_atlas_upload_job = null`），`bake_sea_ice_fraction_only`
也无 live 调用者。`DCFeatureFlags.sea_ice_atlas_active()`（Engine meta，默认缺失=**false 退役**），
由 `main.gd` 的 `@export var sea_ice_atlas_enabled`（默认 `false`）推送，**改勾选后需重新生成地图**。
当前行为：`bake_world` 不再 encode 那张全零 R8（省 ~0.6MB 显存 + 编码）、不分配
`sea_ice_fraction_buffer`；`prepare_sea_ice_fraction_atlas` / `upload_prepared_sea_ice_fraction_atlas` /
`bake_sea_ice_fraction_only` 全部 no-op。`hex_renderer` 绑 `sea_ice_tex=null` 安全（uniform 从不被采样）。
开为 `true` 仅为兼容旧调试/数据通道（`dots_soak_dump` 读 `sea_ice_fraction_buffer` 做哈希；
关时该 buffer 为空，dump 走 `n==0` 兜底）。**不影响任何海冰仿真**（仿真读 `cell.sea_ice_frac`）。

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

## Detail scatter（vegetation / 点缀散布，vegetation-visual-pcg 阶段 A）

主要入口：

- GDScript orchestration：`scripts/rendering/hex_renderer.gd`（按 `DecorationManifest` 或默认 grass/shrub/tree 生成 N 个 `ShrubLayer`）→ `scripts/rendering/shrub_layer.gd::_rebuild_instances` → `_rebuild_via_native`
- C++ per-instance fan-out：`gdext/src/world_ext.cpp::DCWorldExt::encode_detail_scatter`
- 触发：地图生成 / regenerate / 质量档切换时 `layer.setup()` → `_rebuild_instances()`（非每 tick，冷路径）。
- 不属于 SUS scheduler job，不计入 `sus/render/ui`。

当前状态：**混合 C++/GDScript**。GDScript 只做 per-cell（N≤2400）廉价预计算（suitability / attempts / climate_presence / 基础色 / size_density）；O(Σattempts) 的逐候选热循环（jitter+warp、world_noise/micro_gap 门、water/river 拒绝、acceptance、score cap）+ MultiMesh buffer 组装下沉 `encode_detail_scatter`。`_world_ext` 缺失 / 旧 DLL 无该方法 / C++ 返回 `fallback=true` 时透明回退到 `shrub_layer.gd` 的 GDScript 逐实例路径（`_last_scatter_path` 暴露实际路径 `gdext` / `gdscript`）。

输入 / 输出：

| 项 | 来源 | 备注 |
| --- | --- | --- |
| `keys` / `center_x,y` / `suitability` / `attempts` / `vitality` / `size_density` / `color_r,g,b,a` | `shrub_layer.gd` per-cell 预计算 | 仅"活跃 cell"（suitability>0 且 climate_presence>0.02）；长度 = K。 |
| `offset_is_water`（PackedByteArray，`grid_w*grid_h`，odd-r） | `shrub_layer.gd` 从 `_map` 栅格化 | C++ 复刻 `world_to_cube → cube_to_offset` 精确 `_is_water_position`；空位 / 越界置 1（拒绝）。 |
| `flow_buffer` + `flow_w,h` + `river_clear_threshold` | `WorldData.flow_buffer` / `derived_size` | C++ 复刻 `_bilinear_float` 做 river-body 拒绝。 |
| PCG / size / vitality 标量 | `ShrubVisualProfile`（质量档已解算的 `instance_cap` / `size_scale`） | 逐位对齐 GDScript fallback 同名公式。 |
| `buffer` + `instance_count` + `path` + `elapsed_ms` | 返回值 Dict | `buffer` = 每实例 16 float（transform2d 8 + color 4 + custom 4）；GDScript `multimesh.buffer = buf` 一次赋值。 |

关键契约：

- 纯 **buffer-encoder**：不读 `_slots`、不写 slot、不要求 `_bound`——散布是 render product，所有输入由 knobs flat PackedArray 喂入，地图刚生成 / climate slot 未绑定也能工作（同 `encode_overlay_atlas`）。
- `hash01` / `hash2i` / `value_noise2` / `smoothstep` 与 `shrub_layer.gd` 同公式同 64-bit 整型语义（GDScript `float`=double，`>>` 算术移位），native 与 fallback 输出近 bit-一致（仅 libm `sin` 末位差异）；这是确定性 stochastic 场，验收按聚合密度而非 bit-equal。
- MultiMesh 2D buffer 布局：`[xx, yx, 0, ox, xy, yy, 0, oy, r,g,b,a, u,v,seed,variant]`，与 `set_instance_transform_2d/color/custom_data` 等价。

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
- Warm ocean cores use the same exception in GDScript and
  `DCWorldExt::run_weather_field_solve_pass`: a warm/humid cell with
  `ocean_an > 0.12`, `instability > 0.80`, `precip > 0.10`, and `cloud > 0.26`
  classifies as `STORM` even if high-tail precipitation damping has pulled
  precip below the ordinary `0.16` storm threshold. This keeps tropical warm
  water convection from being downgraded to ordinary rain after the damping
  stage.
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
- Earth-like defaults now strengthen weather convergence cadence and gain
  (`weather_convergence_gain=0.50`,
  `weather_convergence_refresh_stride=2`) while reducing broad snow cover
  (`snowpack_accum_gain=0.08`, stronger melt, `snowpack_cover_full=0.32`,
  `snowline_temp_threshold=0.29`, `snowline_band=0.27`,
  `snow_accum_days_req=2`). This is intended to keep cold/elevated land snowy
  without letting lowland/plain snow coverage dominate the CSV distribution.

### Ocean current vector limits

- `PhysicalCirculationSolver.psi_to_ocean_current()` and
  `DCWorldExt::run_psi_solver_pass` apply the same final vector-magnitude
  clamp after response blending. `ocean_current_scale` controls PSI-gradient
  conversion; `ocean_current_max_magnitude` controls the final vector length.
- Current defaults keep the physical field below the old near-unit plateau:
  `ocean_psi_source_scale=0.06`, `ocean_current_scale=0.13`,
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

### PSI solver SOR warm-start (plan/psi-warm-start, 2026-06-17)

- `run_psi_solver_pass` solves the ocean stream-function ψ with SOR
  (Gauss-Seidel + over-relaxation, `psi_sor_omega≈1.4`). The cost is roughly
  `n_water × 6 × psi_total_iters`; with ~2200 water cells the old 40-iteration
  cold start was the dominant ~1ms inside the recurring `phys_psi_init` peak
  (SLP prepass + PSI stacking on the same tick).
- The stream-function changes only slightly day-to-day (the daily delta is just
  the wind-stress-curl increment), so the previous tick's converged ψ is an
  excellent initial guess. The kernel now **warm-starts** by default: at pass
  start it seeds `psi[k]` from the last value published to the `cell_ocean_psi`
  slot (mapped via `water_to_cell[k]`) instead of zero. SOR then starts from a
  near-converged state and only needs to absorb the small daily residual.
- Knob `psi_warm_start` (default `true`) gates this. With warm-start on,
  `psi_total_iters` was lowered `40 → 16` (`MapBaker._PHYS_PSI_TOTAL_ITERS`),
  cutting the PSI stage from ~1ms to ~0.3ms while *improving* convergence
  quality versus a 40-iteration cold start. Set `psi_warm_start=false` (and
  raise iterations) only for cold-start A/B comparison.
- Cold-start safety: on the very first solve (or whenever the slot is missing /
  size-mismatched / warm-start disabled) `PSI_PREV` is null and ψ falls back to
  the zero initial guess, so behavior degrades gracefully. The initial bake's
  physical solve already publishes ψ to the slot, so SUS round 1 is normally
  warm too.
- Validation: watch `phys_slice`'s `ocean_delta_p95` — it should stay smooth
  (no large per-tick jumps). A sudden increase after lowering iterations means
  under-convergence; raise `psi_total_iters` or re-check that warm-start is
  engaging.

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
