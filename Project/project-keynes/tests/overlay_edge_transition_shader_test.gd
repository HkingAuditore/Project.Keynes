extends SceneTree

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var variants := {
		"desktop": "",
		"mobile_low": "#define MOBILE_QUALITY_LOW\n#define PK_SHADER_TIER_LOW\n",
		"mobile_mid": "#define MOBILE_QUALITY_MID\n#define PK_SHADER_TIER_MID\n",
		"mobile_high": "#define MOBILE_QUALITY_HIGH\n#define PK_SHADER_TIER_HIGH\n",
	}
	for shader_path in [
		"res://shaders/fog_of_war.gdshader",
		"res://shaders/weather_overlay.gdshader",
	]:
		var source := FileAccess.get_file_as_string(shader_path)
		_expect(not source.is_empty(), "%s source loads" % shader_path)
		_expect(source.contains("DITHER_THRESHOLD_MARGIN"),
			"%s compresses Bayer rank tails" % shader_path)
		for label in variants:
			var shader := Shader.new()
			shader.code = String(variants[label]) + source
			var names := {}
			for entry in shader.get_shader_uniform_list():
				names[String(entry.get("name", ""))] = true
			_expect(names.has("terrain_edge_neighbor_tex"),
				"%s %s exposes edge neighbor" % [shader_path, label])
			_expect(names.has("terrain_edge_distance_tex"),
				"%s %s exposes edge distance" % [shader_path, label])
			_expect(names.has("has_terrain_edge_data"),
				"%s %s exposes edge fallback gate" % [shader_path, label])
			_expect(names.has("terrain_ecotone_width"),
				"%s %s exposes shared transition width" % [shader_path, label])
			var tiled_shader := Shader.new()
			tiled_shader.code = "#define MAP_VISUAL_TILED\n" + String(variants[label]) + source
			var tiled_uniforms := tiled_shader.get_shader_uniform_list()
			var tiled_names := {}
			for entry in tiled_uniforms:
				tiled_names[String(entry.get("name", ""))] = true
			_expect(not tiled_uniforms.is_empty(),
				"%s %s tiled compiles" % [shader_path, label])
			_expect(tiled_names.has("visual_map_index_tiles"),
				"%s %s tiled exposes map-index array" % [shader_path, label])
			_expect(tiled_names.has("visual_edge_neighbor_tiles"),
				"%s %s tiled exposes edge-neighbor array" % [shader_path, label])
			_expect(tiled_names.has("visual_edge_distance_tiles"),
				"%s %s tiled exposes edge-distance array" % [shader_path, label])
			_expect(not tiled_names.has("map_index_atlas"),
				"%s %s tiled omits legacy map-index sampler" % [shader_path, label])
			_expect(not tiled_names.has("terrain_edge_neighbor_tex"),
				"%s %s tiled omits legacy edge sampler" % [shader_path, label])
	await _validate_layer_binding()
	print("=== overlay edge shader variants: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _validate_layer_binding() -> void:
	var neighbor_image := Image.create(2, 2, false, Image.FORMAT_RG8)
	var distance_image := Image.create(2, 2, false, Image.FORMAT_L8)
	var neighbor_tex := ImageTexture.create_from_image(neighbor_image)
	var distance_tex := ImageTexture.create_from_image(distance_image)

	var fog := FogOfWarLayer.new()
	root.add_child(fog)
	var weather := WeatherLayer.new()
	root.add_child(weather)
	await process_frame

	fog.set_edge_transition_data(neighbor_tex, distance_tex, 0.84)
	weather.set_edge_transition_data(neighbor_tex, distance_tex, 0.84)
	var fog_mat: ShaderMaterial = fog.get("_shader_mat")
	var weather_mat: ShaderMaterial = weather.get("_overlay_mat")
	_expect(fog_mat != null and bool(fog_mat.get_shader_parameter("has_terrain_edge_data")),
		"fog layer binds shared edge textures")
	_expect(weather_mat != null and bool(weather_mat.get_shader_parameter("has_terrain_edge_data")),
		"weather layer binds shared edge textures")

	fog.set_mobile_quality_tier("MOBILE_QUALITY_HIGH")
	weather.set_mobile_quality_tier("MOBILE_QUALITY_HIGH")
	fog_mat = fog.get("_shader_mat")
	weather_mat = weather.get("_overlay_mat")
	_expect(bool(fog_mat.get_shader_parameter("has_terrain_edge_data")),
		"fog shader reload preserves edge binding")
	_expect(bool(weather_mat.get_shader_parameter("has_terrain_edge_data")),
		"weather shader reload preserves edge binding")


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
