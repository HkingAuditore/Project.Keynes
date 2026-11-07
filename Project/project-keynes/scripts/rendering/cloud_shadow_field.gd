class_name CloudShadowField
extends Node2D

const FIELD_SHADER_PATH := "res://shaders/cloud_shadow_field.gdshader"
const COMPOSITE_SHADER_PATH := "res://shaders/cloud_shadow_composite.gdshader"
const DEBUG_SHADER_PATH := "res://shaders/cloud_shadow_debug.gdshader"
## 云影强度是最终直射光的最大压暗比例。云量遮罩本身已经做了柔化，
## 这里提高到可感知范围，避免中等云量只有几个百分点的变化。
const CLOUD_SHADOW_STRENGTH_HIGH := 0.64
const CLOUD_SHADOW_STRENGTH_MID := 0.48
const CLOUD_SHADOW_STRENGTH_LOW := 0.36
const CLOUD_SHADOW_MOTION_SPEED := 0.075
const CLOUD_SHADOW_SHAPE_CONTRAST := 1.0
const CLOUD_SHADOW_NOISE_WARP := 0.28
const CLOUD_SHADOW_MASK_BIAS := 0.0
const CLOUD_SHADOW_CELL_SCALE := 0.75
const CLOUD_SHADOW_WORLD_SCALE := 0.0045

var _world: WorldData
var _map: MapData
var _bounds := Rect2()
var _wrap_period_x := 0.0
var _visual_tiles
var _visual_quality := 1
var _mobile_tier := ""
var _direct_mode := false
var _debug_view := false
var _night_factor := 0.0
var _world_time := 0.0
var _weather_lerp := 1.0
var _last_lut_update_usec := -1
var _last_lut_change_usec := 0
var _commit_interval_usec := 500000.0
var _last_pushed_lerp := -1.0
var _last_uploaded_wind_update_usec := -1
var _last_mean_wind_update_usec := -1
var _last_composite_strength := -1.0
var _last_night_visibility := -1.0
var _mean_wind := Vector3(0.35, 0.12, 0.0)
var _strength_high := CLOUD_SHADOW_STRENGTH_HIGH
var _strength_mid := CLOUD_SHADOW_STRENGTH_MID
var _strength_low := CLOUD_SHADOW_STRENGTH_LOW
var _coverage_gain := 1.35
var _motion_speed := CLOUD_SHADOW_MOTION_SPEED
var _shape_contrast := CLOUD_SHADOW_SHAPE_CONTRAST
var _noise_warp := CLOUD_SHADOW_NOISE_WARP
var _mask_bias := CLOUD_SHADOW_MASK_BIAS
var _cell_scale := CLOUD_SHADOW_CELL_SCALE
var _world_scale := CLOUD_SHADOW_WORLD_SCALE
var _has_weather_source := false
var _dirty := true
var _configured := false
var _shader_tiled := false

var _viewport: SubViewport
var _field_texture: ViewportTexture
var _field_quad: ColorRect
var _field_material: ShaderMaterial
var _composite_quad: MeshInstance2D
var _composite_material: ShaderMaterial
var _debug_quad: MeshInstance2D
var _debug_material: ShaderMaterial
var _field_size := Vector2i.ZERO


static func resolution_for_quality(quality: int, mobile_or_web: bool) -> Vector2i:
	if mobile_or_web or quality <= 0:
		return Vector2i(128, 64)
	if quality == 1:
		return Vector2i(256, 128)
	return Vector2i(512, 256)


static func direct_mode_for_quality(quality: int, mobile_or_web: bool,
		shader_tier: String) -> bool:
	return quality >= 2 and not mobile_or_web and shader_tier.is_empty()


static func encode_wind(direction: Vector2, speed: float) -> Color:
	var dir := direction.normalized() if direction.length_squared() > 0.000001 else Vector2.ZERO
	return Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, clampf(speed / 20.0, 0.0, 1.0), 1.0)


static func interpolated_cloud_amount(previous_cloud: float, previous_vapor: float,
		current_cloud: float, current_vapor: float, lerp_weight: float) -> float:
	var cloud := lerpf(previous_cloud, current_cloud, clampf(lerp_weight, 0.0, 1.0))
	var vapor := lerpf(previous_vapor, current_vapor, clampf(lerp_weight, 0.0, 1.0))
	return clampf(cloud + 0.6 * vapor, 0.0, 1.0)


static func has_valid_weather_source(texture: Texture2D, dims: Vector2i) -> bool:
	return texture != null and dims.x > 0 and dims.y > 0


func _ready() -> void:
	top_level = true
	z_as_relative = false
	z_index = 4
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_nodes()
	set_process(true)


func configure(bounds: Rect2, world: WorldData, map: MapData, visual_tiles,
		wrap_period_x: float, quality: int, mobile_tier: String, direct_mode: bool) -> void:
	var world_changed := _world != world
	var map_changed := _map != map
	var tiled := visual_tiles != null and bool(visual_tiles.ready) \
			and String(visual_tiles.layout.mode) == "tiled"
	var next_quality := clampi(quality, 0, 2)
	var shader_changed := not _configured or _shader_tiled != tiled \
			or _direct_mode != direct_mode or _visual_quality != next_quality
	var geometry_changed := not _configured or _bounds != bounds \
			or not is_equal_approx(_wrap_period_x, wrap_period_x)
	_world = world
	_map = map
	_bounds = bounds
	_wrap_period_x = maxf(wrap_period_x, 0.0)
	_visual_tiles = visual_tiles
	_visual_quality = next_quality
	_mobile_tier = mobile_tier
	_direct_mode = direct_mode
	z_index = 4
	_ensure_nodes()
	if shader_changed:
		_shader_tiled = tiled
		_configure_shaders()
	_resize_field()
	if geometry_changed:
		_configure_geometry()
	_push_static_inputs()
	if world_changed:
		_last_lut_update_usec = -1
		_last_uploaded_wind_update_usec = -1
		_last_mean_wind_update_usec = -1
		_weather_lerp = 1.0
		_last_pushed_lerp = -1.0
	_sync_weather_sources(not _configured or world_changed)
	_sync_wind_lut(not _configured or map_changed or shader_changed)
	if shader_changed or geometry_changed or world_changed or map_changed:
		_mark_dirty()
	_configured = true
	_update_visibility()


func set_quality(quality: int, mobile_tier: String, direct_mode: bool) -> void:
	var changed := _visual_quality != clampi(quality, 0, 2) \
			or _mobile_tier != mobile_tier or _direct_mode != direct_mode
	if not changed:
		return
	var shader_changed := _direct_mode != direct_mode
	_visual_quality = clampi(quality, 0, 2)
	_mobile_tier = mobile_tier
	_direct_mode = direct_mode
	if shader_changed:
		_configure_shaders()
	_resize_field()
	_mark_dirty()
	_update_visibility()


func set_night_factor(value: float) -> void:
	_night_factor = clampf(value, 0.0, 1.0)
	_push_composite_night_visibility()


func set_debug_view(enabled: bool) -> void:
	_debug_view = enabled
	_push_debug_material_inputs()
	_update_visibility()


func get_field_texture() -> Texture2D:
	if _field_texture != null:
		return _field_texture
	return _viewport.get_texture() if _viewport != null else null


func get_wrap_origin_uv() -> float:
	return (0.0 - _bounds.position.x) / maxf(_bounds.size.x, 0.0001)


func get_wrap_period_uv() -> float:
	return _wrap_period_x / maxf(_bounds.size.x, 0.0001)


func is_direct_mode() -> bool:
	return _direct_mode


func get_strength() -> float:
	return _strength_for_quality()


func set_tuning(strength_high: float, strength_mid: float, strength_low: float,
		coverage_gain: float, motion_speed: float = CLOUD_SHADOW_MOTION_SPEED,
		shape_contrast: float = CLOUD_SHADOW_SHAPE_CONTRAST,
		noise_warp: float = CLOUD_SHADOW_NOISE_WARP,
		mask_bias: float = CLOUD_SHADOW_MASK_BIAS,
		cell_scale: float = CLOUD_SHADOW_CELL_SCALE,
		world_scale: float = CLOUD_SHADOW_WORLD_SCALE) -> void:
	_strength_high = clampf(strength_high, 0.0, 1.0)
	_strength_mid = clampf(strength_mid, 0.0, 1.0)
	_strength_low = clampf(strength_low, 0.0, 1.0)
	_coverage_gain = clampf(coverage_gain, 0.25, 3.0)
	_motion_speed = clampf(motion_speed, 0.0, 0.20)
	_shape_contrast = clampf(shape_contrast, 0.0, 1.0)
	_noise_warp = clampf(noise_warp, 0.0, 1.0)
	_mask_bias = clampf(mask_bias, 0.0, 0.8)
	_cell_scale = clampf(cell_scale, 0.35, 2.5)
	_world_scale = clampf(world_scale, 0.001, 0.05)
	if _field_material != null:
		_field_material.set_shader_parameter("cloud_shadow_coverage_gain", _coverage_gain)
		_field_material.set_shader_parameter("cloud_shadow_motion_speed", _motion_speed)
		_field_material.set_shader_parameter("cloud_shadow_shape_contrast", _shape_contrast)
		_field_material.set_shader_parameter("cloud_shadow_noise_warp", _noise_warp)
		_field_material.set_shader_parameter("cloud_shadow_mask_bias", _mask_bias)
		_field_material.set_shader_parameter("cloud_shadow_cell_scale", _cell_scale)
		_field_material.set_shader_parameter("cloud_shadow_world_scale", _world_scale)
	_update_visibility()


func has_weather_source() -> bool:
	return _has_weather_source


func clear_inputs() -> void:
	_world = null
	_map = null
	_visual_tiles = null
	_has_weather_source = false
	_direct_mode = false
	_dirty = false
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _composite_quad != null:
		_composite_quad.visible = false
	if _debug_quad != null:
		_debug_quad.visible = false


func get_quality_resolution() -> Vector2i:
	return _field_size


func _process(delta: float) -> void:
	if _world == null:
		return
	_world_time += delta
	var update_usec := int(_world.weather_lut_update_usec)
	if update_usec != _last_lut_update_usec:
		if _last_lut_update_usec >= 0:
			var gap := float(update_usec - _last_lut_update_usec)
			if gap > 1000.0 and gap < 5000000.0:
				_commit_interval_usec = lerpf(_commit_interval_usec, gap, 0.3)
		_last_lut_update_usec = update_usec
		_last_lut_change_usec = Time.get_ticks_usec()
		_sync_weather_sources(false)
		_sync_wind_lut(false)
		_mark_dirty()
	var lerp_weight := 1.0
	if _world.weather_lut_prev_tex != null and _commit_interval_usec > 1.0:
		lerp_weight = clampf(float(Time.get_ticks_usec() - _last_lut_change_usec) \
				/ _commit_interval_usec, 0.0, 1.0)
	if absf(lerp_weight - _last_pushed_lerp) >= 0.015:
		_weather_lerp = lerp_weight
		_last_pushed_lerp = lerp_weight
		if _field_material != null:
			_field_material.set_shader_parameter("weather_lerp", _weather_lerp)
		_mark_dirty()
	if _field_material != null:
		_field_material.set_shader_parameter("world_time", _world_time)
	if _has_weather_source:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	else:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE if _dirty else SubViewport.UPDATE_DISABLED
		_dirty = false


func _ensure_nodes() -> void:
	if _viewport == null:
		_viewport = SubViewport.new()
		_viewport.name = "CloudShadowFieldViewport"
		_viewport.size = Vector2i(128, 64)
		_viewport.transparent_bg = true
		_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_viewport)
		_field_texture = _viewport.get_texture()
		_field_quad = ColorRect.new()
		_field_quad.name = "Field"
		_field_quad.color = Color.WHITE
		_field_quad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_viewport.add_child(_field_quad)
	if _composite_quad == null:
		_composite_quad = MeshInstance2D.new()
		_composite_quad.name = "CloudShadowComposite"
		_composite_quad.z_as_relative = true
		_composite_quad.z_index = 0
		add_child(_composite_quad)
	if _debug_quad == null:
		_debug_quad = MeshInstance2D.new()
		_debug_quad.name = "CloudShadowDebug"
		_debug_quad.z_as_relative = true
		_debug_quad.z_index = 1
		add_child(_debug_quad)


func _configure_shaders() -> void:
	if _field_quad == null:
		return
	var tiled := _visual_tiles != null and bool(_visual_tiles.ready) \
			and String(_visual_tiles.layout.mode) == "tiled"
	var shader := ResourceLoader.load(FIELD_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader != null:
		var prefix := "#define MAP_VISUAL_TILED\n" if tiled else ""
		if _direct_mode:
			prefix += "#define CLOUD_SHADOW_DETAIL_HIGH\n#define CLOUD_SHADOW_LOCAL_WIND\n"
		elif not (OS.has_feature("mobile") or OS.has_feature("web") or not _mobile_tier.is_empty()) \
				and _visual_quality >= 1:
			prefix += "#define CLOUD_SHADOW_DETAIL_MID\n"
		else:
			prefix += "#define CLOUD_SHADOW_DETAIL_LOW\n"
		shader = shader.duplicate() as Shader
		shader.code = prefix + shader.code
		_field_material = ShaderMaterial.new()
		_field_material.shader = shader
		_field_quad.material = _field_material
	var composite_shader := ResourceLoader.load(COMPOSITE_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if composite_shader != null:
		_composite_material = ShaderMaterial.new()
		_composite_material.shader = composite_shader
		_composite_quad.material = _composite_material
		_composite_material.set_shader_parameter("cloud_shadow_strength", _strength_for_quality())
		_last_composite_strength = _strength_for_quality()
		_composite_material.set_shader_parameter("night_visibility", 1.0 - _night_factor)
		_last_night_visibility = 1.0 - _night_factor
		_composite_material.set_shader_parameter("cloud_shadow_tex", get_field_texture())
		_composite_material.set_shader_parameter("wrap_x_enabled", _wrap_period_x > 0.0001)
		_composite_material.set_shader_parameter("wrap_origin_uv", get_wrap_origin_uv())
		_composite_material.set_shader_parameter("wrap_period_uv", get_wrap_period_uv())
		if _field_material != null:
			_field_material.set_shader_parameter("cloud_shadow_coverage_gain", _coverage_gain)
			_field_material.set_shader_parameter("cloud_shadow_motion_speed", _motion_speed)
			_field_material.set_shader_parameter("cloud_shadow_shape_contrast", _shape_contrast)
			_field_material.set_shader_parameter("cloud_shadow_noise_warp", _noise_warp)
			_field_material.set_shader_parameter("cloud_shadow_mask_bias", _mask_bias)
			_field_material.set_shader_parameter("cloud_shadow_cell_scale", _cell_scale)
			_field_material.set_shader_parameter("cloud_shadow_world_scale", _world_scale)
	var debug_shader := ResourceLoader.load(DEBUG_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if debug_shader != null:
		_debug_material = ShaderMaterial.new()
		_debug_material.shader = debug_shader
		_debug_quad.material = _debug_material
		_debug_material.set_shader_parameter("cloud_shadow_tex", get_field_texture())
		_debug_material.set_shader_parameter("wrap_x_enabled", _wrap_period_x > 0.0001)
		_debug_material.set_shader_parameter("wrap_origin_uv", get_wrap_origin_uv())
		_debug_material.set_shader_parameter("wrap_period_uv", get_wrap_period_uv())


func _resize_field() -> void:
	var mobile_or_web := OS.has_feature("mobile") or OS.has_feature("web") or not _mobile_tier.is_empty()
	var size := resolution_for_quality(_visual_quality, mobile_or_web)
	if size == _field_size or _viewport == null:
		return
	_field_size = size
	_viewport.size = size
	_mark_dirty()


func _configure_geometry() -> void:
	if _composite_quad == null:
		return
	var bounds := _bounds
	var vertices := PackedVector2Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	var offsets := PackedFloat32Array([0.0])
	if _wrap_period_x > 0.0001:
		offsets = PackedFloat32Array([-_wrap_period_x, 0.0, _wrap_period_x])
	for offset_index in range(offsets.size()):
		var x_offset := offsets[offset_index]
		var first := vertices.size()
		var u_offset := x_offset / maxf(bounds.size.x, 0.0001)
		vertices.append_array(PackedVector2Array([
			bounds.position + Vector2(x_offset, 0.0),
			bounds.position + Vector2(bounds.size.x + x_offset, 0.0),
			bounds.position + bounds.size + Vector2(x_offset, 0.0),
			bounds.position + Vector2(x_offset, bounds.size.y),
		]))
		uv.append_array(PackedVector2Array([
			Vector2(u_offset, 0.0), Vector2(1.0 + u_offset, 0.0),
			Vector2(1.0 + u_offset, 1.0), Vector2(u_offset, 1.0),
		]))
		indices.append_array(PackedInt32Array([
			first, first + 1, first + 2, first, first + 2, first + 3,
		]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_composite_quad.mesh = mesh
	if _debug_quad != null:
		_debug_quad.mesh = mesh


func _push_static_inputs() -> void:
	if _field_material == null or _world == null:
		return
	_field_material.set_shader_parameter("world_origin", _bounds.position)
	_field_material.set_shader_parameter("world_size", _bounds.size)
	_field_material.set_shader_parameter("wrap_origin_x", 0.0)
	_field_material.set_shader_parameter("wrap_period_x", _wrap_period_x)
	_field_material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims))
	if _visual_tiles != null and bool(_visual_tiles.ready) \
			and String(_visual_tiles.layout.mode) == "tiled":
		var layout = _visual_tiles.layout
		_field_material.set_shader_parameter("visual_map_index_tiles", _visual_tiles.map_index)
		_field_material.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
		_field_material.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
		_field_material.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
		_field_material.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
		_field_material.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
		_field_material.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
		_field_material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		_field_material.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)


func _sync_weather_sources(force: bool) -> void:
	if _world == null or _field_material == null:
		_has_weather_source = false
		_update_visibility()
		return
	var current: Texture2D = _world.weather_lut_tex
	var previous: Texture2D = _world.weather_lut_prev_tex
	_has_weather_source = has_valid_weather_source(current, _world.lut_dims)
	if force or _has_weather_source:
		_field_material.set_shader_parameter("weather_lut", current)
		_field_material.set_shader_parameter("weather_lut_prev", previous if previous != null else current)
		_field_material.set_shader_parameter("has_weather_prev", previous != null)
		_field_material.set_shader_parameter("lut_dims", Vector2(_world.lut_dims))
		_field_material.set_shader_parameter("weather_lerp", _weather_lerp)
	_update_visibility()


func _sync_wind_lut(force: bool) -> void:
	if _field_material == null or _map == null:
		return
	var stamp := int(_world.weather_lut_update_usec) if _world != null else 0
	if force or stamp != _last_mean_wind_update_usec:
		_mean_wind = _average_wind(_map)
		_last_mean_wind_update_usec = stamp
	if _field_material != null:
		_field_material.set_shader_parameter("global_wind", Vector2(_mean_wind.x, _mean_wind.y))
	if not _direct_mode:
		return
	if not force and stamp == _last_uploaded_wind_update_usec:
		return
	var image := _build_wind_lut_image(_map, _world.lut_dims if _world != null else Vector2i.ZERO)
	if image != null:
		_field_material.set_shader_parameter("wind_lut", ImageTexture.create_from_image(image))
		_field_material.set_shader_parameter("has_local_wind", true)
	else:
		_field_material.set_shader_parameter("has_local_wind", false)
	_last_uploaded_wind_update_usec = stamp


func _build_wind_lut_image(map: MapData, dims: Vector2i) -> Image:
	if map == null or dims.x <= 0 or dims.y <= 0 \
			or map.wind_x_arr.size() == 0 or map.wind_y_arr.size() != map.wind_x_arr.size():
		return null
	var n := mini(map.wind_x_arr.size(), dims.x * dims.y)
	if n <= 0:
		return null
	var mean_wind := _average_wind(map)
	var mean_dir := Vector2(mean_wind.x, mean_wind.y)
	var mean_speed := mean_wind.z
	var speed_arr := map.wind_speed_arr
	var image := Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	for i in range(dims.x * dims.y):
		var wind := mean_dir
		var speed := mean_speed
		if i < n:
			wind = Vector2(map.wind_x_arr[i], map.wind_y_arr[i])
			if wind.length_squared() > 0.000001:
				wind = wind.normalized()
			else:
				wind = mean_dir
			if i < speed_arr.size():
				speed = float(speed_arr[i])
		image.set_pixel(i % dims.x, int(i / dims.x), encode_wind(wind, speed))
	return image


func _average_wind(map: MapData) -> Vector3:
	if map == null or map.wind_x_arr.is_empty() or map.wind_y_arr.size() != map.wind_x_arr.size():
		return Vector3(0.35, 0.12, 0.0)
	var speed_arr := map.wind_speed_arr
	var sum := Vector2.ZERO
	var speed_sum := 0.0
	var count := map.wind_x_arr.size()
	for i in range(count):
		var direction := Vector2(map.wind_x_arr[i], map.wind_y_arr[i])
		var speed := clampf(float(speed_arr[i]) if i < speed_arr.size() else 1.0, 0.0, 20.0)
		if direction.length_squared() > 0.000001:
			sum += direction.normalized() * maxf(speed, 0.05)
		speed_sum += speed
	var mean_direction := sum.normalized() if sum.length_squared() > 0.000001 \
			else Vector2(0.35, 0.12).normalized()
	return Vector3(mean_direction.x, mean_direction.y, speed_sum / float(maxi(count, 1)))


func _strength_for_quality() -> float:
	if _direct_mode:
		return _strength_high
	if _visual_quality >= 1 and _mobile_tier.is_empty() and not OS.has_feature("mobile") and not OS.has_feature("web"):
		return _strength_mid
	return _strength_low


func _mark_dirty() -> void:
	_dirty = true
	if _viewport != null and not _direct_mode:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _update_visibility() -> void:
	var ready := _has_weather_source and get_field_texture() != null
	if _composite_quad != null:
		_composite_quad.visible = ready and not _direct_mode and not _debug_view
	if _debug_quad != null:
		_debug_quad.visible = ready and _debug_view
	if _composite_material != null:
		var strength := _strength_for_quality()
		if not is_equal_approx(strength, _last_composite_strength):
			_composite_material.set_shader_parameter("cloud_shadow_strength", strength)
			_last_composite_strength = strength
		_push_composite_night_visibility()
	_push_debug_material_inputs()


func _push_debug_material_inputs() -> void:
	if _debug_material == null:
		return
	_debug_material.set_shader_parameter("cloud_shadow_tex", get_field_texture())
	_debug_material.set_shader_parameter("wrap_x_enabled", _wrap_period_x > 0.0001)
	_debug_material.set_shader_parameter("wrap_origin_uv", get_wrap_origin_uv())
	_debug_material.set_shader_parameter("wrap_period_uv", get_wrap_period_uv())


func _push_composite_night_visibility() -> void:
	if _composite_material == null:
		return
	var visibility := 1.0 - _night_factor
	if is_equal_approx(visibility, _last_night_visibility):
		return
	_composite_material.set_shader_parameter("night_visibility", visibility)
	_last_night_visibility = visibility
