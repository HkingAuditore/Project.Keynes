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

# Ocean-adjacent cells receive this additional moisture bonus.
@export var coastal_moisture_boost: float = 0.20

# Windward upslope boost (orographic rainfall).
@export var orographic_boost: float = 1.5

# Leeward rain-shadow: if upstream elevation delta ≥ threshold, the cell's
# moisture is multiplied by factor (0 = completely dry; 1 = no shadow).
@export var rain_shadow_threshold: float = 0.12
@export var rain_shadow_factor: float = 0.55

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
## the legacy world.sample_wind() + monsoon_offset path for regression. Default true.
@export var weather_advect_use_wind_vector: bool = true

# ══════════════════════════════════════════════════════════════════════
# [Seasons]
# ══════════════════════════════════════════════════════════════════════

# Per-season moisture scaler. Length must be 4 (Spring/Summer/Autumn/Winter).
@export var seasonal_moisture_scale: Array[float] = [1.05, 1.20, 0.92, 0.78]

# Seasonal temperature amplitude: peak |Δtemp| between summer-mid and
# winter-mid (mid-latitudes, ny ≈ 0.5 → 0). Mirrors the shader-side
# `season_temp_amp` constant in world_map.gdshader; keep both in sync.
@export var season_temp_amp: float = 0.20

# Master switch for daily-continuous climate refresh. When true, MapGenerator
# updates each cell's current_state.temperature / moisture / snow_cover every
# day along the continuous season_phase ∈ [0, 4) curve, instead of the
# legacy "set once per season" hard step. Set false to fall back to the
# original season-aligned behavior (debug / regression).
@export var daily_climate_interpolation: bool = true

# Stride (in days) for daily-continuous refresh: 1 = every day, N>1 = every
# N days (cheap downgrade if profiling shows the per-day pass too costly).
# Has no effect when daily_climate_interpolation == false.
# Used by SUS RefreshClimateDailyJob via StridePolicy.
@export var daily_climate_refresh_stride: int = 1

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
@export_range(1, 30, 1) var weather_albedo_stride: int = 10
@export_range(1, 30, 1) var weather_vegetation_dynamics_stride: int = 10
@export_range(1, 30, 1) var weather_feedback_stride: int = 10

# DEPRECATED — superseded by SUS OceanCurrentsJob (sliced-update-scheduler
# requirement 4.5). Field is kept on disk for save-file compatibility, but
# MapGenerator emits a one-shot warning if it is set to anything other than
# the default sentinel value (4) and otherwise ignores it. Use
# `ocean_currents_period_ticks` / `ocean_currents_slice_count` below instead.
@export_range(1, 4, 1) var ocean_current_refresh_seasons: int = 4

# SUS OceanCurrentsJob — period (in days) of one full ocean current rebake.
# Default 240 days keeps currents on a seasonal/slow layer. Lower → fresher
# currents at the cost of more frequent slices.
@export_range(7, 360, 1) var ocean_currents_period_ticks: int = 240

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

# ══════════════════════════════════════════════════════════════════════
# [Hydrology]
# ══════════════════════════════════════════════════════════════════════

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
# Per-day vitality change rate; low/high thresholds; and number of
# consecutive days required to trigger succession up/down. Values mirror
# the original Phase 8 / Milestone 4 constants in map_generator.gd.

@export var vitality_change_rate: float = 0.004         # per day, at most ±0.004 (~250 days from 0 to 1)
@export var vitality_low_threshold: float = 0.15        # below → downgrade streak（only truly dying cells count）
@export var vitality_high_threshold: float = 0.90       # above → upgrade streak
@export var succession_degrade_days: int = 180          # ~half a year of low vitality
@export var succession_upgrade_days: int = 360          # ~1 full year of high vitality
# Asymmetric drift: negative drift (compat ≤ 0.4) is multiplied by this harshness.
# Positive drift (compat ≥ 0.6) stays at 1.0. Compat ∈ (0.4, 0.6) → dead zone (dv = 0).
@export var compat_harshness: float = 0.8

# Long-term base_moisture drift from eco_score (Phase 8).
@export var eco_drift_amp: float = 0.012                # max ±0.012 / year
@export var eco_score_clamp: float = 0.5                # calm-period dampener

# ══════════════════════════════════════════════════════════════════════
# [Emergent climate coupling — Phase E]
# ══════════════════════════════════════════════════════════════════════
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
@export var weather_to_soil_gain: float = 0.008          # daily ↑ on soil_moisture per unit precip
@export var weather_to_vegetation_gain: float = 0.005    # daily ↑ on growth_pressure per unit precip
@export var feedback_decay: float = 0.5                  # multiplier applied at season boundary
@export var feedback_per_day_clamp: float = 0.005        # |Δ| per day clamp (≤ 0.5% of base)

# Sea-ice daily pass tunables (replace the old hard-step _apply_sea_ice_pass).
@export var sea_ice_freeze_rate: float = 0.18            # k_freeze per "degree" below T_form
@export var sea_ice_melt_rate: float = 0.22              # k_melt per "degree" above T_melt
@export var sea_ice_terrain_threshold: float = 0.55      # frac at which terrain flips to SEA_ICE
@export var sea_ice_terrain_hysteresis: float = 0.10     # flip back when frac < threshold - hyst
@export var sea_ice_neighbor_contagion: float = 0.35     # extra k_freeze if any neighbor frac ≥ 0.6

# Local-coupling tunables (consumed when enable_local_climate_coupling = true).
@export var coastal_heat_leak_winter_boost: float = 1.5
@export var snow_albedo_cooling: float = 0.04            # extra cooling per unit snow_cover
@export var vegetation_cooling: float = 0.025            # extra cooling per unit foliage cover
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
@export var weather_field_enabled: bool = true
@export_range(0, 1, 1) var weather_field_advect_steps: int = 1
@export_range(0.0, 0.5, 0.01) var weather_field_diffusion: float = 0.08
@export_range(0.0, 2.0, 0.01) var weather_condensation_gain: float = 0.55
@export_range(0.0, 1.0, 0.01) var weather_precip_decay: float = 0.35
@export_range(0.0, 2.0, 0.01) var weather_orographic_lift_gain: float = 0.35
@export_range(0.0, 2.0, 0.01) var weather_convergence_gain: float = 0.25
@export_range(1, 12, 1) var weather_convergence_refresh_stride: int = 4
@export_range(0.0, 2.0, 0.01) var weather_ocean_evap_gain: float = 0.40
@export_range(1, 12, 1) var weather_component_summary_limit: int = 12
@export_range(100, 2400, 50) var weather_field_slice_cells: int = 500

# ══════════════════════════════════════════════════════════════════════
# [Physical Wind & Ocean Circulation — hex-domain solver]
# ══════════════════════════════════════════════════════════════════════
# 把风场/洋流从纯 ny-only 像素函数升级为"二维海陆耦合 + 海盆环流"的
# 物理化简化模型。求解粒度落在 hex 中心；像素 buffer 由 hex 场光栅化得到，
# 与现有 shader (wind_field_buffer / ocean_current_buffer / sea_ice_tex / etc) 完全兼容。
#
# 1) physical_circulation_enabled
#    总开关。true → MapBaker 在风场/洋流烘焙路径里启用 hex 物理求解器
#    （SLP → 地转风 + 海陆季风 → ψ 求解 → 西边界强化 → 沿岸 Ekman 上升流 → 光栅化）。
#    false → 走旧的 WindBelt.wind_at + Ekman ±45° + 海岸高度梯度 + 噪声路径，
#    用于回归对照与低端硬件 fallback。默认 true。
@export var physical_circulation_enabled: bool = true

# 2) enable_terrain_aware_wind
#    当 physical_circulation_enabled = true 时附加生效。true → 物理化风场求解器
#    在山地 cell 处对结果向量做地形偏转修正（背风侧降压、山脊阻挡 + 转向），
#    直接调制 cell.wind_vector，不新增独立 buffer。false → 跳过地形修正，
#    只保留地转风 + 海陆季风。默认 true。
@export var enable_terrain_aware_wind: bool = true

# 3) enable_ocean_heat_transport
#    当 physical_circulation_enabled = true 时附加生效。true → MapBaker 在水域
#    hex 上用 SOR 迭代求解 ∇²ψ = -curl(τ)/β（β-plane Stommel 简化）+ 西边界强化，
#    再 u = -∂ψ/∂y, v = ∂ψ/∂x 回算 cell.ocean_current，得到闭合海盆环流 + 黑潮 / 湾流型东岸强流。
#    false → 跳过 ψ 求解，直接用纬度风场 + Ekman ±45° 写出 hex ocean_current
#    （仍保留 hex 域，只是不解全局环流），作为零成本 fallback。默认 true。
@export var enable_ocean_heat_transport: bool = true

# ══════════════════════════════════════════════════════════════════════
# [True insolation-driven climate — Phase F]
# ══════════════════════════════════════════════════════════════════════
# Switches the "season signal" upstream source from independent cosine
# curves (one per subsystem) to a single physical quantity: insolation,
# derived from a real sub-solar latitude that moves sinusoidally between
# the tropics as year_progress sweeps [0, 1).
#
# When true_insolation_enabled == true:
#   • Temperature seasonal offset in refresh_climate_daily uses
#     insolation_season_gain × (insol_now − insol_annual_mean) × season_temp_amp
#     instead of _season_temp_offset_phase's standalone cosine.
#   • Sea-ice daily pass reads insol_dev = (insol_now − insol_mean)/insol_mean
#     for its "winter strength" factor (replaces dist_to_winter cosine).
#   • Moisture seasonal scale at _moisture_scale_at_phase is further modulated
#     by (1 + 0.2 × insol_dev) so equator ≈ invariant, high-lat amplified.
#   • Shader-side season_temp_offset() in world_map.gdshader is kept in sync
#     via the same closed formula (CPU/GPU single source of truth).
#
# When false: all paths fall back to the legacy independent-cosine path
# (seasonal-continuous-climate + emergent-climate-coupling baselines).
@export var true_insolation_enabled: bool = true

# Axial tilt (obliquity). 23.5° ≈ Earth. Lower values → milder seasons even
# at high latitudes; higher → more extreme. Used to compute subsolar_lat.
@export_range(0.0, 45.0, 0.5) var axial_tilt_deg: float = 23.5

# Gain applied to (insol_now - insol_annual_mean) when deriving the temperature
# seasonal offset. Default 1.0 keeps amplitude roughly aligned with legacy
# season_temp_amp at mid-latitudes.
@export_range(0.0, 2.0, 0.05) var insolation_season_gain: float = 1.0

# Continuous day-length amplitude (how much the "day length" term modulates
# insolation away from pure cos_zenith). 0 → pure sun-angle; higher → longer
# summer days contribute more. Matches the existing _INSOLATION_DAYLEN_AMP
# const, exposed here for per-profile tuning.
@export_range(0.0, 1.0, 0.01) var insolation_daylen_amp: float = 0.35

# ══════════════════════════════════════════════════════════════════════
# [Special features]
# ══════════════════════════════════════════════════════════════════════

# Sea-ice cover thresholds (temperature).
@export var sea_ice_form_threshold: float = 0.07
@export var sea_ice_melt_threshold: float = 0.12

# Volcano placement.
@export var max_volcanoes: int = 8
@export var volcano_min_dist: int = 6           # minimum hex-distance between volcanoes
@export var volcano_min_land_h: float = 0.65    # minimum elevation to qualify as volcano
