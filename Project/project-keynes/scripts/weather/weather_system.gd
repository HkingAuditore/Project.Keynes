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
	if _front_spawn == null:
		_front_spawn = DCWeatherFrontSpawn.new(self)
	if _native_bridge == null:
		_native_bridge = DCWeatherNativeBridge.new()
	# dots-monolith-split §1.2：field_solver 实例化。已接管天气场 slice hot loop
	# （begin_slice/run_slice/commit/_solve_weather_field）；本类对应函数仅薄转发。
	if _field_solver == null:
		_field_solver = DCWeatherFieldSolver.new(self)
	if _feedback == null:
		_feedback = DCWeatherFeedback.new(self)
	if _summary_builder == null:
		_summary_builder = DCWeatherSummaryBuilder.new(self)
	else:
		_summary_builder.reset()


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
	return _weather_field_enabled

func is_weather_field_solve_active() -> bool:
	return _field_solver._field_slice_active

func begin_weather_field_solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true, for_worker_knobs_only: bool = false) -> void:
	# dots-monolith-split §1.2 / PR-6：切片初始化主体已搬迁到
	# scripts/weather/field_solver.gd::begin_slice()。本侧仅作为外部 caller
	# (map_generator.gd / weather_refresh_job 等 SUS job) 的薄转发入口。
	_field_solver.begin_slice(map, world, season_idx, climate_anomaly, season_phase, count_day, for_worker_knobs_only)

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
func run_synoptic_advance_pass(map: MapData, world: WorldData) -> float:
	if _data_core_world_ext == null or not _use_gdext_weather_field:
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


func build_field_knobs_for_worker(map: MapData, world: WorldData,
		season_idx: int, climate_anomaly: float,
		season_phase: float) -> Dictionary:
	if _data_core_world_ext == null or map == null or world == null:
		return {}
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return {}
	_current_map_for_tick = map
	begin_weather_field_solve(map, world, season_idx, climate_anomaly,
		season_phase, true, true)
	if not _field_solver._field_slice_fast_indexed:
		# fast-indexed 是 solve 的硬前置，缺了它生产也会 fallback。
		_clear_weather_field_slice_state()
		_current_map_for_tick = null
		return {}
	# The resident/native path stores this Dictionary on the slice state.  Make
	# a shallow copy before clearing that state below; otherwise
	# `_clear_weather_field_slice_state()` empties the very Dictionary returned
	# to the worker, leaving stage_weather silently unconfigured every day.
	var knobs: Dictionary = _field_solver._field_slice_native_knobs.duplicate(false) \
		if not _field_solver._field_slice_native_knobs.is_empty() \
		else _build_weather_field_knobs(map, world, n_cells)
	_clear_weather_field_slice_state()
	_current_map_for_tick = null
	return knobs


# begin_weather_field_solve 的 refresh_convergence 按 _field_solve_tick 调用次数取
# 奇偶；worker 的 capture 会因失败重试或其他调用多走一步，所以 worker 侧改按
# 捕获日取同一个 stride。
func convergence_refresh_due_on_day(day: int) -> bool:
	return posmod(day - 1, maxi(1, _field_convergence_refresh_stride)) == 0


# ACTIVE climate authority：worker 侧 distribute stage 的 knobs 入口。
#
# 生产路径经 build_unified_fast_tick_weather_knobs 一次拿 field+distribute+summary
# 三组，但那条会先调 begin_weather_field_solve 初始化 field slice state；worker
# 权威下生产的 weather 段是被抑制的，那份 state 没人消费。这里只暴露 distribute
# 段，与生产共用同一个 builder —— 那些 snow/flood 阈值有一半是 builder 里的硬编码
# 常量，在 map_generator 侧重抄一份等于给它们开第二个漂移入口。
#
# 无副作用：_build_weather_distribute_knobs 只读 map 与 profile 派生的标量，
# 唯一的写是 _dist_acc_snow_cache / _dist_pre_cover_cache 的重建，而那是幂等的。
func build_distribute_knobs_for_worker(map: MapData, n_cells: int) -> Dictionary:
	if map == null or n_cells <= 0:
		return {}
	return _build_weather_distribute_knobs(map, n_cells)


# 调用 C++ 端 run_weather_distribute_pass。返回 Dictionary {"elapsed_ms", "cover_dirty",
# "changed_cells"(PackedInt32Array), "accumulated_snow_days"/"pre_snow_cover"(已被 C++ 改写)}。
# elapsed_ms < 0 表示 precondition 失败，调用方走 GDScript fallback。
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
func _front_diagnostic_kind(temp_advection: float) -> int:
	return WeatherDiagnostics.front_diagnostic_kind(self, temp_advection)

func _front_diagnostic_counts(fronts: Array) -> Dictionary:
	return WeatherDiagnostics.front_diagnostic_counts(self, fronts)

# ─── Phase A.1 helper：把 C++ 返回值优先走 SoA 路径，缺失 / flag off 时
# fallback 到 Array[Dict] 路径。集中在一个 helper 里供 summary 与 combined
# 两处复用，避免重复 dispatch 逻辑分叉。
func _sync_profile_weather_knobs(cp: Resource) -> void:

	if _native_bridge == null:
		_native_bridge = DCWeatherNativeBridge.new()
	_native_bridge._sync_profile_weather_knobs(self, cp)

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

	# dots-monolith-split §1.2 / PR-6：250 行 dead code 已删除；逻辑入口
	# 整体下沉到 scripts/weather/field_solver.gd::solve()，内部走
	# begin_slice → 循环 run_slice → commit。

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
	return WeatherDiagnostics.prev_vapor_cached(self, cell, map, prev_vapor)

# dots-monolith-split §1.2 / PR-1：搬迁到 field_solver.gd（薄转发）。
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
	if ext != null:
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
	if _data_core_world_ext != null:
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
