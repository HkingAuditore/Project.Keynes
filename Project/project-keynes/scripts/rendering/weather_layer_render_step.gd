extends RefCounted

## Initializes weather projection and updates it for the current view.

static func _ready(layer: WeatherLayer) -> void:
	layer.z_as_relative = false
	layer.z_index = 4
	layer.process_mode = Node.PROCESS_MODE_ALWAYS

	# v9.perf：默认整层隐藏，set_weather_fronts() 来了再 visible=true，
	# 在没有任何天气时省掉 overlay quad 的全屏 fragment + framebuffer blend
	layer.visible = false

	layer._overlay_quad = MeshInstance2D.new()
	layer._overlay_quad.name = "WeatherOverlayQuad"
	layer._overlay_quad.z_as_relative = true
	layer._overlay_quad.z_index = 0
	layer.add_child(layer._overlay_quad)

	layer._curtains.attach(layer)

	layer._particles_root = Node2D.new()
	layer._particles_root.name = "WeatherParticles"
	layer._particles_root.z_as_relative = true
	layer._particles_root.z_index = 2
	layer.add_child(layer._particles_root)

	layer._load_overlay_shader()
	layer._load_curtain_shader()
	layer._init_particles_pool()
	layer.set_process(true)


static func _process(layer: WeatherLayer, delta: float) -> void:
	# 画质门关闭（web 低 / 中 / auto）：不推进、不上传 uniform、不绘制 ——
	# 低画质连逐帧 blend/粒子/雨幕同步的 CPU 也不付。开门后下一帧按最新
	# LUT / fronts 继续（set_render_gate 已先重算可见性）。
	if not layer._render_gate_open:
		layer.visible = false
		return
	var has_weather: bool = (not layer._front_target_snapshots.is_empty()) \
			or (not layer._front_visual_snapshots.is_empty()) \
			or (layer._weather_field_tex != null) \
			or layer._has_weather_lut_source()

	if not has_weather:
		layer._active_count = 0
		layer.visible = false
		return
	var visual_time_scale := layer._clock_speed_multiplier if layer._clock_running else 1.0
	layer._world_time += delta * visual_time_scale
	if layer._overlay_mat != null:
		layer._overlay_mat.set_shader_parameter("world_time", layer._world_time)
	# [parallax-rain] 遍历所有 curtain 材质
	for mat in layer._curtains.materials:
		mat.set_shader_parameter("world_time", layer._world_time)
	if has_weather:
		layer._update_weather_front_blend(delta)
		if layer._overlay_mat != null and layer._world_ref != null:
			# [uniform-churn 2026-11-02] 这两个纹理 + weather_lerp 以前**每帧**无条件
			# 推送：真机 Vulkan/GL 上等于每帧给 overlay + 全部 curtain 材质重绑采样器，
			# 渲染线程持续处理网格面/描符集变更。现在按"值变了才推"（纹理对象同一性 +
			# lerp 变化超过 1/512），把稳态开销压到接近 0。
			if layer._world_ref.weather_lut_tex != null \
					and layer._wx_pushed_weather_lut != layer._world_ref.weather_lut_tex:
				layer._wx_pushed_weather_lut = layer._world_ref.weather_lut_tex
				layer._weather_lut_tex = layer._wx_pushed_weather_lut
				layer._overlay_mat.set_shader_parameter("weather_lut", layer._weather_lut_tex)
				for mat in layer._curtains.materials:
					mat.set_shader_parameter("weather_lut", layer._weather_lut_tex)
			if layer._world_ref.weather_lut_prev_tex != null \
					and layer._wx_pushed_weather_prev != layer._world_ref.weather_lut_prev_tex:
				layer._wx_pushed_weather_prev = layer._world_ref.weather_lut_prev_tex
				layer._overlay_mat.set_shader_parameter("weather_lut_prev", layer._wx_pushed_weather_prev)
				for mat in layer._curtains.materials:
					mat.set_shader_parameter("weather_lut_prev", layer._wx_pushed_weather_prev)
			# [cell-field-overlays 2026-11-18] weather_table + 层号：同样按"值变了才推"。
			# 层号翻转与 weather_lut 换纹理发生在同一次提交（cell_lut_baker 里紧贴），
			# 所以这里看到的 (tex, cur) 永远是配套的一对。
			layer._push_weather_table()
			# 时间平滑:weather_lerp 按 LUT 的【实际更新节奏】推进 0→1,与 prev/curr 严格对齐(不再复用 front blend)。
			var _now_us: int = Time.get_ticks_usec()
			var _upd: int = int(layer._world_ref.weather_lut_update_usec)
			if _upd != layer._wx_lut_last_usec:
				if layer._wx_lut_last_usec > 0:
					var _gap: float = float(_upd - layer._wx_lut_last_usec)
					if _gap > 1000.0 and _gap < 5000000.0:
						var _adapt: float = 0.75 if _gap < layer._wx_commit_interval_usec else 0.30
						layer._wx_commit_interval_usec = lerpf(layer._wx_commit_interval_usec, _gap, _adapt)  # IIR 自适应（加速时快收敛，防 lerp 未走完就重置跳变）
				layer._wx_lut_last_usec = _upd
				layer._wx_lut_t0_usec = _now_us
			var _wlerp: float = 1.0
			if layer._wx_commit_interval_usec > 1.0:
				_wlerp = clampf(float(_now_us - layer._wx_lut_t0_usec) / layer._wx_commit_interval_usec, 0.0, 1.0)
			# 只在变化超过 1/512 时推，稳态下每帧的 uniform 写回到 0。
			if absf(_wlerp - layer._wx_pushed_lerp) > 0.002 or layer._wx_pushed_lerp < 0.0:
				layer._wx_pushed_lerp = _wlerp
				layer._overlay_mat.set_shader_parameter("weather_lerp", _wlerp)
				for mat in layer._curtains.materials:
					mat.set_shader_parameter("weather_lerp", _wlerp)
			layer._refresh_curtain_instances(_upd, layer._wx_pushed_lerp < 0.999)
			if _upd != 0 and (layer._wx_lut_diag_count < 12 or _now_us / 1000 - layer._wx_lut_diag_last_msec >= 2000):
				layer._wx_lut_diag_count += 1
				layer._wx_lut_diag_last_msec = _now_us / 1000
				print("[weather-layer][lut] #%d update_usec=%d last_usec=%d lerp=%.3f prev_tex=%s curr_tex=%s dims=%s visible=%s" % [
					layer._wx_lut_diag_count, _upd, layer._wx_lut_last_usec, _wlerp,
					str(layer._world_ref.weather_lut_prev_tex != null), str(layer._world_ref.weather_lut_tex != null),
					str(layer._weather_lut_dims), str(layer.visible),
				])

		# Drift-debug：每秒采样 visual_snapshots[0] 的 center，看 lerp 是否真的在推进。
		if WeatherLayer.DRIFT_DEBUG_LOG and layer._world_time - layer._drift_debug_last_log_time >= 1.0:
			layer._drift_debug_last_log_time = layer._world_time
			if layer._front_visual_snapshots.size() > 0:
				var v0: Dictionary = layer._front_visual_snapshots[0]
				var s0_c: Vector2 = Vector2.INF
				var t0_c: Vector2 = Vector2.INF
				if layer._front_start_snapshots.size() > 0:
					s0_c = layer._front_center(layer._front_start_snapshots[0])
				if layer._front_target_snapshots.size() > 0:
					t0_c = layer._front_center(layer._front_target_snapshots[0])
				var raw_t: float = 0.0
				if layer._front_blend_duration > 0.0001:
					raw_t = clampf(layer._front_blend_elapsed / layer._front_blend_duration, 0.0, 1.0)
				print("[weather-layer-tick] t=%.2fs visual0=%s start0=%s target0=%s blend_t=%.2f vel=%s" % [
					layer._world_time, str(layer._front_center(v0).round()),
					str(s0_c.round()) if s0_c != Vector2.INF else "<none>",
					str(t0_c.round()) if t0_c != Vector2.INF else "<none>",
					raw_t, str(layer._front_velocity(v0).round()),
				])
	else:
		# 没有天气时跳过 fronts/particles 同步，仅靠推进 world_time
		# 让 shader 自己刷云的噪声飘动。
		layer._refresh_visibility()

# 兼容旧接口：上层仍会同步 WorldClock.paused，但天气表现层现在暂停时也持续播放。


static func setup(layer: WeatherLayer, bounds: Rect2, map_index_atlas: ImageTexture, noise_tex: ImageTexture, hex_size: float = 22.0, weather_lut: ImageTexture = null, lut_dims: Vector2i = Vector2i.ZERO, wrap_period_x: float = 0.0, map: MapData = null) -> void:
	layer._world_bounds = bounds
	layer._wrap_period_x = maxf(0.0, wrap_period_x)
	layer._map_index_atlas_tex = map_index_atlas
	layer._noise_tex = noise_tex
	layer._hex_size = hex_size
	layer._weather_lut_tex = weather_lut
	layer._weather_lut_dims = lut_dims
	layer._weather_map = map

	layer._reset_front_blend_state()
	if layer._overlay_quad != null:
		layer._overlay_quad.mesh = layer._build_full_quad(bounds, layer._wrap_period_x)
	if layer._overlay_mat != null:
		layer._overlay_mat.set_shader_parameter("map_index_atlas", map_index_atlas)
		# cell-index 间接寻址（cloud-from-field 2026-06-20）：weather_lut + lut_dims 让
		# weather_overlay 逐格采样真实天气场（map_index_atlas.GB 已含 cell.index）。
		layer._overlay_mat.set_shader_parameter("weather_lut", weather_lut)
		layer._overlay_mat.set_shader_parameter("lut_dims", Vector2(lut_dims.x, lut_dims.y))
		layer._overlay_mat.set_shader_parameter("world_origin", bounds.position)
		layer._overlay_mat.set_shader_parameter("world_size", bounds.size)
		layer._overlay_mat.set_shader_parameter("wrap_origin_x", 0.0)
		layer._overlay_mat.set_shader_parameter("wrap_period_x", layer._wrap_period_x)
		# hex_size = 半径，hex 直径（wp 单位）= 2 * hex_size。
		layer._overlay_mat.set_shader_parameter("hex_world_diameter", 2.0 * hex_size)
		layer._overlay_mat.set_shader_parameter("weather_strength", layer._strength)
		layer._overlay_mat.set_shader_parameter("cloud_opacity_scale", layer._cloud_opacity_scale)
		layer._overlay_mat.set_shader_parameter("weather_debug_view", layer._weather_debug_view)
		# 进入时把 fronts 数组清空，避免上一张地图的残留
		layer._push_empty_fronts_to_overlay()
		# v-data-driven：一次性把 8 个 WeatherProfile 的颜色推入 shader。
		layer._push_weather_profile_uniforms_to_overlay()
		layer._overlay_mat.set_shader_parameter("tod_sun_dir", layer._tod_sun_dir)
		# [cell-field-overlays 2026-11-18 / O2] 场函数路径的世界坐标 / per-cell 表绑定
		# （hex_size、map_dims、cell_table*）。旧路径不声明这些 uniform，多推是空操作。
		layer._push_cell_field_uniforms()
	layer._rebuild_curtain_layers()
	layer._push_curtain_runtime_state()
	layer._update_curtain_visibility()
	layer._refresh_visibility()

## 视野屏蔽。已探索但当前不可见的格子不显示实时天气——那是「记忆中的地形」，
## 不是「现在的天气」。enum_lut 与主地形 / 迷雾层共用同一张纹理（A 通道 = k）。


static func set_fog_mask(layer: WeatherLayer, enabled: bool, enum_lut: Texture2D) -> void:
	layer._fog_mask_enabled = enabled
	layer._fog_enum_lut_tex = enum_lut
	layer._push_fog_mask_uniforms()


static func set_edge_transition_data(layer: WeatherLayer,
	neighbor_tex: Texture2D,
	distance_tex: Texture2D,
	width: float
) -> void:
	layer._edge_neighbor_tex = neighbor_tex
	layer._edge_distance_tex = distance_tex
	layer._edge_transition_width = clampf(width, 0.0, 0.96)
	layer._push_edge_transition_data()


static func set_visual_tiles(layer: WeatherLayer, tiles) -> void:
	var was_tiled := layer._visual_tiles_active()
	layer._visual_tiles = tiles
	var is_tiled := layer._visual_tiles_active()
	if was_tiled != is_tiled and layer._overlay_quad != null:
		layer._load_overlay_shader()
	layer._push_visual_tile_uniforms()


static func _visual_tiles_active(layer: WeatherLayer) -> bool:
	return layer._visual_tiles != null and bool(layer._visual_tiles.ready) \
		and String(layer._visual_tiles.layout.mode) == "tiled"


static func _push_visual_tile_uniforms(layer: WeatherLayer) -> void:
	if layer._overlay_mat == null or not layer._visual_tiles_active():
		return
	var layout = layer._visual_tiles.layout
	layer._overlay_mat.set_shader_parameter("visual_map_index_tiles", layer._visual_tiles.map_index)
	layer._overlay_mat.set_shader_parameter("visual_edge_neighbor_tiles", layer._visual_tiles.edge_neighbor)
	layer._overlay_mat.set_shader_parameter("visual_edge_distance_tiles", layer._visual_tiles.edge_distance)
	layer._overlay_mat.set_shader_parameter("visual_domain_origin", layout.visual_domain.position)
	layer._overlay_mat.set_shader_parameter("visual_domain_size", layout.visual_domain.size)
	layer._overlay_mat.set_shader_parameter("visual_grid_size", Vector2(layout.grid_size))
	layer._overlay_mat.set_shader_parameter("visual_interior_size", Vector2(layout.interior_size))
	layer._overlay_mat.set_shader_parameter("visual_layer_size", Vector2(layout.layer_size))
	layer._overlay_mat.set_shader_parameter("visual_logical_resolution", Vector2(layout.logical_size))
	layer._overlay_mat.set_shader_parameter("visual_gutter_px", float(layout.gutter_px))


static func _push_edge_transition_data(layer: WeatherLayer) -> void:
	if layer._overlay_mat == null:
		return
	var ready := layer._visual_tiles_active() or (layer._edge_neighbor_tex != null and layer._edge_distance_tex != null)
	if not layer._visual_tiles_active() and layer._edge_neighbor_tex != null:
		layer._overlay_mat.set_shader_parameter("terrain_edge_neighbor_tex", layer._edge_neighbor_tex)
	if not layer._visual_tiles_active() and layer._edge_distance_tex != null:
		layer._overlay_mat.set_shader_parameter("terrain_edge_distance_tex", layer._edge_distance_tex)
	layer._overlay_mat.set_shader_parameter("has_terrain_edge_data", ready)
	layer._overlay_mat.set_shader_parameter("terrain_ecotone_width", layer._edge_transition_width)


static func _push_fog_mask_uniforms(layer: WeatherLayer) -> void:
	var tex: Texture2D = layer._fog_enum_lut_tex
	if layer._overlay_mat != null:
		layer._overlay_mat.set_shader_parameter("fog_mask_enabled", layer._fog_mask_enabled and tex != null)
		if tex != null:
			layer._overlay_mat.set_shader_parameter("enum_lut", tex)
	for mat in layer._curtains.materials:
		mat.set_shader_parameter("fog_mask_enabled", layer._fog_mask_enabled and tex != null)
		if tex != null:
			mat.set_shader_parameter("enum_lut", tex)


# 云层不透明度（只影响云，不影响降水/风）。
