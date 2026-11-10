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
		_wrap_period_x: Callable) -> void:
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
		if _world.ocean_current_flow_tex != null:
			sm.set_shader_parameter("ocean_current_flow_tex", _world.ocean_current_flow_tex)
			sm.set_shader_parameter("ocean_current_flow_tex_bound", true)
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
			if visual_tiles.gi_occluder != null:
				sm.set_shader_parameter("visual_gi_occluder_tiles", visual_tiles.gi_occluder)
		_push_visual_tile_layout_uniforms.call(sm, visual_tiles.layout)
	else:
		sm.set_shader_parameter("height_tex", _world.height_tex)
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
		# [surface-array-edge 2026-11-02] compact 水面自行声明的 ecotone 宽度（与
		# uniforms.gdshaderinc 同一个 @export 值）；世界地图水面程序会从主材质整表拷贝。
		sm.set_shader_parameter("terrain_ecotone_width", terrain_ecotone_width)
	sm.set_shader_parameter("has_water_depth_tex", _world.water_depth_tex != null)
	sm.set_shader_parameter("ocean_current_flow_tex", _world.ocean_current_flow_tex)
	sm.set_shader_parameter("ocean_current_flow_tex_bound", _world.ocean_current_flow_tex != null)
	sm.set_shader_parameter("enum_lut", _world.enum_lut_tex)
	sm.set_shader_parameter("dyn_lut", _world.dyn_lut_tex)
	sm.set_shader_parameter("lut_dims", Vector2(_world.lut_dims.x, _world.lut_dims.y))
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
		_trade_visual_layer.set_terrain_lighting(_world, _shader_mat)
	if is_instance_valid(_military_visual_layer):
		_military_visual_layer.set_terrain_lighting(_world, _shader_mat)
