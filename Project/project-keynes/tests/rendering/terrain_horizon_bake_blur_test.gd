extends SceneTree

const SurfaceBakerScript = preload("res://scripts/rendering/bakers/surface_baker.gd")
const VisualTileHorizonBakerScript = preload("res://scripts/rendering/visual_tile_horizon_baker.gd")
const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")
const VisualTileSetScript = preload("res://scripts/rendering/visual_tile_set.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_trace_params_with_single_texture_bake_disabled()
	_test_surface_baker_layers_and_blur()
	_test_shader_contracts()
	_test_compute_blur_shader_compiles()
	print("=== terrain horizon bake/blur: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_trace_params_with_single_texture_bake_disabled() -> void:
	var flag := DCFeatureFlags.TERRAIN_HORIZON_GPU_META
	var old_flag = Engine.get_meta(flag) if Engine.has_meta(flag) else null
	DCFeatureFlags.set_terrain_horizon_gpu_bake(false)
	var baker := MapBakerScript.new()
	if ClassDB.class_exists("DCWorldExt"):
		baker._world_ext = ClassDB.instantiate("DCWorldExt")
	var world := WorldData.new()
	world.hm_size = Vector2i(8, 4)
	world.world_bounds = Rect2(0, 0, 160, 80)
	world.wrap_period_x = 154.0
	world.sea_level = 0.37
	world.height_buffer.resize(32)
	world.height_buffer.fill(0.5)
	var hex_size := 11.0
	preload("res://scripts/rendering/initial_terrain_bake.gd").bake_horizon(baker, world, hex_size)
	if old_flag == null:
		Engine.remove_meta(flag)
	else:
		Engine.set_meta(flag, old_flag)
	var params := world.terrain_horizon_gpu_params
	var height_scale := float(ProjectSettings.get_setting(
		"project_keynes/rendering/map_tiles/horizon_height_scale_hex",
		MapBakerScript.TERRAIN_HORIZON_HEIGHT_SCALE_HEX))
	_expect(not world.terrain_horizon_gpu_pending and not params.is_empty(),
		"disabling the single texture GPU bake keeps the tile compute parameters")
	_expect(is_equal_approx(float(params.get("max_horizon_angle", 0.0)), 1.309)
		and is_equal_approx(float(params.get("sea_level", 0.0)), world.sea_level)
		and is_equal_approx(float(params.get("bias", 0.0)), MapBakerScript.TERRAIN_HORIZON_BIAS)
		and is_equal_approx(float(params.get("height_world_scale", 0.0)), hex_size * height_scale)
		and is_equal_approx(float(params.get("max_distance_world", 0.0)),
			hex_size * MapBakerScript.TERRAIN_HORIZON_MAX_DISTANCE_HEX)
		and is_equal_approx(float(params.get("wrap_period_x", 0.0)), world.wrap_period_x),
		"tile compute receives the bake angle, sea level, bias, scale, distance, and true wrap period")
	var map_material := load("res://materials/world_map_material.tres") as ShaderMaterial
	_expect(is_equal_approx(float(map_material.get_shader_parameter("terrain_horizon_max_angle")),
		MapBakerScript.TERRAIN_HORIZON_MAX_ANGLE), "land material decodes the exact bake angle")


func _test_surface_baker_layers_and_blur() -> void:
	_expect(MapBakerScript.SURFACE_ARRAY_LAYERS == 10,
		"MapBaker.SURFACE_ARRAY_LAYERS expanded to 10 (incl. gi_sky + dir0/1)")
	_expect(VisualTileSetScript.FIELD_FORMATS.has("horizon_dir0")
		and VisualTileSetScript.FIELD_FORMATS.has("horizon_dir1"),
		"VisualTileSet declares horizon_dir0 and horizon_dir1 fields")

	# 4x4 synthetic packed horizon texture with a single high-occlusion spike at (0, 2)
	# so we can verify both horizontal wrap_x and vertical clamp in the 3x3 Gaussian blur.
	var w := 4
	var h := 4
	var raw := PackedByteArray()
	raw.resize(w * h * 4)
	raw.fill(0)
	# At (0, 2): E=15 (hi nibble of byte 0), W=15 (hi nibble of byte 2).
	var spike_off := (2 * w + 0) * 4
	raw[spike_off] = 15 << 4
	raw[spike_off + 2] = 15 << 4
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, raw)
	var world := WorldData.new()
	world.terrain_horizon_tex = ImageTexture.create_from_image(img)

	var layers: Array = SurfaceBakerScript._make_surface_horizon_layers(
		world, Vector2i(w, h), MapBakerScript.TERRAIN_HORIZON_MAX_ANGLE)
	_expect(layers.size() == 4 and bool(layers[3]) == true,
		"_make_surface_horizon_layers returns [gi_sky, dir0, dir1, true]")
	var gi_img: Image = layers[0]
	var dir0_img: Image = layers[1]
	var dir1_img: Image = layers[2]
	var dir0_bytes: PackedByteArray = dir0_img.get_data()
	var dir1_bytes: PackedByteArray = dir1_img.get_data()
	var gi_bytes: PackedByteArray = gi_img.get_data()

	# Center of 3x3 Gaussian [1,2,1;2,4,2;1,2,1]/16 on a single 255 impulse => round(255*4/16)=64
	_expect(dir0_bytes[spike_off] == 64,
		"dir0 E channel at impulse center blurred to 64 (got %d)" % dir0_bytes[spike_off])
	_expect(dir1_bytes[spike_off] == 64,
		"dir1 W channel at impulse center blurred to 64 (got %d)" % dir1_bytes[spike_off])
	# Horizontal wrap: (w-1, 2) is adjacent to (0, 2) with weight 2/16 => round(255*2/16)=32
	var wrap_left_off := (2 * w + (w - 1)) * 4
	_expect(dir0_bytes[wrap_left_off] == 32,
		"dir0 3x3 Gaussian wraps horizontally across X seam (got %d)" % dir0_bytes[wrap_left_off])
	# Diagonal neighbor (1, 1) has weight 1/16 => round(255/16)=16
	var diag_off := (1 * w + 1) * 4
	_expect(dir0_bytes[diag_off] == 16,
		"dir0 diagonal neighbor blurred to 16 (got %d)" % dir0_bytes[diag_off])
	# gi_sky R channel at impulse center should be lower than open sky (255) and smoothed
	_expect(gi_bytes[spike_off] < 255 and gi_bytes[wrap_left_off] < 255,
		"gi_sky R channel is blurred across wrap neighbor (center=%d left=%d)" % [
			gi_bytes[spike_off], gi_bytes[wrap_left_off]])
	# bent_normal stays unit length after 3x3 blur
	var bx := (float(gi_bytes[spike_off + 1]) / 255.0) * 2.0 - 1.0
	var by := (float(gi_bytes[spike_off + 2]) / 255.0) * 2.0 - 1.0
	var bz := float(gi_bytes[spike_off + 3]) / 255.0
	var blen := sqrt(bx * bx + by * by + bz * bz)
	_expect(absf(blen - 1.0) < 0.03,
		"gi_sky bent_normal stays normalized after 3x3 blur (len=%.4f)" % blen)


func _test_shader_contracts() -> void:
	var surface_src := FileAccess.get_file_as_string(
		"res://shaders/include/terrain_surface_detail.gdshaderinc")
	var biome_src := FileAccess.get_file_as_string(
		"res://shaders/include/biome_detail.gdshaderinc")
	var horizon_src := FileAccess.get_file_as_string(
		"res://shaders/include/terrain_horizon.gdshaderinc")

	_expect(not surface_src.contains("defined(PK_QUALITY_HIGH)) && !defined(PK_WEB_WORLD_MIN)"),
		"terrain_materials_active no longer compiles out PK_QUALITY_HIGH")
	_expect(surface_src.contains("(defined(PK_QUALITY_LOW) || defined(PK_QUALITY_MID)) && !defined(PK_WEB_WORLD_MIN)"),
		"terrain_materials_active still compiles out mobile LOW and MID")
	_expect(not biome_src.contains("pk_apply_near_detail")
		and not biome_src.contains("PK_NEAR_DETAIL_FREQ"),
		"near-view fbm noise layer removed from biome_detail across all tiers")
	_expect(horizon_src.contains("terrain_horizon_direct_from_dir_tex(")
		and horizon_src.contains("if (gi_sky_tex_bound && horizon_dir_tex_bound)"),
		"terrain_horizon uses linear horizon_dir0/1 fast path when bound")
	_expect(horizon_src.contains("terrain_horizon_direct_from_packed_nearest(")
		and horizon_src.contains("terrain_horizon_sample_nearest_packed("),
		"terrain_horizon provides 1-tap NEAREST 8-in-1 packed direct shadow helper")
	_expect(horizon_src.contains("#elif defined(MOBILE_QUALITY_MID) && !defined(PK_WEB_HORIZON)\n\treturn terrain_horizon_sample_nearest_packed(uv, light_dir);"),
		"mobile MID routes to 1-tap NEAREST 8-in-1 packed shadow")
	_expect(horizon_src.contains("if (visual_quality == 1) {\n\t\treturn terrain_horizon_sample_nearest_packed(uv, light_dir);\n\t}"),
		"web MID routes to 1-tap NEAREST 8-in-1 packed shadow")
	_expect(horizon_src.contains("#else\n\tif (visual_quality <= 0) {\n\t\treturn terrain_horizon_sample_nearest_packed(uv, light_dir);\n\t}"),
		"desktop LOW routes to 1-tap NEAREST 8-in-1 packed shadow")


func _test_compute_blur_shader_compiles() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("  [SKIP] local RenderingDevice unavailable in headless Dummy renderer")
		return
	for path in [
		VisualTileHorizonBakerScript.TRACE_SHADER,
		VisualTileHorizonBakerScript.BLUR_SHADER,
	]:
		var source_text := FileAccess.get_file_as_string(path)
		_expect(not source_text.is_empty(), "compute shader source exists: %s" % path)
		source_text = source_text.trim_prefix("#[compute]\r\n").trim_prefix("#[compute]\n")
		var src := RDShaderSource.new()
		src.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
		var spirv := rd.shader_compile_spirv_from_source(src)
		var err := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE) if spirv != null else "null spirv"
		_expect(spirv != null and err.is_empty(),
			"compute shader compiles cleanly: %s (%s)" % [path, err])
	rd.free()


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
