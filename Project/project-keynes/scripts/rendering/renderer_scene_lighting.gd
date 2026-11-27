extends RefCounted

## Publishes sky and time-of-day uniform changes to the live renderer layers.

# Phase 1：让 main.gd 在 WorldClock day_changed 时推进 shader 季节相位

static func set_season_phase(host, phase: float) -> void:

	host._season_phase = phase
	host._push_water_lighting_uniforms()
	if host._shader_mat != null:
		host._push_world_uniform("season_phase", host._season_phase)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_season_phase(host._season_phase)
	if host._weather_layer != null:
		host._weather_layer.set_season_phase(host._season_phase)
	if host._fog_layer != null:
		host._fog_layer.set_season_phase(host._season_phase)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_season_phase(host._season_phase)
	)
	host._sync_detail_and_activity_materials()


static func set_climate_anomaly(host, v: float) -> void:

	host._climate_anomaly = v
	if host._shader_mat != null:
		host._push_world_uniform("climate_anomaly", host._climate_anomaly)

# True Insolation-Driven（Phase F）：旧兼容 setter。运行时和 shader 统一保持
# insolation 分支，bool 只保留给旧材质参数兼容。

static func set_true_insolation_enabled(host, v: bool) -> void:

	var _unused_v: bool = v
	host.true_insolation_enabled = true
	if host._shader_mat != null:
		host._push_world_uniform("true_insolation_enabled", host.true_insolation_enabled)

# 任务 2：昼夜相位。由 main.gd 接收 WorldClock.day_phase_changed 信号后转发。
# 同时写入地形 shader 与 weather overlay shader（两者都需要昼夜相位。但后者

static func set_day_phase(host, v: float) -> void:

	host._day_phase = fposmod(v, 1.0)
	host._push_world_uniform("sky_global_day_weight", host._global_sky_day_weight())
	if host._sky_background != null:
		host._sky_background.set_global_time(host._day_phase, host.day_night_enabled)
	host._push_water_lighting_uniforms()
	if host._shader_mat != null:
		host._push_world_uniform("day_phase", host._day_phase)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_day_phase(host._day_phase)
	if host._weather_layer != null:
		host._weather_layer.set_day_phase(host._day_phase)
	if host._fog_layer != null:
		host._fog_layer.set_day_phase(host._day_phase)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_day_phase(host._day_phase)
	)
	host._sync_detail_and_activity_materials()



static func set_tod_debug_sun_position(host, enabled: bool, uv: Vector2) -> void:

	host._tod_debug_sun_position_enabled = enabled
	host._tod_debug_sun_uv = Vector2(fposmod(uv.x, 1.0), clampf(uv.y, 0.0, 1.0))
	if host._shader_mat != null:
		host._push_world_uniform("tod_debug_sun_position_enabled", host._tod_debug_sun_position_enabled)
		host._push_world_uniform("tod_debug_sun_uv", host._tod_debug_sun_uv)
	if host._weather_layer != null and host._weather_layer.has_method("set_tod_debug_sun_position"):
		host._weather_layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	if host._fog_layer != null:
		host._fog_layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_tod_debug_sun_position(
			host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_tod_debug_sun_position"):
			layer.set_tod_debug_sun_position(host._tod_debug_sun_position_enabled, host._tod_debug_sun_uv)
	)
	host._sync_detail_and_activity_materials()



static func set_tod_debug_sun_height_scale(host, v: float) -> void:

	host._tod_debug_sun_height_scale = clampf(v, 0.2, 1.5)
	if host._shader_mat != null:
		host._push_world_uniform("tod_debug_sun_height_scale", host._tod_debug_sun_height_scale)
	if host._weather_layer != null and host._weather_layer.has_method("set_tod_debug_sun_height_scale"):
		host._weather_layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
	if host._fog_layer != null:
		host._fog_layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_tod_debug_sun_height_scale(
			host._tod_debug_sun_height_scale)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_tod_debug_sun_height_scale"):
			layer.set_tod_debug_sun_height_scale(host._tod_debug_sun_height_scale)
	)
	host._sync_detail_and_activity_materials()
