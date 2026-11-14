extends SceneTree

## Headless contract test for the production formation body/shadow renderer.
## It exercises real MultiMesh/MultiMeshInstance2D and ShaderMaterial resources;
## the assertions are not limited to inspecting shader source text.

const TOKEN_SCRIPT = preload(
	"res://scripts/rendering/military_army_token_layer.gd")
const FORMATION_SHADER = preload(
	"res://shaders/military_formation_sprite.gdshader")

var _checks := 0
var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(FORMATION_SHADER != null, "formation shader loads")
	if FORMATION_SHADER != null:
		_expect(FORMATION_SHADER.code.contains(
			"terrain_instance_lighting.gdshaderinc"),
			"formation shader uses the shared terrain lighting include")
		_expect(FORMATION_SHADER.code.contains(
			"eval_terrain_instance_lighting"),
			"formation shader evaluates the shared map lighting function")

	var layer = TOKEN_SCRIPT.new()
	get_root().add_child(layer)
	await process_frame
	layer.set_process(false)
	layer._ensure_nodes()

	if layer._formation_batch == null \
			or layer._formation_shadow_batch == null:
		_expect(false, "formation body/shadow backend initializes")
		await _teardown(layer)
		_finish()
		return

	_test_shared_geometry(layer)
	_test_shadow_parameters(layer)
	_test_daylight_and_terrain_sync(layer)
	_test_quality_and_clear(layer)
	await _teardown(layer)
	_finish()


func _test_shared_geometry(layer) -> void:
	var body: MultiMeshInstance2D = layer._formation_batch
	var shadow: MultiMeshInstance2D = layer._formation_shadow_batch
	_expect(body.multimesh != null, "formation body owns a MultiMesh")
	_expect(shadow.multimesh != null, "formation shadow owns a MultiMesh")
	_expect(body.multimesh == shadow.multimesh,
		"body and shadow share the exact same MultiMesh")
	_expect(body.material is ShaderMaterial
		and shadow.material is ShaderMaterial,
		"body and shadow use ShaderMaterials")
	if not (body.material is ShaderMaterial \
			and shadow.material is ShaderMaterial):
		return
	var body_material := body.material as ShaderMaterial
	var shadow_material := shadow.material as ShaderMaterial
	_expect(body_material.shader != null,
		"formation body material has a shader")
	_expect(shadow_material.shader == body_material.shader,
		"body and shadow use the same shader variant")
	_expect(layer.debug_snapshot().get(
		"formation_shadow_shared_multimesh", false),
		"token layer reports shared formation geometry")


func _test_shadow_parameters(layer) -> void:
	var body_material: ShaderMaterial = layer._formation_material
	var shadow_material: ShaderMaterial = layer._formation_shadow_material
	var body_pass: Variant = body_material.get_shader_parameter("shadow_pass")
	_expect(body_pass == null or body_pass == false,
		"body pass does not enable shadow_pass")
	_expect(shadow_material.get_shader_parameter("shadow_pass") == true,
		"shadow material enables shadow_pass")

	for name in [
		"shadow_strength",
		"shadow_height_ratio",
		"shadow_max_length_ratio",
		"shadow_footprints",
		"shadow_heights",
		"shadow_edge_softness",
		"shadow_color",
		"formation_atlas",
	]:
		_expect_parameter_matches(layer, name,
			layer._formation_parameters.get(name))


func _test_daylight_and_terrain_sync(layer) -> void:
	var first_daylight := _daylight_values(0.18, 0.63)
	layer.set_daylight_parameters(first_daylight)
	_expect_dictionary_mirrored(layer, first_daylight,
		"initial daylight")

	var source_values := _terrain_source_values()
	var source := ShaderMaterial.new()
	source.shader = FORMATION_SHADER
	for name in source_values:
		source.set_shader_parameter(name, source_values[name])

	var legacy := _make_legacy_world()
	layer.set_terrain_lighting(legacy.world, source)
	_expect(not layer._formation_shader_tiled,
		"legacy terrain selects the non-tiled shader variant")
	_expect_terrain_common(layer, legacy, source_values,
		"legacy terrain")
	_expect_parameter_matches(layer, "terrain_normal_tex",
		legacy.normal_texture)
	_expect_parameter_matches(layer, "terrain_horizon_tex",
		legacy.horizon_texture)

	var second_daylight := _daylight_values(0.71, 2.35)
	layer.set_daylight_parameters(second_daylight)
	_expect_dictionary_mirrored(layer, second_daylight,
		"daylight before tiled switch")

	var tiled := _make_tiled_world()
	layer.set_terrain_lighting(tiled.world, source)
	_expect(layer._formation_shader_tiled,
		"tiled terrain selects the tiled shader variant")
	_expect_body_shadow_shader_identity(layer, true)
	_expect_terrain_common(layer, tiled, source_values,
		"tiled terrain")
	_expect_parameter_matches(layer, "visual_horizon_tiles",
		tiled.horizon_tiles)
	_expect_parameter_matches(layer, "visual_terrain_normal_tiles",
		tiled.normal_tiles)
	_expect_parameter_matches(layer, "visual_domain_origin",
		tiled.world.visual_tiles.layout.visual_domain.position)
	_expect_parameter_matches(layer, "visual_domain_size",
		tiled.world.visual_tiles.layout.visual_domain.size)
	_expect_parameter_matches(layer, "visual_grid_size",
		Vector2(tiled.world.visual_tiles.layout.grid_size))
	_expect_parameter_matches(layer, "visual_interior_size",
		Vector2(tiled.world.visual_tiles.layout.interior_size))
	_expect_parameter_matches(layer, "visual_layer_size",
		Vector2(tiled.world.visual_tiles.layout.layer_size))
	_expect_parameter_matches(layer, "visual_logical_resolution",
		Vector2(tiled.world.visual_tiles.layout.logical_size))
	_expect_parameter_matches(layer, "visual_gutter_px",
		float(tiled.world.visual_tiles.layout.gutter_px))
	_expect_dictionary_mirrored(layer, second_daylight,
		"daylight after tiled switch")
	_expect_shadow_pass_state(layer,
		"tiled shader variant")

	var third_daylight := _daylight_values(0.36, 3.6)
	layer.set_daylight_parameters(third_daylight)
	_expect_dictionary_mirrored(layer, third_daylight,
		"daylight while tiled")

	layer.set_terrain_lighting(legacy.world, source)
	_expect(not layer._formation_shader_tiled,
		"legacy rebind restores the non-tiled shader variant")
	_expect_body_shadow_shader_identity(layer, false)
	_expect_terrain_common(layer, legacy, source_values,
		"legacy terrain after tiled switch")
	_expect_dictionary_mirrored(layer, third_daylight,
		"daylight after restoring non-tiled shader")
	_expect_parameter_matches(layer, "terrain_normal_tex",
		legacy.normal_texture)
	_expect_parameter_matches(layer, "terrain_horizon_tex",
		legacy.horizon_texture)
	_expect_shadow_pass_state(layer,
		"restored non-tiled shader variant")


func _test_quality_and_clear(layer) -> void:
	var body: MultiMeshInstance2D = layer._formation_batch
	var shadow: MultiMeshInstance2D = layer._formation_shadow_batch
	body.multimesh.visible_instance_count = 1

	layer.set_visual_quality(2)
	_expect_parameter_matches(layer, "visual_quality", 2)
	if OS.has_feature("web"):
		print("[SKIP] high-quality shadow visibility is disabled on Web")
	else:
		_expect(shadow.visible,
			"high quality enables formation shadows on non-Web")

	layer.set_visual_quality(1)
	_expect_parameter_matches(layer, "visual_quality", 1)
	_expect(not shadow.visible,
		"medium quality disables formation shadows")

	layer.set_visual_quality(0)
	_expect_parameter_matches(layer, "visual_quality", 0)
	_expect(not shadow.visible,
		"low quality disables formation shadows")

	layer.set_visual_quality(2)
	_expect_parameter_matches(layer, "visual_quality", 2)
	var expected := {
		"terrain_instance_lighting_enabled": true,
		"terrain_normal_tex_bound": true,
		"terrain_horizon_tex_bound": true,
		"gi_lut_bound": true,
	}
	var expected_count: int = \
		layer._formation_batch.multimesh.visible_instance_count
	layer.clear()
	_expect(layer._formation_batch.multimesh.visible_instance_count == 0,
		"clear removes visible formation instances")
	_expect(not layer._formation_shadow_batch.visible,
		"clear hides the shadow batch")
	for name in expected:
		_expect_parameter_matches(layer, name, expected[name])
	_expect_parameter_matches(layer, "world_origin",
		Vector2(12.0, 24.0))
	_expect_parameter_matches(layer, "world_size",
		Vector2(1600.0, 900.0))
	_expect_shadow_pass_state(layer, "clear")
	_expect(expected_count > 0,
		"quality test established a formation instance before clear")


func _expect_terrain_common(layer, fixture: Dictionary,
		source_values: Dictionary, label: String) -> void:
	_expect_parameter_matches(layer, "world_origin",
		fixture.world.world_bounds.position)
	_expect_parameter_matches(layer, "world_size",
		fixture.world.world_bounds.size.max(Vector2(0.0001, 0.0001)))
	_expect_parameter_matches(layer, "wrap_origin_x", 0.0)
	_expect_parameter_matches(layer, "wrap_period_x",
		fixture.world.wrap_period_x)
	_expect_parameter_matches(layer, "terrain_instance_lighting_enabled",
		true)
	_expect_parameter_matches(layer, "terrain_normal_tex_bound", true)
	_expect_parameter_matches(layer, "terrain_horizon_tex_bound", true)
	_expect_parameter_matches(layer, "gi_lut_bound", true)
	for name in source_values:
		_expect_parameter_matches(layer, name, source_values[name],
			label + " source uniform " + name)


func _expect_dictionary_mirrored(layer, values: Dictionary,
		label: String) -> void:
	for name in values:
		_expect_parameter_matches(layer, name, values[name],
			label + " uniform " + name)


func _expect_parameter_matches(layer, name: String, expected: Variant,
		context: String = "") -> void:
	var body_value: Variant = null
	var shadow_value: Variant = null
	if layer._formation_material != null:
		body_value = layer._formation_material.get_shader_parameter(name)
	if layer._formation_shadow_material != null:
		shadow_value = layer._formation_shadow_material.get_shader_parameter(name)
	var suffix := "" if context.is_empty() else " (%s)" % context
	_expect(_same_value(body_value, expected),
		"body material receives %s%s: got %s" %
		[name, suffix, str(body_value)])
	_expect(_same_value(shadow_value, expected),
		"shadow material receives %s%s: got %s" %
		[name, suffix, str(shadow_value)])
	if layer._formation_parameters.has(name):
		_expect(_same_value(layer._formation_parameters[name], expected),
			"token-layer parameter cache receives %s%s: got %s" %
			[name, suffix, str(layer._formation_parameters[name])])


func _expect_body_shadow_shader_identity(layer, tiled: bool) -> void:
	var body_material: ShaderMaterial = layer._formation_material
	var shadow_material: ShaderMaterial = layer._formation_shadow_material
	_expect(body_material != null and shadow_material != null,
		"formation materials exist for shader variant check")
	if body_material == null or shadow_material == null:
		return
	_expect(body_material.shader == shadow_material.shader,
		"body and shadow keep one shader variant")
	_expect(body_material.shader.code.contains("#define MAP_VISUAL_TILED")
		== tiled,
		"formation shader variant tiled flag is %s" % str(tiled))


func _expect_shadow_pass_state(layer, context: String) -> void:
	var body_pass: Variant = layer._formation_material.get_shader_parameter(
		"shadow_pass")
	_expect(body_pass == false,
		"body shadow_pass is false after %s" % context)
	_expect(layer._formation_shadow_material.get_shader_parameter(
		"shadow_pass") == true,
		"shadow shadow_pass is true after %s" % context)


func _make_legacy_world() -> Dictionary:
	var world := WorldData.new()
	world.wrap_period_x = 1600.0
	world.world_bounds = Rect2(12.0, 24.0, 1600.0, 900.0)
	var normal := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	normal.fill(Color(0.43, 0.57, 0.0, 1.0))
	var horizon := Image.create(16, 16, false, Image.FORMAT_RGBA8)
	horizon.fill(Color8(0xDD, 0xDD, 0xDD, 0xDD))
	world.terrain_normal_tex = ImageTexture.create_from_image(normal)
	world.terrain_horizon_tex = ImageTexture.create_from_image(horizon)
	return {
		"world": world,
		"normal_texture": world.terrain_normal_tex,
		"horizon_texture": world.terrain_horizon_tex,
	}


func _make_tiled_world() -> Dictionary:
	var world := WorldData.new()
	world.wrap_period_x = 1600.0
	world.world_bounds = Rect2(40.0, 60.0, 1600.0, 900.0)
	var tiles := VisualTileSet.new()
	var layout := VisualTileLayout.new()
	layout.mode = "tiled"
	layout.visual_domain = world.world_bounds
	layout.grid_size = Vector2i(2, 1)
	layout.layer_count = 1
	layout.interior_size = Vector2i(8, 8)
	layout.layer_size = Vector2i(12, 12)
	layout.logical_size = Vector2i(16, 8)
	layout.gutter_px = 2

	var normal_image := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	normal_image.fill(Color(0.61, 0.39, 0.0, 1.0))
	tiles.terrain_normal = Texture2DArray.new()
	tiles.terrain_normal.create_from_images([normal_image])

	var horizon_image := Image.create(12, 12, false, Image.FORMAT_RGBA8)
	horizon_image.fill(Color8(0x77, 0x77, 0x77, 0x77))
	if not DCFeatureFlags.is_compatibility_renderer():
		horizon_image = Image.create_from_data(
			12, 12, false, Image.FORMAT_RG16, horizon_image.get_data())
	tiles.horizon = Texture2DArray.new()
	tiles.horizon.create_from_images([horizon_image])
	tiles.layout = layout
	tiles.ready = true
	tiles.horizon_ready = true
	world.visual_tiles = tiles
	return {
		"world": world,
		"normal_tiles": tiles.terrain_normal,
		"horizon_tiles": tiles.horizon,
	}


func _daylight_values(day_phase: float, season_phase: float) -> Dictionary:
	return {
		"season_phase": season_phase,
		"day_phase": day_phase,
		"axial_tilt_rad": 0.4101523,
		"day_night_enabled": true,
		"tod_debug_sun_position_enabled": true,
		"tod_debug_sun_uv": Vector2(0.31, 0.58),
		"tod_debug_sun_height_scale": 0.83,
		"tod_sun_dir": Vector3(0.42, -0.61, 0.67).normalized(),
		"tod_exposure": 0.91,
	}


func _terrain_source_values() -> Dictionary:
	return {
		"terrain_horizon_strength": 0.83,
		"terrain_horizon_softness": 0.27,
		"terrain_horizon_max_angle": 1.22,
		"terrain_normal_influence": 0.63,
		"gi_horizon_lut": HexRenderer.build_gi_horizon_lut(1.22),
		"gi_lut_bound": true,
		"gi_ao_strength": 0.86,
		"gi_ao_floor": 0.34,
		"gi_ao_smoothing": 0.72,
		"gi_bent_strength": 0.41,
		"gi_normal_floor": 0.81,
	}


func _same_value(left: Variant, right: Variant) -> bool:
	if left == null or right == null:
		return left == right
	if typeof(left) != typeof(right):
		return false
	match typeof(left):
		TYPE_FLOAT:
			return is_equal_approx(float(left), float(right))
		TYPE_VECTOR2:
			return (left as Vector2).is_equal_approx(right as Vector2)
		TYPE_VECTOR3:
			return (left as Vector3).is_equal_approx(right as Vector3)
		TYPE_COLOR:
			return (left as Color).is_equal_approx(right as Color)
	return left == right


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _teardown(layer) -> void:
	layer.queue_free()
	await process_frame


func _finish() -> void:
	print("=== military formation shader/lighting test: %d checks, %d failures ===" %
		[_checks, _failures.size()])
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
