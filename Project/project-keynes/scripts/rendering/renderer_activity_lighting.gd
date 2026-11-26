extends RefCounted

## Keeps trade, military and detail layer materials in step with terrain lighting.

## Player scene assembly supplies the trade layer and the world published at readiness.

static func configure_trade_visuals(host, layer: TradeActivityLayer, world: WorldData) -> void:

	host._trade_visual_layer = layer
	if is_instance_valid(layer):
		layer.set_terrain_lighting(world, host._shader_mat)
		_sync_trade_daylight(host)


## Military formations are also a read-only map visual. Register them through
## the renderer so they consume the same daylight/horizon state as terrain and
## trade convoys instead of maintaining a second lighting authority.

static func configure_military_visuals(host, layer: MilitaryArmyTokenLayer) -> void:

	host._military_visual_layer = layer
	if is_instance_valid(layer):
		layer.set_visual_quality(host.visual_quality)
		layer.set_terrain_lighting(host._world, host._shader_mat)
		_sync_military_daylight(host)



static func _instance_daylight_parameters(host) -> Dictionary:

	return {
		"season_phase": host._season_phase,
		"day_phase": host._day_phase,
		"axial_tilt_rad": deg_to_rad(host.axial_tilt_deg),
		"day_night_enabled": host.day_night_enabled,
		"tod_debug_sun_position_enabled": host._tod_debug_sun_position_enabled,
		"tod_debug_sun_uv": host._tod_debug_sun_uv,
		"tod_debug_sun_height_scale": host._tod_debug_sun_height_scale,
		"eternal_min_elevation_rad": deg_to_rad(host.eternal_min_elevation_deg),
		"eternal_max_hour_angle_rad": deg_to_rad(host.eternal_max_hour_angle_deg),
		"tod_sun_dir": host._tod_sun_dir,
		"tod_exposure": host._tod_exposure,
	}



static func _sync_trade_daylight(host) -> void:

	if not is_instance_valid(host._trade_visual_layer):
		return
	host._trade_visual_layer.set_daylight_parameters(
		_instance_daylight_parameters(host))



static func _sync_military_daylight(host) -> void:

	if not is_instance_valid(host._military_visual_layer):
		return
	host._military_visual_layer.set_daylight_parameters(
		_instance_daylight_parameters(host))



static func _sync_detail_and_activity_materials(host) -> void:

	_sync_trade_daylight(host)
	_sync_military_daylight(host)
	if is_instance_valid(host._military_visual_layer):
		host._military_visual_layer.set_visual_quality(host.visual_quality)
	if host.detail_scatter_family_renderer_enabled and host._detail_family_layer != null \
			and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.sync_dynamic_materials()
