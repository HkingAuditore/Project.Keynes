extends RefCounted

## Rendering bindings and profile uniforms; state stays owned by ResourceVisualLayer.

static func _sync_terrain_textures(host) -> void:
	if host._material == null or host._material_geo == null or host._world == null:
		return
	var tiles = host._world.visual_tiles
	var tiled = tiles != null and bool(tiles.ready) and String(tiles.layout.mode) == "tiled"
	var prefix = host.shader_variant_prefix(tiled, host._cloud_shadow_direct)
	var geo_prefix = host.geology_variant_prefix(tiled, host._cloud_shadow_direct)
	if tiled != host._shader_tiled or prefix != host._shader_prefix or geo_prefix != host._shader_geo_prefix:
		host._shader_tiled = tiled
		host._shader_prefix = prefix
		host._shader_geo_prefix = geo_prefix
		host._assign_variant(host._material, prefix)
		host._assign_variant(host._material_geo, geo_prefix)
	for material in host._materials():
		host._bind_terrain_textures(material, tiles, tiled)
	host._push_cloud_shadow_uniforms()

static func set_cloud_shadow_field(host, texture: Texture2D, direct_enabled: bool,
		wrap_origin_uv: float, wrap_period_uv: float) -> void:
	var changed = host._cloud_shadow_direct != direct_enabled
	host._cloud_shadow_direct = direct_enabled
	if texture != null:
		host._cloud_shadow_texture = texture
	host._cloud_shadow_wrap_origin_uv = wrap_origin_uv
	host._cloud_shadow_wrap_period_uv = maxf(wrap_period_uv, 0.0)
	if changed:
		host._sync_terrain_textures()
	host._push_cloud_shadow_uniforms()
	if host._cover != null:
		host._cover.set_cloud_shadow_field(host._cloud_shadow_texture, host._cloud_shadow_direct,
			host._cloud_shadow_wrap_origin_uv, host._cloud_shadow_wrap_period_uv)

static func _push_cloud_shadow_uniforms(host) -> void:
	for material in [host._material, host._material_geo]:
		if material == null or material.shader == null \
				or not material.shader.code.contains("#define PK_CLOUD_SHADOW_DIRECT"):
			continue
		if host._cloud_shadow_texture != null:
			material.set_shader_parameter("cloud_shadow_tex", host._cloud_shadow_texture)
		material.set_shader_parameter("cloud_shadow_field_bound",
			host._cloud_shadow_direct and host._cloud_shadow_texture != null)
		material.set_shader_parameter("cloud_shadow_wrap_origin_uv", host._cloud_shadow_wrap_origin_uv)
		material.set_shader_parameter("cloud_shadow_wrap_period_uv", host._cloud_shadow_wrap_period_uv)

static func _assign_variant(host, target: ShaderMaterial, prefix: String) -> void:
	if target == null:
		return
	if prefix.is_empty():
		target.shader = host.RESOURCE_SHADER
	else:
		var shader = Shader.new()
		shader.code = prefix + host.RESOURCE_SHADER.code
		target.shader = shader

static func _set_param(host, name: String, value) -> void:
	var material: ShaderMaterial = host._material
	var geology: ShaderMaterial = host._material_geo
	if material != null:
		material.set_shader_parameter(name, value)
	if geology != null:
		geology.set_shader_parameter(name, value)

static func _material_for(host, family: int) -> ShaderMaterial:
	# batch 2 = 矿物道具（rt_geology_solid）；桌面两份材质指向同一资源，等价。
	return host._material_geo if family == host.MINERAL_BATCH and host._material_geo != null else host._material

static func _materials(host) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	if host._material != null:
		out.append(host._material)
	if host._material_geo != null:
		out.append(host._material_geo)
	if host._cover != null:
		out.append(host._cover.material())
	return out

static func _bind_terrain_textures(host, target: ShaderMaterial, tiles, tiled: bool) -> void:
	if tiled:
		target.set_shader_parameter("visual_horizon_tiles", tiles.horizon)
		target.set_shader_parameter("visual_terrain_normal_tiles", tiles.terrain_normal)
		target.set_shader_parameter("visual_height_tiles", tiles.height)
		var layout = tiles.layout
		target.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
		target.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
		for pair in [["visual_grid_size", layout.grid_size], ["visual_interior_size", layout.interior_size],
			["visual_layer_size", layout.layer_size], ["visual_logical_resolution", layout.logical_size]]:
			target.set_shader_parameter(pair[0], Vector2(pair[1]))
		target.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		target.set_shader_parameter("terrain_horizon_tex", host._world.terrain_horizon_tex)
		target.set_shader_parameter("terrain_normal_tex", host._world.terrain_normal_tex)
		target.set_shader_parameter("height_tex", host._world.height_tex)
	var height_bound = tiles.height != null if tiled else host._world.height_tex != null
	target.set_shader_parameter("has_height_tex", height_bound)
	target.set_shader_parameter("has_flow_tex",
		DCFeatureFlags.water_flowmap_enabled() and height_bound and not host._world.flow_buffer.is_empty())
	target.set_shader_parameter("sea_level", host._world.sea_level)
	target.set_shader_parameter("terrain_horizon_tex_bound", bool(tiles.horizon_ready) if tiled else host._world.terrain_horizon_tex != null)
	target.set_shader_parameter("terrain_normal_tex_bound", tiles.terrain_normal != null if tiled else host._world.terrain_normal_tex != null)

static func set_terrain_lighting(host, source: ShaderMaterial) -> void:
	if source == null or host._material == null:
		return
	host._sync_terrain_textures()
	for name in ["terrain_horizon_strength", "terrain_horizon_softness", "terrain_horizon_max_angle",
		"terrain_horizon_cast_floor", "terrain_horizon_debug_view", "gi_horizon_lut", "gi_lut_bound",
		"gi_ao_strength", "gi_ao_floor", "gi_ao_smoothing", "gi_bent_strength", "gi_normal_floor",
		"sky_ibl_bound", "sky_ambient_strength", "sky_day_sh_l1", "sky_night_sh_l1"]:
		var value = source.get_shader_parameter(name)
		if value != null:
			for material in host._materials():
				material.set_shader_parameter(name, value)

static func _apply_profile(host) -> void:
	for name in ["vitality_dead_threshold", "vitality_power", "climate_response", "snow_response",
		"wind_strength", "animal_motion", "detailed_pixels", "simple_pixels", "fade_pixels",
		"palette_saturation", "badge_px", "decal_opacity", "submerged_opacity",
		"decal_slope_fit", "decal_ground_tint",
		"outline_strength", "contact_shadow", "cast_shadow", "luma_compress", "luma_range",
			"area_feather", "area_edge_noise", "solid_edge_softness", "decal_edge_softness",
			"decal_edge_noise", "plant_cluster_density", "river_clear_threshold"]:
		host._set_param(name, host.profile.get(name))
	for name in ["herd_size_min", "herd_size_max", "animal_length_hex", "animal_min_pixels"]:
		host._set_param(name, host.profile.get(name))
	host._set_param("herd_radius_hex", host.herd_radius_hex())
	host._set_param("visual_quality", host.quality())
	host._set_param("filter_style", host._filter_style)
	if host._cover != null:
		host._cover.apply_profile(host.profile)
		host._cover.set_quality(host.quality(), host._mobile_tier)

static func _build_style_texture(host) -> void:
	# shader在第143-144行从X=0.25和X=0.75采样
	# 在4像素宽的纹理中：0.25→像素1(颜色)，0.75→像素3(元数据)
	var image = Image.create(4, 64, false, Image.FORMAT_RGBAF)
	host._max_style_scale = 1.0
	for i in host._styles.size():
		var e = host._styles[i]
		var override: Dictionary = host.profile.style_overrides.get(e.id, {})
		host._max_style_scale = maxf(host._max_style_scale, float(override.get("size_scale", 1.0)))
		var art = ResourceArtLibrary.shared()
		var material_cell = art.material_cell(e.id)
		# X=0.125采样（像素0）：specular、材质图集格+1、是否绑定位图、metallic。
		image.set_pixel(0, i, Color(float(e.get("specular", 0.0)),
			float(material_cell + 1), 1.0 if material_cell >= 0 else 0.0,
			float(e.get("metallic", 0.0))))
		# X=0.25采样（像素1）：颜色数据
		var color_val = override.get("color", e.color) if override.has("color") else e.color
		image.set_pixel(1, i, color_val)
		# X=0.75采样（像素3）：元数据(form, family, sub_style, metallic)
		image.set_pixel(3, i, Color(float(e.form), float(e.family), float(e.get("sub_style", i % 4)), float(e.get("metallic", 0.0))))
		# X=0.625采样（像素2）：动物/鱼位图（-, 图集层+1, 图集精灵数, -）；0 = 无位图。
		# 植物位图由 ResourceGroundCover 自己的 LUT 映射。
		var fauna_layer = art.fauna_layer(e.id)
		image.set_pixel(2, i, Color(0.0, float(fauna_layer + 1),
			float(art.fauna_count) if fauna_layer >= 0 else 0.0, 0.0))
	host._set_param("style_lut", ImageTexture.create_from_image(image))
	host._bind_art()

static func _bind_art(host) -> void:
	var art = ResourceArtLibrary.shared()
	host._set_param("art_fauna_bound", art.fauna != null)
	if art.fauna != null:
		host._set_param("art_fauna", art.fauna)
	host._set_param("art_material_bound", art.material != null)
	if art.material != null:
		host._set_param("art_material", art.material)

## The clock can move each frame while the wind, lighting and bound textures stay the same.
static func sync_frame_bindings(host, time: float, sun: Vector3, state: Dictionary) -> void:
	var dyn: Texture2D = host._world.dyn_lut_tex if host._world != null else null
	var eco: Texture2D = host._world.eco_lut_tex if host._world != null else null
	var enums: Texture2D = host._world.enum_lut_tex if host._world != null else null
	var resource_shader: Shader = host._material.shader
	var geology_shader: Shader = host._material_geo.shader
	var cover: ResourceGroundCover = host._cover
	var inputs := {"state": state, "sun": sun, "dyn": dyn, "eco": eco, "enum": enums,
		"resource_shader": resource_shader, "geology_shader": geology_shader}
	if cover != null:
		inputs.merge({"cover_shader": cover.material().shader, "memory_only": cover.memory_climate_only,
			"memory": host._memory_texture, "fog": host._fog})
	var previous: Dictionary = host._last_frame_bindings
	var old_inputs: Dictionary = previous.get("inputs", {})
	if inputs == old_inputs:
		if cover != null:
			cover.material().set_shader_parameter("world_time", time)
		return

	var values := state.duplicate()
	values.merge({"tod_sun_dir": sun})
	values.merge({"dyn_lut": dyn, "has_dynamic_lut": dyn != null,
		"eco_lut": eco, "has_ecology_lut": eco != null, "enum_lut": enums}, true)
	var old_values: Dictionary = previous.get("values", {})
	var rebind: bool = old_inputs.get("resource_shader") != resource_shader or old_inputs.get("geology_shader") != geology_shader
	for name in values:
		var value: Variant = values[name]
		if rebind or not old_values.has(name) or old_values[name] != value:
			host._set_param(name, value)
	inputs.state = state.duplicate()
	host._last_frame_bindings = {"inputs": inputs, "values": values}
	if cover != null:
		var cover_state := state.duplicate()
		cover_state.merge({"tod_sun_dir": sun, "fog_enabled": host._fog, "dyn_lut": dyn,
			"has_dynamic_lut": dyn != null, "enum_lut": enums}, true)
		cover.set_frame_state(time, cover_state, host._memory_texture)
