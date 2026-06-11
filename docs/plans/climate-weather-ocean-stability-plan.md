# Climate / Weather / Ocean Stability Plan

> Scope: 针对 `tmp/tile_data_record_20260611_205704.csv` 暴露的天气诊断错位、天气/收敛更新稀疏、温度/湿度/TTA ping-pong、洋流物理解算冻结与洋流强度饱和问题，按 P0 到 P3 顺序落地修复。
>
> Current-runtime references:
> - `docs/cpp-dots-runtime/architecture-overview.md`
> - `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`
> - `docs/cpp-dots-runtime/scheduling-and-job-graph.md`
> - `docs/cpp-dots-runtime/computation-pipelines.md`
> - `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`

## Grounding Summary

### 现有机制

- GDScript 是 orchestration 层：`main.gd` 采集样本，`MapGenerator` 组装 C++ pass knobs、调度 fallback，`WeatherSystem` / `OceanCurrentsJob` 管理 stage state machine。
- `MapData` 是 GDScript 可见的 SoA 镜像，`DCWorld` 是 GDScript DataCore world，`DCWorldExt` 是 C++ slot / SoA compute world。C++ pass 写 slot 后，必须通过 flush / snapshot / `published_to_slot=true` 让 GDScript、MapData、渲染或后续 GDScript fallback 看见。
- `refresh_climate_daily`、`weather_refresh`、`ocean_currents` 由 SUS/DCSystem 调度。`must_run=true` 只绕过 scheduler-wide frame budget gate，不绕过 job policy、depends 或 job 内部 state machine。
- Ocean physical chain 和 pixel raster 是两类工作：physical SLP / wind / PSI / upwelling 影响模拟权威；pixel raster / atlas commit 影响可视化。runtime 文档要求 visual upload 可以被 budget / stride 滞后，但 physical solve 不能长期冻结。

### 受影响域

- Logic: weather field classification、convergence refresh、ocean current solve、ocean heat transport、climate daily finalizer。
- Config: `ClimateProfile` 中 weather convergence stride、ocean current scale / limit、TTA blend / cap 等参数。
- Components / data bridge: `cell_ocean_current_x/y`、`cell_temperature_transport_anomaly`、`weather_*` arrays、`weather_dirty_mask`。
- Hooks / orchestration: `main.gd` diagnostics sample、`tile_data_recorder.gd` CSV row generation、`OceanCurrentsJob.run_slice()`。
- Workers / C++: `DCWorldExt::run_weather_field_commit_pass`、`run_psi_solver_pass`、`run_ocean_water_pass`、`run_ocean_land_pass`、`run_climate_pass_b`。

### 非目标

- 不新建 parallel climate/weather/ocean subsystem。
- 不改变地图数据模型或 component schema，除非 P2 评估证明 TTA 新参数必须进 schema；默认优先复用 `ClimateProfile` 与现有 `cell_temperature_transport_anomaly`。
- 不把低 N 的 weather front object layer 迁移到 SIMD / thread。

## P0: 修正天气诊断与 CSV 可信度

### 目标

先修数据采样链路，让后续 P1-P3 验证建立在可信指标上。当前 CSV 中 `weather_dirty_count=0`、`active_weather_ratio=0` 与 `weather_dirty_mask` 大量 dirty 同时出现，根因是 recorder 从 `sample["climate"]` 读取 weather 字段，而真实字段由 weather breakdown 产生。

### 涉及文件

- `Project/project-keynes/scripts/main.gd`
- `Project/project-keynes/scripts/ui/tile_data_recorder.gd`
- `Project/project-keynes/scripts/geography/map_generator.gd`
- `Project/project-keynes/scripts/weather/field_solver.gd`
- `gdext/src/world_ext.cpp`
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`

### 具体步骤

1. 确认 `main.gd` 每个采样入口都写入 weather breakdown。
   - `_collect_tile_data_sample` 或同等 sample path 需要包含：
     - `sample["climate"] = generator.sus_climate_breakdown()`
     - `sample["weather"] = generator.sus_weather_breakdown()`
     - `sample["ocean_currents"] = generator.sus_ocean_currents_breakdown()`
   - 已存在只用于 F11/debug 的 `out["weather"]` 不等于 CSV sample 已经有 weather 字段，必须检查实际 recorder 输入对象。
2. 修改 `tile_data_recorder.gd::_base_row()` 的数据来源。
   - `weather_dirty_count` 从 `sample.get("weather", {})` 读取。
   - `active_weather_ratio` 从 `sample.get("weather", {})` 读取。
   - `water_budget_error` 优先从 weather breakdown 读取；如果 climate breakdown 仍有同名字段，可写清楚优先级：`weather.get("water_budget_error", climate.get("water_budget_error", 0.0))`。
   - climate 自有字段继续从 `sample["climate"]` 读取，不混用。
3. 增加 CSV 诊断字段，避免下次误判。
   - 新增 `weather_diag_present`：`sample.has("weather")`。
   - 新增 `weather_field_commit_path`：来自 `weather.field_commit_path`。
   - 新增 `weather_refresh_convergence`：来自 weather breakdown 中已有 `refresh_convergence` 时读取；没有则留空/false。
   - 不改变已有列顺序时可追加到末尾，避免破坏旧分析脚本。
4. 确认 C++ commit pass 的输出不需要改算法。
   - `DCWorldExt::run_weather_field_commit_pass` 已返回 `weather_dirty_count` 和 `active_weather_ratio`。
   - `field_solver.gd` fallback 也已经构造同名字段。
   - P0 不动 native weather math。
5. 更新诊断文档。
   - 在 `performance-diagnostics-playbook.md` 增加一条：CSV 中 `weather_dirty_count` 必须来自 weather breakdown，不是 climate breakdown。

### 验收指标

- 新 CSV 中 `weather_dirty_count` 与 `weather_dirty_mask` 非零趋势一致。
- 当 `weather_dirty_mask` 平均 dirty cells > 0 时，`weather_dirty_count` 不再长期全 0。
- `active_weather_ratio` 在 weather 更新 tick 上约等于 `weather_dirty_count / cell_count`。
- `weather_diag_present=true` 的样本覆盖率接近 100%，除非 generator 为空或地图未初始化。

### 验证方法

1. 静态检查：
   - `rg -n "sample\\[\"weather\"\\]|weather_dirty_count|active_weather_ratio" Project/project-keynes/scripts`
2. 运行一次短采样，至少 100 tick。
3. 用现有 CSV 分析脚本或临时 pandas 检查：
   - `weather_dirty_count == 0` 的比例。
   - `weather_dirty_count` 与 `weather_dirty_mask` dirty cell count 的相关性。
4. 检查 `[SUS-cpp]` weather_refresh breakdown 中 `field_commit_path` 与 CSV `weather_field_commit_path` 一致。

### 回滚方式

- 只回滚 `main.gd` sample 字段追加和 `tile_data_recorder.gd` weather 字段来源。
- CSV 新增列若影响外部脚本，可保留旧列语义并新增 `weather_*` 精确列，不删除旧列。

## P1a: 洋流强度向量限幅

### 目标

解决水域 `ocean_current` 大量饱和到 `sqrt(2)` 的问题。当前 C++ 与 GDScript fallback 都按 x/y 分量分别 clamp 到 [-1, 1]，导致向量模长可达 `sqrt(2)`，与 `physical_circulation_solver.gd` 注释中的 ocean_mag 目标区间不一致。

### 涉及文件

- `gdext/src/world_ext.cpp`
- `Project/project-keynes/scripts/rendering/physical_circulation_solver.gd`
- `Project/project-keynes/scripts/rendering/map_baker.gd`
- `Project/project-keynes/scripts/data/climate_profile.gd`
- `docs/cpp-dots-runtime/computation-pipelines.md`
- `docs/cpp-dots-runtime/gdscript-cpp-data-bridge.md`

### 具体步骤

1. 在 `ClimateProfile` 增加可调参数，默认保持保守。
   - `ocean_current_max_magnitude: float = 0.50`。
   - `ocean_current_scale: float = 0.30`，如果当前 scale 只在 `map_baker.gd` hard-code，则迁移为 profile 参数，默认仍为 0.30。
   - 参数说明写清楚：`scale` 影响 PSI gradient 转换，`max_magnitude` 是最终向量模长上限。
2. 修改 `map_baker.gd` PSI knobs。
   - 用 `profile.ocean_current_scale` 替代 hard-coded `"ocean_current_scale": 0.30`。
   - 传入 `"ocean_current_max_magnitude": profile.ocean_current_max_magnitude`。
3. 修改 `DCWorldExt::run_psi_solver_pass`。
   - 在 response blend 之后做 vector magnitude clamp：
     - `mag2 = cx*cx + cy*cy`
     - `if mag2 > max_mag*max_mag: scale = max_mag / sqrt(mag2); cx *= scale; cy *= scale`
   - 保留 NaN / inf guard；若 `max_mag <= 0`，fallback 到旧的 component clamp 或强制最小正值，避免全部变 0。
   - 不再用 per-component clamp 作为主要限幅；可保留最终 safety clamp 到 [-1, 1]，但它不应在正常路径触发。
4. 修改 `PhysicalCirculationSolver.psi_to_ocean_current()`。
   - 使用同一 profile 参数。
   - 在 `old_cur.lerp(target_cur, response_rate)` 后做同样的 vector magnitude clamp。
   - `solve_ocean_current_fallback()` 如仍写 ocean current，也要应用同一限幅 helper，避免 heat_transport=false 路径重新饱和。
5. 抽一个 GDScript 小 helper，避免两条 GDScript 路径不一致。
   - 例如 `_limit_ocean_current(cur: Vector2, max_mag: float) -> Vector2`。
   - C++ 不需要新增 API，只要公式一致。
6. 更新文档。
   - `computation-pipelines.md` 的 Ocean currents physical chain 增加“PSI current output uses vector magnitude limit”。
   - `gdscript-cpp-data-bridge.md` 不需要新增 bridge 规则，但可在 `published_to_slot` 调试段补充 ocean current 输出验证点。

### 验收指标

- 水域 `sqrt(ocx^2 + ocy^2)` 的 p50 / p90 / p95 / p99 不再集中在 `sqrt(2)`。
- 默认目标建议：
  - p50: 0.10-0.35
  - p95: <= 0.55
  - max: <= `ocean_current_max_magnitude + 1e-4`
- 陆地 current 仍为 0。
- `run_psi_solver_pass` 仍返回 `published_to_slot=true`，`cell_ocean_current_x/y` 能 flush 到 `MapData`。

### 验证方法

1. C++ 改动后 rebuild GDExtension，重启 Godot。
2. 运行 30 tick 与 300 tick 采样。
3. 对比修复前后：
   - `ocean_current_mag` 分位数。
   - `climate_ocean_mag_p95`。
   - `temperature_transport_anomaly_arr` sign flip 率。
   - `temp_arr` sign flip 率。
4. 检查 console：
   - `stage_psi_path=gdext`
   - `published_to_slot=true`
   - 无 `fallback_reason`。

### 回滚方式

- 将 `ocean_current_max_magnitude` 临时调回 `1.414214` 可近似恢复旧最大模长。
- 如果新参数引起资源兼容问题，保留 C++ 默认 fallback 到 0.50，GDScript 中用 `profile.get(...)` 探测避免旧 `.tres` 加载失败。

## P1b: 解耦 ocean physical solve 与 pixel raster / commit

### 目标

解决 CSV 中 `ocean_pixel_slice` 长时间占用同一个 ocean round，导致 physical SLP / wind / PSI / upwelling 只更新 4 次的问题。物理解算必须按合理频率推进；pixel raster / atlas commit 可以滞后。

### 涉及文件

- `Project/project-keynes/scripts/simulation/sus/jobs/ocean_currents_job.gd`
- `Project/project-keynes/scripts/simulation/systems/ocean_currents_system.gd`
- `Project/project-keynes/scripts/geography/map_generator.gd`
- `Project/project-keynes/scripts/rendering/map_baker.gd`
- `Project/project-keynes/scripts/data/climate_profile.gd`
- `docs/cpp-dots-runtime/scheduling-and-job-graph.md`
- `docs/cpp-dots-runtime/computation-pipelines.md`
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`

### 设计原则

- Physical authority round 和 visual raster round 分开计数、分开 progress。
- Physical round 完成后立即允许下一轮 physical solve 进入，不等待 pixel raster 完成。
- Visual raster 只消费“最后一次已发布的 physical fields”。如果 raster 落后，显示旧 atlas，但 simulation 继续读最新 `MapData` / DataCore slots。
- 不新建大 subsystem。优先在现有 `OceanCurrentsJob` 内拆两个内部状态；如果后续复杂度过高，再评估单独 visual job。

### 具体步骤

1. 在 `OceanCurrentsJob` 中拆分状态。
   - 保留 physical 状态：
     - `_phys_round_active`
     - `_phys_solve_done`
     - `_phys_phase_locked`
     - `_run_ocean_this_round`
   - 新增 visual 状态：
     - `_visual_round_active`
     - `_visual_phase_locked`
     - `_visual_next_pixel_idx`
     - `_visual_pending_commit`
   - 旧 `_round_active` 只作为兼容 report 字段，或明确改名并更新所有引用。
2. 修改 round start 逻辑。
   - `slow_due` 时，只要 physical 没有 active，就可以开新的 physical round。
   - 如果 visual 正在 raster，不阻止 physical round start。
   - 当 physical round 结束且需要 pixel rebake 时，只 enqueue visual rebake request：
     - 如果没有 visual active，立刻启动 visual round。
     - 如果已有 visual active，记录 `visual_rebase_pending=true`，等当前 visual commit 后用最新 phase 重启，或直接丢弃旧 visual round，按最新 physical snapshot 重烘焙。
3. 修改 pixel branch。
   - pixel raster 只推进 visual 状态，不再决定 physical round 生命周期。
   - `on_commit` 中区分 physical commit callback 与 visual atlas commit callback；如果当前 callback 只重置 per-cell sample cache，需要拆成两个 callback 或传入 reason。
4. 修改 `should_run()`。
   - daily wind prepass 和 physical due 优先。
   - visual pending commit / visual raster 可以让 job eligible，但不能让 policy 误判 physical 已经 active。
   - report skip reason 区分：
     - `physical_policy_gated`
     - `visual_policy_gated`
     - `visual_pending_commit`
     - `climate_defer`
5. 增加 report 字段。
   - `phys_round_active`
   - `visual_round_active`
   - `phys_stage_name`
   - `visual_stage_name`
   - `visual_lag_ticks`
   - `visual_pixel_progress`
   - `physical_round_id`
   - `visual_round_id`
6. 配置保护。
   - `ocean_currents_slice_count` 保持当前默认也应不再冻结 physical。
   - 如 visual backlog 仍高，新增 `ocean_visual_rebake_drop_stale: bool = true`，默认 true，跨季节 phase 时丢弃旧 raster round。
7. 更新 runtime 文档。
   - `scheduling-and-job-graph.md` 说明 ocean job 内部 physical / visual 双状态。
   - `computation-pipelines.md` 说明 pixel raster 滞后不会阻塞 physical solve。
   - `performance-diagnostics-playbook.md` 增加 `visual_lag_ticks` 和相关 skip reason 解释。

### 验收指标

- 300 tick 采样中 physical SLP / wind / PSI / upwelling 更新次数显著高于当前 4 次。
- `phys_sim_day` 不再只出现少数离散值；按配置预期推进。
- 长时间 `ocean_pixel_slice` 不再伴随 physical fields 完全冻结。
- `[SUS-cpp]` largest 可以仍指向 `ocean_pixel_slice`，但 `ocean_delta_p95` / `wind_delta_p95` / `slp_delta_p95` 应按 physical cadence 有变化。
- visual atlas 允许落后，但 `visual_lag_ticks` 应有上限；建议默认 <= 120 tick，超过则 drop stale visual round。

### 验证方法

1. 跑 30 tick，检查无 crash、无 NaN、无 fallback。
2. 跑 300 tick，比较：
   - `phys_stage_name` 序列。
   - physical fields changed intervals。
   - `visual_lag_ticks` 最大值。
   - `skipped[...]` 中新增 reason 是否符合预期。
3. 跑 1000 tick soak：
   - 0 crash。
   - no `frame_budget_exhausted` runaway。
   - no `visual_pending_commit` permanent stuck。
4. 视觉检查：
   - shader atlas 可滞后，但不能黑屏、错位、永久不更新。

### 回滚方式

- 保留旧单 round 路径 behind config：
  - `ocean_decoupled_visual_raster: bool = true`
  - 出问题时设 false 回到旧状态机。
- 如果不希望新增长期 config，可至少在 PR 内保留小范围 feature flag，soak 通过后再删除。

## P2a: TTA 源头平滑与温湿 ping-pong 抑制

### 目标

在 P1a / P1b 修复海流强度与频率后，处理仍存在的温度、湿度和 `temperature_transport_anomaly` ping-pong。核心是把 TTA 从“每轮 scratch 瞬时重算并可直接归零”改成“带低通、decay、源头 cap 的状态量”。

### 涉及文件

- `Project/project-keynes/scripts/geography/map_generator.gd`
- `Project/project-keynes/scripts/simulation/systems/climate_daily_system.gd`
- `Project/project-keynes/scripts/data/climate_profile.gd`
- `gdext/src/world_ext.cpp`
- `Project/project-keynes/scripts/data_core/component_schema.gd`
- `docs/cpp-dots-runtime/computation-pipelines.md`

### 前置条件

- P1a 完成，并确认 ocean current 不再大面积饱和。
- P1b 完成，或至少 physical ocean cadence 不再被 pixel round 长期阻塞。
- P0 诊断可信，能稳定观测 TTA、temp、moisture 的 sign flip / clamp hit。

### 具体步骤

1. 增加 profile 参数。
   - `temperature_transport_anomaly_source_cap: float = 0.08`
   - `temperature_transport_anomaly_blend_rate: float = 0.35`
   - `temperature_transport_anomaly_decay_rate: float = 0.12`
   - `temperature_transport_anomaly_zero_current_decay: float = 0.20`
   - 这些参数只影响 TTA 源头，不替代 daily finalizer 的 `temperature_transport_anomaly_daily_cap`。
2. 修改 native ocean knobs。
   - `_build_native_daily_ocean_knobs()` 传入 previous TTA array。
   - 传入 source cap、blend、decay 参数。
   - 当前 `_gdext_ocean_anomaly_work_buf` 每轮清零仍可作为 scratch，但最终写回时必须与 previous state 混合。
3. 修改 `DCWorldExt::run_ocean_water_pass`。
   - 对 `new_anomaly = temp_mixed - baseline` 先做 source cap。
   - 最终 `AOUT[i] = lerp(prev_tta, new_anomaly, blend_rate)`。
   - 对 zero current 或 advect_steps=0 的水格，不再直接 `AOUT[i]=0`，改为 `prev_tta * (1 - zero_current_decay)`。
   - 对非水格保持由 land pass 处理。
4. 修改 `DCWorldExt::run_ocean_land_pass`。
   - land anomaly from water neighbors 同样 source cap。
   - 如果 `weight_total == 0`，land TTA decay toward 0，而不是立刻归零。
   - 写 temp 时继续使用 fallback baseline 防止锁 0。
5. 修改 GDScript fallback 等价路径。
   - `_ocean_water_pass_soa`、slice impl、land pass fallback 中应用同样公式。
   - 保持 native / fallback A/B 可解释。
6. 检查 `run_climate_pass_b` 中 TTA 使用。
   - `d_coastal` 和 `t_eff = temp_final + TTA[i]` 暂不改公式，先让输入 TTA 稳定。
   - 如果 P2a 后 moisture 仍 ping-pong，再评估 P2b。
7. 修改 finalizer 只做安全钳制。
   - `_apply_daily_climate_finalizer()` 保留 temp daily cap 与 TTA daily cap。
   - 增加 diag:
     - `tta_source_cap_hits`
     - `tta_decay_count`
     - `tta_blend_rate`
8. 更新文档。
   - `computation-pipelines.md` 的 Ocean water / land 说明 TTA 是 low-pass state，不是纯 scratch。

### 验收指标

- `temperature_transport_anomaly_arr` sign flip 率明显下降。
  - 当前约 91.9%；目标先降到 < 35%。
- period-2 backtrack 比例明显下降。
  - 当前约 41.9%；目标先降到 < 15%。
- `temp_arr` 非零 sign flip 率下降。
  - 当前约 54%；目标先降到 < 25%。
- land moisture near 1.0 clamp hit 不再随 TTA 高频翻转同步出现。
- `climate_max_transport_anomaly` 不再长期贴近 daily cap。

### 验证方法

1. 用同 seed、同 map config 跑修复前/后各 300 tick。
2. 输出同样 CSV，比较：
   - TTA sign flip。
   - temp sign flip。
   - moisture sign flip。
   - clamp hit ratio。
   - precipitation distribution。
3. 检查沿岸切片，不只看全图平均：
   - polar coast。
   - temperate west/east coast。
   - tropical coast。
   - inland dry belt。
4. 若 native 与 fallback 都可跑，做 SAME_SOURCE 小样本对比，确认差异来自预期参数而非路径不一致。

### 回滚方式

- 把 `temperature_transport_anomaly_blend_rate` 设为 1.0、decay 设为 1.0 可近似恢复旧“瞬时写入/瞬时归零”。
- 如新参数引入旧资源兼容问题，GDScript 使用 `cp.get(...) != null` 检查，C++ knobs 使用默认值。

## P2b: 低温降水分类兜底

### 目标

减少极地/低温地块出现大量 RAIN 的自然规律违和。当前 field classification 中 cold 条件只覆盖部分 BLIZZARD 阈值，未命中时 `meaningful_precip` 会返回 RAIN。

### 涉及文件

- `Project/project-keynes/scripts/weather/weather_system.gd`
- `Project/project-keynes/scripts/geography/weather_type.gd`
- `Project/project-keynes/scripts/data/weather_profile.gd`
- `Project/project-keynes/scripts/rendering/weather_layer.gd`
- `docs/cpp-dots-runtime/computation-pipelines.md`

### 具体步骤

1. 明确分类策略。
   - `temp < SNOW_FREEZE_T` 且 meaningful precip: BLIZZARD。
   - `SNOW_FREEZE_T <= temp < SNOW_MELT_T` 且 precip/cloud/vapor 达标: BLIZZARD 或 cold rain hysteresis。
   - 如果当前 enum 没有普通 SNOW weather type，只使用 BLIZZARD 表示降雪天气；cover 层仍由 snow accumulation 处理。
2. 修改两个分类函数，保持 fast indexed 与 cell path 一致。
   - `_classify_field_weather_at(...)`
   - `_classify_field_weather(...)`
3. 保持低纬限制。
   - 如果 `low_lat` 且 cold 来自高海拔而非极地，可允许 BLIZZARD，但需要依赖 elevation / local temp，而不是单纯纬度禁用。
   - 不复用 emergent spawn 的“低纬永远禁 BLIZZARD”逻辑到 field classification，否则高山雪会失真。
4. 保留 hysteresis。
   - 用 `SNOW_FREEZE_T` / `SNOW_MELT_T` 防止 0.30 左右 RAIN/BLIZZARD 每 tick 互跳。
   - 如需要，可新增 `weather_snow_classification_margin` 到 `ClimateProfile`，默认 0.03。
5. 检查 visual/profile。
   - `WeatherType.WT.BLIZZARD` 已对应 snow grain visual。
   - 不新增 `WT.SNOW`，避免 enum / profile / renderer 扩散。

### 验收指标

- polar land 且 `temp < SNOW_FREEZE_T` 的 RAIN 比例接近 0。
- cold precip 不消失，只从 RAIN 转为 BLIZZARD。
- 中纬温带雨带不被大量误改为 BLIZZARD。
- weather front 数量、生命周期没有明显突变。

### 验证方法

1. 对 CSV 做地理切片：
   - polar land。
   - high elevation land。
   - temperate lowland。
   - tropical highland。
2. 对每个切片统计 weather type ratio by temp bucket。
3. 检查 `cover=SNOW` 的积累/融化是否仍按 `SNOW_FREEZE_T` / `SNOW_MELT_T` 滞回。

### 回滚方式

- 将 cold precip guard behind config：
  - `weather_cold_precip_as_blizzard: bool = true`
  - 出问题时设 false 回到旧分类。

## P3: 天气收敛刷新 cadence 与诊断补强

### 目标

在 P0-P2 后，重新评估 `weather_convergence_arr` 更新过稀的问题。P3 不先动 weather math，而是先让 cadence、native convergence boost、commit publish 的诊断足够清楚，再决定是否把 stride 从 4 调到 1。

### 涉及文件

- `Project/project-keynes/scripts/weather/field_solver.gd`
- `Project/project-keynes/scripts/weather/weather_system.gd`
- `Project/project-keynes/scripts/data/climate_profile.gd`
- `gdext/src/world_ext.cpp`
- `Project/project-keynes/scripts/ui/tile_data_recorder.gd`
- `docs/cpp-dots-runtime/performance-diagnostics-playbook.md`
- `docs/cpp-dots-runtime/computation-pipelines.md`

### 具体步骤

1. 补齐 diagnostics。
   - weather breakdown 增加或确认已有：
     - `field_solve_tick`
     - `field_convergence_refresh_stride`
     - `refresh_convergence`
     - `native_convergence_boost`
     - `weather_convergence_dirty_count`
     - `weather_convergence_delta_p95`
   - CSV 追加这些字段。
2. 检查 native convergence boost 是否发布结果。
   - 如果 native path 修改了 convergence arrays，确认写回 `weather_convergence_arr` 或对应 slot。
   - 如果只是临时用于 precip 计算，需要在 report 中明确 `convergence_published=false`，避免 CSV 误判。
3. 做三档实验，不直接改默认。
   - A: 当前 stride=4。
   - B: stride=2。
   - C: stride=1。
   - 每档同 seed 跑 300 tick。
4. 比较指标。
   - `weather_convergence_arr` changed ticks。
   - precip-convergence correlation。
   - weather type changed intervals。
   - weather_dirty_count。
   - weather_refresh avg/p95/max。
5. 决定默认值。
   - 如果 stride=1 性能 p95 可接受且降水空间分布更自然，改 default 到 1。
   - 如果 stride=1 太贵，选择 stride=2，并在 P1b 后确保 wind/current 输入不冻结。
   - 如果 convergence array 不该每 tick publish，只更新诊断字段，不强迫 array 变动。
6. 更新文档。
   - `performance-diagnostics-playbook.md` 写清楚 `refresh_convergence=false` 时 convergence 不变不是 bug。
   - `computation-pipelines.md` weather field 段写清楚 convergence 的刷新 cadence。

### 验收指标

- CSV 能解释每次 convergence 是否应该更新。
- 如果默认 stride 调整：
  - `weather_refresh` p95 增幅 <= 10%。
  - precipitation 与 convergence 的相关性高于当前近 0 状态。
  - weather generation/update interval 没有退化为每 tick 全图随机闪烁。
- `weather_dirty_count` 与 convergence refresh 的关系可观测。

### 验证方法

1. 同 seed 三档 A/B/C。
2. 每档生成 CSV 与 `[SUS-cpp]` 30 tick windows。
3. 对比地理切片：
   - windward coast。
   - leeward rain shadow。
   - polar coast。
   - inland dry belt。
4. 确认 `weather_convergence_delta_p95` 与 precip spatial change 同步。

### 回滚方式

- 保持 `weather_convergence_refresh_stride` 为 profile 参数。
- 如 stride=1 导致 p95 超预算，恢复默认 4，但保留诊断字段。

## 执行顺序与 PR 切分

1. PR-1 P0 diagnostics
   - 只改 sample / recorder / docs。
   - 产出可信 CSV。
2. PR-2 P1a ocean current magnitude
   - 改 C++ + GDScript fallback + profile knobs。
   - 需要 rebuild GDExtension。
3. PR-3 P1b ocean physical / visual decoupling
   - 改 OceanCurrentsJob state machine 和 reports。
   - 需要 300-1000 tick soak。
4. PR-4 P2a TTA smoothing
   - 改 ocean water/land native + fallback。
   - 需要 A/B 数值验证。
5. PR-5 P2b cold precip classification
   - 改 weather classification。
   - 可与 P2a 分开，降低调参耦合。
6. PR-6 P3 convergence cadence
   - 先补诊断，再按 A/B/C 决定默认 stride。

## 全局验收矩阵

| 指标 | 当前问题 | 目标 |
| --- | --- | --- |
| `weather_dirty_count` | CSV 长期 0 | 与 `weather_dirty_mask` 同步 |
| weather changed interval | 122/548 interval changed，诊断不完整 | 可解释 cadence，无全图闪烁 |
| convergence changed ticks | 仅 4 次 | 与 `refresh_convergence` report 一致 |
| polar cold RAIN | cold land RAIN 偏高 | `temp < SNOW_FREEZE_T` 时接近 0 |
| ocean physical updates | physical fields 仅 4 次 | 不被 pixel raster 长期阻塞 |
| ocean current mag | 大量 `sqrt(2)` 饱和 | p95 <= max magnitude |
| TTA sign flip | 约 91.9% | P2 后 < 35% |
| temp sign flip | 约 54% | P2 后 < 25% |
| moisture clamp ping-pong | 多 land cell 贴 1.0 | clamp hit 与 sign flip 明显下降 |

## 必跑检查

### P0 / docs-only

```powershell
rg -n "sample\\[\"weather\"\\]|weather_dirty_count|active_weather_ratio" Project/project-keynes/scripts
git -C Project.Keynes diff --check
```

### C++ 修改后

```powershell
scons platform=windows target=template_debug dev_build=yes -j8
scons platform=windows target=template_release dev_build=no -j8
```

### Runtime soak

- 30 tick smoke: 检查 crash / fallback / NaN。
- 300 tick CSV: 检查地理与时间切片。
- 1000 tick soak: 检查 scheduler p95/max、`largest`、skip reasons、visual lag。

## 文档维护要求

- P0 改 diagnostics 字段：更新 `performance-diagnostics-playbook.md`。
- P1a 改 current solve 数值语义：更新 `computation-pipelines.md`。
- P1b 改 ocean job stage / skip reason：更新 `scheduling-and-job-graph.md` 和 `performance-diagnostics-playbook.md`。
- P2 改 TTA 语义：更新 `computation-pipelines.md`。
- P3 改 convergence cadence：更新 `computation-pipelines.md` 和 `performance-diagnostics-playbook.md`。

