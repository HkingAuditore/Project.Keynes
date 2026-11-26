class_name ClimateProfile
extends "res://scripts/data/climate_profile_models.gd"

# ══════════════════════════════════════════════════════════════════════
# [Continent shaping]
# ══════════════════════════════════════════════════════════════════════
@export_category("世界生成")
@export_group("大陆形态")

# Low-frequency noise warp applied to the distance-to-coast field.
@export var continent_warp_amp: float = 0.15

# Weighting between distance-field (smooth radial) and multi-octave noise
# when composing the final elevation. Should roughly sum to 1.0.
# [宏观地形增强 2026-06-19] dist 0.55→0.58 略增大陆主体连贯度；noise 0.45→0.40 降中高频
# 碎起伏，给低频 macro 让位（让大尺度结构读得出）。
@export var dist_field_weight: float = 0.58
@export var noise_weight: float = 0.40

# Ridge boost for mountain-range spines.
# [macro-relief 2026-06-19] 0.50→0.68：抬高山脉脊线，使大山系更高耸、海拔对比更强 →
# 配合加强后的 hillshade，宏观山脉/山系在地图上更醒目；同时更多脊线格越过 mountain_line
# 成为裸岩山地，山系面积更大、更连片。
# [宏观地形增强 2026-06-19] 0.68→0.80：山脉脊线更高耸，大山系在加强后的 macro 起伏上更醒目。
# [地貌真实性 2026-06-25] 0.80→0.60：实测(tile_data 0625)陆地约 22% 落在 land_h>0.70 的山地带，
# 远高于真实地球(几个百分点)，0.80 把过多陆地抬成极高地。回调到 0.60(介于历史 0.50/0.68)收窄
# 极高地占比，让"高原+丘陵+少量高峰"的山区过渡更自然。⚠ 单值可逆，须按新 CSV 复核高山占比。
@export var ridge_boost_amp: float = 0.60

# Meso-scale noise weight (between continent and micro detail).
# 注：2026-06-19 早些时候曾把它降到 0.12 想"消除破碎"，但用户反馈上一版（meso=0.40）的大陆
# 形状（数块大陆 + 点缀岛屿/群岛）才是想要的，降权反而把大陆合并成单块。已回退到 0.40。
# 真正"看不到河流/宏观地形"的根因是渲染层（河流 SDF 未上传 GPU、hillshade 偏弱），与此无关。
# [宏观地形增强 2026-06-19] 0.40→0.30：meso(乘 dist_field)是内陆中频"碎起伏"主因(实测大尺度
# block 内起伏>块间起伏→宏观弱)。温和下调减少内陆破碎、显出大平原；幅度远小于此前失败的 0.12
# (那会合并大陆)，配合 macro 大增仍保留多块大陆+群岛形状。
@export var meso_weight: float = 0.30

# [macro-relief 2026-06-19] 低频大尺度起伏权重（~4 周期/全宽）。meso(高频)负责海岸破碎/群岛
# 不动；macro 叠加大尺度高地/盆地 → 出现"大平原/大高地/大盆地"，并放大汇水盆地 → 长干流+支流。
# 实测根因：meso=400×高频把大陆切成 ~80 个微流域(最大汇水仅 66 格)，故河短、无宏观地形。
# 调大=宏观起伏更强(更多大山/大盆，河更长)；过大会在内陆生成大片新内海。0 = 关闭。
# [宏观地形增强 2026-06-19] 0.18→0.32：大尺度起伏翻近一倍，成为相对 meso 的主导项(占比
# 0.45→1.07)，直接制造大高原/大盆地/大平原洼地；负值大盆地若低于海平面且≥lake_min 还会自然
# 成"少而大的湖"(兼顾需求1)。过大(>0.4)会生成过多内海，0.32 为折中。
@export_range(0.0, 0.5, 0.01) var macro_relief_weight: float = 0.32

# Offshore (sub-sea) terrain amplitude.
# 注：2026-06-19 回退（曾降到 0.20）。近海隆起正是"点缀岛屿/群岛"的来源，用户想保留，恢复 0.45。
@export var offshore_amp: float = 0.45

# Edge falloff band: between START and END, elevation fades toward the edge
# of the map; DEPTH controls how deep the fade goes.
@export var edge_falloff_start: float = 0.80
@export var edge_falloff_end: float = 0.95
@export var edge_falloff_depth: float = 0.55

# Main-continent radius range (normalized 0..1).
@export var main_radius_min: float = 0.70
@export var main_radius_max: float = 0.90

# Satellite-island radius range.
@export var satellite_radius_min: float = 0.18
@export var satellite_radius_max: float = 0.40

# How many satellite islands spawn per main continent.
@export var satellites_per_main: int = 3

# Placement corridor for main continents (normalized 0..1 across map width).
@export var main_placement_min: float = 0.18
@export var main_placement_max: float = 0.82

# Placement corridor for satellite islands.
@export var satellite_placement_min: float = 0.08
@export var satellite_placement_max: float = 0.92

# Separation factors: 1.0 means "centers must be at least r1+r2 apart".
# Lower values allow overlap. Mains should not overlap; satellites may
# approach main edges.
@export var main_separation_factor: float = 0.85
@export var satellite_separation_factor: float = 0.55

# ══════════════════════════════════════════════════════════════════════
# [Moisture & precipitation]
# ══════════════════════════════════════════════════════════════════════
@export_group("水汽与降水")

# Ocean-adjacent cells receive this additional moisture bonus.
@export var coastal_moisture_boost: float = 0.20

# Windward upslope boost (orographic rainfall).
@export var orographic_boost: float = 1.2

# Leeward rain-shadow: if upstream elevation delta ≥ threshold, the cell's
# moisture is multiplied by factor (0 = completely dry; 1 = no shadow).
@export var rain_shadow_threshold: float = 0.13
@export var rain_shadow_factor: float = 0.65

# How many cells upwind to look back when detecting rain shadow.
@export var rain_shadow_lookback: int = 3

# Legacy global wind vector. DEPRECATED since Phase 6 — MapGenerator now
# queries WindBelt.wind_at(ny, phase) per cell. Retained for backwards
# compatibility; new ClimateProfile tres files may leave this at default.
@export var prevailing_wind: Vector2 = Vector2(1.0, 0.2)

## When true, WeatherSystem.advect / spawn samples the per-cell terrain-warped
## wind (HexCell.wind_vector) instead of the latitude-only baseline
## wind_field_buffer. This makes weather fronts feel mountains (deflection,
## piling, slow-down) without changing the baker. Set false to fall back to
## the legacy world.sample_wind() baseline for regression. Default true.
@export var weather_advect_use_wind_vector: bool = true

# ══════════════════════════════════════════════════════════════════════
# [Orbital Daily Climate]
# ══════════════════════════════════════════════════════════════════════
@export_category("模拟频率与预算")
@export_group("轨道相位与日气候")
@export_subgroup("兼容字段")

## Legacy compatibility only. Runtime climate no longer reads a four-season
## moisture table; precipitation/moisture must emerge from native fields.
@export var seasonal_moisture_scale: Array[float] = [1.0, 1.0, 1.0, 1.0]

# Temperature response amplitude used by the insolation chain:
# temp_delta = insolation_season_gain * insolation_dev * season_temp_amp.
# This is not an independent season cosine. Tune axial_tilt_deg,
# insolation_season_gain, day length, and thermal inertia for seasonal shape.
@export var season_temp_amp: float = 0.32
# Compatibility residue from the 2026-06-21 pass-A experiment. Runtime pass-A
# no longer consumes this multiplier; keeping the field avoids breaking older
# resources that still serialize it.
@export_range(1.0, 2.5, 0.05) var temp_land_continentality: float = 1.0

# Fallback orbital year length used by resource-only/native paths before a
# WorldClock is injected. At runtime WorldClock.days_per_year() is authoritative.
@export_range(1, 3660, 1) var orbital_days_per_year: int = 365

# Master switch for daily-continuous climate refresh. When true, MapGenerator
# updates each cell's current_state.temperature / moisture / snow_cover every
# day along the continuous season_phase ∈ [0, 4) curve, instead of the
# legacy "set once per season" hard step. Set false to fall back to the
# original season-aligned behavior (debug / regression).
@export var daily_climate_interpolation: bool = true

# ── Season-Refresh periodic driver (2026-05-18) ──────────────────────────
@export_subgroup("慢变量刷新")
# 慢变量批量重算的驱动方式。
#
# 设计背景：refresh_climate_daily 已经在每天连续更新温度 / 湿度 / 海冰，
# 而 season_refresh 12-stage 是给"植被演替 / 冰川 / 红树林 / biome 重判 /
# 反馈缓冲消费"等慢变量做批量重算的。游戏世界里温度 / 降水本就是连续涌现，
# 不存在"明确的季节切换瞬间"——但慢变量的批量重算本质上仍需要"周期性"地
# 进行，否则单纯每帧增量会出现 biome 边界抖动 + 反馈缓冲永远满。
#
# 新设计（默认）：SeasonRefreshSystem 自驱周期，每 season_refresh_period_ticks
# 个真实 SUS tick 启动一次 round（无视游戏速度档）。30 tick @ x1 速度 = 约
# 30 秒一次 round；@ x20 速度 = 约 1.5 秒一次 round。慢变量演化速率与玩家
# 在场时间挂钩，而非与游戏世界日数挂钩，避免高速档下慢变量被反复批量推进。
#
# 旧路径（legacy）：season_refresh 由 WorldClock.season_changed 信号触发
# （main.gd._on_season_changed → queue_season_refresh）。速度档 x20 下每
# ~15 ticks 就排一次 round，几乎 100% 占用主循环。打开 legacy_signal 时
# 回到这条路径，仅用于回归对照。
#
# 切换说明：
#   - legacy_signal=false 时 main.gd 仍然会调用 queue_season_refresh，但
#     SeasonRefreshSystem 不再消费它；新路径靠 period_ticks 自驱。
#   - legacy_signal=true 时 SeasonRefreshSystem 走 has_pending_season_refresh
#     检查（与旧行为完全一致），period_ticks 字段被忽略。
@export_range(1, 360, 1) var season_refresh_period_ticks: int = 30
@export var season_refresh_legacy_signal: bool = false

@export_subgroup("气候与天气频率")
# Stride (in days) for daily-continuous refresh: 1 = every day, N>1 = every
# N days (cheap downgrade if profiling shows the per-day pass too costly).
# Has no effect when daily_climate_interpolation == false.
# Used by ClimateDailySystem via StridePolicy.
#
# 2026-05-18：默认曾从 1 调到 2。理由：温度/湿度/海冰每天变化 < 1%，2 天间隔
# 玩家"理论上"无感；refresh_climate_daily 在 hot path 占用从 ran=24/30 → ran=12/30，
# 平均 0.74 → 0.37ms/tick。整体 p95 −0.5ms。
# 2026-05-25：默认改回 1。原因：玩家肉眼能明显感觉到海冰/雪线/水温视觉相位
# 滞后（shader 派生海冰直接采样 cell.temperature，stride=2 导致 +1 仿真日延迟，
# 叠加 dynamic_visual_atlas_upload_stride=2 后总延迟达 ~3 仿真日）。性能成本：
# refresh_climate_daily ran 12/30 → 24/30，p95 +0.5ms，可接受。如需严格性能
# 回归对照可在 Inspector / 具体 profile (.tres) 中改回 2。
@export_range(1, 8, 1) var daily_climate_refresh_stride: int = 1

@export var sea_ice_independent_system_enabled: bool = true
@export_range(1, 8, 1) var sea_ice_daily_stride: int = 1

# DEPRECATED：旧 sea_ice_atlas_upload job/system 已退役，主海冰视觉由
# dyn_atlas_smooth.A / shader 派生。本字段仅为旧 .tres 资源兼容保留，
# 不再驱动任何生产调度。
@export_range(1, 8, 1) var sea_ice_atlas_upload_stride: int = 2

@export_range(1, 30, 1) var weather_albedo_stride: int = 10
# 2026-05-19 vegetation-survival-rebalance v2：植被 pass 频率从 10 → 5，
# 配合 vitality_change_rate 提升后让漂移更密集地写回 vitality / streak。
@export_range(1, 30, 1) var weather_vegetation_dynamics_stride: int = 5
@export_range(1, 30, 1) var weather_feedback_stride: int = 10
@export_range(1, 30, 1) var natural_resource_daily_stride: int = 1

@export_subgroup("视觉上传频率")
# Enum atlas upload updates terrain/biome/cover/vegetation lookup textures after
# simulation changes. It still only runs when dirty; this stride controls how
# often a pending dirty upload is allowed to consume one axis.
@export_range(1, 8, 1) var enum_atlas_upload_stride: int = 2

# Dynamic visual atlas upload updates dynamic_cell/ecology/smooth/ice atlases.
# Default 1 keeps temperature/snow/ice visuals aligned with the daily climate
# pass. Raise to 2+ only for profiling-driven GPU/main-thread savings.
@export_range(1, 8, 1) var dynamic_visual_atlas_upload_stride: int = 1

# ─── DataCore（已删除字段）─────────────────────────────────────────
# use_data_core / use_data_core_weather / use_data_core_climate 已在
# dots-flag-prune-pr1（2026-05-22）随 hot-path 折叠一同删除——DataCore
# 已恒走单路径（World 始终 bind，weather/climate 始终走 DCWorld view 镜像）。
# CLI --data-core / --no-data-core / --data-core-climate 等开关同步已废弃，
# 调用点会 push_warning 提示 deprecated。

const NATIVE_MODE_OFF: int = 0
const NATIVE_MODE_SHADOW: int = 1
const NATIVE_MODE_ACTIVE: int = 2

@export_group("原生管线")

# Native top-level migration modes. OFF preserves the current pass-by-pass
# path, SHADOW runs native diagnostics beside legacy paths, ACTIVE is allowed
# to replace the corresponding GDScript orchestration when the native probe
# reports readiness.
# dots-total-cpp（2026-06-18）：地图生成 C++ 化已通过逐字段 A/B parity（base +
# post_base 全字段 mismatch=0），默认切到 ACTIVE，generate() 走 native 生成路径。
@export_range(0, 2, 1) var native_generation_mode: int = NATIVE_MODE_ACTIVE
@export_range(0, 2, 1) var native_daily_sim_mode: int = NATIVE_MODE_OFF
@export_range(0, 2, 1) var native_runtime_graph_mode: int = NATIVE_MODE_ACTIVE
@export_range(0, 2, 1) var native_render_prepare_mode: int = NATIVE_MODE_OFF
@export var native_environment_runtime_enabled: bool = false
@export_range(1, 30, 1) var native_daily_sim_stride: int = 1
@export_range(1, 8, 1) var native_environment_runtime_stride: int = 1
@export_range(0.25, 8.0, 0.05) var native_daily_perf_target_ms: float = 1.0
# Native daily round 跨 tick 错峰执行。默认 false：整轮在同一个 day_changed
# tick 内原子跑完（per-tick 峰值高，下游永远读到完整数据）。
# 设 true：让一轮的 slice batch 摊到多个 tick，每 tick 只跑
# native_daily_max_slices_per_tick 个 batch（默认 1，即"A→B→C→A…"轮转），
# 把 per-tick 峰值压低，给其它系统让出帧预算。代价：采样日的权威结果会在
# 后续 tick 才提交。该延迟必须由 native_daily_commit_lag_budget_days 约束并记录
# 到 report/CSV；超过预算视为契约违约，而不是悄悄累积误差。
@export var native_daily_spread_across_ticks: bool = false
@export_range(1, 30, 1) var native_daily_commit_lag_budget_days: int = 10
@export_range(1, 32, 1) var native_daily_max_slices_per_tick: int = 1
# Optional spread-mode optimization: keep only true dynamic/JIT boundaries as yield nodes
# and let C++ batch more adjacent native graph nodes. Default off until perf/bitequal soak.
@export var native_daily_coarse_spread_yield_enabled: bool = false
# Mobile P2 perf gate: split native_daily weather into schedule-visible C++ subnodes.
# Default false keeps the historical monolithic weather pass as the normal path.
@export var native_daily_split_weather_node_enabled: bool = false
# Native daily node-level cell range slicing. Default off: C++ graph continuation keeps
# historical full-node execution unless a profile explicitly opts in. The node allow-list
# is intentionally narrow and report-driven; start with already range-aware passes, then
# expand after bit-equal/perf validation.
@export var native_daily_node_range_enabled: bool = false
@export_range(128, 4096, 64) var native_daily_node_range_cells: int = 768
@export var native_daily_node_range_nodes: PackedStringArray = PackedStringArray(["climate_pass_a", "ocean_water", "ocean_land", "wind_air", "wind_surface"])
@export var native_daily_ocean_thread_variant_enabled: bool = false
@export_range(0, 16, 1) var native_daily_ocean_thread_tasks: int = 0
@export_range(1.0, 30.0, 0.5) var native_daily_sea_ice_spread_dt_cap_days: float = 2.0
@export var native_daily_finalizer_slice_enabled: bool = false
@export_range(128, 4096, 64) var native_daily_finalizer_slice_cells: int = 768
@export var native_daily_finalizer_native_publish_enabled: bool = false
@export_enum("dense", "sparse_safe", "sparse_perf") var native_daily_finalizer_write_mode: String = "sparse_perf"
@export_range(0.0, 0.01, 0.0001) var native_daily_finalizer_temp_epsilon: float = 0.0005
@export_range(0.0, 0.01, 0.0001) var native_daily_finalizer_tta_epsilon: float = 0.0005
@export_range(0.0, 0.01, 0.0001) var native_daily_finalizer_thermal_epsilon: float = 0.0005
@export_range(0.0, 1.0, 0.01) var native_daily_finalizer_sparse_max_dirty_ratio: float = 0.45
# 错峰执行的"让预算"门禁（2026-06）。spread 模式下 native_daily_sim 不再 must_run，
# 而是遵守 frame_budget：当同 tick 更早跑的慢变量重算器（如 season_refresh 的
# 11-stage round，priority 50 先跑且单 stage ~3ms 就吃满 2ms 预算）已耗尽预算时，
# native 本 tick 让出（不再无视预算硬叠加 → 消除 season+native 的 ~5.8ms 撞峰）。
# starve_ticks 是防饿死保险：连续被预算挤掉这么多 tick 后强制跑一个 batch，确保
# 在极端持续抢占下 native 仍能推进。默认 16（> season round 的 ~11 stage，所以一个
# season round 期间 native 完整让位、不撞峰；round 结束后立即恢复每 tick 推进）。
@export_range(0, 64, 1) var native_daily_spread_starve_ticks: int = 16
@export var native_shadow_diff_enabled: bool = true
# Controlled handoff gate for the climate round state owner. When false, reports
# stop at native_ready; when true, the native daily snapshot may report
# native_active while Godot/MapData boundary intents still remain explicit.
@export var native_climate_round_active_owner_enabled: bool = false
## ACTIVE daily bundles use compact native lifecycle capsules. Full snapshots
## remain available to SHADOW/debug callers and older extensions.
@export var native_daily_compact_state_capsule_enabled: bool = true
## Publish native visual mutations as one indexed batch when the ABI is present.
@export var native_daily_sparse_visual_publish_enabled: bool = true
# Controlled handoff gate for weather transaction authority. When false,
# weather reports stop at native_ready after visible publish has been proven;
# when true, native daily may report native_active while Godot texture/front
# presentation remains an explicit visual boundary.
@export var native_weather_transaction_active_owner_enabled: bool = false
# Controlled handoff gate for ocean physical lifecycle authority. Native owns
# round/stage lifecycle first; Godot visual raster/upload remains boundary.
@export var native_ocean_physical_active_owner_enabled: bool = false
# Controlled handoff gate for season refresh simulation authority. Native/B+
# owns cadence and dirty simulation intents; atlas/detail upload remains boundary.
@export var native_season_refresh_active_owner_enabled: bool = false
# Final retirement gate for legacy daily production/fallback paths. Keep false
# until SHADOW/A-B/ACTIVE soak proves graph coverage complete.
@export var native_daily_legacy_daily_production_retired: bool = false

# ─── ViewAdapter / DCSystemScheduler（已删除字段）─────────────────────
# use_world_view_adapter / use_dc_system_scheduler 已在 dots-flag-prune-pr1
# （2026-05-22）随 hot-path 折叠一同删除——ViewAdapter 恒走 World 路径，
# DCSystemScheduler 恒挂载（reads/writes 拓扑校验始终启用）。
# 注：feature_flags.gd 上 use_world_view_adapter 仍保留为 sentinel-true 让
# DCFeatureFlags.is_on() 在字段缺失时正确返回 true；is_known/find/owner_of
# API 行为与原先一致。

# Native-normal simulation budget profile. Strict 1ms can still be restored per
# resource, but the default favors completing lightweight DOTS/native transactions
# in the same fast tick under a 2ms envelope.
@export_group("每帧预算")
@export var sim_strict_budget_enabled: bool = false
@export_range(0.25, 1600.0, 0.05) var sim_frame_budget_ms: float = 2.0
@export_range(0.10, 800.0, 0.05) var sim_slice_budget_ms: float = 0.75
## 2026-05-19 方案 B：dynamic visual atlas 上传 phase 的单 tick budget。
## 0.50 → 1.5ms：配合 MAX_CELLS_PER_TICK=4096，让 dynamic/ecology/smooth/ice 四个 phase
## 的每一个都能在单 tick 内扫完（典型 64×64=4096 cells），把雪量响应从约 40 仿真日
## 缩短到约 8 仿真日（stride=2 × 4 phase）。tick 内峰值多花约 1ms，但 stride 之间不付代价。
@export_range(0.10, 800.0, 0.05) var sim_upload_slice_budget_ms: float = 1.5
@export_range(0.25, 1600.0, 0.05) var sim_budget_warn_ms: float = 2.0

@export_group("调度错峰")
@export var sim_stagger_enabled: bool = true
@export_range(1, 16, 1) var sim_stagger_bucket_stride: int = 8
@export_range(1, 8, 1) var sim_stagger_climate_stride: int = 2
@export_range(0, 15, 1) var sim_stagger_climate_phase: int = 1
@export_range(0, 15, 1) var sim_stagger_ocean_phase: int = 0
@export_range(0, 15, 1) var sim_stagger_native_environment_phase: int = 0
@export_range(0, 15, 1) var sim_stagger_dynamic_visual_phase: int = 2
@export_range(0, 15, 1) var sim_stagger_enum_atlas_phase: int = 4
@export_range(0, 15, 1) var sim_stagger_sea_ice_phase: int = 6

# ─── Phase F / dots-full-migration §F.1-F.6 hot pass C++ flags（已删除）─
# 以下 10 个 flag 在 dots-flag-prune-pr1（2026-05-22）一并删除，调用点折叠为
# 恒走 ext != null + has_method 探测分支（C++ 不可用时 hot pass 内部仍透明
# fallback 到 GDScript，不需 caller 端 flag）：
#   use_gdext_weather_field / ocean_water / ocean_land / climate_pass_b /
#   sea_ice / sea_ice_atlas_prepare / transpiration / weather_front /
#   weather_distribute / weather_summary
# weather_system.gd 内部的 _use_gdext_weather_field/distribute/summary 私有
# 字段保留（仅作为 commit 重算 saved/restore 工具），赋值改为恒走 ext+has_method
# 探测；_use_gdext_weather_front 是死字段，已删除。
# Block B（Master 手册 §4）：ocean_currents wind solver C++ 化（已删除 flag）。
# use_gdext_wind_field / use_gdext_physical_circulation / use_gdext_season_refresh
# 已在 dots-flag-prune-pr1 round 2（2026-05-22）随 hot-path 折叠一同删除——
# 三个 hot pass 恒走 ext != null + has_method 探测分支，C++ 返回 fallback 或
# ext 未 bind 时透明 fallback 到 GDScript。
# ─── Phase B+（已删除）：use_gdext_season_round 已固化为单路径 ──

# ─── dots-slp-psi-cpp（已删除 flag）— physical-circulation final push ──
# use_gdext_slp_field / use_gdext_psi_solver 已在 dots-flag-prune-pr1 round 2
# （2026-05-22）随 hot-path 折叠一同删除——stage 1 (SLP) 与 stage 3+4+5
# (PSI) 恒走 ext != null + has_method 探测分支，C++ 返回 fallback 时透明
# fallback 到 GDScript。
@export_enum("off", "balanced", "perf") var psi_early_exit_mode: String = "perf"

# ─── Phase A.1（dots-total-cpp roadmap，已删除）：fronts SoA 路径 ───
# use_gdext_fronts_soa 已随 hot-path 折叠一同删除——weather summary fronts
# 路径恒走 SoA Dict 探测（字段缺失时自动回退 Array[Dict]）。

# ─── Phase A.3（dots-total-cpp roadmap，已删除）：常驻 knobs RID ─────────
# use_gdext_resident_knobs 已随 hot-path 折叠一同删除——weather_system 恒走
# ClassDB.class_exists('KnobsHandle') 探测，Class 不可用时透明 fallback 到
# GDScript build_*_knobs。

# ─── DOTS-Final-Push stage_b 合并（已删除 flag）──────────────────────────# 默认 false：上线前需完成 SAME_SOURCE A/B 30 tick numeric drift ≤ 1e-5 验收。
# C++ 不可用时入口分支会自动 fallback 到 GDScript 并打印一次 UNAVAILABLE。
# stride 字段沿用现有 weather_albedo_stride / weather_vegetation_dynamics_stride
# / weather_feedback_stride，无需新增。
# ─── Phase F stage_b 三件套（已删除）─────────────────────────────────
# use_gdext_albedo / use_gdext_vegetation_dynamics / use_gdext_climate_feedback
# 已在 dots-flag-prune-pr1（2026-05-22）随 hot-path 折叠一同删除。
# 三段独立 C++ 化路径默认恒走 ext != null + has_method 探测分支；
# stage_b_combined 入口仍保留（合并入口 + 三段独立 ext 探测互补共存）。
# refresh_daily_stage_b 走单 cpp call run_stage_b_pass。
# use_gdext_stage_b_combined 已在 dots-flag-prune-pr1 round 2（2026-05-22）随
# hot-path 折叠一同删除——stage_b 合并入口恒走 ext + has_method 探测分支。
# ─── plan/weather-refresh-cpp-all（PR-2 gd-facade-merge）─────────────────────
# weather refresh daily 顶层一体化 C++ pass。打开后 map_generator.refresh_weather_daily
# 走单 cpp call run_weather_refresh_daily_pass，把 field_solve / distribute /
# summary / cyclone_wake / stage_b 五段串调一次完成，消除 GDScript ↔ C++ 间 5 次
# Variant round-trip。前置条件：use_gdext_weather_field / use_gdext_weather_distribute /
# use_gdext_weather_summary / use_gdext_stage_b_combined 各独立路径已 ACTIVE
# （或至少 ext bound + has_method 通过）。任何环节缺失 / rc<0 → 自动回退到现路径
# （refresh_daily_stage_a + refresh_daily_stage_b 两段链），保证 bit-equal 兜底。
# 默认 false：上线前需完成 SAME_SOURCE A/B soak 验收。
# use_gdext_weather_refresh_daily 已在 dots-flag-prune-pr1 round 2（2026-05-22）随
# hot-path 折叠一同删除——weather refresh daily 顶层一体化入口恒走 ext + has_method
# 探测分支，任一环节缺失或 rc<0 透明回退到现路径（refresh_daily_stage_a +
# refresh_daily_stage_b 两段链）。
# ─── DOTS-Total-CPP（plan/dots-total-cpp Phase A.2，已删除）─────────────────
# use_gdext_unified_fast_tick 已在 dots-flag-prune-pr1（2026-05-22）随 hot-path
# 折叠一同删除——unified fast tick 注入 weather_knobs 进 native_daily_bundle
# 的路径是新功能（验收前 default=false），本轮重构按"删未上线灰度"策略一并清理。
# ─── DOTS-Final-Push 与 atlas pack（已删除）─────────────────────────────────
# use_gdext_enum_atlas_pack 已在 dots-flag-prune-pr1（2026-05-22）一并删除——
# enum_atlas_upload pack C++ 化已恒走单路径。

# ─── Phase C.1（plan/dots-total-cpp，已删除）：System schedule graph 静态 DAG ──
# use_gdext_system_schedule 已在 dots-flag-prune-pr1（2026-05-22）一并删除——
# 调度路径恒走单路径（C++ 端的 11 段 if-chain fallback 仍保留作为内部实现细节，
# 不再需要 caller 端 flag 控制）。

# ─── DOTS-Total-CPP（plan/dots-total-cpp，已删除）：剩余 GDScript 残余下沉 C++ ─
# use_gdext_ocean_currents_pixel / use_gdext_weather_field_pixel /
# use_gdext_sea_ice_atlas_pack 已在 dots-flag-prune-pr1（2026-05-22）随
# hot-path 折叠一同删除——所有像素 baker 与 atlas pack 已恒走 C++ 单路径
# （C++ 不可用时 baker 内部仍透明 fallback 到 GDScript，不需 caller 端 flag）。

# ─── Dirty-Push Atlas Encode（plan/dirty-push-atlas-encode，已删除 flag）──────
# 4 张运行期 atlas（dynamic_cell / ecology_visual / dyn_atlas_smooth /
# ice_state）baker 改造：sim 端 setter / DCWorld write API 漏斗式推送
# cell-level dirty mask。dirty_push_enabled / cpp_atlas_encode_enabled /
# cpp_atlas_pipeline_enabled 已在 dots-flag-prune-pr1 round 2（2026-05-22）一并
# 删除——baker 恒走 DCWorld.read_and_clear_dirty_mask() 拿 dirty cells（mask 不
# 可用时透明 fallback 到 all_cells）；DCWorldExt encode_* / run_atlas_pipeline_step
# 恒走 ext + has_method 探测分支（ext 缺失时自动回退到 GDScript mask 路径或
# 旧 GD 4-phase 状态机）。
# ─── plan/sim-2ms-simd-dirty-budget（2026-05-21，已删除 flag）：SIMD 内核 + 线程兜底 ──────
# use_gdext_pass_b_simd / use_gdext_ocean_water_simd / use_gdext_ocean_land_simd /
# use_gdext_thread_fallback 已在 dots-flag-prune-pr1 round 2（2026-05-22）随 hot-path
# 折叠一同删除——SIMD 内核与 thread fallback 已固化为 C++ 端内部实现细节
# （C++ 内部根据 CPU 特性 / 数据规模自动选择 scalar/SIMD/threaded 三档执行路径），
# 不再需要 caller 端 flag 控制。自愈路径（dirty-rect 每 64 tick 全图回退）仍在
# baker 内部保持。

# ─── plan/sim-2ms-simd-dirty-budget（2026-05-21，已删除 flag）：enum atlas upload 节流 ───
# Godot 4 没有 partial texture upload API（issue godotengine/godot#65762 未解决），
# 整图 RGB8 (~1.8MB) GPU upload 是 1.27ms 瓶颈。use_atlas_dirty_throttle 已在
# dots-flag-prune-pr1 round 2（2026-05-22）随 hot-path 折叠一同删除——节流策略
# 已下沉为 baker 内部实现细节（达阈值才 image_create + texture.update，
# 视觉残影由 64-tick 自愈 + 强制 flush 钩子兜底），不再需 caller 端 flag。

# ─── plan/sim-2ms-simd-dirty-budget 任务 7（已删除 flag）：dynamic_visual_atlas 编码 ─
# use_gdext_dynamic_atlas_terminal_dirty 已在 dots-flag-prune-pr1 round 2（2026-05-22）
# 随 hot-path 折叠一同删除——cpp run_atlas_pipeline_step 4 phase 恒走 cpp 现行
# dirty 路径（dirty_indices 比对 + value-diff + 1-跳邻居膨胀），不再提供 A/B
# 对照 kill-switch。

## ─── Phase 1A（plan/sus-cpp-port，已删除）：SUS 调度外壳 native 化总开关 ──
## use_gdext_sus_scheduler 已在 dots-flag-prune-pr1（2026-05-22）随 hot-path
## 折叠一同删除——SusScheduler/DCSystemScheduler 上的同名字段、10 处 hot-path if
## 与失败 fallback 写回均同步清理，恒走 C++ 单路径（C++ 不可用时内部仍透明
## fallback 到 GDScript Job.run_slice，不需 caller 端 flag）。

# ─── PR-2.passA-unblock（已删除）──────────────────────────────────────────
# use_gdext_climate_pass_a 已在 dots-flag-prune-pr1（2026-05-22）一并删除——
# Pass-A C++ 化已恒走 ext != null + has_method 探测分支。

# ─── PR-2.3a HexCell facade（已删除）──────────────────────────────────────
# use_hexcell_facade 已在 dots-flag-prune-pr1（2026-05-22）一并删除——bind_world
# 入口恒挂 facade，cell.<热字段> setter/getter 透传 World SoA 已是单路径行为。

# ─── DEPRECATED ocean_current_refresh_seasons（已删除）────────────────────
# E 类废字段 ocean_current_refresh_seasons 已在 dots-flag-prune-pr1（2026-05-22）
# 一并删除——MapGenerator 早已迁移到 SUS OceanCurrentsJob，本字段长期处于
# warning sentinel 状态，本轮统一清理。请使用下方 ocean_currents_period_ticks /
# ocean_currents_slice_count 配置 ocean current 切片节奏。

# SUS OceanCurrentsJob — period (in days) of one full ocean current solve.
# Default 1 keeps ocean stream-function coupled to the now-daily wind/SLP field;
# pixel atlas rebake is still season-gated, so this affects simulation state, not GPU upload cadence.
@export_group("洋流频率")
@export_range(1, 360, 1) var ocean_currents_period_ticks: int = 1

# SUS OceanCurrentsJob — number of slices each round is split into. Each
# slice processes ⌈total_pixels / slice_count⌉ pixels. Default 120 slices
# means one slice every 2 days for a 240-day period. Aim for per-slice
# elapsed ≤ 30ms (ocean_currents_slice + upwelling_slice combined).
#
# 实测调优记录（1024×606 = 620k 像素）：
#   - slice_count=10 → 每片 62k 像素 → 266ms（严重卡顿）
#   - slice_count=60 → 每片 10k 像素 → ~44ms（可接受）
#   - slice_count=120 → 每片 5k 像素 → ~22ms（更平滑）
@export_range(1, 240, 1) var ocean_currents_slice_count: int = 120

# OceanCurrentsJob C++ raster sub-slice 数（plan/ocean-raster-subslice 2026-05-22）。
# use_gdext_ocean_currents_pixel=true 时，run_ocean_field_rasterize_full 把整图
# 620k 像素的 ~4.7ms hot loop 拆成 N 个 sub-tick（每 sub-tick 一个像素区间），
# 复用现有 _next_pixel_idx 切片游标 + commit-defer 框架。
#
# 实测（1024×606 = 620544 像素，C++ raster 总耗时 ~4.7ms）：
#   - 1  → 一次性吃完，单 slice 4.7ms（旧行为，留作 kill-switch）
#   - 4  → 每片 ~155k 像素 ≈ 1.2ms（推荐：与 weather_refresh fronts_12 / phys_wind 同量级）
#   - 8  → 每片 ~78k 像素 ≈ 0.6ms（更激进，但 round 长度翻倍占用 SUS 调度位）
#
# 注意：sub-slice 仅在 _need_pixel_this_round=true 的轮次生效（每季最多一轮），
# 不影响 phys_solve 的 7 stage 切片节奏。
@export_range(1, 16, 1) var ocean_pixel_subslice_count: int = 4

# 弱机/移动端物理解周期缩放（item ④「架构·弱机」）。
# ocean_currents_job._apply_device_period_scale() 读取：>1 时把 wind_period_ticks /
# ocean_period_ticks / period_ticks 整体放大该倍率（每 2–3 日而非每日跑一轮物理），
# 降低单帧物理尖峰出现的频率。仅改变"多久跑一轮"，不改变单阶段工作量（单片 magnitude
# 由 per-cell 切片负责，那是需持久化中间状态的 native 重构，本字段不动）。
# 移动端自动 ×2；弱 PC 可在 profile 设 2.0~3.0。默认 1.0（桌面不动）。
@export_range(1.0, 4.0, 0.5) var ocean_period_scale_weak: float = 1.0

# ══════════════════════════════════════════════════════════════════════
# [Hydrology]
# ══════════════════════════════════════════════════════════════════════
@export_category("地表与生态")
@export_group("水文")

# Top (1 - percentile) flux cells become river sources; native generation then
# carves each accepted source down its downhill path to water.
# [river-rework 2026-06-19] ⚠ 已弃用：分位法只能标出 land 的固定比例(0.72→占全图 10% 成网)，
# 无论怎么调都在"填满大陆的网"和"贴海岸短段"之间二选一。河道选择已改用下方
# river_channel_init_cells(汇水面积阈值)。此值保留仅为兼容，不再影响河道。
@export var river_flow_percentile: float = 0.72

# [river-rework 2026-06-19] 河道起始阈值：上游汇水格数 ≥ 此值才成河（地貌学 channel-initiation）。
# 天然生成稀疏树状河网，干流(汇水多)宽、支流(汇水少)细。实测(150×100 地图)：
#   12→~480 格(偏密)  16→~300 格(适中)  20→~200 格(稀疏)  24→~140 格(很稀疏)
# 调小=河更多更密；调大=河更少更稀。配合 macro_relief 放大流域后，同阈值河会更长更分级。
@export var river_channel_init_cells: int = 16
# [density-fix 2026-06-30] 6→10：原 headwater 阈值过低，用 1/2.67 的更低阈值主动 trace
# 支流到主河道，加剧河网密集。上调后支流补充更克制（仍低于 channel_init=16）。
@export_range(1, 64, 1) var river_headwater_init_cells: int = 10
@export_range(0.0, 1.0, 0.01) var river_headwater_min_land_h: float = 0.30

# Minimum accepted land cells in a rendered river path. Shorter runoff paths
# still contribute flow, but are not drawn as standalone streams.
# terrain-overhaul: 18→8 让更多中短河流成形（配合统一水汽场后流量分布更分散）。
# ⚠ 2026-06-19: 8→5。降低最短河长门槛，让中短支流也能绘出，水网更密。
@export var hydro_river_min_length: int = 5

# Priority-Flood depression lakes: keep only basins with enough area/depth so
# noise pits become drained land instead of one-cell ponds.
# ⚠ 2026-06-19: 18→8。降低成湖最小面积，让中小型内陆湖泊得以保留(此前几乎无 LAKE)。
@export var hydro_lake_min_cells: int = 8
@export var hydro_lake_min_depth: float = 0.018
@export var hydro_lake_min_volume: float = 0.22

# Max iterations for depression / pit filling.
@export var pit_fill_max_iters: int = 100

# Low-frequency lake seed noise creates fewer, larger inland basins instead of
# many one-cell ponds on large maps.
# [湖泊少而大 2026-06-19] freq 0.07→0.05：更低频→高噪声区更大更连续→单个湖盆更大(≥lake_min
# 才会被 5b 回填逻辑保留为湖，否则填平)；threshold 0.62→0.60：让每个种子区足够大成块。
@export var lake_seed_freq: float = 0.05
@export var lake_seed_threshold: float = 0.60

# Lake cell elevation depression and min-interior distance from coast.
# [湖泊少而大 2026-06-19] 0.04→0.10：种子下沉更深，保留下来的湖盆更明确成"湖"(深蓝、不被
# 误判为浅滩 COAST)，视觉上是真正的内陆湖而非低洼浅水。
@export var lake_seed_depth: float = 0.10
@export var lake_seed_min_interior: float = 0.12

# ══════════════════════════════════════════════════════════════════════
# [Vegetation → climate feedback (moisture donor)]
# ══════════════════════════════════════════════════════════════════════
@export_group("植被水汽反馈")
# Per-terrain moisture donation (positive = humid, negative = dessicating).
# STEPPE is deliberately absent from _vegetation_donor_amount's match
# (treated as neutral 0.0).

@export var veg_forest_donor: float = 0.06
@export var veg_swamp_donor: float = 0.10
@export var veg_grassland_donor: float = 0.02
@export var veg_desert_donor: float = -0.04
@export var veg_jungle_donor: float = 0.08
@export var veg_taiga_donor: float = 0.05
@export var veg_savanna_donor: float = 0.02
@export var veg_oasis_donor: float = 0.08
@export var veg_delta_donor: float = 0.06
@export var veg_salt_flat_donor: float = -0.03

# Transpiration flux: per day, at most outflow_rate% moisture leaves to
# neighbors (spread across 6), and self_rate% stays as closure.
@export var transpiration_outflow_rate: float = 0.025
@export var transpiration_self_rate: float = 0.015

## Elevation-based decay applied to vegetation→neighbor moisture donation in
## _apply_vegetation_feedback. Effective factor = clampf(1 - elevation * decay,
## 0.1, 1.0). 0 = legacy behavior (no decay); 0.5 = high mountains contribute
## ~half as much as low-land forests of the same biome. Default 0.5.
@export_range(0.0, 1.0, 0.05) var veg_feedback_elev_decay: float = 0.5

# Albedo feedback: Δtemp = (reference_albedo - albedo) × albedo_temp_gain.
# reference_albedo = 0.30 is the neutral "bare ground" reference.
@export var reference_albedo: float = 0.30
@export var albedo_temp_gain: float = 0.025

# ══════════════════════════════════════════════════════════════════════
# [Ecosystem vitality & succession]
# ══════════════════════════════════════════════════════════════════════
@export_group("生态活力与演替")
# Per-day vitality change rate; low/high thresholds; and number of
# consecutive days required to trigger succession up/down. Values mirror
# the original Phase 8 / Milestone 4 constants in map_generator.gd.

# 2026-05-19 vegetation-survival-rebalance v2：rate 从 0.004 → 0.015
# （≈ 67 天可从 0 到 1），让暴雨/极旱在数周内即可看到 vitality 漂移。
# 死区同步从 (0.4, 0.6) 收窄到 (0.48, 0.52)，避免大量 cell 永远卡在 dv=0。
@export var vitality_change_rate: float = 0.010         # per day, at most ±0.010 (~100 days from 0 to 1)
# 2026-07-22：退化 streak 由“濒死才计时”改为“存在更适合候选且 target<0.45”。
# earth-like 原生 cadence 每次 vegetation pass 约代表 100 游戏日，200 日门槛要求
# 至少两个连续不适宜样本，避免一次离散采样翻转，同时让多年漂移能够发生演替。
@export var vitality_low_threshold: float = 0.45        # low target + better candidate → downgrade streak
@export var vitality_high_threshold: float = 0.75       # above → upgrade streak
@export var succession_degrade_days: int = 200          # two earth-like native vegetation samples
@export var succession_upgrade_days: int = 200
@export_range(0.0, 1.0, 0.01) var vegetation_degrade_reset_target: float = 0.75
@export_range(0.0, 1.0, 0.01) var vegetation_low_vitality_damping_threshold: float = 0.40
@export_range(0, 365, 1) var vegetation_succession_cooldown_days: int = 30
# Asymmetric drift: negative drift (compat ≤ 0.4) is multiplied by this harshness.
# Positive drift (compat ≥ 0.6) stays at 1.0. Compat ∈ (0.4, 0.6) → dead zone (dv = 0).
@export var compat_harshness: float = 0.35
@export_range(0.0, 1.0, 0.05) var vegetation_weather_penalty_scale: float = 0.25
@export var plant_water_balance_weight: float = 0.35
@export var plant_soil_buffer_weight: float = 0.30
@export var plant_drought_penalty: float = 0.25
@export_range(0.0, 1.0, 0.01) var vegetation_min_suitability: float = 0.18
@export_range(0.0, 0.01, 0.000001) var vegetation_tie_epsilon: float = 0.000001
@export_range(0.0, 0.25, 0.005) var vegetation_none_hysteresis: float = 0.02
@export var succession_min_compat_gain: float = 0.06
@export var vegetation_stress_enabled: bool = true
@export_range(1, 365, 1) var vegetation_stress_memory_days: int = 30

# Long-term base_moisture drift from eco_score (Phase 8).
@export var eco_drift_amp: float = 0.012                # max ±0.012 / year
@export var eco_score_clamp: float = 0.5                # calm-period dampener

# ══════════════════════════════════════════════════════════════════════
# [Emergent climate coupling — Phase E]
# ══════════════════════════════════════════════════════════════════════
@export_category("气候与天气模型")
@export_group("涌现气候耦合")
# Master switches for the "Emergent Climate Coupling" rework. All four
# default to true (new behavior). Flipping any one to false routes the
# corresponding pass back to the legacy hard-coded path, so old saves and
# regression baselines stay reproducible.
#
# 1. emergent_season_enabled
#    When true, refresh_climate_daily uses a continuous insolation function
#    (latitude × hemisphere × continuous day-length) driven by season_phase
#    instead of branching on integer season_index. refresh_seasonal is
#    triggered only when season_phase crosses an integer boundary, doing
#    incremental biome refresh instead of "every 30 days hard rewrite".
#    When false, falls back to the legacy season_index hard-step path.
@export var emergent_season_enabled: bool = true

# 2. enable_local_climate_coupling
#    When true, refresh_climate_daily layers three local perturbations on
#    top of the latitude/season baseline:
#      • albedo  : -albedo_factor * snow_cover, -vegetation_cooling * foliage
#      • coastal : +COASTAL_HEAT_LEAK * neighbor.ocean_current_anomaly
#                  (×1.5 in winter phase)
#      • landform: valley/basin diurnal amplification, modulated by phase
#    Moisture also gets evaporation / transpiration / per-day rain-shadow.
#    When false, climate_daily reverts to pure latitude/elevation/season.
@export var enable_local_climate_coupling: bool = true

# 3. emergent_weather_coupling
#    When true, WeatherSystem advection reads WindBelt.wind_at(ny, phase)
#    per day, decay scales by "front type vs local temp/moist band match",
#    spawn probability is biased by local 1-ring temp/moisture gradient,
#    and front type is jointly decided by (temp band, moisture band, phase).
#    When false, falls back to uniform-random spawn / fixed-season velocity.
@export var emergent_weather_coupling: bool = true

# 4. fast_slow_layering_enabled
#    When true, _apply_weather_to_map_feedback_pass runs at end of each day
#    and accumulates daily weather effects into slow-layer feedback buffers
#    (soil_moisture, vegetation_growth_pressure) with very small weights;
#    refresh_seasonal consumes & decays these buffers. WeatherSystem is
#    forbidden from writing base_* / landform / terrain / cover directly
#    (enforced via MapData.sample_slow_layer in debug builds).
#    When false, the feedback pass is skipped and base_* are only written
#    by refresh_seasonal/yearly as in the legacy path.
@export var fast_slow_layering_enabled: bool = true

# Sub-knobs for the feedback pass (consumed by _apply_weather_to_map_feedback_pass
# and refresh_seasonal). All values intentionally small to keep "weather → map"
# coupling on a slow timescale.
@export var weather_to_soil_gain: float = 0.014          # daily ↑ on soil_moisture per unit precip
@export var weather_to_vegetation_gain: float = 0.012    # daily ↑ on growth_pressure per unit precip
# weather → base_moisture 直接反馈(降水抬升/干旱压低局地气候湿度)。代码保留(map_generator.gd +
# world_ext.cpp 三镜像)，默认 0 关闭 —— 2026-06-21 部分回滚：与 A(vapor 去锚定)一同撤下，先单独
# 验证 C(风场 synoptic)对流动性的贡献，避免反馈耦合干扰分离实验。需要时设 >0 重新启用。
@export var weather_to_base_moisture_gain: float = 0.0
@export var feedback_decay: float = 0.5                  # multiplier applied at season boundary
@export var feedback_per_day_clamp: float = 0.005        # |Δ| per day clamp (≤ 0.5% of base)

# Runtime moisture uses the generated background only as a static geographic anchor.
# Seasonal solar forcing must reach it through evaporation, wind/ocean transport,
# precipitation, soil water, and the rolling water balance, never through a direct
# insolation multiplier in Pass-A.
@export_range(0.0, 1.0, 0.01) var runtime_moisture_base_relax_rate: float = 0.24
@export var weather_direct_moisture_enabled: bool = false
@export_range(0.0, 1.0, 0.01) var runtime_moisture_weather_vapor_weight: float = 0.12
@export_range(0.0, 2.5, 0.01) var runtime_moisture_precip_weight: float = 0.78
@export_range(0.0, 2.5, 0.01) var runtime_moisture_soil_weight: float = 1.82
@export_range(0.0, 2.5, 0.01) var runtime_moisture_soil_dry_weight: float = 2.71
@export_range(0.0, 2.5, 0.01) var runtime_moisture_water_balance_weight: float = 1.04
@export_range(0.0, 2.5, 0.01) var runtime_moisture_water_balance_dry_weight: float = 1.55

# Sea-ice daily pass tunables (replace the old hard-step _apply_sea_ice_pass).
@export_group("海冰")
# 2026-05-19 Plan-C 三次调参（用户报告"南北极同时白 + 不化"）：
# 现象：截图里两极同时大量永久冰盖，夏季不消退。
# 进一步诊断：bootstrap 给两极满冰；运行时 _insol_dev 在两极 mean ≈ 0.05~0.10
# 不会触发 1e-4 兜底，理论上夏至 temp ≈ 0.48 应该化冰，但用户单次 sea_ice pass
# 的 d_frac per-call 没乘 dt，且 melt_rate=0.30 << freeze_rate=1.50 (5:1)，
# 夏季融化能力比冬季冻结能力慢得多 → 一年净累积，开局后越冻越厚。
# 2026-05-26：在保持温度驱动的前提下收窄面积；冻结慢于融化，低浓度冰不再快速翻地形。
# [海冰冻融重标定 2026-06-28] 实测(CSV)冷水最暗桶 mean_ice 仅 0.49、全盆地在 0↔0.98 双稳跳变：
# 旧 freeze_rate(0.40) << melt_rate(1.45) 且滞回带太窄(form0.06~melt0.11)→冻结太慢、夏冬不对称致抖动、
# 极地不饱和。抬高 freeze、降低 melt 不对称，并下方拉宽滞回带(form 0.14 / melt 0.22)，
# 目标"极地核心常年饱和(>0.9)+海冰边缘季节进退"，而非整盆地全冻全融。起步值，待 dt>1 探针迭代。
@export var sea_ice_freeze_rate: float = 1.0             # k_freeze per "degree" below T_form（0.40→1.0：堆冰至阈值 ~60d→~10d）
@export var sea_ice_melt_rate: float = 0.95              # k_melt per "degree" above T_melt（1.45→0.95：削弱融化不对称）
@export var sea_ice_terrain_threshold: float = 0.72      # frac at which terrain flips to SEA_ICE
@export var sea_ice_terrain_hysteresis: float = 0.18     # flip back when frac < threshold - hyst
@export var sea_ice_neighbor_contagion: float = 0.035    # extra k_freeze if any neighbor frac >= 0.6
@export var sea_ice_solar_gate_enabled: bool = true      # high current insolation blocks tropical ice growth
@export var sea_ice_freeze_insol_low: float = 0.22       # freeze gate is fully open below this insolation
@export var sea_ice_freeze_insol_high: float = 0.45      # freeze gate is fully closed above this insolation
@export var sea_ice_solar_melt_start: float = 0.28       # current insolation above this adds melt pressure
@export var sea_ice_solar_melt_gain: float = 0.90        # [2026-06-28] extra melt per insol unit above start（1.35→0.90：极昼太阳融化更温和，保极地核心）
@export_range(0.0, 0.50, 0.005) var sea_ice_daily_delta_cap: float = 0.070
@export_range(0.0, 0.20, 0.005) var sea_ice_edge_mix_rate: float = 0.035
# 2026-06-27 CSV 复核显示厚冰在本半球夏季仍被日照 melt shielding 保护过强。
# 这里提高厚冰最小日照暴露，让极昼可稳定消融边缘/季节性厚冰，但仍保留永久极地核心。
@export_range(0.0, 0.50, 0.005) var sea_ice_min_thick_ice_solar_exposure: float = 0.32

# Local-coupling tunables (consumed when enable_local_climate_coupling = true).
@export_group("局地气候耦合")
@export var coastal_heat_leak_winter_boost: float = 1.5
# [climate-zone-fix P2] 沿海海洋性调温（让温带海洋性 Cfb 涌现）。
# pass_a 对陆地 cell 按"距海指数衰减"的 maritime 因子缩放 season_offset，缩小沿海年较差
# (冬暖夏凉)：season_offset *= (1 - maritime_season_damp * maritime_factor[i])，其中
#   maritime_factor[i] = exp(-dist_ocean_cells[i] / maritime_decay_cells) ∈ (0,1]，海岸≈1、内陆→0。
# maritime_season_damp = 0 → 关闭(退回纯纬度大陆性，与历史逐位一致)。
# 该机制独立于 legacy 标量 temp_land_continentality（后者仍被 pass_a 忽略，故
# native_pass_a_legacy_season_offset_test 不变）。同源接线：sync run_climate_pass_a /
# run_climate_pass_a_thread / async _async_pass_a_kernel_pure 三路共用同一 maritime_factor 数组。
# [2026-06-28夜] 维持 0.45：headless A/B(tmp_maritime_eval) 证实温度侧已饱和——damp 0.45 已使
#   ~48 个中纬沿海格达「凉夏(Twarm<0.60)+低年较差(<0.26)」，再加到 0.55 仅 +1 格、沿海年较差
#   只再降 5.8%。Cfb 计数的真正瓶颈是「降水型」：这 ~48 格里只有 9 格同时是全年均匀降水
#   (0.40<swet<0.62)，其余为夏旱(地中海)或夏雨(季风)。扩 Cfb 应走 P3 降水均匀化(冬雨)标定，非加大阻尼。
@export_range(0.0, 0.9, 0.01) var maritime_season_damp: float = 0.45
@export_range(1.0, 12.0, 0.5) var maritime_decay_cells: float = 4.0
@export var snow_albedo_cooling: float = 0.04            # extra cooling per unit snow_cover
@export var vegetation_cooling: float = 0.025            # extra cooling per unit foliage cover
# climate-loop-closure Phase 4.1：海冰反照率→温度反馈。Pass B 对水域 cell 按
# sea_ice_fraction 施加降温 d_temp = -sea_ice_albedo_cooling * sea_ice_frac，闭合
# "更多海冰→更冷→更多海冰"的温和正反馈(此前海冰是单向温度→冰，缺反照率回写)。
# Pass B 在海冰 pass 之前跑，读到的是前一日 sea_ice_frac(1 日滞后，稳定)。2026-06-27
# CSV 显示 0.03 仍让厚冰水域春季锁冷，海冰峰值相对日照低谷滞后 2-3 个月；
# 默认降到 0.01，仅保留弱反馈，避免把季节性边缘冰拖到春末/夏初。设 0 关闭(A/B 对照)。
@export_range(0.0, 0.3, 0.005) var sea_ice_albedo_cooling: float = 0.01
@export var evaporation_gain: float = 0.06               # moisture gain per warm water-neighbor
@export var landform_diurnal_amp: float = 0.015          # valley/basin diurnal amplification

# ── Ocean current → moisture coupling (cold-current coastal desert) ──
# Multiplier applied to d_evap when neighbor water has cold/warm anomaly:
# d_evap *= clampf(1 + ocean_moisture_coupling_gain * avg_neighbor_anomaly, 0.0, 2.0).
# Cold current (anomaly < 0) → suppresses evaporation; warm current (anomaly > 0) → boosts.
# Set 0.0 to disable (legacy behavior). Default 1.5 means a -0.2 anomaly gives ×0.7 d_evap.
@export_range(0.0, 5.0, 0.05) var ocean_moisture_coupling_gain: float = 1.5

# Long-term base_moisture drift driven by sustained ocean anomaly on the
# coastal land cells. Per-day delta is clamped to ±feedback_per_day_clamp;
# annual ceiling ≈ ocean_moisture_drift_gain × 365 ≈ 0.012 * 365 = sane.
# This is what makes Atacama / Namib-type cold-coast biomes emerge over
# years of in-game time without rewriting base_moisture every day.
# Set 0.0 to disable (legacy behavior).
@export_range(0.0, 0.05, 0.0005) var ocean_moisture_drift_gain: float = 0.004

# Weather-event spawn bias from cold/warm coastal anomaly. When the spawn
# candidate cell sees average neighbor-water anomaly < 0 (cold current),
# RAIN/STORM/MONSOON spawn weight is multiplied by max(0.1, 1 + bias × anomaly);
# warm anomaly boosts the same types up to ×(1 + bias). BLIZZARD/FOG are
# unaffected. Set 0.0 to disable.
@export_range(0.0, 3.0, 0.05) var ocean_weather_spawn_bias: float = 1.2
