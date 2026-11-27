extends SceneTree

const WorldLightingFieldScript = preload("res://scripts/rendering/world_lighting_field.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	_checks += 1
	print("[world-lighting-field] ", "PASS " if ok else "FAIL ", message)
	if not ok:
		_failures += 1


func _make_solid_tex(size: Vector2i, color: Color) -> ImageTexture:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


func _make_solid_array_tex(size: Vector2i, layers: int, color: Color) -> Texture2DArray:
	var imgs: Array[Image] = []
	for _i in range(layers):
		var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		img.fill(color)
		imgs.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(imgs)
	return arr


func _uniform_names(shader: Shader) -> Array[String]:
	var names: Array[String] = []
	if shader == null:
		return names
	var raw: Array = shader.get_shader_uniform_list()
	for item in raw:
		if item is Dictionary and item.has("name"):
			names.append(String(item["name"]))
	return names


func _run() -> void:
	if not root.is_node_ready():
		await root.ready
	_test_shader_compilation()
	_test_resolution_tiers()
	_test_dirty_and_throttling()
	_test_mobile_low_lifecycle()
	_test_tiled_variant_and_fallback()
	if DisplayServer.get_name() != "headless":
		await _test_shadow_light_direction_on_gpu()
	print("=== world_lighting_field_test: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_shader_compilation() -> void:
	var direct_shader := ResourceLoader.load(
		WorldLightingFieldScript.DIRECT_RADIANCE_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	) as Shader
	var gather_shader := ResourceLoader.load(
		WorldLightingFieldScript.GATHER_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	) as Shader
	var comp_shader := ResourceLoader.load(
		WorldLightingFieldScript.COMPOSITE_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	) as Shader

	_check(direct_shader != null and direct_shader.get_rid().is_valid(),
		"Pass 1 shader (world_gi_direct_radiance.gdshader) loads with valid RID")
	_check(gather_shader != null and gather_shader.get_rid().is_valid(),
		"Pass 2 shader (world_gi_gather.gdshader) loads with valid RID")
	_check(comp_shader != null and comp_shader.get_rid().is_valid(),
		"Pass 3 shader (world_lighting_composite.gdshader) loads with valid RID")

	var direct_uniforms := _uniform_names(direct_shader)
	_check(direct_uniforms.has("ptt_albedo_tex")
		and direct_uniforms.has("ptt_coupling_tex")
		and direct_uniforms.has("radiance_scale")
		and direct_uniforms.has("day_phase")
		and direct_uniforms.has("eternal_min_elevation_rad"),
		"Pass 1 shader compiles and exposes daylight + PTT uniforms (count=%d)" % direct_uniforms.size())

	var gather_uniforms := _uniform_names(gather_shader)
	_check(gather_uniforms.has("direct_radiance_tex")
		and gather_uniforms.has("ptt_transfer_idx_tex")
		and gather_uniforms.has("ptt_coupling_tex")
		and gather_uniforms.has("gi_size"),
		"Pass 2 shader compiles and exposes gather uniforms (count=%d)" % gather_uniforms.size())

	var comp_uniforms := _uniform_names(comp_shader)
	_check(comp_uniforms.has("indirect_light_tex")
		and comp_uniforms.has("terrain_horizon_tex")
		and comp_uniforms.has("terrain_surface_tex")
		and comp_uniforms.has("horizon_dir_tex_bound")
		and comp_uniforms.has("direct_shadow_enabled"),
		"Pass 3 non-tiled shader compiles and exposes composite uniforms (count=%d)" % comp_uniforms.size())

	var comp_tiled := comp_shader.duplicate() as Shader
	comp_tiled.code = "#define MAP_VISUAL_TILED\n" + comp_tiled.code
	var comp_tiled_uniforms := _uniform_names(comp_tiled)
	_check(comp_tiled_uniforms.has("indirect_light_tex")
		and comp_tiled_uniforms.has("visual_horizon_tiles")
		and comp_tiled_uniforms.has("visual_horizon_dir0_tiles")
		and comp_tiled_uniforms.has("visual_horizon_dir1_tiles")
		and comp_tiled_uniforms.has("visual_domain_origin"),
		"Pass 3 MAP_VISUAL_TILED shader compiles and exposes tiled uniforms (count=%d)" % comp_tiled_uniforms.size())


func _test_resolution_tiers() -> void:
	_check(is_equal_approx(WorldLightingFieldScript.RADIANCE_SCALE, 2.0),
		"RADIANCE_SCALE == 2.0")
	_check(is_equal_approx(WorldLightingFieldScript.UPDATE_HZ, 12.0),
		"UPDATE_HZ == 12.0")

	# Mobile / Web tiers
	_check(WorldLightingFieldScript.composite_resolution_for_quality(0, true) == Vector2i(256, 128),
		"mobile/web LOW composite resolution == 256x128")
	_check(WorldLightingFieldScript.composite_resolution_for_quality(1, true) == Vector2i(384, 192),
		"mobile/web MID composite resolution == 384x192")
	_check(WorldLightingFieldScript.composite_resolution_for_quality(2, true) == Vector2i(512, 256),
		"mobile/web HIGH composite resolution == 512x256")

	# Desktop tiers
	_check(WorldLightingFieldScript.composite_resolution_for_quality(0, false) == Vector2i(384, 192),
		"desktop LOW composite resolution == 384x192")
	_check(WorldLightingFieldScript.composite_resolution_for_quality(1, false) == Vector2i(512, 256),
		"desktop MID composite resolution == 512x256")
	_check(WorldLightingFieldScript.composite_resolution_for_quality(2, false) == Vector2i(1024, 512),
		"desktop HIGH composite resolution == 1024x512")

	# Clamped to hm_size
	_check(WorldLightingFieldScript.composite_resolution_for_quality(2, false, Vector2i(320, 160)) == Vector2i(320, 160),
		"composite resolution clamped to hm_size (320x160)")
	_check(WorldLightingFieldScript.composite_resolution_for_quality(0, false, Vector2i(1024, 256)) == Vector2i(384, 192),
		"composite resolution keeps target when smaller than hm_size")

	# Direct shadow tier gating
	_check(not WorldLightingFieldScript.direct_shadow_enabled_for_quality(0, true, ""),
		"mobile/web LOW disables direct shadow")
	_check(not WorldLightingFieldScript.direct_shadow_enabled_for_quality(2, true, "MOBILE_QUALITY_LOW"),
		"MOBILE_QUALITY_LOW caps HIGH and disables direct shadow")
	_check(WorldLightingFieldScript.direct_shadow_enabled_for_quality(1, true, "MOBILE_QUALITY_MID"),
		"mobile/web MID keeps direct shadow enabled")
	_check(WorldLightingFieldScript.direct_shadow_enabled_for_quality(0, false, ""),
		"desktop LOW keeps direct shadow enabled")


func _test_dirty_and_throttling() -> void:
	var field := WorldLightingFieldScript.new()
	root.add_child(field)

	var world := WorldData.new()
	world.hm_size = Vector2i(1024, 512)
	world.world_bounds = Rect2(-500.0, -250.0, 1000.0, 500.0)
	world.terrain_horizon_tex = _make_solid_tex(Vector2i(16, 8), Color(0, 0, 0, 0))
	field.configure(world, world.world_bounds, 1000.0, 2, "")
	var vps: Array[Node] = field.get_children()
	_check(vps.size() == 3
		and vps[0] is SubViewport and vps[1] is SubViewport and vps[2] is SubViewport,
		"WorldLightingField creates 3 SubViewport children in pass order")
	for i in range(3):
		var vp := vps[i] as SubViewport
		_check(vp.transparent_bg and vp.disable_3d
			and vp.render_target_clear_mode == SubViewport.CLEAR_MODE_ALWAYS
			and vp.render_target_update_mode == SubViewport.UPDATE_DISABLED,
			"Pass %d SubViewport configured with transparent_bg, disable_3d, CLEAR_MODE_ALWAYS, UPDATE_DISABLED" % (i + 1))

	_check(field.is_lighting_ready(), "is_lighting_ready() is true when horizon source is bound")
	_check(field.get_lighting_texture() != null, "get_lighting_texture() returns non-null ViewportTexture")
	_check(is_equal_approx(field.get_radiance_scale(), 2.0), "get_radiance_scale() returns 2.0")
	_check(field.get_composite_resolution() == Vector2i(1024, 512),
		"desktop HIGH configures composite viewport to 1024x512")
	_check(field.is_dirty(), "configure() marks field dirty for initial refresh")

	# First _process forces initial refresh immediately even with small delta
	field._process(0.001)
	_check(field.get_render_trigger_count() == 1 and not field.is_dirty(),
		"first _process() immediately triggers initial refresh and clears dirty")
	_check((vps[0] as SubViewport).render_target_update_mode == SubViewport.UPDATE_DISABLED
		and (vps[1] as SubViewport).render_target_update_mode == SubViewport.UPDATE_DISABLED
		and (vps[2] as SubViewport).render_target_update_mode == SubViewport.UPDATE_ONCE,
		"without PTT-GI ready, Pass 1 & 2 stay UPDATE_DISABLED and only Pass 3 runs")

	# Idle / paused: no changes -> 0 updates
	field._process(0.5)
	field._process(0.5)
	_check(field.get_render_trigger_count() == 1,
		"idle frames with clean state trigger 0 GPU updates")

	# First daylight call sets initial values -> dirty
	field.set_daylight_params(0.3, 1.0, 0.4091, true, Vector3(0.2, 0.3, 0.9), false, Vector2(0.5, 0.5), 1.0, 0.1745, 1.2217)
	_check(field.is_dirty(), "set_daylight_params() with changed values marks dirty")

	# Throttling below 1/UPDATE_HZ (~0.0833s)
	field._process(0.03)
	_check(field.get_render_trigger_count() == 1 and field.is_dirty(),
		"throttle holds update when accumulated delta < 1/UPDATE_HZ")
	field._process(0.03)
	_check(field.get_render_trigger_count() == 1 and field.is_dirty(),
		"throttle continues holding at 0.06s < 0.0833s")
	field._process(0.03)
	_check(field.get_render_trigger_count() == 2 and not field.is_dirty(),
		"update fires once accumulated delta >= 1/UPDATE_HZ")

	# Calling set_daylight_params again with identical values does NOT mark dirty
	field.set_daylight_params(0.3, 1.0, 0.4091, true, Vector3(0.2, 0.3, 0.9), false, Vector2(0.5, 0.5), 1.0, 0.1745, 1.2217)
	_check(not field.is_dirty(), "identical set_daylight_params() keeps dirty=false (paused/static sun 0 cost)")
	field._process(0.5)
	_check(field.get_render_trigger_count() == 2,
		"repeated identical daylight params cause 0 GPU triggers")

	# Horizon params change detection
	field.set_horizon_params(WorldLightingFieldScript.DEFAULT_HORIZON_STRENGTH,
		WorldLightingFieldScript.DEFAULT_HORIZON_SOFTNESS)
	_check(not field.is_dirty(), "identical set_horizon_params() keeps dirty=false")
	field.set_horizon_params(0.85, 0.25)
	_check(field.is_dirty(), "changed set_horizon_params() marks dirty")
	field._process(0.1)
	_check(field.get_render_trigger_count() == 3 and not field.is_dirty(),
		"horizon param change flushes after throttle interval")

	# Daily PTT publication invalidates the configured world's lighting field.
	world.ptt_albedo_changed.emit()
	_check(field.is_dirty(), "mark_albedo_dirty() marks field dirty")
	field._process(0.1)
	_check(field.get_render_trigger_count() == 4 and not field.is_dirty(),
		"mark_albedo_dirty() flushes after throttle interval")

	# Clear inputs
	field.clear_inputs()
	world.ptt_albedo_changed.emit()
	_check(not field.is_lighting_ready() and not field.is_dirty(),
		"clear_inputs() resets readiness and dirty state")

	field.queue_free()


func _test_mobile_low_lifecycle() -> void:
	if OS.has_feature("web"):
		return
	var field := WorldLightingFieldScript.new()
	root.add_child(field)
	var world := WorldData.new()
	world.hm_size = Vector2i(16, 8)
	world.derived_size = world.hm_size
	world.world_bounds = Rect2(0, 0, 160, 80)
	world.height_buffer.resize(128)
	world.height_buffer.fill(0.6)
	world.lut_dims = Vector2i(1, 1)
	var owners := PackedInt64Array()
	owners.resize(128)
	var present := PackedByteArray()
	present.resize(128)
	present.fill(1)
	world.publish_pixel_lookup([], owners, present)
	world.terrain_horizon_tex = _make_solid_tex(world.hm_size, Color(0, 0, 0, 0))
	world.ptt_bake_deferred = true

	var baker := MapBaker.new()
	var enums := PackedByteArray([7, 0, 0, 255])
	var dynamics := PackedByteArray([0, 0, 0, 255])
	field.configure(world, world.world_bounds, 160.0, 2, "MOBILE_QUALITY_LOW", 10.0)
	baker._publish_bounce_lut(enums, dynamics, world, 1, 1)
	field._process(1.0)
	_check(field.get_child_count() == 0 and not field.is_lighting_ready() and not field.is_processing()
		and field.get_render_trigger_count() == 0 and world.ptt_bake_deferred
		and world.ptt_transfer_idx_tex == null and world.ptt_albedo_tex == null,
		"cold mobile LOW skips viewports, static transfer and coarse albedo")
	field.configure(world, world.world_bounds, 160.0, 1, "MOBILE_QUALITY_MID", 10.0)
	field._process(1.0)
	var transfer := world.ptt_transfer_idx_tex
	var dry := world.ptt_albedo_bytes
	_check(world.ptt_gi_ready and transfer != null and dry.size() >= 4
		and dry.slice(0, 4) == world.bounce_lut_bytes
		and field.is_lighting_ready() and field.get_render_trigger_count() == 1,
		"upgrading to MID bakes once with the published representative color")
	field.configure(world, world.world_bounds, 160.0, 0, "MOBILE_QUALITY_LOW", 10.0)
	dynamics[2] = 255
	baker._publish_bounce_lut(enums, dynamics, world, 1, 1, PackedInt32Array([0]), false)
	field._process(1.0)
	_check(not field.is_lighting_ready() and not field.is_dirty() and not field.is_processing()
		and field.get_render_trigger_count() == 1 and world.ptt_albedo_bytes == dry
		and field.get_children().all(func(vp: SubViewport) -> bool:
			return vp.render_target_update_mode == SubViewport.UPDATE_DISABLED),
		"downgrade cancels all passes and suspends coarse albedo uploads")
	field.configure(world, world.world_bounds, 160.0, 2, "MOBILE_QUALITY_HIGH", 10.0)
	field._process(1.0)
	_check(field.is_lighting_ready() and field.get_render_trigger_count() == 2
		and world.ptt_transfer_idx_tex == transfer and world.ptt_albedo_bytes != dry
		and world.ptt_albedo_bytes.slice(0, 4) == world.bounce_lut_bytes,
		"returning to HIGH reuses transfer and uploads the latest snow color")
	field.queue_free()


func _test_shadow_light_direction_on_gpu() -> void:
	var field := WorldLightingFieldScript.new()
	root.add_child(field)
	var world := WorldData.new()
	world.hm_size = Vector2i(16, 8)
	world.derived_size = world.hm_size
	world.world_bounds = Rect2(0, 0, 160, 80)
	# East-facing occlusion maxes the high nibble of the first byte. The west is clear.
	world.terrain_horizon_tex = _make_solid_tex(world.hm_size, Color(240.0 / 255.0, 0, 0, 0))
	field.configure(world, world.world_bounds, world.world_bounds.size.x, 2, "")
	field.set_daylight_params(0.5, 1.0, 0.4091, true, Vector3(1, 0, 0.45), false,
		Vector2(0.5, 0.5), 1.0, 0.1745, 1.2217, false)
	field._process(1.0)
	await RenderingServer.frame_post_draw
	var east_vis := field.get_lighting_texture().get_image().get_pixel(8, 4).a
	field.set_daylight_params(0.5, 1.0, 0.4091, true, Vector3(-1, 0, 0.45), false,
		Vector2(0.5, 0.5), 1.0, 0.1745, 1.2217, false)
	field._process(1.0)
	await RenderingServer.frame_post_draw
	var west_vis := field.get_lighting_texture().get_image().get_pixel(8, 4).a
	_check(east_vis < 0.1 and west_vis > 0.9,
		"shared visibility follows the BRDF global light override (east=%.3f, west=%.3f)"
		% [east_vis, west_vis])
	field.queue_free()


func _test_tiled_variant_and_fallback() -> void:
	var field := WorldLightingFieldScript.new()
	root.add_child(field)

	# Empty world with neither horizon nor PTT-GI -> not ready
	var empty_world := WorldData.new()
	empty_world.hm_size = Vector2i(512, 256)
	empty_world.world_bounds = Rect2(0.0, 0.0, 512.0, 256.0)
	field.configure(empty_world, empty_world.world_bounds, 512.0, 1, "")
	_check(not field.is_lighting_ready(),
		"empty world without horizon or PTT-GI reports is_lighting_ready() == false")

	# Non-tiled with 10-layer terrain_surface_tex -> horizon_dir_tex_bound == true
	var surface_world := WorldData.new()
	surface_world.hm_size = Vector2i(512, 256)
	surface_world.world_bounds = Rect2(0.0, 0.0, 512.0, 256.0)
	surface_world.terrain_surface_tex = _make_solid_array_tex(Vector2i(8, 4), 10, Color(0, 0, 0, 0))
	surface_world.terrain_horizon_dir_layers_bound = true
	field.configure(surface_world, surface_world.world_bounds, 512.0, 1, "")
	var comp_mat: ShaderMaterial = field.get("_composite_material")
	_check(field.is_lighting_ready()
		and comp_mat != null
		and comp_mat.get_shader_parameter("horizon_dir_tex_bound") == true
		and int(comp_mat.get_shader_parameter("terrain_surface_layer_count")) == 10,
		"non-tiled 10-layer terrain_surface_tex binds horizon_dir_tex_bound=true")

	# Tiled mock VisualTileSet
	var tiled_world := WorldData.new()
	tiled_world.hm_size = Vector2i(1024, 512)
	tiled_world.world_bounds = Rect2(0.0, 0.0, 1024.0, 512.0)
	var mock_layout := {
		"mode": "tiled",
		"visual_domain": Rect2(0.0, 0.0, 1024.0, 512.0),
		"grid_size": Vector2i(2, 1),
		"interior_size": Vector2i(512, 512),
		"layer_size": Vector2i(516, 516),
		"logical_size": Vector2i(1024, 512),
		"gutter_px": 2,
	}
	var dir_arr := _make_solid_array_tex(Vector2i(8, 8), 2, Color(0, 0, 0, 0))
	var mock_vt := {
		"ready": true,
		"layout": mock_layout,
		"horizon": dir_arr,
		"horizon_dir0": dir_arr,
		"horizon_dir1": dir_arr,
		"horizon_ready": true,
		"horizon_dir_ready": true,
	}
	# WorldData.visual_tiles is typed RefCounted, so wrap in a lightweight RefCounted holder.
	var vt_holder := _MockVisualTiles.new(mock_vt)
	tiled_world.visual_tiles = vt_holder
	field.configure(tiled_world, tiled_world.world_bounds, 1024.0, 2, "")
	var tiled_mat: ShaderMaterial = field.get("_composite_material")
	_check(tiled_mat != null and tiled_mat.shader.code.begins_with("#define MAP_VISUAL_TILED\n"),
		"tiled world compiles Pass 3 shader with #define MAP_VISUAL_TILED")
	_check(field.is_lighting_ready()
		and tiled_mat.get_shader_parameter("horizon_dir_tex_bound") == true
		and tiled_mat.get_shader_parameter("visual_horizon_dir0_tiles") == dir_arr,
		"tiled world binds visual_horizon_dir0/1 and reports ready")

	field.queue_free()


class _MockLayout extends RefCounted:
	var mode: String
	var visual_domain: Rect2
	var grid_size: Vector2i
	var interior_size: Vector2i
	var layer_size: Vector2i
	var logical_size: Vector2i
	var gutter_px: int

	func _init(d: Dictionary) -> void:
		mode = d["mode"]
		visual_domain = d["visual_domain"]
		grid_size = d["grid_size"]
		interior_size = d["interior_size"]
		layer_size = d["layer_size"]
		logical_size = d["logical_size"]
		gutter_px = d["gutter_px"]


class _MockVisualTiles extends RefCounted:
	var ready: bool
	var layout: _MockLayout
	var horizon: Texture2DArray
	var horizon_dir0: Texture2DArray
	var horizon_dir1: Texture2DArray
	var horizon_ready: bool
	var horizon_dir_ready: bool

	func _init(d: Dictionary) -> void:
		ready = d["ready"]
		layout = _MockLayout.new(d["layout"])
		horizon = d["horizon"]
		horizon_dir0 = d["horizon_dir0"]
		horizon_dir1 = d["horizon_dir1"]
		horizon_ready = d["horizon_ready"]
		horizon_dir_ready = d["horizon_dir_ready"]
