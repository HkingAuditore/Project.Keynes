# Runtime Domain 字段映射

本文是输入冻结和 Climate POD 垂直切片的当前字段契约。它只覆盖已经进入
`RuntimeEnvironmentSnapshot`、`RuntimeClimateStore` 的字段；当前模式仍为
`simulation_thread_mode=OFF`、`domain_pod_mode=SHADOW`、
`implemented_domain_mask=COMMIT`。这些 POD 值用于 worker 诊断和未来对拍，**不是**
Climate 的 ACTIVE 权威，也不会写回 `MapData`、纹理、atlas 或 GPU。

所有 worker 字段都不持有 Godot 值。`Dictionary`、`Variant`、`Object`、`PackedArray` 和
`MapData` 只允许存在于主线程的 capture facade。没有写入本表的字段不得加入 worker store。

## 约定

| 标记 | 含义 |
| --- | --- |
| owner | 当前唯一可变 owner；`capture` 是主线程复制边界，`worker-shadow` 是后台只诊断状态。 |
| hash | 是否进入对应 POD state/input hash。 |
| save | 是否进入 PKSR section；Climate 已使用独立 CLM2 section，仍需最终 parity gate。 |
| visual | 是否产生可消费视觉发布；本阶段全部为否。 |

浮点数均要求有限值。数组字段的长度必须为 `cell_count`，除非表中另有说明；日期是
`int64_t`，generation/revision 是 `uint64_t`，cell ID 是 `uint32_t`。

## RuntimeEnvironmentSnapshot

| 字段组 | 来源与单位 | owner | hash | save | visual | 约束 |
| --- | --- | --- | --- | --- | --- | --- |
| `generation`、`day`、`season_phase`、`climate_anomaly`、`dt_days` | 主线程世界/时钟；日、归一化相位、浮点 anomaly、实际逻辑日跨度 | capture | input | runtime envelope 元数据 | 否 | generation 单调；day 不倒退；phase/anomaly finite；`dt_days` 必须为 finite 且 `0 < dt_days <= 365`。 |
| `climate_input_complete` | 主线程 capture 完成标记；完整 Climate frame 才可作为未来 authority 输入 | capture | input | 否 | 否 | 为 true 时 catalog/map shape/topology 和所有 Climate lanes 必须完整；缺失直接拒绝，不允许默认值补齐。 |
| `vision_revision`、`topology_generation`、`fog_solved` | 地图/视觉 revision | capture | input | runtime envelope 元数据 | 否 | revision 单调语义由 capture owner 保证。 |
| `cell_temp`、`cell_temp_30d`、`cell_temp_365d`、`cell_temp_baseline_year` | 当前/历史温度与年度地理基线；现有 normalized/生产单位 | capture | input | 否 | 否 | finite，长度为 cell 数。 |
| `cell_base_moisture`、`cell_moisture`、`cell_plant_available_water`、`cell_soil_moisture`、`cell_water_balance_30d` | 地理湿度锚、运行湿度、植物可用水、土壤异常与 30 日水量平衡 | capture | input | 否 | 否 | finite，长度为 cell 数；`soil_moisture` 保持有符号异常语义。 |
| `cell_weather_precip`、`cell_weather_intensity`、`cell_weather_vapor`、`cell_weather_cloud_water`、`cell_weather_cloud`、`cell_weather_type`、`cell_weather_transition` | 天气字段与 transition 状态 | capture | input | 否 | 否 | 浮点 finite；byte 字段长度为 cell 数；生产 frame 不得缺失。 |
| `cell_snow_cover`、`cell_sea_ice_frac_prev`、`cell_river_discharge_30d`、`cell_vegetation_vitality` | 雪盖、上一日海冰、水文历史与植被状态 | capture | input | 否 | 否 | finite，长度为 cell 数。 |
| `cell_insolation_dev`、`cell_heat_input` | 日照偏差与热输入 | capture | input | 否 | 否 | finite，长度为 cell 数。 |
| `cell_wind_x`、`cell_wind_y`、`cell_wind_speed`、`cell_ocean_current_x`、`cell_ocean_current_y` | 单位风向/强度与海流向量 | capture | input | 否 | 否 | finite，长度为 cell 数；方向与强度分开，不得用向量模长替代 speed。 |
| `cell_air_mass_temp_anomaly`、`cell_ocean_thermal_anomaly`、`cell_local_thermal_anomaly`、`cell_temperature_transport_anomaly` | 风、海洋、局地与持久 TTA 异常 | capture | input | 否 | 否 | finite，长度为 cell 数；最终温度仍由 wind-surface 唯一合成。 |
| `cell_ema_initialized` | EMA 初始化状态 | capture | input | 否 | 否 | byte，长度为 cell 数。 |
| `cell_elevation`、`cell_lat_norm`、`terrain`、`landform`、`vegetation`、`cover`、`is_water`、`has_river` | 地图生成/MapData；高程、归一化纬度、枚举 | capture | input | 否 | 否 | float finite；其他数组长度为 cell 数。 |
| `neighbor_offsets`、`neighbor_indices` | 地图邻接；CSR 或兼容固定六邻接 | capture | input | 否 | 否 | CSR offsets 长度为 cell+1、单调、首项 0、末项等于 indices 长度；固定布局长度为 cell*6；索引仅 `-1` 或有效 cell。 |
| `hydro_parent` | 运行期水文父节点 DAG | capture | input | 否 | 否 | 长度为 cell 数；仅 `-1` 或有效 cell；捕获边界拒绝闭环，避免 worker 路由顺序不确定。 |
| `canal_edge_mask`、`canal_water` | MapData 运河数据；位掩码、现有水量单位 | capture | input | 否 | 否 | 水量 finite，长度为 cell 数。 |
| `trade_passable_lut`、`trade_move_cost_lut` | 贸易目录/LUT | capture | input | 否 | 否 | 同时为空或各 256 项；move cost 非负。 |
| `visible`、`building_resource_reserve`、`building_resource_extra` | 视野与经济桥输入 | capture | input | 否 | 否 | reserve/extra finite，长度为 cell 数。 |

输入验证由 `validate_runtime_environment_snapshot()` 完成。验证失败必须拒绝发布，worker
不得推进该输入对应的日；capture 成本不计入 worker daily timing。

## RuntimeClimateStore（SHADOW full-state kernel）

| 字段组 | 单位/来源 | owner | hash | save | visual | 状态与约束 |
| --- | --- | --- | --- | --- | --- | --- |
| `cell_count`、`generation`、`climate_generation`、`committed_day` | 容量、版本、日 | worker-shadow | 是 | 否 | 否 | bootstrap 一次分配；日循环不得 resize。 |
| `temperature`、`temperature_30d_ema`、`temperature_365d_ema`、`temperature_baseline`、`thermal_energy` | 气候温度/EMA/热能 | worker-shadow | 是 | 是（CLM2） | 否 | 14-stage POD kernel 计算；finite、长度为 cell 数。 |
| `moisture`、`plant_available_water`、`water_balance_30d`、`runoff`、`groundwater`、`river_storage`、`river_discharge`、`riparian_moisture` | 水文状态 | worker-shadow | 是 | 是（CLM2） | 否 | hydrology/stage-B-after-hydrology 后提交。 |
| `weather_precipitation`、`weather_intensity`、`vapor`、`cloud_water`、`cloud_cover`、`convergence`、`instability`、`weather_type`、`weather_transition` | 天气场 | worker-shadow | 是 | 是（CLM2） | 否 | worker 只保存数值；WeatherFront/GPU 仍是主线程资源。 |
| `snow_cover`、`snowpack`、`sea_ice` | 雪/海冰 | worker-shadow | 是 | 是（CLM2） | 否 | 形成/消融按固定顺序 replay。 |
| `vegetation_vitality`、`vegetation_growth_pressure`、`vegetation_heat_stress`、`vegetation_drought_stress`、`vegetation_cold_stress`、`vegetation_growth_streak`、`vegetation_drought_streak`、`vegetation_succession_candidate` | 植被反馈/演替候选 | worker-shadow | 是 | 是（CLM2） | 否 | 预分配 lane；不写回 MapData。 |
| `climate_anomaly`、`annual_temperature_drift`、`rng_state`、`annual_rng_state`、`history_cursor`、`temperature_history` | 年度状态与历史环 | worker-shadow | 是 | 是（CLM2） | 否 | RNG、历史环均纳入 hash/save。 |

`RuntimeClimateAuthority` 的 plan 只读上一份 worker state 和 immutable environment；commit
才写 store。其诊断经 `RuntimeThreadReport` 投射为 `climate_pod_*`，trace 队列指标经
`climate_trace_*` 投射，再由
`get_runtime_perf_snapshot()` 和 `PerfRecorder` 输出 `runtime_graph_climate_pod_*` CSV 列。

## 尚未允许的结论

- 没有 1000 日 OFF/SHADOW 全量 hash、事件和回执对拍前，Climate bit 不得加入
  `implemented_domain_mask`。
- 当前 kernel 是纯 POD 的确定性 shadow 实现；它已覆盖 graph stage 和完整状态面，但尚未证明
  与生产 Dictionary 图逐字段 bit-identical，因此仍不能视为 ACTIVE 权威。
- 首次差异按 `RuntimeClimateParityReport` 记录 day/stage/cell/field、reference/worker bit
  pattern、input/base generation、trace hash 和两侧 state hash；不使用全局 epsilon 掩盖差异。
- 主线程不读取 worker store；视觉层只能在未来通过 immutable snapshot/intent 消费提交结果。

## Shadow domain runner diagnostics

`RuntimeThreadReport` exposes `domain_authority_planned_mask`,
`domain_authority_committed_mask`, `domain_authority_ack_count`, input/state
hashes, plan/replay timings, and `domain_authority_fallback_reason`. These are
diagnostic-only fields; they do not expand the domain mask or make the runner
authoritative. The runner is Godot-free and never writes MapData.
