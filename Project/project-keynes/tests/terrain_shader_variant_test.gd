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
	_expect(source.contains("visual_land_biome"),
		"full land material pipeline consumes a DitherUV-selected visual biome")
	_expect(source.contains("visual_land_veg") and source.contains("visual_land_cover"),
		"land DitherUV selects static biome/vegetation/cover axes together")
	_expect(source.contains("!terrain_static_biome_is_water(land_secondary_biome)"),
		"land DitherUV cannot cross the land/water domain")
	_expect(surface_source.contains("terrain_land_dither_zoom_strength"),
		"land DitherUV has an explicit close-view zoom fade")
	_expect(not surface_source.contains("near_floor"),
		"close land view has no non-zero DitherUV floor")
	_expect(surface_source.contains("TERRAIN_DITHER_THRESHOLD_MARGIN"),
		"terrain Bayer rank tails are compressed to prevent elongated teeth")
	_expect(source.contains("land_dither_probability"),
		"full land visual cell selection shares the close-view zoom fade")
	var biome_detail_source := FileAccess.get_file_as_string(
		"res://shaders/include/biome_detail.gdshaderinc")
	_expect(biome_detail_source.contains(
		"landform_visual(int landform, vec2 wp, vec3 col, float slope_mag, float flow)"),
		"landform material receives continuous river geometry")
	_expect(biome_detail_source.contains("float rock_mask")
		and biome_detail_source.contains("vec3 rgb = mix(col, warm_rock, rock_mask)"),
		"canyon material is masked by continuous geometry")
	_expect(not biome_detail_source.contains("vec3 shade = col * vec3(0.68, 0.64, 0.64)"),
		"canyon no longer darkens the entire categorical cell")
	var renderer_source := FileAccess.get_file_as_string(
		"res://scripts/rendering/hex_renderer.gd")
	_expect(renderer_source.contains("sm.set_shader_parameter(\"visual_reference_resolution\",\n\t\tvisual_resolution)"),
		"tiled DitherUV follows the active visual resolution")
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
	for label in variants:
		var shader := Shader.new()
		shader.code = "#define MAP_VISUAL_TILED\n" + String(variants[label]) + source
		var uniforms: Array = shader.get_shader_uniform_list()
		var names := {}
		for entry in uniforms:
			names[String(entry.get("name", ""))] = true
		_expect(not uniforms.is_empty(), "%s tiled variant compiles" % label)
		_expect(names.has("visual_height_tiles"), "%s tiled exposes height array" % label)
		_expect(names.has("visual_map_index_tiles"), "%s tiled exposes map-index array" % label)
		_expect(names.has("visual_horizon_tiles"), "%s tiled exposes horizon array" % label)
		_expect(not names.has("height_tex"), "%s tiled omits legacy height sampler" % label)
		_expect(not names.has("map_index_atlas"), "%s tiled omits legacy map-index sampler" % label)
		_expect(not names.has("terrain_horizon_tex"), "%s tiled omits legacy horizon sampler" % label)
	print("=== terrain shader variants: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
