extends SceneTree

const SHADER_PATH := "res://shaders/world_map.gdshader"

var _checks := 0
var _failures := 0


func _init() -> void:
	var source := FileAccess.get_file_as_string(SHADER_PATH)
	_expect(not source.is_empty(), "world shader source loads")
	var surface_source := FileAccess.get_file_as_string(
		"res://shaders/include/terrain_surface_detail.gdshaderinc")
	_expect(surface_source.contains("terrain_static_biome_is_water"),
		"terrain edge blend contains an explicit coast-domain guard")
	_expect(surface_source.contains("terrain_hybrid_static_weight"),
		"desktop terrain combines distance-field blending with zoom-aware DitherUV")
	_expect(source.contains("visual_water_biome"),
		"ocean selects a visual-only water cell from the shared edge field")
	_expect(source.contains("terrain_static_biome_is_water(water_secondary_biome)"),
		"ocean DitherUV cannot cross the land/water domain")
	var variants := {
		"desktop": "",
		"mobile_low": "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
		"mobile_mid": "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n",
		"mobile_high": "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n",
	}
	for label in variants:
		var shader := Shader.new()
		shader.code = String(variants[label]) + source
		var uniforms: Array = shader.get_shader_uniform_list()
		var names := {}
		for entry in uniforms:
			names[String(entry.get("name", ""))] = true
		_expect(names.has("terrain_edge_neighbor_tex"), "%s exposes terrain edge neighbor" % label)
		_expect(names.has("terrain_ecotone_width"), "%s exposes terrain ecotone width" % label)
		_expect(names.has("terrain_ecotone_noise"), "%s exposes terrain ecotone noise" % label)
		_expect(names.has("terrain_micro_tex"), "%s exposes terrain micro texture" % label)
		_expect(names.has("camera_zoom"), "%s exposes camera zoom" % label)
	print("=== terrain shader variants: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
