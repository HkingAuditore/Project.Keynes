extends RefCounted

## Refreshes the building materials from the world textures and lighting.

static func _rebind_world_textures(layer: BuildingVisualLayer) -> void:
	if layer._world == null:
		return
	var materials := [layer._body_material, layer._shadow_material, layer._decal_material]
	for material in materials:
		if material == null:
			continue
		material.set_shader_parameter("dyn_lut", layer._world.dyn_lut_tex)
		material.set_shader_parameter("enum_lut", layer._world.enum_lut_tex)
		material.set_shader_parameter("lut_dims", Vector2(layer._world.lut_dims))
		material.set_shader_parameter("cell_count",
			float(layer._map.cell_count()) if layer._map != null else 1.0)
	if layer._body_material != null:
		layer._body_material.set_shader_parameter("weather_lut", layer._world.weather_lut_tex)
	if layer._decal_material != null:
		layer._decal_material.set_shader_parameter("weather_lut", layer._world.weather_lut_tex)
	if layer._macro_material != null:
		layer._macro_material.set_shader_parameter("map_index_atlas", layer._world.enum_atlas_tex)
		if layer._macro_index_high_texture != null:
			layer._macro_material.set_shader_parameter(
				"cell_index_high_atlas", layer._macro_index_high_texture)
		layer._macro_material.set_shader_parameter("enum_lut", layer._world.enum_lut_tex)
		layer._macro_material.set_shader_parameter("lut_dims", Vector2(layer._world.lut_dims))
		if layer._world.enum_atlas_tex != null:
			layer._macro_material.set_shader_parameter("atlas_pixel_size", Vector2(
				1.0 / maxf(1.0, layer._world.enum_atlas_tex.get_width()),
				1.0 / maxf(1.0, layer._world.enum_atlas_tex.get_height())))
	var bounds := layer._world.world_bounds
	var daylight_materials := [layer._body_material, layer._shadow_material, layer._decal_material,
		layer._macro_material]
	for material in daylight_materials:
		if material == null:
			continue
		material.set_shader_parameter("world_origin", bounds.position)
		material.set_shader_parameter("world_size", Vector2(
			maxf(bounds.size.x, 0.0001), maxf(bounds.size.y, 0.0001)))
		material.set_shader_parameter("wrap_origin_x", 0.0)
		material.set_shader_parameter("wrap_period_x", layer._world.wrap_period_x)
	layer._cloud_shadow_wrap_origin_uv = (0.0 - bounds.position.x) / maxf(bounds.size.x, 0.0001)
	layer._cloud_shadow_wrap_period_uv = layer._world.wrap_period_x / maxf(bounds.size.x, 0.0001)
	layer._sync_terrain_textures()
	layer._push_material_state()
	layer._push_cloud_shadow_uniforms()


static func _push_material_state(layer: BuildingVisualLayer) -> void:
	for material in [layer._body_material, layer._shadow_material, layer._decal_material]:
		if material != null:
			material.set_shader_parameter("camera_zoom", layer._camera_zoom)
			material.set_shader_parameter("visual_quality", layer._visual_quality)
	if layer._shadow_material != null:
		layer._shadow_material.set_shader_parameter("shadow_strength",
			0.0 if OS.has_feature("web") else float(BuildingVisualLayer.SHADOW_STRENGTH[layer._visual_quality]))
	if layer._macro_material != null:
		layer._macro_material.set_shader_parameter("camera_zoom", layer._camera_zoom)
		# The macro pass now gates its terrain lighting on the same quality tier.
		layer._macro_material.set_shader_parameter("visual_quality", layer._visual_quality)
	layer._push_lod_fraction()
	layer._set_tod_parameter("season_phase", layer._season_phase)
	layer._set_tod_parameter("day_phase", layer._day_phase)
	layer._set_tod_parameter("axial_tilt_rad", layer._axial_tilt_rad)
	layer._set_tod_parameter("day_night_enabled", layer._day_night_enabled)
	layer._set_tod_parameter("tod_debug_sun_position_enabled",
		layer._tod_debug_sun_position_enabled)
	layer._set_tod_parameter("tod_debug_sun_uv", layer._tod_debug_sun_uv)
	layer._set_tod_parameter("tod_debug_sun_height_scale",
		layer._tod_debug_sun_height_scale)
	layer._set_tod_parameter("tod_sun_dir", layer._tod_sun_dir)
	layer._set_tod_parameter("eternal_min_elevation_rad", layer._eternal_min_elevation_rad)
	layer._set_tod_parameter("eternal_max_hour_angle_rad", layer._eternal_max_hour_angle_rad)
	layer._set_tod_parameter("tod_exposure", layer._tod_exposure, false)


## [building-terrain-light 2026-10-18] 高画质建筑共享地形光照：地表法线（body/decal 在
## vertex 每实例一次；macro 是整图 quad，只能逐像素）与 8 方向 horizon GI（fragment 逐像素）。
## 这里只做纹理绑定与参数同步，档位门控在 shader 里按 visual_quality >= 2 短路，所以低/中
## 画质的材质与接入前完全一致。数据源与 ShrubLayer / ResourceVisualLayer 是同一个 world +
## 同一个地形材质，避免出现"屋顶按一套 horizon 算、脚下地形按另一套算"。


static func set_terrain_lighting(layer: BuildingVisualLayer, source: ShaderMaterial) -> void:
	layer._sync_terrain_textures()
	if source == null:
		return
	for name in BuildingVisualLayer.TERRAIN_LIGHTING_PARAMS:
		var value: Variant = source.get_shader_parameter(name)
		if value == null:
			continue
		for material in [layer._body_material, layer._decal_material, layer._macro_material]:
			if material != null:
				material.set_shader_parameter(name, value)


static func set_cloud_shadow_field(layer: BuildingVisualLayer, texture: Texture2D, direct_enabled: bool,
		wrap_origin_uv: float, wrap_period_uv: float) -> void:
	var variant_changed := layer._cloud_shadow_direct != direct_enabled
	layer._cloud_shadow_direct = direct_enabled
	if texture != null:
		layer._cloud_shadow_texture = texture
	layer._cloud_shadow_wrap_origin_uv = wrap_origin_uv
	layer._cloud_shadow_wrap_period_uv = maxf(wrap_period_uv, 0.0)
	if variant_changed:
		layer._apply_cloud_shadow_shader_variants()
	layer._push_cloud_shadow_uniforms()


static func _apply_cloud_shadow_shader_variants(layer: BuildingVisualLayer) -> void:
	for entry in [[layer._body_material, layer._body_shader_source],
			[layer._shadow_material, layer._shadow_shader_source],
			[layer._decal_material, layer._decal_shader_source],
			[layer._macro_material, layer._macro_shader_source]]:
		layer._assign_shader_variant(entry[0], entry[1])


static func _push_cloud_shadow_uniforms(layer: BuildingVisualLayer) -> void:
	for material in [layer._body_material, layer._shadow_material, layer._decal_material, layer._macro_material]:
		if material == null or material.shader == null \
				or not material.shader.code.contains("#define PK_CLOUD_SHADOW_DIRECT"):
			continue
		if layer._cloud_shadow_texture != null:
			material.set_shader_parameter("cloud_shadow_tex", layer._cloud_shadow_texture)
		material.set_shader_parameter("cloud_shadow_field_bound",
			layer._cloud_shadow_direct and layer._cloud_shadow_texture != null)
		material.set_shader_parameter("cloud_shadow_wrap_origin_uv", layer._cloud_shadow_wrap_origin_uv)
		material.set_shader_parameter("cloud_shadow_wrap_period_uv", layer._cloud_shadow_wrap_period_uv)


static func _sync_terrain_textures(layer: BuildingVisualLayer) -> void:
	if layer._world == null:
		return
	var tiles: Variant = layer._world.visual_tiles
	var tiled := tiles != null and bool(tiles.ready) \
		and String(tiles.layout.mode) == "tiled"
	if tiled != layer._shader_tiled:
		layer._shader_tiled = tiled
		layer._apply_terrain_shader_variants()
	for material in [layer._body_material, layer._decal_material, layer._macro_material]:
		if material == null:
			continue
		if tiled:
			material.set_shader_parameter("visual_horizon_tiles", tiles.horizon)
			material.set_shader_parameter("visual_terrain_normal_tiles", tiles.terrain_normal)
			var layout: Variant = tiles.layout
			material.set_shader_parameter("visual_domain_origin",
				layout.visual_domain.position)
			material.set_shader_parameter("visual_domain_size",
				layout.visual_domain.size)
			for pair in [["visual_grid_size", layout.grid_size],
					["visual_interior_size", layout.interior_size],
					["visual_layer_size", layout.layer_size],
					["visual_logical_resolution", layout.logical_size]]:
				material.set_shader_parameter(pair[0], Vector2(pair[1]))
			material.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))
		else:
			material.set_shader_parameter("terrain_horizon_tex",
				layer._world.terrain_horizon_tex)
			material.set_shader_parameter("terrain_normal_tex",
				layer._world.terrain_normal_tex)
		material.set_shader_parameter("terrain_horizon_tex_bound",
			bool(tiles.horizon_ready) if tiled else layer._world.terrain_horizon_tex != null)
		material.set_shader_parameter("terrain_normal_tex_bound",
			tiles.terrain_normal != null if tiled else layer._world.terrain_normal_tex != null)


## tiled 与 legacy 的地表寻址由 #ifdef 选一套：legacy 声明 sampler2D，tiled 声明
## sampler2DArray + 图块寻址 uniform。形态切换必须换 shader 代码，否则采样器类型与
## 绑定不匹配（与 ResourceVisualLayer 同处理）。body / decal / macro 都要换。


static func _apply_terrain_shader_variants(layer: BuildingVisualLayer) -> void:
	# tiled 宏与 web 档位宏统一由 compose_shader_code 合成，避免两处前缀各写一半。
	for entry in [[layer._body_material, layer._body_shader_source],
			[layer._decal_material, layer._decal_shader_source],
			[layer._macro_material, layer._macro_shader_source]]:
		layer._assign_shader_variant(entry[0], entry[1])
