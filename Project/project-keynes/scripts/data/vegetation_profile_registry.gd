# vegetation_profile_registry.gd
# Single-point accessor that maps VegetationType.VEG enum values to
# VegetationProfile resources. Lazy-loaded on first access, cached in a
# static Dictionary.
#
# Usage:
#   var profile := VegetationProfileRegistry.get_profile(VegetationType.VEG.TAIGA)
#   var eco := profile.eco_score
#
# If a profile fails to load, the registry returns the NONE fallback profile
# (disk-loaded if possible, otherwise an in-memory default) and pushes a
# warning. Game never crashes on missing .tres files.

class_name VegetationProfileRegistry

# 显式 preload，保证 VegetationProfile 类在本脚本解析前已被 Godot 加载，避免
# 首次导入 / 冷启动时的 "Could not parse global class" 报错。
const _VegetationProfileScript = preload("res://scripts/data/vegetation_profile.gd")

const _PROFILE_PATHS: Dictionary = {
	0:  "res://data/vegetation/none.tres",
	1:  "res://data/vegetation/polar_desert.tres",
	2:  "res://data/vegetation/tundra.tres",
	3:  "res://data/vegetation/alpine_tundra.tres",
	4:  "res://data/vegetation/alpine_meadow.tres",
	5:  "res://data/vegetation/taiga.tres",
	6:  "res://data/vegetation/boreal_shrub.tres",
	7:  "res://data/vegetation/temperate_deciduous.tres",
	8:  "res://data/vegetation/temperate_conifer.tres",
	9:  "res://data/vegetation/temperate_grassland.tres",
	10: "res://data/vegetation/temperate_steppe.tres",
	11: "res://data/vegetation/mediterranean_shrub.tres",
	12: "res://data/vegetation/subtropical_forest.tres",
	13: "res://data/vegetation/savanna.tres",
	14: "res://data/vegetation/tropical_rainforest.tres",
	15: "res://data/vegetation/tropical_dry_forest.tres",
	16: "res://data/vegetation/desert_scrub.tres",
	17: "res://data/vegetation/xeric_desert.tres",
	18: "res://data/vegetation/oasis_veg.tres",
	19: "res://data/vegetation/mangrove.tres",
	20: "res://data/vegetation/swamp.tres",
	21: "res://data/vegetation/marsh.tres",
	22: "res://data/vegetation/kelp_forest.tres",
	23: "res://data/vegetation/coral_reef.tres",
}

static var _cache: Dictionary = {}        # int (VEG) → VegetationProfile
static var _loaded: bool = false
static var _fallback: VegetationProfile = null

# Idempotent bulk loader. Called implicitly by get_profile / get_all_profiles
# but may also be invoked explicitly at boot to pre-warm the cache.
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_cache.clear()
	for v in _PROFILE_PATHS:
		var path: String = _PROFILE_PATHS[v]
		var res := ResourceLoader.load(path, "Resource") as VegetationProfile
		if res == null:
			push_warning(
				"VegetationProfileRegistry: failed to load %s (VEG=%d)"
				% [path, v]
			)
			continue
		_cache[int(v)] = res
	# map-visual-overhaul-v1：对于尚未在 .tres 内手填 season_color_lut 的资源，
	# 套用 VegetationProfile.apply_default_season_lut() 给出生态合理的默认四季偏色。
	# 这样既不强制美术手填 24 个文件，又能让游戏内立即看到"四季换色"。
	# .tres 已配置过的资源（is_season_lut_default 返回 false）则尊重原值。
	for v2 in _cache.keys():
		var p2: VegetationProfile = _cache[v2]
		if p2 != null and p2.is_season_lut_default():
			p2.apply_default_season_lut()

static func _ensure_fallback() -> VegetationProfile:
	if _fallback == null:
		_fallback = VegetationProfile.new()
		_fallback.veg_type = 0
		_fallback.display_name_cn = "无植被"
		_fallback.transpiration = 0.0
		_fallback.albedo = 0.30
		_fallback.eco_score = 0.0
		_fallback.ideal_temp = 0.5
		_fallback.ideal_moist = 0.5
		_fallback.temp_tolerance = 0.28
		_fallback.moist_tolerance = 0.28
		_fallback.next_richer = -1
		_fallback.next_harsher = -1
	return _fallback

# Returns the profile for the given VegetationType.VEG value. On cache miss,
# returns the NONE profile if available, else an in-memory default.
static func get_profile(v: int) -> VegetationProfile:
	ensure_loaded()
	var p := _cache.get(v, null) as VegetationProfile
	if p == null:
		p = _cache.get(0, null) as VegetationProfile
		if p == null:
			push_warning(
				"VegetationProfileRegistry.get_profile: VEG=%d not found and NONE fallback missing"
				% v
			)
			p = _ensure_fallback()
	return p

# Returns profiles ordered by VEG enum. Useful for debug dumps or shader arrays.
static func get_all_profiles() -> Array:
	ensure_loaded()
	var out: Array = []
	for v in _PROFILE_PATHS:
		out.append(get_profile(int(v)))
	return out

# Count of registered enum slots.
static func profile_count() -> int:
	return _PROFILE_PATHS.size()
