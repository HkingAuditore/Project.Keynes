# vegetation_profile.gd
# Data-driven configuration for a single vegetation type.
#
# Single source of truth for:
#   - identity (veg_type enum value + Chinese display name)
#   - eco-physics: transpiration / albedo / eco_score
#   - climate-adaptation: ideal_temp / ideal_moist + Gaussian tolerance
#   - succession chain: next_richer / next_harsher (-1 = chain tail)
#
# One .tres per VegetationType.VEG value, collected by VegetationProfileRegistry.
# Consumers: VegetationType (facade), MapGenerator (succession passes),
# UI (hex_info_panel), ecosystem scoring (Phase 8).

class_name VegetationProfile
extends Resource

# ─── Identity ───────────────────────────────────────────────────────────

@export var veg_type: int = 0              # VegetationType.VEG value
@export var display_name_cn: String = "无植被"

# ─── Eco-physics ────────────────────────────────────────────────────────

@export var transpiration: float = 0.0     # [0, 1], moisture donated to neighbors
@export var albedo: float = 0.30           # [0, 1], reflectivity (snow/sand high)
@export var eco_score: float = 0.0         # typically -0.8 ~ +1.2, drives base_moisture drift

# ─── Climate adaptation ─────────────────────────────────────────────────
# climate_compat_score() uses a 2-D Gaussian:
#   score = exp(-0.5 * ((dt/tt)^2 + (dm/mt)^2))
# Lower tolerance = pickier about climate deviation.

@export var ideal_temp: float = 0.5        # [0, 1], climate center
@export var ideal_moist: float = 0.5       # [0, 1], climate center
@export var temp_tolerance: float = 0.28   # Gaussian sigma for temp (vegetation-survival-rebalance 方案 D：整体 1.6× 扩大，避免正常季节波动就进入负漂区)
@export var moist_tolerance: float = 0.28  # Gaussian sigma for moist

# ─── Succession chain ───────────────────────────────────────────────────
# -1 = chain tail (no further transition in this direction). Self-reference
# (next == veg_type) is also treated as chain tail by the facade.

@export var next_richer: int = -1          # long-term climate boon → upgrade
@export var next_harsher: int = -1         # long-term climate hardship → downgrade
