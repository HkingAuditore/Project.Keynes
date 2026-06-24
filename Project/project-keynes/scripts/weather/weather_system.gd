# weather_system.gd
# Milestone 3：天气子系统主类（按 day_changed 推进）。
#
# ─── 模块结构（dots-monolith-split / Phase E.3 真实状态，2026-06-20 校正）──
#
# 历史目标：把本文件拆到 ≤200 行。实际只完成了 hot-loop 抽出，本文件至今仍是
# 天气子系统的「编排 + 配置中心」（数千行 = 已知上帝类，见下方职责清单）。
#
# ✅ 已落地的拆分：
#   weather/field_solver.gd (DCWeatherFieldSolver)
#       已接管天气场 slice hot loop：begin_slice / run_slice / commit /
#       _solve_weather_field + 邻居/上风/抬升/辐合/海洋异常 helper。
#       本文件的 begin/run/commit_weather_field_solve 仅是薄转发入口。
#   weather/front_advect.gd (DCWeatherFrontAdvect)
#       已接管 front 推进 + cyclone wake。
#
# ❌ 计划但未落地（仍在本文件，是后续「做减法」的目标）：
#   - _distribute_weather_field_to_cells（field→cell 反馈）→ 计划 feedback.gd
#   - _build_field_summary_fronts（field→front 聚类）→ 计划 summary_builder.gd
#   - _spawn_random_front / _build_front_at（legacy front 对象层）
#
# 本文件当前实际承担的职责（≥10 个关注点）：配置中心(_field_* + configure_weather_field)、
# ClimateProfile 同步、C++ knobs 三件套构造、GDExtension 调度 + A/B verify、
# 天气类型分类、distribute 反馈、summary 聚类、legacy front 路径、查询 API。
#
# ⚠ 双份镜像维护铁律：天气物理公式在 field_solver.gd(GDScript fallback) 与
#   world_ext.cpp::run_weather_field_solve_pass(C++ 权威) 各有一份，改任一侧
#   必须同步另一侧，并跑 set_field_verify_mode(true) 对账（默认容差 1e-4）。
#
# ─── 原始职责说明（保留）────────────────────────────────────────────────
#
# 职责：
#   1. 维护一个最多 MAX_FRONTS 个活动 WeatherFront 的队列
#   2. 每天 tick：
#      a) 推进所有 front（advect by wind_field, decay intensity, age++）
#      b) 回收 dead front
#      c) 按 season + 全球气候 spawn 新 front（带类型分布）
#      d) 把每个 cell 的"被覆盖到的最强 front"写到 cell.current_state.weather/intensity
#      e) 根据 weather 临时调整 cell.moisture / temperature（覆盖 current_state.*）
#      f) 必要时短期改写 cell.cover（BLIZZARD → SNOW、MONSOON/STORM → FLOODING）
#   3. 提供 query_at(world_pos) 与 pack_to_uniforms() 让 UI / shader 直接复用
#
# 设计原则：
#   - 不写回 base_*：天气是临时性的，年度漂移（Phase 8）只看 base_moisture，
#     这样 weather 不会污染长期生态记忆，玩家手感 = "天气是表层、生态是底层"
#   - max-merge 而非线性叠加：避免双暴雨之类的数值爆炸
#   - 与 WorldClock seed 解耦：自己持有 RNG，可独立 seed → 复盘 / 多人同步友好
#   - 仅 max 16 fronts：可一次塞进 shader uniform 数组，每 fragment 16 次距离测试
#     就能完整渲染所有天气效果

class_name WeatherSystem
extends RefCounted

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
# NativeKnobs 字段与 positional 签名一并删除（见 computation-pipelines.md 根因重构节）。
var _field_precip_decay: float = 0.85
var _field_precip_carryover_max: float = 0.08
var _field_vapor_precip_sink: float = 0.85
var _field_vapor_relax_rate: float = 0.08
var _weather_temp_anomaly_cap: float = 0.025
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
var _cold_precip_as_blizzard: bool = true
var _snow_classification_margin: float = 0.03
var _field_ocean_evap_gain: float = 0.55
var _field_land_evapotranspiration_gain: float = 0.85
var _field_precip_rh_threshold: float = 0.70 # 0.60→0.70：见 climate_profile.weather_precip_rh_threshold（物理层根治：提阈让中湿区转晴）
var _field_ocean_precip_suppression: float = 0.95
# 降水惯性 EMA 系数 α(2026-06-20 根因重构)：precip = lerp(prev_precip, target, α)。越小越平滑(惯性强)、
# 越大越跟手(接近瞬时投影)。2026-06-22 标定为 0.40，减少降水拖尾。
# 统一替代旧 carryover/拖尾/滞回三件套的时间平滑机制。
var _field_precip_inertia: float = 0.40
# 雨云化(2026-06-22):降水动力化的两个旋钮镜像(默认与 field_solver const 一致;C++ 经 knobs 接收,不重编)。
var _field_precip_base_frac: float = 0.12  # autoconv 背景成雨比例;原0.50→弥漫弱雨,降到0.12让降水靠动力触发
var _field_cloud_reevap: float = 0.18      # 干空气云水再蒸发;原0.06→云不消散永雨,提到0.18让雨团消散转晴
var _field_frontogenesis_gain: float = 0.42
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
	if _tick_cell_pos.has(cell):
		return _tick_cell_pos[cell]
	return HexUtils.cube_to_world(cell.q, cell.r, _hex_size)

func _cell_neighbors(cell: HexCell, map: MapData) -> Array:
	if _tick_cell_neighbors.has(cell):
		return _tick_cell_neighbors[cell]
	if map == null:
		return []
	return map.get_neighbors(cell)

func last_breakdown() -> Dictionary:
	return _last_breakdown


func _mark_weather_commit_tick() -> Dictionary:
	var prev: int = _last_weather_commit_tick
	var delta: int = (_field_solve_tick - prev) if prev >= 0 else 0
	_last_weather_commit_tick = _field_solve_tick
	return {
		"weather_commit_tick_delta": delta,
		"weather_last_commit_tick": _last_weather_commit_tick,
	}

func _percentile_abs_from_array(values: PackedFloat32Array, q: float) -> float:
	var n: int = values.size()
	if n <= 0:
		return 0.0
	var sorted: Array[float] = []
	sorted.resize(n)
	for i in range(n):
		sorted[i] = absf(values[i])
	sorted.sort()
	var qi: int = clampi(int(floor(float(n - 1) * clampf(q, 0.0, 1.0))), 0, n - 1)
	return float(sorted[qi])

# --- 初始化 ---

func init(seed_val: int, world_bounds: Rect2, hex_size: float) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_val ^ 0xBEEF1234
	_world_bounds = world_bounds
	_hex_size = hex_size
	_active_fronts.clear()
	_day_counter = 0
	# Continuity-fix：换地图/重 init 时必须清掉跨 tick 继承状态，
	# 否则旧地图的 HexCell 弱引用 + 旧 cluster 中心会污染新地图的首帧聚类。
	_prev_summary_membership.clear()
	_prev_summary_seeds.clear()
	# dots-monolith-split §1.1：sub-module 实例化（owner 引用 self，
	# sub-module 通过 owner 访问 ocean_current_perturbation / _active_fronts /
	# _hex_size / _cyclone_wake_days 等共享状态）。
	if _advect == null:
		_advect = DCWeatherFrontAdvect.new(self)
	# dots-monolith-split §1.2：field_solver 实例化。已接管天气场 slice hot loop
	# （begin_slice/run_slice/commit/_solve_weather_field）；本类对应函数仅薄转发。
	if _field_solver == null:
		_field_solver = DCWeatherFieldSolver.new(self)

# --- 每日 tick（由 MapGenerator.refresh_daily 调用） ---

# season_idx: 0=春 1=夏 2=秋 3=冬
# climate_anomaly: 全球长期温度偏移 [-0.2, +0.2]
# season_phase: 连续浮点 [0,4)；如果 caller 不传则 fallback 到 season_idx + 0.5。
# 返回当前活动 front 的快照（给 main / renderer 上传 shader uniform 用）
func tick_one_day(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	if map == null or world == null:
		return _active_fronts
	_day_counter += 1
	_current_map_for_tick = map
	# 缓存当前轨道相位给 wind_fn / spawn 的兼容签名。
	# fallback：如果 caller 没提供（旧调用方兼容），按 season_idx 取季中点。
	_season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5

	# wind_fn 优先读 per-cell 风场；fallback 只给无风场时的纬向基线。
	var bounds := _world_bounds
	var sp := _season_phase
	var map_ref := map
	var self_ref := self
	var wind_fn := func(pos: Vector2) -> Vector2:
		var ny: float = 0.5
		if bounds.size.y > 0.001:
			ny = clampf((pos.y - bounds.position.y) / bounds.size.y, 0.0, 1.0)
		return self_ref._sample_terrain_wind(map_ref, world, pos, ny, sp)

	if _weather_field_enabled:
		begin_weather_field_solve(map, world, season_idx, climate_anomaly, _season_phase, false)
		while true:
			var slice_result: Dictionary = run_weather_field_solve_slice(2147483647)
			if bool(slice_result.get("done", true)):
				break
		return commit_weather_field_solve()

	# Daily-sim perf instrumentation：带埋点的 advance / spawn / distribute / cyclone 四段。
	var t_us0: int = Time.get_ticks_usec()

	# 1) 推进所有 front + 2) 回收 dead 与出图 front
	# dots-monolith-split §1.1 第 2 步：130 行内联实现已迁出至
	# scripts/weather/front_advect.gd::tick_advance_fronts(map, wind_fn)。
	# 业务等价：emergent_coupling 预算 + F.6 C++ 快路径 + GDScript fallback + reap。
	var advance_ms: float = _advect.tick_advance_fronts(map, wind_fn)

	# 3) Spawn 新 front
	t_us0 = Time.get_ticks_usec()
	var spawn_prob: float = 0.34
	for i in range(SPAWN_TRIES_PER_DAY):
		if _active_fronts.size() >= MAX_FRONTS:
			break
		if _rng.randf() < spawn_prob:
			var f: WeatherFront
			if _emergent_coupling:
				f = _spawn_emergent_front(map, world, season_idx, climate_anomaly)
			else:
				f = _spawn_random_front(world, season_idx, climate_anomaly)
			if f != null:
				_active_fronts.append(f)
	var spawn_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 4) 把当前所有 front 影响分发到每个 cell
	t_us0 = Time.get_ticks_usec()
	_distribute_to_cells(map)
	var distribute_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 5) Systemic Ocean Currents：台风尾迹扰动（可选，默认关闭）
	# 在强海上风暴（STORM + on_water + intensity > 0.8）点注入旋转扰动向量，
	# 随后每天线性衰减，_cyclone_wake_days 后清零。仅 CPU 端维护；渲染消费方
	# 可按需扩展（例如上传 RG8 overlay 让 shader 与主流场相加）。
	var cyclone_ms: float = 0.0
	if _cyclone_wake_enabled:
		t_us0 = Time.get_ticks_usec()
		# dots-monolith-split §1.1：cyclone_wake 已迁出至 DCWeatherFrontAdvect。
		_advect.tick_cyclone_wake(map)
		cyclone_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	_last_breakdown = {
		"advance_ms": advance_ms,
		"spawn_ms": spawn_ms,
		"distribute_ms": distribute_ms,
		"cyclone_ms": cyclone_ms,
	}
	_last_breakdown.merge(_front_diagnostic_counts(_active_fronts), true)
	_last_breakdown.merge(_mark_weather_commit_tick(), true)
	_current_map_for_tick = null
	return _active_fronts

# --- 内部：按 season + 经纬度 spawn 一个新 front ---

func _spawn_random_front(world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	# 在地图内随机选一个 spawn 点
	var origin := _world_bounds.position
	var size := _world_bounds.size
	var sx: float = _rng.randf_range(origin.x, origin.x + size.x)
	var sy: float = _rng.randf_range(origin.y, origin.y + size.y)
	var spawn_pos := Vector2(sx, sy)

	# 该点的 latitude_norm（用于决定可生成的天气类型）。
	# latitude_buffer 直接给的是 [0,1] 的 ny，转成 [-1, 1] 表示南北纬。
	var lat_norm: float = world.sample_moisture(spawn_pos)  # placeholder if no helper
	# 安全用法：直接复用 _world_to_uv 思路 → 自己算
	if size.y > 0.001:
		lat_norm = clampf((sy - origin.y) / size.y, 0.0, 1.0)
	var lat_signed: float = lat_norm * 2.0 - 1.0   # -1 = 南极, +1 = 北极
	var abs_lat: float = absf(lat_signed)

	# 在水面 spawn 的天气类型受限（HEATWAVE/DROUGHT 不在海上 spawn）
	var on_water: bool = false
	var biome_at_spawn: int = world.sample_biome(spawn_pos)
	if biome_at_spawn == 0 or biome_at_spawn == 1 or biome_at_spawn == 18 \
			or biome_at_spawn == 19 or biome_at_spawn == 20 or biome_at_spawn == 21:
		# OCEAN/COAST/LAKE/REEF/SEA_ICE/KELP（与 world_map.gdshader B_* 常量同序）
		on_water = true

	# 类型抽样：按 (season, latitude, on_water) 加权
	var wt: int = _pick_weather_type(season_idx, abs_lat, on_water, climate_anomaly)
	if wt == WeatherType.WT.CLEAR:
		return null  # CLEAR 不需要 front 实例

	var front := WeatherFront.new()
	front.center = spawn_pos
	front.type = wt
	front.intensity = _rng.randf_range(0.55, 1.0)
	# 半径以 hex_size 为基准；不同天气大小不同
	var radius_mul: float = 1.0
	match wt:
		WeatherType.WT.RAIN:     radius_mul = _rng.randf_range(6.0, 12.0)
		WeatherType.WT.STORM:    radius_mul = _rng.randf_range(5.0, 9.0)
		WeatherType.WT.BLIZZARD: radius_mul = _rng.randf_range(7.0, 13.0)
		WeatherType.WT.DROUGHT:  radius_mul = _rng.randf_range(10.0, 18.0)
		WeatherType.WT.FOG:      radius_mul = _rng.randf_range(4.0, 8.0)
		WeatherType.WT.HEATWAVE: radius_mul = _rng.randf_range(8.0, 14.0)
		WeatherType.WT.MONSOON:  radius_mul = _rng.randf_range(8.0, 14.0)
		_:                       radius_mul = 8.0
	front.radius = _hex_size * radius_mul
	front.edge_seed = _rng.randf_range(0.0, 1000.0)
	# 寿命与衰减：DROUGHT/HEATWAVE 较慢，雷暴较快
	# Phase E（方案 A）：寿命整体 ~×2，decay 减半。短命类型（STORM/FOG/BLIZZARD）
	# 在快推进档位下原本 2~4 天就消失，肉眼上是"突现突灭"；现在 RAIN ~14 天、
	# STORM ~9 天、FOG ~8 天、BLIZZARD ~12 天，配合更慢衰减让强度曲线变缓，
	# 表现层有充足时间做 birth/dissolve 渐变。DROUGHT/HEATWAVE 已是长寿命，
	# 仅微调以维持相对比例。
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = _rng.randi_range(30, 56)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = _rng.randi_range(12, 22)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			# 强对流/热带暴雨：原 6-11 天 → 4-8 天，避免单地连下一周
			front.ttl_days = _rng.randi_range(4, 8)
			front.decay_per_day = 0.14
		WeatherType.WT.BLIZZARD:
			# 暴雪：原 8-14 天 → 5-10 天
			front.ttl_days = _rng.randi_range(5, 10)
			front.decay_per_day = 0.12
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			# RAIN：原 10-16 天 → 6-11 天
			front.ttl_days = _rng.randi_range(6, 11)
			front.decay_per_day = 0.07
	# 初始速度沿当前 spawn 点风向。
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((sy - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = _sample_terrain_wind(_map_for_spawn(world), world, spawn_pos, ny_spawn, _season_phase)
	if wind.length() > 0.05:
		var wind_axis := wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		# Phase E（方案 A）：把每天行进距离从 0.4×radius 提到 0.65×radius。
		# 配合寿命翻倍，front 总位移从 ~2×radius 提到 ~5×radius，
		# 视觉上是“持续飘过来再飘过去”，而不是“原地附近晃动”。
		front.velocity = wind_axis * (front.radius * 0.65)
	else:
		var a := _rng.randf_range(0.0, TAU)
		front.axis = Vector2(cos(a), sin(a))
		front.stable_axis = front.axis
	_apply_front_shape_by_type(front)
	front.refresh_visual_lifecycle()
	return front

func _apply_front_shape_by_type(front: WeatherFront) -> void:
	if front == null:
		return
	match front.type:
		WeatherType.WT.RAIN:
			front.major_scale = 1.65
			front.minor_scale = 0.68
		WeatherType.WT.STORM:
			front.major_scale = 1.18
			front.minor_scale = 0.72
		WeatherType.WT.BLIZZARD:
			front.major_scale = 1.85
			front.minor_scale = 0.48
		WeatherType.WT.DROUGHT:
			front.major_scale = 1.42
			front.minor_scale = 0.86
		WeatherType.WT.FOG:
			front.major_scale = 1.35
			front.minor_scale = 1.05
		WeatherType.WT.HEATWAVE:
			front.major_scale = 1.55
			front.minor_scale = 0.82
		WeatherType.WT.MONSOON:
			front.major_scale = 2.05
			front.minor_scale = 0.56
		_:
			front.major_scale = 1.0
			front.minor_scale = 1.0

# 加权类型抽样：
#   abs_lat ∈ [0, 1]：0=赤道, 1=极地
#   on_water：海面禁用 HEATWAVE / DROUGHT；WT.MONSOON 作为强热带降水兼容类型
#   climate_anomaly：全球暖化 → HEATWAVE/DROUGHT 概率上调；冷化 → BLIZZARD 上调
func _pick_weather_type(season_idx: int, abs_lat: float, on_water: bool, climate_anomaly: float) -> int:
	season_idx = -1
	var weights: Dictionary = {
		WeatherType.WT.RAIN:     1.0,
		WeatherType.WT.STORM:    0.5,
		WeatherType.WT.FOG:      0.3,
		WeatherType.WT.BLIZZARD: 0.0,
		WeatherType.WT.DROUGHT:  0.0,
		WeatherType.WT.HEATWAVE: 0.0,
		WeatherType.WT.MONSOON:  0.0,
	}

	# 旧季节调权分支已禁用；front 类型不再由 season_idx 直接指定。
	match -1:
		0:  # 春
			weights[WeatherType.WT.RAIN]     = 1.4
			weights[WeatherType.WT.STORM]    = 0.6
			weights[WeatherType.WT.FOG]      = 0.5
		1:  # 夏
			weights[WeatherType.WT.STORM]    = 1.2
			weights[WeatherType.WT.HEATWAVE] = 0.7 if not on_water else 0.0
			weights[WeatherType.WT.DROUGHT]  = 0.5 if not on_water else 0.0
			# Legacy only：旧夏季低纬强降水权重，当前分支不会进入。
			if abs_lat < 0.45:
				weights[WeatherType.WT.MONSOON] = 1.0
		2:  # 秋
			weights[WeatherType.WT.RAIN]     = 1.2
			weights[WeatherType.WT.STORM]    = 0.7
			weights[WeatherType.WT.FOG]      = 0.6
		3:  # 冬
			weights[WeatherType.WT.RAIN]     = 0.6
			weights[WeatherType.WT.STORM]    = 0.4
			# Legacy only：旧冬季高纬暴雪权重，当前分支不会进入。
			if abs_lat > 0.45:
				weights[WeatherType.WT.BLIZZARD] = 1.6
			weights[WeatherType.WT.FOG] = 0.7

	# 高纬度永远禁掉 HEATWAVE/MONSOON
	if abs_lat > 0.55:
		weights[WeatherType.WT.HEATWAVE] = 0.0
		weights[WeatherType.WT.MONSOON]  = 0.0
	# 低纬度永远禁掉 BLIZZARD
	if abs_lat < 0.30:
		weights[WeatherType.WT.BLIZZARD] = 0.0

	# 全球气候异常调权
	if climate_anomaly > 0.05:
		weights[WeatherType.WT.HEATWAVE] *= 1.0 + climate_anomaly * 4.0
		weights[WeatherType.WT.DROUGHT]  *= 1.0 + climate_anomaly * 3.0
		weights[WeatherType.WT.BLIZZARD] *= 0.5
	elif climate_anomaly < -0.05:
		weights[WeatherType.WT.BLIZZARD] *= 1.0 + (-climate_anomaly) * 4.0
		weights[WeatherType.WT.HEATWAVE] *= 0.4
		weights[WeatherType.WT.DROUGHT]  *= 0.6

	# 累计概率抽样
	var total: float = 0.0
	for v in weights.values():
		total += float(v)
	if total <= 0.001:
		return WeatherType.WT.CLEAR
	var pick: float = _rng.randf() * total
	var acc: float = 0.0
	for k in weights.keys():
		acc += float(weights[k])
		if pick <= acc:
			return int(k)
	return WeatherType.WT.CLEAR

# --- 把活跃 front 的影响分发到每个 cell ---

func _distribute_to_cells(map: MapData) -> void:
	_cover_dirty = false
	# PR-2.1.6（weather → climate 反馈写路径下移）：预分配 batch buffer。
	# distribute 段在 weather field commit 之后跑，把 weather 扰动叠加到 cell.moisture/temp。
	# 详见 master 手册 §3.9.2 PR-2.1.6b。
	var _wd_n: int = map.cell_count() if map.has_method("cell_count") else map.all_cells().size()
	var _wd_idx: PackedInt32Array = PackedInt32Array()
	var _wd_moist: PackedFloat32Array = PackedFloat32Array()
	var _wd_temp: PackedFloat32Array = PackedFloat32Array()
	_wd_idx.resize(_wd_n)
	_wd_moist.resize(_wd_n)
	_wd_temp.resize(_wd_n)
	var _wd_w: int = 0

	for cell: HexCell in map.all_cells():
		var pos := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		var result := query_at(pos)
		var wt: int = int(result.get("type", WeatherType.WT.CLEAR))
		var intensity: float = float(result.get("intensity", 0.0))
		# 把 weather 状态写到 current_state（weather/intensity 仍是离散字段，保留字典）
		cell.current_state["weather"] = wt
		cell.current_state["weather_intensity"] = intensity
		# 应用临时湿度 / 温度扰动（不写回 base_*）
		# Fast-tick perf opt (C)：moisture / temperature 已升级为强类型成员，直接读写。
		var moist_now: float = cell.moisture
		var temp_now: float = cell.temperature
		moist_now = clampf(moist_now + WeatherType.moisture_delta(wt) * intensity, 0.0, 1.0)
		var weather_temp_delta: float = clampf(WeatherType.temp_delta(wt) * intensity, -_weather_temp_anomaly_cap, _weather_temp_anomaly_cap)
		temp_now = clampf(temp_now + weather_temp_delta, 0.0, 1.0)
		# [perf 2026-05-20] 删除 cell.moisture = / cell.temperature = 单点 setter。
		# 这里循环 2400 次，每次走 facade setter → world.write_f32 → _dirty_mark_one 风暴，
		# 把 _dirty_cell_mask 标成全 1。下面的批量数组 _wd_moist / _wd_temp + 末尾
		# write_f32_indexed 已经完整 commit（含 dirty range 标记），单点 setter 是冗余写。
		# 若 facade 未启用 → fallback 回单点 setter（保 backing 同步）。
		if _data_core_world == null:
			cell.moisture = moist_now
			cell.temperature = temp_now
		# PR-2.1.6：收集 dirty entry。
		if cell.index >= 0 and _wd_w < _wd_n:
			_wd_idx[_wd_w] = int(cell.index)
			_wd_moist[_wd_w] = moist_now
			_wd_temp[_wd_w] = temp_now
			_wd_w += 1
		# 临时覆盖物：FLOODING 仍走即时写入；SNOW 改走 _apply_snow_accumulation 累积式
		# 累积式好处：(1) 雪不再随单帧 BLIZZARD 闪烁出现；(2) 温升时按节律消融
		var is_water_cell: bool = LandformType.is_water(cell.landform) or _is_water_terrain(int(cell.terrain))
		if not is_water_cell:
			# 1) 雪：累积 / 融化
			if _apply_snow_accumulation(cell, wt, temp_now, intensity):
				_cover_dirty = true
			# 2) 洪涝：保留即时写入。放宽条件 + 高强度直接淹（让暴雨真的导致洪涝）
			# 修：原条件 intensity>0.4 + elev<0.55 + moist>0.65 太严，从未触发
			# 现：低洼+中强度，或任意海拔下的极端暴雨都能淹
			if cell.cover != CoverType.CV.SNOW and WeatherType.can_form_flood(wt):
				var precip_now: float = float(cell.current_state.get("weather_precip", 0.0))
				var heavy_flood: bool = intensity > 0.55 and precip_now > 0.55  # 极端暴雨：任意海拔
				var lowland_flood: bool = intensity > 0.32 and cell.elevation < 0.50 and moist_now > 0.60
				if (heavy_flood or lowland_flood) and cell.cover != CoverType.CV.FLOODING:
					cell.cover = CoverType.CV.FLOODING
					cell.current_state["cover"] = int(cell.cover)
					_cover_dirty = true
				elif cell.cover == CoverType.CV.FLOODING and not heavy_flood and not lowland_flood and moist_now < 0.50:
					# Stage8 修"洪泛不退→与旱灾共存"：积水在干燥(无致洪条件且 moist<0.50)时退去，恢复 NONE。
					cell.cover = CoverType.CV.NONE
					cell.current_state["cover"] = int(cell.cover)
					_cover_dirty = true

	# PR-2.1.6（weather → climate 反馈写路径下移）：循环结束后批量提交 cell.moisture / cell.temperature 到 DCWorld。
	if _data_core_world != null and _wd_w > 0:
		_wd_idx.resize(_wd_w)
		_wd_moist.resize(_wd_w)
		_wd_temp.resize(_wd_w)
		var _cid_md: int = _data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		if _cid_md >= 0:
			_data_core_world.write_f32_indexed(_cid_md, _wd_idx, _wd_moist)
		var _cid_td: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
		if _cid_td >= 0:
			_data_core_world.write_f32_indexed(_cid_td, _wd_idx, _wd_temp)
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] 前 5 次 + 之后每 50 次打一次
		_diag_wd_commit_count += 1
		if _diag_wd_commit_count <= 5 or (_diag_wd_commit_count % 50) == 0:
			print("[DIAG weather_wd_commit] #%d wrote %d cells (moist+temp)" % [_diag_wd_commit_count, _wd_w])

func uses_weather_field() -> bool:
	return _weather_field_enabled

func is_weather_field_solve_active() -> bool:
	return _field_solver._field_slice_active

func begin_weather_field_solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true) -> void:
	# dots-monolith-split §1.2 / PR-6：切片初始化主体已搬迁到
	# scripts/weather/field_solver.gd::begin_slice()。本侧仅作为外部 caller
	# (map_generator.gd / weather_refresh_job 等 SUS job) 的薄转发入口。
	_field_solver.begin_slice(map, world, season_idx, climate_anomaly, season_phase, count_day)

func run_weather_field_solve_slice(cell_budget: int) -> Dictionary:
	# dots-monolith-split §1.2 / PR-6：切片单步主体（含 DCWorldExt fast path
	# 与 GDScript fallback hot loop）已搬迁到 scripts/weather/field_solver.gd::run_slice()。
	return _field_solver.run_slice(cell_budget)

func commit_weather_field_solve() -> Array[WeatherFront]:
	# dots-monolith-split §1.2 / PR-5：149 行 commit 主体已整体搬迁到
	# scripts/weather/field_solver.gd::commit()。weather_system 本侧末端仅作为
	# tick_one_day 调用入口作薄转发，然后 PR-7 可考虑进一步清理。
	return _field_solver.commit()

# ─── Phase F.1：DCWorldExt 路径 helper ───────────────────────────────────
# 把 GDScript 端的所有 cp/profile/_field_* 旋钮、世界边界、预先打包好的
# PackedArray 输入打包成一个 Dictionary 交给 C++。所有 key 名与 world_ext.h
# 的 F.1 文档块一一对应；任何 key 缺失都会让 C++ return -1.0 透明 fallback。
func _build_weather_field_knobs(map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> Dictionary:
	var end_idx_resolved: int = n_cells if end_idx < 0 else end_idx
	var temp_anom_arr: PackedFloat32Array = _field_solver._field_slice_temp_anom
	if temp_anom_arr.size() != n_cells:
		temp_anom_arr = map.temperature_transport_anomaly_arr
	if temp_anom_arr.size() != n_cells:
		temp_anom_arr = PackedFloat32Array()
		temp_anom_arr.resize(n_cells)
		var cells_l: Array = _field_solver._field_slice_cells
		for i in range(n_cells):
			var c: HexCell = cells_l[i]
			temp_anom_arr[i] = float(c.temperature_transport_anomaly)
	# ─── Phase A.3 fast path：从 KnobsHandle 拿标量段缓存 Dict ──────────
	# 动态字段（SoA cache / PackedArray ref / temp_anom_arr）仍每帧准备并 merge。
	# 标量段在 ClimateProfile 不变的稳态下复用缓存 Dict（CoW 引用 ++）。
	if _knobs_handle != null and _knobs_handle.has_method("to_field_knobs_dict"):
		# day_counter / season_phase 每帧可能变 → 这里同步推一次（dirty-write 内部
		# 走值比较，无变化时不拉 dirty，缓存 Dict 命中）。
		_push_resident_knobs_from_cp(_cp_for_front_flag)
		var dynamic_fields: Dictionary = {
			"start_idx": start_idx,
			"end_idx": end_idx_resolved,
			"n_cells": n_cells,
			"season_idx": _field_solver._field_slice_season_idx,
			"climate_anomaly": _field_solver._field_slice_climate_anomaly,
			"refresh_convergence": _field_solver._field_slice_refresh_convergence,
			"weather_lat_te_norm": _field_solver._field_slice_lat_te_norm,
			"weather_solve_tick": _field_solve_tick,
			"cell_pos": _field_solver._field_slice_cell_pos,
			"weather_wrap_width_x": _field_solver._field_slice_wrap_width_x,
			"weather_cell_pos_scale": _field_solver._field_slice_cell_pos_scale,
			"temp_anomaly": map.temp_anomaly_arr,
			"neighbor_indices": _field_solver._field_slice_neighbor_indices,
			"prev_vapor": _field_solver._field_slice_prev_vapor,
			"prev_precip": _field_solver._field_slice_prev_precip,
			"prev_cloud_water": map.weather_cloud_water_arr,
			"temp_read_arr": _field_solver._field_slice_temp_read,
			"moisture_read_arr": _field_solver._field_slice_moisture_read,
			"snow_cover_read_arr": _field_solver._field_slice_snow_cover_read,
			"temp_transport_anomaly": temp_anom_arr,
			"out_vapor": _field_solver._field_slice_next_vapor,
			"out_cloud": _field_solver._field_slice_next_cloud,
			"out_cloud_water": _field_solver._field_slice_next_cloud_water,
			"out_precip": _field_solver._field_slice_next_precip,
			"out_instability": _field_solver._field_slice_next_instability,
			"out_intensity": _field_solver._field_slice_next_intensity,
			"out_convergence": _field_solver._field_slice_next_convergence,
			"out_type": _field_solver._field_slice_next_type,
			"field_precip_carryover_max": _field_precip_carryover_max,
			"field_vapor_precip_sink": _field_vapor_precip_sink,
			"field_precip_inertia": _field_precip_inertia,
			"field_precip_base_frac": _field_precip_base_frac,
			"field_cloud_reevap": _field_cloud_reevap,
			"field_vapor_relax_rate": _field_vapor_relax_rate,
			"field_orographic_lift_cap": _field_orographic_lift_cap,
			"field_wet_terrain_precip_damping": _field_wet_terrain_precip_damping,
			"field_lake_precip_damping": _field_lake_precip_damping,
			"field_lake_evap_scale": _field_lake_evap_scale,
			"field_extreme_precip_soft_cap": _field_extreme_precip_soft_cap,
			"field_extreme_precip_softness": _field_extreme_precip_softness,
			"field_land_evapotranspiration_gain": _field_land_evapotranspiration_gain,
			"field_precip_rh_threshold": _field_precip_rh_threshold,
			"field_ocean_precip_suppression": _field_ocean_precip_suppression,
			"field_frontogenesis_gain": _field_frontogenesis_gain,
			"field_rain_shadow_drying": _field_rain_shadow_drying,
			"field_vapor_transport_gain": _field_vapor_transport_gain,
			"cold_precip_as_blizzard": _cold_precip_as_blizzard,
			"snow_classification_margin": _snow_classification_margin,
			"weather_transition_enabled": bool(_cp_for_front_flag.weather_transition_enabled) if _cp_for_front_flag != null and _cp_for_front_flag.get("weather_transition_enabled") != null else false,
			"weather_transition_alpha_rate": float(_cp_for_front_flag.weather_transition_alpha_rate) if _cp_for_front_flag != null and _cp_for_front_flag.get("weather_transition_alpha_rate") != null else 1.0,
		}
		return _merge_resident_knobs_with_dynamic(_knobs_handle.to_field_knobs_dict(), dynamic_fields)
	# ─── Fallback：原 builder 路径（与 Phase A.3 之前 100% bit-equal）──
	return {
		"start_idx": start_idx,
		"end_idx": end_idx_resolved,
		"n_cells": n_cells,
		"season_idx": _field_solver._field_slice_season_idx,
		"climate_anomaly": _field_solver._field_slice_climate_anomaly,
		"season_phase": _season_phase,
		"world_bounds_pos_y": _world_bounds.position.y,
		"world_bounds_size_y": _world_bounds.size.y,
		"weather_lat_te_norm": _field_solver._field_slice_lat_te_norm,
		"weather_solve_tick": _field_solve_tick,
		"refresh_convergence": _field_solver._field_slice_refresh_convergence,
		"weather_wrap_width_x": _field_solver._field_slice_wrap_width_x,
		"weather_cell_pos_scale": _field_solver._field_slice_cell_pos_scale,
		"apply_convergence_boost": not _field_verify_enabled,
		"hex_size": _hex_size,
		"field_advect_steps": _field_advect_steps,
		"field_diffusion": _field_diffusion,
		"field_condensation_gain": _field_condensation_gain,
		"field_orographic_lift_gain": _field_orographic_lift_gain,
		"field_convergence_gain": _field_convergence_gain,
		"field_ocean_evap_gain": _field_ocean_evap_gain,
		"field_precip_decay": _field_precip_decay,
		"cell_pos": _field_solver._field_slice_cell_pos,
		"temp_anomaly": map.temp_anomaly_arr,
		"neighbor_indices": _field_solver._field_slice_neighbor_indices,
		"prev_vapor": _field_solver._field_slice_prev_vapor,
		"prev_precip": _field_solver._field_slice_prev_precip,
		"prev_cloud_water": map.weather_cloud_water_arr,
		"temp_read_arr": _field_solver._field_slice_temp_read,
		"moisture_read_arr": _field_solver._field_slice_moisture_read,
		"snow_cover_read_arr": _field_solver._field_slice_snow_cover_read,
		"temp_transport_anomaly": temp_anom_arr,
		"out_vapor": _field_solver._field_slice_next_vapor,
		"out_cloud": _field_solver._field_slice_next_cloud,
		"out_cloud_water": _field_solver._field_slice_next_cloud_water,
		"out_precip": _field_solver._field_slice_next_precip,
		"out_instability": _field_solver._field_slice_next_instability,
		"out_intensity": _field_solver._field_slice_next_intensity,
		"out_convergence": _field_solver._field_slice_next_convergence,
		"out_type": _field_solver._field_slice_next_type,
		"field_precip_carryover_max": _field_precip_carryover_max,
		"field_vapor_precip_sink": _field_vapor_precip_sink,
		"field_precip_inertia": _field_precip_inertia,
		"field_precip_base_frac": _field_precip_base_frac,
		"field_cloud_reevap": _field_cloud_reevap,
		"field_vapor_relax_rate": _field_vapor_relax_rate,
		"field_orographic_lift_cap": _field_orographic_lift_cap,
		"field_wet_terrain_precip_damping": _field_wet_terrain_precip_damping,
		"field_lake_precip_damping": _field_lake_precip_damping,
		"field_lake_evap_scale": _field_lake_evap_scale,
		"field_extreme_precip_soft_cap": _field_extreme_precip_soft_cap,
		"field_extreme_precip_softness": _field_extreme_precip_softness,
		"field_land_evapotranspiration_gain": _field_land_evapotranspiration_gain,
		"field_precip_rh_threshold": _field_precip_rh_threshold,
		"field_ocean_precip_suppression": _field_ocean_precip_suppression,
		"field_frontogenesis_gain": _field_frontogenesis_gain,
		"field_rain_shadow_drying": _field_rain_shadow_drying,
		"field_vapor_transport_gain": _field_vapor_transport_gain,
		"cold_precip_as_blizzard": _cold_precip_as_blizzard,
		"snow_classification_margin": _snow_classification_margin,
		"weather_transition_enabled": bool(_cp_for_front_flag.weather_transition_enabled) if _cp_for_front_flag != null and _cp_for_front_flag.get("weather_transition_enabled") != null else false,
		"weather_transition_alpha_rate": float(_cp_for_front_flag.weather_transition_alpha_rate) if _cp_for_front_flag != null and _cp_for_front_flag.get("weather_transition_alpha_rate") != null else 1.0,
	}

# 调用 C++ 端 run_weather_field_solve_pass。返回 elapsed_ms (≥0) 或 -1.0。
# 任何异常都被 catch 成 -1.0，让上层透明回退。
func _try_run_weather_field_solve_gdext(map: MapData, world: WorldData, n_cells: int, start_idx: int = 0, end_idx: int = -1) -> float:
	if _data_core_world_ext == null:
		return -1.0
	var end_idx_resolved: int = n_cells if end_idx < 0 else end_idx
	var knobs: Dictionary = _field_solver._field_slice_native_knobs
	if knobs.is_empty():
		knobs = _build_weather_field_knobs(map, world, n_cells, start_idx, end_idx_resolved)
	else:
		knobs["start_idx"] = start_idx
		knobs["end_idx"] = end_idx_resolved
		knobs["prev_cloud_water"] = map.weather_cloud_water_arr
		knobs["out_vapor"] = _field_solver._field_slice_next_vapor
		knobs["out_cloud"] = _field_solver._field_slice_next_cloud
		knobs["out_cloud_water"] = _field_solver._field_slice_next_cloud_water
		knobs["out_precip"] = _field_solver._field_slice_next_precip
		knobs["out_instability"] = _field_solver._field_slice_next_instability
		knobs["out_intensity"] = _field_solver._field_slice_next_intensity
		knobs["out_convergence"] = _field_solver._field_slice_next_convergence
		knobs["out_type"] = _field_solver._field_slice_next_type
	# Stage6c: 对流抑制记忆改存为 C++ ext 成员(_wx_conv_inhib)，不再走 knob 回传(CoW 失败)。GDScript fallback
	# 路径仍用 _field_solver._convective_inhib 成员(同进程内无边界问题)。
	var rc: float = float(_data_core_world_ext.run_weather_field_solve_pass(knobs))
	if rc >= 0.0 and knobs.has("out_vapor"):
		_field_solver._field_slice_next_vapor = knobs["out_vapor"]
		_field_solver._field_slice_next_cloud = knobs["out_cloud"]
		_field_solver._field_slice_next_cloud_water = knobs.get("out_cloud_water", _field_solver._field_slice_next_cloud_water)
		_field_solver._field_slice_next_precip = knobs["out_precip"]
		_field_solver._field_slice_next_instability = knobs["out_instability"]
		_field_solver._field_slice_next_intensity = knobs["out_intensity"]
		_field_solver._field_slice_next_convergence = knobs["out_convergence"]
		_field_solver._field_slice_next_type = knobs["out_type"]
	# C++ 在失败时已经 push_warning；这里只在第一次 fallback 时打一条 GDScript
	# 侧提示，避免每 tick spam。
	if rc < 0.0 and not _gdext_field_warned_fallback:
		_gdext_field_warned_fallback = true
		push_warning("[weather] gdext run_weather_field_solve_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
	return rc


# Stage13「让天气移动」：调用 C++ 独立全场 ψ 推进 pass（每 weather 轮一次，在 commit 后）。
# ψ 演化已从 solve 热循环抽出 → 本 pass 用平滑引导流做半拉格朗日真平移，让 ψ 涡旋成片随风移动；
# solve 循环只读 _wx_synoptic 做耦合 → 云/雨随 ψ 移动。复用本轮 begin 已构建的 native knobs
# (含 cell_pos/neighbor_indices/wind/temp/wrap/tick/syn_*)。未就绪/失败返回 -1.0（ψ 保持上轮值，不崩）。
func run_synoptic_advance_pass(map: MapData, world: WorldData) -> float:
	if _data_core_world_ext == null or not _use_gdext_weather_field:
		return -1.0
	if not _data_core_world_ext.has_method("run_synoptic_advance_pass"):
		return -1.0
	var knobs: Dictionary = _field_solver._field_slice_native_knobs
	if knobs.is_empty():
		# native_knobs 未就绪 → 自建一份(合并/切片路径 begin 已设 _field_slice_* 状态)。
		var n_cells: int = map.cell_count() if map != null and map.has_method("cell_count") else 0
		if n_cells <= 0:
			return -1.0
		knobs = _build_weather_field_knobs(map, world, n_cells, 0, n_cells)
	if knobs.is_empty():
		return -1.0
	var rc: float = float(_data_core_world_ext.run_synoptic_advance_pass(knobs))
	return rc


func _try_run_weather_field_commit_gdext(map: MapData, n_cells: int) -> Dictionary:
	if _data_core_world_ext == null or not _data_core_world_ext.has_method("run_weather_field_commit_pass"):
		return { "elapsed_ms": -1.0, "reason": "native_unavailable" }
	var knobs: Dictionary = _field_solver._field_slice_native_knobs
	if knobs.is_empty():
		knobs = {}
	knobs["n_cells"] = n_cells
	knobs["neighbor_indices"] = _field_solver._field_slice_neighbor_indices
	knobs["prev_vapor"] = _field_solver._field_slice_prev_vapor
	knobs["out_vapor"] = _field_solver._field_slice_next_vapor
	knobs["out_cloud"] = _field_solver._field_slice_next_cloud
	knobs["out_cloud_water"] = _field_solver._field_slice_next_cloud_water
	knobs["out_precip"] = _field_solver._field_slice_next_precip
	knobs["out_instability"] = _field_solver._field_slice_next_instability
	knobs["out_intensity"] = _field_solver._field_slice_next_intensity
	knobs["out_convergence"] = _field_solver._field_slice_next_convergence
	knobs["out_type"] = _field_solver._field_slice_next_type
	knobs["refresh_convergence"] = _field_solver._field_slice_refresh_convergence
	knobs["weather_transition_enabled"] = bool(_cp_for_front_flag.weather_transition_enabled) if _cp_for_front_flag != null and _cp_for_front_flag.get("weather_transition_enabled") != null else false
	knobs["weather_transition_alpha_rate"] = float(_cp_for_front_flag.weather_transition_alpha_rate) if _cp_for_front_flag != null and _cp_for_front_flag.get("weather_transition_alpha_rate") != null else 1.0
	var rc_dict: Dictionary = _data_core_world_ext.run_weather_field_commit_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0 and not _gdext_field_commit_warned_fallback:
		_gdext_field_commit_warned_fallback = true
		push_warning("[weather] gdext run_weather_field_commit_pass returned %.2f (%s); falling back to GDScript commit loop" % [
			rc,
			str(rc_dict.get("reason", "unknown")),
		])
	return rc_dict

# ─── Weather Hot-Path：dist GDExt 接入点（plan/weather-hotpath-cpp 任务 3）──
# 与 F.1 同款套路：sig 校验 + knobs 构造 + try。任务 4 实装 C++ 主体后；本接入
# 点立即生效。骨架期 C++ 返回 elapsed_ms = -1 → 自动 fallback 到 GDScript。
func _validate_weather_distribute_signature(ext: RefCounted) -> bool:
	if ext == null:
		return false
	if not ext.has_method("run_weather_distribute_pass"):
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_distribute_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_distribute_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_debug dev_build=no -j8'." % args.size())
			return false
	return false

func _validate_weather_summary_signature(ext: RefCounted) -> bool:
	if ext == null:
		return false
	if not ext.has_method("run_weather_summary_fronts_pass"):
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_summary_fronts_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_summary_fronts_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_debug dev_build=no -j8'." % args.size())
			return false
	return false

func _build_weather_distribute_knobs(map: MapData, n_cells: int) -> Dictionary:
	# 标量入参（snow / flood 阈值与 GDScript 版严格同源；任务 4 在 C++ 内消费）。
	# SoA view 由 C++ 端通过 ext._map_data + 已绑定 schema 直接拿，无需 GDScript
	# 显式传 PackedArray（与 F.1 一致）。
	#
	# 例外（无 SoA 镜像的 AoS 字段）：
	#   - accumulated_snow_days：HexCell.int 字段，没在 component_schema 里。
	#   - pre_snow_cover：HexCell.int 字段，同上。
	# 这两个字段每帧打包成 PackedInt32Array 传入；C++ 写完后通过 CoW alias 透回。
	#
	# WeatherType / LandformType 静态查询：profile lookup 是 Resource access，
	# C++ 拿不到。打包成 8-element PackedArray 按 WT 索引，C++ 内部 O(1) 查表。
	var map_id: int = map.get_instance_id()
	if _dist_cache_map_id != map_id or _dist_cache_n != n_cells \
			or _dist_acc_snow_cache.size() != n_cells or _dist_pre_cover_cache.size() != n_cells:
		var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		_dist_acc_snow_cache = PackedInt32Array()
		_dist_pre_cover_cache = PackedInt32Array()
		_dist_acc_snow_cache.resize(n_cells)
		_dist_pre_cover_cache.resize(n_cells)
		for i in range(n_cells):
			var c: HexCell = cells[i]
			_dist_acc_snow_cache[i] = c.accumulated_snow_days
			_dist_pre_cover_cache[i] = c.pre_snow_cover
		_dist_cache_map_id = map_id
		_dist_cache_n = n_cells
	# 8 个 WT 的 profile 静态值（temp_delta / moisture_delta / can_form_snow /
	# can_form_flood）按 WT 索引。WT 枚举值 0..7（CLEAR..MONSOON）。
	var temp_d: PackedFloat32Array = PackedFloat32Array()
	var moist_d: PackedFloat32Array = PackedFloat32Array()
	var cfs: PackedByteArray = PackedByteArray()
	var cff: PackedByteArray = PackedByteArray()
	temp_d.resize(8)
	moist_d.resize(8)
	cfs.resize(8)
	cff.resize(8)
	for w in range(8):
		temp_d[w] = WeatherType.temp_delta(w)
		moist_d[w] = WeatherType.moisture_delta(w)
		cfs[w] = 1 if WeatherType.can_form_snow(w) else 0
		cff[w] = 1 if WeatherType.can_form_flood(w) else 0
	# ─── Phase A.3 fast path：从 KnobsHandle 拿 distribute 段缓存 Dict ──
	if _knobs_handle != null and _knobs_handle.has_method("to_distribute_knobs_dict"):
		# 标量段与 LUT 由 _push_resident_knobs_from_cp 在 changed signal 时已推送；
		# 这里仅 merge 动态字段（n_cells / SoA AoS cache）。
		var dynamic_fields_dist: Dictionary = {
			"n_cells": n_cells,
			"accumulated_snow_days": _dist_acc_snow_cache,
			"pre_snow_cover": _dist_pre_cover_cache,
			"snowpack_accum_gain": _snowpack_accum_gain,
			"snowpack_melt_temp_gain": _snowpack_melt_temp_gain,
			"snowpack_melt_sun_gain": _snowpack_melt_sun_gain,
			"snowpack_cover_low": _snowpack_cover_low,
			"snowpack_cover_full": _snowpack_cover_full,
			"weather_temp_anomaly_cap": _weather_temp_anomaly_cap,
			"snowline_temp_threshold": _snowline_temp_threshold,
			"snowline_band": _snowline_band,
		}
		return _merge_resident_knobs_with_dynamic(
			_knobs_handle.to_distribute_knobs_dict(), dynamic_fields_dist)
	return {
		"n_cells": n_cells,
		# _apply_snow_accumulation 用到的 cover/温度阈值（任务 4 中 C++ 复刻 GDScript
		# 同名函数；任意改动需保持双侧同步）。
		# 2026-05-18 雪线修正：GDScript 在 _apply_snow_accumulation 内做 elev 偏移；
		# C++ 端 run_weather_distribute_pass 已同步实现（gdext/src/world_ext.cpp，
		# SNOW_ELEV_NEUTRAL=0.30 / FREEZE_GAIN=0.20 / MELT_GAIN=0.30，常数硬编码不走 knobs）。
		# 若日后调参，需双侧同步修改。
		"snow_min_intensity": 0.001,
		"snow_freeze_t": SNOW_FREEZE_T,
		"snow_melt_t": SNOW_MELT_T,
		"snow_intensity_for_snowing": 0.4,
		"snow_accum_days_req": _snow_accum_days_req,
		"flood_heavy_intensity": 0.55,
		"flood_heavy_precip": 0.55,
		"flood_lowland_intensity": 0.32,
		"flood_lowland_elev": 0.50,
		"flood_lowland_moisture": 0.60,
		"snowpack_accum_gain": _snowpack_accum_gain,
		"snowpack_melt_temp_gain": _snowpack_melt_temp_gain,
		"snowpack_melt_sun_gain": _snowpack_melt_sun_gain,
		"snowpack_cover_low": _snowpack_cover_low,
		"snowpack_cover_full": _snowpack_cover_full,
		"weather_temp_anomaly_cap": _weather_temp_anomaly_cap,
		"snowline_temp_threshold": _snowline_temp_threshold,
		"snowline_band": _snowline_band,
		# WT.CLEAR / SNOW / NONE / FLOODING 的 enum 值。GDScript 端用 Type.WT
		# / Type.CV，C++ 不能直接引用，所以把数值传进去。
		"wt_clear": int(WeatherType.WT.CLEAR),
		"cv_snow": int(CoverType.CV.SNOW),
		"cv_none": int(CoverType.CV.NONE),
		"cv_flooding": int(CoverType.CV.FLOODING),
		# AoS 字段 PackedArray（CoW shared via Dictionary 持有）。C++ 直接 ptrw 写回，
		# GDScript 在 try 函数末尾用同样的 Packed 引用 lookup 写回 AoS。
		"accumulated_snow_days": _dist_acc_snow_cache,
		"pre_snow_cover": _dist_pre_cover_cache,
		# WeatherType 静态查询表（PackedArray 按 WT 索引，C++ 内部 O(1)）。
		"temp_delta_arr": temp_d,
		"moisture_delta_arr": moist_d,
		"can_form_snow_arr": cfs,
		"can_form_flood_arr": cff,
	}

# 调用 C++ 端 run_weather_distribute_pass。返回 Dictionary {"elapsed_ms", "cover_dirty",
# "changed_cells"(PackedInt32Array), "accumulated_snow_days"/"pre_snow_cover"(已被 C++ 改写)}。
# elapsed_ms < 0 表示 precondition 失败，调用方走 GDScript fallback。
func _try_run_weather_distribute_gdext(map: MapData, n_cells: int) -> Dictionary:
	if _data_core_world_ext == null:
		return { "elapsed_ms": -1.0, "cover_dirty": false }
	var knobs: Dictionary = _build_weather_distribute_knobs(map, n_cells)
	var rc_dict: Dictionary = _data_core_world_ext.run_weather_distribute_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0:
		_sync_weather_distribute_cache_to_cells(map, n_cells)
		if not _gdext_dist_warned_fallback:
			_gdext_dist_warned_fallback = true
			push_warning("[weather] gdext run_weather_distribute_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
		return rc_dict
	# C++ 已通过 PackedArray ptrw 把 acc_snow_days / pre_snow_cover 改写完成（CoW
	# alias 透传）。fast path 以 PackedArray 为连续状态源，不再每 tick 全量写回
	# HexCell；只有 cover 真正变化的 cell 需要同步 current_state。verify/fallback
	# 路径仍会全量同步，保证调试和降级语义一致。
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var acc_after: PackedInt32Array = knobs.get("accumulated_snow_days", PackedInt32Array())
	var pre_after: PackedInt32Array = knobs.get("pre_snow_cover", PackedInt32Array())
	var changed: PackedInt32Array = rc_dict.get("changed_cells", PackedInt32Array())
	if _distribute_verify_enabled:
		_sync_weather_distribute_cache_to_cells(map, n_cells)
	else:
		for ci in changed:
			if ci < 0 or ci >= cells.size():
				continue
			var cc: HexCell = cells[ci]
			if acc_after.size() == n_cells and pre_after.size() == n_cells:
				cc.accumulated_snow_days = acc_after[ci]
				cc.pre_snow_cover = pre_after[ci]
			# C++ 已经写好 cover_arr (SoA)；HexCell facade reader cell.cover 应当透读 SoA。
			# 但 current_state["cover"] 是 dict 字段，需手动同步。
			cc.current_state["cover"] = int(cc.cover)
	return rc_dict

func _sync_weather_distribute_cache_to_cells(map: MapData, n_cells: int) -> void:
	if map == null:
		return
	if _dist_acc_snow_cache.size() != n_cells or _dist_pre_cover_cache.size() != n_cells:
		return
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var limit: int = mini(n_cells, cells.size())
	for i in range(limit):
		var c: HexCell = cells[i]
		c.accumulated_snow_days = _dist_acc_snow_cache[i]
		c.pre_snow_cover = _dist_pre_cover_cache[i]
		c.current_state["cover"] = int(c.cover)

# ─── Weather Hot-Path：summary fronts pass GDExt 接入（任务 6）────────────
# C++ pass 要求的 SoA + 静态查表数据由 _build_weather_summary_knobs 一次构造。
# 输出：Dictionary{ elapsed_ms: float, fronts: Array[Dictionary] }；GDScript 端
# 把 Array[Dictionary] 解包为 Array[WeatherFront]（与原 _build_field_summary_fronts
# 的返回签名严格一致），让 field_solver 调用方完全无感。
# elapsed_ms < 0 → fallback 到 GDScript（push_warning 一次）。
func _build_weather_summary_knobs(map: MapData, world: WorldData) -> Dictionary:
	var n_cells: int = map.cell_count()
	var map_id: int = map.get_instance_id()
	if _summary_cache_map_id != map_id or _summary_cache_n != n_cells \
			or _summary_q_cache.size() != n_cells or _summary_r_cache.size() != n_cells:
		var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
		_summary_q_cache = PackedInt32Array()
		_summary_r_cache = PackedInt32Array()
		_summary_q_cache.resize(n_cells)
		_summary_r_cache.resize(n_cells)
		for i in range(n_cells):
			var c: HexCell = cells[i]
			_summary_q_cache[i] = c.q
			_summary_r_cache[i] = c.r
		_summary_cache_map_id = map_id
		_summary_cache_n = n_cells
	# wind_x / wind_y 已是 SoA（map.wind_x_arr / wind_y_arr）；C++ 通过 _slots
	# 直接读，不必通过 knobs 传。
	var water_ids: PackedByteArray = PackedByteArray([
		int(TerrainType.TERRAIN.OCEAN) & 0xFF,
		int(TerrainType.TERRAIN.COAST) & 0xFF,
		int(TerrainType.TERRAIN.LAKE) & 0xFF,
		int(TerrainType.TERRAIN.REEF) & 0xFF,
		int(TerrainType.TERRAIN.KELP) & 0xFF,
		int(TerrainType.TERRAIN.SEA_ICE) & 0xFF,
	])
	# ─── Phase A.3 fast path：从 KnobsHandle 拿 summary 段缓存 Dict ──
	if _knobs_handle != null and _knobs_handle.has_method("to_summary_knobs_dict"):
		# day_counter 每帧变化 → 走单字段细粒度入口（无变化时不拉 dirty）
		if _knobs_handle.has_method("set_day_counter"):
			_knobs_handle.set_day_counter(_day_counter)
		var dynamic_fields_sum: Dictionary = {
			"n_cells": n_cells,
			"hex_size": _hex_size,
			"cell_q_arr": _summary_q_cache,
			"cell_r_arr": _summary_r_cache,
			"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
			"cyclone_storm_type_id": int(WeatherType.WT.STORM),
			"water_terrain_ids": water_ids,
		}
		return _merge_resident_knobs_with_dynamic(
			_knobs_handle.to_summary_knobs_dict(), dynamic_fields_sum)
	return {
		"n_cells": n_cells,
		"hex_size": _hex_size,
		"summary_limit": _field_summary_limit,
		# 阈值（与 _build_field_summary_fronts 内 const 严格同源）
		"intensity_enter": 0.10,
		"intensity_hold": 0.06,
		# 合并相关
		"merge_ratio": 0.65,
		"merge_max_rounds": 4,
		# WeatherFront radius 公式： size*(1.6 + sqrt(area)*1.05)；
		# merge 距离阈值用的"等效半径"公式：size*sqrt(area)*1.05。
		"radius_base": 1.6,
		"radius_scale": 1.05,
		# WT 枚举常量（C++ 不直读 GDScript Resource，传过来用整型即可）
		"wt_clear": int(WeatherType.WT.CLEAR),
		"cyclone_storm_type_id": int(WeatherType.WT.STORM),
		"water_terrain_ids": water_ids,
		# Q/R 拓扑（C++ 端用于 cube_to_world / world_to_cube 反查）
		"cell_q_arr": _summary_q_cache,
		"cell_r_arr": _summary_r_cache,
		# 邻居索引（n_cells*6，-1 表无邻居；C++ 端 BFS / pick_inheritance_seed 必需）
		"neighbor_indices": map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array(),
		# Drift 调试日志（C++ 路径下默认关闭，verify mode 不影响日志）
		"drift_debug_log": false,
		"day_counter": _day_counter,
	}

# 把 C++ 端返回的 fronts Dictionary 解包为 WeatherFront 实例。字段命名必须与
# C++ 端 build_front_dict 保持 1:1，任何缺字段就退化到 WeatherFront 默认值。
func _unpack_summary_dict_to_front(d: Dictionary) -> WeatherFront:
	var f := WeatherFront.new()
	f.type = int(d.get("type", WeatherType.WT.CLEAR))
	f.center = d.get("center", Vector2.ZERO)
	f.intensity = clampf(float(d.get("intensity", 0.0)), 0.0, 1.0)
	f.radius = float(d.get("radius", 200.0))
	var ax: Vector2 = d.get("axis", Vector2.RIGHT)
	if ax.length_squared() <= 0.0001:
		ax = Vector2.RIGHT
	f.axis = ax.normalized()
	f.stable_axis = d.get("stable_axis", f.axis)
	f.velocity = d.get("velocity", Vector2.ZERO)
	f.major_scale = float(d.get("major_scale", 1.30))
	f.minor_scale = float(d.get("minor_scale", 0.85))
	f.age_days = int(d.get("age_days", 0))
	f.ttl_days = int(d.get("ttl_days", 12))
	f.decay_per_day = float(d.get("decay_per_day", 0.0))
	f.life_progress = clampf(float(d.get("life_progress", 0.15)), 0.0, 1.0)
	f.cloud_amount = clampf(float(d.get("cloud_amount", 0.0)), 0.0, 1.0)
	f.precip_amount = clampf(float(d.get("precip_amount", 0.0)), 0.0, 1.0)
	f.dissolve_amount = float(d.get("dissolve_amount", 0.0))
	f.edge_seed = float(d.get("edge_seed", 0.0))
	f.front_temperature_advection = float(d.get("front_temperature_advection", 0.0))
	f.front_diagnostic_kind = int(d.get("front_diagnostic_kind", WeatherFront.FRONT_DIAG_NONE))
	return f

# ─── Phase A.1（dots-total-cpp roadmap）：fronts zero-copy SoA 解包 ─────
# 从 C++ 端 run_weather_summary_fronts_pass 返回的 out["fronts_soa"]: Dict
# 中读取 23 个 PackedArray 列（命名严格沿用 fronts_schema.gd FRONTS_SCHEMA
# cpp_name），按 idx 1:1 构造 WeatherFront 实例数组。
#
# 与 _unpack_summary_dict_to_front 等价但 marshalling 大幅减负：
#   - 旧路径：每 front N=12 个 → 跨语言 ~17*12 = 204 个 Variant entry
#   - SoA 路径：固定 ~24 个 PackedArray 引用（与 N 无关）
#
# 容错策略：任意必需列缺失或 size 不匹配 → 返回 null 触发 caller fallback
# 到旧 dict 路径（保证向前兼容 stale .dll）。
func _unpack_summary_soa_to_fronts(soa: Dictionary) -> Variant:
	var n: int = int(soa.get("n_fronts", -1))
	if n < 0:
		return null
	if n == 0:
		return [] as Array[WeatherFront]
	var center_x: PackedFloat32Array = soa.get("front_center_x", PackedFloat32Array())
	var center_y: PackedFloat32Array = soa.get("front_center_y", PackedFloat32Array())
	var radius_arr: PackedFloat32Array = soa.get("front_radius", PackedFloat32Array())
	var velocity_x: PackedFloat32Array = soa.get("front_velocity_x", PackedFloat32Array())
	var velocity_y: PackedFloat32Array = soa.get("front_velocity_y", PackedFloat32Array())
	var axis_x: PackedFloat32Array = soa.get("front_axis_x", PackedFloat32Array())
	var axis_y: PackedFloat32Array = soa.get("front_axis_y", PackedFloat32Array())
	var stable_axis_x: PackedFloat32Array = soa.get("front_stable_axis_x", PackedFloat32Array())
	var stable_axis_y: PackedFloat32Array = soa.get("front_stable_axis_y", PackedFloat32Array())
	var major_scale_arr: PackedFloat32Array = soa.get("front_major_scale", PackedFloat32Array())
	var minor_scale_arr: PackedFloat32Array = soa.get("front_minor_scale", PackedFloat32Array())
	var edge_seed_arr: PackedFloat32Array = soa.get("front_edge_seed", PackedFloat32Array())
	var intensity_arr: PackedFloat32Array = soa.get("front_intensity", PackedFloat32Array())
	var decay_arr: PackedFloat32Array = soa.get("front_decay_per_day", PackedFloat32Array())
	var life_arr: PackedFloat32Array = soa.get("front_life_progress", PackedFloat32Array())
	var cloud_arr: PackedFloat32Array = soa.get("front_cloud_amount", PackedFloat32Array())
	var precip_arr: PackedFloat32Array = soa.get("front_precip_amount", PackedFloat32Array())
	var dissolve_arr: PackedFloat32Array = soa.get("front_dissolve_amount", PackedFloat32Array())
	var type_arr: PackedInt32Array = soa.get("front_type", PackedInt32Array())
	var ttl_arr: PackedInt32Array = soa.get("front_ttl_days", PackedInt32Array())
	var age_arr: PackedInt32Array = soa.get("front_age_days", PackedInt32Array())
	var temp_adv_arr: PackedFloat32Array = soa.get("front_temperature_advection", PackedFloat32Array())
	var diag_kind_arr: PackedInt32Array = soa.get("front_diagnostic_kind", PackedInt32Array())
	# 必需列长度全检查（任一不匹配立即放弃，让 caller 走 dict fallback）
	if center_x.size() != n or center_y.size() != n: return null
	if radius_arr.size() != n: return null
	if velocity_x.size() != n or velocity_y.size() != n: return null
	if axis_x.size() != n or axis_y.size() != n: return null
	if stable_axis_x.size() != n or stable_axis_y.size() != n: return null
	if major_scale_arr.size() != n or minor_scale_arr.size() != n: return null
	if edge_seed_arr.size() != n: return null
	if intensity_arr.size() != n: return null
	if decay_arr.size() != n: return null
	if life_arr.size() != n: return null
	if cloud_arr.size() != n or precip_arr.size() != n: return null
	if dissolve_arr.size() != n: return null
	if type_arr.size() != n or ttl_arr.size() != n or age_arr.size() != n: return null

	var out: Array[WeatherFront] = [] as Array[WeatherFront]
	out.resize(n)
	for i in range(n):
		var f := WeatherFront.new()
		f.type = type_arr[i]
		f.center = Vector2(center_x[i], center_y[i])
		f.intensity = clampf(intensity_arr[i], 0.0, 1.0)
		f.radius = radius_arr[i]
		# axis 归一化与 dict 路径等价（C++ 端已经 normalize 但 GDScript fallback 也照同样语义守护）
		var ax := Vector2(axis_x[i], axis_y[i])
		if ax.length_squared() <= 0.0001:
			ax = Vector2.RIGHT
		f.axis = ax.normalized()
		var sax := Vector2(stable_axis_x[i], stable_axis_y[i])
		if sax.length_squared() <= 0.0001:
			sax = f.axis
		f.stable_axis = sax
		f.velocity = Vector2(velocity_x[i], velocity_y[i])
		f.major_scale = major_scale_arr[i]
		f.minor_scale = minor_scale_arr[i]
		f.age_days = age_arr[i]
		f.ttl_days = ttl_arr[i]
		f.decay_per_day = decay_arr[i]
		f.life_progress = clampf(life_arr[i], 0.0, 1.0)
		f.cloud_amount = clampf(cloud_arr[i], 0.0, 1.0)
		f.precip_amount = clampf(precip_arr[i], 0.0, 1.0)
		f.dissolve_amount = dissolve_arr[i]
		f.edge_seed = edge_seed_arr[i]
		if temp_adv_arr.size() == n:
			f.front_temperature_advection = temp_adv_arr[i]
		if diag_kind_arr.size() == n:
			f.front_diagnostic_kind = diag_kind_arr[i]
		out[i] = f
	return out


func _front_diagnostic_kind(temp_advection: float) -> int:
	const FRONT_TEMP_ADVECTION_THRESHOLD: float = 0.015
	if temp_advection > FRONT_TEMP_ADVECTION_THRESHOLD:
		return WeatherFront.FRONT_DIAG_COLD
	if temp_advection < -FRONT_TEMP_ADVECTION_THRESHOLD:
		return WeatherFront.FRONT_DIAG_WARM
	return WeatherFront.FRONT_DIAG_NONE


func _front_diagnostic_counts(fronts: Array) -> Dictionary:
	var cold_count: int = 0
	var warm_count: int = 0
	for front in fronts:
		if front == null:
			continue
		match int(front.front_diagnostic_kind):
			WeatherFront.FRONT_DIAG_COLD:
				cold_count += 1
			WeatherFront.FRONT_DIAG_WARM:
				warm_count += 1
	return {
		"weather_cold_front_count": cold_count,
		"weather_warm_front_count": warm_count,
	}

# ─── Phase A.1 helper：把 C++ 返回值优先走 SoA 路径，缺失 / flag off 时
# fallback 到 Array[Dict] 路径。集中在一个 helper 里供 summary 与 combined
# 两处复用，避免重复 dispatch 逻辑分叉。
func _build_fronts_from_rc(rc_dict: Dictionary) -> Array[WeatherFront]:
	# dots-flag-prune-pr1 round 2: use_gdext_fronts_soa flag 已删除——恒走 SoA 探测路径，
	# rc_dict.fronts_soa 存在时列扫描构造 WeatherFront，缺失时 fallback 到 Array[Dict]。
	if rc_dict.has("fronts_soa"):
		var soa: Dictionary = rc_dict["fronts_soa"]
		# Phase B Z-lock 实测遥测：editor-only 包夹 unpack 调用，100 样本 ring 满 print。
		var _telemetry_on: bool = OS.has_feature("editor")
		var _t0_us: int = Time.get_ticks_usec() if _telemetry_on else 0
		var soa_out: Variant = _unpack_summary_soa_to_fronts(soa)
		if _telemetry_on:
			var _dt_us: int = Time.get_ticks_usec() - _t0_us
			if _fronts_soa_unpack_us_ring.size() < _FRONTS_SOA_TELEMETRY_WINDOW:
				_fronts_soa_unpack_us_ring.resize(_FRONTS_SOA_TELEMETRY_WINDOW)
			_fronts_soa_unpack_us_ring[_fronts_soa_unpack_window_idx] = _dt_us
			_fronts_soa_unpack_window_idx = (_fronts_soa_unpack_window_idx + 1) % _FRONTS_SOA_TELEMETRY_WINDOW
			_fronts_soa_unpack_window_count += 1
			if _fronts_soa_unpack_window_count >= _FRONTS_SOA_TELEMETRY_WINDOW:
				# 窗口满：计算 p50/p95/mean，print 后归零再采（持续观测，便于跨阶段对比）
				var _samples: PackedInt32Array = _fronts_soa_unpack_us_ring.duplicate()
				_samples.sort()
				var _w: int = _samples.size()
				var _p50: int = _samples[_w / 2]
				var _p95: int = _samples[int(float(_w) * 0.95)]
				var _sum: int = 0
				for _v in _samples:
					_sum += int(_v)
				var _mean: float = float(_sum) / float(_w)
				print("[weather/summary] fronts_soa unpack telemetry — n=%d mean=%.1fμs p50=%dμs p95=%dμs (Z-lock threshold: p95<100μs)" % [_w, _mean, _p50, _p95])
				_fronts_soa_unpack_window_count = 0
				_fronts_soa_unpack_window_idx = 0
		if soa_out != null:
			if not _fronts_soa_path_logged:
				_fronts_soa_path_logged = true
				print("[weather/summary] fronts_soa path ACTIVE — first run n=%d (PackedArray columns, marshalling ~90%% slim vs Array[Dict])" % int(soa.get("n_fronts", 0)))
			return soa_out as Array[WeatherFront]
		else:
			if not _fronts_soa_warned_fallback:
				_fronts_soa_warned_fallback = true
				push_warning("[weather/summary] fronts_soa columns missing/invalid; falling back to Array[Dict] path (will retry next tick)")
	# Fallback: 走旧 Array[Dict] 路径
	var fronts_arr: Array = rc_dict.get("fronts", [])
	var out: Array[WeatherFront] = [] as Array[WeatherFront]
	for d in fronts_arr:
		out.append(_unpack_summary_dict_to_front(d))
	return out

# ─── Phase A.3（dots-total-cpp roadmap）：KnobsHandle dirty-write helper ─
# 把 ClimateProfile + weather_system 自身 _field_* 持久旋钮一次性推送到
# KnobsHandle 的所有段。caller：configure_gdext_acceleration 首次装配 + 后续
# ClimateProfile.changed 信号触发（信号 cb 会再调一次本函数）。
#
# 注意：动态 PackedArray ref（_field_slice_* / _summary_q_cache / map.* SoA /
# neighbor_indices）不在这里推送 —— 它们每帧由 caller 在 _build_*_knobs
# 外层 merge 进 to_*_knobs_dict() 输出（保留每帧 ref 替换语义）。
func _sync_profile_weather_knobs(cp: Resource) -> void:
	if cp == null:
		return
	if cp.get("weather_field_enabled") != null:
		_weather_field_enabled = bool(cp.weather_field_enabled)
	if cp.get("weather_field_advect_steps") != null:
		_field_advect_steps = clampi(int(cp.weather_field_advect_steps), 0, 8)  # 方案③ 上限 4→8
	if cp.get("weather_field_diffusion") != null:
		_field_diffusion = clampf(float(cp.weather_field_diffusion), 0.0, 0.5)
	if cp.get("weather_condensation_gain") != null:
		_field_condensation_gain = maxf(0.0, float(cp.weather_condensation_gain))
	if cp.get("weather_precip_decay") != null:
		_field_precip_decay = clampf(float(cp.weather_precip_decay), 0.0, 1.0)
	if cp.get("weather_orographic_lift_gain") != null:
		_field_orographic_lift_gain = maxf(0.0, float(cp.weather_orographic_lift_gain))
	if cp.get("weather_convergence_gain") != null:
		_field_convergence_gain = maxf(0.0, float(cp.weather_convergence_gain))
	if cp.get("weather_ocean_evap_gain") != null:
		_field_ocean_evap_gain = maxf(0.0, float(cp.weather_ocean_evap_gain))
	if cp.get("weather_land_evapotranspiration_gain") != null:
		_field_land_evapotranspiration_gain = maxf(0.0, float(cp.weather_land_evapotranspiration_gain))
	if cp.get("weather_precip_rh_threshold") != null:
		_field_precip_rh_threshold = clampf(float(cp.weather_precip_rh_threshold), 0.40, 0.95)
	if cp.get("weather_ocean_precip_suppression") != null:
		_field_ocean_precip_suppression = clampf(float(cp.weather_ocean_precip_suppression), 0.0, 1.0)
	if cp.get("weather_frontogenesis_gain") != null:
		_field_frontogenesis_gain = maxf(0.0, float(cp.weather_frontogenesis_gain))
	if cp.get("weather_rain_shadow_drying") != null:
		_field_rain_shadow_drying = clampf(float(cp.weather_rain_shadow_drying), 0.0, 1.0)
	if cp.get("weather_vapor_transport_gain") != null:
		_field_vapor_transport_gain = clampf(float(cp.weather_vapor_transport_gain), 0.0, 1.0)
	if cp.get("weather_component_summary_limit") != null:
		_field_summary_limit = clampi(int(cp.weather_component_summary_limit), 1, 12)
	if cp.get("weather_convergence_refresh_stride") != null:
		_field_convergence_refresh_stride = clampi(int(cp.weather_convergence_refresh_stride), 1, 12)
	if cp.get("weather_precip_carryover_max") != null:
		_field_precip_carryover_max = clampf(float(cp.weather_precip_carryover_max), 0.0, 1.0)
	if cp.get("weather_vapor_precip_sink") != null:
		_field_vapor_precip_sink = clampf(float(cp.weather_vapor_precip_sink), 0.0, 1.0)
	if cp.get("weather_precip_inertia") != null:
		_field_precip_inertia = clampf(float(cp.weather_precip_inertia), 0.05, 1.0)
	if cp.get("weather_field_precip_base_frac") != null:
		_field_precip_base_frac = clampf(float(cp.weather_field_precip_base_frac), 0.0, 1.0)
	if cp.get("weather_field_cloud_reevap") != null:
		_field_cloud_reevap = clampf(float(cp.weather_field_cloud_reevap), 0.0, 0.5)
	if cp.get("snowpack_accum_gain") != null:
		_snowpack_accum_gain = clampf(float(cp.snowpack_accum_gain), 0.0, 1.0)
	if cp.get("snowpack_melt_temp_gain") != null:
		_snowpack_melt_temp_gain = clampf(float(cp.snowpack_melt_temp_gain), 0.0, 1.0)
	if cp.get("snowpack_melt_sun_gain") != null:
		_snowpack_melt_sun_gain = clampf(float(cp.snowpack_melt_sun_gain), 0.0, 1.0)
	if cp.get("snowpack_cover_low") != null:
		_snowpack_cover_low = clampf(float(cp.snowpack_cover_low), 0.0, 0.5)
	if cp.get("snowpack_cover_full") != null:
		_snowpack_cover_full = maxf(_snowpack_cover_low + 0.001, clampf(float(cp.snowpack_cover_full), 0.0, 1.0))
	if cp.get("snow_accum_days_req") != null:
		_snow_accum_days_req = clampi(int(cp.snow_accum_days_req), 1, 8)
	if cp.get("weather_temp_anomaly_cap") != null:
		_weather_temp_anomaly_cap = clampf(float(cp.weather_temp_anomaly_cap), 0.0, 0.10)
	if cp.get("snowline_temp_threshold") != null:
		_snowline_temp_threshold = clampf(float(cp.snowline_temp_threshold), 0.0, 1.0)
	if cp.get("snowline_band") != null:
		_snowline_band = clampf(float(cp.snowline_band), 0.02, 0.6)
	if cp.get("weather_vapor_relax_rate") != null:
		_field_vapor_relax_rate = clampf(float(cp.weather_vapor_relax_rate), 0.0, 1.0)
	if cp.get("weather_orographic_lift_cap") != null:
		_field_orographic_lift_cap = clampf(float(cp.weather_orographic_lift_cap), 0.0, 1.0)
	if cp.get("weather_wet_terrain_precip_damping") != null:
		_field_wet_terrain_precip_damping = clampf(float(cp.weather_wet_terrain_precip_damping), 0.0, 1.0)
	if cp.get("weather_lake_precip_damping") != null:
		_field_lake_precip_damping = clampf(float(cp.weather_lake_precip_damping), 0.0, 1.0)
	if cp.get("weather_lake_evap_scale") != null:
		_field_lake_evap_scale = clampf(float(cp.weather_lake_evap_scale), 0.0, 1.0)
	if cp.get("weather_extreme_precip_soft_cap") != null:
		_field_extreme_precip_soft_cap = clampf(float(cp.weather_extreme_precip_soft_cap), 0.0, 1.0)
	if cp.get("weather_extreme_precip_softness") != null:
		_field_extreme_precip_softness = clampf(float(cp.weather_extreme_precip_softness), 0.0, 1.0)
	if cp.get("weather_cold_precip_as_blizzard") != null:
		_cold_precip_as_blizzard = bool(cp.weather_cold_precip_as_blizzard)
	if cp.get("weather_snow_classification_margin") != null:
		_snow_classification_margin = clampf(float(cp.weather_snow_classification_margin), 0.0, 0.12)


func _push_resident_knobs_from_cp(cp: Resource) -> void:
	if _knobs_handle == null or cp == null:
		return
	_sync_profile_weather_knobs(cp)

	# ─── field 段标量 ──
	if _knobs_handle.has_method("set_field_scalars"):
		_knobs_handle.set_field_scalars(
			_world_bounds.position.y,
			_world_bounds.size.y,
			not _field_verify_enabled,  # apply_convergence_boost = (not verify_mode)
			_hex_size,
			_field_advect_steps,
			_field_diffusion,
			_field_condensation_gain,
			_field_orographic_lift_gain,
			_field_convergence_gain,
			_field_ocean_evap_gain,
			_field_precip_decay,
			_season_phase,
		)
	var field_extra_scalars_available: bool = _knobs_handle.has_method("set_field_precip_stability_scalars")
	if field_extra_scalars_available:
		_knobs_handle.set_field_precip_stability_scalars(
			_field_precip_carryover_max,
			_field_vapor_precip_sink,
			_field_vapor_relax_rate,
			_field_orographic_lift_cap,
			_field_wet_terrain_precip_damping,
			_field_lake_precip_damping,
			_field_lake_evap_scale,
			_field_extreme_precip_soft_cap,
			_field_extreme_precip_softness,
		)

	# ─── distribute 段标量（snow/flood 阈值与 _build_weather_distribute_knobs 严格同源）──
	if _knobs_handle.has_method("set_distribute_scalars"):
		_knobs_handle.set_distribute_scalars(
			0.001,    # snow_min_intensity
			SNOW_FREEZE_T,
			SNOW_MELT_T,
			0.4,      # snow_intensity_for_snowing
			_snow_accum_days_req,
			0.55,     # flood_heavy_intensity
			0.55,     # flood_heavy_precip
			0.32,     # flood_lowland_intensity
			0.50,     # flood_lowland_elev
			0.60,     # flood_lowland_moisture
			int(WeatherType.WT.CLEAR),
			int(CoverType.CV.SNOW),
			int(CoverType.CV.NONE),
			int(CoverType.CV.FLOODING),
		)
	# distribute WT LUT（8-长度）—— 每次重建（cp.WeatherType 静态表理论上不会变，
	# 但 push 全路径覆盖一次更稳）
	if _knobs_handle.has_method("set_distribute_wt_tables"):
		var temp_d: PackedFloat32Array = PackedFloat32Array()
		var moist_d: PackedFloat32Array = PackedFloat32Array()
		var cfs: PackedByteArray = PackedByteArray()
		var cff: PackedByteArray = PackedByteArray()
		temp_d.resize(8)
		moist_d.resize(8)
		cfs.resize(8)
		cff.resize(8)
		for w in range(8):
			temp_d[w] = WeatherType.temp_delta(w)
			moist_d[w] = WeatherType.moisture_delta(w)
			cfs[w] = 1 if WeatherType.can_form_snow(w) else 0
			cff[w] = 1 if WeatherType.can_form_flood(w) else 0
		_knobs_handle.set_distribute_wt_tables(temp_d, moist_d, cfs, cff)

	# ─── summary 段标量 ──
	if _knobs_handle.has_method("set_summary_scalars"):
		_knobs_handle.set_summary_scalars(
			_field_summary_limit,
			0.10,   # intensity_enter
			0.06,   # intensity_hold
			0.65,   # merge_ratio
			4,      # merge_max_rounds
			1.6,    # radius_base
			1.05,   # radius_scale
			false,  # drift_debug_log
			_day_counter,
		)


# ClimateProfile.changed 信号回调：段级 invalidate + 重新推送。
# cp 通过 .bind(cp) 透传到这里（Resource.changed 信号自身不带 sender 参数）。
func _on_climate_profile_changed_for_knobs(cp: Resource) -> void:
	if _knobs_handle == null:
		return
	if _knobs_handle.has_method("invalidate_all"):
		_knobs_handle.invalidate_all()
	_push_resident_knobs_from_cp(cp)


# 把 to_*_knobs_dict 缓存 Dict 与每帧动态字段（PackedArray ref / cache）合并。
# 用于 _build_weather_field_knobs / _build_weather_distribute_knobs /
# _build_weather_summary_knobs 三个 hot path 的 fast path。
#
# 实现要点：to_*_knobs_dict 返回的 Dict 是缓存 Dict 的 CoW 引用，duplicate(false)
# 浅拷贝出一份后 merge 动态字段（不污染缓存 Dict）。duplicate(false) 在 standard
# Godot Dictionary 是 O(N_keys)，N≤30 标量段约 0.01ms 量级，比标量段重建省一个量级。
func _merge_resident_knobs_with_dynamic(base_dict: Dictionary, dynamic_fields: Dictionary) -> Dictionary:
	if base_dict.is_empty():
		# KnobsHandle 拿不到缓存（首次或 invalidate 后），caller 应已 fallback 旧路径
		return dynamic_fields
	var out: Dictionary = base_dict.duplicate(false)
	for k in dynamic_fields:
		out[k] = dynamic_fields[k]
	if not _knobs_handle_first_use_logged:
		_knobs_handle_first_use_logged = true
		var fr: int = -1
		if _knobs_handle != null and _knobs_handle.has_method("get_field_rebuild_count"):
			fr = int(_knobs_handle.get_field_rebuild_count())
		print("[weather/knobs] resident KnobsHandle path ACTIVE — first to_*_knobs_dict hit (field_rebuild_count=%d expected ≤1; stable Hz target ≤1 Hz)" % fr)
	return out

# 调用 C++ pass。返回 Variant：
#   Array[WeatherFront]  → 成功（替换原 _build_field_summary_fronts 的输出）
#   null                 → 失败（GDScript fallback）
# 同时把 elapsed_ms / runs / fallbacks 累计到节流告警状态。
func _try_run_weather_summary_fronts_gdext(map: MapData, world: WorldData) -> Variant:
	if _data_core_world_ext == null:
		return null
	var knobs: Dictionary = _build_weather_summary_knobs(map, world)
	var rc_dict: Dictionary = _data_core_world_ext.run_weather_summary_fronts_pass(knobs)
	var rc: float = float(rc_dict.get("elapsed_ms", -1.0))
	if rc < 0.0:
		_gdext_summary_fallbacks += 1
		if not _gdext_summary_warned_fallback:
			_gdext_summary_warned_fallback = true
			push_warning("[weather/summary] gdext run_weather_summary_fronts_pass returned %.2f; falling back to GDScript for this tick (will retry next tick)" % rc)
		return null
	_gdext_summary_runs += 1
	_gdext_summary_total_ms += rc
	if _gdext_summary_runs == 1:
		print("[weather/summary] gdext path ACTIVE — first run elapsed=%.2fms (legacy GDScript baseline ≈ 17.8ms; charter target < 3.0ms)" % rc)
	# Phase A.1: SoA 优先 + Dict fallback（旧 Array[Dict] 路径仍兼容 stale .dll）
	return _build_fronts_from_rc(rc_dict)

# ─── plan/weather-refresh-cpp-all PR-2 facade ─────────────────────────────
# 单 cpp call 跑完 weather refresh daily 全套（field_solve + distribute +
# summary_fronts + cyclone_wake + stage_b 五段），消除 GDScript ↔ C++ 之间
# 5 次 marshal。返回值：
#   { ok: bool, fronts: Array[WeatherFront], breakdown: Dictionary, fail_stage: String }
# ok=false 时 caller 必须走 GDScript fallback（refresh_daily_stage_a +
# refresh_daily_stage_b）。fail_stage 用于诊断（"precondition" / "field_solve" /
# "distribute" / "summary" / "stage_b" / "rc"）。
#
# 前置条件：
#   - _data_core_world_ext 已绑定且 has_method("run_weather_refresh_daily_pass")
#   - 由 map_generator.refresh_weather_daily() 间接保证
#
# 副作用（成功路径）：
#   - 推进 _day_counter / _field_solve_tick（等价于 tick_one_day 的 day-bump）
#   - 写入 SoA 8 字段（cpp 端 field_solve 直写）
#   - 写入 _active_fronts = fronts_cpp（替代 commit() 末段）
#   - 同步 ocean_current_perturbation（cpp 端 cyclone_wake 维护）
#   - 写入 _last_breakdown（advance/distribute/summary/cyclone/stage_b 子段 ms）
#   - distribute 写回的 acc_snow / pre_snow_cover 由 caller 在拿到 fronts 后
#     按需同步（与 _try_run_weather_distribute_gdext 行为一致）；本函数不
#     做 cell-level 反向写入，避免重复 hot loop。
func try_run_refresh_daily_combined_gdext(map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float = -1.0,
		stage_b_knobs: Dictionary = {}) -> Dictionary:
	var ret: Dictionary = {
		"ok": false,
		"fronts": [] as Array[WeatherFront],
		"breakdown": {},
		"fail_stage": "precondition",
	}
	if _data_core_world_ext == null:
		return ret
	if not _data_core_world_ext.has_method("run_weather_refresh_daily_pass"):
		return ret
	if map == null or world == null:
		return ret
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return ret

	var t_us0: int = Time.get_ticks_usec()

	# Step 1：初始化 field slice state（替代 tick_one_day 入口的 day-bump +
	# wind_fn 设置；count_day=true，与 tick_one_day 语义一致）。
	_current_map_for_tick = map
	begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase, true)
	# fast-indexed 是 cpp 5 段的硬前置条件（field_solve / distribute /
	# summary / feedback 都要 neighbor_indices_packed 完整）。任意一段缺失
	# 立即放弃，让 caller 走 GDScript fallback 而不是付出半 cpp 半 GDScript 代价。
	if not _field_solver._field_slice_fast_indexed:
		_clear_weather_field_slice_state()
		ret["fail_stage"] = "fast_indexed_missing"
		return ret

	# Step 2：合并 4 组 knobs。各 builder 已存在且严格按 cpp 端 5 段所需 key
	# 集合产出。super-knobs 用 merge() 合到一个 Dictionary 单次跨界传递。
	# stage_b 的 knobs 由 generator 提供（builder 在 generator 那边，
	# weather_system 拿不到 cp/lut；caller 必须传入）。
	var super_knobs: Dictionary = _build_weather_field_knobs(map, world, n_cells)
	var dist_knobs: Dictionary = _build_weather_distribute_knobs(map, n_cells)
	for k in dist_knobs.keys():
		super_knobs[k] = dist_knobs[k]
	var summary_knobs: Dictionary = _build_weather_summary_knobs(map, world)
	for k in summary_knobs.keys():
		super_knobs[k] = summary_knobs[k]
	# stage_b 的 5 段 knobs 由 caller（map_generator.refresh_weather_daily facade）
	# 通过 stage_b_knobs 参数注入——builder 在 generator 那边（依赖 cp/lut），
	# weather_system 拿不到。如果 caller 传空 dict（例如还在试运行阶段），那么
	# cpp 端会跳过 stage_b 段（stage_b_pass 内部检查 run_albedo/veg_dyn/feedback
	# 三个 flag 全 false 时直接 return rc=0），这是允许的过渡状态。
	# 注意：把 stage_b_knobs 的所有 key 平铺到 super_knobs 顶层，与 cpp 端
	# run_weather_refresh_daily_pass 解 stage_b 段时按 top-level key 取值的约定一致。
	if not stage_b_knobs.is_empty():
		for k in stage_b_knobs.keys():
			# 不允许 stage_b key 覆盖 weather field/distribute/summary 已写好的同名
			# key（例如 n_cells / neighbor_indices）——后者是真值，stage_b 端的
			# n_cells / neighbor_indices 与 weather 段必然一致，但为安全起见
			# 用 has() 做防御。
			if not super_knobs.has(k):
				super_knobs[k] = stage_b_knobs[k]

	# Step 3：单次 cpp call。
	var rc_dict: Dictionary = _data_core_world_ext.run_weather_refresh_daily_pass(super_knobs)
	var rc_int: int = int(rc_dict.get("rc", -1))
	if rc_int != 0:
		# cpp 端任一段失败 → 清理 slice state，让 caller 走 GDScript fallback。
		_clear_weather_field_slice_state()
		ret["fail_stage"] = String(rc_dict.get("fail_stage", "rc"))
		ret["breakdown"] = {
			"total_ms": float(rc_dict.get("total_ms", 0.0)),
		}
		if not _gdext_combined_warned_fallback:
			_gdext_combined_warned_fallback = true
			push_warning("[weather/combined] run_weather_refresh_daily_pass rc=%d fail_stage=%s; falling back to GDScript chain" % [rc_int, ret["fail_stage"]])
		return ret

	# Step 4：解包 fronts，写 _active_fronts（替代 commit() summary 段 +
	# tick_one_day 末端 _active_fronts 写入）。
	# Phase A.1: SoA 优先 + Dict fallback（与 _try_run_weather_summary_fronts_gdext
	# 共享 _build_fronts_from_rc helper，single source of truth）。
	var fronts_out: Array[WeatherFront] = _build_fronts_from_rc(rc_dict)
	_active_fronts = fronts_out

	# Step 5：cover_dirty 同步（distribute 段输出）。
	_cover_dirty = bool(rc_dict.get("cover_dirty", false)) or _cover_dirty

	# Step 6：cyclone_wake 镜像（cpp 端维护 _cyclone_perturbations 内部
	# vector，GDScript 端 ocean_current_perturbation 用于航运 AI 直读）。
	if _data_core_world_ext.has_method("get_cyclone_perturbations_dict"):
		var cyclone_mirror: Dictionary = _data_core_world_ext.get_cyclone_perturbations_dict()
		# 替换式同步而非 merge：cpp 是 source of truth（已经做了衰减 + 注入）。
		ocean_current_perturbation = cyclone_mirror

	# Step 7：清理 slice state（cpp 已直写 SoA，_field_slice_* buffer 不再需要）。
	_clear_weather_field_slice_state()
	_current_map_for_tick = null

	# Step 8：拼装 _last_breakdown（与 GDScript path 字段集合保持一致）。
	var combined_total_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	var br: Dictionary = {
		"advance_ms": float(rc_dict.get("advance_ms", 0.0)),
		"distribute_ms": float(rc_dict.get("distribute_ms", 0.0)),
		"summary_ms": float(rc_dict.get("summary_ms", 0.0)),
		"cyclone_ms": float(rc_dict.get("cyclone_ms", 0.0)),
		# Phase B.2 cyclone 细粒度遥测（C++ cyclone_wake_step by-ref 写回 6 字段
		# + caller 写回 cyclone_pool_size，map_generator._dump_weather_breakdown_if_slow
		# 触发时立即定位是衰减循环 vs 注入循环、是大量 evict vs 大量 replace）
		"cyclone_phase1_decay_ms": float(rc_dict.get("cyclone_phase1_decay_ms", 0.0)),
		"cyclone_phase2_inject_ms": float(rc_dict.get("cyclone_phase2_inject_ms", 0.0)),
		"cyclone_n_decayed": int(rc_dict.get("cyclone_n_decayed", 0)),
		"cyclone_n_evicted": int(rc_dict.get("cyclone_n_evicted", 0)),
		"cyclone_n_replaced": int(rc_dict.get("cyclone_n_replaced", 0)),
		"cyclone_n_injected": int(rc_dict.get("cyclone_n_injected", 0)),
		"cyclone_pool_size": int(rc_dict.get("cyclone_pool_size", 0)),
		"stage_b_ms": float(rc_dict.get("stage_b_ms", 0.0)),
		"albedo_ms": float(rc_dict.get("albedo_ms", 0.0)),
		"veg_dyn_ms": float(rc_dict.get("veg_dyn_ms", 0.0)),
		"feedback_ms": float(rc_dict.get("feedback_ms", 0.0)),
		"weather_tick_ms": float(rc_dict.get("weather_tick_ms", combined_total_ms)),
		"total_ms": combined_total_ms,
		"fronts": fronts_out.size(),
		"path": "gdext_combined",
	}
	br.merge(_front_diagnostic_counts(fronts_out), true)
	# stage_b succession 写回（与 _build_native_daily_stage_b_knobs 等价）
	if rc_dict.has("succession_indices"):
		br["succession_indices"] = rc_dict["succession_indices"]
		br["succession_to_veg"] = rc_dict["succession_to_veg"]
		br["stat_succession_count"] = int(rc_dict.get("stat_succession_count", 0))
	br.merge(_mark_weather_commit_tick(), true)
	_last_breakdown = br

	# 节流告警（仅首次）：标记 gdext_combined ACTIVE。
	_gdext_combined_runs += 1
	_gdext_combined_total_ms += combined_total_ms
	if _gdext_combined_runs == 1:
		print("[weather/combined] gdext path ACTIVE — first run elapsed=%.2fms (target ≤ 1.5ms; legacy stage_a+stage_b chain ≈ 1.0-1.2ms baseline + 3 marshal overhead)" % combined_total_ms)

	ret["ok"] = true
	ret["fronts"] = fronts_out
	ret["breakdown"] = br
	ret["fail_stage"] = ""
	return ret


# ─── Phase A.2 unified fast tick：weather_knobs 嵌入 native_daily_bundle ─────
# 当 native_daily_sim_mode=ACTIVE 时（unified_fast_tick 路径现恒走），由
# map_generator._build_native_daily_bundle 调用本 helper 构造平铺 weather super_knobs，
# 由 run_native_daily_tick 内部的 bundle["weather_knobs"] 分支自动转调
# run_weather_refresh_daily_pass，省去 weather_refresh_job 独立的一次跨界。
#
# 与 try_run_refresh_daily_combined_gdext step 1-2 同源逻辑（field_slice state
# 初始化 + 3 组 weather knobs builder + 顶层平铺 stage_b knobs）。失败时返回
# 空 dict，caller 据此跳过 weather_knobs 嵌入退回 stage_b-only bundle。
#
# 副作用（成功路径）：
#   - 推进 _day_counter（与 tick_one_day 语义一致，count_day=true）
#   - 初始化 _field_solver._field_slice_* state（_field_slice_fast_indexed 必须为 true）
#   - 设置 _current_map_for_tick = map
# 这些状态会在 apply_unified_fast_tick_result 内被 _clear_weather_field_slice_state 清理。
func build_unified_fast_tick_weather_knobs(map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float, season_phase: float,
		stage_b_knobs: Dictionary) -> Dictionary:
	if _data_core_world_ext == null:
		return {}
	if not _data_core_world_ext.has_method("run_weather_refresh_daily_pass"):
		return {}
	if map == null or world == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}

	# Step 1：初始化 field slice state（与 try_run_refresh_daily_combined_gdext line 1361 同源）。
	_current_map_for_tick = map
	begin_weather_field_solve(map, world, season_idx, climate_anomaly, season_phase, true)
	if not _field_solver._field_slice_fast_indexed:
		# fast-indexed 是 cpp 5 段的硬前置；缺失 → 清理 + 让 caller fallback 不嵌入 weather_knobs。
		_clear_weather_field_slice_state()
		_current_map_for_tick = null
		return {}

	# Step 2：合并 4 组 knobs（与 line 1374-1395 同源）。
	var super_knobs: Dictionary = _build_weather_field_knobs(map, world, n_cells)
	var dist_knobs: Dictionary = _build_weather_distribute_knobs(map, n_cells)
	for k in dist_knobs.keys():
		super_knobs[k] = dist_knobs[k]
	var summary_knobs: Dictionary = _build_weather_summary_knobs(map, world)
	for k in summary_knobs.keys():
		super_knobs[k] = summary_knobs[k]
	if not stage_b_knobs.is_empty():
		for k in stage_b_knobs.keys():
			if not super_knobs.has(k):
				super_knobs[k] = stage_b_knobs[k]
	return super_knobs


# 与 try_run_refresh_daily_combined_gdext step 4-8 同源：从 native_daily 返回的
# breakdown 字典里取 weather 段子字典（C++ 端 run_native_daily_tick 把 weather
# 段产出 copy_dict_into 进顶层 breakdown），解 fronts、同步 _active_fronts、
# cyclone mirror、cover_dirty，清理 slice state。
#
# 入参 weather_rc：bundle.weather_knobs 触发的 run_weather_refresh_daily_pass
# 返回 dict，由 native_daily breakdown 透传上来。
#
# 返回 fronts_out：与 try_run_refresh_daily_combined_gdext 一致的 Array[WeatherFront]，
# 由 caller（map_generator）写入 _last_active_fronts / _weather_round_fronts。
func apply_unified_fast_tick_result(weather_rc: Dictionary) -> Array[WeatherFront]:
	if _data_core_world_ext == null:
		_clear_weather_field_slice_state()
		_current_map_for_tick = null
		return [] as Array[WeatherFront]

	# Step 4：解包 fronts，写 _active_fronts。
	var fronts_out: Array[WeatherFront] = _build_fronts_from_rc(weather_rc)
	_active_fronts = fronts_out

	# Step 5：cover_dirty 同步。
	_cover_dirty = bool(weather_rc.get("cover_dirty", false)) or _cover_dirty

	# Step 6：cyclone_wake 镜像。
	if _data_core_world_ext.has_method("get_cyclone_perturbations_dict"):
		var cyclone_mirror: Dictionary = _data_core_world_ext.get_cyclone_perturbations_dict()
		ocean_current_perturbation = cyclone_mirror

	# Step 7：清理 slice state。
	_clear_weather_field_slice_state()
	_current_map_for_tick = null

	# Step 8：runs/total_ms 统计（与 combined path 共享计数器）。
	_gdext_combined_runs += 1
	_gdext_combined_total_ms += float(weather_rc.get("total_ms", 0.0))
	var br: Dictionary = weather_rc.duplicate(true)
	br.merge(_front_diagnostic_counts(fronts_out), true)
	br.merge(_mark_weather_commit_tick(), true)
	_last_breakdown = br
	return fronts_out


# C++ 完成后 SoA 已经写好，把 8 个数组的内容按 i 拷回 _field_solver._field_slice_next_*
# 让 commit_weather_field_solve() 用同样的 GDScript 数据流 commit 回 cells +
# fronts 等下游 sub-system，无需感知 C++ 路径的存在。
func _pull_gdext_field_results_to_next(map: MapData, n_cells: int) -> void:
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_cloud_water: PackedFloat32Array = map.weather_cloud_water_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_inst: PackedFloat32Array = map.weather_instability_arr
	var soa_intens: PackedFloat32Array = map.weather_intensity_arr
	var soa_conv: PackedFloat32Array = map.weather_convergence_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	for i in range(n_cells):
		_field_solver._field_slice_next_vapor[i] = soa_vapor[i]
		_field_solver._field_slice_next_cloud[i] = soa_cloud[i]
		if soa_cloud_water.size() == n_cells:
			_field_solver._field_slice_next_cloud_water[i] = soa_cloud_water[i]
		_field_solver._field_slice_next_precip[i] = soa_precip[i]
		_field_solver._field_slice_next_instability[i] = soa_inst[i]
		_field_solver._field_slice_next_intensity[i] = soa_intens[i]
		_field_solver._field_slice_next_convergence[i] = soa_conv[i]
		_field_solver._field_slice_next_type[i] = int(soa_type[i])

# ─── F.1 A/B 运行时验证 ───────────────────────────────────────────────────
# 触发：set_field_verify_mode(true) 之后每次 C++ 路径成功 commit 前进入。
# 步骤：
#   1. 把 C++ 已写好的 8 个 SoA 字段快照成独立 PackedArray（CoW 复制；不影响
#      _field_solver._field_slice_next_* 已经持有的同一 SoA 引用）。
#   2. 把 SoA 反向回滚到本 tick 入口的 prev 状态（vapor/precip 用 prev_*；
#      其余字段在 commit 之前不被本 pass 内部读，所以无需精确还原）。
#   3. 把 GDScript 的 _field_solver._field_slice_next_* 拷成另一组独立缓冲，再用 GDScript
#      slice loop 重新写一遍——但这会污染 _field_solver._field_slice_next_*，所以我们先用
#      临时 var 备份再恢复。
#   4. 对照 8 个字段逐 cell 比 abs(cpp - gdscript)，首次超过 tol 时打日志并
#      记录 "_field_verify_first_divergence_logged = true"，避免 spam。
#
# 实现策略：直接调用 _solve_weather_field_internal_loop_for_verify(...) 把
# slice 主循环做成独立函数，避免在 verify 路径里复制 600 行算法。
func _verify_gdext_field_against_gdscript(map: MapData, world: WorldData, n_cells: int) -> void:
	# C++ 结果快照（dup() 保证 CoW，不和 SoA 引用别名）
	var cpp_vapor: PackedFloat32Array = _field_solver._field_slice_next_vapor.duplicate()
	var cpp_cloud: PackedFloat32Array = _field_solver._field_slice_next_cloud.duplicate()
	var cpp_cloud_water: PackedFloat32Array = _field_solver._field_slice_next_cloud_water.duplicate()
	var cpp_precip: PackedFloat32Array = _field_solver._field_slice_next_precip.duplicate()
	var cpp_inst: PackedFloat32Array = _field_solver._field_slice_next_instability.duplicate()
	var cpp_intens: PackedFloat32Array = _field_solver._field_slice_next_intensity.duplicate()
	var cpp_conv: PackedFloat32Array = _field_solver._field_slice_next_convergence.duplicate()
	var cpp_type: PackedInt32Array = _field_solver._field_slice_next_type.duplicate()

	# 用 GDScript path 重写 _field_solver._field_slice_next_*。复用现有 slice 循环主体最干净
	# 的办法是：临时关掉 _use_gdext_weather_field、把 cursor reset 到 0、再调
	# 一次 run_weather_field_solve_slice 走 GDScript 分支。
	var saved_cursor: int = _field_solver._field_slice_cursor
	var saved_solve_ms: float = _field_solver._field_slice_solve_ms
	var saved_last_ms: float = _field_solver._field_slice_last_ms
	var saved_use_gdext: bool = _use_gdext_weather_field
	_use_gdext_weather_field = false
	_field_solver._field_slice_cursor = 0
	_field_solver.run_slice(2147483647)
	_field_solver._field_slice_cursor = saved_cursor
	_field_solver._field_slice_solve_ms = saved_solve_ms
	_field_solver._field_slice_last_ms = saved_last_ms
	_use_gdext_weather_field = saved_use_gdext

	# 此时 _field_solver._field_slice_next_* = GDScript 版结果。逐 cell 比较。
	var max_dvap: float = 0.0
	var max_dcld: float = 0.0
	var max_dcw: float = 0.0
	var max_dpre: float = 0.0
	var max_dins: float = 0.0
	var max_dint: float = 0.0
	var max_dcnv: float = 0.0
	var type_mismatches: int = 0
	var first_div_idx: int = -1
	var first_div_field: String = ""
	var first_div_cpp: float = 0.0
	var first_div_gd: float = 0.0
	for i in range(n_cells):
		var dvap: float = absf(cpp_vapor[i] - _field_solver._field_slice_next_vapor[i])
		var dcld: float = absf(cpp_cloud[i] - _field_solver._field_slice_next_cloud[i])
		var dcw: float = absf(cpp_cloud_water[i] - _field_solver._field_slice_next_cloud_water[i])
		var dpre: float = absf(cpp_precip[i] - _field_solver._field_slice_next_precip[i])
		var dins: float = absf(cpp_inst[i] - _field_solver._field_slice_next_instability[i])
		var dint: float = absf(cpp_intens[i] - _field_solver._field_slice_next_intensity[i])
		var dcnv: float = absf(cpp_conv[i] - _field_solver._field_slice_next_convergence[i])
		max_dvap = maxf(max_dvap, dvap)
		max_dcld = maxf(max_dcld, dcld)
		max_dcw = maxf(max_dcw, dcw)
		max_dpre = maxf(max_dpre, dpre)
		max_dins = maxf(max_dins, dins)
		max_dint = maxf(max_dint, dint)
		max_dcnv = maxf(max_dcnv, dcnv)
		if cpp_type[i] != _field_solver._field_slice_next_type[i]:
			type_mismatches += 1
		if first_div_idx < 0:
			if dvap > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "vapor"; first_div_cpp = cpp_vapor[i]; first_div_gd = _field_solver._field_slice_next_vapor[i]
			elif dcld > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "cloud"; first_div_cpp = cpp_cloud[i]; first_div_gd = _field_solver._field_slice_next_cloud[i]
			elif dcw > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "cloud_water"; first_div_cpp = cpp_cloud_water[i]; first_div_gd = _field_solver._field_slice_next_cloud_water[i]
			elif dpre > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "precip"; first_div_cpp = cpp_precip[i]; first_div_gd = _field_solver._field_slice_next_precip[i]
			elif dins > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "instability"; first_div_cpp = cpp_inst[i]; first_div_gd = _field_solver._field_slice_next_instability[i]
			elif dint > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "intensity"; first_div_cpp = cpp_intens[i]; first_div_gd = _field_solver._field_slice_next_intensity[i]
			elif dcnv > _field_verify_tol_f32:
				first_div_idx = i; first_div_field = "convergence"; first_div_cpp = cpp_conv[i]; first_div_gd = _field_solver._field_slice_next_convergence[i]

	# 把 _field_solver._field_slice_next_* 还原成 C++ 结果（commit 才能拿到 C++ 路径数据）。
	_field_solver._field_slice_next_vapor = cpp_vapor
	_field_solver._field_slice_next_cloud = cpp_cloud
	_field_solver._field_slice_next_cloud_water = cpp_cloud_water
	_field_solver._field_slice_next_precip = cpp_precip
	_field_solver._field_slice_next_instability = cpp_inst
	_field_solver._field_slice_next_intensity = cpp_intens
	_field_solver._field_slice_next_convergence = cpp_conv
	_field_solver._field_slice_next_type = cpp_type

	if first_div_idx >= 0 and not _field_verify_first_divergence_logged:
		_field_verify_first_divergence_logged = true
		push_warning("[weather/F.1 verify] FAIL — first divergence cell=%d field=%s cpp=%.6f gdscript=%.6f delta=%.2e (tol=%.1e). max abs deltas: vapor=%.2e cloud=%.2e cloud_water=%.2e precip=%.2e inst=%.2e intens=%.2e conv=%.2e type_mismatch=%d/%d" % [
			first_div_idx, first_div_field, first_div_cpp, first_div_gd, absf(first_div_cpp - first_div_gd), _field_verify_tol_f32,
			max_dvap, max_dcld, max_dcw, max_dpre, max_dins, max_dint, max_dcnv, type_mismatches, n_cells,
		])
	elif first_div_idx < 0:
		# 全 cell 通过——只在第一次通过时打一条 INFO，避免每 tick spam。
		if not _field_verify_first_divergence_logged:
			_field_verify_first_divergence_logged = true
			print("[weather/F.1 verify] PASS — all %d cells within tol (max abs deltas: vapor=%.2e cloud=%.2e cloud_water=%.2e precip=%.2e inst=%.2e intens=%.2e conv=%.2e type_mismatch=%d)" % [
				n_cells, max_dvap, max_dcld, max_dcw, max_dpre, max_dins, max_dint, max_dcnv, type_mismatches,
			])

func _clear_weather_field_slice_state() -> void:
	_field_solver._field_slice_active = false
	_field_solver._field_slice_map = null
	_field_solver._field_slice_world = null
	_field_solver._field_slice_season_idx = 0
	_field_solver._field_slice_climate_anomaly = 0.0
	_field_solver._field_slice_cursor = 0
	_field_solver._field_slice_refresh_convergence = false
	_field_solver._field_slice_fast_indexed = false
	_field_solver._field_slice_cells = []
	_field_solver._field_slice_cell_pos = PackedVector2Array()
	_field_solver._field_slice_neighbor_indices = PackedInt32Array()
	_field_solver._field_slice_prev_vapor = PackedFloat32Array()
	_field_solver._field_slice_prev_precip = PackedFloat32Array()
	_field_solver._field_slice_next_vapor = PackedFloat32Array()
	_field_solver._field_slice_next_cloud = PackedFloat32Array()
	_field_solver._field_slice_next_cloud_water = PackedFloat32Array()
	_field_solver._field_slice_next_precip = PackedFloat32Array()
	_field_solver._field_slice_next_instability = PackedFloat32Array()
	_field_solver._field_slice_next_intensity = PackedFloat32Array()
	_field_solver._field_slice_next_convergence = PackedFloat32Array()
	_field_solver._field_slice_next_type = PackedInt32Array()
	_field_solver._field_slice_solve_ms = 0.0
	_field_solver._field_slice_last_ms = 0.0
	_field_solver._field_slice_results_in_soa = false
	_field_solver._field_slice_native_convergence_boost = false
	_field_solver._field_slice_temp_anom = PackedFloat32Array()
	_field_solver._field_slice_wrap_width_x = 0.0
	_field_solver._field_slice_cell_pos_scale = 1.0
	_field_solver._field_slice_native_knobs.clear()

func _solve_weather_field(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> void:
	# dots-monolith-split §1.2 / PR-6：250 行 dead code 已删除；逻辑入口
	# 整体下沉到 scripts/weather/field_solver.gd::solve()，内部走
	# begin_slice → 循环 run_slice → commit。
	_field_solver.solve(map, world, season_idx, climate_anomaly)

func _apply_frontal_convergence_boost(map: MapData, cells: Array, climate_anomaly: float, neighbor_indices: PackedInt32Array, fast_indexed: bool) -> void:
	# 锋面温差阈值（temperature 归一化为 [0,1]，0.28 ≈ 14°C，0.06 ≈ 3°C）。
	# 修（v4）：v3 的 0.20/0.32 在中纬度风带几乎全境触发 → STORM 横贯地图。
	# 现在大幅收紧：温差需 14°C 以上、辐合需更强，才进入"真正的锋面带"。
	const STORM_TEMP_DIFF: float = 0.28
	const WEAK_TEMP_DIFF: float = 0.06
	const CONVERGENCE_THRESHOLD: float = 0.45
	# B-full Step-2：循环外一次性取 SoA 数组引用（与 view_f32 同引用）。
	# cell-level 字段全部走 PackedArray index 访问；只有 _avg_ocean_anomaly_at_idx
	# 内部读 temperature_transport_anomaly 仍走 AoS（不在本 plan 范围）。
	var soa_temp: PackedFloat32Array = map.temp_arr
	var soa_air_anomaly: PackedFloat32Array = map.air_mass_temp_anomaly_arr
	var soa_field_init: PackedByteArray = map.weather_field_init_arr
	var soa_convergence: PackedFloat32Array = map.weather_convergence_arr
	var soa_cloud: PackedFloat32Array = map.weather_cloud_arr
	var soa_precip: PackedFloat32Array = map.weather_precip_arr
	var soa_instability: PackedFloat32Array = map.weather_instability_arr
	var soa_vapor: PackedFloat32Array = map.weather_vapor_arr
	var soa_type: PackedByteArray = map.weather_type_arr
	var soa_intensity: PackedFloat32Array = map.weather_intensity_arr
	# PR-2.1.6（frontal convergence boost 写路径下移）：dirty 收集。
	var _fb_idx: PackedInt32Array = PackedInt32Array()
	var _fb_cloud: PackedFloat32Array = PackedFloat32Array()
	var _fb_precip: PackedFloat32Array = PackedFloat32Array()
	var _fb_inst: PackedFloat32Array = PackedFloat32Array()
	var _fb_intensity: PackedFloat32Array = PackedFloat32Array()
	var _fb_type: PackedByteArray = PackedByteArray()
	var _fb_w: int = 0

	for i in range(cells.size()):
		var cell: HexCell = cells[i]
		if soa_field_init[i] == 0:
			continue
		var conv: float = soa_convergence[i]
		if conv < CONVERGENCE_THRESHOLD:
			continue
		# 计算 cell 邻域的温差 max - min（含 cell 自身）。
		var t_self: float = clampf(soa_temp[i] + climate_anomaly + soa_air_anomaly[i], 0.0, 1.0)
		var t_min: float = t_self
		var t_max: float = t_self
		if fast_indexed:
			var base: int = i * 6
			for d in range(6):
				var nb_idx: int = neighbor_indices[base + d]
				if nb_idx < 0:
					continue
				var t_nb: float = clampf(soa_temp[nb_idx] + climate_anomaly + soa_air_anomaly[nb_idx], 0.0, 1.0)
				if t_nb < t_min:
					t_min = t_nb
				if t_nb > t_max:
					t_max = t_nb
		else:
			for nb: HexCell in _cell_neighbors(cell, map):
				if nb == null:
					continue
				var t_nb: float = clampf(nb.temperature + climate_anomaly + nb.air_mass_temp_anomaly, 0.0, 1.0)
				if t_nb < t_min:
					t_min = t_nb
				if t_nb > t_max:
					t_max = t_nb
		var temp_diff: float = t_max - t_min
		# frontal_score：辐合强度 × 温差强度（温差 0.20 时为 1.0）。
		var frontal_score: float = clampf(
			(conv - CONVERGENCE_THRESHOLD) / (1.0 - CONVERGENCE_THRESHOLD)
			* clampf(temp_diff / STORM_TEMP_DIFF, 0.0, 1.0),
			0.0, 1.0
		)
		if frontal_score < 0.45:
			continue
		# 修（v5）：boost 进一步弱化——只让锋面带"略多云"，不再硬推 precip / inst 过阈值
		# 让 STORM 等强对流完全由 _classify 的物理条件决定，不再被锋面后处理强制锁
		var cloud0: float = soa_cloud[i]
		var precip0: float = soa_precip[i]
		var inst0: float = soa_instability[i]
		var cloud1: float = clampf(maxf(cloud0, 0.25 + frontal_score * 0.20), 0.0, 1.0)
		var vapor1: float = soa_vapor[i]
		var frontal_precip_allowed: bool = vapor1 > 0.09
		var precip1: float = clampf(maxf(precip0, 0.05 + frontal_score * 0.12), 0.0, 1.0) if frontal_precip_allowed else precip0
		var inst1: float = clampf(maxf(inst0, 0.25 + frontal_score * 0.15), 0.0, 1.0)
		# AoS 镜像写回（兼容 renderer 在 round 内未 flush 时直读 HexCell 字段）
		cell.weather_cloud = cloud1
		cell.weather_precip = precip1
		cell.weather_instability = inst1
		# 修（v5）：彻底取消温差升级到 STORM/BLIZZARD 的锁定逻辑。
		# 锋面只做云的"轻推"，不再改 type。强对流完全交给 classify 物理条件判断。
		# 仅保留：温差极小时把残余 STORM/MONSOON 降级 RAIN（防止旧 STORM 持留）
		var wt0: int = int(soa_type[i])
		var new_wt: int = wt0
		if temp_diff < WEAK_TEMP_DIFF and (wt0 == WeatherType.WT.STORM or wt0 == WeatherType.WT.MONSOON):
			new_wt = WeatherType.WT.RAIN
		var ocean_an: float = _avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else _avg_ocean_anomaly_at(cell, map)
		if not _is_precip_weather_type(new_wt) and precip1 >= 0.040:
			new_wt = WeatherType.WT.RAIN
		if not _is_precip_weather_type(new_wt):
			precip1 = 0.0
		cell.weather_type = new_wt
		cell.weather_precip = precip1
		# 重算 intensity（沿用同套公式，确保下游可视化一致）。
		var new_intensity: float = _field_intensity_for_type(new_wt, t_self, vapor1, cloud1, precip1, inst1, ocean_an)
		cell.weather_intensity = new_intensity
		# B-full Step-2：SoA 镜像（与 view_f32 同引用）—— 所有被本 pass 修改的字段都写出
		soa_cloud[i] = cloud1
		soa_precip[i] = precip1
		soa_instability[i] = inst1
		soa_intensity[i] = new_intensity
		soa_type[i] = new_wt & 0xFF
		# PR-2.1.6：收集 dirty entry。
		_fb_idx.append(i)
		_fb_cloud.append(cloud1)
		_fb_precip.append(precip1)
		_fb_inst.append(inst1)
		_fb_intensity.append(new_intensity)
		_fb_type.append(new_wt & 0xFF)
		_fb_w += 1

	# PR-2.1.6（frontal convergence boost 写路径下移）：循环结束后批量提交到 DCWorld SoA。
	if _data_core_world != null and _fb_w > 0:
		var _cid_fbc: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_CLOUD)
		if _cid_fbc >= 0:
			_data_core_world.write_f32_indexed(_cid_fbc, _fb_idx, _fb_cloud)
		var _cid_fbp: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_PRECIP)
		if _cid_fbp >= 0:
			_data_core_world.write_f32_indexed(_cid_fbp, _fb_idx, _fb_precip)
		var _cid_fbi: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_INSTABILITY)
		if _cid_fbi >= 0:
			_data_core_world.write_f32_indexed(_cid_fbi, _fb_idx, _fb_inst)
		var _cid_fbI: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_INTENSITY)
		if _cid_fbI >= 0:
			_data_core_world.write_f32_indexed(_cid_fbI, _fb_idx, _fb_intensity)
		var _cid_fbt: int = _data_core_world.component_id(DCComponentIds.CELL_WEATHER_TYPE)
		if _cid_fbt >= 0:
			_data_core_world.write_u8_indexed(_cid_fbt, _fb_idx, _fb_type)
		# [DIAG mask_dirty=2400 排查 · 2026-05-20] 前 5 次 + 之后每 50 次打一次
		_diag_fb_commit_count += 1
		if _diag_fb_commit_count <= 5 or (_diag_fb_commit_count % 50) == 0:
			print("[DIAG weather_fb_commit] #%d wrote %d cells (cloud+precip+inst+intensity+type)" % [_diag_fb_commit_count, _fb_w])
# Phase 3c：积雪累积与融化（共享方法）
# ------------------------------------------------------------------------
# 目的：把"BLIZZARD/SNOW 一发生立刻 cover=SNOW"换成累积式累计 + 温升融化。
# 字段约定（hex_cell.gd 已新增）：
#   accumulated_snow_days: int  —— 当前连续可降雪天数，>=SNOW_ACCUM_DAYS 时落地为 SNOW
#   pre_snow_cover: int         —— 备份覆盖前的 cover；融化时恢复（-1 表示未备份）
# 写入策略：
#   1) 可降雪条件（can_form_snow 且 temp<冰点 且 intensity>0.4）→ accumulated_snow_days += 1
#   2) 否则若 temp 高于解冻阈值 → accumulated_snow_days -= 1（不再降雪即缓慢消融）
#   3) 累计达阈值且当前不是 SNOW → 备份原 cover，写 cover=SNOW
#   4) 累计回零且当前是 SNOW 且有备份 → 恢复 cover=pre_snow_cover
const SNOW_ACCUM_DAYS_REQ: int = 2      # legacy fallback；运行时由 ClimateProfile.snow_accum_days_req 覆盖。
const SNOW_FREEZE_T: float = 0.24       # 低于此温度才算"可降雪冷度"
const SNOW_MELT_T: float = 0.31         # 高于此温度开始消融，保持滞回防抖
# 涌现式分类门（2026-06-20 去季节化重写）：阈值由 tile_data_record_20260620_004323 实测标定。
# 不再有任何 season_idx 派生的开关——天气类型完全由瞬时物理场涌现。
const BLIZZARD_WIND_GATE: float = 1.0  # Stage2: 1.15→1.0(过渡带冷降水阈降，原 1.15>典型风速 1.04 把冷降水误判冷雨)。过渡带(FREEZE~MELT)冷降水仅当风速>此值才算"暴风雪"
const HEATWAVE_ANOM_GATE: float = 0.06   # Stage3 (2026-06-23): 0.0→0.06。热浪改为气象学定义=显著正温度距平(比常态明显偏暖)的暖事件。temp_anomaly_arr p90≈0.058，0.06 约取最暖 ~9%，配合 temp>0.55+precip<0.015 落在暖季少雨暖距平区

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

func _summer_snow_melt_bonus(heat_input: float, elevation: float) -> float:
	var sun: float = smoothstep(0.55, 0.90, clampf(heat_input, 0.0, 1.0))
	var high_elev: float = smoothstep(0.62, 0.95, clampf(elevation, 0.0, 1.0))
	return sun * (1.0 - high_elev * 0.60) * 0.045

func _snowline_floor_for_cell(temp_now: float, heat_input: float, elevation: float) -> float:
	if _snowline_temp_threshold <= 0.0:
		return 0.0
	var sun: float = smoothstep(0.45, 0.85, clampf(heat_input, 0.0, 1.0))
	var high_elev: float = smoothstep(0.60, 0.95, clampf(elevation, 0.0, 1.0))
	var summer_drop: float = sun * lerpf(0.14, 0.045, high_elev)
	var elev_bonus: float = clampf((elevation - SNOW_ELEV_NEUTRAL) * 0.10, 0.0, 0.08)
	var effective_threshold: float = _snowline_temp_threshold + elev_bonus - summer_drop
	var raw_floor: float = clampf((effective_threshold - temp_now) / maxf(_snowline_band, 0.001), 0.0, 1.0)
	# Stage4(2026-06-23): 雪线 floor 只为「深冻区」自动铺白；雪线边缘(floor 弱)交给 snowpack-from-snowfall，
	# 让降雪可见地先于积雪(修"雪盖先于降雪")。smoothstep(0.30,0.80) 截掉最弱的暖侧雪线 floor。镜像 world_ext.cpp。
	return smoothstep(0.30, 0.80, raw_floor)

func _apply_snow_accumulation(cell: HexCell, wt: int, temp_now: float, intensity: float) -> bool:
	# 返回 true 表示本调用改写了 cell.cover（caller 据此设置 _cover_dirty）。
	if LandformType.is_water(cell.landform) or _is_water_terrain(int(cell.terrain)):
		return false
	var changed: bool = false
	# 海拔偏移（雪线修正）：让高山即使 temp_now 较高也能积雪，平原相反。
	var elev_delta: float = cell.elevation - SNOW_ELEV_NEUTRAL
	var freeze_off: float = clampf(elev_delta * SNOW_ELEV_FREEZE_GAIN, -SNOW_ELEV_FREEZE_MAX_OFF, SNOW_ELEV_FREEZE_MAX_OFF)
	var melt_off: float = clampf(elev_delta * SNOW_ELEV_MELT_GAIN, -SNOW_ELEV_MELT_MAX_OFF, SNOW_ELEV_MELT_MAX_OFF)
	var freeze_t_local: float = SNOW_FREEZE_T + freeze_off
	var melt_t_local: float = SNOW_MELT_T + melt_off
	var snowing: bool = WeatherType.can_form_snow(wt) and temp_now < freeze_t_local and intensity > 0.4
	if snowing:
		cell.accumulated_snow_days += 1
	elif temp_now > melt_t_local:
		cell.accumulated_snow_days = max(0, cell.accumulated_snow_days - 1)
	# 升级：累积够了且当前还不是 SNOW → 备份并覆盖
	if cell.accumulated_snow_days >= _snow_accum_days_req and cell.cover != CoverType.CV.SNOW:
		cell.pre_snow_cover = int(cell.cover)
		cell.cover = CoverType.CV.SNOW
		cell.current_state["cover"] = int(cell.cover)
		changed = true
	# 融化：累积清零且当前是 SNOW → 恢复（无备份则置 NONE）
	elif cell.accumulated_snow_days <= 0 and cell.cover == CoverType.CV.SNOW:
		var restored: int = cell.pre_snow_cover if cell.pre_snow_cover >= 0 else int(CoverType.CV.NONE)
		cell.cover = restored
		cell.current_state["cover"] = int(cell.cover)
		cell.pre_snow_cover = -1
		changed = true
	return changed

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd；本端保留薄转发以兼容
# weather_system 内自我调用与外部 caller。实现入口见
# scripts/weather/field_solver.gd 的 region PR-1。
func _upstream_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary, wind_dir: Vector2) -> float:
	return _field_solver._upstream_vapor(cell, map, prev_vapor, wind_dir)

func _neighbor_average_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary) -> float:
	return _field_solver._neighbor_average_vapor(cell, map, prev_vapor)

func _prev_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	var idx: int = map.index_of(cell)
	if idx >= 0 and idx < prev_vapor.size():
		return prev_vapor[idx]
	return cell.weather_vapor if cell.weather_field_initialized else cell.moisture

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd（薄转发）。
func _upstream_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	return _field_solver._upstream_vapor_cached(cell, map, prev_vapor, wind_dir)

func _neighbor_average_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	return _field_solver._neighbor_average_vapor_cached(cell, map, prev_vapor)

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd（薄转发）。
func _neighbor_aligned_idx(idx: int, dir: Vector2, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> int:
	return _field_solver._neighbor_aligned_idx(idx, dir, cell_pos, neighbor_indices)

func _upstream_vapor_idx(idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	return _field_solver._upstream_vapor_idx(idx, cell_pos, neighbor_indices, prev_vapor, wind_dir)

func _upstream_vapor_idx_from_first(idx: int, first_upstream_idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	return _field_solver._upstream_vapor_idx_from_first(idx, first_upstream_idx, cell_pos, neighbor_indices, prev_vapor, wind_dir)

func _neighbor_average_vapor_idx(idx: int, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array) -> float:
	return _field_solver._neighbor_average_vapor_idx(idx, neighbor_indices, prev_vapor)

# dots-monolith-split §1.2 / PR-3：搬迁到 field_solver.gd（薄转发）。
func _avg_ocean_anomaly_at_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array) -> float:
	return _field_solver._avg_ocean_anomaly_at_idx(idx, cells, neighbor_indices)

func _evaporation_for_cell_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array, temp: float, moisture: float, ocean_an: float, on_water: bool) -> float:
	var cell: HexCell = cells[idx]
	var evap: float = 0.028 if on_water else 0.006
	if int(cell.terrain) == TerrainType.TERRAIN.LAKE:
		evap *= _field_lake_evap_scale
	evap += maxf(moisture - 0.45, 0.0) * 0.018
	evap += _vegetation_transpiration_factor(cell) * 0.012
	if not on_water:
		if cell.has_river:
			evap += 0.012
		var base: int = idx * 6
		for d in range(6):
			var nb_idx: int = neighbor_indices[base + d]
			if nb_idx < 0:
				continue
			var nb: HexCell = cells[nb_idx]
			if _is_water_terrain(int(nb.terrain)):
				evap += 0.018
				break
	var ocean_mul: float = clampf(1.0 + _field_ocean_evap_gain * ocean_an, 0.20, 1.80)
	var temp_mul: float = clampf(0.35 + temp * 1.05, 0.12, 1.35)
	return evap * ocean_mul * temp_mul

func _evaporation_for_cell(cell: HexCell, map: MapData, temp: float, moisture: float, ocean_an: float, on_water: bool) -> float:
	var evap: float = 0.028 if on_water else 0.006
	if int(cell.terrain) == TerrainType.TERRAIN.LAKE:
		evap *= _field_lake_evap_scale
	evap += maxf(moisture - 0.45, 0.0) * 0.018
	evap += _vegetation_transpiration_factor(cell) * 0.012
	if not on_water:
		# v9d：自身有河 → 给固定 +0.012（比"邻居有水"的 +0.018 略低，
		# 因为河只占 cell 面积一小部分）。这是叠加在 base 0.006 上，
		# 让河流穿过的陆地实际 evap 接近 0.018，介于陆地与海面之间。
		if cell.has_river:
			evap += 0.012
		for nb: HexCell in _cell_neighbors(cell, map):
			if nb != null and _is_water_terrain(int(nb.terrain)):
				evap += 0.018
				break
	var ocean_mul: float = clampf(1.0 + _field_ocean_evap_gain * ocean_an, 0.20, 1.80)
	var temp_mul: float = clampf(0.35 + temp * 1.05, 0.12, 1.35)
	return evap * ocean_mul * temp_mul

func _vegetation_transpiration_factor(cell: HexCell) -> float:
	var veg: int = int(cell.vegetation)
	if veg == VegetationType.VEG.NONE:
		return 0.0
	if veg == VegetationType.VEG.TROPICAL_RAINFOREST or veg == VegetationType.VEG.SWAMP or veg == VegetationType.VEG.MANGROVE:
		return 1.0
	if veg == VegetationType.VEG.TEMPERATE_DECIDUOUS or veg == VegetationType.VEG.TAIGA or veg == VegetationType.VEG.SUBTROPICAL_FOREST:
		return 0.65
	if veg == VegetationType.VEG.TEMPERATE_GRASSLAND or veg == VegetationType.VEG.SAVANNA or veg == VegetationType.VEG.MARSH:
		return 0.35
	return 0.18

# dots-monolith-split §1.2 / PR-2：搬迁到 field_solver.gd（薄转发）。
func _orographic_lift_for_cell(cell: HexCell, map: MapData, wind_dir: Vector2) -> float:
	return _field_solver._orographic_lift_for_cell(cell, map, wind_dir)

func _orographic_lift_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, wind_dir: Vector2) -> float:
	return _field_solver._orographic_lift_idx(idx, cells, cell_pos, neighbor_indices, wind_dir)

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
func _classify_field_weather_at(temp: float, vapor: float, cloud: float, cloud_water: float, precip: float, instability: float, ocean_an: float, wind_speed: float, temp_anom: float, monsoon_flux: float = 0.0, is_water: bool = false, snow_cover: float = 0.0) -> int:
	return _classify_field_weather_core(temp, vapor, cloud, cloud_water, precip, instability, ocean_an, wind_speed, temp_anom, monsoon_flux, is_water, snow_cover)

# 涌现判据（无 season_idx，阈值由 tile_data_record_20260620_004323 实测标定）：
#   temp 已含轴倾→季节的温度结构；temp_anom=该格温度距平(异常冷暖)；wind_speed=原始风速(暴风强度)。
# 判定顺序：冰雪/暴风雪 → 强暖海/强对流风暴 → 季风 → 普通降水 → 雾 → 热浪 → 旱灾 → 晴。
func _classify_field_weather_core(temp: float, vapor: float, cloud: float, cloud_water: float, precip: float, instability: float, ocean_an: float, wind_speed: float, temp_anom: float, monsoon_flux: float = 0.0, is_water: bool = false, snow_cover: float = 0.0) -> int:
	# 去纬度门(2026-06-20)：分类不再使用纬度，类型边界由温度/湿度等弯曲物理场涌现，避免沿纬线的直线条带。
	var warm: bool = temp > 0.55
	# Stage3(2026-06-23): 删除 hot(temp>0.64)——热浪重定义为温度距平事件，不再用绝对高温门。
	# advective 模型下陆地 vapor/cloud 量级仅海洋的 1/5~1/30(海洋是水汽源,陆地天然干)。湿润类阈值海陆
	# 独立标定:海洋保原值(海洋天气分布已合理);陆地按实测分位下调(陆 vapor p50=.034/p90=.086,cloud
	# p50=.021/p90=.078),否则陆地 STORM/MONSOON/FOG 被"打死"全归 CLEAR/DROUGHT(用户:内陆永旱)。
	var humid_gate: float = 0.28 if is_water else 0.09
	var mp_cloud_gate: float = 0.22 if is_water else 0.12
	var mp_vapor_gate: float = 0.28 if is_water else 0.09
	var monsoon_vapor: float = 0.40 if is_water else 0.14
	var monsoon_precip: float = 0.055 if is_water else 0.065
	var monsoon_cloud: float = 0.45 if is_water else 0.24
	var fog_vapor: float = 0.34 if is_water else 0.16
	var fog_cloud: float = 0.14 if is_water else 0.18
	var humid: bool = vapor > humid_gate
	var effective_cloud: float = maxf(cloud, cloud_water * 1.25)
	var precip_cloud_mass: float = maxf(cloud_water, precip * 0.70)
	# 降水判据回归单阈值(2026-06-20 根因重构)：precip 已是带时间惯性的 EMA 状态量(见 field_solver/
	# world_ext)，逐tick平滑由场层惯性提供，分类不再需要滞回/拖尾补丁。precip>0.030 或 中等降水+厚云
	# 高湿即算"有效降水"。
	var precip_gate: float = 0.032 if is_water else 0.040
	var weak_precip_gate: float = 0.022 if is_water else 0.030
	var meaningful_precip: bool = precip > precip_gate or (precip > weak_precip_gate and effective_cloud > mp_cloud_gate and precip_cloud_mass > mp_cloud_gate * 0.35 and vapor > mp_vapor_gate)

	# 1) 冰雪 / 暴风雪：极冷(temp≤FREEZE)+可观降水 → 直接暴雪（极地降水本就是冰雪）。
	#    过渡带(FREEZE~MELT)+降水 → 仅当大风(wind_speed>门)才算"暴风雪"，风弱则视为冷雨落到 RAIN。
	#    修前：整条过渡带冷降水无差别判暴雪 → 高纬湿润海洋一片白(实测海面 17%)。
	if _cold_precip_as_blizzard and meaningful_precip:
		if temp <= SNOW_FREEZE_T:
			return WeatherType.WT.BLIZZARD
		if not is_water and snow_cover >= 0.25 and temp < SNOW_MELT_T + _snow_classification_margin:
			return WeatherType.WT.BLIZZARD
		if temp < SNOW_MELT_T + _snow_classification_margin \
				and effective_cloud > 0.18 and vapor > 0.20 and precip > 0.04 \
				and wind_speed > BLIZZARD_WIND_GATE:
			return WeatherType.WT.BLIZZARD
	# 2) 强对流风暴：暖湿 + 高不稳定 + 强降水；暖洋异常核心强制成 STORM。
	#    去硬纬度门(原 lat_abs<0.70)——warm(temp>0.55) 已把 STORM 限制在暖区，类型边界改由弯曲的
	#    等温线决定，消除"沿纬线的数学直线天气带"(用户反馈的不科学条带)。实测 STORM inst p50≈0.65。
	# Stage6h: STORM 阈大幅提高(雷暴应是少数强对流)。原 instability>0.50 被 47% 的 RAIN 格满足→STORM≈RAIN 数量、
	# 且与 RAIN 在 0.50 阈两侧逐 tick 横跳。提到 0.70(RAIN p90=0.76→仅最强对流入选)+ precip 0.05→0.065。
	var warm_ocean_core: bool = is_water and ocean_an > 0.05 and instability > 0.64 and precip > 0.060 and effective_cloud > 0.24 and precip_cloud_mass > 0.045
	if warm and humid and ((instability > 0.70 and precip > 0.065 and precip_cloud_mass > 0.050) or warm_ocean_core):
		return WeatherType.WT.STORM
	# 3) 季风：暖 + 季风湿通量/大尺度高湿 + 持续降水 + 厚云。暖海强对流核心先归 STORM，
	#    季风保留给沿岸/上岸的持续雨带，避免台风种子被 MONSOON 抢占。
	var monsoon_driver: float = maxf(monsoon_flux, smoothstep(monsoon_vapor * 0.78, monsoon_vapor + 0.06, vapor) * 0.24)
	var sustained_precip: bool = precip > monsoon_precip * 0.82 and precip_cloud_mass > monsoon_cloud * 0.38
	var monsoon_flux_gate: float = 0.08 if is_water else 0.13
	var inland_monsoon_plume: bool = (not is_water) and vapor > 0.24 and wind_speed > 0.75 and precip > monsoon_precip and precip_cloud_mass > monsoon_cloud * 0.45
	var monsoon_flow_gate: bool = monsoon_driver > monsoon_flux_gate or inland_monsoon_plume
	if warm and sustained_precip and effective_cloud > monsoon_cloud * 0.82 and monsoon_flow_gate:
		return WeatherType.WT.MONSOON
	# 4) 普通降水（含被降级的过渡带冷雨）。
	if meaningful_precip:
		return WeatherType.WT.RAIN
	# 5) 雾：高湿低降水、偏凉。单阈 cloud>0.14（FOG 闪烁由 EMA 平滑后的 cloud/precip 场自然消除）。
	if vapor > fog_vapor and effective_cloud > fog_cloud and precip < 0.030 and temp < 0.55:
		return WeatherType.WT.FOG
	# 6) 旱灾(2026-06-22 定义，Stage3 提到热浪之前)：暖 + 异常偏暖(temp_anom>0.10) + 几乎无降水 + 少云。
	#    bone-dry 强暖距平先归旱灾；剩余的暖距平少雨格落到下面的热浪。
	if (not is_water) and temp > 0.55 and temp_anom > 0.10 and precip < 0.006 and effective_cloud < 0.18:
		return WeatherType.WT.DROUGHT
	# 7) 热浪(Stage3→Stage5 重定义 2026-06-23)：实测 target_type=6 在运行期恒为 0——分类器运行期收到的
	#    temp_anom 与录制 temp_anomaly_arr 不一致(疑似写入时序/climate_anomaly 冷偏)，使"绝对热"或"正距平"
	#    两条路都打不到暖格。改用 STORM/MONSOON 同款已验证可达的 warm(temp>0.55) + 晴(effective_cloud<0.24)
	#    + 干(vapor<0.12) + 少雨。语义=暖季晴干热天(副热带下沉/大陆内部)。注意:本判据可达但速率需用新录制标定。
	if (not is_water) and warm and precip < 0.012 and effective_cloud < 0.24 and vapor < 0.12:
		return WeatherType.WT.HEATWAVE
	return WeatherType.WT.CLEAR


func _is_precip_weather_type(wt: int) -> bool:
	return wt == WeatherType.WT.RAIN \
		or wt == WeatherType.WT.STORM \
		or wt == WeatherType.WT.BLIZZARD \
		or wt == WeatherType.WT.MONSOON


func _weather_precip_terrain_damping_factor(terrain: int) -> float:
	# Stage8 (2026-06-23) 用户:雨团绕着湖/山/盆地走、湿润地形不下雨。原设定把恰恰最该多雨的地形(雨林/
	# 地形抬升坡/湿地)的降水压低——方向反了。JUNGLE/HILL 应多雨故归 0；湿地仅轻微阻尼防过湿。镜像 world_ext.cpp。
	match terrain:
		TerrainType.TERRAIN.LAKE:
			return 0.50
		TerrainType.TERRAIN.DELTA:
			return 0.40
		TerrainType.TERRAIN.SWAMP:
			return 0.30
		TerrainType.TERRAIN.JUNGLE:
			return 0.0
		TerrainType.TERRAIN.HILL:
			return 0.0
		_:
			return 0.0


func _moderate_field_precip_for_terrain(terrain: int, precip: float) -> float:
	var out: float = clampf(precip, 0.0, 1.0)
	var factor: float = _weather_precip_terrain_damping_factor(terrain)
	if factor > 0.0 and out > 0.08:
		var damp: float = _field_lake_precip_damping if terrain == TerrainType.TERRAIN.LAKE else _field_wet_terrain_precip_damping
		out -= (out - 0.08) * clampf(damp, 0.0, 1.0) * factor
	var cap: float = clampf(_field_extreme_precip_soft_cap, 0.0, 1.0)
	if cap > 0.0 and out > cap:
		out = cap + (out - cap) * clampf(_field_extreme_precip_softness, 0.0, 1.0)
	return clampf(out, 0.0, 1.0)


func _field_intensity_for_type(wt: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> float:
	match wt:
		WeatherType.WT.STORM:
			return clampf(maxf(precip, instability) * 0.82 + cloud * 0.18, 0.0, 1.0)
		WeatherType.WT.MONSOON:
			return clampf(precip * 0.72 + vapor * 0.18 + cloud * 0.18, 0.0, 1.0)
		WeatherType.WT.RAIN, WeatherType.WT.BLIZZARD:
			return clampf(precip * 1.15 + cloud * 0.20, 0.0, 1.0)
		WeatherType.WT.FOG:
			return clampf(cloud * 0.75 + vapor * 0.20, 0.0, 1.0)
		WeatherType.WT.HEATWAVE:
			return clampf((temp - 0.65) * 2.2 + maxf(0.32 - vapor, 0.0), 0.0, 1.0)
		WeatherType.WT.DROUGHT:
			return clampf((0.35 - vapor) * 2.0 + (0.16 - cloud) + maxf(-ocean_an, 0.0) * 0.6, 0.0, 1.0)
	return 0.0

func _distribute_weather_field_to_cells(map: MapData) -> void:
	_cover_dirty = false
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	# [perf 2026-05-20] 同 _distribute_to_cells：累积到批量数组，末尾 write_f32_indexed。
	# 原循环里 cell.moisture / cell.temperature 单点 setter 会导致 _dirty_mark_one 风暴
	# （N 次单点 mark → mask 全 1 → atlas_upload 退化为全推）。
	var _wfd_n: int = cells.size()
	var _wfd_idx: PackedInt32Array = PackedInt32Array()
	var _wfd_moist: PackedFloat32Array = PackedFloat32Array()
	var _wfd_temp: PackedFloat32Array = PackedFloat32Array()
	var _wfd_env_idx: PackedInt32Array = PackedInt32Array()
	var _wfd_snow_cover: PackedFloat32Array = PackedFloat32Array()
	var _wfd_snowpack: PackedFloat32Array = PackedFloat32Array()
	var _wfd_water_balance: PackedFloat32Array = PackedFloat32Array()
	var _wfd_soil: PackedFloat32Array = PackedFloat32Array()
	_wfd_idx.resize(_wfd_n)
	_wfd_moist.resize(_wfd_n)
	_wfd_temp.resize(_wfd_n)
	_wfd_env_idx.resize(_wfd_n)
	_wfd_snow_cover.resize(_wfd_n)
	_wfd_snowpack.resize(_wfd_n)
	_wfd_water_balance.resize(_wfd_n)
	_wfd_soil.resize(_wfd_n)
	var _wfd_w: int = 0
	var _wfd_env_w: int = 0
	var has_snowpack_arr: bool = map.snowpack_arr.size() == _wfd_n
	var has_water_balance_arr: bool = map.water_balance_30d_arr.size() == _wfd_n
	var has_soil_arr: bool = map.soil_moisture_arr.size() == _wfd_n
	var has_snow_arr: bool = map.snow_cover_arr.size() == _wfd_n
	var has_heat_arr: bool = map.heat_input_arr.size() == _wfd_n
	for cell: HexCell in cells:
		var idx: int = int(cell.index)
		var is_water_cell: bool = LandformType.is_water(cell.landform) or _is_water_terrain(int(cell.terrain))
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var intensity: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var raw_precip: float = cell.weather_precip if cell.weather_field_initialized else 0.0
		var precip: float = raw_precip if _is_precip_weather_type(wt) else 0.0
		var moist_now: float = cell.moisture
		var temp_now: float = cell.temperature
		if wt == WeatherType.WT.CLEAR or intensity <= 0.001:
			if not is_water_cell \
					and (cell.accumulated_snow_days > 0 or cell.cover == CoverType.CV.SNOW):
				if _apply_snow_accumulation(cell, wt, cell.temperature, 0.0):
					_cover_dirty = true
			if idx >= 0 and idx < _wfd_n:
				var clear_sp: float = map.snowpack_arr[idx] if has_snowpack_arr else clampf(cell.snow_cover * 0.35, 0.0, 1.0)
				var clear_wb: float = map.water_balance_30d_arr[idx] if has_water_balance_arr else 0.0
				var clear_soil: float = map.soil_moisture_arr[idx] if has_soil_arr else cell.soil_moisture
				var clear_heat: float = map.heat_input_arr[idx] if has_heat_arr else 0.0
				if is_water_cell:
					clear_sp = 0.0
					clear_wb = lerpf(clear_wb, 0.0, 1.0 / 30.0)
				else:
					var clear_elev_delta: float = cell.elevation - SNOW_ELEV_NEUTRAL
					var clear_freeze_off: float = clampf(clear_elev_delta * SNOW_ELEV_FREEZE_GAIN, -SNOW_ELEV_FREEZE_MAX_OFF, SNOW_ELEV_FREEZE_MAX_OFF)
					var clear_melt_off: float = clampf(clear_elev_delta * SNOW_ELEV_MELT_GAIN, -SNOW_ELEV_MELT_MAX_OFF, SNOW_ELEV_MELT_MAX_OFF)
					var clear_freeze_t: float = SNOW_FREEZE_T + clear_freeze_off
					var clear_melt_t: float = SNOW_MELT_T + clear_melt_off
					var clear_melt: float = maxf(temp_now - clear_melt_t, 0.0) * _snowpack_melt_temp_gain + clear_heat * _snowpack_melt_sun_gain + _summer_snow_melt_bonus(clear_heat, cell.elevation)
					var clear_cold_precip: bool = temp_now < clear_freeze_t and precip > 0.002
					var clear_snow_accum: float = precip * _snowpack_accum_gain * 0.75 if clear_cold_precip else 0.0
					if clear_cold_precip:
						clear_snow_accum += minf(intensity, 0.15) * 0.006
					clear_sp = clampf(clear_sp + clear_snow_accum - clear_melt, 0.0, 1.0)
					if cell.cover == CoverType.CV.GLACIER and clear_sp < 0.80:
						clear_sp = 0.80
					var clear_evap: float = clampf((0.01 + maxf(moist_now - 0.45, 0.0) * 0.03) * (0.35 + temp_now * 1.05) * 0.65, 0.0, 1.0)
					var clear_runoff: float = maxf(moist_now - 0.82, 0.0) * 0.25 + maxf(cell.elevation - 0.70, 0.0) * precip * 0.06
					var clear_daily_balance: float = clampf(precip - clear_evap - clear_runoff, -1.0, 1.0)
					clear_wb = lerpf(clear_wb, clear_daily_balance, 1.0 / 30.0)
					# climate-loop-closure Phase 3.1：土壤水每日衰减(×0.97,~33日时间常数)，
					# 使停雨后土壤能排干、持续小雨区不再单调累积到 +0.5 上限(诊断实测根因)。
					clear_soil = clampf(clear_soil * 0.97 + clear_daily_balance * 0.08, -0.5, 0.5)
					var clear_moist: float = clampf(moist_now + precip * 0.35 + maxf(clear_daily_balance, 0.0) * 0.04, 0.0, 1.0)
					if _data_core_world == null:
						cell.moisture = clear_moist
					elif _wfd_w < _wfd_n:
						_wfd_idx[_wfd_w] = idx
						_wfd_moist[_wfd_w] = clear_moist
						_wfd_temp[_wfd_w] = temp_now
						_wfd_w += 1
				# climate-loop-closure Phase 2.1/2.2：气候态物理雪线 floor（仅陆地）。
				# 冷区即便无降水也按当前温度获得基线雪盖；雪线随海拔/季节自然升降。
				if _snowline_temp_threshold > 0.0 and not is_water_cell:
					var clear_floor: float = _snowline_floor_for_cell(temp_now, clear_heat, cell.elevation)
					if clear_floor > 0.0:
						clear_sp = maxf(clear_sp, clear_floor * _snowpack_cover_full)
				var clear_sc: float = smoothstep(_snowpack_cover_low, _snowpack_cover_full, clear_sp)
				if _snowline_temp_threshold > 0.0 and not is_water_cell:
					clear_sc = maxf(clear_sc, _snowline_floor_for_cell(temp_now, clear_heat, cell.elevation))
				if cell.cover == CoverType.CV.GLACIER and clear_sc < 0.80:
					clear_sc = 0.80
				if has_snowpack_arr: map.snowpack_arr[idx] = clear_sp
				if has_snow_arr: map.snow_cover_arr[idx] = clear_sc
				if has_water_balance_arr: map.water_balance_30d_arr[idx] = clear_wb
				if has_soil_arr: map.soil_moisture_arr[idx] = clear_soil
				_wfd_env_idx[_wfd_env_w] = idx
				_wfd_snow_cover[_wfd_env_w] = clear_sc
				_wfd_snowpack[_wfd_env_w] = clear_sp
				_wfd_water_balance[_wfd_env_w] = clear_wb
				_wfd_soil[_wfd_env_w] = clear_soil
				_wfd_env_w += 1
			continue

		moist_now = clampf(cell.moisture + WeatherType.moisture_delta(wt) * intensity + precip * 0.35, 0.0, 1.0)
		var weather_temp_delta: float = clampf(WeatherType.temp_delta(wt) * intensity, -_weather_temp_anomaly_cap, _weather_temp_anomaly_cap)
		temp_now = clampf(cell.temperature + weather_temp_delta, 0.0, 1.0)
		# [perf] 删除单点 setter；累积到批量数组（fallback 时仍走 setter 兜 backing）
		if _data_core_world == null:
			cell.moisture = moist_now
			cell.temperature = temp_now
		if cell.index >= 0 and _wfd_w < _wfd_n:
			_wfd_idx[_wfd_w] = idx
			_wfd_moist[_wfd_w] = moist_now
			_wfd_temp[_wfd_w] = temp_now
			_wfd_w += 1

		if idx >= 0 and idx < _wfd_n:
			var sp_now: float = map.snowpack_arr[idx] if has_snowpack_arr else clampf(cell.snow_cover * 0.35, 0.0, 1.0)
			var prev_sp: float = sp_now
			var wb_now: float = map.water_balance_30d_arr[idx] if has_water_balance_arr else 0.0
			var soil_now: float = map.soil_moisture_arr[idx] if has_soil_arr else cell.soil_moisture
			var snow_cover_now: float = 0.0
			var heat_input: float = map.heat_input_arr[idx] if has_heat_arr else 0.0
			if is_water_cell:
				sp_now = 0.0
				wb_now = lerpf(wb_now, 0.0, 1.0 / 30.0)
			else:
				var elev_delta: float = cell.elevation - SNOW_ELEV_NEUTRAL
				var freeze_off: float = clampf(elev_delta * SNOW_ELEV_FREEZE_GAIN, -SNOW_ELEV_FREEZE_MAX_OFF, SNOW_ELEV_FREEZE_MAX_OFF)
				var melt_off: float = clampf(elev_delta * SNOW_ELEV_MELT_GAIN, -SNOW_ELEV_MELT_MAX_OFF, SNOW_ELEV_MELT_MAX_OFF)
				var freeze_t_local: float = SNOW_FREEZE_T + freeze_off
				var melt_t_local: float = SNOW_MELT_T + melt_off
				var precip_can_snow: bool = wt != WeatherType.WT.DROUGHT and wt != WeatherType.WT.HEATWAVE and wt != WeatherType.WT.CLEAR
				var snowing: bool = (WeatherType.can_form_snow(wt) or precip_can_snow) and temp_now < freeze_t_local and precip > 0.0
				var snow_accum: float = precip * _snowpack_accum_gain if snowing else 0.0
				if snowing:
					snow_accum += intensity * 0.015
				var warm_rain_melt: float = precip * 0.03 if temp_now > melt_t_local else 0.0
				var melt: float = maxf(temp_now - melt_t_local, 0.0) * _snowpack_melt_temp_gain + heat_input * _snowpack_melt_sun_gain + _summer_snow_melt_bonus(heat_input, cell.elevation) + warm_rain_melt
				sp_now = clampf(sp_now + snow_accum - melt, 0.0, 1.0)
				if cell.cover == CoverType.CV.GLACIER and sp_now < 0.80:
					sp_now = 0.80
				var meltwater: float = maxf(prev_sp - sp_now, 0.0)
				var runoff: float = maxf(moist_now - 0.82, 0.0) * 0.25 + maxf(cell.elevation - 0.70, 0.0) * precip * 0.06
				var evap_proxy: float = clampf((0.01 + maxf(moist_now - 0.45, 0.0) * 0.03) * (0.35 + temp_now * 1.05) * 0.65, 0.0, 1.0)
				var daily_balance: float = clampf(precip * 1.15 + meltwater * 0.65 - evap_proxy - runoff, -1.0, 1.0)
				wb_now = lerpf(wb_now, daily_balance, 1.0 / 30.0)
				# climate-loop-closure Phase 3.1：土壤水每日衰减(见 clear 分支同段注释)。
				soil_now = clampf(soil_now * 0.97 + daily_balance * 0.08, -0.5, 0.5)
			# climate-loop-closure Phase 2.1/2.2：气候态物理雪线 floor（仅陆地）。
			if _snowline_temp_threshold > 0.0 and not is_water_cell:
				var snow_floor: float = _snowline_floor_for_cell(temp_now, heat_input, cell.elevation)
				if snow_floor > 0.0:
					sp_now = maxf(sp_now, snow_floor * _snowpack_cover_full)
			snow_cover_now = smoothstep(_snowpack_cover_low, _snowpack_cover_full, sp_now)
			if _snowline_temp_threshold > 0.0 and not is_water_cell:
				snow_cover_now = maxf(snow_cover_now, _snowline_floor_for_cell(temp_now, heat_input, cell.elevation))
			if cell.cover == CoverType.CV.GLACIER and snow_cover_now < 0.80:
				snow_cover_now = 0.80
			if has_snowpack_arr: map.snowpack_arr[idx] = sp_now
			if has_snow_arr: map.snow_cover_arr[idx] = snow_cover_now
			if has_water_balance_arr: map.water_balance_30d_arr[idx] = wb_now
			if has_soil_arr: map.soil_moisture_arr[idx] = soil_now
			_wfd_env_idx[_wfd_env_w] = idx
			_wfd_snow_cover[_wfd_env_w] = snow_cover_now
			_wfd_snowpack[_wfd_env_w] = sp_now
			_wfd_water_balance[_wfd_env_w] = wb_now
			_wfd_soil[_wfd_env_w] = soil_now
			_wfd_env_w += 1

		if not is_water_cell:
			# 雪：累积式（同 fronts 路径，避免两条分支不一致）
			if _apply_snow_accumulation(cell, wt, temp_now, intensity):
				_cover_dirty = true
			# 洪涝：放宽条件 + 高强度直接淹（与 fronts 路径同步）
			if cell.cover != CoverType.CV.SNOW and WeatherType.can_form_flood(wt):
				var heavy_flood: bool = intensity > 0.55 and precip > 0.55
				var lowland_flood: bool = intensity > 0.32 and cell.elevation < 0.50 and moist_now > 0.60
				if (heavy_flood or lowland_flood) and cell.cover != CoverType.CV.FLOODING:
					cell.cover = CoverType.CV.FLOODING
					cell.current_state["cover"] = int(cell.cover)
					_cover_dirty = true
			# Stage8 退水：不受 can_form_flood 门限制(故 DROUGHT/CLEAR 也能退)→修"洪泛与旱灾共存"。干燥时积水退去。
			if cell.cover == CoverType.CV.FLOODING and moist_now < 0.50 and precip < 0.04:
				cell.cover = CoverType.CV.NONE
				cell.current_state["cover"] = int(cell.cover)
				_cover_dirty = true

	# [perf] 末尾批量 commit moisture / temperature 到 DCWorld（一次性 mark dirty）
	if _data_core_world != null and _wfd_w > 0:
		_wfd_idx.resize(_wfd_w)
		_wfd_moist.resize(_wfd_w)
		_wfd_temp.resize(_wfd_w)
		var _cid_md_f: int = _data_core_world.component_id(DCComponentIds.CELL_MOISTURE)
		if _cid_md_f >= 0:
			_data_core_world.write_f32_indexed(_cid_md_f, _wfd_idx, _wfd_moist)
		var _cid_td_f: int = _data_core_world.component_id(DCComponentIds.CELL_TEMP)
		if _cid_td_f >= 0:
			_data_core_world.write_f32_indexed(_cid_td_f, _wfd_idx, _wfd_temp)
	if _data_core_world != null and _wfd_env_w > 0:
		_wfd_env_idx.resize(_wfd_env_w)
		_wfd_snow_cover.resize(_wfd_env_w)
		_wfd_snowpack.resize(_wfd_env_w)
		_wfd_water_balance.resize(_wfd_env_w)
		_wfd_soil.resize(_wfd_env_w)
		var _cid_sc_f: int = _data_core_world.component_id(DCComponentIds.CELL_SNOW_COVER)
		if _cid_sc_f >= 0:
			_data_core_world.write_f32_indexed(_cid_sc_f, _wfd_env_idx, _wfd_snow_cover)
		var _cid_sp_f: int = _data_core_world.component_id(DCComponentIds.CELL_SNOWPACK)
		if _cid_sp_f >= 0:
			_data_core_world.write_f32_indexed(_cid_sp_f, _wfd_env_idx, _wfd_snowpack)
		var _cid_wb_f: int = _data_core_world.component_id(DCComponentIds.CELL_WATER_BALANCE_30D)
		if _cid_wb_f >= 0:
			_data_core_world.write_f32_indexed(_cid_wb_f, _wfd_env_idx, _wfd_water_balance)
		var _cid_sm_f: int = _data_core_world.component_id(DCComponentIds.CELL_SOIL_MOISTURE)
		if _cid_sm_f >= 0:
			_data_core_world.write_f32_indexed(_cid_sm_f, _wfd_env_idx, _wfd_soil)

func _build_field_summary_fronts(map: MapData, world: WorldData) -> Array[WeatherFront]:
	# Continuity-fix（2026-05-10）：完全重写聚类阶段，根治"天气特效跳变"。
	#
	# 旧实现的问题：
	#   1. 每 tick 都用 flood-fill 从零聚类，没有跨 tick 身份；视觉层只能靠
	#      (type, 距离 ≤ 1.5×r) 反推同一性，split/merge/边界 cell 翻 type 时
	#      匹配失败 → 旧 front 淡出 + 新 front 在另一处淡入 = 跳变。
	#   2. 单一硬阈值 0.10 → 边界 cell 在 0.08~0.12 之间抖动 → 聚类形态每 tick 漂移。
	#   3. summary front 的 velocity 字段从未填写 → weather_layer._predict 外推位移恒为 0
	#      → 跳日间云完全静止，下次 snapshot 来时是位移阶跃。
	#
	# 现在的修法：
	#   Step 1（C）以 _prev_summary_seeds 为优先种子做 BFS，让 cluster 跨 tick 保身份。
	#   Step 2（D）阈值滞回：上 tick 在某簇内的 cell 用 _HOLD=0.06 留簇里；新加入需 ≥ _ENTER=0.10。
	#   Step 3（A）给每个 front 设 velocity = axis × radius × 0.4（与 _spawn_random_front 同源），
	#                   weather_layer 外推预测就能让云在跳日/blend 阶段顺风继续飘。
	#   Step 4 inherited cluster 的 life_progress 按继承代数前进，让 birth/dissolve 曲线
	#                   只在真正"新生云"上触发；老簇保持 mature 不再每 tick 复位为 0.2。
	const _SUMMARY_INTENSITY_ENTER: float = 0.10
	const _SUMMARY_INTENSITY_HOLD: float = 0.06
	var components: Array = []
	var visited: Dictionary = {}
	var new_membership: Dictionary = {}
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()

	# Step 1：先用上 tick 的 cluster 中心做 BFS 种子，保持身份。
	# 按 area 降序处理：大 cluster 优先认领，避免被相邻的小 cluster 抢走中心 cell。
	var prev_seed_list: Array = _prev_summary_seeds.duplicate()
	prev_seed_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("area", 1)) > int(b.get("area", 1))
	)
	for prev in prev_seed_list:
		var prev_type: int = int(prev.get("type", WeatherType.WT.CLEAR))
		var prev_center: Vector2 = prev.get("center", Vector2.ZERO)
		var cube := HexUtils.world_to_cube(prev_center, _hex_size)
		var seed_cell: HexCell = map.get_cell_by_cube(cube)
		if seed_cell == null:
			continue
		# 找到合格种子：优先 prev_center 所在 cell；若 type 改变或强度跌穿 hold，
		# 再在 1 环邻居里寻找同型且 ≥ hold 阈值的 cell 作为继承种子。
		var picked_seed: HexCell = _pick_inheritance_seed(
			seed_cell, prev_type, map, visited,
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if picked_seed == null:
			continue
		var component := _flood_fill_field_component(
			picked_seed, prev_type, map, visited, new_membership, components.size(),
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if not component.is_empty():
			component["inherited_age"] = int(prev.get("age", 0)) + 1
			# Drift-fix（2026-05-10）：把上 tick 的中心 + 速度透传给本 tick 的 component，
			# 用于在 build front 阶段计算实测每-snapshot 位移（observed_drift）。
			# 这是让"云会飘"真正生效的关键：之前 axis × radius × 0.4 是凭空给的常数，
			# weather_layer 外推又跑不到，所以视觉位移恒为 0。
			component["inherited_from_center"] = prev_center
			component["inherited_from_velocity"] = prev.get("velocity", Vector2.ZERO)
			components.append(component)

	# Step 2：剩下未访问的 cell 自起新 cluster（age=0 → 走 birth 渐入曲线）。
	for seed_cell: HexCell in cells:
		if visited.has(seed_cell):
			continue
		var wt: int = seed_cell.weather_type if seed_cell.weather_field_initialized else WeatherType.WT.CLEAR
		var intensity: float = seed_cell.weather_intensity if seed_cell.weather_field_initialized else 0.0
		var thresh: float = _SUMMARY_INTENSITY_HOLD if _prev_summary_membership.has(seed_cell) else _SUMMARY_INTENSITY_ENTER
		if intensity < thresh or wt == WeatherType.WT.CLEAR:
			visited[seed_cell] = true
			continue
		var component := _flood_fill_field_component(
			seed_cell, wt, map, visited, new_membership, components.size(),
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if not component.is_empty():
			component["inherited_age"] = 0
			components.append(component)

	# 跨 tick 状态更新（在 _merge_nearby_components 重排前记录 cell 归属）。
	_prev_summary_membership = new_membership

	# dramatic-fx：同型相邻合并 pass。flood-fill 后仍可能存在"被一两格 CLEAR 隔开"
	# 的同型团块（云之间的过渡空隙），这些在视觉上是连续的一片云，但作为两个 front
	# 下发会被 shader 各自做包络衰减 → 边界处出现"双圆叠加 + 中间空"的诡异形态。
	# 这里 O(n²) 扫一遍，把同型且圆心距 < (r1+r2)*0.65 的两个 component 合并，
	# 中心按 area 加权平均、area 累加、intensity 取 max。
	components = _merge_nearby_components(components)

	components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var next_seeds: Array = []
	var limit: int = mini(_field_summary_limit, components.size())
	for i in range(limit):
		var c: Dictionary = components[i]
		var front := WeatherFront.new()
		front.type = int(c.get("type", WeatherType.WT.CLEAR))
		front.center = c.get("center", Vector2.ZERO)
		front.intensity = clampf(float(c.get("intensity", 0.0)), 0.0, 1.0)
		# dramatic-fx：sqrt(area) 系数 0.78 → 1.05；基底 1.35 → 1.6。
		# 单 front 半径整体 +35%，配合下方拉长的 major_scale，覆盖面积约 ×2.
		front.radius = _hex_size * (1.6 + sqrt(float(c.get("area", 1))) * 1.05)
		var axis: Vector2 = c.get("axis", Vector2.RIGHT)
		if axis.length_squared() <= 0.0001:
			axis = Vector2.RIGHT
		front.axis = axis.normalized()
		front.stable_axis = front.axis
		# Drift-fix（2026-05-10，替代 Continuity-fix A）：
		# velocity 改为"实测每-snapshot 位移"——继承 cluster 用 (new_center - prev_center)，
		# 新生 cluster 用 avg_wind 作 fallback。weather_layer 在 set_weather_fronts 内
		# 会用这个 velocity 给 lerp target 做 forward-bias，让 lerp 终点本身就是
		# "下次 snapshot 到达时云应该在的位置"，避免回弹 + 让中间帧持续向前飘。
		# EMA 平滑 (lerp 0.5)：单帧 BFS 抖动产生的伪位移会被前一 tick 的 velocity 拉回。
		# 位移上限 = radius × 0.6：避免重聚类质心阶跃造成 visual 飞窜。
		var fallback_velocity: Vector2 = front.axis * front.radius * 0.4
		var measured_velocity: Vector2 = fallback_velocity
		var debug_observed_drift: Vector2 = Vector2.ZERO
		var debug_prev_center: Vector2 = Vector2.ZERO
		var debug_inherited: bool = false
		if c.has("inherited_from_center"):
			debug_inherited = true
			var prev_center_pos: Vector2 = c["inherited_from_center"]
			debug_prev_center = prev_center_pos
			var prev_velocity: Vector2 = c.get("inherited_from_velocity", Vector2.ZERO)
			var observed_drift: Vector2 = front.center - prev_center_pos
			var max_drift: float = front.radius * 0.6
			if observed_drift.length() > max_drift:
				observed_drift = observed_drift.normalized() * max_drift
			debug_observed_drift = observed_drift
			# EMA：50% 历史 + 50% 当前，缓和单 tick 的随机漂移
			measured_velocity = prev_velocity.lerp(observed_drift, 0.5)
		front.velocity = measured_velocity
		if DRIFT_DEBUG_LOG and i < 3:
			if debug_inherited:
				print("[weather-drift] day=%d c%d type=%d r=%.0f prev=%s new=%s drift=%s |drift|=%.1f vel=%s |vel|=%.1f" % [
					_day_counter, i, front.type, front.radius,
					str(debug_prev_center.round()), str(front.center.round()),
					str(debug_observed_drift.round()), debug_observed_drift.length(),
					str(front.velocity.round()), front.velocity.length(),
				])
			else:
				print("[weather-drift] day=%d c%d type=%d r=%.0f NEW center=%s vel(fallback)=%s |vel|=%.1f" % [
					_day_counter, i, front.type, front.radius,
					str(front.center.round()),
					str(front.velocity.round()), front.velocity.length(),
				])
		# dramatic-fx：椭圆比从 1.10/0.92 改 1.30/0.85，让 front 沿风向拉长，
		# 视觉上更像"风带云团"，不再是圆球。
		front.major_scale = 1.30
		front.minor_scale = 0.85
		# Continuity-fix：用继承代数代替原来硬写的 ttl=2/age=0/life=0.2。
		# 新生 cluster (age=0) → life=0.15，birth=smoothstep(0,0.32,0.15)≈0.30 渐入；
		# 继承 ≥3 tick → life≈0.45，birth=1.0，已成熟、不再每 tick 复位为半透明。
		# ttl 给个足够大的上限以避开 dissolve（smoothstep 起点 0.58）。
		var inherited_age: int = int(c.get("inherited_age", 0))
		front.age_days = inherited_age
		front.ttl_days = maxi(inherited_age * 3 + 12, 12)
		front.decay_per_day = 0.0
		front.edge_seed = float((i + 1) * 37 + int(front.center.x) * 3 + int(front.center.y) * 5)
		front.cloud_amount = clampf(float(c.get("cloud", 0.0)), 0.0, 1.0)
		front.precip_amount = clampf(float(c.get("precip", 0.0)), 0.0, 1.0)
		front.dissolve_amount = 0.0
		front.life_progress = clampf(0.15 + float(inherited_age) * 0.08, 0.15, 0.45)
		front.front_temperature_advection = float(c.get("temp_advection", 0.0))
		front.front_diagnostic_kind = int(c.get("front_diag_kind", WeatherFront.FRONT_DIAG_NONE))
		fronts.append(front)
		next_seeds.append({
			"type": front.type,
			"center": front.center,
			"age": inherited_age,
			"area": int(c.get("area", 1)),
			# Drift-fix：保存本 tick 实测速度，下 tick EMA 时作为历史项使用。
			"velocity": front.velocity,
		})
	# 持久化下一 tick 的种子列表（仅顶部 limit 个；溢出 limit 的小 cluster 不再继承
	# 给下 tick——避免 16 front 上限造成的"幽灵种子"持续抢 BFS 优先权）。
	_prev_summary_seeds = next_seeds
	return fronts

# Continuity-fix：找到一个适合做"继承种子"的 cell。
#   1. 若 prev_center 所在 cell 仍是同 type 且 ≥ hold 阈值 → 直接用
#   2. 否则 1 环邻居里找一个同 type 且 ≥ hold 阈值的 cell
#   3. 都没有 → 返回 null（这个 prev cluster 本 tick 死掉，让它进 fade-out 路径）
# 注意：picked_seed 必须未被其它 cluster 抢占（visited.has 检查）。
func _pick_inheritance_seed(
		seed_cell: HexCell, prev_type: int, map: MapData,
		visited: Dictionary, enter_thresh: float, hold_thresh: float) -> HexCell:
	# prev_center 所在 cell 仍可用 → 直接用
	if not visited.has(seed_cell):
		var swt: int = seed_cell.weather_type if seed_cell.weather_field_initialized else WeatherType.WT.CLEAR
		var si: float = seed_cell.weather_intensity if seed_cell.weather_field_initialized else 0.0
		var s_thresh: float = hold_thresh if _prev_summary_membership.has(seed_cell) else enter_thresh
		if swt == prev_type and si >= s_thresh:
			return seed_cell
	# Fallback：1 环邻居（即使 seed_cell 本身被其它继承簇抢走，邻居仍可能可用，
	# 这对应"两个 prev cluster 中心相邻、第二个被迫沿外缘扩展"的场景）。
	for nb: HexCell in _cell_neighbors(seed_cell, map):
		if nb == null or visited.has(nb):
			continue
		var nwt: int = nb.weather_type if nb.weather_field_initialized else WeatherType.WT.CLEAR
		var ni: float = nb.weather_intensity if nb.weather_field_initialized else 0.0
		var n_thresh: float = hold_thresh if _prev_summary_membership.has(nb) else enter_thresh
		if nwt == prev_type and ni >= n_thresh:
			return nb
	return null

# Continuity-fix：带 hysteresis 的 flood-fill。
# 从 seed 起 BFS，把所有同 type 且 ≥ 个性化阈值（在上 tick 簇内则用 hold，否则用 enter）的
# cell 收进同一 component。新成员的归属写到 new_membership[cell] = cluster_idx，
# 供下 tick 的 hysteresis 判定使用。
func _flood_fill_field_component(
		seed: HexCell, wt: int, map: MapData,
		visited: Dictionary, new_membership: Dictionary, cluster_idx: int,
		enter_thresh: float, hold_thresh: float) -> Dictionary:
	var queue: Array = [seed]
	visited[seed] = true
	var cells: Array = []
	var sum_pos := Vector2.ZERO
	var sum_axis := Vector2.ZERO
	var sum_cloud: float = 0.0
	var sum_precip: float = 0.0
	var sum_temp_adv: float = 0.0
	var temp_adv_weight: float = 0.0
	var max_i: float = 0.0
	while not queue.is_empty():
		var cell: HexCell = queue.pop_front()
		var cwt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var ci: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var thresh_self: float = hold_thresh if _prev_summary_membership.has(cell) else enter_thresh
		if cwt != wt or ci < thresh_self:
			continue
		cells.append(cell)
		new_membership[cell] = cluster_idx
		sum_pos += _cell_world_pos(cell)
		sum_axis += cell.wind_vector
		sum_cloud += cell.weather_cloud
		sum_precip += cell.weather_precip
		var wind: Vector2 = cell.wind_vector
		if wind.length_squared() > 0.0001:
			var upstream: HexCell = _neighbor_aligned(cell, map, -wind)
			var downstream: HexCell = _neighbor_aligned(cell, map, wind)
			if downstream != null:
				var upstream_temp: float = upstream.temperature if upstream != null else cell.temperature
				var local_adv: float = upstream_temp - downstream.temperature
				sum_temp_adv += local_adv * ci
				temp_adv_weight += ci
		max_i = maxf(max_i, ci)
		for nb: HexCell in _cell_neighbors(cell, map):
			if nb == null or visited.has(nb):
				continue
			var nwt: int = nb.weather_type if nb.weather_field_initialized else WeatherType.WT.CLEAR
			var ni: float = nb.weather_intensity if nb.weather_field_initialized else 0.0
			var thresh_nb: float = hold_thresh if _prev_summary_membership.has(nb) else enter_thresh
			if nwt == wt and ni >= thresh_nb:
				visited[nb] = true
				queue.append(nb)
	if cells.is_empty():
		return {}
	var count: float = float(cells.size())
	var temp_advection: float = sum_temp_adv / maxf(temp_adv_weight, 0.001)
	return {
		"type": wt,
		"center": sum_pos / count,
		"axis": sum_axis / count,
		"cloud": sum_cloud / count,
		"precip": sum_precip / count,
		"temp_advection": temp_advection,
		"front_diag_kind": _front_diagnostic_kind(temp_advection),
		"intensity": max_i,
		"area": cells.size(),
		"score": max_i * sqrt(count),
	}

# dramatic-fx：把同型 + 圆心距 < (r1+r2) * MERGE_RATIO 的 component 合并。
# 用每 component 的"等效半径"（hex_size * sqrt(area) * 1.05）做距离阈值——
# 与下方 build_front 的 radius 公式同源，避免阈值与最终视觉半径脱节。
# 多轮迭代直到无可合并为止（典型 1-2 轮收敛）。
func _merge_nearby_components(components: Array) -> Array:
	const MERGE_RATIO: float = 0.65
	var changed: bool = true
	var rounds: int = 0
	while changed and rounds < 4:
		changed = false
		rounds += 1
		var n: int = components.size()
		var merged_into: Array[int] = []
		merged_into.resize(n)
		for i in range(n):
			merged_into[i] = -1
		for i in range(n):
			if merged_into[i] >= 0:
				continue
			var ci: Dictionary = components[i]
			var ai: float = float(ci.get("area", 1))
			var ri: float = _hex_size * sqrt(maxf(ai, 1.0)) * 1.05
			var center_i: Vector2 = ci.get("center", Vector2.ZERO)
			var type_i: int = int(ci.get("type", WeatherType.WT.CLEAR))
			for j in range(i + 1, n):
				if merged_into[j] >= 0:
					continue
				var cj: Dictionary = components[j]
				if int(cj.get("type", WeatherType.WT.CLEAR)) != type_i:
					continue
				var aj: float = float(cj.get("area", 1))
				var rj: float = _hex_size * sqrt(maxf(aj, 1.0)) * 1.05
				var center_j: Vector2 = cj.get("center", Vector2.ZERO)
				var dist: float = center_i.distance_to(center_j)
				if dist > (ri + rj) * MERGE_RATIO:
					continue
				# 合并 j → i：area 加和、center 按 area 加权、强度取 max、
				# cloud/precip 按 area 加权、axis 按 area 加权后归一化。
				var total: float = ai + aj
				ci["center"] = (center_i * ai + center_j * aj) / total
				ci["axis"] = (Vector2(ci.get("axis", Vector2.ZERO)) * ai + Vector2(cj.get("axis", Vector2.ZERO)) * aj) / total
				ci["cloud"] = (float(ci.get("cloud", 0.0)) * ai + float(cj.get("cloud", 0.0)) * aj) / total
				ci["precip"] = (float(ci.get("precip", 0.0)) * ai + float(cj.get("precip", 0.0)) * aj) / total
				var temp_adv: float = (float(ci.get("temp_advection", 0.0)) * ai + float(cj.get("temp_advection", 0.0)) * aj) / total
				ci["temp_advection"] = temp_adv
				ci["front_diag_kind"] = _front_diagnostic_kind(temp_adv)
				ci["intensity"] = maxf(float(ci.get("intensity", 0.0)), float(cj.get("intensity", 0.0)))
				ci["area"] = total
				ci["score"] = float(ci.get("intensity", 0.0)) * sqrt(total)
				# Continuity-fix：合并时取较大的继承代数，让"两个老簇合并"的结果
				# 仍被视为成熟簇，而不是被新生分量拖回 birth 阶段。
				ci["inherited_age"] = maxi(
					int(ci.get("inherited_age", 0)),
					int(cj.get("inherited_age", 0))
				)
				ai = total
				ri = _hex_size * sqrt(maxf(ai, 1.0)) * 1.05
				center_i = ci.get("center", Vector2.ZERO)
				components[i] = ci
				merged_into[j] = i
				changed = true
		# 把未被合并的 component 收集为新一轮 components
		var next_components: Array = []
		for i in range(n):
			if merged_into[i] < 0:
				next_components.append(components[i])
		components = next_components
	return components

func has_cover_dirty() -> bool:
	return _cover_dirty

# --- 查询接口（给 UI / 其他子系统） ---
# 返回 { "type": int(WT), "intensity": float [0,1] }；max-merge：取覆盖到该点的最强 front。
func query_at(world_pos: Vector2) -> Dictionary:
	if _weather_field_enabled:
		var map_ref: MapData = _current_map_for_tick if _current_map_for_tick != null else _last_map_for_query
		if map_ref != null:
			var cube := HexUtils.world_to_cube(world_pos, _hex_size)
			var cell: HexCell = map_ref.get_cell_by_cube(cube)
			if cell != null and cell.weather_field_initialized:
				return {
					"type": cell.weather_type,
					"intensity": cell.weather_intensity,
					"cloud": cell.weather_cloud,
					"precip": cell.weather_precip,
					"vapor": cell.weather_vapor,
					"instability": cell.weather_instability,
				}
	var best_type: int = WeatherType.WT.CLEAR
	var best_intensity: float = 0.0
	for front in _active_fronts:
		var c: float = front.coverage_at(world_pos)
		if c > best_intensity:
			best_intensity = c
			best_type = front.type
	return {"type": best_type, "intensity": best_intensity}

# --- shader uniform 打包 ---
# 返回 { "centers": Array[Vector4(cx, cy, radius, intensity)], "types": Array[int], "count": int }
# 由 HexRenderer.set_weather_fronts 取用，组装成 shader uniform 数组。
func pack_to_uniforms() -> Dictionary:
	var centers: Array = []
	var types: Array = []
	var shapes: Array = []
	var visuals: Array = []
	for front in _active_fronts:
		centers.append(Vector4(front.center.x, front.center.y, front.radius, front.intensity))
		types.append(int(front.type))
		var ax := front.normalized_axis()
		shapes.append(Vector4(ax.x, ax.y, front.major_scale, front.minor_scale))
		visuals.append(Vector4(
			front.cloud_amount,
			front.precip_amount,
			front.dissolve_amount,
			front.life_progress
		))
	return {
		"centers": centers,
		"types": types,
		"shapes": shapes,
		"visuals": visuals,
		"count": _active_fronts.size()
	}

func active_fronts() -> Array[WeatherFront]:
	return _active_fronts

# ─── Systemic Ocean Currents：台风尾迹扰动（可选） ──────────────────────

# 由外部在初始化时调用，把 MapConfig.enable_cyclone_wake / CYCLONE_WAKE_DAYS 写入。
func configure_cyclone_wake(enabled: bool, wake_days: int) -> void:
	_cyclone_wake_enabled = enabled
	_cyclone_wake_days = max(1, wake_days)
	if not enabled:
		ocean_current_perturbation.clear()

# ─── Phase F.1：DCWorldExt 加速钩子注入 ─────────────────────────
# 由 map_generator 在 _data_core_world_ext 成功 bind 后调用一次（典型路径：
# DataCore._setup_sus 末尾 / refresh_daily 首次调度前）。后续若 ext 失效可
# 再调一次本函数 enabled=false 清空。
#
# 契约：
#   ext == null 或 enabled == false  → run_weather_field_solve_slice 全程走
#                                       GDScript legacy（与无加速完全等价）
#   ext != null 且 enabled == true   → 只要 slice 是全量 (cell_budget ≥ n)
#                                       就尝试 C++ 单 shot 路径，失败则透明
#                                       fallback 到 GDScript 完成本 tick

# 任务 2（dots-completion）：HexCell facade 启用时关掉 hot loop AoS 双写。
# - main / map_generator 在 ClimateProfile.use_hexcell_facade=true 时调用本方法。
# - 启用后 commit_weather_field_solve / GDScript fallback 跳过 16 行 out_cell.weather_*=
#   直写，cell 字段读全部走 SoA（DCWorld view_f32 / facade getter）。
# - 关闭时退回到双写（兼容 facade=false 的 legacy reader）。
# 该方法可在运行时反复调用；调用对下一次 tick 立即生效。
func set_hexcell_facade_on(b: bool) -> void:
	_hexcell_facade_on = b


func configure_gdext_acceleration(ext: RefCounted, enabled: bool, cp: Resource = null, dc_world = null) -> void:
	_data_core_world_ext = ext
	# PR-2.1.6：注入 GDScript DCWorld 用于 commit/spawn 写路径下移（master 手册 §3.9）。
	# 旧 caller（3 参数版）仍可用，dc_world 默认为 null → 仅维持现状双写不下移。
	_data_core_world = dc_world
	# has_method 仅检查方法名存在；旧 stub 签名是 (knobs, grid_w, grid_h, season_idx,
	# climate_anomaly, season_phase) 6 参数，新签名只剩 (knobs) 1 参数。stale .dll
	# 下 has_method=true 但 binding 拒调 → rc=null → float(null)=0.0 → 误判 success
	# → SoA 静默不写。下面用 get_method_list 验证实际参数数 = 1。
	#
	# dots-flag-prune-pr1 (2026-05-22)： use_gdext_weather_field/distribute/summary
	# 三个 cp 字段已删除——赋值现恒走 ext+has_method+sig 探测（仅保留
	# enabled 参数作为 caller 主动 kill-switch）。
	var sig_ok: bool = _validate_weather_field_signature(ext)
	var commit_sig_ok: bool = _validate_weather_field_commit_signature(ext)
	_use_gdext_weather_field = enabled and ext != null and ext.has_method("run_weather_field_solve_pass") and sig_ok
	_use_gdext_weather_field_commit = enabled and ext != null and ext.has_method("run_weather_field_commit_pass") and commit_sig_ok
	_gdext_field_warned_fallback = false
	_gdext_field_commit_warned_fallback = false
	# F.6 / fronts_soa / resident_knobs：cache cp reference 供 advect / soa / knobs 同步读。
	_cp_for_front_flag = cp
	_sync_profile_weather_knobs(cp)
	if _use_gdext_weather_field:
		print("[weather] gdext acceleration ON (class=DCWorldExt)")
	elif ext != null and enabled and not sig_ok:
		# sig probe 已经 push_warning 过具体的 args 数；这里再加一条总结
		push_warning("[weather] gdext acceleration DISABLED for this session: stale .dll signature mismatch (rebuild gdext to enable)")
	elif ext != null and enabled:
		push_warning("[weather] gdext acceleration requested but ext lacks run_weather_field_solve_pass; staying on GDScript path")
	if _use_gdext_weather_field_commit:
		print("[weather] gdext field commit ON")
	elif ext != null and enabled and ext.has_method("run_weather_field_commit_pass") and not commit_sig_ok:
		push_warning("[weather] gdext field commit DISABLED: stale .dll signature mismatch")

	# ─── Weather Hot-Path C++ 化（plan/weather-hotpath-cpp）───────────────────
	# dist + summary 两个 pass 的能力探测：方法存在 + 签名 arg-count = 1。任一失败镜像 flag
	# = false → 永远走 GDScript fallback。
	var dist_sig_ok: bool = _validate_weather_distribute_signature(ext)
	var summary_sig_ok: bool = _validate_weather_summary_signature(ext)
	_use_gdext_weather_distribute = enabled and ext != null \
			and ext.has_method("run_weather_distribute_pass") and dist_sig_ok
	_use_gdext_weather_summary = enabled and ext != null \
			and ext.has_method("run_weather_summary_fronts_pass") and summary_sig_ok
	_gdext_dist_warned_fallback = false
	_gdext_summary_warned_fallback = false
	# Flag 切换时清空 C++ 端持久化 summary 状态，避免新旧实现互相污染。
	if ext != null and ext.has_method("reset_weather_summary_state"):
		ext.reset_weather_summary_state()

	if _use_gdext_weather_distribute:
		print("[weather] gdext distribute ON")
	elif ext != null and enabled and not dist_sig_ok:
		push_warning("[weather] gdext distribute DISABLED: stale .dll signature mismatch")
	if _use_gdext_weather_summary:
		print("[weather] gdext summary ON")
	elif ext != null and enabled and not summary_sig_ok:
		push_warning("[weather] gdext summary DISABLED: stale .dll signature mismatch")

	# dots-flag-prune-pr1 (2026-05-22)： use_hexcell_facade 已删除——facade 现恒启用（
	# DataCore world 已恒 bind，hot loop 跳过 16 行 AoS 双写，cell 字段读全部走 SoA）。
	if cp != null:
		_hexcell_facade_on = true
		if _hexcell_facade_on:
			print("[weather] hexcell facade ON (skip AoS double-write in hot loop)")
	# ─── Phase A.3：常驻 KnobsHandle 装配 ────────────────────────
	# dots-flag-prune-pr1 round 2: use_gdext_resident_knobs flag 已删除——恒走 ext +
	# ClassDB.class_exists('KnobsHandle') 探测分支。启用条件（任一失败永久 fallback 到
	# GDScript builder）：
	#   1. enabled 整体启用且 ext != null
	#   2. ClassDB 内有 "KnobsHandle" 类（rebuild 后 stale .dll 无此类则 instantiate 失败）
	_knobs_handle = null
	_knobs_handle_first_use_logged = false
	if enabled and ext != null:
		if ClassDB.class_exists("KnobsHandle"):
			_knobs_handle = ClassDB.instantiate("KnobsHandle")
			if _knobs_handle != null and _knobs_handle.has_method("invalidate_all"):
				# 首次装配 → all-dirty。caller 应立刻通过 _push_resident_knobs_from_cp(cp)
				# 把当前 ClimateProfile 全字段写入；后续 ClimateProfile.changed 信号触发同样路径。
				_knobs_handle.invalidate_all()
				_push_resident_knobs_from_cp(cp)
				# 连接 ClimateProfile.changed 信号（Resource 内置）→ 段级 invalidate
				if cp != null and cp.has_signal("changed") and not cp.changed.is_connected(_on_climate_profile_changed_for_knobs):
					cp.changed.connect(_on_climate_profile_changed_for_knobs.bind(cp))
				print("[weather] gdext resident knobs ON (class=KnobsHandle)")
			else:
				push_warning("[weather] KnobsHandle instantiate returned invalid object; resident knobs DISABLED")
				_knobs_handle = null
		else:
			push_warning("[weather] ClassDB lacks 'KnobsHandle' (stale .dll); resident knobs DISABLED. REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'")
# Stale .dll probe：验证 run_weather_field_solve_pass 实际签名。旧 stub 6 参，新
# 实装 1 参 (Dictionary knobs)。不匹配时 push_warning 一次 + 返回 false 让外层
# 永久走 GDScript fallback。
func _validate_weather_field_signature(ext: RefCounted) -> bool:
	if ext == null:
		return false
	if not ext.has_method("run_weather_field_solve_pass"):
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_field_solve_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_field_solve_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'." % args.size())
			return false
	return false


func _validate_weather_field_commit_signature(ext: RefCounted) -> bool:
	if ext == null:
		return false
	if not ext.has_method("run_weather_field_commit_pass"):
		return false
	var ml: Array = ext.get_method_list()
	for m: Dictionary in ml:
		if String(m.get("name", "")) == "run_weather_field_commit_pass":
			var args: Array = m.get("args", [])
			if args.size() == 1:
				return true
			push_warning("[gdext sig] run_weather_field_commit_pass has %d args (expected 1); gdext .dll is STALE. REBUILD: 'cd gdext && scons platform=windows target=template_release dev_build=no -j8'." % args.size())
			return false
	return false

# ─── Phase F.1：A/B 运行时验证（离线诊断专用）────────────────────────────
# enabled=true 后每 tick 都先用 C++ 跑 → 把 next_* + SoA 快照 → 复位 SoA →
# 用 GDScript 重跑 → 逐 cell 比较，首次 abs(delta) > tol 时打详细日志。
# 默认 tol=1.0e-4（charter §12.6.2 sqrt+lerp 链经验值）。
# 性能开销：≈ 2×（同一 tick 跑两次），仅适合 dev / repro 模式下用一两个 tick
# 抓 bug；正常游玩别开。
func set_field_verify_mode(enabled: bool, tol_f32: float = 1.0e-4) -> void:
	_field_verify_enabled = enabled
	_field_verify_tol_f32 = max(0.0, tol_f32)
	_field_verify_first_divergence_logged = false
	if enabled:
		print("[weather] field A/B verify ON (tol=%.1e); next tick will run both paths" % tol_f32)

# ─── Weather Hot-Path：dist A/B verify mode（任务 5）─────────────────────
# 流程：snapshot 5 个 SoA/AoS 字段 → C++ 跑（SoA 已写新值）→ 把 C++ 结果搬到
# shadow → 复位 SoA/AoS → 跑 GDScript → 逐 cell 比对 → commit 走 C++（把
# shadow 写回 SoA/AoS）。开启后整 pass 时间 ≈ 旧 × 2，仅 dev 模式短时使用。
# 切换 verify mode 时清空 dist 节流告警状态，避免历史 fallback 状态污染。
func set_distribute_verify_mode(enabled: bool, tol_f32: float = 1.0e-4) -> void:
	_distribute_verify_enabled = enabled
	_distribute_verify_tol_f32 = max(0.0, tol_f32)
	_distribute_verify_first_divergence_logged = false
	if enabled:
		print("[weather] distribute A/B verify ON (tol=%.1e); next tick will run both paths" % tol_f32)

# ─── Weather Hot-Path：summary A/B verify mode（任务 8 中实装比对主体；本处先
# 提供 setter 给 dev 工具调用，避免任务 6/7 引用未定义符号）。──────────────
func set_summary_verify_mode(enabled: bool,
		tol_pos: float = 0.5, tol_intensity: float = 1.0e-3,
		tol_velocity: float = 0.5) -> void:
	_summary_verify_enabled = enabled
	_summary_verify_tol_pos = max(0.0, tol_pos)
	_summary_verify_tol_intensity = max(0.0, tol_intensity)
	_summary_verify_tol_velocity = max(0.0, tol_velocity)
	_summary_verify_first_divergence_logged = false
	# 切换 verify 时清空 C++ 端持久化 summary 状态，避免新旧实现相互污染（与
	# flag 切换走同一通路）。
	if _data_core_world_ext != null and _data_core_world_ext.has_method("reset_weather_summary_state"):
		_data_core_world_ext.reset_weather_summary_state()
	if enabled:
		print("[weather] summary A/B verify ON (pos=%.2f intensity=%.1e velocity=%.2f)" % [
			tol_pos, tol_intensity, tol_velocity
		])

# 触发：set_distribute_verify_mode(true) 之后每次 C++ dist 成功 commit 前进入。
# 调用前置条件：C++ 已经把 dist 结果写入 SoA + acc/pre PackedArray。
# 主流程把这些 commit 后的值快照到 shadow，复位 SoA/AoS 到 snapshot 入口状态，
# 跑 GDScript 重新 dist，比较两侧最大 delta；最后把 shadow 重新塞回 SoA/AoS 让
# commit 走 C++ 路径。
func _verify_gdext_distribute_against_gdscript(map: MapData, n_cells: int, cpp_rc: Dictionary) -> void:
	if not _distribute_verify_enabled:
		return
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	# Step 1：把 C++ 已经 commit 的 5 个字段复制为 shadow（CoW dup 保证脱离 SoA 引用）。
	var shadow_temp: PackedFloat32Array = map.temp_arr.duplicate()
	var shadow_moist: PackedFloat32Array = map.moisture_arr.duplicate()
	var shadow_cover: PackedByteArray = map.cover_arr.duplicate()
	var shadow_acc: PackedInt32Array = PackedInt32Array()
	var shadow_pre: PackedInt32Array = PackedInt32Array()
	shadow_acc.resize(n_cells)
	shadow_pre.resize(n_cells)
	for i in range(n_cells):
		var c: HexCell = cells[i]
		shadow_acc[i] = c.accumulated_snow_days
		shadow_pre[i] = c.pre_snow_cover

	# Step 2：复位到本 tick 入口状态（cpp_rc 携带的 snapshot；调用方提供）。
	# snapshot 字段名约定：snap_temp / snap_moist / snap_cover / snap_acc / snap_pre。
	# 调用方在 fast-path 调度阶段已 dup 一份原始 SoA 传入。
	var snap_temp: PackedFloat32Array = cpp_rc.get("snap_temp", PackedFloat32Array())
	var snap_moist: PackedFloat32Array = cpp_rc.get("snap_moist", PackedFloat32Array())
	var snap_cover: PackedByteArray = cpp_rc.get("snap_cover", PackedByteArray())
	var snap_acc: PackedInt32Array = cpp_rc.get("snap_acc", PackedInt32Array())
	var snap_pre: PackedInt32Array = cpp_rc.get("snap_pre", PackedInt32Array())
	if snap_temp.size() != n_cells or snap_moist.size() != n_cells or \
			snap_cover.size() != n_cells or snap_acc.size() != n_cells or \
			snap_pre.size() != n_cells:
		push_warning("[weather/dist verify] snapshot 不全或大小不匹配，跳过本 tick verify")
		return
	# 把 SoA 还原。facade=true 时 cell.cover/temperature/moisture 通过 setter 透写
	# SoA；这里直接覆写 SoA arr 即可。
	map.temp_arr = snap_temp.duplicate()
	map.moisture_arr = snap_moist.duplicate()
	map.cover_arr = snap_cover.duplicate()
	for i in range(n_cells):
		var c2: HexCell = cells[i]
		c2.accumulated_snow_days = snap_acc[i]
		c2.pre_snow_cover = snap_pre[i]
		# current_state["cover"] 可能在 C++ commit 阶段被改过；同步回 snapshot。
		c2.current_state["cover"] = int(snap_cover[i])

	# Step 3：跑 GDScript 版 dist。它会读 cell.* 写 cell.* 同源覆盖。
	_distribute_weather_field_to_cells(map)

	# Step 4：逐 cell 比对（temp/moist 用 tol_f32；cover/acc/pre 严格相等）。
	var max_dt: float = 0.0
	var max_dm: float = 0.0
	var first_div_idx: int = -1
	var first_div_field: String = ""
	for i in range(n_cells):
		var dt: float = absf(shadow_temp[i] - map.temp_arr[i])
		var dm: float = absf(shadow_moist[i] - map.moisture_arr[i])
		if dt > max_dt:
			max_dt = dt
		if dm > max_dm:
			max_dm = dm
		if first_div_idx < 0 and (dt > _distribute_verify_tol_f32 or dm > _distribute_verify_tol_f32):
			first_div_idx = i
			first_div_field = "temperature" if dt > dm else "moisture"
		if shadow_cover[i] != map.cover_arr[i] and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "cover"
		var c3: HexCell = cells[i]
		if shadow_acc[i] != c3.accumulated_snow_days and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "accumulated_snow_days"
		if shadow_pre[i] != c3.pre_snow_cover and first_div_idx < 0:
			first_div_idx = i
			first_div_field = "pre_snow_cover"

	if first_div_idx >= 0 and not _distribute_verify_first_divergence_logged:
		_distribute_verify_first_divergence_logged = true
		var c4: HexCell = cells[first_div_idx]
		push_warning("[weather/dist verify] divergence at idx=%d field=%s cpp_temp=%.4f gd_temp=%.4f cpp_moist=%.4f gd_moist=%.4f cpp_cover=%d gd_cover=%d cpp_acc=%d gd_acc=%d (max_dt=%.4e max_dm=%.4e)" % [
			first_div_idx, first_div_field,
			shadow_temp[first_div_idx], map.temp_arr[first_div_idx],
			shadow_moist[first_div_idx], map.moisture_arr[first_div_idx],
			int(shadow_cover[first_div_idx]), int(map.cover_arr[first_div_idx]),
			shadow_acc[first_div_idx], c4.accumulated_snow_days,
			max_dt, max_dm
		])

	# Step 5：把 shadow（C++ 结果）写回 SoA/AoS，让 commit 走 C++ 路径。
	map.temp_arr = shadow_temp
	map.moisture_arr = shadow_moist
	map.cover_arr = shadow_cover
	for i in range(n_cells):
		var c5: HexCell = cells[i]
		c5.accumulated_snow_days = shadow_acc[i]
		c5.pre_snow_cover = shadow_pre[i]
		c5.current_state["cover"] = int(shadow_cover[i])

# ─── Weather Hot-Path：summary fronts A/B verify（任务 8）─────────────────
# 调用前提：set_summary_verify_mode(true) 之后，C++ summary pass 已成功跑过
# 一次（fronts_cpp 已就位）；调用方把 fronts_cpp 与 cpp_state_snapshotted=true
# 作为入参传入。本函数：
#   1. 调 C++ restore_weather_summary_state() 把 prev_seeds/membership 还原到
#      C++ pass 入口状态（snapshot 已在 fast-path 调度时由 caller 完成）；
#   2. 跑 GDScript _build_field_summary_fronts → 得 fronts_gd；
#   3. 同长度 + 字段容差比对（type 严格 / center 0.5px / intensity 1e-3 /
#      velocity 0.5px），首个发散 push_warning 一次（_summary_verify_first_
#      divergence_logged 节流）；
#   4. 调用方把 fronts_cpp 写回 _active_fronts 完成 commit（本函数不动 commit）。
#
# 注意：GDScript 复跑 _build_field_summary_fronts 会改 _prev_summary_seeds /
# _prev_summary_membership（GDScript 镜像）。这两个状态在 fast-path 模式下
# 不被使用，但 verify off 切回 GDScript 路径时会被复用 —— 不算污染（GDScript
# 路径下本来就由 _build_field_summary_fronts 自维护）。
func _verify_gdext_summary_against_gdscript(map: MapData, world: WorldData,
		fronts_cpp: Array[WeatherFront]) -> void:
	if not _summary_verify_enabled:
		return
	if _data_core_world_ext == null:
		return
	# Step 1：C++ 端把 prev_seeds/membership restore 到本 tick 入口状态。
	# 调用方应已在 fast-path 调度入口调用 snapshot_weather_summary_state()。
	if _data_core_world_ext.has_method("restore_weather_summary_state"):
		_data_core_world_ext.restore_weather_summary_state()
	# Step 2：GDScript 复跑（注意 GDScript prev_seeds/membership 也会被改，
	# 见函数说明）。
	var fronts_gd: Array[WeatherFront] = _build_field_summary_fronts(map, world)
	# Step 3：逐 front 容差比对。
	var n_cpp: int = fronts_cpp.size()
	var n_gd: int = fronts_gd.size()
	if n_cpp != n_gd and not _summary_verify_first_divergence_logged:
		_summary_verify_first_divergence_logged = true
		push_warning("[weather/summary verify] front count mismatch: cpp=%d gd=%d" % [n_cpp, n_gd])
		return
	var n: int = mini(n_cpp, n_gd)
	for i in range(n):
		var fc: WeatherFront = fronts_cpp[i]
		var fg: WeatherFront = fronts_gd[i]
		if fc.type != fg.type and not _summary_verify_first_divergence_logged:
			_summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] type mismatch cpp=%d gd=%d" % [i, fc.type, fg.type])
			return
		var dpos: float = fc.center.distance_to(fg.center)
		if dpos > _summary_verify_tol_pos and not _summary_verify_first_divergence_logged:
			_summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] center mismatch cpp=%s gd=%s |Δ|=%.2f (tol=%.2f)" % [
				i, str(fc.center.round()), str(fg.center.round()), dpos, _summary_verify_tol_pos
			])
			return
		if absf(fc.intensity - fg.intensity) > _summary_verify_tol_intensity and not _summary_verify_first_divergence_logged:
			_summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] intensity mismatch cpp=%.4f gd=%.4f (tol=%.1e)" % [
				i, fc.intensity, fg.intensity, _summary_verify_tol_intensity
			])
			return
		var dvel: float = fc.velocity.distance_to(fg.velocity)
		if dvel > _summary_verify_tol_velocity and not _summary_verify_first_divergence_logged:
			_summary_verify_first_divergence_logged = true
			push_warning("[weather/summary verify] front[%d] velocity mismatch cpp=%s gd=%s |Δ|=%.2f (tol=%.2f)" % [
				i, str(fc.velocity.round()), str(fg.velocity.round()), dvel, _summary_verify_tol_velocity
			])
			return

# ─── 任务 9：节流式回归告警 ───────────────────────────────────────────────
# field_solver 在 dist/summary commit 完成后分别调一次。维护最近 5 个 elapsed
# 样本；连续 5 个都 > budget × 2 时 push_warning 一次（warned 节流防止刷屏）。
# 一旦最近某次回到 budget 内，warned 重置回 false（性能恢复后可再警告）。
func push_dist_perf_sample(elapsed_ms: float) -> void:
	_dist_recent_ms.append(elapsed_ms)
	if _dist_recent_ms.size() > _PERF_RING_SIZE:
		_dist_recent_ms.remove_at(0)
	var threshold: float = _DIST_PERF_BUDGET_MS * _PERF_BUDGET_MULTIPLIER
	if _dist_recent_ms.size() >= _PERF_RING_SIZE:
		var all_over: bool = true
		for v in _dist_recent_ms:
			if v <= threshold:
				all_over = false
				break
		if all_over and not _dist_regression_warned:
			_dist_regression_warned = true
			push_warning("[weather/dist] perf regression: last %d ticks all > %.2fms (budget %.2fms × %.1f)" % [
				_PERF_RING_SIZE, threshold, _DIST_PERF_BUDGET_MS, _PERF_BUDGET_MULTIPLIER
			])
		elif (not all_over) and _dist_regression_warned:
			# 性能恢复，下次回归时还能再警告一次
			_dist_regression_warned = false

func push_summary_perf_sample(elapsed_ms: float) -> void:
	_summary_recent_ms.append(elapsed_ms)
	if _summary_recent_ms.size() > _PERF_RING_SIZE:
		_summary_recent_ms.remove_at(0)
	var threshold: float = _SUMMARY_PERF_BUDGET_MS * _PERF_BUDGET_MULTIPLIER
	if _summary_recent_ms.size() >= _PERF_RING_SIZE:
		var all_over: bool = true
		for v in _summary_recent_ms:
			if v <= threshold:
				all_over = false
				break
		if all_over and not _summary_regression_warned:
			_summary_regression_warned = true
			push_warning("[weather/summary] perf regression: last %d ticks all > %.2fms (budget %.2fms × %.1f)" % [
				_PERF_RING_SIZE, threshold, _SUMMARY_PERF_BUDGET_MS, _PERF_BUDGET_MULTIPLIER
			])
		elif (not all_over) and _summary_regression_warned:
			_summary_regression_warned = false

# Emergent Climate Coupling：由 MapGenerator 在 refresh_daily 之前调用。
# 启用时 tick_one_day 内会做 4 项耦合：
#   1. 推进前按 front 中心 cell 的 local 状态调整本日 decay_per_day（类型匹配 ×0.7、不匹配 ×1.5）
#   2. 推进时如经过山脉迎风坡：本格 precip 强度叠加；经过背风坡：额外衰减
#   3. spawn 概率按本地 1 环温湿梯度加权（梯度大处更易生成 front）
#   4. spawn 类型由本地温度带、湿度带、水陆条件和实际气候异常决定。
# 关闭时保留旧 front 行为作为兼容回退，但不重新启用季节硬切气候 forcing。
func configure_emergent_coupling(enabled: bool, rain_shadow_threshold: float, rain_shadow_factor: float, orographic_boost: float) -> void:
	_emergent_coupling = enabled
	_emergent_rain_shadow_threshold = rain_shadow_threshold
	_emergent_rain_shadow_factor = rain_shadow_factor
	_emergent_orographic_boost = orographic_boost

# v11 由 MapGenerator 在初始化时推送。控制 advect / spawn 是否优先采样
# HexCell.wind_vector（地形扰动后的实际风）。
func configure_terrain_wind(enabled: bool) -> void:
	_use_wind_vector_for_advect = enabled

# Ocean spawn bias：由 MapGenerator 在 init/refresh_daily 推送 ClimateProfile
# 中的 ocean_weather_spawn_bias。0 = 关闭（legacy 行为），>0 = 寒流海岸抑制
# 降水类天气 spawn、暖流海岸促进。详见 _spawn_emergent_front 内的偏置公式。
func configure_ocean_spawn_bias(bias: float) -> void:
	_ocean_spawn_bias = maxf(0.0, bias)

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
	_weather_field_enabled = enabled
	_field_advect_steps = clampi(advect_steps, 0, 8)  # 方案③ 上限 4→8
	_field_diffusion = clampf(diffusion, 0.0, 0.5)
	_field_condensation_gain = maxf(0.0, condensation_gain)
	_field_precip_decay = clampf(precip_decay, 0.0, 1.0)
	_field_precip_carryover_max = clampf(precip_carryover_max, 0.0, 1.0)
	_field_vapor_precip_sink = clampf(vapor_precip_sink, 0.0, 1.0)
	_field_vapor_relax_rate = clampf(vapor_relax_rate, 0.0, 1.0)
	_field_orographic_lift_gain = maxf(0.0, orographic_lift_gain)
	_field_orographic_lift_cap = clampf(orographic_lift_cap, 0.0, 1.0)
	_field_wet_terrain_precip_damping = clampf(wet_terrain_precip_damping, 0.0, 1.0)
	_field_lake_precip_damping = clampf(lake_precip_damping, 0.0, 1.0)
	_field_lake_evap_scale = clampf(lake_evap_scale, 0.0, 1.0)
	_field_extreme_precip_soft_cap = clampf(extreme_precip_soft_cap, 0.0, 1.0)
	_field_extreme_precip_softness = clampf(extreme_precip_softness, 0.0, 1.0)
	_field_convergence_gain = maxf(0.0, convergence_gain)
	_field_convergence_refresh_stride = clampi(convergence_refresh_stride, 1, 12)
	_field_ocean_evap_gain = maxf(0.0, ocean_evap_gain)
	_field_land_evapotranspiration_gain = maxf(0.0, land_evapotranspiration_gain)
	_field_precip_rh_threshold = clampf(precip_rh_threshold, 0.40, 0.95)
	_field_ocean_precip_suppression = clampf(ocean_precip_suppression, 0.0, 1.0)
	_field_frontogenesis_gain = maxf(0.0, frontogenesis_gain)
	_field_rain_shadow_drying = clampf(rain_shadow_drying, 0.0, 1.0)
	_field_vapor_transport_gain = clampf(vapor_transport_gain, 0.0, 1.0)
	_snowpack_accum_gain = clampf(snowpack_accum_gain, 0.0, 1.0)
	_snowpack_melt_temp_gain = clampf(snowpack_melt_temp_gain, 0.0, 1.0)
	_snowpack_melt_sun_gain = clampf(snowpack_melt_sun_gain, 0.0, 1.0)
	_snowpack_cover_low = clampf(snowpack_cover_low, 0.0, 0.5)
	_snowpack_cover_full = maxf(_snowpack_cover_low + 0.001, clampf(snowpack_cover_full, 0.0, 1.0))
	_snow_accum_days_req = clampi(snow_accum_days_req, 1, 8)
	_snowline_temp_threshold = clampf(snowline_temp_threshold, 0.0, 1.0)
	_snowline_band = clampf(snowline_band, 0.02, 0.6)
	_weather_temp_anomaly_cap = clampf(weather_temp_anomaly_cap, 0.0, 0.10)
	if _cp_for_front_flag != null:
		if _cp_for_front_flag.get("weather_cold_precip_as_blizzard") != null:
			_cold_precip_as_blizzard = bool(_cp_for_front_flag.weather_cold_precip_as_blizzard)
		if _cp_for_front_flag.get("weather_snow_classification_margin") != null:
			_snow_classification_margin = clampf(float(_cp_for_front_flag.weather_snow_classification_margin), 0.0, 0.12)
		if _cp_for_front_flag.get("weather_wet_terrain_precip_damping") != null:
			_field_wet_terrain_precip_damping = clampf(float(_cp_for_front_flag.weather_wet_terrain_precip_damping), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_lake_precip_damping") != null:
			_field_lake_precip_damping = clampf(float(_cp_for_front_flag.weather_lake_precip_damping), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_lake_evap_scale") != null:
			_field_lake_evap_scale = clampf(float(_cp_for_front_flag.weather_lake_evap_scale), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_extreme_precip_soft_cap") != null:
			_field_extreme_precip_soft_cap = clampf(float(_cp_for_front_flag.weather_extreme_precip_soft_cap), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_extreme_precip_softness") != null:
			_field_extreme_precip_softness = clampf(float(_cp_for_front_flag.weather_extreme_precip_softness), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_land_evapotranspiration_gain") != null:
			_field_land_evapotranspiration_gain = maxf(0.0, float(_cp_for_front_flag.weather_land_evapotranspiration_gain))
		if _cp_for_front_flag.get("weather_precip_rh_threshold") != null:
			_field_precip_rh_threshold = clampf(float(_cp_for_front_flag.weather_precip_rh_threshold), 0.40, 0.95)
		if _cp_for_front_flag.get("weather_ocean_precip_suppression") != null:
			_field_ocean_precip_suppression = clampf(float(_cp_for_front_flag.weather_ocean_precip_suppression), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_frontogenesis_gain") != null:
			_field_frontogenesis_gain = maxf(0.0, float(_cp_for_front_flag.weather_frontogenesis_gain))
		if _cp_for_front_flag.get("weather_rain_shadow_drying") != null:
			_field_rain_shadow_drying = clampf(float(_cp_for_front_flag.weather_rain_shadow_drying), 0.0, 1.0)
		if _cp_for_front_flag.get("weather_vapor_transport_gain") != null:
			_field_vapor_transport_gain = clampf(float(_cp_for_front_flag.weather_vapor_transport_gain), 0.0, 1.0)
	_field_summary_limit = clampi(summary_limit, 1, 12)
	if not enabled:
		_weather_field.clear()

# v11 风场采样统一入口：
#   - 开关为 true 且能反查到 cell 且 cell.wind_vector 足够大 → 直接返回 cell.wind_vector。
#     这是地形扰动后的 per-cell 实际风，本身已含山脈绕流、海岸热力加速和压力场响应。
#   - fallback（开关为 false / 反查失败 / wind_vector 太小）
#     C3 plan (vector_atlas removal)：原 fallback 调 world.sample_wind(pos)
#     从 wind_field_buffer 双线性采样，但 buffer 已停止 bake（is_empty）。
#     新 fallback：直接走 WindBelt.wind_at(ny, season_phase) 的纯纬度风基线。
func _sample_terrain_wind(map: MapData, _world: WorldData, world_pos: Vector2, ny: float, season_phase: float) -> Vector2:
	if _use_wind_vector_for_advect and map != null:
		var cube := HexUtils.world_to_cube(world_pos, _hex_size)
		var cell: HexCell = map.get_cell_by_cube(cube)
		if cell != null:
			var wv: Vector2 = cell.wind_vector
			if wv.length() > 0.01:
				return wv
	# Pure-baseline fallback：纬度风基线（不再走像素 buffer 采样）。
	return WindBelt.wind_at(ny, season_phase)

# spawn 路径（_spawn_random_front / _build_front_at）复用 _current_map_for_tick 取 map
# 引用；if tick 未运行（外部直接调 _build_front_at）则返回 null → _sample_terrain_wind
# 会优雅 fallback。
func _map_for_spawn(_world: WorldData) -> MapData:
	return _current_map_for_tick

# 只读查询：返回某 cell 当前的扰动向量（无则 Vector2.ZERO）。给航运 AI / 未来 shader 上传用。
func cell_perturbation(cell: HexCell) -> Vector2:
	if cell == null:
		return Vector2.ZERO
	var key: int = cell.q * 10000 + cell.r
	if not ocean_current_perturbation.has(key):
		return Vector2.ZERO
	var d: Dictionary = ocean_current_perturbation[key]
	return d.get("vec", Vector2.ZERO)

# 每日推进：
#   1) 对已有扰动 days_left - 1，days_left <= 0 则移除；
#      vec 幅度按 days_left / init_days 线性衰减。
#   2) 遍历当前活跃 front，找 STORM + on_water + intensity > 0.8 的"强海上风暴"，
#      在其中心 cell 注入旋转扰动（与风速正交，按 intensity 缩放）。
# dots-monolith-split §1.1：_tick_cyclone_wake 内联实现已迁出至
# scripts/weather/front_advect.gd::tick_cyclone_wake(map)，本处不再保留函数体。
# 静态 _is_water_terrain 仍在本文件保留（被 weather_field/distribute 等多处调用）。

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
func _front_decay_modifier(front: WeatherFront, cell: HexCell) -> float:
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var temp: float = cell.temperature
	var moist: float = cell.moisture
	var warm: bool = temp > 0.55
	var cold: bool = temp < 0.30
	var humid: bool = moist > 0.55
	var dry: bool = moist < 0.35
	match front.type:
		WeatherType.WT.RAIN:
			if humid: return 0.7
			if dry and warm: return 1.5
		WeatherType.WT.STORM:
			if humid and warm: return 0.7
			if dry or cold: return 1.5
		WeatherType.WT.MONSOON:
			if humid and warm: return 0.7
			if dry: return 1.5
		WeatherType.WT.BLIZZARD:
			if cold: return 0.7
			if warm: return 1.5
		WeatherType.WT.HEATWAVE:
			if warm and dry: return 0.7
			if cold or humid: return 1.5
		WeatherType.WT.DROUGHT:
			if dry and warm: return 0.7
			if humid: return 1.5
		WeatherType.WT.FOG:
			if humid and cold: return 0.7
	return 1.0

func _cold_precip_should_snow(temp: float, vapor: float, cloud: float, precip: float, meaningful_precip: bool) -> bool:
	if not _cold_precip_as_blizzard or not meaningful_precip:
		return false
	if temp <= SNOW_FREEZE_T:
		return true
	return temp < SNOW_MELT_T + _snow_classification_margin \
			and cloud > 0.18 and vapor > 0.20 and precip > 0.04

# 迎风坡降水加成 / 背风坡额外衰减：
#   沿 front.velocity 方向找上风 cell：若上风 cell 海拔比本格高出阈值 → 迎风坡（返回正 bonus）
#   若本格海拔比上风 cell 高出阈值 → 背风坡（返回负 bonus，作衰减）
# 仅对降水型 front 生效（RAIN / STORM / MONSOON / BLIZZARD）。
func _front_orographic_precip_bonus(front: WeatherFront, cell: HexCell, map: MapData) -> float:
	var t: int = front.type
	if t != WeatherType.WT.RAIN and t != WeatherType.WT.STORM \
	and t != WeatherType.WT.MONSOON and t != WeatherType.WT.BLIZZARD:
		return 0.0
	var v: Vector2 = front.velocity
	if v.length_squared() < 1e-6:
		return 0.0
	# 从本格向上风（-v）方向找最对齐邻居
	var w_dir: Vector2 = -v.normalized()
	var self_wp: Vector2 = _cell_world_pos(cell)
	var best_nb: HexCell = null
	var best_dot: float = 0.1
	for nb: HexCell in _cell_neighbors(cell, map):
		if nb == null:
			continue
		var nbwp: Vector2 = _cell_world_pos(nb)
		var d: Vector2 = (nbwp - self_wp)
		if d.length_squared() < 1e-6:
			continue
		var dv: float = d.normalized().dot(w_dir)
		if dv > best_dot:
			best_dot = dv
			best_nb = nb
	if best_nb == null:
		return 0.0
	var h_diff: float = cell.elevation - best_nb.elevation
	if h_diff < -_emergent_rain_shadow_threshold:
		# 本格比上风低很多 → 迎风爬坡 → 加成
		return 0.08 * _emergent_orographic_boost
	if h_diff > _emergent_rain_shadow_threshold:
		# 本格比上风高很多 → 背风 → 衰减（通过负 bonus 在分发时减少降水）
		return -0.08
	return 0.0

# Emergent spawn：按本地 1 环温湿梯度加权抽 1 个 cell 作为 spawn 源，
# 类型由本地温度带、湿度带、水陆条件和实际气候异常共同决定。
func _spawn_emergent_front(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	if map == null:
		return null
	# Step 1：采样一批候选 cell（32 个），按 1 环温湿梯度最大值加权选取
	var all_cells: Array = map.all_cells()
	if all_cells.is_empty():
		return null
	var samples: int = mini(32, all_cells.size())
	var best_cell: HexCell = null
	# 累计权重抽样：先算 total，再用 randf*total 抽
	var cands: Array = []
	var weights: Array = []
	var total_w: float = 0.0
	for i in range(samples):
		var c: HexCell = all_cells[_rng.randi_range(0, all_cells.size() - 1)]
		if c == null:
			continue
		var w: float = _local_temp_moist_gradient(c, map) + 0.05  # 底噪避免全 0
		# Ocean spawn bias：寒流邻水抑制候选 cell 的 spawn 权重，暖流提升。
		# 仅对陆地 / 海岸有 ≥1 个水域邻居的 cell 生效；远海面与内陆不变。
		# 偏置因子整体作用于"权重通道"，与具体 weather type 无关；
		# 类型抑制（寒流海岸 RAIN→CLEAR 之类）由 _pick_weather_type_emergent
		# 内部独立处理，避免双重惩罚。
		if _ocean_spawn_bias > 0.0:
			var w_mul: float = _ocean_weight_multiplier(c, map)
			w *= w_mul
		cands.append(c)
		weights.append(w)
		total_w += w
	if total_w <= 0.001 or cands.is_empty():
		return null
	var pick: float = _rng.randf() * total_w
	var acc: float = 0.0
	for i in range(cands.size()):
		acc += float(weights[i])
		if pick <= acc:
			best_cell = cands[i]
			break
	if best_cell == null:
		return null
	# Step 2：用该 cell 的温湿、水陆条件和实际气候异常决定类型。
	var wt: int = _pick_weather_type_emergent(best_cell, season_idx, climate_anomaly, map)
	if wt == WeatherType.WT.CLEAR:
		return null
	# Step 3：复用 _spawn_random_front 的参数化流程，但强制 spawn 位置为 best_cell 的世界坐标
	var spawn_pos: Vector2 = HexUtils.cube_to_world(best_cell.q, best_cell.r, _hex_size)
	return _build_front_at(spawn_pos, wt, world)

# 本地 1 环温湿梯度最大值（温度差 + 湿度差取 max）
func _local_temp_moist_gradient(cell: HexCell, map: MapData) -> float:
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var t0: float = cell.temperature
	var m0: float = cell.moisture
	var max_dt: float = 0.0
	var max_dm: float = 0.0
	for nb: HexCell in _cell_neighbors(cell, map):
		if nb == null:
			continue
		var dt: float = absf(nb.temperature - t0)
		var dm: float = absf(nb.moisture - m0)
		if dt > max_dt: max_dt = dt
		if dm > max_dm: max_dm = dm
	return maxf(max_dt, max_dm)

# 由本地温度带、湿度带、水陆条件和实际气候异常决定 front 类型。
# 规则：
#   暖湿陆地 + 强实际升温 → STORM
#   寒冷海面          → BLIZZARD
#   暖干陆地 + 高温     → HEATWAVE
#   暖干陆地           → DROUGHT
#   寒湿 / 暖湿海岸   → RAIN
#   低温湿             → FOG
# 其余返回 CLEAR（不 spawn）。
func _pick_weather_type_emergent(cell: HexCell, season_idx: int, climate_anomaly: float, map: MapData = null) -> int:
	season_idx = -1
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var t: float = cell.temperature + climate_anomaly
	var m: float = cell.moisture
	var cell_world: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	var lat_norm: float = 0.5
	if _world_bounds.size.y > 0.001:
		lat_norm = clampf((cell_world.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0)
	var lat_signed: float = lat_norm * 2.0 - 1.0
	var low_lat: bool = absf(lat_signed) < 0.42
	var on_water: bool = _is_water_terrain(int(cell.terrain))
	var warm: bool = t > 0.55
	var hot: bool = t > 0.68
	var cold: bool = t < 0.30
	var humid: bool = m > 0.55
	var dry: bool = m < 0.35

	if on_water:
		if cold:
			return WeatherType.WT.BLIZZARD
		# 暖湿海面：STORM（台风/热带风暴）
		if warm and humid:
			return _ocean_filter_precip(cell, map, WeatherType.WT.STORM)
		return _ocean_filter_precip(cell, map, WeatherType.WT.RAIN)
	# 陆地路径
	if hot and humid:
		return _ocean_filter_precip(cell, map, WeatherType.WT.STORM)
	if warm and dry:
		if hot:
			return WeatherType.WT.HEATWAVE
		return WeatherType.WT.DROUGHT
	if cold:
		return WeatherType.WT.BLIZZARD
	if humid:
		if warm and low_lat and m > 0.65:
			return _ocean_filter_precip(cell, map, WeatherType.WT.MONSOON)
		return _ocean_filter_precip(cell, map, WeatherType.WT.RAIN)
	if t < 0.45 and m > 0.40:
		return WeatherType.WT.FOG
	return WeatherType.WT.CLEAR

# Ocean spawn bias helpers：当 _ocean_spawn_bias > 0 时启用。
# 实现"洋流温度异常 → 沿岸天气事件偏置"通路：
#   - 寒流海岸（邻水 anomaly < 0）→ 抑制 RAIN/STORM/MONSOON 的 spawn 权重
#     与类型保留概率，让寒流海岸沙漠在天气层也表现为"少雨多雾"。
#   - 暖流海岸（邻水 anomaly > 0）→ 同类型权重提升，模拟湾流型多雨气候。
#   - 内陆 cell（无水邻居）与远海面（cell 自身就是水）→ 无影响。
#   - BLIZZARD/FOG/HEATWAVE/DROUGHT 不受影响（与"降水/对流"无直接因果）。

# 候选 cell 的 spawn 权重乘子：> 1 表示更易被抽中、< 1 表示更难。
# 仅对"邻水 ≥ 1 的陆地 / 海岸"生效。范围 clamp 到 [0.1, 1 + bias]。
func _ocean_weight_multiplier(cell: HexCell, map: MapData) -> float:
	if cell == null or map == null or _ocean_spawn_bias <= 0.0:
		return 1.0
	var avg_an: float = _avg_ocean_anomaly_at(cell, map)
	if absf(avg_an) < 0.005:
		return 1.0
	# bias × anomaly 直接影响乘子。anomaly ∈ ~[-0.3, +0.3]，bias 1.2 →
	# 寒流极端 ×0.64 / 暖流极端 ×1.36；clamp 防止退化为 0。
	var mul: float = 1.0 + _ocean_spawn_bias * avg_an
	return clampf(mul, 0.1, 1.0 + _ocean_spawn_bias)

# 寒流海岸 RAIN/STORM/MONSOON → CLEAR/FOG 软降级；暖流海岸不动作。
# 用累计概率：寒流强度越大、邻水占比越高，降级概率越大。
func _ocean_filter_precip(cell: HexCell, map: MapData, wt: int) -> int:
	if map == null or _ocean_spawn_bias <= 0.0:
		return wt
	var avg_an: float = _avg_ocean_anomaly_at(cell, map)
	if avg_an >= -0.01:
		return wt  # 不冷或暖流 → 不动
	# 降级概率 = bias × |anomaly|，clamp [0, 0.85]。
	var p_demote: float = clampf(_ocean_spawn_bias * (-avg_an), 0.0, 0.85)
	if _rng.randf() < p_demote:
		# 极冷（|anomaly| 大）→ FOG；中冷 → CLEAR。让"沿岸冷雾"在寒流海岸涌现。
		if -avg_an > 0.15:
			return WeatherType.WT.FOG
		return WeatherType.WT.CLEAR
	return wt

# 取 cell 1 环邻水的平均 temperature_transport_anomaly。无水邻居返回 0。
# 海面 cell 直接返回自身 anomaly（因为本身就是洋流体）。
# dots-monolith-split §1.2 / PR-3：搬迁到 field_solver.gd（薄转发）。
func _avg_ocean_anomaly_at(cell: HexCell, map: MapData) -> float:
	return _field_solver._avg_ocean_anomaly_at(cell, map)

# 基于给定 spawn_pos + 类型 wt 构造 front（从 _spawn_random_front 提炼），
# 避免重复类型抽样逻辑。
func _build_front_at(spawn_pos: Vector2, wt: int, world: WorldData) -> WeatherFront:
	var front := WeatherFront.new()
	front.center = spawn_pos
	front.type = wt
	front.intensity = _rng.randf_range(0.55, 1.0)
	var radius_mul: float = 1.0
	match wt:
		WeatherType.WT.RAIN:     radius_mul = _rng.randf_range(6.0, 12.0)
		WeatherType.WT.STORM:    radius_mul = _rng.randf_range(5.0, 9.0)
		WeatherType.WT.BLIZZARD: radius_mul = _rng.randf_range(7.0, 13.0)
		WeatherType.WT.DROUGHT:  radius_mul = _rng.randf_range(10.0, 18.0)
		WeatherType.WT.FOG:      radius_mul = _rng.randf_range(4.0, 8.0)
		WeatherType.WT.HEATWAVE: radius_mul = _rng.randf_range(8.0, 14.0)
		WeatherType.WT.MONSOON:  radius_mul = _rng.randf_range(8.0, 14.0)
		_:                       radius_mul = 8.0
	front.radius = _hex_size * radius_mul
	front.edge_seed = _rng.randf_range(0.0, 1000.0)
	# Phase E（方案 A）：与 _spawn_random_front 同步——寿命 ~×2、decay 减半。
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = _rng.randi_range(30, 56)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = _rng.randi_range(12, 22)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			# 强对流/热带暴雨：原 6-11 天 → 4-8 天，避免单地连下一周
			front.ttl_days = _rng.randi_range(4, 8)
			front.decay_per_day = 0.14
		WeatherType.WT.BLIZZARD:
			# 暴雪：原 8-14 天 → 5-10 天
			front.ttl_days = _rng.randi_range(5, 10)
			front.decay_per_day = 0.12
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			# RAIN：原 10-16 天 → 6-11 天
			front.ttl_days = _rng.randi_range(6, 11)
			front.decay_per_day = 0.07
	var origin := _world_bounds.position
	var size := _world_bounds.size
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((spawn_pos.y - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = _sample_terrain_wind(_map_for_spawn(world), world, spawn_pos, ny_spawn, _season_phase)
	if wind.length() > 0.05:
		var wind_axis := wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		# Phase E（方案 A）：行进距离 0.4 → 0.65 倍 radius/天。
		front.velocity = wind_axis * (front.radius * 0.65)
	else:
		var a := _rng.randf_range(0.0, TAU)
		front.axis = Vector2(cos(a), sin(a))
		front.stable_axis = front.axis
	_apply_front_shape_by_type(front)
	front.refresh_visual_lifecycle()
	return front
