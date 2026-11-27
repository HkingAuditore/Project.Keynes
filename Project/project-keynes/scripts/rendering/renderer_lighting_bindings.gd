extends RefCounted

## Binds water and shared sky lighting to individual materials and visual layers through explicit renderer ports.

static func _apply_water_uniforms(
		_shader_mat: ShaderMaterial,
		_water_mat: ShaderMaterial,
		_water_uses_world_map: bool,
		_world: WorldData,
		parchment_strength: float,
		parchment_tint: Color,
		terrain_ecotone_width: float,
		terrain_surface_debug_view: int,
		_push_visual_tile_layout_uniforms: Callable,
		_push_water_fog_uniforms: Callable,
		_push_water_lighting_uniforms: Callable,
		_push_water_params_to: Callable,
		_visual_tiles_active: Callable,
		_wrap_period_x: Callable,
		water_flowmap_enabled: bool) -> void:
	if _water_mat == null or _world == null:
		return
	var sm := _water_mat
	_push_water_params_to.call(sm)
	if _water_uses_world_map and _shader_mat != null:
		# Bind the PC water inputs from the terrain material after its full push.
		# Shared textures update in place; this loop runs on bind/reconfiguration only.
		for param in _shader_mat.shader.get_shader_uniform_list():
			var key := StringName(param.name)
			var value = _shader_mat.get_shader_parameter(key)
			if value != null:
				sm.set_shader_parameter(key, value)
		# 水面程序是独立材质，主材质绑过的采样器不会自动跟过来：噪声包（波浪细节
		# 法线）与水深在这里显式补绑，避免材质重建后丢采样器。
		if _world.noise_tex != null:
			sm.set_shader_parameter("noise_tex", _world.noise_tex)
		if not _visual_tiles_active.call() and _world.water_depth_tex != null:
			sm.set_shader_parameter("water_depth_tex", _world.water_depth_tex)
	var tiled: bool = _visual_tiles_active.call()
	var bounds := _world.world_bounds
	if tiled:
		var visual_tiles = _world.visual_tiles
		# 布局 uniform 与主地形共用同一个推送函数，避免两处各写一遍 7 个参数。
		sm.set_shader_parameter("visual_height_tiles", visual_tiles.height)
		sm.set_shader_parameter("visual_map_index_tiles", visual_tiles.map_index)
		# [land-water-split 2026-11-02] 桌面 tiled 的拆分水面 program 与陆地 program
		# 用同一套采样预算（VT_USE_* 相同），水深/法线等数组也必须绑，否则采到空白。
		if _water_uses_world_map:
			sm.set_shader_parameter("visual_terrain_normal_tiles", visual_tiles.terrain_normal)
			sm.set_shader_parameter("visual_terrain_relief_tiles", visual_tiles.terrain_relief)
			sm.set_shader_parameter("visual_water_depth_tiles", visual_tiles.water_depth)
			sm.set_shader_parameter("visual_terrain_detail_tiles", visual_tiles.terrain_detail)
			sm.set_shader_parameter("visual_edge_neighbor_tiles", visual_tiles.edge_neighbor)
			sm.set_shader_parameter("visual_edge_distance_tiles", visual_tiles.edge_distance)
			if visual_tiles.horizon != null:
				sm.set_shader_parameter("visual_horizon_tiles", visual_tiles.horizon)
			if visual_tiles.gi_sky != null:
				sm.set_shader_parameter("visual_gi_sky_tiles", visual_tiles.gi_sky)
			if visual_tiles.horizon_dir0 != null:
				sm.set_shader_parameter("visual_horizon_dir0_tiles", visual_tiles.horizon_dir0)
			if visual_tiles.horizon_dir1 != null:
				sm.set_shader_parameter("visual_horizon_dir1_tiles", visual_tiles.horizon_dir1)
			if visual_tiles.gi_occluder != null:
				sm.set_shader_parameter("visual_gi_occluder_tiles", visual_tiles.gi_occluder)
			# [cell-field 2026-11-18] 格界扭曲场 tile（方案 §3.7 / 契约 §4.2）：水面 program
			# 与陆地 program 必须采同一份 warp 场，否则同一个像素在两片里的 is_water 判定
			# 会错开 ⇒ 海岸线出 1-px 洞。未烘焙时保持"不绑"（warp_layer_bound=false 时
			# helper 返回中性值，绝不采样未绑定的 sampler）。
			if visual_tiles.boundary_warp != null:
				sm.set_shader_parameter("visual_warp_tiles", visual_tiles.boundary_warp)
			# [cell-field 2026-11-18] 与 _apply_uniforms 的同名推送同值：tiled 的 warp 是否
			# 就绪只看 warp tile 数组（非 tiled 看 WorldData 的权威标志，见下面的 else 分支）。
			# 放在这个世界地图变体守卫内：只有它声明这两个 uniform —— 紧凑 web_min 水面
			# 不编 PK_CELL_FIELD（方案 §3.10 / 契约 §4.3），独立材质里没有它们。
			sm.set_shader_parameter("terrain_warp_layer_bound",
				visual_tiles.boundary_warp != null)
			sm.set_shader_parameter("gi_sky_tex_bound",
				bool(visual_tiles.gi_sky_ready))
			sm.set_shader_parameter("horizon_dir_tex_bound",
				bool(visual_tiles.horizon_dir_ready))
		_push_visual_tile_layout_uniforms.call(sm, visual_tiles.layout)
	else:
		sm.set_shader_parameter("height_tex", _world.height_tex)
		sm.set_shader_parameter("derived_resolution", Vector2(_world.derived_size))
		sm.set_shader_parameter("map_index_atlas", _world.enum_atlas_tex)
		# [terrain-web-baked-surface-B 2026-11-01] 水面 depth 纹理：Web 两个水面程序
		# （HIGH water 走 PC water_pipeline 的 ctx.water_depth_px；compact water 走
		# visual_sample_water_depth）都在非 tiled 分支消费它。桌面 tiled 走主 pass 的
		# visual_water_depth_tiles，与本 pass 无关。
		sm.set_shader_parameter("water_depth_tex", _world.water_depth_tex)
		# [surface-array-edge 2026-11-02] 两个水面程序都与陆地程序共用同一个 6 层
		# surface array（HIGH water 7→8 槽、compact water 5→6 槽），用来恢复
		# edge_mix / shore_frac / 次生水格。层数门控与陆地 program 同源：
		# 不足 6 层时 shader 侧 helper 返回中性值，水色退回 C 回合的硬边行为。
		var water_surface_layers := 0
		if _world.terrain_surface_tex != null:
			water_surface_layers = int(_world.terrain_surface_tex.get_layers())
		sm.set_shader_parameter("terrain_surface_tex", _world.terrain_surface_tex)
		sm.set_shader_parameter("terrain_surface_layer_count", water_surface_layers)
		sm.set_shader_parameter("terrain_edge_layers_bound", water_surface_layers >= 6)
		# 与 _apply_uniforms 的同名推送同值（世界地图两片必须逐项同值，否则色差）。
		sm.set_shader_parameter("has_terrain_edge_data",
			(_world.terrain_edge_neighbor_tex != null
				and _world.terrain_edge_distance_tex != null)
			or water_surface_layers >= 6)
		sm.set_shader_parameter("terrain_static_baked", water_surface_layers >= 6)
		# [cell-field 2026-11-18] layer6（boundary_warp）是否就绪：与陆地 program **同一数据源**
		# （WorldData.terrain_warp_layer_bound）—— surface array 恒为 7 层，中性兜底层也是
		# 一层，层数推不出载荷真假；两片 program 的判定一旦不同，海岸线就会出 1-px 洞。
		# 与层数取与是越界保护（6 层旧图 + 标志残留时不得采 layer6）。**不**并入
		# terrain_static_baked：后者只表示 edge_distance / edge_neighbor / water_depth 这套
		# layer4/5 静态通道可用（water_pipeline / shore_common 只据此二选一）。
		sm.set_shader_parameter("terrain_warp_layer_bound",
			_world.terrain_warp_layer_bound and water_surface_layers >= 7)
		sm.set_shader_parameter("gi_sky_tex_bound",
			_world.terrain_gi_sky_layer_bound and water_surface_layers >= 8)
		sm.set_shader_parameter("horizon_dir_tex_bound",
			_world.terrain_horizon_dir_layers_bound and water_surface_layers >= 10)
		# [surface-array-edge 2026-11-02] compact 水面自行声明的 ecotone 宽度（与
		# uniforms.gdshaderinc 同一个 @export 值）；世界地图水面程序会从主材质整表拷贝。
		sm.set_shader_parameter("terrain_ecotone_width", terrain_ecotone_width)
	sm.set_shader_parameter("has_water_depth_tex", _world.water_depth_tex != null)
	sm.set_shader_parameter("ocean_current_flow_tex", _world.ocean_current_flow_tex)
	sm.set_shader_parameter("ocean_current_flow_tex_bound",
		water_flowmap_enabled and _world.ocean_current_flow_tex != null)
	sm.set_shader_parameter("enum_lut", _world.enum_lut_tex)
	sm.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
	sm.set_shader_parameter("lut_dims", Vector2(_world.lut_dims.x, _world.lut_dims.y))
	# [cell-field 2026-11-18] 格界场的共享输入（方案 §3.7 的硬约束）：陆地与水面两个
	# program 必须拿到**逐项同值**的 cell_table / 尺寸 / 扭曲参数，否则同一个像素在两片
	# program 里的 is_water 判定会错开 ⇒ 海岸线出 1-px 洞（规则是宁可重叠，不许出洞）。
	# 未 bake / 旧存档时 bound=false 且 sampler 保持不绑，shader 侧早退。
	# 尺寸走 vec2（同本文件 lut_dims 的约定），shader 声明的名字是 `cell_table_size`。
	var water_cell_table: Texture2DArray = _world.cell_table_tex
	var water_cell_dims: Vector2i = _world.cell_table_dims
	if water_cell_table != null and water_cell_dims.x > 0 and water_cell_dims.y > 0:
		sm.set_shader_parameter("cell_table", water_cell_table)
		sm.set_shader_parameter("cell_table_size", Vector2(water_cell_dims.x, water_cell_dims.y))
	sm.set_shader_parameter("cell_table_bound", _world.cell_table_bound and water_cell_table != null)
	# [cell-field-web 2026-11-18] layer3（class_by_index，cell.index 空间）是否发布：与
	# renderer_material_publish.gd::_apply_uniforms 的**同名同表达式**推送（两片 program 的
	# 格界/类别判定必须逐项同值，否则同一个像素在水陆两侧读到不同的 class）。字段为 0
	# （旧存档 / 未 bake / 发布失败）时推 false，shader 不读那一层。
	sm.set_shader_parameter("cell_class_index_bound", _world.cell_table_layers >= 4)
	sm.set_shader_parameter("terrain_warp_range", _world.boundary_warp_range)
	sm.set_shader_parameter("terrain_warp_amp", MapBaker.WARP_AMP)
	sm.set_shader_parameter("world_origin", bounds.position)
	sm.set_shader_parameter("world_size", bounds.size)
	sm.set_shader_parameter("wrap_origin_x", 0.0)
	sm.set_shader_parameter("wrap_period_x", _wrap_period_x.call())
	# 羊皮纸：这两项必须与主地形取同一个属性值（_apply_uniforms 也是从这里推的），
	# 否则拆成两 pass 后水陆会差一层色调。
	sm.set_shader_parameter("parchment_tint", parchment_tint)
	sm.set_shader_parameter("parchment_strength", parchment_strength)
	# 调试视图让位开关（pass 1 整屏输出诊断色时本 pass 必须整体 discard）。
	sm.set_shader_parameter("terrain_surface_debug_view", terrain_surface_debug_view)
	_push_water_lighting_uniforms.call()
	_push_water_fog_uniforms.call()


static func _push_world_lighting_profile(
		_building_visual_layer: BuildingVisualLayer,
		_day_phase: float,
		_detail_family_layer,
		_military_visual_layer: MilitaryArmyTokenLayer,
		_resource_visual_layer: Node2D,
		_shader_mat: ShaderMaterial,
		_sky_background: Node,
		_trade_visual_layer: TradeActivityLayer,
		_water_mat: ShaderMaterial,
		_world: WorldData,
		day_night_enabled: bool,
		world_lighting_profile: WorldLightingProfile,
		_for_each_vegetation_layer: Callable,
		_global_sky_day_weight: Callable,
		_push_world_uniform: Callable,
		_shader_declares_uniform: Callable) -> void:
	if _shader_mat == null:
		return
	var profile := world_lighting_profile
	var zero_sh := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	var day_sh := profile.day_sh_l1 if profile != null and profile.day_sh_l1.size() == 4 else zero_sh
	var night_sh := profile.night_sh_l1 if profile != null and profile.night_sh_l1.size() == 4 else zero_sh
	_push_world_uniform.call("sky_ibl_bound", profile != null and profile.day_sh_l1.size() == 4
		and profile.night_sh_l1.size() == 4)
	_push_world_uniform.call("sky_ambient_strength", profile.ambient_strength if profile != null else 1.0)
	_push_world_uniform.call("sky_day_sh_l1", day_sh)
	_push_world_uniform.call("sky_night_sh_l1", night_sh)
	var needs_irradiance: bool = _shader_declares_uniform.call(_shader_mat.shader, &"sky_irradiance_array")
	var needs_reflection: bool = needs_irradiance \
		or _shader_declares_uniform.call(_shader_mat.shader, &"sky_specular_array") \
		or (_water_mat != null and _shader_declares_uniform.call(_water_mat.shader, &"sky_specular_array"))
	var irradiance_array := profile.get_irradiance_array() \
		if profile != null and needs_irradiance else null
	var specular_array := profile.get_specular_array() \
		if profile != null and needs_reflection else null
	_push_world_uniform.call("sky_irradiance_array", irradiance_array)
	_push_world_uniform.call("sky_irradiance_bound", irradiance_array != null)
	_push_world_uniform.call("sky_specular_array", specular_array)
	_push_world_uniform.call("sky_specular_bound", specular_array != null)
	_push_world_uniform.call("sky_specular_level_count", WorldLightingProfile.SPECULAR_LEVELS)
	_push_world_uniform.call("sky_reflection_strength", profile.reflection_strength if profile != null else 1.0)
	_push_world_uniform.call("sky_global_day_weight", _global_sky_day_weight.call())
	if _sky_background != null:
		var bounds := _world.world_bounds if _world != null else Rect2()
		_sky_background.setup(bounds, profile, _day_phase, day_night_enabled)
	_for_each_vegetation_layer.call(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_world_sky_lighting"):
			layer.set_world_sky_lighting(_shader_mat)
	)
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer) \
			and _detail_family_layer.has_method("set_world_sky_lighting"):
		_detail_family_layer.set_world_sky_lighting(_shader_mat)
	if _resource_visual_layer != null:
		_resource_visual_layer.set_terrain_lighting(_shader_mat)
	if _building_visual_layer != null:
		_building_visual_layer.set_terrain_lighting(_shader_mat)
	if is_instance_valid(_trade_visual_layer):
		_trade_visual_layer.refresh_terrain_lighting(_shader_mat)
	if is_instance_valid(_military_visual_layer):
		_military_visual_layer.set_terrain_lighting(_world, _shader_mat)



static func push_world_lighting_profile(host) -> void:

	_push_world_lighting_profile(
		host._building_visual_layer,
		host._day_phase,
		host._detail_family_layer,
		host._military_visual_layer,
		host._resource_visual_layer,
		host._shader_mat,
		host._sky_background,
		host._trade_visual_layer,
		host._water_mat,
		host._world,
		host.day_night_enabled,
		host.world_lighting_profile,
		host._for_each_vegetation_layer,
		host._global_sky_day_weight,
		host._push_world_uniform,
		host._shader_declares_uniform)


## Cloud shadows share the same material and visual-layer binding boundary.
static func push_cloud_shadow_material_inputs(
		_cloud_shadow_field,
		_shader_mat,
		_water_mat,
		cloud_shadow_ambient_weight,
		cloud_shadow_water_scale,
		_building_visual_layer,
		_resource_visual_layer,
		_for_each_vegetation_layer: Callable,
		_detail_family_layer,
		direct_enabled: bool) -> void:

	if _cloud_shadow_field == null:
		return
	var has_source: bool = _cloud_shadow_field.has_weather_source()
	var field_texture: Texture2D = _cloud_shadow_field.get_field_texture() if has_source else null
	var wrap_origin_uv: float = _cloud_shadow_field.get_wrap_origin_uv()
	var wrap_period_uv: float = _cloud_shadow_field.get_wrap_period_uv()
	for material in [_shader_mat, _water_mat]:
		if material == null or material.shader == null:
			continue
		if material.shader.code.contains("#define PK_CLOUD_SHADOW_DIRECT"):
			if field_texture != null:
				material.set_shader_parameter("cloud_shadow_tex", field_texture)
			material.set_shader_parameter("cloud_shadow_field_bound", direct_enabled and has_source)
			material.set_shader_parameter("cloud_shadow_strength", _cloud_shadow_field.get_strength())
			material.set_shader_parameter("cloud_shadow_ambient_weight", cloud_shadow_ambient_weight)
			material.set_shader_parameter("cloud_shadow_water_scale", cloud_shadow_water_scale)
			material.set_shader_parameter("cloud_shadow_wrap_origin_uv", wrap_origin_uv)
			material.set_shader_parameter("cloud_shadow_wrap_period_uv", wrap_period_uv)
	if _building_visual_layer != null and _building_visual_layer.has_method("set_cloud_shadow_field"):
		_building_visual_layer.set_cloud_shadow_field(field_texture, direct_enabled,
			wrap_origin_uv, wrap_period_uv)
	if _resource_visual_layer != null and _resource_visual_layer.has_method("set_cloud_shadow_field"):
		_resource_visual_layer.set_cloud_shadow_field(field_texture, direct_enabled,
			wrap_origin_uv, wrap_period_uv)
	_for_each_vegetation_layer.call(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_cloud_shadow_field"):
			layer.set_cloud_shadow_field(field_texture, direct_enabled,
				wrap_origin_uv, wrap_period_uv)
	)
	if _detail_family_layer != null and is_instance_valid(_detail_family_layer) \
			and _detail_family_layer.has_method("set_cloud_shadow_field"):
		_detail_family_layer.set_cloud_shadow_field(field_texture, direct_enabled,
			wrap_origin_uv, wrap_period_uv)


static func configure_world_lighting_field(host) -> void:
	if host._world_lighting_field == null:
		return
	if host._world == null:
		host._world_lighting_field.clear_inputs()
		return
	host._world_lighting_field.configure(
		host._world,
		host._world.world_bounds,
		host._wrap_period_x(),
		host.visual_quality,
		host._mobile_quality_tier_define,
		host.hex_size)
	sync_world_lighting_daylight(host)
	host._world_lighting_field.set_horizon_params(
		host.terrain_horizon_strength,
		host.terrain_horizon_softness)


static func sync_world_lighting_daylight(host) -> void:
	if host._world_lighting_field == null:
		return
	var material: ShaderMaterial = host._shader_mat
	var latitude_sun = material.get_shader_parameter("tod_latitude_sun_enabled") if material != null else null
	var sun_max_up = material.get_shader_parameter("tod_sun_relief_max_up") if material != null else null
	host._world_lighting_field.set_daylight_params(
		host._day_phase,
		host._season_phase,
		deg_to_rad(host.axial_tilt_deg),
		host.day_night_enabled,
		host._tod_sun_dir,
		host._tod_debug_sun_position_enabled,
		host._tod_debug_sun_uv,
		host._tod_debug_sun_height_scale,
		deg_to_rad(host.eternal_min_elevation_deg),
		deg_to_rad(host.eternal_max_hour_angle_deg),
		true if latitude_sun == null else bool(latitude_sun),
		0.88 if sun_max_up == null else float(sun_max_up))


static func _push_world_lighting_to_material(material: ShaderMaterial,
		tex: Texture2D, bound: bool, radiance_scale: float) -> void:
	if material == null or material.shader == null:
		return
	if tex != null:
		material.set_shader_parameter("world_lighting_tex", tex)
	material.set_shader_parameter("world_lighting_tex_bound", bound)
	material.set_shader_parameter("world_lighting_radiance_scale", radiance_scale)


static func push_world_lighting_material_inputs(host) -> void:
	if host._world_lighting_field == null:
		return
	var tex: Texture2D = host._world_lighting_field.get_lighting_texture()
	var bound: bool = bool(host._world_lighting_field.is_lighting_ready()) and tex != null
	var radiance_scale: float = float(host._world_lighting_field.get_radiance_scale())
	for material in [host._shader_mat, host._water_mat]:
		if material == null or material.shader == null:
			continue
		if material.shader.code.contains("#define PK_WORLD_LIGHTING_FIELD"):
			_push_world_lighting_to_material(material, tex, bound, radiance_scale)
	if host._building_visual_layer != null:
		for mat_prop in ["_body_material", "_decal_material", "_macro_material"]:
			var bmat = host._building_visual_layer.get(mat_prop) as ShaderMaterial
			_push_world_lighting_to_material(bmat, tex, bound, radiance_scale)
	if host._resource_visual_layer != null:
		if host._resource_visual_layer.has_method("_materials"):
			for rmat in host._resource_visual_layer._materials():
				_push_world_lighting_to_material(rmat as ShaderMaterial, tex, bound, radiance_scale)
		else:
			_push_world_lighting_to_material(
				host._resource_visual_layer.get("_material") as ShaderMaterial,
				tex, bound, radiance_scale)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		_push_world_lighting_to_material(layer.get("_material") as ShaderMaterial, tex, bound, radiance_scale)
		var fam_mats = layer.get("_family_materials")
		if fam_mats is Array:
			for fmat in fam_mats:
				_push_world_lighting_to_material(fmat as ShaderMaterial, tex, bound, radiance_scale)
	)
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer):
		var df_mats = host._detail_family_layer.get("_materials")
		if df_mats is Dictionary:
			for fmat in df_mats.values():
				_push_world_lighting_to_material(fmat as ShaderMaterial, tex, bound, radiance_scale)
	if is_instance_valid(host._trade_visual_layer):
		_push_world_lighting_to_material(
			host._trade_visual_layer.get("_material") as ShaderMaterial, tex, bound, radiance_scale)
	if is_instance_valid(host._military_visual_layer):
		if host._military_visual_layer.has_method("_set_formation_parameter"):
			if tex != null:
				host._military_visual_layer._set_formation_parameter("world_lighting_tex", tex)
			host._military_visual_layer._set_formation_parameter("world_lighting_tex_bound", bound)
			host._military_visual_layer._set_formation_parameter("world_lighting_radiance_scale", radiance_scale)
