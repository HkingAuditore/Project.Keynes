# weather_profile_registry.gd
# Single-point accessor that maps WeatherType.WT enum values to WeatherProfile
# resources. Lazy-loaded on first access, cached in a static Dictionary.
#
# Usage:
#   var profile := WeatherProfileRegistry.get_profile(WeatherType.WT.RAIN)
#   var moisture := profile.moisture_delta
#
# If a profile fails to load, the registry returns the CLEAR fallback profile
# (an in-memory default, not the disk resource) and pushes a warning. Game
# never crashes on missing .tres files.

class_name WeatherProfileRegistry

const _PROFILE_PATHS: Dictionary = {
	0: "res://data/weather/clear.tres",     # WT.CLEAR
	1: "res://data/weather/rain.tres",      # WT.RAIN
	2: "res://data/weather/storm.tres",     # WT.STORM
	3: "res://data/weather/blizzard.tres",  # WT.BLIZZARD
	4: "res://data/weather/drought.tres",   # WT.DROUGHT
	5: "res://data/weather/fog.tres",       # WT.FOG
	6: "res://data/weather/heatwave.tres",  # WT.HEATWAVE
	7: "res://data/weather/monsoon.tres",   # WT.MONSOON
}

static var _cache: Dictionary = {}         # int (WT) → WeatherProfile
static var _loaded: bool = false
static var _fallback: WeatherProfile = null

# Idempotent bulk loader. Called implicitly by get_profile / get_all_profiles
# but may also be invoked explicitly at boot to pre-warm the cache and surface
# any missing-file errors up front (e.g. from WeatherLayer._ready).
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_cache.clear()
	for wt in _PROFILE_PATHS:
		var path: String = _PROFILE_PATHS[wt]
		var res := ResourceLoader.load(path, "Resource") as WeatherProfile
		if res == null:
			push_warning(
				"WeatherProfileRegistry: failed to load %s (WT=%d), using fallback"
				% [path, wt]
			)
			continue
		_cache[int(wt)] = res

static func _ensure_fallback() -> WeatherProfile:
	if _fallback == null:
		_fallback = WeatherProfile.new()
		_fallback.weather_type = 0
		_fallback.display_name = "Fallback"
	return _fallback

# Returns the profile for the given WeatherType.WT value. On cache miss
# (either the .tres failed to load or an unknown enum value was passed),
# returns the in-memory fallback and pushes a warning.
static func get_profile(wt: int) -> WeatherProfile:
	ensure_loaded()
	var p := _cache.get(wt, null) as WeatherProfile
	if p == null:
		# Prefer the CLEAR profile if it loaded successfully; else the default.
		p = _cache.get(0, null) as WeatherProfile
		if p == null:
			push_warning(
				"WeatherProfileRegistry.get_profile: WT=%d not found and CLEAR fallback missing"
				% wt
			)
			p = _ensure_fallback()
	return p

# Returns profiles ordered by WT enum (CLEAR..MONSOON). Useful for pushing
# the full table as shader uniform arrays.
static func get_all_profiles() -> Array:
	ensure_loaded()
	var out: Array = []
	for wt in _PROFILE_PATHS:
		out.append(get_profile(int(wt)))
	return out

# Count of enum slots (always 8 for now). Handy for sizing shader arrays.
static func profile_count() -> int:
	return _PROFILE_PATHS.size()
