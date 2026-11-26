extends RefCounted

## Copies published lighting and animation uniforms into vegetation family materials.

static func sync_dynamic(materials: Dictionary, representatives: Dictionary,
		shadow_materials: Dictionary, shadow_representatives: Dictionary) -> void:
	var params := [
		"world_time", "season_phase", "day_phase", "wind_dir", "weather_wind_boost",
		"axial_tilt_rad", "day_night_enabled", "tod_sun_dir", "tod_exposure",
		"tod_debug_sun_position_enabled", "tod_debug_sun_uv", "tod_debug_sun_height_scale",
		"eternal_min_elevation_rad", "eternal_max_hour_angle_rad",
	]
	for raw_family in materials.keys():
		var family := int(raw_family)
		var target: ShaderMaterial = materials[raw_family]
		var representative = representatives.get(family, null)
		if target == null or representative == null or representative._material == null:
			continue
		for param in params:
			target.set_shader_parameter(param, representative._material.get_shader_parameter(param))
	# Shadow copies are duplicated at configure time; without this they keep
	# the sun of that moment and stop following day, season and debug sun.
	var shadow_params := [
		"season_phase", "day_phase", "axial_tilt_rad", "day_night_enabled", "tod_sun_dir",
		"tod_debug_sun_position_enabled", "tod_debug_sun_uv", "tod_debug_sun_height_scale",
		"eternal_min_elevation_rad", "eternal_max_hour_angle_rad",
	]
	for raw_family in shadow_materials.keys():
		var shadow_target: ShaderMaterial = shadow_materials[raw_family]
		var shadow_source = shadow_representatives.get(int(raw_family), null)
		if shadow_target == null or shadow_source == null or shadow_source._shadow_material == null:
			continue
		for param in shadow_params:
			shadow_target.set_shader_parameter(param,
				shadow_source._shadow_material.get_shader_parameter(param))


static func set_sky_lighting(source: ShaderMaterial, materials: Dictionary) -> void:
	if source == null:
		return
	var values := {}
	for name in ["sky_ibl_bound", "sky_ambient_strength", "sky_day_sh_l1", "sky_night_sh_l1"]:
		var value: Variant = source.get_shader_parameter(name)
		if value != null:
			values[name] = value
	for material in materials.values():
		if material == null:
			continue
		for name in values:
			material.set_shader_parameter(name, values[name])
