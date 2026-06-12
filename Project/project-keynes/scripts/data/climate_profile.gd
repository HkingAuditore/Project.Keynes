# climate_profile.gd
# Data-driven configuration for a single "world generation preset" — the
# full set of numeric knobs that MapGenerator consumes to shape a world.
#
# Swapping a different ClimateProfile lets designers produce radically
# different worlds (earth-like / ice-age / desert-world / archipelago)
# without any code changes.
#
# Field naming mirrors the original const names in map_generator.gd
# (lowercased) to make the migration mechanical and greppable.
#
# Consumers: MapGenerator (the one and only). Future: a preset-selection UI.

class_name ClimateProfile
extends Resource

# ══════════════════════════════════════════════════════════════════════
# [Continent shaping]
# ══════════════════════════════════════════════════════════════════════
@export_category("世界生成")
@export_group("大陆形态")

# Low-frequency noise warp applied to the distance-to-coast field.
@export var continent_warp_amp: float = 0.15

# Weighting between distance-field (smooth radial) and multi-octave noise
# when composing the final elevation. Should roughly sum to 1.0.
@export var dist_field_weight: float = 0.55
@export var noise_weight: float = 0.45

# Ridge boost for mountain-range spines.
@export var ridge_boost_amp: float = 0.50

# Meso-scale noise weight (between continent and micro detail).
@export var meso_weight: float = 0.40

# Offshore (sub-sea) terrain amplitude.
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
@export var orographic_boost: float = 1.5

# Leeward rain-shadow: if upstream elevation delta ≥ threshold, the cell's
# moisture is multiplied by factor (0 = completely dry; 1 = no shadow).
@export var rain_shadow_threshold: float = 0.16
@export var rain_shadow_factor: float = 0.68

# How many cells upwind to look back when detecting rain shadow.
@export var rain_shadow_lookback: int = 2

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
# 新设计（默认）：SeasonRefreshJob 自驱周期，每 season_refresh_period_ticks
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
#     SeasonRefreshJob 不再消费它；新路径靠 period_ticks 自驱。
#   - legacy_signal=true 时 SeasonRefreshJob 走 has_pending_season_refresh
#     检查（与旧行为完全一致），period_ticks 字段被忽略。
@export_range(1, 360, 1) var season_refresh_period_ticks: int = 30
@export var season_refresh_legacy_signal: bool = false

@export_subgroup("气候与天气频率")
# Stride (in days) for daily-continuous refresh: 1 = every day, N>1 = every
# N days (cheap downgrade if profiling shows the per-day pass too costly).
# Has no effect when daily_climate_interpolation == false.
# Used by SUS RefreshClimateDailyJob via StridePolicy.
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

# Stride (in days) for the sea-ice atlas GPU upload (SeaIceAtlasUploadJob).
# Daily Sim SoA Refactor 阶段 1：把原先内嵌在 refresh_climate_daily 末尾、每日 ~105ms
# 的 GPU 上传摘出，单独走这个 stride。海冰每日变化 < 5%，stride=2 玩家不可察觉延迟。
# 1 = 每日上传（debug / regression）；2 = 每 2 日（推荐默认，吞吐 -50%）；
# 4+ = 极慢 GPU / 远程显卡 fallback。
@export_range(1, 8, 1) var sea_ice_atlas_upload_stride: int = 2

# Fast-tick perf opt (A): stride for the weather / feedback chain in
# MapGenerator.refresh_daily (_apply_transpiration_pass / _apply_albedo_pass /
# _apply_vegetation_dynamics / _apply_weather_to_map_feedback_pass + GPU
# rebakes). 1 = run every day (legacy), N>1 = run every N days and on skip
# days reuse the last active fronts snapshot. Auto-adjusted by main.gd on
# speed change (x1→1, x5→4, x20→8). Manual override via Inspector is allowed.
# Used by SUS WeatherRefreshJob via StridePolicy.
@export_range(1, 8, 1) var weather_refresh_stride: int = 1
# When true, main.gd may retune weather_refresh_stride on speed changes
# (x1=1, x5=4, x20=8). Disable this when the profile should be the single
# source of truth for weather cadence.
@export var weather_refresh_auto_stride_by_speed: bool = true
@export_range(1, 30, 1) var weather_albedo_stride: int = 10
# 2026-05-19 vegetation-survival-rebalance v2：植被 pass 频率从 10 → 5，
# 配合 vitality_change_rate 提升后让漂移更密集地写回 vitality / streak。
@export_range(1, 30, 1) var weather_vegetation_dynamics_stride: int = 5
@export_range(1, 30, 1) var weather_feedback_stride: int = 10

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
@export_range(0, 2, 1) var native_generation_mode: int = NATIVE_MODE_OFF
@export_range(0, 2, 1) var native_daily_sim_mode: int = NATIVE_MODE_OFF
@export_range(0, 2, 1) var native_render_prepare_mode: int = NATIVE_MODE_OFF
@export var native_environment_runtime_enabled: bool = false
@export_range(1, 8, 1) var native_daily_sim_stride: int = 1
@export_range(1, 8, 1) var native_environment_runtime_stride: int = 1
@export_range(0.25, 8.0, 0.05) var native_daily_perf_target_ms: float = 1.0
@export var native_shadow_diff_enabled: bool = true

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

# ══════════════════════════════════════════════════════════════════════
# [Hydrology]
# ══════════════════════════════════════════════════════════════════════
@export_category("地表与生态")
@export_group("水文")

# Top (1 - percentile) flux cells become rivers.
@export var river_flow_percentile: float = 0.78

# Max iterations for depression / pit filling.
@export var pit_fill_max_iters: int = 100

# Noise frequency + threshold for placing lake seeds.
@export var lake_seed_freq: float = 0.18
@export var lake_seed_threshold: float = 0.55

# Lake cell elevation depression and min-interior distance from coast.
@export var lake_seed_depth: float = 0.04
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
# 2026-05-18：演替门槛大幅放宽，让暴雨/极旱/连续不利气候有机会在 1.5 个月内触发
# 可见的植被退化/升级。原 (0.15 / 0.90 / 180 / 360) 几乎需要 9 个月不间断的恶劣
# 气候才能触发一次演替，玩家完全感受不到天气对地块的中长期影响。
# 新默认：低/高阈值放宽 (0.25 / 0.75)，天数缩短到 (45 / 90)；
# earth_like.tres 中 succession_upgrade_days 的覆盖值也同步调低（91）。
@export var vitality_low_threshold: float = 0.25        # below → downgrade streak（only truly dying cells count）
@export var vitality_high_threshold: float = 0.75       # above → upgrade streak
@export var succession_degrade_days: int = 45           # ~1.5 个月的低 vitality
@export var succession_upgrade_days: int = 90           # ~3 个月的高 vitality
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
@export var weather_to_vegetation_gain: float = 0.008    # daily ↑ on growth_pressure per unit precip
@export var feedback_decay: float = 0.5                  # multiplier applied at season boundary
@export var feedback_per_day_clamp: float = 0.005        # |Δ| per day clamp (≤ 0.5% of base)

# Sea-ice daily pass tunables (replace the old hard-step _apply_sea_ice_pass).
@export_group("海冰")
# 2026-05-19 Plan-C 三次调参（用户报告"南北极同时白 + 不化"）：
# 现象：截图里两极同时大量永久冰盖，夏季不消退。
# 进一步诊断：bootstrap 给两极满冰；运行时 _insol_dev 在两极 mean ≈ 0.05~0.10
# 不会触发 1e-4 兜底，理论上夏至 temp ≈ 0.48 应该化冰，但用户单次 sea_ice pass
# 的 d_frac per-call 没乘 dt，且 melt_rate=0.30 << freeze_rate=1.50 (5:1)，
# 夏季融化能力比冬季冻结能力慢得多 → 一年净累积，开局后越冻越厚。
# 2026-05-26：在保持温度驱动的前提下收窄面积；冻结慢于融化，低浓度冰不再快速翻地形。
@export var sea_ice_freeze_rate: float = 0.55            # k_freeze per "degree" below T_form
@export var sea_ice_melt_rate: float = 1.45              # k_melt per "degree" above T_melt
@export var sea_ice_terrain_threshold: float = 0.68      # frac at which terrain flips to SEA_ICE
@export var sea_ice_terrain_hysteresis: float = 0.12     # flip back when frac < threshold - hyst
@export var sea_ice_neighbor_contagion: float = 0.06     # extra k_freeze if any neighbor frac >= 0.6
@export var sea_ice_solar_gate_enabled: bool = true      # high current insolation blocks tropical ice growth
@export var sea_ice_freeze_insol_low: float = 0.30       # freeze gate is fully open below this insolation
@export var sea_ice_freeze_insol_high: float = 0.55      # freeze gate is fully closed above this insolation
@export var sea_ice_solar_melt_start: float = 0.45       # current insolation above this adds melt pressure
@export var sea_ice_solar_melt_gain: float = 0.65        # extra melt per insolation unit above start
@export_range(0.0, 0.50, 0.005) var sea_ice_daily_delta_cap: float = 0.08

# Local-coupling tunables (consumed when enable_local_climate_coupling = true).
@export_group("局地气候耦合")
@export var coastal_heat_leak_winter_boost: float = 1.5
@export var snow_albedo_cooling: float = 0.04            # extra cooling per unit snow_cover
@export var vegetation_cooling: float = 0.025            # extra cooling per unit foliage cover
# climate-loop-closure Phase 4.1：海冰反照率→温度反馈。Pass B 对水域 cell 按
# sea_ice_fraction 施加降温 d_temp = -sea_ice_albedo_cooling * sea_ice_frac，闭合
# "更多海冰→更冷→更多海冰"的温和正反馈(此前海冰是单向温度→冰，缺反照率回写)。
# Pass B 在海冰 pass 之前跑，读到的是前一日 sea_ice_frac(1 日滞后，稳定)。系数取
# 小值并配阻尼(每日重算非累积)避免失控；设 0 关闭(回归 legacy 无反馈，A/B 对照)。
@export_range(0.0, 0.3, 0.005) var sea_ice_albedo_cooling: float = 0.06
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

# Grid weather field solver. When enabled, WeatherSystem computes per-hex
# vapor/cloud/precip/instability fields and derives weather type directly from
# local climate, terrain, wind and ocean signals. Legacy fronts remain only as a
# visual/compatibility summary.
@export_group("天气场求解")
@export var weather_field_enabled: bool = true
@export_range(0, 2, 1) var weather_field_advect_steps: int = 2
@export_range(0.0, 0.5, 0.01) var weather_field_diffusion: float = 0.04
@export_range(0.0, 2.0, 0.01) var weather_condensation_gain: float = 0.85
@export_range(0.0, 1.0, 0.01) var weather_precip_decay: float = 0.48
@export_range(0.0, 1.0, 0.01) var weather_precip_carryover_max: float = 0.12
@export_range(0.0, 1.0, 0.01) var weather_vapor_precip_sink: float = 0.58
@export_range(0.0, 1.0, 0.01) var weather_vapor_relax_rate: float = 0.08
@export_range(0.0, 1.0, 0.01) var weather_orographic_lift_cap: float = 0.35
@export_range(0.0, 1.0, 0.01) var weather_wet_terrain_precip_damping: float = 0.22
@export_range(0.0, 1.0, 0.01) var weather_lake_precip_damping: float = 0.35
@export_range(0.0, 1.0, 0.01) var weather_lake_evap_scale: float = 0.35
@export_range(0.0, 1.0, 0.01) var weather_extreme_precip_soft_cap: float = 0.24
@export_range(0.0, 1.0, 0.01) var weather_extreme_precip_softness: float = 0.35
@export_range(0.0, 0.10, 0.005) var weather_temp_anomaly_cap: float = 0.025
@export_range(0.0, 2.0, 0.01) var weather_orographic_lift_gain: float = 0.35
@export_range(0.0, 2.0, 0.01) var weather_convergence_gain: float = 0.25
@export_range(1, 12, 1) var weather_convergence_refresh_stride: int = 4
@export var weather_cold_precip_as_blizzard: bool = true
@export_range(0.0, 0.12, 0.005) var weather_snow_classification_margin: float = 0.03
@export_range(0.0, 2.0, 0.01) var weather_ocean_evap_gain: float = 0.40
@export_range(1, 12, 1) var weather_component_summary_limit: int = 12
@export_range(100, 2400, 50) var weather_field_slice_cells: int = 500
@export var weather_transition_enabled: bool = true
@export_range(0.0, 1.0, 0.01) var weather_transition_alpha_rate: float = 0.35

# ══════════════════════════════════════════════════════════════════════
# [Physical Wind & Ocean Circulation — hex-domain solver]
# ══════════════════════════════════════════════════════════════════════
@export_group("物理风场与洋流")
# 把风场/洋流从纯 ny-only 像素函数升级为"二维海陆耦合 + 海盆环流"的
# 物理化简化模型。求解粒度落在 hex 中心；像素 buffer 由 hex 场光栅化得到，
# 与现有 shader (wind_field_buffer / ocean_current_buffer / sea_ice_tex / etc) 完全兼容。
#
# 1) physical_circulation_enabled
#    总开关。true → MapBaker 在风场/洋流烘焙路径里启用 hex 物理求解器
#    （日照/热惯性 → SLP → 压力梯度/地转风 + 沿海热力环流 → ψ 求解 → 西边界强化 → 沿岸 Ekman 上升流 → 光栅化）。
#    false → 走旧的 WindBelt.wind_at + Ekman ±45° + 海岸高度梯度 + 噪声路径，
#    用于回归对照与低端硬件 fallback。默认 true。
@export var physical_circulation_enabled: bool = true
@export_range(1, 60, 1) var wind_circulation_period_ticks: int = 1
@export_range(0.0, 1.0, 0.01) var slp_response_rate: float = 0.55
@export_range(0.0, 0.20, 0.005) var slp_synoptic_amp: float = 0.075
@export_range(0.0, 0.20, 0.005) var slp_moist_low_weight: float = 0.12
@export_range(0.0, 1.0, 0.01) var wind_response_rate: float = 0.75
@export_range(0.0, 0.20, 0.005) var wind_synoptic_amp: float = 0.075
# Debug isolation: true forces physical wind solve to output WindBelt only,
# bypassing pressure-gradient/coastal-thermal/synoptic/old-wind inertia.
@export var wind_belt_only_debug: bool = false
@export_range(0.0, 1.0, 0.01) var wind_thermal_slp_weight: float = 0.28
@export_range(0.0, 1.0, 0.01) var slp_ice_high_weight: float = 0.12
@export_range(0.0, 1.0, 0.01) var slp_snow_high_weight: float = 0.06

# 2) enable_terrain_aware_wind
#    当 physical_circulation_enabled = true 时附加生效。true → 物理化风场求解器
#    在山地 cell 处对结果向量做地形偏转修正（背风侧降压、山脊阻挡 + 转向），
#    直接调制 cell.wind_vector，不新增独立 buffer。false → 跳过地形修正，
#    只保留纬度背景风 + SLP 压力梯度响应。默认 true。
@export var enable_terrain_aware_wind: bool = true

# 3) enable_ocean_heat_transport
#    当 physical_circulation_enabled = true 时附加生效。true → MapBaker 在水域
#    hex 上用 SOR 迭代求解 ∇²ψ = -curl(τ)/β（β-plane Stommel 简化）+ 西边界强化，
#    再 u = -∂ψ/∂y, v = ∂ψ/∂x 回算 cell.ocean_current，得到闭合海盆环流 + 黑潮 / 湾流型东岸强流。
#    false → 跳过 ψ 求解，直接用纬度风场 + Ekman ±45° 写出 hex ocean_current
#    （仍保留 hex 域，只是不解全局环流），作为零成本 fallback。默认 true。
@export var enable_ocean_heat_transport: bool = true
@export_range(0.0, 1.0, 0.01) var ocean_current_response_rate: float = 0.60
@export_range(0.0, 1.0, 0.01) var ocean_thermal_current_weight: float = 0.12
@export_range(0.0, 1.0, 0.01) var ocean_density_cold_weight: float = 0.22
@export_range(0.0, 1.0, 0.01) var ocean_density_ice_weight: float = 0.12

# 4) enable_wind_heat_transport
#    climate-loop-closure Phase 1.1：把风致热平流（气团段 + 地表段，对称复刻洋流
#    热输运）接入 ClimateDailySystem 的逐日 sliced round。true → 每日在 ocean_land
#    之后、sea_ice 之前跑 _wind_air_mass_pass + _wind_surface_pass，让上风方向温度
#    被混合（空间梯度平滑 + 内陆海洋性调节）。false → 跳过（回归到无横向热输运的
#    legacy 行为）。默认 true。
#    注：legacy 非切片 wrapper refresh_climate_daily 仍按 enable_ocean_heat_transport
#    统一控制风温段；本开关只管 sliced 生产路径。
@export var enable_wind_heat_transport: bool = true

# ══════════════════════════════════════════════════════════════════════
# [True insolation-driven climate — Phase F]
# ══════════════════════════════════════════════════════════════════════
@export_group("真实日照")
# Deprecated compatibility field. Runtime climate no longer has a switchable
# independent season signal: C++/DOTS Pass-A always derives climate forcing
# from sub-solar latitude, daily insolation, day length, thermal inertia,
# pressure/wind, and moisture. This bool is kept only for old UI/shader wiring
# that still expects the property to exist.
#
# Setting this false must not re-enable legacy independent-cosine climate
# forcing. Use axial_tilt_deg / insolation_season_gain / thermal inertia
# parameters to tune seasonal amplitude.
@export var true_insolation_enabled: bool = true

# Axial tilt (obliquity). 23.5° ≈ Earth. Lower values → milder seasons even
# at high latitudes; higher → more extreme. Used to compute subsolar_lat.
@export_range(0.0, 45.0, 0.5) var axial_tilt_deg: float = 23.5

# Gain applied to (insol_now - insol_mean) absolute deviation when deriving
# the temperature seasonal offset: season_offset = gain × dev × season_temp_amp.
# C++ native + GDScript SoA 双路径同步生效。
# dev 已改为绝对日射差(insol_now−insol_mean ∈ [−1,+1])，不再分数化。
# 配合 thermal_inertia_land=0.35 + delta_cap=0.15，中纬度实际温差 ≈ 增益×0.12。
# gain=2.0 → 40°N 冬夏温差 ~0.27（基线 63%），肉眼明确可见。
@export_range(0.5, 4.0, 0.05) var insolation_season_gain: float = 0.6

# ══════════════════════════════════════════════════════════════════════
# [Climate-Weather 2ms Budget — governance switches]
# ══════════════════════════════════════════════════════════════════════
@export_category("DOTS 优化开关")
@export_group("气候天气预算治理")
# 5 个独立总开关，分别控制 climate-weather-2ms-budget plan 的优化路径上线。
# 全部默认 false → 走 legacy 路径，行为 0 漂移；任意一个翻 true → 在下一次
# round 入口安全切换到 SoA / 稀疏 / 低频 / 部分上传新路径。
#
# 1) use_soa_pipeline
#    总开关。true → climate Pass A/B、ocean_water/ocean_land、sea_ice、transp
#    通过 MapData SoA 数组（temp_arr / moisture_arr / ...）读写而不是 cell.*；
#    sub-pass 完成后由调度器调用 MapData.flush_soa_to_cells() 同步给 UI / Baker。
#    false → 走原有 cell.temperature 等强类型成员路径（legacy）。
#    依赖：MapData.has_soa() == true（rebuild_soa_from_cells 已被 bake_world 调用）。
@export var use_soa_pipeline: bool = true

# 2) use_sparse_climate
#    在 use_soa_pipeline = true 的前提下启用 climate_dirty_mask 增量更新。
#    Pass A 写温度时按 epsilon=1/512 自动标 dirty；Pass B / 下游稀疏 sub-pass
#    仅遍历 dirty + 1 跳邻居。dirty_ratio 在 [50/N, 0.8] 之外时自动回退全图遍历。
#    季节切换日 / 每 30 日强制全图 dirty。false → SoA 路径仍跑全图。
@export var use_sparse_climate: bool = true

# 3) use_sparse_weather
#    与 use_sparse_climate 平行的 weather field 稀疏开关。weather_field_solver
#    与 advect / distribute 仅跑 weather_dirty_mask 标记的 cell（由当日 fronts 的
#    AABB 膨胀 N 跳生成）。false → weather 路径全图遍历不变。
@export var use_sparse_weather: bool = false

# 4) use_low_freq_ocean_psi
#    OceanCurrentsJob 默认 stride 升到 30 个 game-day（约一月一次）；季节切换日
#    强触发；下游 ocean_water/ocean_land 读双缓冲快照。false → 走原来的
#    ocean_currents_period_ticks 设置（默认 16 + 120 切片）。
@export var use_low_freq_ocean_psi: bool = false
@export_range(0.01, 1.0, 0.01) var ocean_psi_source_scale: float = 0.08
@export_range(0.0, 2.0, 0.01) var ocean_current_scale: float = 0.16
@export_range(0.05, 1.414, 0.005) var ocean_current_max_magnitude: float = 0.65
@export var ocean_decoupled_visual_raster: bool = true
@export var ocean_visual_rebake_drop_stale: bool = true

# 5) use_partial_atlas_upload
#    enum_atlas_upload / sea_ice_atlas_upload 改 tile dirty 部分上传：
#    维护 32×32 tile 粒度 tile_dirty_mask，仅上传变化 tile，单 tick 上限 8 tile。
#    false → 维持现有整张纹理上传（legacy）。
@export var use_partial_atlas_upload: bool = true

# Continuous day-length amplitude (how much the "day length" term modulates
# insolation away from pure cos_zenith). 0 → pure sun-angle; higher → longer
# summer days contribute more. Matches the existing _INSOLATION_DAYLEN_AMP
# const, exposed here for per-profile tuning.
@export_range(0.0, 1.0, 0.01) var insolation_daylen_amp: float = 0.35

## Native astronomy heat gain applied to per-cell insolation before it is
## exposed as cell.heat_input. Keep at 1.0 for Earth-like balance.
@export_range(0.0, 2.0, 0.05) var solar_gain: float = 1.0
@export_range(-1.0, 0.0, 0.05) var insolation_dev_clamp_min: float = -1.0
@export_range(0.0, 1.0, 0.05) var insolation_dev_clamp_max: float = 1.0
@export_range(0.0, 1.0, 0.005) var thermal_inertia_land: float = 0.35
@export_range(0.0, 1.0, 0.005) var thermal_inertia_water: float = 0.07
@export_range(0.0, 1.0, 0.005) var thermal_inertia_snow: float = 0.09
@export_range(0.0, 1.0, 0.005) var thermal_inertia_high_mountain: float = 0.16
@export_range(0.0, 0.30, 0.005) var thermal_daily_delta_cap: float = 0.15
@export var thermal_final_delta_cap_enabled: bool = true
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_daily_cap: float = 0.12
@export_range(0.0, 0.5, 0.005) var temperature_transport_anomaly_source_cap: float = 0.08
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_blend_rate: float = 0.35
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_decay_rate: float = 0.12
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_zero_current_decay: float = 0.20
@export_range(0.0, 1.0, 0.005) var snowpack_accum_gain: float = 0.10
@export_range(0.0, 1.0, 0.005) var snowpack_melt_temp_gain: float = 0.08
@export_range(0.0, 1.0, 0.005) var snowpack_melt_sun_gain: float = 0.03
@export_range(0.0, 0.5, 0.005) var snowpack_cover_low: float = 0.03
@export_range(0.0, 1.0, 0.005) var snowpack_cover_full: float = 0.25

# climate-loop-closure Phase 2.1：气候态物理雪线（snowline）。
# 现状问题：snow_cover 完全由天气 snowpack 派生，而冷区往往无降水 → 雪几乎从不
# 累积（recorder 实测全程 snowpack 峰值仅 0.0136，山顶 snow=0）。物理雪线给每个
# 陆地 cell 一个"按当前温度决定的基线雪盖"：当 temp_now 低于 snowline_temp_threshold
# 时，按越阈深度 (threshold - temp_now)/snowline_band 线性升到 1。temp_now 已含
# 海拔 lapse + 日照/热惯性派生温度项，因此雪线自然随海拔升高、随太阳直射点南北推移；天气降雪在此基线
# 之上叠加波动。在 weather distribute（snow_cover/snowpack 的最终写入处）应用：
#   climatic_floor = clamp((snowline_temp_threshold - temp_now) / snowline_band, 0, 1)
#   snowpack   = max(snowpack, climatic_floor)
#   snow_cover = max(snow_cover, climatic_floor)
# 设 snowline_temp_threshold=0 可完全关闭（回归到纯天气驱动，用于 A/B 对照）。
@export_range(0.0, 1.0, 0.005) var snowline_temp_threshold: float = 0.34
@export_range(0.02, 0.6, 0.005) var snowline_band: float = 0.18

# ══════════════════════════════════════════════════════════════════════
# [Special features]
# ══════════════════════════════════════════════════════════════════════
@export_category("特殊功能")
@export_group("海冰阈值")

# Sea-ice cover thresholds (temperature).
# 2026-05-26：form 保持较低，melt 保持迟滞窗口；海冰范围由温度场持续越阈决定。
@export var sea_ice_form_threshold: float = 0.12
@export var sea_ice_melt_threshold: float = 0.22

# Volcano placement.
@export_group("火山")
@export var max_volcanoes: int = 8
@export var volcano_min_dist: int = 6           # minimum hex-distance between volcanoes
@export var volcano_min_land_h: float = 0.65    # minimum elevation to qualify as volcano

# ══════════════════════════════════════════════════════════════════════
# [Reference-impl demo channels — DO NOT use in real game logic]
# ══════════════════════════════════════════════════════════════════════
@export_category("调试与演示")
@export_group("热力梯度演示")
# These switches drive the C++/GDScript communication-contract reference
# passes documented in `docs/performance-charter.md` §12.5 (Pass #1) and
# §12.6 (Pass #2). They are **demo-only** — real climate / weather / biome
# / vegetation / UI tooltip paths must never read the corresponding
# `cell.demo.*` components. The default is false so that production runs
# pay zero cost.

# Pass #2 — `thermal_gradient_pass`
#   true  → after the daily climate chain, run `_ext.run_thermal_gradient_pass`
#           and surface the result through Overlay mode `DEMO_THERMAL_GRADIENT`.
#   false → entire chain is no-op; the `cell.demo.thermal_gradient` slot is
#           never even allocated, and the overlay dropdown hides the entry.
@export var demo_thermal_gradient_enabled: bool = false

# Pass #2/#3 dispatch path selector — picks how main.gd hands the C++ kernel
# its work. Used as a reference / benchmark site for the DOTS upgrade tracks
# documented in `docs/dots-experiment-report.md`. The output written to
# `cell_demo_thermal_gradient` is bit-equal across LEGACY and ECS; the
# ECS_ARCHETYPE path zeros out OCEAN cells by design and is therefore not
# bit-equal — only used for visual / perf comparison.
#   * LEGACY        → hand-coded direct call to `run_demo_complex_pass`.
#                     Zero scheduler overhead. Pre-DOTS baseline. **Default**:
#                     in single-pass scenarios the scheduler is pure overhead
#                     with zero benefit (verified in
#                     `bench_thermal_gradient_paths.gd`); the scheduler is
#                     justified only when J ≥ ~10 with complex deps (see
#                     `docs/dots-experiment-report.md` §3.6).
#   * ECS           → DCEcsScheduler with one job declaring
#                     reads=[CELL_TEMP, CELL_ELEVATION] /
#                     writes=[CELL_DEMO_THERMAL_GRADIENT]. Bit-equal to LEGACY.
#                     Real-jobs bench (J=8 mixed pipeline) measured +5.08%
#                     scheduler overhead — well under the 25% red line.
#   * ECS_ARCHETYPE → same scheduler, but the job uses
#                     `run_demo_complex_pass_archetyped(target=LAND)` after
#                     populating archetypes from `is_water_arr`. Demonstrates
#                     archetype-as-logical-filter end-to-end. NOTE: OCEAN
#                     cells are forced to 0.0 and excluded from min/max
#                     normalization (see report §2.5) — visual divergence
#                     vs LEGACY/ECS is by design, not a bug.
enum DemoTGPath { LEGACY = 0, ECS = 1, ECS_ARCHETYPE = 2 }
@export var demo_thermal_gradient_path: DemoTGPath = DemoTGPath.LEGACY

# Pass #2 — elevation gain knob (1 + gain * elevation amplifies grad_mag).
# Higher values exaggerate mountain edges; default 1.5 mirrors the spec.
@export_range(0.0, 5.0, 0.1) var demo_thermal_gradient_elevation_gain: float = 1.5

# Pass #2 — final normalize coefficient applied before clamp([0, 1]).
# Tune up if the visualization looks washed out, down if it saturates.
@export_range(0.0, 5.0, 0.05) var demo_thermal_gradient_normalize_k: float = 0.5

# ── Pass #3 knobs (`run_demo_complex_pass`, charter §12.6.6) ─────────
@export_subgroup("复杂扩散演示")
# These four knobs upgrade the Pass #2 kernel from a one-shot 4-neighbour
# gradient to an iterated anisotropic-diffusion + multi-scale wind
# approximation. They share `demo_thermal_gradient_enabled` as the master
# switch — when that switch is OFF, none of these are read or applied.
# Higher values = slower per tick but richer visual patterns.

# Pass #3 — number of diffusion / advection iterations per tick.
# Time-depth dial: more iterations let curls and fronts fully develop,
# but cost scales linearly. Default 16 ≈ ~1ms on the default 60×40 grid.
@export_range(1, 64, 1) var demo_complex_iterations: int = 16

# Pass #3 — Gaussian smoothing kernel radius (full size = 2r+1).
# Spatial-influence dial: r=1 → 3×3 stencil (cheap); r=5 → 11×11 (heavy).
# Cost scales as (2r+1)² × iterations, so doubling r ~ quadruples cost.
@export_range(1, 5, 1) var demo_complex_kernel_radius: int = 2

# Pass #3 — Coriolis bias strength (-1 = full reversed, +1 = full standard).
# Hemispheric-bias dial: signed by latitude (north ≠ south), drives the
# rotation of the gradient vector before it feeds the flux divergence.
# 0.0 disables the rotation (returns to pure diffusion).
@export_range(-1.0, 1.0, 0.05) var demo_complex_coriolis_strength: float = 0.5

# Pass #3 — terrain drag coefficient (mountains slow the diffusion).
# Damping dial: damp = 1 - drag * elevation, so high elevation cells evolve
# slower than low-lying ones, producing visible "shelter" patterns leeward
# of mountain ranges. 0.0 disables the damping.
@export_range(0.0, 1.0, 0.05) var demo_complex_terrain_drag: float = 0.6
