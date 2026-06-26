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
@export var rain_shadow_factor: float = 0.50

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
# 大陆性季节增幅(2026-06-21)：陆地季节温度强迫的额外倍率(海洋=1.0固定)。>1 放大陆地夏热冬冷，
# 建立同纬"夏陆>海、冬陆<海"的真实海陆温差(诊断:原温差恒负-0.10、max=0,大陆性看不出)。
# 1.0=关闭;1.55=中等大陆性。调高→陆地季节更极端(夏更热冬更冷);过高→夏季内陆过热。
@export_range(1.0, 2.5, 0.05) var temp_land_continentality: float = 1.8

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
# dots-total-cpp（2026-06-18）：地图生成 C++ 化已通过逐字段 A/B parity（base +
# post_base 全字段 mismatch=0），默认切到 ACTIVE，generate() 走 native 生成路径。
@export_range(0, 2, 1) var native_generation_mode: int = NATIVE_MODE_ACTIVE
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
@export_range(1, 64, 1) var river_headwater_init_cells: int = 6
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
@export var weather_to_vegetation_gain: float = 0.012    # daily ↑ on growth_pressure per unit precip
# weather → base_moisture 直接反馈(降水抬升/干旱压低局地气候湿度)。代码保留(map_generator.gd +
# world_ext.cpp 三镜像)，默认 0 关闭 —— 2026-06-21 部分回滚：与 A(vapor 去锚定)一同撤下，先单独
# 验证 C(风场 synoptic)对流动性的贡献，避免反馈耦合干扰分离实验。需要时设 >0 重新启用。
@export var weather_to_base_moisture_gain: float = 0.0
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
@export var sea_ice_freeze_rate: float = 0.40            # k_freeze per "degree" below T_form
@export var sea_ice_melt_rate: float = 1.45              # k_melt per "degree" above T_melt
@export var sea_ice_terrain_threshold: float = 0.68      # frac at which terrain flips to SEA_ICE
@export var sea_ice_terrain_hysteresis: float = 0.12     # flip back when frac < threshold - hyst
@export var sea_ice_neighbor_contagion: float = 0.035    # extra k_freeze if any neighbor frac >= 0.6
@export var sea_ice_solar_gate_enabled: bool = true      # high current insolation blocks tropical ice growth
@export var sea_ice_freeze_insol_low: float = 0.30       # freeze gate is fully open below this insolation
@export var sea_ice_freeze_insol_high: float = 0.55      # freeze gate is fully closed above this insolation
@export var sea_ice_solar_melt_start: float = 0.40       # current insolation above this adds melt pressure
@export var sea_ice_solar_melt_gain: float = 0.80        # extra melt per insolation unit above start
@export_range(0.0, 0.50, 0.005) var sea_ice_daily_delta_cap: float = 0.05

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
# 半真实大气调参（2026-06-19）：把"逐格稳态场"调成"随风平流的动态大气"。
# advect_steps 上限 2→4、默认 3→4(2026-06-21 让天气流动)：同日上风采样更远(每 tick 最多 4 格)，
# 配合 vapor base_m 回归下调，让远方水汽随风平流更深入内陆 → 移动云带、打破永雨永旱。
@export_range(0, 8, 1) var weather_field_advect_steps: int = 6  # 方案③ 4→6 水汽长距离随风输送(atmospheric river)
@export_range(0.0, 0.5, 0.01) var weather_field_diffusion: float = 0.04
# condensation_gain：cloud_source 主项(condense_gate×本系数)。脚本默认 0.42 经 field_solver 云合成 ~1.5×
# 放大(cloud_water 自反馈 1.26× + cloud=source*0.62+water*0.70 双重计数)→ cloud 稳态≈0.72(满屏云)。
# 运行时 earth_like.tres 覆盖为 0.30 降满屏云(与永雨同源，连带压降水)。2026-06-21。
@export_range(0.0, 2.0, 0.01) var weather_condensation_gain: float = 0.42
@export_range(0.0, 1.0, 0.01) var weather_precip_decay: float = 0.85
# carryover_max 0.02→0.08：让雨带跨日/跨格随风延续（与 weather_field_solver_test 已验证值对齐）。
@export_range(0.0, 1.0, 0.01) var weather_precip_carryover_max: float = 0.08
# vapor_precip_sink 0.70→0.85(2026-06-20 阶段2打破水汽稳态)：下雨更快耗尽本地水汽 → 形成"雨→变干→
# 再积累"的松弛循环，配合 transport_gain 下调一起消除永雨永旱(precip 普遍 >阈值致 66% 格子持续降水)。
@export_range(0.0, 1.0, 0.01) var weather_vapor_precip_sink: float = 0.85
# precip_inertia(2026-06-20 根因重构)：降水 EMA 惯性系数 α。precip=lerp(prev_precip,target,α)，越小越
# 平滑(惯性强)、越大越跟手。从机制上消除天气逐tick横跳/不连续，统一替代旧 carryover/拖尾/滞回三件套。
@export_range(0.05, 1.0, 0.01) var weather_precip_inertia: float = 0.40
# 雨云化(2026-06-22):把降水从"静力+背景主导"转为"动力触发主导",消除弥漫弱雨/原地永雨,让降水集中成雨核并随
# 辐合/锋面/对流系统移动(生成-运动-消减)。两参数经 weather_system→knobs 进 C++ run_climate_pass_a(不重编)。
# precip_base_frac:autoconversion 背景成雨比例。原0.50→零动力区也有8%背景雨→海62.8%弥漫弱雨。降0.12让无动力
#   区转晴、降水只在移动天气系统处爆发。注:陆地热力对流雨(THERMAL_CONV_PRECIP)旁路本项,内陆对流雨保留。
@export_range(0.0, 1.0, 0.01) var weather_field_precip_base_frac: float = 0.12
# cloud_reevap:干空气云水再蒸发率。原0.06太弱→云团不消散、陆地连续降水中位32天。提0.18让低湿处云水更快蒸发回
#   vapor→雨团/云团边缘消散、雨过转晴,形成生命周期。过高则云难积累,须按CSV复核。
@export_range(0.0, 0.5, 0.01) var weather_field_cloud_reevap: float = 0.18
@export_range(0.0, 1.0, 0.01) var weather_vapor_relax_rate: float = 0.08
@export_range(0.0, 1.0, 0.01) var weather_orographic_lift_cap: float = 0.35
@export_range(0.0, 1.0, 0.01) var weather_wet_terrain_precip_damping: float = 0.60
@export_range(0.0, 1.0, 0.01) var weather_lake_precip_damping: float = 0.65
@export_range(0.0, 1.0, 0.01) var weather_lake_evap_scale: float = 0.85  # Stage14d 0.35→0.85 湖面蒸发接近海面→湖区+下风有水汽可成雨(原0.35过低致湖泊降水不明显)
@export_range(0.0, 1.0, 0.01) var weather_extreme_precip_soft_cap: float = 0.16
@export_range(0.0, 1.0, 0.01) var weather_extreme_precip_softness: float = 0.45  # 收尾标定: 0.32→0.45 进一步少压缩暴雨峰→恢复方案③后偏低的暴雨(只放大已下大雨的格,不增降雨频率)
@export_range(0.0, 0.10, 0.005) var weather_temp_anomaly_cap: float = 0.025
@export_range(0.0, 2.0, 0.01) var weather_orographic_lift_gain: float = 0.22
@export_range(0.0, 2.0, 0.01) var weather_convergence_gain: float = 0.18
@export_range(1, 12, 1) var weather_convergence_refresh_stride: int = 2
@export var weather_cold_precip_as_blizzard: bool = true
@export_range(0.0, 0.12, 0.005) var weather_snow_classification_margin: float = 0.03
# ocean_evap_gain 0.20→0.55：海洋成为强水汽源，喂给上风平流，让水汽能被搬到内陆。
# 运行时 earth_like.tres 覆盖为 0.45：暖洋面 vapor 偏高致永雨(36%)，轻降洋面蒸发压永雨；只小降以免削
# 弱内陆水汽供给加重高纬永旱(13%)。2026-06-21。
@export_range(0.0, 2.0, 0.01) var weather_ocean_evap_gain: float = 0.55
# land_evapotranspiration_gain 0.85→1.6（2026-06-22 开源增内陆本地水汽）：修复陆地整体偏干
# (moisture 中位0.33/河边0.32,几乎无高湿陆地)+降水单一成因。陆地蒸散源~翻倍→vapor↑→锋面/辐合/
# 对流各成因降水↑→moisture↑→高湿陆地出现。@export 可在编辑器微调(0-2.0),不足可继续上调。
@export_range(0.0, 2.0, 0.01) var weather_land_evapotranspiration_gain: float = 1.6
# precip_rh_threshold：0.60→0.70(2026-06-20 物理层根治)。原 0.60 过低——蒸发充足致 RH 普遍越阈、
# condense_gate 恒高 → cloud/precip 整体偏高(连不下雨的 CLEAR 都凝≈0.6 云)、全图无真正晴空，连带
# 满屏云/固定降水/热浪旱灾消失。提阈让凝结只在真正高湿(RH>0.70)发生，中湿区转晴、拉开干湿对比。
@export_range(0.40, 0.95, 0.01) var weather_precip_rh_threshold: float = 0.70
# ocean_precip_suppression 0.85→0.95：海面原始降水近乎处处偏高(近饱和)，本系数把无动力强迫的
# 静洋面压到降水阈值以下→只剩 convergence(辐合)/frontogenesis(锋生)/暖流异常 的「空间强迫带」成雨团，
# 其余洋面转晴(雨团之间的晴海)。释放门控见 field_solver.gd 的 ocean_drive；越高雨团越紧、晴海越多。
# 0.95→0.60 (climate-realism Stage 0, 2026-06-23)：实测全球降水 99% 落陆地、海洋仅 1%(地球≈陆22/海78)。
# 海洋只当水汽源、几乎不下雨。降低抑制让海上 ITCZ/辐合带恢复降水；空间结构由 Stage 1 omega 环流项提供
# (ITCZ 上升下雨、副热带下沉转晴)，故可放心降低而不会回到"满屏弱雨"。
# 0.60→0.45 (Stage 6b, 2026-06-23)：放电(Stage6)已自限海上过湿，可进一步放开让海面有足够降水形成
# 充放电系统(修"海上不生成雨团"；实测 Stage6 后 ocean/land onset 比掉到 0.04)。
@export_range(0.0, 1.0, 0.01) var weather_ocean_precip_suppression: float = 0.45
# frontogenesis_gain 0.42→0.70 (climate-realism Stage 0, 2026-06-23)：增强锋生降水，让中纬斜压带出现
# 会移动、会消散的温带过境雨团(修"只有单一 ITCZ 雨带摆动")，并把降水送到冷区触发降雪。
@export_range(0.0, 2.0, 0.01) var weather_frontogenesis_gain: float = 0.70
@export_range(0.0, 1.0, 0.01) var weather_rain_shadow_drying: float = 0.35
# vapor_transport_gain 0.92→0.75(2026-06-20 阶段2打破水汽稳态)：原 0.92 让 vapor 被平流摊平锁成近
# 稳态(干湿区固定)→永雨永旱。下调让本地蒸发-降水收支更主导，雨区耗水汽后能转干、干区能重新积累。
@export_range(0.0, 1.0, 0.01) var weather_vapor_transport_gain: float = 0.75
@export_range(1, 12, 1) var weather_component_summary_limit: int = 12
@export_range(100, 6400, 50) var weather_field_slice_cells: int = 2400
# 天气类型过渡状态机（prev_type→target_type 按 alpha 0→1）。两个作用：
#   1) 视觉淡入：当前无 shader/baker 采样 weather_transition_alpha，淡入不会被渲染出来；
#   2) ★离散 type 稳定化：连续 ⌈1/rate⌉ tick 维持同一新类型才真正切换 weather_type，吸收
#      阈值附近的逐 tick 横跳（离线重放预测：RAIN↔STORM 横跳 24%→9%、总转换约 −45%；
#      但对两极 BLIZZARD↔CLEAR 那类较长周期交替无效——那是场层问题，不靠本开关解）。
# 脚本默认保持 false（不影响 tests 的瞬时分类断言）；运行时世界 data/world/earth_like.tres
# 已显式置 true 启用 type 稳定化。成本：enabled=true 时跳过日也要跑 commit fan-out（高倍速
# 下 ~35ms/次）。C++ 与 GDScript 两条路径都受此开关控制；rate 见下，⌈1/rate⌉=确认所需 tick。
# Stage6h (2026-06-23) false→true：启用离散类型稳定化，吸收阈值附近 RAIN↔STORM 逐 tick 横跳(用户:雷暴/降水反复切换)。
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
# plan/daily-wind-stage-split（2026-06-17）：把每日 SLP/wind 两段权威错峰到相邻
# 游戏日（偶数日只跑 SLP ~3ms、奇数日只跑 wind ~1ms），单 tick SUS 峰值从 ~5ms
# 降到 ~3ms，把 wind 日的预算让给被饿死的 atlas 上传。代价：SLP/wind 各自刷新
# 周期从每日变每 2 日（错峰），20–50x 高倍速下气压/风场无感。false → 保留每日
# 两段一起跑的合并路径（回归对照 / 低倍速精度优先）。
@export var daily_wind_split_passes: bool = true
@export_range(0.0, 1.0, 0.01) var slp_response_rate: float = 0.55
@export_range(0.0, 0.20, 0.005) var slp_synoptic_amp: float = 0.18
@export_range(0.0, 0.20, 0.005) var slp_moist_low_weight: float = 0.12
@export_range(0.0, 1.0, 0.01) var wind_response_rate: float = 0.75
# 天气尺度修复(2026-06-19)：synoptic(天气尺度)风/压扰动原先时间项挂在 day_t=sim_day/days_per_year
# 上 → 平移一个波长约需 1.3 年 → 在日/月尺度上风型实质冻结 → 水汽永远被送到同一批辐合带 →
# 固定雨带/干区、整图天气高度静止。wind_synoptic_period_days 控制 synoptic 波平移/振荡的真实周期
# （天），~6 天对应中纬度天气系统过境节奏；越小天气系统移动越快（过小会偏躁动），越大越接近静止。
# wind/SLP 两个 pass 共用本周期。amp 同步 0.075→0.10 以让移动的辐合带足以打破固定雨/干区。
@export_range(0.0, 0.30, 0.005) var wind_synoptic_amp: float = 0.24
@export_range(2.0, 60.0, 0.5) var wind_synoptic_period_days: float = 6.0
# 让天气流动(2026-06-21 阶段1)：移动低压系统。在 SLP 场上叠加 N 个随引导气流（自西向东、
# 中纬西风带主导，到达东缘后从西缘环绕）平移的高斯低压中心 −amp·exp(−r²/2σ²)。这制造出
# "会移动的辐合源"——下游 wind 读含本项的 slp 算压力梯度 → 移动辐合带 → cloud_source/
# frontogenesis → 雨带整团随系统漂移（field_solver 已有"雨带成团随风系移动"链，无需改 vapor
# 镜像）。诊断与结构性评估见 canvas weather-flow-structural-eval。仅 C++ 路径实现（SLP fallback
# 已与 C++ 分叉，生产恒走 gdext）。count=0 或 amp=0 关闭；默认保守开启以打破永雨永旱固定带。
@export_range(0, 8, 1) var slp_mobile_low_count: int = 5
@export_range(0.0, 0.30, 0.01) var slp_mobile_low_amp: float = 0.16
@export_range(0.05, 0.40, 0.01) var slp_mobile_low_sigma: float = 0.16
@export_range(5.0, 120.0, 1.0) var slp_mobile_low_period_days: float = 16.0
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
@export_range(0.0, 1.0, 0.01) var ocean_thermal_current_weight: float = 0.32
@export_range(0.0, 1.0, 0.01) var ocean_density_cold_weight: float = 0.35
@export_range(0.0, 1.0, 0.01) var ocean_density_ice_weight: float = 0.18

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
@export_range(0.5, 4.0, 0.05) var insolation_season_gain: float = 1.8

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
@export_range(0.01, 1.0, 0.01) var ocean_psi_source_scale: float = 0.06
@export_range(0.0, 2.0, 0.01) var ocean_current_scale: float = 0.18
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
# 2026-06-16 物理化（大陆性对比，"中等"档）：海洋热容远大于陆地。把 α_water 0.07→0.008
# （时间常数 τ≈14d→125d）。注意：pass_a 的吸收短波因子给海洋 1.15×季节强迫（低反照率
# 多吸收），单靠 τ≈25d(α=0.04) 对"全年"周期几乎不衰减，反而让海洋摆幅>陆地；数值实验
# （tmp/verify_physical_temp_20260616.py）显示需 α≈0.008 才能把同纬陆/海振幅拉到≈1.9:1、
# 海洋振幅≈0.20 仍清晰可见且滞后~1.5 月——大陆性对比明显。配合吸收短波因子共同体现
# 海陆/极地真实温差。调高→海洋更跟随季节（大陆性减弱）；调低→更接近真实 SST 小摆幅。
@export_range(0.0, 1.0, 0.001) var thermal_inertia_water: float = 0.008
@export_range(0.0, 1.0, 0.005) var thermal_inertia_snow: float = 0.09
@export_range(0.0, 1.0, 0.005) var thermal_inertia_high_mountain: float = 0.16
@export_range(0.0, 0.30, 0.005) var thermal_daily_delta_cap: float = 0.15
@export var thermal_final_delta_cap_enabled: bool = true
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_daily_cap: float = 0.12
@export_range(0.0, 0.5, 0.005) var temperature_transport_anomaly_source_cap: float = 0.22
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_blend_rate: float = 0.70
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_decay_rate: float = 0.04
@export_range(0.0, 1.0, 0.005) var temperature_transport_anomaly_zero_current_decay: float = 0.06
@export_range(0.0, 1.0, 0.005) var snowpack_accum_gain: float = 0.08
@export_range(0.0, 1.0, 0.005) var snowpack_melt_temp_gain: float = 0.22
@export_range(0.0, 1.0, 0.005) var snowpack_melt_sun_gain: float = 0.12
@export_range(0.0, 0.5, 0.005) var snowpack_cover_low: float = 0.05
@export_range(0.0, 1.0, 0.005) var snowpack_cover_full: float = 0.32
@export_range(1, 8, 1) var snow_accum_days_req: int = 2

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
@export_range(0.0, 1.0, 0.005) var snowline_temp_threshold: float = 0.24
@export_range(0.02, 0.6, 0.005) var snowline_band: float = 0.22

# ══════════════════════════════════════════════════════════════════════
# [Runtime hydrology — river / climate / vegetation feedback loop]
# ══════════════════════════════════════════════════════════════════════
@export_group("运行期水文")
@export var runtime_hydrology_enabled: bool = false
@export_range(1, 30, 1) var runtime_hydrology_stride: int = 1
@export_range(0.0, 4.0, 0.01) var hydro_precip_scale: float = 1.0
@export_range(0.0, 4.0, 0.01) var hydro_snowmelt_scale: float = 0.55
@export_range(0.05, 2.0, 0.01) var hydro_soil_capacity: float = 0.75
@export_range(0.0, 1.0, 0.005) var hydro_infiltration_rate: float = 0.52
@export_range(0.0, 1.0, 0.005) var hydro_curve_number_dry: float = 0.34
@export_range(0.0, 1.0, 0.005) var hydro_curve_number_wet: float = 0.78
@export_range(0.0, 1.0, 0.005) var hydro_quickflow_fraction: float = 0.36
@export_range(0.0, 0.5, 0.001) var hydro_baseflow_recession: float = 0.035
@export_range(0.01, 1.0, 0.005) var hydro_channel_release_rate: float = 0.62
@export_range(0.005, 1.0, 0.005) var hydro_lake_release_rate: float = 0.18
@export_range(0.01, 1.0, 0.005) var hydro_discharge_ema: float = 0.08
@export_range(0.0, 0.25, 0.001) var hydro_bank_moisture_gain: float = 0.035
@export_range(0.0, 1.0, 0.005) var hydro_river_evap_gain: float = 0.12
@export_range(0.1, 8.0, 0.05) var hydro_flood_threshold: float = 2.2
@export_range(0.0, 1.0, 0.005) var hydro_flood_decay: float = 0.10

# ══════════════════════════════════════════════════════════════════════
# [Diagnostics — runtime perf opt-in]
# ══════════════════════════════════════════════════════════════════════
@export_group("运行时诊断")
# climate_daily_system._debug_climate_integrity 会在每个 climate pass 末尾跑一遍
# 2400 cell 比对循环（17 PackedArray reads + cell facade compare + samples 构造），
# 8 个 pass × 每 tick ≈ 6ms 纯 GDScript 开销。移动端实测占 refresh_climate_daily
# avg 28ms 中的 ~80%。default false 让生产环境关闭诊断；开发期手动改 true 重启
# 即可在编辑器/PC build 上恢复完整 integrity check。代码里也对 OS.has_feature("mobile")
# 做了硬短路兜底——即使误把 cp 改 true，移动端仍不跑。
@export var climate_pass_diagnostics_enabled: bool = false

# ─── async climate round（plan §async-stage-3，2026-06-14）────────────
# 默认 true：climate_daily_system 走 worker thread 后台完整 8-pass round，主线程
# kick + poll，每帧 climate 工作 < 1.5ms。
#
# 移动端 60 FPS 路径的最后一公里：log(3).txt 实测 sync 路径下 climate round
# 跨 21 game days 才完成，温度天气更新慢。async 模式下 worker 在后台 30-50ms
# 完成一轮，1 game day = 1 round（x1 速度）。
#
# 切换前提：dots_ext arm64 .so 须含 Stage 3 build（包含 `async_climate_round_*`
# API + 全 8 pass pure kernel）。dev 期建议先用 KEY_B / KEY_V 跑 bench 验证
# bit-equal，再翻开本 flag。
@export var use_climate_round_async: bool = true

# ══════════════════════════════════════════════════════════════════════
# [Special features]
# ══════════════════════════════════════════════════════════════════════
@export_category("特殊功能")
@export_group("海冰阈值")

# Sea-ice cover thresholds (temperature). temp < form → 结冰(frac→1)；temp > melt → 化冰(frac→0)。
# 2026-05-26：form 保持较低，melt 保持迟滞窗口；海冰范围由温度场持续越阈决定。
# ⚠ 2026-06-19：两极海冰带偏大(SEA_ICE 占水域~18%)。form 0.14→0.10、melt 0.22→0.16 同步下调，
# 让结冰带更靠极、整体收窄约 30%，同时维持 0.06 迟滞窗口避免冰缘逐日抖动。
# ⚠ 2026-06-19(午):form 0.10 仍偏大(SEA_ICE ~15.5% 水域)。再降 form 0.10→0.06、melt 0.16→0.11，
# 结冰带进一步靠极收窄(temp<0.06 才结冰)，维持 0.05 迟滞窗。若仍偏大可叠加 terrain_threshold 上调。
@export var sea_ice_form_threshold: float = 0.06
@export var sea_ice_melt_threshold: float = 0.11

# Volcano placement.
@export_group("火山")
@export var max_volcanoes: int = 8
@export var volcano_min_dist: int = 6           # minimum hex-distance between volcanoes
@export var volcano_min_land_h: float = 0.55    # minimum elevation to qualify as volcano

# ══════════════════════════════════════════════════════════════════════
# [terrain-overhaul Phase 0 — 板块构造基底]
# ══════════════════════════════════════════════════════════════════════
# Voronoi 板块（泊松散点 + Lloyd 松弛）取代放射状大陆中心：会聚边界抬升线状山脉带/岛弧、
# 离散边界成洋中脊/裂谷。tectonic_blend=0 完全回退旧放射状大陆（降风险）。
# ⚠ 2026-06-18 回归修复：blend=0.8 时板块基线(大陆 0.62 / 海洋 0.15)经 min-max 归一化后
# 把整张图抬成"超大高原大陆"——70% 陆地、land 海拔中位 0.67 → 海拔惩罚使全图过冷(温度中位
# 0.22)、纬向水汽模型内陆枯干(湿度中位 0.13)，山地/荒漠/寒漠铺满、暖湿生物群系几近消失。
# 板块场的 hypsometric 分布难以在无法实机迭代时调准，故默认回退到经过验证的放射状大陆
# (blend=0)。板块构造代码保留，后续需重新标定大陆基线与归一化后再开启。
@export_group("板块构造(生成)")
@export_range(0.0, 1.0, 0.05) var tectonic_blend: float = 0.0
@export_range(3, 40, 1) var tectonic_plate_count: int = 14
@export_range(0.0, 1.0, 0.05) var tectonic_continental_fraction: float = 0.45
@export var tectonic_continental_base: float = 0.62
@export var tectonic_oceanic_base: float = 0.15
@export var tectonic_uplift_amp: float = 0.55
@export var tectonic_ridge_width: float = 0.06
@export var tectonic_drift_speed: float = 1.0
@export_range(0, 6, 1) var tectonic_lloyd_iters: int = 2

# ══════════════════════════════════════════════════════════════════════
# [terrain-overhaul Phase 1 — 水力/热力侵蚀]
# ══════════════════════════════════════════════════════════════════════
# 液滴水力侵蚀(作用于 cell 海拔) + 热力坍塌；droplet_factor=0 关闭。迭代上限控制生成耗时。
# 注：2026-06-19 回退到 0.6（曾误判它造成"单格海洋"而关到 0；修正坐标后的实测显示孤立单格
# 水体仅 ~34 个，并非液滴侵蚀所致，而是我的分析脚本把多 tick 快照按错误宽度合并的假象）。
# 液滴侵蚀刻出的河谷/沟壑有助于"宏观大峡谷/下切河谷"的可读性，恢复开启。
@export_group("侵蚀(生成)")

# ── Stream-Power 河流侵蚀 (Cordonnier et al. 2016, EG) ──────────────────────
# 构造抬升场(=噪声地形陆地相对高度)与河流侵蚀达准平衡：priority-flood 求汇流 → 汇水面积 →
# 隐式 SPL 下切 E=(E+U+C·E_down)/(1+C), C=K·(A/Ā)^m。产出连贯山脉脊线、树状长河(干流+支流)、
# 大流域；并把杂散闭流洼地抬填(减少内陆碎水 + 修复运行时盆地灌水)。开启时自动跳过随机液滴侵蚀。
# spl_iters=0 一键回退到旧的随机液滴侵蚀。
@export_range(0, 60, 1) var spl_iters: int = 14            # 迭代轮数(0=关闭SPL)；越大越接近平衡、河谷越深
@export_range(0.0, 6.0, 0.05) var spl_erodibility: float = 1.2   # 侵蚀系数 K：越大河谷下切越强、地形越平缓
@export_range(0.2, 1.0, 0.05) var spl_area_exp: float = 0.45     # 汇水面积指数 m(地貌学常用 0.4~0.6)
@export_range(0.0, 0.5, 0.01) var spl_uplift_rate: float = 0.10  # 抬升回补：越大山体越高耸、起伏越强

@export_range(0.0, 2.0, 0.05) var erosion_droplet_factor: float = 0.6
@export_range(1, 200, 1) var erosion_max_lifetime: int = 30
@export var erosion_capacity: float = 4.0
@export_range(0.0, 1.0, 0.01) var erosion_deposit_rate: float = 0.3
@export_range(0.0, 1.0, 0.01) var erosion_erode_rate: float = 0.3
@export_range(0.0, 1.0, 0.01) var erosion_evaporation: float = 0.02
@export var erosion_gravity: float = 4.0
@export var erosion_min_slope: float = 0.01
@export_range(0, 12, 1) var erosion_thermal_iters: int = 2
@export var erosion_thermal_talus: float = 0.04
@export_range(0.0, 1.0, 0.05) var erosion_thermal_rate: float = 0.5
# [coast-erosion 2026-06-26] 水域波蚀强度：邻接水体(海/湖)按波浪能量下蚀近岸陆地，向海蚀台地收敛
# (河流沿河道切，水域沿岸线切)。0=关；越大海岸退得越多/海崖越明显。post_base #2c 消费。
@export_range(0.0, 1.0, 0.01) var coast_wave_erosion: float = 0.30

# ══════════════════════════════════════════════════════════════════════
# [terrain-overhaul Phase 3 — 统一气候场(盛行风水汽输送 + 海洋温度调节)]
# ══════════════════════════════════════════════════════════════════════
# 取代旧"噪声 + 单向 coastal/orographic 加湿"棘轮：海面蒸发为源，沿盛行风纬向平流，过陆地
# 按里程 rain-out 衰减(大陆度)，迎风增雨、背风自然成雨影；温度按距海做海洋性调节。
# ⚠ 2026-06-18 回归修复：原 baseline 使大陆偏大时内陆枯干(中位 0.13)→荒漠铺满；遂抬高基线。
# ⚠ 2026-06-19 再平衡：上轮回退到放射状大陆后变成 65% 水世界(处处近海)→湿度中位 0.986 过湿、
# 沙漠/草原消失。这里把基线/降水增益重新下调，并依赖"大陆连贯化"自然形成干燥内陆，目标中位
# ~0.45-0.55。注意：moisture 在无法实机迭代时最难一次调准，须按新 CSV 复核微调。
# ⚠ 2026-06-19(凌晨) 实测 041728.csv：湿度中位骤降到 0.24，半干旱(0.15-0.3)占陆地 52%、湿润(>0.5)
# 仅 12% → 地表整体偏黄、veg=NONE 高达 57%(地形/biome 区分不足)。问题是大陆连贯后内陆 rain-out 过
# 度，远低于上面目标的 0.45-0.55。本轮温和抬湿(基线翻倍/内陆衰减减弱/降水增益与沿海地板上调)，目标
# 中位 ~0.35-0.40：减少半干旱铺满又不至变回水世界。
# ⚠ 2026-06-22 抬湿(用户:湿度普遍偏低,沿海/沿河/季风区本该大片高湿如中国南方;且"高湿≠天天下雨")：
#   land_base 0.12→0.18→0.17(陆地基线适度回落，给副热带/内陆旱带留空间)、continental_dry 0.030→0.022(内陆 rain-out 衰减减弱,救深
#   内陆 hop8≈0.22)、coastal_floor 0.36→0.45→0.42(沿海地板,保留海岸过渡但不过度抬湿)、precip_gain 2.9→3.4(降水→base
#   湿度,季风/雨林高湿)。目标中位 ~0.45-0.50(回原始 0.45-0.55 下沿)。⚠须按新 CSV 复核,过头则回调防水世界。
@export_group("统一气候场(生成)")
@export var moisture_wind_evap: float = 0.18
@export var moisture_rainout_base: float = 0.12
@export var moisture_orographic_gain: float = 6.0
@export var moisture_continental_dry: float = 0.022
@export var moisture_land_base: float = 0.17
@export var moisture_precip_gain: float = 3.4
@export var moisture_humidity_cap: float = 1.2
@export_range(0.0, 1.0, 0.05) var moisture_smooth: float = 0.35
@export var moisture_noise_amp: float = 0.08
# 副热带干带：在南北副热带纬度按距海大陆度扣湿，恢复稳定的热带/暖温带荒漠带。
# [地貌真实性 2026-06-25] strength 0.22→0.32：实测(tile_data 0625)真沙漠 DESERT 仅占陆地 0.39%，
# 而萨王纳(SAVANNA) 高达 ~16%——副热带内陆本该出现的真荒漠(撒哈拉/阿拉伯型)被中湿萨王纳吃掉。
# 适度加强副热带干带强度，只抽干副热带大陆内部(地理正确位置)，不影响其它纬度湿度平衡。
# ⚠ 单值可逆，须按新 CSV 复核 DESERT/SAVANNA 占比，过头(沙漠铺满副热带)则回调。
@export var moisture_subtropical_dry_strength: float = 0.32
@export_range(0.0, 1.0, 0.01) var moisture_subtropical_dry_center: float = 0.33
@export_range(0.02, 0.5, 0.01) var moisture_subtropical_dry_width: float = 0.16
# 全向沿海湿度地板：纬向平流忽略非纬向最近海，易出现"假内陆干燥带"。用 dist_ocean(全向 BFS)
# 给一个随距海衰减的湿度下限，保证任意方向近海格不至枯干，同时保留纬向雨影结构。
# ⚠ 2026-06-19 再平衡：0.55→0.28。水世界下该地板把所有近海格抬得过湿，下调以恢复海岸-内陆梯度。
# ⚠ 2026-06-19(凌晨)：连贯大陆下海岸带也偏干，0.28→0.36 适度抬高，加宽湿润海岸过渡带。
@export_range(0.0, 1.0, 0.01) var moisture_coastal_floor: float = 0.42
@export var moisture_coastal_scale: float = 7.0
@export_range(0.0, 1.0, 0.01) var coastal_temp_moderation: float = 0.18
@export var coastal_temp_scale: float = 6.0

# ══════════════════════════════════════════════════════════════════════
# [terrain-overhaul Phase 5 — 特征点缀门槛]
# ══════════════════════════════════════════════════════════════════════
@export_group("特征点缀(生成)")
# 盐滩仅在距海 ≥ 该格数的内流盆地底部生成，消除沿海"错位盐滩"。
@export_range(0, 30, 1) var salt_flat_min_dist_ocean: int = 4
# 硬叶灌丛(CHAPARRAL)仅在距海 ≤ 该格数的暖温带中等偏旱草/灌带生成（地中海式干夏）。
@export_range(1, 20, 1) var chaparral_max_dist_ocean: int = 4
@export_range(0.0, 1.0, 0.01) var plateau_min_land_h: float = 0.25
@export_range(0.0, 0.2, 0.005) var plateau_max_relief: float = 0.14
@export_range(1, 80, 1) var plateau_min_cells: int = 3
@export_range(0.0, 1.0, 0.01) var mountain_min_land_h: float = 0.70
@export_range(0.0, 0.2, 0.005) var mountain_min_relief: float = 0.115
@export_range(0.0, 1.0, 0.01) var peak_min_land_h: float = 0.74
@export_range(0.0, 0.2, 0.005) var peak_min_prominence: float = 0.035
@export_range(1, 400, 1) var peak_land_cells_per_peak: int = 120

# 峡谷(CANYON)：河流深切、两壁陡立的线状侵蚀峡谷（须有河道穿过），与干旱片状荒原(BADLANDS)、
# 构造裂谷(RIFT_VALLEY)区分。canyon_min_wall=单侧陡壁最小相对高差(越大越陡才算)；canyon_min_axis=
# 对置两壁的综合下切门槛(越大峡谷越深越稀有)。仅 C++ 生成路径消费(world_ext.cpp CANYON pass)。
@export_range(0.0, 0.3, 0.005) var canyon_min_wall: float = 0.05
@export_range(0.0, 0.3, 0.005) var canyon_min_axis: float = 0.06

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
