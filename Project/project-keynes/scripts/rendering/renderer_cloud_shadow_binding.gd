extends RefCounted

static func _visual_tiles_active(host) -> bool:

	return host._world != null and host._world.visual_tiles != null \
		and bool(host._world.visual_tiles.ready) \
		and String(host._world.visual_tiles.layout.mode) == "tiled"


static func _cloud_shadow_direct_active(host) -> bool:

	return host.CloudShadowFieldScript.direct_mode_for_quality(
		host.visual_quality,
		OS.has_feature("mobile") or OS.has_feature("web"),
		host._mobile_quality_tier_define)


static func _configure_cloud_shadow_field(host) -> void:

	if host._cloud_shadow_field == null:
		return
	if host._weather_layer != null and not host._cloud_shadow_field.wind_lut_changed.is_connected(host._weather_layer.set_wind_luts):
		host._cloud_shadow_field.wind_lut_changed.connect(host._weather_layer.set_wind_luts)
	host._cloud_shadow_field.configure_wind_inputs(host._world, host._map)
	if not host._graphics_details.cloud_shadow_enabled():
		host._cloud_shadow_field.clear_shadow_inputs()
		_push_cloud_shadow_material_inputs(host)
		return
	if host._world == null or host._map == null:
		host._cloud_shadow_field.clear_inputs()
		_push_cloud_shadow_material_inputs(host)
		return
	var tiled = _visual_tiles_active(host)
	host._cloud_shadow_field.set_tuning(
		host.cloud_shadow_strength_high,
		host.cloud_shadow_strength_mid,
		host.cloud_shadow_strength_low,
		host.cloud_shadow_coverage_gain,
		host.cloud_shadow_motion_speed,
		host.cloud_shadow_shape_contrast,
		host.cloud_shadow_noise_warp,
		host.cloud_shadow_mask_bias,
		host.cloud_shadow_tile_repeat,
		host.cloud_shadow_world_scale,
		host.cloud_shadow_erosion,
		host.cloud_shadow_uv_scroll_gain,
		host.cloud_shadow_dynamic_detail_gain,
		host.cloud_shadow_dynamic_warp_gain,
		host.cloud_shadow_edge_softness,
		host.cloud_shadow_wind_influence,
		host.cloud_shadow_interior_detail,
		host.cloud_shadow_detail_texel_world)
	host._cloud_shadow_field.configure(
		host._world.world_bounds,
		host._world,
		host._map,
		host._world.visual_tiles if tiled else null,
		host._wrap_period_x(),
		host.visual_quality,
		host._mobile_quality_tier_define,
		_cloud_shadow_direct_active(host),
		2.0 * host.hex_size)
	host._cloud_shadow_field.set_world_time(host._world_time)
	host._cloud_shadow_field.set_night_factor(host._tod_night_factor if host.day_night_enabled else 0.0)
	host._cloud_shadow_field.set_debug_view(host.cloud_shadow_debug_view)


static func _push_cloud_shadow_tuning(host) -> void:

	if host._cloud_shadow_field == null:
		return
	host._cloud_shadow_field.set_tuning(
		host.cloud_shadow_strength_high,
		host.cloud_shadow_strength_mid,
		host.cloud_shadow_strength_low,
		host.cloud_shadow_coverage_gain,
		host.cloud_shadow_motion_speed,
		host.cloud_shadow_shape_contrast,
		host.cloud_shadow_noise_warp,
		host.cloud_shadow_mask_bias,
		host.cloud_shadow_tile_repeat,
		host.cloud_shadow_world_scale,
		host.cloud_shadow_erosion,
		host.cloud_shadow_uv_scroll_gain,
		host.cloud_shadow_dynamic_detail_gain,
		host.cloud_shadow_dynamic_warp_gain,
		host.cloud_shadow_edge_softness,
		host.cloud_shadow_wind_influence,
		host.cloud_shadow_interior_detail,
		host.cloud_shadow_detail_texel_world)
	_push_cloud_shadow_material_inputs(host)


static func _push_cloud_shadow_material_inputs(host) -> void:

	host.RendererLightingBindings.push_cloud_shadow_material_inputs(
		host._cloud_shadow_field,
		host._shader_mat,
		host._water_mat,
		host.cloud_shadow_ambient_weight,
		host.cloud_shadow_water_scale,
		host._building_visual_layer,
		host._resource_visual_layer,
		host._for_each_vegetation_layer,
		host._detail_family_layer,
		host._cloud_shadow_direct_active() and host._graphics_details.cloud_shadow_enabled())
