extends RefCounted

## Render quality remains the preset used by existing map texture baking. Custom
## controls override the individual display settings above that preset.
const ADAPTIVE_FPS := -1
const PRESET_IDS := ["auto", "low", "medium", "high"]
const DETAIL_LEVEL := {"low": 0, "medium": 1, "high": 2}
const OPTION_VALUES := {
	"map_render_scale": [100, 90, 85, 75],
	"water_detail": [0, 1, 2],
	"fog_render_scale": [50, 75, 100],
	"vegetation_detail": [0, 1, 2],
	"weather_detail": [0, 1, 2],
	"cloud_shadow": [false, true],
	"frame_rate_limit": [30, 60, 0, ADAPTIVE_FPS],
}


static func resolve(settings: Dictionary, mobile: bool) -> Dictionary:
	var preset := str(settings.get("render_quality", "auto"))
	if not PRESET_IDS.has(preset):
		preset = "auto"
	var quality := ("low" if mobile else "high") if preset == "auto" else preset
	var detail: int = DETAIL_LEVEL[quality]
	var map_scale := 100
	if mobile:
		if preset == "low":
			map_scale = 75
		elif preset == "medium":
			map_scale = 90
	elif preset == "low":
		map_scale = 85
	var fog_scales := [50, 75, 100]
	var result := {
		"render_quality": quality,
		"map_render_scale": map_scale,
		"water_detail": detail,
		"fog_render_scale": fog_scales[detail],
		"vegetation_detail": detail,
		"weather_detail": detail,
		"cloud_shadow": detail >= (2 if mobile else 1),
		"frame_rate_limit": (30 if preset == "low" else 60) if mobile else 0,
	}
	if mobile and preset == "auto":
		result.frame_rate_limit = ADAPTIVE_FPS
	var custom = settings.get("graphics_custom", false)
	if custom is bool and custom:
		for key in OPTION_VALUES:
			var value = settings.get(key)
			if is_supported_value(key, value):
				result[key] = value
	return result


static func is_supported_value(key: String, value: Variant) -> bool:
	if not OPTION_VALUES.has(key):
		return false
	var choices: Array = OPTION_VALUES[key]
	return typeof(value) == typeof(choices[0]) and choices.has(value)
