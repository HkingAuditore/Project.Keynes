# terrain_profile_registry.gd
# Single-point accessor that maps TerrainType.TERRAIN enum values to
# TerrainProfile resources. Lazy-loaded on first access, cached in a static
# Dictionary.
#
# Usage:
#   var profile := TerrainProfileRegistry.get_profile(TerrainType.TERRAIN.FOREST)
#   var cost := profile.move_cost
#
# If a profile fails to load, the registry returns the OCEAN fallback profile
# (the one loaded from disk, or an in-memory default if even OCEAN is missing)
# and pushes a warning. Game never crashes on missing .tres files.

class_name TerrainProfileRegistry

# 显式 preload，保证 TerrainProfile 类在本脚本解析前已被 Godot 加载，避免
# 首次导入 / 冷启动时的 "Could not parse global class" 报错。
const _TerrainProfileScript = preload("res://scripts/data/terrain_profile.gd")

const _PROFILE_PATHS: Dictionary = {
	0:  "res://data/terrain/ocean.tres",
	1:  "res://data/terrain/coast.tres",
	2:  "res://data/terrain/plain.tres",
	3:  "res://data/terrain/grassland.tres",
	4:  "res://data/terrain/forest.tres",
	5:  "res://data/terrain/hill.tres",
	6:  "res://data/terrain/mountain.tres",
	7:  "res://data/terrain/desert.tres",
	8:  "res://data/terrain/tundra.tres",
	9:  "res://data/terrain/snow.tres",
	10: "res://data/terrain/swamp.tres",
	11: "res://data/terrain/jungle.tres",
	12: "res://data/terrain/savanna.tres",
	13: "res://data/terrain/taiga.tres",
	14: "res://data/terrain/steppe.tres",
	15: "res://data/terrain/shrubland.tres",
	16: "res://data/terrain/mangrove.tres",
	17: "res://data/terrain/glacier.tres",
	18: "res://data/terrain/lake.tres",
	19: "res://data/terrain/reef.tres",
	20: "res://data/terrain/sea_ice.tres",
	21: "res://data/terrain/kelp.tres",
	22: "res://data/terrain/delta.tres",
	23: "res://data/terrain/oasis.tres",
	24: "res://data/terrain/salt_flat.tres",
	25: "res://data/terrain/badlands.tres",
	26: "res://data/terrain/cold_desert.tres",
	27: "res://data/terrain/chaparral.tres",
	28: "res://data/terrain/moor.tres",
	29: "res://data/terrain/floodplain.tres",
	30: "res://data/terrain/mesa.tres",
}

static var _cache: Dictionary = {}        # int (TERRAIN) → TerrainProfile
static var _loaded: bool = false
static var _fallback: TerrainProfile = null

# Idempotent bulk loader. Called implicitly by get_profile / get_all_profiles
# but may also be invoked explicitly at boot to pre-warm the cache and surface
# any missing-file errors up front.
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_cache.clear()
	for t in _PROFILE_PATHS:
		var path: String = _PROFILE_PATHS[t]
		var res := ResourceLoader.load(path, "Resource") as TerrainProfile
		if res == null:
			push_warning(
				"TerrainProfileRegistry: failed to load %s (TERRAIN=%d)"
				% [path, t]
			)
			continue
		_cache[int(t)] = res

static func _ensure_fallback() -> TerrainProfile:
	if _fallback == null:
		_fallback = TerrainProfile.new()
		_fallback.terrain_type = 0
		_fallback.display_name = "Fallback"
		_fallback.display_name_cn = "未知"
		_fallback.passable_land = false
		_fallback.passable_sea = true
		_fallback.move_cost = 0
		_fallback.base_color = Color(0.039216, 0.149020, 0.250980, 1.0)
	return _fallback

# Returns the profile for the given TerrainType.TERRAIN value. On cache miss
# (the .tres failed to load or an unknown enum value was passed), returns the
# OCEAN profile if available, else an in-memory default, and pushes a warning.
static func get_profile(t: int) -> TerrainProfile:
	ensure_loaded()
	var p := _cache.get(t, null) as TerrainProfile
	if p == null:
		p = _cache.get(0, null) as TerrainProfile
		if p == null:
			push_warning(
				"TerrainProfileRegistry.get_profile: TERRAIN=%d not found and OCEAN fallback missing"
				% t
			)
			p = _ensure_fallback()
	return p

# Returns profiles ordered by TERRAIN enum. Useful for building shader uniform
# arrays or debug dumps.
static func get_all_profiles() -> Array:
	ensure_loaded()
	var out: Array = []
	for t in _PROFILE_PATHS:
		out.append(get_profile(int(t)))
	return out

# Count of registered enum slots.
static func profile_count() -> int:
	return _PROFILE_PATHS.size()
