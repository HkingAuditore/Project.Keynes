class_name WorldLightingField
extends Node2D

## Low-frequency shared dynamic lighting field (Node2D + 3 SubViewports):
##   Pass 1 (gi_size):        Direct exitant radiance D on coarse PTT-GI grid
##   Pass 2 (gi_size):        K=8 PTT-GI indirect bounce gather
##   Pass 3 (composite_size): Composite world_lighting_tex
##                            RGB = PTT-GI indirect irradiance / RADIANCE_SCALE (LINEAR)
##                            A   = dynamic terrain direct-sun visibility [0, 1]
## Updated on-demand via dirty flag throttled to UPDATE_HZ; 0 GPU cost when idle/paused.

const RADIANCE_SCALE := 2.0
const UPDATE_HZ := 12.0
const DEFAULT_GI_SIZE := Vector2i(128, 64)
const PttGiBaker = preload("res://scripts/rendering/bakers/ptt_gi_baker.gd")

const DIRECT_RADIANCE_SHADER_PATH := "res://shaders/world_gi_direct_radiance.gdshader"
const GATHER_SHADER_PATH := "res://shaders/world_gi_gather.gdshader"
const COMPOSITE_SHADER_PATH := "res://shaders/world_lighting_composite.gdshader"

const DEFAULT_HORIZON_STRENGTH := 1.20
const DEFAULT_HORIZON_SOFTNESS := 0.30

var _world: WorldData
var _bounds := Rect2()
var _wrap_period_x := 0.0
var _visual_quality := 1
var _mobile_tier := ""
var _shader_tiled := false
var _configured := false
var _map_drawn := true

var _gi_size := DEFAULT_GI_SIZE
var _composite_size := Vector2i(512, 256)
var _ptt_gi_ready := false
var _has_horizon_source := false
var _direct_shadow_enabled := true

var _dirty := false
var _needs_initial_refresh := true
var _update_accum := 0.0
var _render_trigger_count := 0

# Daylight parameters (cached for change detection so idle/paused frames do 0 GPU work)
var _daylight_initialized := false
var _day_phase := 0.25
var _season_phase := 0.0
var _axial_tilt_rad := 0.4091
var _day_night_enabled := false
var _tod_sun_dir := Vector3(0.0, 0.0, 1.0)
var _tod_latitude_sun_enabled := true
var _tod_sun_relief_max_up := 0.88
var _tod_debug_sun_position_enabled := false
var _tod_debug_sun_uv := Vector2(0.5, 0.5)
var _tod_debug_sun_height_scale := 1.0
var _eternal_min_elevation_rad := 0.17453293
var _eternal_max_hour_angle_rad := 1.22173048

# Horizon shadow parameters
var _horizon_strength := DEFAULT_HORIZON_STRENGTH
var _horizon_softness := DEFAULT_HORIZON_SOFTNESS

# 3-pass SubViewport chain (added in strict execution order: 1 -> 2 -> 3)
var _direct_viewport: SubViewport
var _direct_quad: ColorRect
var _direct_material: ShaderMaterial
var _direct_texture: ViewportTexture

var _gather_viewport: SubViewport
var _gather_quad: ColorRect
var _gather_material: ShaderMaterial
var _gather_texture: ViewportTexture

var _composite_viewport: SubViewport
var _composite_quad: ColorRect
var _composite_material: ShaderMaterial
var _composite_texture: ViewportTexture


static func quality_for_tier(quality: int, tier: String) -> int:
	var cap := 2
	if tier == "MOBILE_QUALITY_LOW":
		cap = 0
	elif tier == "MOBILE_QUALITY_MID":
		cap = 1
	return mini(clampi(quality, 0, 2), cap)


static func composite_resolution_for_quality(quality: int, mobile_or_web: bool,
		hm_size: Vector2i = Vector2i.ZERO) -> Vector2i:
	var q := clampi(quality, 0, 2)
	var target: Vector2i = (
		[Vector2i(256, 128), Vector2i(384, 192), Vector2i(512, 256)][q]
		if mobile_or_web else
		[Vector2i(384, 192), Vector2i(512, 256), Vector2i(1024, 512)][q]
	)
	if hm_size.x > 0 and hm_size.y > 0:
		target = Vector2i(
			maxi(mini(target.x, hm_size.x), 1),
			maxi(mini(target.y, hm_size.y), 1)
		)
	return target


static func direct_shadow_enabled_for_quality(quality: int, mobile_or_web: bool,
		mobile_tier: String) -> bool:
	var effective_q := quality_for_tier(quality, mobile_tier)
	return not (mobile_or_web and effective_q <= 0)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var map_renderer := get_parent() as CanvasItem
	if map_renderer != null:
		map_renderer.visibility_changed.connect(_sync_map_visibility.bind(map_renderer))
		_sync_map_visibility(map_renderer)
	set_process(_configured)


func configure(world: WorldData, bounds: Rect2, wrap_period_x: float,
		visual_quality: int, mobile_tier: String, hex_size: float = 0.0) -> void:
	if world == null:
		clear_inputs()
		return

	_mobile_tier = mobile_tier
	var next_quality := quality_for_tier(visual_quality, mobile_tier)
	if not OS.has_feature("web") and _is_limited_platform() and next_quality == 0:
		world.ptt_albedo_refresh_suspended = true
		clear_inputs()
		return

	_ensure_nodes()
	if world.ptt_bake_deferred and hex_size > 0.0:
		world.ptt_bake_deferred = false
		var result := PttGiBaker.bake_world(null, world, hex_size, world.bounce_lut_bytes)
		if not bool(result.get("ok", false)):
			push_warning("WorldLightingField: PTT-GI bake failed - %s" % String(result.get("reason", "")))
	elif world.ptt_albedo_refresh_suspended and world.ptt_gi_ready:
		PttGiBaker.refresh_albedo(world, world.bounce_lut_bytes)
	world.ptt_albedo_refresh_suspended = false

	var world_changed := _world != world
	var tiled := _is_world_tiled(world)
	var shader_changed := _composite_material == null or _shader_tiled != tiled

	if world_changed:
		_disconnect_albedo()
		_world = world
		_world.ptt_albedo_changed.connect(mark_albedo_dirty)
	_bounds = bounds
	_wrap_period_x = maxf(wrap_period_x, 0.0)
	_visual_quality = next_quality
	_direct_shadow_enabled = direct_shadow_enabled_for_quality(
		visual_quality, _is_limited_platform(), mobile_tier
	)

	if shader_changed:
		_shader_tiled = tiled
		_configure_shaders()

	_sync_ptt_inputs()
	_resize_viewports()
	_push_static_inputs()
	_push_daylight_uniforms()
	_push_horizon_uniforms()

	_configured = true
	set_process(true)
	if world_changed or shader_changed:
		_needs_initial_refresh = true
	_dirty = true


func clear_inputs() -> void:
	_disconnect_albedo()
	_world = null
	_configured = false
	_ptt_gi_ready = false
	_has_horizon_source = false
	_dirty = false
	_needs_initial_refresh = true
	set_process(false)
	_disable_all_viewports()


func set_daylight_params(day_phase: float, season_phase: float, axial_tilt_rad: float,
		day_night_enabled: bool, tod_sun_dir: Vector3,
		tod_debug_sun_position_enabled: bool, tod_debug_sun_uv: Vector2,
		tod_debug_sun_height_scale: float, eternal_min_elevation_rad: float,
		eternal_max_hour_angle_rad: float, latitude_sun_enabled: bool = true,
		sun_relief_max_up: float = 0.88) -> void:
	var changed := (
		not _daylight_initialized
		or not is_equal_approx(_day_phase, day_phase)
		or not is_equal_approx(_season_phase, season_phase)
		or not is_equal_approx(_axial_tilt_rad, axial_tilt_rad)
		or _day_night_enabled != day_night_enabled
		or not _tod_sun_dir.is_equal_approx(tod_sun_dir)
		or _tod_latitude_sun_enabled != latitude_sun_enabled
		or not is_equal_approx(_tod_sun_relief_max_up, sun_relief_max_up)
		or _tod_debug_sun_position_enabled != tod_debug_sun_position_enabled
		or not _tod_debug_sun_uv.is_equal_approx(tod_debug_sun_uv)
		or not is_equal_approx(_tod_debug_sun_height_scale, tod_debug_sun_height_scale)
		or not is_equal_approx(_eternal_min_elevation_rad, eternal_min_elevation_rad)
		or not is_equal_approx(_eternal_max_hour_angle_rad, eternal_max_hour_angle_rad)
	)
	if not changed:
		return
	_daylight_initialized = true
	_day_phase = day_phase
	_season_phase = season_phase
	_axial_tilt_rad = axial_tilt_rad
	_day_night_enabled = day_night_enabled
	_tod_sun_dir = tod_sun_dir
	_tod_latitude_sun_enabled = latitude_sun_enabled
	_tod_sun_relief_max_up = sun_relief_max_up
	_tod_debug_sun_position_enabled = tod_debug_sun_position_enabled
	_tod_debug_sun_uv = tod_debug_sun_uv
	_tod_debug_sun_height_scale = tod_debug_sun_height_scale
	_eternal_min_elevation_rad = eternal_min_elevation_rad
	_eternal_max_hour_angle_rad = eternal_max_hour_angle_rad
	if _configured:
		_push_daylight_uniforms()
		_dirty = true


func set_horizon_params(strength: float, softness: float) -> void:
	var next_strength := clampf(strength, 0.0, 1.5)
	var next_softness := clampf(softness, 0.01, 1.0)
	if is_equal_approx(_horizon_strength, next_strength) \
			and is_equal_approx(_horizon_softness, next_softness):
		return
	_horizon_strength = next_strength
	_horizon_softness = next_softness
	if _configured:
		_push_horizon_uniforms()
		_dirty = true


func _disconnect_albedo() -> void:
	if _world != null and _world.ptt_albedo_changed.is_connected(mark_albedo_dirty):
		_world.ptt_albedo_changed.disconnect(mark_albedo_dirty)


func mark_albedo_dirty() -> void:
	if _world != null:
		_sync_ptt_inputs()
		_resize_viewports()
	_dirty = true


func get_lighting_texture() -> Texture2D:
	if _composite_texture != null:
		return _composite_texture
	return _composite_viewport.get_texture() if _composite_viewport != null else null


func is_lighting_ready() -> bool:
	return _configured and _world != null and get_lighting_texture() != null \
		and (_ptt_gi_ready or _has_horizon_source)


func get_radiance_scale() -> float:
	return RADIANCE_SCALE


func get_composite_resolution() -> Vector2i:
	return _composite_size


func get_gi_resolution() -> Vector2i:
	return _gi_size


func is_dirty() -> bool:
	return _dirty


func get_render_trigger_count() -> int:
	return _render_trigger_count


func _process(delta: float) -> void:
	if not _configured or _world == null or not _map_drawn:
		return
	if not _dirty:
		return
	_update_accum += maxf(delta, 0.0)
	if _needs_initial_refresh or _update_accum >= 1.0 / UPDATE_HZ:
		_update_accum = 0.0
		_needs_initial_refresh = false
		_dirty = false
		_trigger_render_passes()


func _trigger_render_passes() -> void:
	if _direct_viewport == null or _gather_viewport == null or _composite_viewport == null:
		return
	if _ptt_gi_ready:
		_direct_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		_gather_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	else:
		_direct_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_gather_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_composite_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_render_trigger_count += 1


func _disable_all_viewports() -> void:
	if _direct_viewport != null:
		_direct_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _gather_viewport != null:
		_gather_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _composite_viewport != null:
		_composite_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _sync_map_visibility(map_renderer: CanvasItem) -> void:
	_map_drawn = map_renderer.is_visible_in_tree()
	if not _map_drawn:
		_disable_all_viewports()
	elif _configured and _world != null:
		_dirty = true


func _is_limited_platform() -> bool:
	return DCFeatureFlags.is_limited_render_platform() \
		or (not OS.has_feature("web") and not _mobile_tier.is_empty())


static func _is_world_tiled(world: WorldData) -> bool:
	if world == null:
		return false
	var vt: Variant = world.visual_tiles
	return vt != null and bool(vt.ready) and String(vt.layout.mode) == "tiled"


func _ensure_nodes() -> void:
	if _direct_viewport == null:
		_direct_viewport = _create_pass_viewport("WorldGIDirectRadianceViewport", _gi_size)
		add_child(_direct_viewport)
		_direct_texture = _direct_viewport.get_texture()
		_direct_quad = _create_pass_quad("DirectRadianceQuad")
		_direct_viewport.add_child(_direct_quad)

	if _gather_viewport == null:
		_gather_viewport = _create_pass_viewport("WorldGIGatherViewport", _gi_size)
		add_child(_gather_viewport)
		_gather_texture = _gather_viewport.get_texture()
		_gather_quad = _create_pass_quad("GatherQuad")
		_gather_viewport.add_child(_gather_quad)

	if _composite_viewport == null:
		_composite_viewport = _create_pass_viewport("WorldLightingCompositeViewport", _composite_size)
		add_child(_composite_viewport)
		_composite_texture = _composite_viewport.get_texture()
		_composite_quad = _create_pass_quad("CompositeQuad")
		_composite_viewport.add_child(_composite_quad)


static func _create_pass_viewport(vp_name: String, vp_size: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = vp_name
	vp.size = vp_size
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	return vp


static func _create_pass_quad(quad_name: String) -> ColorRect:
	var quad := ColorRect.new()
	quad.name = quad_name
	quad.color = Color.WHITE
	quad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return quad


func _configure_shaders() -> void:
	var direct_shader := ResourceLoader.load(
		DIRECT_RADIANCE_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	) as Shader
	if direct_shader != null:
		_direct_material = ShaderMaterial.new()
		_direct_material.shader = direct_shader
		_direct_material.set_shader_parameter("radiance_scale", RADIANCE_SCALE)
		_direct_quad.material = _direct_material

	var gather_shader := ResourceLoader.load(
		GATHER_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	) as Shader
	if gather_shader != null:
		_gather_material = ShaderMaterial.new()
		_gather_material.shader = gather_shader
		_gather_material.set_shader_parameter("direct_radiance_tex", _direct_texture)
		_gather_quad.material = _gather_material

	var composite_shader := ResourceLoader.load(
		COMPOSITE_SHADER_PATH, "Shader", ResourceLoader.CACHE_MODE_IGNORE
	) as Shader
	if composite_shader != null:
		if _shader_tiled:
			composite_shader = composite_shader.duplicate() as Shader
			composite_shader.code = "#define MAP_VISUAL_TILED\n" + composite_shader.code
		_composite_material = ShaderMaterial.new()
		_composite_material.shader = composite_shader
		_composite_material.set_shader_parameter("indirect_light_tex", _gather_texture)
		_composite_quad.material = _composite_material


func _sync_ptt_inputs() -> void:
	if _world == null:
		_ptt_gi_ready = false
		return

	var ptt_ready_flag := bool(_world.get("ptt_gi_ready"))
	var ptt_albedo: Texture2D = _world.get("ptt_albedo_tex") as Texture2D
	var ptt_coupling: Texture2D = _world.get("ptt_coupling_tex") as Texture2D
	var ptt_transfer: Texture2DArray = _world.get("ptt_transfer_idx_tex") as Texture2DArray
	var raw_gi_size: Variant = _world.get("ptt_gi_size")
	var next_gi_size := raw_gi_size as Vector2i if raw_gi_size is Vector2i else Vector2i.ZERO
	if next_gi_size.x <= 0 or next_gi_size.y <= 0:
		next_gi_size = DEFAULT_GI_SIZE

	_gi_size = next_gi_size
	_ptt_gi_ready = (
		ptt_ready_flag
		and ptt_albedo != null
		and ptt_coupling != null
		and ptt_transfer != null
	)

	if _direct_material != null:
		_direct_material.set_shader_parameter("ptt_albedo_tex", ptt_albedo)
		_direct_material.set_shader_parameter("ptt_coupling_tex", ptt_coupling)
		_direct_material.set_shader_parameter("radiance_scale", RADIANCE_SCALE)
		_direct_material.set_shader_parameter("ptt_gi_ready", _ptt_gi_ready)

	if _gather_material != null:
		_gather_material.set_shader_parameter("direct_radiance_tex", _direct_texture)
		_gather_material.set_shader_parameter("ptt_transfer_idx_tex", ptt_transfer)
		_gather_material.set_shader_parameter("ptt_coupling_tex", ptt_coupling)
		_gather_material.set_shader_parameter("gi_size", Vector2(_gi_size))
		_gather_material.set_shader_parameter("ptt_gi_ready", _ptt_gi_ready)

	if _composite_material != null:
		_composite_material.set_shader_parameter("indirect_light_tex", _gather_texture)
		_composite_material.set_shader_parameter("ptt_gi_ready", _ptt_gi_ready)


func _resize_viewports() -> void:
	if _direct_viewport != null and _direct_viewport.size != _gi_size:
		_direct_viewport.size = _gi_size
	if _gather_viewport != null and _gather_viewport.size != _gi_size:
		_gather_viewport.size = _gi_size
	var hm_size := _world.hm_size if _world != null else Vector2i.ZERO
	var next_comp := composite_resolution_for_quality(
		_visual_quality, _is_limited_platform(), hm_size
	)
	if _composite_viewport != null and (_composite_size != next_comp or _composite_viewport.size != next_comp):
		_composite_size = next_comp
		_composite_viewport.size = next_comp


func _push_static_inputs() -> void:
	if _world == null:
		return

	for mat in [_direct_material, _composite_material]:
		if mat == null:
			continue
		mat.set_shader_parameter("world_origin", _bounds.position)
		mat.set_shader_parameter("world_size", _bounds.size)
		mat.set_shader_parameter("wrap_origin_x", 0.0)
		mat.set_shader_parameter("wrap_period_x", _wrap_period_x)

	if _composite_material == null:
		return

	var latitude_height := _world.derived_size.y
	var horizon_dir_bound := false
	var horizon_packed_bound := false
	if _shader_tiled:
		var vt: Variant = _world.visual_tiles
		var layout: Variant = vt.layout
		latitude_height = layout.logical_size.y
		_composite_material.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
		_composite_material.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
		_composite_material.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
		_composite_material.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
		_composite_material.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
		_composite_material.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
		_composite_material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))
		if vt.horizon != null:
			_composite_material.set_shader_parameter("visual_horizon_tiles", vt.horizon)
		if vt.horizon_dir0 != null:
			_composite_material.set_shader_parameter("visual_horizon_dir0_tiles", vt.horizon_dir0)
		if vt.horizon_dir1 != null:
			_composite_material.set_shader_parameter("visual_horizon_dir1_tiles", vt.horizon_dir1)
		horizon_dir_bound = bool(vt.horizon_dir_ready) and vt.horizon_dir0 != null and vt.horizon_dir1 != null
		horizon_packed_bound = bool(vt.horizon_ready) and vt.horizon != null
	else:
		var surface_tex: Texture2DArray = _world.terrain_surface_tex
		var surface_layers := int(surface_tex.get_layers()) if surface_tex != null else 0
		_composite_material.set_shader_parameter("terrain_surface_tex", surface_tex)
		_composite_material.set_shader_parameter("terrain_surface_layer_count", surface_layers)
		_composite_material.set_shader_parameter("terrain_horizon_tex", _world.terrain_horizon_tex)
		horizon_dir_bound = bool(_world.terrain_horizon_dir_layers_bound) \
			and surface_tex != null and surface_layers >= 10
		horizon_packed_bound = _world.terrain_horizon_tex != null

	_composite_material.set_shader_parameter("horizon_dir_tex_bound", horizon_dir_bound)
	_composite_material.set_shader_parameter("terrain_horizon_tex_bound", horizon_packed_bound)
	_composite_material.set_shader_parameter("direct_shadow_enabled", _direct_shadow_enabled)
	_composite_material.set_shader_parameter("daylight_height_px", float(maxi(latitude_height, 2)))
	_has_horizon_source = horizon_dir_bound or horizon_packed_bound


func _push_daylight_uniforms() -> void:
	for mat in [_direct_material, _composite_material]:
		if mat == null:
			continue
		mat.set_shader_parameter("day_phase", _day_phase)
		mat.set_shader_parameter("season_phase", _season_phase)
		mat.set_shader_parameter("axial_tilt_rad", _axial_tilt_rad)
		mat.set_shader_parameter("day_night_enabled", _day_night_enabled)
		mat.set_shader_parameter("tod_sun_dir", _tod_sun_dir)
		mat.set_shader_parameter("tod_debug_sun_position_enabled", _tod_debug_sun_position_enabled)
		mat.set_shader_parameter("tod_debug_sun_uv", _tod_debug_sun_uv)
		mat.set_shader_parameter("tod_debug_sun_height_scale", _tod_debug_sun_height_scale)
		mat.set_shader_parameter("eternal_min_elevation_rad", _eternal_min_elevation_rad)
		mat.set_shader_parameter("eternal_max_hour_angle_rad", _eternal_max_hour_angle_rad)
	if _composite_material != null:
		_composite_material.set_shader_parameter("tod_latitude_sun_enabled", _tod_latitude_sun_enabled)
		_composite_material.set_shader_parameter("tod_sun_relief_max_up", _tod_sun_relief_max_up)


func _push_horizon_uniforms() -> void:
	if _composite_material == null:
		return
	_composite_material.set_shader_parameter("terrain_horizon_strength", _horizon_strength)
	_composite_material.set_shader_parameter("terrain_horizon_softness", _horizon_softness)
	_composite_material.set_shader_parameter("terrain_horizon_max_angle", MapBaker.TERRAIN_HORIZON_MAX_ANGLE)
