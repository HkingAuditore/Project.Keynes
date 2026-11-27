# weather_system.gd
# Milestone 3：天气子系统主类（按 day_changed 推进）。
# Weather subsystem facade and configuration owner.
#
# ─── 模块结构（dots-monolith-split / Phase E.3 真实状态，2026-06-20 校正）──
# WeatherSystem owns public lifecycle/query entry points, front state, climate
# profile knobs, and the visible publish boundary. Weather field slice state and
# its fallback solver live in field_solver.gd; front spawning, feedback, summary,
# and native bridge helpers remain in their existing collaborators.
#
class_name WeatherSystem
extends RefCounted

const WeatherDailyCycle = preload("res://scripts/weather/weather_daily_cycle.gd")
const WeatherNativeConfiguration = preload("res://scripts/weather/weather_native_configuration.gd")
const WeatherFrontProjection = preload("res://scripts/weather/weather_front_projection.gd")
const WeatherFieldSettings = preload("res://scripts/weather/weather_field_settings.gd")

const WeatherDiagnostics = preload("res://scripts/weather/weather_diagnostics.gd")

const MAX_FRONTS := 16
# 每天 spawn 检查次数（每次都按概率 spawn 一个；MAX_FRONTS 已满则跳过）
const SPAWN_TRIES_PER_DAY := 2
# 不同季节的 spawn 概率（让冬天天气更频繁）
# Phase E（方案 A）：寿命整体翻倍后，相同 spawn 频率会让池子常态打满，
# 新生 front 在边界排队 → 还是看起来像"忽闪"。这里把 spawn 概率统一 ×0.7，
# 与寿命延长相抵后，池子里的 front 数量大致与改动前持平，但每个个体都
# 待得更久、走得更远。
# Phase E（方案 A）：寿命整体翻倍后，相同 spawn 频率会让池子常态打满，
# 新生 front 在边界排队 → 还是看起来

var _rng: RandomNumberGenerator
var _active_fronts: Array[WeatherFront] = []
var _world_bounds: Rect2 = Rect2()
var _hex_size: float = 22.0
var _day_counter: int = 0
# 当前年内轨道相位（连续浮点 [0, 4)）。
# 只用于向 field solver 传递太阳几何/日照链条的年内位置；
# 风向变化来自 SLP、压力梯度和 terrain-aware wind，不再由天气层叠加独立季节风向偏置。
var _season_phase: float = 1.0
# Milestone 3：上次 tick 是否改写过任何 cell.cover（给 baker 决定要不要 rebake cover_tex）
var _cover_dirty: bool = false

# Systemic Ocean Currents：台风尾迹扰动（可选，由 MapConfig.enable_cyclone_wake 开关控制）。
# 结构：{ cell_id (int "q*10000+r"): { "vec": Vector2, "days_left": int, "init_days": int } }。
# 每天 _tick_cyclone_wake 对 days_left 递减，days_left<=0 时移除；vec 幅度按比例衰减。
# 消费方：未来可由 HexRenderer 上传为 RG8 overlay uniform 供 shader 与主流场相加；
# 目前仅暴露只读 API cell_perturbation(cell) 供逻辑层直读（例如航运 AI）。
var ocean_current_perturbation: Dictionary = {}
# 下列两个字段由外部（MapGenerator/main）在 init 时写入一次，tick 时读。
# 为避免循环依赖，这里只保存基本数值。
var _cyclone_wake_enabled: bool = false
var _cyclone_wake_days: int = 3

# Emergent Climate Coupling：开关 + 子参数。
# 由外部 MapGenerator 在 init/refresh_daily 前写入，tick_one_day 内消费。
# 关闭时所有耦合行为退回到旧的均匀/季节硬切路径（兼容回退）。
var _emergent_coupling: bool = false
var _emergent_rain_shadow_threshold: float = 0.13
var _emergent_rain_shadow_factor: float = 0.50
var _emergent_orographic_boost: float = 1.2

# v11 地形—水汽耦合：开启后，weather 锁面 advection / spawn 优先采样
# HexCell.wind_vector（地形扰动后的六边形尺度实际风），而不是纣红度基线
# wind_field_buffer，让恶天镹面能被山脈裁引、微原。由 MapGenerator 在初始化时
# 通过 configure_terrain_wind() 推送。关闭后完全走旧路径（便于回滚验证）。
var _use_wind_vector_for_advect: bool = true

# Ocean current → weather event spawn bias：寒流/暖流海岸对降水类天气的
# spawn 概率偏置。bias > 0 时 spawn 评分中读取候选 cell 邻水 anomaly：
#   - 显著负 anomaly（寒流） → RAIN/STORM/MONSOON 权重乘 max(0.1, 1+bias×anomaly)
#   - 显著正 anomaly（暖流） → 同类型权重乘 (1+bias×anomaly) 提升
# BLIZZARD/FOG 不受影响。bias = 0 时退回 legacy 行为。
# 由 MapGenerator 在 init/configure 时通过 configure_ocean_spawn_bias 写入。
var _ocean_spawn_bias: float = 0.0

# Grid weather field solver. This is the primary weather logic when enabled:
# each hex owns vapor/cloud/precip/instability/type/intensity, and legacy fronts
# are rebuilt as a compact visual summary after the field solve.
var _weather_field_enabled: bool = true
var _field_advect_steps: int = 6  # 方案③ 默认 4→6(atmospheric river)
var _field_diffusion: float = 0.04
var _field_condensation_gain: float = 0.42
# ⚠ DEPRECATED 僵尸 knob（2026-06-20 根因重构）：precip 已改 EMA 惯性，C++ 与 GDScript
# hot-loop 均不再读取 precip_decay / carryover_max（world_ext.cpp 仅剩注释、field_solver.gd
# 无引用）。仍保留成员/configure/knobs 传递仅为存档 + resident 链路兼容，待后续连同
# NativeKnobs 字段与 positional 签名一并删除（见 docs/architecture/current-state.md 根因重构节）。
var _field_precip_decay: float = 0.85
var _field_precip_carryover_max: float = 0.08
var _field_vapor_precip_sink: float = 0.85
var _field_vapor_relax_rate: float = 0.08
var _weather_temp_anomaly_cap: float = 0.025
var _weather_direct_moisture_enabled: bool = false
var _field_orographic_lift_gain: float = 0.22
var _field_orographic_lift_cap: float = 0.35
var _field_wet_terrain_precip_damping: float = 0.60
var _field_lake_precip_damping: float = 0.65
var _field_lake_evap_scale: float = 0.85  # Stage14d 0.35→0.85 湖面蒸发接近海面(与 ClimateProfile.weather_lake_evap_scale 一致)
var _field_extreme_precip_soft_cap: float = 0.16
var _field_extreme_precip_softness: float = 0.20
var _field_convergence_gain: float = 0.18
var _field_convergence_refresh_stride: int = 2
var _field_solve_tick: int = 0
var _last_weather_commit_tick: int = -1
# [dt-aware transition 2026-06-28] 由 orchestrator（map_generator）每次天气求解前用
# _consume_weather_dt_days() 注入"上次到本次天气求解的真实游戏天数差"。喂给 weather_transition_dt_days
# knob，让过渡 alpha 按游戏天数推进而非求解次数（加速档下避免吞掉短暂天气）。缺省 1.0=与历史 1:1。
var _weather_transition_dt_days: float = 1.0
var _cold_precip_as_blizzard: bool = true
var _snow_classification_margin: float = 0.03
var _field_ocean_evap_gain: float = 0.55
var _field_land_evapotranspiration_gain: float = 0.85
var _field_precip_rh_threshold: float = 0.70 # 0.60→0.70：见 climate_profile.weather_precip_rh_threshold（物理层根治：提阈让中湿区转晴）
var _field_ocean_precip_suppression: float = 0.95
# 降水惯性 EMA 系数 α(2026-06-20 根因重构)：precip = lerp(prev_precip, target, α)。越小越平滑(惯性强)、
# 越大越跟手(接近瞬时投影)。2026-06-22 标定为 0.40，减少降水拖尾。
# 统一替代旧 carryover/拖尾/滞回三件套的时间平滑机制。
var _field_precip_inertia: float = 0.58
var _field_classify_gate_land: float = 0.040   # W4
var _field_classify_gate_water: float = 0.032  # W4
var _field_precip_spatial_smooth: float = 0.30  # W5
var _weather_classify_anomaly_cap: float = 0.12  # W6（分类器距平钳制，≠ _weather_temp_anomaly_cap）
# 雨云化(2026-06-22):降水动力化的两个旋钮镜像(默认与 field_solver const 一致;C++ 经 knobs 接收,不重编)。
var _field_precip_base_frac: float = 0.08  # 背景成雨比例；降低固定弱雨，让降水更依赖移动动力触发
var _field_cloud_reevap: float = 0.28      # 干空气云水再蒸发；保留非降水薄云，避免清云过强
var _field_cloud_inertia: float = 0.74     # cloud EMA 跟手系数；让云层随云水和平流更快移动/消退
var _field_frontogenesis_gain: float = 0.42
# [climate-zone-fix P3] 降水季节性旋钮镜像（默认与 C++ knob 默认 / field_solver const 一致；
# 经 knobs 同时喂 C++ 主路径与 field_solver fallback，保 SAME_SOURCE）。
var _field_thermal_conv_precip: float = 0.30   # 陆地热力对流成雨权重（暖季对流，下调减夏雨主导）
var _field_stratiform_gain: float = 1.0        # 层状降水增益（冷/高/水区，上调补冷季降水）
var _field_omega_ascent_gain: float = 0.40     # ITCZ/风暴轴上升带成雨增益（下调弱化静止 ITCZ 锚定）
var _field_cool_season_vapor_floor: float = 0.0 # 冷季蒸发地板（0=关闭=原行为；>0 给冷季基础水汽）
var _field_rain_shadow_drying: float = 0.35
var _field_vapor_transport_gain: float = 0.75
var _snowpack_accum_gain: float = 0.08
var _snowpack_melt_temp_gain: float = 0.22
var _snowpack_melt_sun_gain: float = 0.12
var _snowpack_cover_low: float = 0.05
var _snowpack_cover_full: float = 0.32
var _snow_accum_days_req: int = 2
# climate-loop-closure Phase 2.1：物理雪线参数（由 ClimateProfile 配置）。
var _snowline_temp_threshold: float = 0.24
var _snowline_band: float = 0.22
var _field_summary_limit: int = 12
var _summary_q_cache: PackedInt32Array = PackedInt32Array()
var _summary_r_cache: PackedInt32Array = PackedInt32Array()
var _summary_cache_map_id: int = 0
var _summary_cache_n: int = 0
var _weather_field: Dictionary = {}
var _last_map_for_query: MapData = null

# dots-monolith-split §1.2 / PR-4：22 个切片状态字段已搬迁到
# scripts/weather/field_solver.gd 的 region PR-4。weather_system 内残留的
# begin / commit / solve 主体读写通过 _field_solver 间接访问；
# PR-5 / PR-6 把 commit / solve 主体也搬过去后，访问会自然变成 self.* 内部字段。

# ─── Phase F.1：DCWorldExt C++ 加速钩子（charter §7 第一优先级）───────
# 通过 configure_gdext_acceleration() 注入；map_generator 在 _data_core_world_ext
# bind 完成后调一次。flag 关 / ext null 时所有 hot path 走 GDScript legacy。
var _data_core_world_ext: RefCounted = null

# PR-2.1.6（weather field 写路径下移）：weather field commit / spawn 反馈写位
# 全部下移到 _data_core_world.write_f32_indexed。configure_gdext_acceleration()
# 第 4 个可选参数注入 GDScript DCWorld。null 时 fallback 到旧的 cell.* 直写
# （保留双写是 PR-2.3 facade 化前的兼容路径）。详见 master 手册 §3.9。
var _data_core_world = null  # DCWorld（GDScript）

# ─── Phase A.3（dots-total-cpp roadmap）：常驻 KnobsHandle ──────────────
# 启用 use_gdext_resident_knobs 时由 configure_gdext_acceleration 装配；
# ClimateProfile.changed 触发段级 invalidate；hot-path 3 个 _build_*_knobs
# 走 to_*_knobs_dict() 缓存输出（map_generator 端持有自己的 _knobs_handle
# 用于 stage_b，两侧共享同一份 cp 但各自走自己的 dirty-write，避免跨节点
# 信号 fan-out）。
# 默认 null：未启用 / stale .dll / ClassDB 无该类时所有 hot-path 走原 builder。
var _knobs_handle: RefCounted = null
var _knobs_handle_first_use_logged: bool = false

# 任务 2（dots-completion）：HexCell facade 启用时跳过 AoS 直写。
# - false（default）：兼容路径，hot loop 仍写 out_cell.weather_*（setter 落到
#   _backing；legacy reader 如 map_baker.gd 走 cell.weather_xxx 仍能取到值）。
# - true（任务 4 启用）：所有 hot loop 跳过 16 行 AoS 写，cell 字段读全部走
#   SoA（已由本函数末尾 write_f32_indexed/write_u8_indexed 批量写入）。
# 由 map_generator / main 在 facade 切换时调 set_hexcell_facade_on(b)。
var _hexcell_facade_on: bool = false

# [DIAG mask_dirty=2400 排查 · 2026-05-20] commit 路径调用计数（节流日志）
var _diag_wd_commit_count: int = 0
var _diag_fb_commit_count: int = 0

var _use_gdext_weather_field: bool = false
var _use_gdext_weather_field_commit: bool = false
# F.1 运行时统计：cpp_runs / cpp_fallbacks / cpp_total_ms（_last_breakdown 暴露给上层 HUD）
var _gdext_field_runs: int = 0
var _gdext_field_fallbacks: int = 0
var _gdext_field_total_ms: float = 0.0
# F.1 fallback 节流：避免 cells size mismatch 时每 tick 都 push_warning。
var _gdext_field_warned_fallback: bool = false
var _gdext_field_commit_warned_fallback: bool = false
# F.1 一次性诊断：第一次 fast-path attempt 时打一条 precondition 状态日志。
var _gdext_field_first_attempt_logged: bool = false
# F.1 运行时 A/B 验证：开关后每 tick 同时跑 C++ + GDScript，逐 cell 比较结果。
# 仅用于离线诊断；开启后整个 pass 时间 ≈ 旧 pass × 2。详见 set_field_verify_mode。
var _field_verify_enabled: bool = false
var _field_verify_tol_f32: float = 1.0e-4
var _field_verify_first_divergence_logged: bool = false

# ─── Weather Hot-Path C++ 化（dist + summary）：plan/weather-hotpath-cpp ───
# 与 F.1 同款套路：configure_gdext_acceleration 时按 ext.has_method + 签名 arg
# 数检测能力，能力达成且 climate_profile 开关 true 时镜像置 true；STALE 时强降级。
# 持久化 C++ 状态在 set_*_verify_mode / flag 切换时由 GDScript 调 ext.reset_*_state() 清空。
var _use_gdext_weather_distribute: bool = false
var _use_gdext_weather_summary: bool = false
# dist 运行时统计与节流告警
var _gdext_dist_runs: int = 0
var _gdext_dist_fallbacks: int = 0
var _gdext_dist_total_ms: float = 0.0
var _gdext_dist_warned_fallback: bool = false
var _gdext_dist_first_attempt_logged: bool = false
var _dist_acc_snow_cache: PackedInt32Array = PackedInt32Array()
var _dist_pre_cover_cache: PackedInt32Array = PackedInt32Array()
var _dist_cache_map_id: int = 0
var _dist_cache_n: int = 0
# summary 运行时统计与节流告警
var _gdext_summary_runs: int = 0
var _gdext_summary_fallbacks: int = 0
var _gdext_summary_total_ms: float = 0.0
var _gdext_summary_warned_fallback: bool = false
var _gdext_summary_first_attempt_logged: bool = false
# Phase A.1 fronts_soa zero-copy 路径：once-log + once-warn 标志
var _fronts_soa_path_logged: bool = false
var _fronts_soa_warned_fallback: bool = false
# Phase B "Z 锁死" 实测遥测：包夹 _unpack_summary_soa_to_fronts 的 wall-clock μs。
# 100 样本 ring 满即一次性 print(p50/p95/mean)，然后归零再采下一窗口。
# gate：OS.has_feature("editor") + use_gdext_fronts_soa（caller 已确认）。
# 若 p95 > 100μs/tick → 推翻 Z 回 X1（archetype 化优先级 ↑）；否则 Z 锁死。
const _FRONTS_SOA_TELEMETRY_WINDOW: int = 100
var _fronts_soa_unpack_us_ring: PackedInt32Array = PackedInt32Array()
var _fronts_soa_unpack_window_idx: int = 0
var _fronts_soa_unpack_window_count: int = 0

# plan/weather-refresh-cpp-all PR-2：weather refresh daily 合并 facade 运行时统计。
# 仅在 try_run_refresh_daily_combined_gdext 成功路径累计；rc!=0 路径走 fallback
# 并节流告警（_gdext_combined_warned_fallback 一次性）。HUD 用 runs/total_ms 算
# 平均 ms，与单 pass 各自的 _gdext_field/dist/summary 统计互斥（合并成功一次
# ≈ 4 段 cpp pass 各被替代一次）。
var _gdext_combined_runs: int = 0
var _gdext_combined_total_ms: float = 0.0
var _gdext_combined_warned_fallback: bool = false
# A/B verify：dev 诊断开关 + 容差。开启后 commit 仍走 C++，verify 跑 GDScript shadow 对账。
var _distribute_verify_enabled: bool = false
var _distribute_verify_tol_f32: float = 1.0e-4
var _distribute_verify_first_divergence_logged: bool = false
var _summary_verify_enabled: bool = false
var _summary_verify_tol_pos: float = 0.5      # px
var _summary_verify_tol_intensity: float = 1.0e-3
var _summary_verify_tol_velocity: float = 0.5  # px / snapshot
var _summary_verify_first_divergence_logged: bool = false

# ─── 任务 9：节流式回归告警 ───────────────────────────────────────────────
# 各保留最近 5 个 elapsed_ms 样本；任一 pass 连续 5 tick 都超过门槛 2× 时
# push_warning 一次（_*_regression_warned 节流，确保 60 tick 内最多 1 条）。
# 阈值与 plan/weather-hotpath-cpp/requirements.md §4.6 同源：
#   dist 门槛 1.5ms、summary 门槛 3.0ms。
const _PERF_RING_SIZE: int = 5
const _DIST_PERF_BUDGET_MS: float = 1.5
const _SUMMARY_PERF_BUDGET_MS: float = 3.0
const _PERF_BUDGET_MULTIPLIER: float = 2.0
var _dist_recent_ms: PackedFloat32Array = PackedFloat32Array()
var _summary_recent_ms: PackedFloat32Array = PackedFloat32Array()
var _dist_regression_warned: bool = false
var _summary_regression_warned: bool = false

# ─── Phase F.6：DCWorldExt fronts advect C++ 加速钩子（charter §7 P3）───
# 通过 configure_gdext_acceleration() 同时注入（同一 ext 实例 + ClimateProfile 引用）。
# F.6 fast-path 在 tick_one_day fronts 推进段（line ~282）触发，详见
# scripts/weather/weather_system.gd::tick_one_day "1) 推进所有 front" 注释。
#
# dots-flag-prune-pr1 (2026-05-22)：_use_gdext_weather_front 死字段已删除
# （front_advect.gd 端现恒走 ext+has_method 探测单边分支）。其余 _gdext_front_*
# 运行时统计字段保留。
var _gdext_front_runs: int = 0
var _gdext_front_fallbacks: int = 0
var _gdext_front_total_ms: float = 0.0
var _gdext_front_first_attempt_logged: bool = false
var _gdext_front_signature_checked: bool = false
var _gdext_front_signature_ok: bool = false
# F.6 ClimateProfile 引用（仍用于 fronts_soa / resident_knobs 等保留 flag）。
var _cp_for_front_flag: Resource = null

# v11 在 tick_one_day 期间缓存当前 MapData 引用，供同一 tick 内部的 spawn
# 分支（_spawn_random_front / _build_front_at）复用，避免从调用链中到处透传。
# tick 结束后置 null，不跨帧持有弱引用 → 与旧生命周期一致。
var _current_map_for_tick: MapData = null

# Daily-sim perf instrumentation：tick_one_day 内部分段耗时快照。
# main.gd / map_generator.refresh_daily 可调 last_breakdown() 读取。
# 字段：advance_ms / spawn_ms / distribute_ms / cyclone_ms
var _last_breakdown: Dictionary = {}

# dots-monolith-split §1.1：weather sub-module 实例。
# 由 init() 创建，tick_one_day 在对应阶段委派 hot pass 给 sub-module。
# 当前已接入：_advect.tick_cyclone_wake() 替代原 _tick_cyclone_wake() 内联实现。
var _advect: DCWeatherFrontAdvect = null
# dots-monolith-split §1.2：field_solver 占位实例。
# 当前 _solve_weather_field 主体仍在本文件，sub-module 提供稳定 facade 入口
# 让后续逐函数搬迁可零摩擦切换调用点。
var _field_solver: DCWeatherFieldSolver = null
# dots-monolith-split §E.2：feedback / summary facade 实例。
var _feedback: DCWeatherFeedback = null
var _summary_builder: DCWeatherSummaryBuilder = null

# Tick-scoped 预计算缓存：每次 _solve_weather_field 进入时一次性把全图 cell

# 的世界坐标和 1 环邻居数组算好；helper 函数（_neighbor_aligned / _upstream_vapor /
# _wind_convergence_for_cell / _orographic_lift_for_cell / _neighbor_average_vapor /
# _avg_ocean_anomaly_at）通过下面两个 accessor 读取，避免在 ~2400 cell × 多次内层
# 循环里反复调用 HexUtils.cube_to_world() 与 map.get_neighbors()。
# tick 结束时清空，避免跨帧弱引用残留。
var _tick_cell_pos: Dictionary = {}
var _tick_cell_neighbors: Dictionary = {}

# Continuity-fix（2026-05-10）：summary front 的跨 tick 身份继承状态。
# 解决"前沿每 tick 重新出生 + 边界 cell 抖动 → 视觉跳变"的根因。
#   _prev_summary_membership: HexCell → cluster_idx，记录上 tick flood-fill 时
#                              每个 cell 的归属，给本 tick 的阈值滞回（hysteresis）
#                              判定使用——上 tick 在某簇内的 cell 用 0.06 阈值
#                              留在簇里，新加入的需要 ≥ 0.10 才能进簇。
#   _prev_summary_seeds:       Array of {type, center, age, area}，记录上 tick 的
#                              聚合中心，本 tick BFS 时优先以这些点为种子，让
#                              cluster 在 split / merge / 边界漂移下仍保持身份。
# 在 init() 与 setup 路径中清零；每次 _build_field_summary_fronts 末尾刷新。
var _prev_summary_membership: Dictionary = {}
var _prev_summary_seeds: Array = []

# Drift-debug（2026-05-10）：set true 后每次 _build_field_summary_fronts 调用都打印
# 顶 3 个 cluster 的 (type, prev_center → new_center, observed_drift, EMA velocity)。
# 用于诊断"云不会动"——可以直观看到 sim 端是否真的产出了非零 velocity。
# 验证完成后改回 false 关日志。
const DRIFT_DEBUG_LOG: bool = false

func _cell_world_pos(cell: HexCell) -> Vector2:
	return WeatherDiagnostics.cell_world_pos(self, cell)

func _cell_neighbors(cell: HexCell, map: MapData) -> Array:
	if _tick_cell_neighbors.has(cell):
		return _tick_cell_neighbors[cell]
	if map == null:
		return []
	return map.get_neighbors(cell)

func last_breakdown() -> Dictionary:
	return _last_breakdown


func set_weather_transition_dt_days(d: float) -> void:
	_weather_transition_dt_days = clampf(d, 0.0, 30.0)


func _mark_weather_commit_tick() -> Dictionary:
	var prev: int = _last_weather_commit_tick
	var delta: int = (_field_solve_tick - prev) if prev >= 0 else 0
	_last_weather_commit_tick = _field_solve_tick
	return {
		"weather_commit_tick_delta": delta,
		"weather_last_commit_tick": _last_weather_commit_tick,
	}

func _percentile_abs_from_array(values: PackedFloat32Array, q: float) -> float:
	return WeatherFieldSettings._percentile_abs_from_array(self, values, q)


func init(seed_val: int, world_bounds: Rect2, hex_size: float) -> void:
	WeatherDailyCycle.init(self, seed_val, world_bounds, hex_size)

func tick_one_day(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	return WeatherDailyCycle.tick_one_day(self, map, world, season_idx, climate_anomaly, season_phase)

const DCWeatherNativeBridge = preload("res://scripts/weather/native_bridge.gd")
var _front_spawn: DCWeatherFrontSpawn = null
var _native_bridge: RefCounted = null


func _spawn_random_front(world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	return _front_spawn._spawn_random_front(self, world, season_idx, climate_anomaly)

func _apply_front_shape_by_type(front: WeatherFront) -> void:
	return _front_spawn._apply_front_shape_by_type(self, front)

func _pick_weather_type(season_idx: int, abs_lat: float, on_water: bool, climate_anomaly: float) -> int:
	return _front_spawn._pick_weather_type(self, season_idx, abs_lat, on_water, climate_anomaly)

func _front_decay_modifier(front: WeatherFront, cell: HexCell) -> float:
	return _front_spawn._front_decay_modifier(self, front, cell)

func _cold_precip_should_snow(temp: float, vapor: float, cloud: float, precip: float, meaningful_precip: bool) -> bool:
	return _front_spawn._cold_precip_should_snow(self, temp, vapor, cloud, precip, meaningful_precip)

func _front_orographic_precip_bonus(front: WeatherFront, cell: HexCell, map: MapData) -> float:
	return _front_spawn._front_orographic_precip_bonus(self, front, cell, map)

func _spawn_emergent_front(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	return _front_spawn._spawn_emergent_front(self, map, world, season_idx, climate_anomaly)

func _local_temp_moist_gradient(cell: HexCell, map: MapData) -> float:
	return _front_spawn._local_temp_moist_gradient(self, cell, map)

func _pick_weather_type_emergent(cell: HexCell, season_idx: int, climate_anomaly: float, map: MapData = null) -> int:
	return _front_spawn._pick_weather_type_emergent(self, cell, season_idx, climate_anomaly, map)

func _ocean_weight_multiplier(cell: HexCell, map: MapData) -> float:
	return _front_spawn._ocean_weight_multiplier(self, cell, map)

func _ocean_filter_precip(cell: HexCell, map: MapData, wt: int) -> int:
	return _front_spawn._ocean_filter_precip(self, cell, map, wt)

func _avg_ocean_anomaly_at(cell: HexCell, map: MapData) -> float:
	return _front_spawn._avg_ocean_anomaly_at(self, cell, map)

func _build_front_at(spawn_pos: Vector2, wt: int, world: WorldData) -> WeatherFront:
	return _front_spawn._build_front_at(self, spawn_pos, wt, world)

func _distribute_to_cells(map: MapData) -> void:
	return _feedback._distribute_to_cells(self, map)

func _summer_snow_melt_bonus(heat_input: float, elevation: float) -> float:
	return _feedback._summer_snow_melt_bonus(self, heat_input, elevation)

func _snowline_floor_for_cell(temp_now: float, heat_input: float, elevation: float) -> float:
	return _feedback._snowline_floor_for_cell(self, temp_now, heat_input, elevation)

func _apply_snow_accumulation(cell: HexCell, wt: int, temp_now: float, intensity: float) -> bool:
	return _feedback._apply_snow_accumulation(self, cell, wt, temp_now, intensity)

func _classify_field_weather_at(temp: float, vapor: float, cloud: float, cloud_water: float, precip: float, instability: float, ocean_an: float, wind_speed: float, temp_anom: float, monsoon_flux: float = 0.0, is_water: bool = false, snow_cover: float = 0.0) -> int:
	return _feedback._classify_field_weather_at(self, temp, vapor, cloud, cloud_water, precip, instability, ocean_an, wind_speed, temp_anom, monsoon_flux, is_water, snow_cover)

func _classify_field_weather_core(temp: float, vapor: float, cloud: float, cloud_water: float, precip: float, instability: float, ocean_an: float, wind_speed: float, temp_anom: float, monsoon_flux: float = 0.0, is_water: bool = false, snow_cover: float = 0.0) -> int:
	return _feedback._classify_field_weather_core(self, temp, vapor, cloud, cloud_water, precip, instability, ocean_an, wind_speed, temp_anom, monsoon_flux, is_water, snow_cover)

func _is_precip_weather_type(wt: int) -> bool:
	return _feedback._is_precip_weather_type(self, wt)

func _weather_precip_terrain_damping_factor(terrain: int) -> float:
	return _feedback._weather_precip_terrain_damping_factor(self, terrain)

func _moderate_field_precip_for_terrain(terrain: int, precip: float) -> float:
	return _feedback._moderate_field_precip_for_terrain(self, terrain, precip)

func _field_intensity_for_type(wt: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> float:
	return _feedback._field_intensity_for_type(self, wt, temp, vapor, cloud, precip, instability, ocean_an)

func _distribute_weather_field_to_cells_legacy(map: MapData) -> void:
	return _feedback._distribute_weather_field_to_cells_legacy(self, map)

func _build_field_summary_fronts_legacy(map: MapData, world: WorldData) -> Array[WeatherFront]:
	return _summary_builder._build_field_summary_fronts_legacy(self, map, world)

func _pick_inheritance_seed(
		seed_cell: HexCell, prev_type: int, map: MapData,
		visited: Dictionary, enter_thresh: float, hold_thresh: float) -> HexCell:
	return _summary_builder._pick_inheritance_seed(self, seed_cell, prev_type, map, visited, enter_thresh, hold_thresh)

func _flood_fill_field_component(
		seed: HexCell, wt: int, map: MapData,
		visited: Dictionary, new_membership: Dictionary, cluster_idx: int,
		enter_thresh: float, hold_thresh: float) -> Dictionary:
	return _summary_builder._flood_fill_field_component(self, seed, wt, map, visited, new_membership, cluster_idx, enter_thresh, hold_thresh)

func _merge_nearby_components(components: Array) -> Array:
	return _summary_builder._merge_nearby_components(self, components)

func _build_weather_field_knobs(map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> Dictionary:
	return _native_bridge._build_weather_field_knobs(self, map, world, n_cells, start_idx, end_idx)

func _try_run_weather_field_solve_gdext(map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> float:
	return _native_bridge._try_run_weather_field_solve_gdext(self, map, world, n_cells, start_idx, end_idx)

func _try_run_weather_field_commit_gdext(map: MapData, n_cells: int) -> Dictionary:
	return _native_bridge._try_run_weather_field_commit_gdext(self, map, n_cells)

func _validate_weather_distribute_signature(ext: RefCounted) -> bool:
	return _native_bridge._validate_weather_distribute_signature(self, ext)

func _validate_weather_summary_signature(ext: RefCounted) -> bool:
	return _native_bridge._validate_weather_summary_signature(self, ext)

func _build_weather_distribute_knobs(map: MapData, n_cells: int) -> Dictionary:
	return _native_bridge._build_weather_distribute_knobs(self, map, n_cells)

func _try_run_weather_distribute_gdext(map: MapData, n_cells: int) -> Dictionary:
	return _native_bridge._try_run_weather_distribute_gdext(self, map, n_cells)

func _build_weather_summary_knobs(map: MapData, world: WorldData) -> Dictionary:
	return _native_bridge._build_weather_summary_knobs(self, map, world)

func _unpack_summary_dict_to_front(d: Dictionary) -> WeatherFront:
	return _native_bridge._unpack_summary_dict_to_front(self, d)

func _unpack_summary_soa_to_fronts(soa: Dictionary) -> Variant:
	return _native_bridge._unpack_summary_soa_to_fronts(self, soa)

func _build_fronts_from_rc(rc_dict: Dictionary) -> Array[WeatherFront]:
	return _native_bridge._build_fronts_from_rc(self, rc_dict)

func _try_run_weather_summary_fronts_gdext(map: MapData, world: WorldData) -> Variant:
	return _native_bridge._try_run_weather_summary_fronts_gdext(self, map, world)

func try_run_refresh_daily_combined_gdext(map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float = -1.0,
		stage_b_knobs: Dictionary = {}) -> Dictionary:
	return _native_bridge.try_run_refresh_daily_combined_gdext(self, map, world, season_idx, climate_anomaly, season_phase, stage_b_knobs)

func build_unified_fast_tick_weather_knobs(map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float,
		stage_b_knobs: Dictionary) -> Dictionary:
	return _native_bridge.build_unified_fast_tick_weather_knobs(self, map, world, season_idx, climate_anomaly, season_phase, stage_b_knobs)

func apply_unified_fast_tick_result(weather_rc: Dictionary) -> Array[WeatherFront]:
	return _native_bridge.apply_unified_fast_tick_result(self, weather_rc)

func _pull_gdext_field_results_to_next(map: MapData, n_cells: int) -> void:
	return _native_bridge._pull_gdext_field_results_to_next(self, map, n_cells)

func _verify_gdext_field_against_gdscript(map: MapData, world: WorldData, n_cells: int) -> void:
	return _native_bridge._verify_gdext_field_against_gdscript(self, map, world, n_cells)

func _verify_gdext_distribute_against_gdscript(map: MapData, n_cells: int, cpp_rc: Dictionary) -> void:
	return _native_bridge._verify_gdext_distribute_against_gdscript(self, map, n_cells, cpp_rc)

func _verify_gdext_summary_against_gdscript(map: MapData, world: WorldData,
		fronts_cpp: Array[WeatherFront]) -> void:
	return _native_bridge._verify_gdext_summary_against_gdscript(self, map, world, fronts_cpp)

func uses_weather_field() -> bool:
	return WeatherDailyCycle.uses_weather_field(self)

func is_weather_field_solve_active() -> bool:
	return WeatherDailyCycle.is_weather_field_solve_active(self)

func begin_weather_field_solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true, for_worker_knobs_only: bool = false) -> void:
	WeatherDailyCycle.begin_weather_field_solve(self, map, world, season_idx, climate_anomaly, season_phase, count_day, for_worker_knobs_only)

func run_weather_field_solve_slice(cell_budget: int) -> Dictionary:
	return WeatherDailyCycle.run_weather_field_solve_slice(self, cell_budget)

func commit_weather_field_solve() -> Array[WeatherFront]:
	return WeatherDailyCycle.commit_weather_field_solve(self)

func run_synoptic_advance_pass(map: MapData, world: WorldData) -> float:
	return WeatherDailyCycle.run_synoptic_advance_pass(self, map, world)

func build_field_knobs_for_worker(map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float,
		season_phase: float, defer_thermal_equator: bool = false) -> Dictionary:
	return WeatherDailyCycle.build_field_knobs_for_worker(self, map, world, season_idx, climate_anomaly, season_phase, defer_thermal_equator)

func convergence_refresh_due_on_day(day: int) -> bool:
	return WeatherDailyCycle.convergence_refresh_due_on_day(self, day)

func build_distribute_knobs_for_worker(map: MapData, n_cells: int) -> Dictionary:
	return WeatherDailyCycle.build_distribute_knobs_for_worker(self, map, n_cells)

func _sync_weather_distribute_cache_to_cells(map: MapData, n_cells: int) -> void:
	WeatherDailyCycle._sync_weather_distribute_cache_to_cells(self, map, n_cells)


func _front_diagnostic_kind(temp_advection: float) -> int:
	return WeatherDiagnostics.front_diagnostic_kind(self, temp_advection)

func _front_diagnostic_counts(fronts: Array) -> Dictionary:
	return WeatherDiagnostics.front_diagnostic_counts(self, fronts)

# ─── Phase A.1 helper：把 C++ 返回值优先走 SoA 路径，缺失 / flag off 时
# fallback 到 Array[Dict] 路径。集中在一个 helper 里供 summary 与 combined
# 两处复用，避免重复 dispatch 逻辑分叉。
func _sync_profile_weather_knobs(cp: Resource) -> void:
	WeatherNativeConfiguration._sync_profile_weather_knobs(self, cp)

func _push_resident_knobs_from_cp(cp: Resource) -> void:
	WeatherNativeConfiguration._push_resident_knobs_from_cp(self, cp)

func _on_climate_profile_changed_for_knobs(cp: Resource) -> void:
	WeatherNativeConfiguration._on_climate_profile_changed_for_knobs(self, cp)

func _merge_resident_knobs_with_dynamic(base_dict: Dictionary, dynamic_fields: Dictionary) -> Dictionary:
	return WeatherNativeConfiguration._merge_resident_knobs_with_dynamic(self, base_dict, dynamic_fields)


func _clear_weather_field_slice_state() -> void:
	WeatherDailyCycle._clear_weather_field_slice_state(self)


func _apply_frontal_convergence_boost(map: MapData, cells: Array, climate_anomaly: float, neighbor_indices: PackedInt32Array, fast_indexed: bool) -> void:
	WeatherFrontProjection._apply_frontal_convergence_boost(self, map, cells, climate_anomaly, neighbor_indices, fast_indexed)

const SNOW_FREEZE_T: float = 0.24       # 低于此温度才算"可降雪冷度"
const SNOW_MELT_T: float = 0.31         # 高于此温度开始消融，保持滞回防抖
# 涌现式分类门（2026-06-20 去季节化重写）：阈值由 tile_data_record_20260620_004323 实测标定。
# 不再有任何 season_idx 派生的开关——天气类型完全由瞬时物理场涌现。
const BLIZZARD_WIND_GATE: float = 1.0  # Stage2: 1.15→1.0(过渡带冷降水阈降，原 1.15>典型风速 1.04 把冷降水误判冷雨)。过渡带(FREEZE~MELT)冷降水仅当风速>此值才算"暴风雪"

# 2026-05-18 雪线修正：海拔放宽 → 高山易积雪、平原难积雪。
# 以 elev=0.30 为中性（freeze_t = 0.30、melt_t = 0.34），
# 高于此值时 freeze 阈值随 elev 抬高（更容易冷到冻结），低于此值时 freeze 阈值压低；
# melt 阈值同方向偏移（高山更难融、平原更易融）。
# 偏移上限 ±0.06，避免极端山顶常年降雪而极平原永远不积雪。
# 注：C++ snapshot（_make_weather_decision_snapshot）目前只携带 SNOW_FREEZE_T/SNOW_MELT_T
# 基线常数；C++ 路径的 elev 偏移待任务 4 同步。GDScript 优先实现。
const SNOW_ELEV_NEUTRAL: float = 0.30
const SNOW_ELEV_FREEZE_GAIN: float = 0.20    # elev 每升 1.0 → freeze_t 上抬 0.20（≈+0.14 山顶）
const SNOW_ELEV_FREEZE_MAX_OFF: float = 0.06
const SNOW_ELEV_MELT_GAIN: float = 0.30      # elev 每升 1.0 → melt_t 上抬 0.30（高山难融）
const SNOW_ELEV_MELT_MAX_OFF: float = 0.10

func _prev_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	return WeatherFrontProjection._prev_vapor_cached(self, cell, map, prev_vapor)


func _upstream_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	return _field_solver._upstream_vapor_cached(cell, map, prev_vapor, wind_dir)

func _neighbor_average_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	return _field_solver._neighbor_average_vapor_cached(cell, map, prev_vapor)

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd（薄转发）。
func _neighbor_aligned_idx(idx: int, dir: Vector2, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> int:
	return _field_solver._neighbor_aligned_idx(idx, dir, cell_pos, neighbor_indices)


func _upstream_vapor_idx_from_first(idx: int, first_upstream_idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	return _field_solver._upstream_vapor_idx_from_first(idx, first_upstream_idx, cell_pos, neighbor_indices, prev_vapor, wind_dir)

func _neighbor_average_vapor_idx(idx: int, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array) -> float:
	return _field_solver._neighbor_average_vapor_idx(idx, neighbor_indices, prev_vapor)

# dots-monolith-split §1.2 / PR-3：搬迁到 field_solver.gd（薄转发）。
func _avg_ocean_anomaly_at_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array) -> float:
	return _field_solver._avg_ocean_anomaly_at_idx(idx, cells, neighbor_indices)


		# v9d：自身有河 → 给固定 +0.012（比"邻居有水"的 +0.018 略低，
		# 因为河只占 cell 面积一小部分）。这是叠加在 base 0.006 上，
		# 让河流穿过的陆地实际 evap 接近 0.018，介于陆地与海面之间。

func _vegetation_transpiration_factor(cell: HexCell) -> float:
	return WeatherFrontProjection._vegetation_transpiration_factor(self, cell)


func _orographic_lift_for_cell(cell: HexCell, map: MapData, wind_dir: Vector2) -> float:
	return _field_solver._orographic_lift_for_cell(cell, map, wind_dir)


func _orographic_lift_from_upstream_idx(idx: int, upstream_idx: int, cells: Array) -> float:
	return _field_solver._orographic_lift_from_upstream_idx(idx, upstream_idx, cells)

func _wind_convergence_for_cell(cell: HexCell, map: MapData) -> float:
	return _field_solver._wind_convergence_for_cell(cell, map)

func _wind_convergence_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> float:
	return _field_solver._wind_convergence_idx(idx, cells, cell_pos, neighbor_indices)

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd（薄转发）。
func _neighbor_aligned(cell: HexCell, map: MapData, dir: Vector2) -> HexCell:
	return _field_solver._neighbor_aligned(cell, map, dir)

# 涌现式半真实大气分类（2026-06-20 去季节化重写）。天气类型完全由瞬时物理场（温度/湿度/云/
# 降水/不稳定度/风/洋流异常）涌现，不再读 season_idx 或纬度——"季节"作为温度场随轴倾/公转的
# 结果自然进入。与 C++ wf_classify_field_weather_at 严格镜像。
func _distribute_weather_field_to_cells(map: MapData) -> void:
	if _feedback == null:
		_feedback = DCWeatherFeedback.new(self)
	_feedback.distribute(map)


func _build_field_summary_fronts(map: MapData, world: WorldData) -> Array[WeatherFront]:
	if _summary_builder == null:
		_summary_builder = DCWeatherSummaryBuilder.new(self)
	return _summary_builder.build(map, world)


func has_cover_dirty() -> bool:
	return WeatherFrontProjection.has_cover_dirty(self)

func query_at(world_pos: Vector2) -> Dictionary:
	return WeatherFrontProjection.query_at(self, world_pos)

func pack_to_uniforms() -> Dictionary:
	return WeatherFrontProjection.pack_to_uniforms(self)

func active_fronts() -> Array[WeatherFront]:
	return WeatherFrontProjection.active_fronts(self)

func configure_cyclone_wake(enabled: bool, wake_days: int) -> void:
	WeatherFrontProjection.configure_cyclone_wake(self, enabled, wake_days)


func set_hexcell_facade_on(b: bool) -> void:
	_hexcell_facade_on = b


func configure_gdext_acceleration(ext: RefCounted, enabled: bool, cp: Resource = null, dc_world = null) -> void:
	WeatherNativeConfiguration.configure_gdext_acceleration(self, ext, enabled, cp, dc_world)

func _validate_weather_field_signature(ext: RefCounted) -> bool:
	return WeatherNativeConfiguration._validate_weather_field_signature(self, ext)

func _validate_weather_field_commit_signature(ext: RefCounted) -> bool:
	return WeatherNativeConfiguration._validate_weather_field_commit_signature(self, ext)

func set_field_verify_mode(enabled: bool, tol_f32: float = 1.0e-4) -> void:
	WeatherNativeConfiguration.set_field_verify_mode(self, enabled, tol_f32)

func set_distribute_verify_mode(enabled: bool, tol_f32: float = 1.0e-4) -> void:
	WeatherNativeConfiguration.set_distribute_verify_mode(self, enabled, tol_f32)

func set_summary_verify_mode(enabled: bool,
		tol_pos: float = 0.5, tol_intensity: float = 1.0e-3,
		tol_velocity: float = 0.5) -> void:
	WeatherNativeConfiguration.set_summary_verify_mode(self, enabled, tol_pos, tol_intensity, tol_velocity)


func push_dist_perf_sample(elapsed_ms: float) -> void:
	WeatherFieldSettings.push_dist_perf_sample(self, elapsed_ms)

func push_summary_perf_sample(elapsed_ms: float) -> void:
	WeatherFieldSettings.push_summary_perf_sample(self, elapsed_ms)

func configure_emergent_coupling(enabled: bool, rain_shadow_threshold: float, rain_shadow_factor: float, orographic_boost: float) -> void:
	WeatherFieldSettings.configure_emergent_coupling(self, enabled, rain_shadow_threshold, rain_shadow_factor, orographic_boost)

func configure_terrain_wind(enabled: bool) -> void:
	WeatherFieldSettings.configure_terrain_wind(self, enabled)

func configure_ocean_spawn_bias(bias: float) -> void:
	WeatherFieldSettings.configure_ocean_spawn_bias(self, bias)

func configure_weather_field(
		enabled: bool,
		advect_steps: int,
		diffusion: float,
		condensation_gain: float,
		precip_decay: float,
		orographic_lift_gain: float,
		convergence_gain: float,
		ocean_evap_gain: float,
		summary_limit: int,
		convergence_refresh_stride: int = 2,
		precip_carryover_max: float = 0.08,
		vapor_precip_sink: float = 0.85,
		snowpack_accum_gain: float = 0.08,
		snowpack_melt_temp_gain: float = 0.22,
		snowpack_melt_sun_gain: float = 0.12,
		snowpack_cover_low: float = 0.05,
		snowpack_cover_full: float = 0.32,
		snow_accum_days_req: int = 2,
		weather_temp_anomaly_cap: float = 0.025,
		snowline_temp_threshold: float = 0.24,
		snowline_band: float = 0.22,
		vapor_relax_rate: float = 0.08,
		orographic_lift_cap: float = 0.35,
		wet_terrain_precip_damping: float = 0.28,
		lake_precip_damping: float = 0.35,
		lake_evap_scale: float = 0.35,
		extreme_precip_soft_cap: float = 0.16,
		extreme_precip_softness: float = 0.20,
		land_evapotranspiration_gain: float = 0.70,
		precip_rh_threshold: float = 0.70,
		ocean_precip_suppression: float = 0.95,
		frontogenesis_gain: float = 0.42,
		rain_shadow_drying: float = 0.35,
		vapor_transport_gain: float = 0.75) -> void:
	WeatherFieldSettings.configure_weather_field(self, enabled, advect_steps, diffusion, condensation_gain, precip_decay, orographic_lift_gain, convergence_gain, ocean_evap_gain, summary_limit, convergence_refresh_stride, precip_carryover_max, vapor_precip_sink, snowpack_accum_gain, snowpack_melt_temp_gain, snowpack_melt_sun_gain, snowpack_cover_low, snowpack_cover_full, snow_accum_days_req, weather_temp_anomaly_cap, snowline_temp_threshold, snowline_band, vapor_relax_rate, orographic_lift_cap, wet_terrain_precip_damping, lake_precip_damping, lake_evap_scale, extreme_precip_soft_cap, extreme_precip_softness, land_evapotranspiration_gain, precip_rh_threshold, ocean_precip_suppression, frontogenesis_gain, rain_shadow_drying, vapor_transport_gain)


func _sample_terrain_wind(map: MapData, _world: WorldData, world_pos: Vector2, ny: float, season_phase: float) -> Vector2:
	return WeatherFrontProjection._sample_terrain_wind(self, map, _world, world_pos, ny, season_phase)

func _map_for_spawn(_world: WorldData) -> MapData:
	return WeatherFrontProjection._map_for_spawn(self, _world)

func cell_perturbation(cell: HexCell) -> Vector2:
	return WeatherFrontProjection.cell_perturbation(self, cell)


static func _is_water_terrain(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE \
			or t == TerrainType.TERRAIN.LAKE

# ─── Emergent Climate Coupling：本地耦合辅助函数 ────────────────────────

# 按 front 类型 vs 当前 cell 温湿带的匹配度返回衰减倍率：
#   匹配 → 0.7（长寿命，例如 RAIN 走暖湿海岸）
#   中性 → 1.0
#   不匹配 → 1.5（例如 STORM 走干冷沙漠、BLIZZARD 走暖带）
