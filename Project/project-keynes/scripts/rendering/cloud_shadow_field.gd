class_name CloudShadowField
extends Node2D

signal wind_lut_changed(current: Texture2D, previous: Texture2D, has_previous: bool)

const FIELD_SHADER_PATH := "res://shaders/cloud_shadow_field.gdshader"
const COMPOSITE_SHADER_PATH := "res://shaders/cloud_shadow_composite.gdshader"
const DEBUG_SHADER_PATH := "res://shaders/cloud_shadow_debug.gdshader"
## 云影强度是最终直射光的最大压暗比例。云量遮罩本身已经做了柔化，
## 这里提高到可感知范围，避免中等云量只有几个百分点的变化。
const CLOUD_SHADOW_STRENGTH_HIGH := 0.85
const CLOUD_SHADOW_STRENGTH_MID := 0.62
const CLOUD_SHADOW_STRENGTH_LOW := 0.48
## [cloud-tex 2026-11-07] 离线烘焙的 Perlin-Worley 噪声（4 通道多尺度、无缝）。
## 由 tools/prebake_cloud_shadow_noise.gd 生成；缺失时云影整体关闭而不是画成全黑。
const CLOUD_NOISE_TEXTURE_PATH := "res://assets/textures/cloud_shadow/cloud_noise_rgba.res"
const CLOUD_BASE_TEXTURE_PATH := "res://assets/textures/cloud_shadow/cloud_shadow_base_rgba.res"
const CLOUD_SHADOW_MOTION_SPEED := 0.15
## UV 平流增益：生产场景把 motion_speed 降低、world_scale 提高后，原始 UV
## 位移只有不到 1 texel/s；8.0 才能稳定看见连续滚动，场景会按自身尺度覆写。
const CLOUD_SHADOW_UV_SCROLL_GAIN := 8.0
const CLOUD_SHADOW_SHAPE_CONTRAST := 1.0
const CLOUD_SHADOW_NOISE_WARP := 0.36
const CLOUD_SHADOW_DYNAMIC_DETAIL_GAIN := 0.32
const CLOUD_SHADOW_DYNAMIC_WARP_GAIN := 0.80
const CLOUD_SHADOW_EDGE_SOFTNESS := 1.10
const CLOUD_SHADOW_WIND_INFLUENCE := 0.22
const CLOUD_SHADOW_MASK_BIAS := 0.10
const CLOUD_SHADOW_CELL_SCALE := 0.75
## [cloud-shape 2026-11-07] 0.0045 时一个噪声单元≈222 世界单位（约 6 hex），
## 云团直径 7~12 hex，整屏只有 3~5 团，读起来像"整片明暗不均"。0.0160 把
## 单元压到约 62 世界单位（1.6 hex），云团直径 3~5 hex，一朵云影在 zoom 0.9
## 下约 100~180px，既独立可辨又不会碎成斑点。
const CLOUD_SHADOW_WORLD_SCALE := 0.0130
## 侵蚀强度：把边缘啃成絮状并在云内部掏洞。0 = 退回单层圆疙瘩。
## 0.40 只侵蚀边缘、云体保持实心；再高会让云内部碎成迷彩。
const CLOUD_SHADOW_EROSION := 0.40
## 形状噪声与天气 mask 共用同一张 field texture。world_time 每帧推进，若这里
## 仍按 20Hz 重绘，噪声会呈现“停住—跳一下”的节奏；提高到显示刷新节奏后，
## 云形位移连续，mask 的取值逻辑保持不变。移动/Web 低分辨率场的成本仍很小。
const FIELD_UPDATE_HZ := 60.0

var _world: WorldData
var _map: MapData
var _bounds := Rect2()
var _wrap_period_x := 0.0
var _hex_world_diameter := 44.0
var _visual_tiles
var _visual_quality := 1
var _mobile_tier := ""
var _direct_mode := false
var _debug_view := false
var _night_factor := 0.0
var _world_time := 0.0
var _world_time_external := false
var _weather_lerp := 1.0
var _last_lut_update_usec := -1
var _last_lut_change_usec := 0
var _commit_interval_usec := 500000.0
var _last_pushed_lerp := -1.0
var _last_uploaded_wind_update_usec := -1
var _wind_lut_texture: Texture2D
var _last_composite_strength := -1.0
var _last_night_visibility := -1.0
var _strength_high := CLOUD_SHADOW_STRENGTH_HIGH
var _strength_mid := CLOUD_SHADOW_STRENGTH_MID
var _strength_low := CLOUD_SHADOW_STRENGTH_LOW
var _coverage_gain := 1.25
var _motion_speed := CLOUD_SHADOW_MOTION_SPEED
var _uv_scroll_gain := CLOUD_SHADOW_UV_SCROLL_GAIN
var _shape_contrast := CLOUD_SHADOW_SHAPE_CONTRAST
var _noise_warp := CLOUD_SHADOW_NOISE_WARP
var _dynamic_detail_gain := CLOUD_SHADOW_DYNAMIC_DETAIL_GAIN
var _dynamic_warp_gain := CLOUD_SHADOW_DYNAMIC_WARP_GAIN
var _edge_softness := CLOUD_SHADOW_EDGE_SOFTNESS
var _wind_influence := CLOUD_SHADOW_WIND_INFLUENCE
var _mask_bias := CLOUD_SHADOW_MASK_BIAS
var _cell_scale := CLOUD_SHADOW_CELL_SCALE
var _world_scale := CLOUD_SHADOW_WORLD_SCALE
var _erosion := CLOUD_SHADOW_EROSION
var _field_update_accum := 1.0
var _has_weather_source := false
static var _noise_texture_cache: Texture2D = null
static var _base_texture_cache: Texture2D = null
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
	if mobile_or_web:
		return [Vector2i(128, 64), Vector2i(192, 96), Vector2i(256, 128)][clampi(quality, 0, 2)]
	return [Vector2i(128, 64), Vector2i(256, 128), Vector2i(512, 256)][clampi(quality, 0, 2)]


static func quality_for_tier(quality: int, tier: String) -> int:
	var cap := 2
	if tier == "MOBILE_QUALITY_LOW":
		cap = 0
	elif tier == "MOBILE_QUALITY_MID":
		cap = 1
	return mini(clampi(quality, 0, 2), cap)


static func direct_mode_for_quality(quality: int, mobile_or_web: bool,
		shader_tier: String) -> bool:
	# [cloud-gi 2026-11-07] 从 quality>=2 下放到 >=1。中画质原来走 composite 的
	# `blend_mul` 整屏乘法，那会把**最终像素**一起乘暗 —— 直射光、环境光、天光、
	# bounce 全被压同样比例，暗部（本来就靠环境光照亮）于是发灰发脏。真实云影
	# 只挡直射阳光，环境光几乎不受影响。direct 路径按层分开算（direct_shadow /
	# cloud_ambient），才是物理正确的做法；代价只是各层多一次 field 纹理采样，
	# 反而省掉了一整屏 composite pass。
	return quality >= 1 and not mobile_or_web and shader_tier.is_empty()


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
		wrap_period_x: float, quality: int, mobile_tier: String, direct_mode: bool,
		hex_world_diameter: float = 44.0) -> void:
	var world_changed := _world != world
	var map_changed := _map != map
	var tiled := visual_tiles != null and bool(visual_tiles.ready) \
			and String(visual_tiles.layout.mode) == "tiled"
	var next_quality := quality_for_tier(quality, mobile_tier)
	var shader_changed := not _configured or _shader_tiled != tiled \
			or _direct_mode != direct_mode or _visual_quality != next_quality
	var geometry_changed := not _configured or _bounds != bounds \
			or not is_equal_approx(_wrap_period_x, wrap_period_x)
	_world = world
	_map = map
	_bounds = bounds
	_wrap_period_x = maxf(wrap_period_x, 0.0)
	_hex_world_diameter = maxf(hex_world_diameter, 1.0)
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
		_wind_lut_texture = null
		_weather_lerp = 1.0
		_last_pushed_lerp = -1.0
	_sync_weather_sources(not _configured or world_changed)
	_sync_wind_lut(not _configured or map_changed or shader_changed)
	if shader_changed or geometry_changed or world_changed or map_changed:
		_mark_dirty()
	_configured = true
	_update_visibility()


func set_quality(quality: int, mobile_tier: String, direct_mode: bool) -> void:
	var next_quality := quality_for_tier(quality, mobile_tier)
	var changed := _visual_quality != next_quality \
			or _mobile_tier != mobile_tier or _direct_mode != direct_mode
	if not changed:
		return
	var shader_changed := changed
	_visual_quality = next_quality
	_mobile_tier = mobile_tier
	_direct_mode = direct_mode
	if shader_changed:
		_configure_shaders()
		_push_static_inputs()
		_sync_weather_sources(true)
		_sync_wind_lut(true)
	_resize_field()
	_mark_dirty()
	_update_visibility()


func set_night_factor(value: float) -> void:
	_night_factor = clampf(value, 0.0, 1.0)
	_push_composite_night_visibility()


func set_world_time(value: float) -> void:
	# HexRenderer 的统一 world_time 是所有动态 shader 的时间源；云影不再
	# 使用自己的 delta 累加器，确保暂停、倍速和其它地形/天气动画同相位。
	var next_time := maxf(value, 0.0)
	_world_time = next_time
	_world_time_external = true
	if _field_material != null:
		_field_material.set_shader_parameter("world_time", _world_time)


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
		world_scale: float = CLOUD_SHADOW_WORLD_SCALE,
		erosion: float = CLOUD_SHADOW_EROSION,
		uv_scroll_gain: float = CLOUD_SHADOW_UV_SCROLL_GAIN,
		dynamic_detail_gain: float = CLOUD_SHADOW_DYNAMIC_DETAIL_GAIN,
		dynamic_warp_gain: float = CLOUD_SHADOW_DYNAMIC_WARP_GAIN,
		edge_softness: float = CLOUD_SHADOW_EDGE_SOFTNESS,
		wind_influence: float = CLOUD_SHADOW_WIND_INFLUENCE) -> void:
	_strength_high = clampf(strength_high, 0.0, 1.0)
	_strength_mid = clampf(strength_mid, 0.0, 1.0)
	_strength_low = clampf(strength_low, 0.0, 1.0)
	_coverage_gain = clampf(coverage_gain, 0.25, 3.0)
	_motion_speed = clampf(motion_speed, 0.0, 0.20)
	_uv_scroll_gain = clampf(uv_scroll_gain, 0.0, 32.0)
	_shape_contrast = clampf(shape_contrast, 0.0, 1.0)
	_noise_warp = clampf(noise_warp, 0.0, 1.0)
	_dynamic_detail_gain = clampf(dynamic_detail_gain, 0.0, 1.0)
	_dynamic_warp_gain = clampf(dynamic_warp_gain, 0.0, 2.0)
	_edge_softness = clampf(edge_softness, 0.0, 2.0)
	_wind_influence = clampf(wind_influence, 0.0, 1.0)
	_mask_bias = clampf(mask_bias, 0.0, 0.8)
	_cell_scale = clampf(cell_scale, 0.35, 2.5)
	_world_scale = clampf(world_scale, 0.001, 0.05)
	_erosion = clampf(erosion, 0.0, 1.0)
	if _field_material != null:
		_field_material.set_shader_parameter("cloud_shadow_coverage_gain", _coverage_gain)
		_field_material.set_shader_parameter("cloud_shadow_motion_speed", _motion_speed)
		_field_material.set_shader_parameter("cloud_shadow_uv_scroll_gain", _uv_scroll_gain)
		_field_material.set_shader_parameter("cloud_shadow_shape_contrast", _shape_contrast)
		_field_material.set_shader_parameter("cloud_shadow_noise_warp", _noise_warp)
		_field_material.set_shader_parameter("cloud_shadow_dynamic_detail_gain", _dynamic_detail_gain)
		_field_material.set_shader_parameter("cloud_shadow_dynamic_warp_gain", _dynamic_warp_gain)
		_field_material.set_shader_parameter("cloud_shadow_edge_softness", _edge_softness)
		_field_material.set_shader_parameter("cloud_shadow_wind_influence", _wind_influence)
		_field_material.set_shader_parameter("cloud_shadow_mask_bias", _mask_bias)
		_field_material.set_shader_parameter("cloud_shadow_cell_scale", _cell_scale)
		_field_material.set_shader_parameter("cloud_shadow_world_scale", _world_scale)
		_field_material.set_shader_parameter("cloud_shadow_erosion", _erosion)
	_update_visibility()


func has_weather_source() -> bool:
	return _has_weather_source


func clear_inputs() -> void:
	_world = null
	_map = null
	_wind_lut_texture = null
	wind_lut_changed.emit(null, null, false)
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
	if not _world_time_external:
		# 独立运行 CloudShadowField（没有 HexRenderer host）时保留本地时钟兜底。
		var next_time := _world_time + maxf(delta, 0.0)
		_world_time = next_time
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
	_field_update_accum += delta
	if _has_weather_source:
		# [cloud-shape 2026-11-07] 形状噪声依赖 world_time，必须按显示刷新节奏重绘；
		# 否则会出现明显的“停住—跳一下”。FIELD_UPDATE_HZ 对移动/Web 的低分辨率
		# 场仍保持较低像素成本，天气 LUT 变化时 _mark_dirty() 仍会立即刷新。
		if _field_update_accum >= 1.0 / FIELD_UPDATE_HZ:
			_field_update_accum = 0.0
			_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
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
		if _visual_quality >= 2:
			prefix += "#define CLOUD_SHADOW_DETAIL_HIGH\n"
		elif _visual_quality >= 1:
			prefix += "#define CLOUD_SHADOW_DETAIL_MID\n"
		else:
			prefix += "#define CLOUD_SHADOW_DETAIL_LOW\n"
		shader = shader.duplicate() as Shader
		shader.code = prefix + shader.code
		_field_material = ShaderMaterial.new()
		_field_material.shader = shader
		_field_quad.material = _field_material
		var noise_tex := _shared_noise_texture()
		if noise_tex == null:
			push_error("[cloud-shadow] noise texture missing: %s" % CLOUD_NOISE_TEXTURE_PATH)
		var base_tex := _shared_base_texture()
		if base_tex == null:
			push_warning("[cloud-shadow] base texture missing, using dynamic noise as fallback: %s" % CLOUD_BASE_TEXTURE_PATH)
			base_tex = noise_tex
		_field_material.set_shader_parameter("cloud_shadow_base_tex", base_tex)
		_field_material.set_shader_parameter("cloud_noise_tex", noise_tex)
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
			_field_material.set_shader_parameter("cloud_shadow_uv_scroll_gain", _uv_scroll_gain)
			_field_material.set_shader_parameter("cloud_shadow_shape_contrast", _shape_contrast)
			_field_material.set_shader_parameter("cloud_shadow_noise_warp", _noise_warp)
			_field_material.set_shader_parameter("cloud_shadow_dynamic_detail_gain", _dynamic_detail_gain)
			_field_material.set_shader_parameter("cloud_shadow_dynamic_warp_gain", _dynamic_warp_gain)
			_field_material.set_shader_parameter("cloud_shadow_edge_softness", _edge_softness)
			_field_material.set_shader_parameter("cloud_shadow_wind_influence", _wind_influence)
			_field_material.set_shader_parameter("cloud_shadow_mask_bias", _mask_bias)
			_field_material.set_shader_parameter("cloud_shadow_cell_scale", _cell_scale)
			_field_material.set_shader_parameter("cloud_shadow_world_scale", _world_scale)
			_field_material.set_shader_parameter("cloud_shadow_erosion", _erosion)
	var debug_shader := ResourceLoader.load(DEBUG_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if debug_shader != null:
		_debug_material = ShaderMaterial.new()
		_debug_material.shader = debug_shader
		_debug_quad.material = _debug_material
		_debug_material.set_shader_parameter("cloud_shadow_tex", get_field_texture())
		_debug_material.set_shader_parameter("wrap_x_enabled", _wrap_period_x > 0.0001)
		_debug_material.set_shader_parameter("wrap_origin_uv", get_wrap_origin_uv())
		_debug_material.set_shader_parameter("wrap_period_uv", get_wrap_period_uv())


static func _shared_noise_texture() -> Texture2D:
	if _noise_texture_cache != null:
		return _noise_texture_cache
	var image := load(CLOUD_NOISE_TEXTURE_PATH) as Image
	if image == null:
		return null
	# 烘焙时已经 generate_mipmaps()，这里原样上传，filter_linear_mipmap 才有效。
	_noise_texture_cache = ImageTexture.create_from_image(image)
	return _noise_texture_cache


static func _shared_base_texture() -> Texture2D:
	if _base_texture_cache != null:
		return _base_texture_cache
	var image := load(CLOUD_BASE_TEXTURE_PATH) as Image
	if image == null:
		return null
	_base_texture_cache = ImageTexture.create_from_image(image)
	return _base_texture_cache


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
	_field_material.set_shader_parameter("cloud_shadow_hex_world_diameter", _hex_world_diameter)
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
	if not force and stamp == _last_uploaded_wind_update_usec:
		return
	var image := _build_wind_lut_image(_map, _world.lut_dims if _world != null else Vector2i.ZERO)
	if image != null:
		var previous := _wind_lut_texture
		_wind_lut_texture = ImageTexture.create_from_image(image)
		_field_material.set_shader_parameter("wind_lut", _wind_lut_texture)
		_field_material.set_shader_parameter("wind_lut_prev", previous if previous != null else _wind_lut_texture)
		_field_material.set_shader_parameter("has_wind_prev", previous != null and not force)
		_field_material.set_shader_parameter("has_local_wind", true)
		wind_lut_changed.emit(_wind_lut_texture, previous if previous != null else _wind_lut_texture, previous != null and not force)
	else:
		_field_material.set_shader_parameter("has_local_wind", false)
		wind_lut_changed.emit(null, null, false)
	_last_uploaded_wind_update_usec = stamp


func _build_wind_lut_image(map: MapData, dims: Vector2i) -> Image:
	if map == null or dims.x <= 0 or dims.y <= 0 \
			or map.wind_x_arr.size() == 0 or map.wind_y_arr.size() != map.wind_x_arr.size():
		return null
	var n := mini(map.wind_x_arr.size(), dims.x * dims.y)
	if n <= 0:
		return null
	var speed_arr := map.wind_speed_arr
	var image := Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	for i in range(dims.x * dims.y):
		var wind := Vector2.ZERO
		var speed := 0.0
		if i < n:
			wind = Vector2(map.wind_x_arr[i], map.wind_y_arr[i])
			if wind.length_squared() > 0.000001:
				wind = wind.normalized()
			if i < speed_arr.size():
				speed = float(speed_arr[i])
		image.set_pixel(i % dims.x, int(i / dims.x), encode_wind(wind, speed))
	return image


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
