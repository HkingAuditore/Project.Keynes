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

# ══════════════════════════════════════════════════════════════════════
# [Seasons]
# ══════════════════════════════════════════════════════════════════════

# Per-season moisture scaler. Length must be 4 (Spring/Summer/Autumn/Winter).
@export var seasonal_moisture_scale: Array[float] = [1.05, 1.20, 0.92, 0.78]

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

@export var vitality_change_rate: float = 0.012         # per day, at most ±0.012 (~83 days from 0 to 1)
@export var vitality_low_threshold: float = 0.20        # below → downgrade streak（only truly dying cells count）
@export var vitality_high_threshold: float = 0.85       # above → upgrade streak
@export var succession_degrade_days: int = 90           # ~1 full season of low vitality
@export var succession_upgrade_days: int = 120          # ~4 months of high vitality
# Asymmetric drift: negative drift (compat ≤ 0.4) is multiplied by this harshness.
# Positive drift (compat ≥ 0.6) stays at 1.0. Compat ∈ (0.4, 0.6) → dead zone (dv = 0).
@export var compat_harshness: float = 1.2

# Long-term base_moisture drift from eco_score (Phase 8).
@export var eco_drift_amp: float = 0.012                # max ±0.012 / year
@export var eco_score_clamp: float = 0.5                # calm-period dampener

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
