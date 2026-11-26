extends RefCounted

const TerrainRenderScale = preload("res://scripts/rendering/terrain_render_scale.gd")

## Player preferences for this renderer. Bare renderer callers retain the
## platform policy by leaving each setting unset.
var water_detail := -1
var vegetation_detail := -1
var cloud_shadow: Variant = null
var terrain_scale_percent := 100
var _terrain_scale: TerrainRenderScale


func water_flowmap_enabled() -> bool:
	return DCFeatureFlags.water_flowmap_enabled() if water_detail < 0 else water_detail >= 2


func cloud_shadow_enabled() -> bool:
	return DCFeatureFlags.cloud_shadow_enabled() if cloud_shadow == null else bool(cloud_shadow)


func apply_terrain_scale(host, percent: int, msaa: Viewport.MSAA) -> void:
	if host._world_quad == null:
		return
	if _terrain_scale == null:
		if percent == 100:
			return
		_terrain_scale = TerrainRenderScale.new()
		host.add_child(_terrain_scale)
	var changed := terrain_scale_percent != percent
	terrain_scale_percent = percent
	_terrain_scale.apply(host._world_quad, percent, msaa)
	_terrain_scale.attach_water(host._water_quad)
	if changed:
		host._push_world_uniform("pixel_world_size", host._refresh_pixel_world_size())


func scaled_surface_parent(surface: MeshInstance2D) -> Node2D:
	return _terrain_scale.main_canvas_parent(surface) if _terrain_scale != null else null


func attach_water_surface(host) -> void:
	if _terrain_scale != null:
		_terrain_scale.attach_water(host._water_quad)
	else:
		host.add_child(host._water_quad)
		if is_instance_valid(host._world_quad):
			host.move_child(host._water_quad, mini(host._world_quad.get_index() + 1, host.get_child_count() - 1))


func apply(host, settings: Dictionary) -> void:
	var next_water := clampi(int(settings.get("water_detail", -1)), -1, 2)
	if next_water != water_detail:
		water_detail = next_water
		host._push_world_uniform("water_detail_override", water_detail)
		if host._world != null:
			host._push_world_uniform("ocean_current_flow_tex_bound",
				water_flowmap_enabled() and host._world.ocean_current_flow_tex != null)
		if host._water_quad != null and host._water_variant_prefix != host._water_program_prefix(host._water_variant_kind):
			host._sync_water_quad()

	if host._fog_layer != null:
		host._fog_layer.set_render_scale(int(settings.get("fog_render_scale", -1)))
	if host._weather_layer != null:
		host._weather_layer.set_weather_detail(int(settings.get("weather_detail", -1)))
		host._apply_weather_layer_render_gate()

	var next_shadow: Variant = settings.get("cloud_shadow")
	if next_shadow != cloud_shadow:
		cloud_shadow = next_shadow
		host._configure_cloud_shadow_field()
		host._push_cloud_shadow_material_inputs()

	var next_vegetation := clampi(int(settings.get("vegetation_detail", -1)), -1, 2)
	if next_vegetation == vegetation_detail:
		return
	vegetation_detail = next_vegetation
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_density_detail(vegetation_detail)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_density_detail(vegetation_detail)
	)
	if host._detail_family_layer != null and host._map != null:
		host._detail_family_layer.configure(host._detail_layers, host.detail_scatter_family_renderer_enabled)
		if host.detail_scatter_family_renderer_enabled and host._camera_view_initialized:
			host._queue_missing_prefetch_detail_chunks()
			host._reactivate_deferred_detail_chunks()
	host._mark_detail_budget_total_dirty()
	host._apply_detail_global_budget()
