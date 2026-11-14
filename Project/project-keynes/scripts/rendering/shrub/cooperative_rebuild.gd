extends RefCounted

## Stateless collaborator for ShrubLayer.

static func setup_cooperative(host, map: MapData, world: WorldData, bounds: Rect2, hex_size: float, visual_quality: int = 1) -> void:

	host._map = map
	host._world = world
	host._bounds = bounds
	host._hex_size = maxf(hex_size, 4.0)
	host._invalidate_chunk_spatial_cache()
	host._active_instance_count_valid = false
	host._visual_quality = clampi(visual_quality, 0, 2)
	host._native_offset_is_water_cache = PackedByteArray()
	host._native_offset_cache_dims = Vector2i.ZERO
	host._native_delta_common_knobs = {}
	# _ready/_ensure_resources 在 world/tiles 就绪前会编出 legacy 变体；setup 才是
	# 第一次拿到 visual_tiles 的入口，必须按实际 tiled 状态重建 shader，不能只 sync。
	var probe_start = Time.get_ticks_usec()
	host._ensure_shader_matches_tiles()
	print("[shrub-load] shader %.1fms" % [float(Time.get_ticks_usec()-probe_start)/1000.0])
	# 首次绘制编译成本（与 setup() 同一个上报口，按变体去重）。
	host._report_veg_shader_cost()
	probe_start = Time.get_ticks_usec()
	if host._defer_initial_rebuild and host._chunked_multimesh_enabled:
		host.clear()
		host._last_rebuild_reason = "deferred_until_prefetch"
		print("[shrub-load] clear %.1fms" % [float(Time.get_ticks_usec()-probe_start)/1000.0])
	else:
		await _rebuild_instances_cooperative(host, )



static func _rebuild_instances_cooperative(host) -> void:

	host._ensure_resources()
	var t0_us = Time.get_ticks_usec()
	var slice_start = Time.get_ticks_usec()
	host._last_candidate_count = 0
	host._last_wrap_edge_copy_count = 0
	host._last_rebuild_reason = ""
	host._last_incremental_cells = 0
	host._last_incremental_missing_slots = 0
	host._last_incremental_dropped_instances = 0
	host._last_dirty_chunks = 0
	host._last_native_sampled_cells = 0
	host._last_native_active_cells = 0
	host.clear()
	var cfg = host._profile()
	if not cfg.enabled or host._map == null or host._map.cell_count() <= 0:
		host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return

	var cells: Array = host._map.iter_cells()
	if cells.is_empty():
		cells = host._map.all_cells()
	if cells.is_empty():
		host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		host._last_rebuild_reason = "no_cells"
		return

	var cell_attempts = PackedInt32Array()
	cell_attempts.resize(cells.size())
	var cell_accepts = PackedFloat32Array()
	cell_accepts.resize(cells.size())
	var cell_states: Array = []
	cell_states.resize(cells.size())
	var cell_suitabilities = PackedFloat32Array()
	cell_suitabilities.resize(cells.size())
	var total_attempts: int = 0
	var max_per_cell: int = maxi(1, host._max_per_cell())
	for order in range(cells.size()):
		if Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await host.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
		var cell = cells[order]
		if cell == null:
			continue
		var idx = host._cell_index(cell, order)
		var key = host._cell_hash_key(cell, order)
		var state = host._sample_cell_state(idx, cell)
		var suitability = host._cell_suitability(cell, idx, key, state)
		if suitability <= 0.0:
			continue
		cell_states[order] = state
		cell_suitabilities[order] = suitability
		var quota = host._cell_quota(suitability, max_per_cell)
		var attempts: int = int(quota.x)
		cell_attempts[order] = attempts
		cell_accepts[order] = quota.y
		total_attempts += attempts

	if total_attempts <= 0:
		host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		host._last_rebuild_reason = "no_attempts"
		return

	# C++ 优先：把"每实例候选生成 + 噪声门 + 接受 + cap + MultiMesh buffer 组装"
	# 整段热循环下沉 DCWorldExt.encode_detail_scatter，GDScript 仅做上面这段
	# per-cell（N≤2400）廉价预计算。失败 / 旧 DLL 无该方法时回退到下方 GDScript 路径。
	if await _rebuild_via_native_cooperative(host, cells, cell_states, cell_suitabilities, cell_attempts, cell_accepts):
		if host._last_scatter_path.is_empty():
			host._last_scatter_path = "gdext"
		host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		host._rebuild_cell_instance_lookup()
		return
	host._last_scatter_path = "gdscript"

	for order in range(cells.size()):
		if Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await host.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
		var cell = cells[order]
		if cell == null:
			continue
		var idx = host._cell_index(cell, order)
		var key = host._cell_hash_key(cell, order)
		var suitability = cell_suitabilities[order]
		if suitability <= 0.0:
			continue
		var state: Dictionary = cell_states[order]
		var accept_p = cell_accepts[order]
		for attempt in range(cell_attempts[order]):
			host._try_append_instance(cell, idx, key, attempt, suitability, accept_p, state)

	host._apply_instance_cap()
	host._reorder_generated_instances_for_lod()
	host._instance_count = host._instance_cell_indices.size()
	host._rebuild_cell_instance_lookup()
	if host._instance_count <= 0:
		host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		host._last_rebuild_reason = "no_instances"
		return

	host._multimesh = MultiMesh.new()
	host._multimesh.transform_format = MultiMesh.TRANSFORM_2D
	host._multimesh.use_colors = true
	host._multimesh.use_custom_data = true
	host._multimesh.mesh = host._cached_detail_mesh()
	host._multimesh.instance_count = host._instance_count
	host._multimesh.visible_instance_count = host._lod_visible_count(host._instance_count, host._far_instance_count)
	host._mmi.multimesh = host._multimesh

	for i in range(host._instance_count):
		var xf = host._instance_transform(i)
		host._multimesh.set_instance_transform_2d(i, xf)
		var idx = host._instance_cell_indices[i]
		var state = host._sample_cell_state(idx, host._instance_cells[i])
		host._multimesh.set_instance_color(i, host._base_color_for_state(state, host._instance_variants[i]))
		var uv = host._world_uv(host._instance_positions[i])
		host._multimesh.set_instance_custom_data(i, Color(
			uv.x,
			uv.y,
			host._instance_seeds[i],
			host._instance_forms[i]
		))
	host.visible = cfg.enabled and not host._camera_lod_hidden and host._instance_count > 0
	host._sync_single_wrap_nodes()
	host._sync_shadow_layer(true)
	host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	host._last_candidate_count = host._instance_scores.size()


static func _rebuild_via_native_cooperative(host, 
		cells: Array,
		cell_states: Array,
		cell_suitabilities: PackedFloat32Array,
		cell_attempts: PackedInt32Array,
		cell_accepts: PackedFloat32Array) -> bool:

	if host._world_ext == null:
		return false
	if host._map == null:
		return false
	var grid_w: int = int(host._map.width) if "width" in host._map else 0
	var grid_h: int = int(host._map.height) if "height" in host._map else 0
	if grid_w <= 0 or grid_h <= 0:
		return false
	var cfg = host._profile()

	# offset 网格（odd-r）用于 C++ 端精确复刻 world_to_wrapped_cell：
	# world_to_cube → cube_to_offset → 越界 / 横向环绕。水域空位预置 1
	# （拒绝），cell 索引空位预置 -1。
	var offset_is_water = PackedByteArray()
	offset_is_water.resize(grid_w * grid_h)
	offset_is_water.fill(1)
	var offset_cell_indices = PackedInt32Array()
	offset_cell_indices.resize(grid_w * grid_h)
	offset_cell_indices.fill(-1)

	# 每个"活跃 cell"（suitability>0 且 climate_presence>0.02）的廉价 per-cell 数据。
	var keys = PackedInt32Array()
	var native_cell_indices = PackedInt32Array()
	var cx = PackedFloat32Array()
	var cy = PackedFloat32Array()
	var suit = PackedFloat32Array()
	var att = PackedInt32Array()
	var accp = PackedFloat32Array()
	var vit = PackedFloat32Array()
	var sized = PackedFloat32Array()
	var col_r = PackedFloat32Array()
	var col_g = PackedFloat32Array()
	var col_b = PackedFloat32Array()
	var col_a = PackedFloat32Array()

	var slice_start = Time.get_ticks_usec()
	for order in range(cells.size()):
		if Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await host.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
		var cell = cells[order]
		if cell == null:
			continue
		var idx = host._cell_index(cell, order)
		# 填 is_water 栅格（所有 cell，含水域）。
		var off = HexUtils.cube_to_offset(int(cell.q), int(cell.r))
		if off.x >= 0 and off.x < grid_w and off.y >= 0 and off.y < grid_h:
			offset_is_water[off.y * grid_w + off.x] = (1 if host._is_water_cell(cell, idx) else 0)
			offset_cell_indices[off.y * grid_w + off.x] = idx
		var suitability = cell_suitabilities[order]
		if suitability <= 0.0:
			continue
		var state: Dictionary = cell_states[order]
		if not (state is Dictionary):
			continue
		if host._scatter_presence(state) <= 0.02:
			continue
		var veg = int(state.get("vegetation", VegetationType.VEG.NONE))
		var lf = int(state.get("landform", LandformType.LF.PLAIN))
		var cover = int(state.get("cover", CoverType.CV.NONE))
		var center = host._cell_center(cell, idx)
		var base = host._base_color_for_vegetation(veg)
		keys.append(host._cell_hash_key(cell, order))
		native_cell_indices.append(idx)
		cx.append(center.x)
		cy.append(center.y)
		suit.append(suitability)
		att.append(cell_attempts[order])
		accp.append(cell_accepts[order])
		vit.append(clampf(float(state.get("vitality", 0.7)), 0.0, 1.0))
		sized.append(host._vegetation_weight(veg) * host._landform_weight(lf) * host._cover_weight(cover))
		col_r.append(base.r)
		col_g.append(base.g)
		col_b.append(base.b)
		col_a.append(base.a)

	if keys.is_empty():
		return false

	var knobs = {
		"hex_size": host._hex_size,
		"origin_x": host._bounds.position.x,
		"origin_y": host._bounds.position.y,
		"size_x": host._bounds.size.x,
		"size_y": host._bounds.size.y,
		"wrap_period_x": HexUtils.wrap_period_x(grid_w, host._hex_size),
		"wrap_edge_margin": 0.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": offset_is_water,
		"offset_cell_indices": offset_cell_indices,
		"flow_buffer": host._world.flow_buffer if host._world != null else PackedFloat32Array(),
		"flow_w": int(host._world.derived_size.x) if host._world != null else 0,
		"flow_h": int(host._world.derived_size.y) if host._world != null else 0,
		"river_clear_threshold": cfg.river_clear_threshold,
		"spawn_domain": host._spawn_domain(),
		"rotation_mode": host._rotation_mode(),
		"random_rotation_strength": host._random_rotation_strength(),
		"upright_jitter_radians": deg_to_rad(host._upright_jitter_degrees()),
		"spawn_radius_factor": host._effective_spawn_radius_factor(),
		"world_noise_warp_strength": cfg.world_noise_warp_strength,
		"patch_frequency": cfg.patch_frequency,
		"patch_cutoff": cfg.patch_cutoff,
		"patch_contrast": cfg.patch_contrast,
		"world_noise_mid_mix": cfg.world_noise_mid_mix,
		"world_noise_fine_mix": cfg.world_noise_fine_mix,
		"micro_gap_threshold": cfg.micro_gap_threshold,
		"world_noise_acceptance": cfg.world_noise_acceptance,
		"min_size_factor": minf(cfg.min_size_factor, cfg.max_size_factor),
		"max_size_factor": maxf(cfg.min_size_factor, cfg.max_size_factor),
		"size_scale": host._quality_size_scale(),
		"vitality_dead_threshold": cfg.vitality_dead_threshold,
		"vitality_dieback_noise_strength": cfg.vitality_dieback_noise_strength,
		"instance_cap": host._instance_cap(),
		"keys": keys,
		"cell_indices": native_cell_indices,
		"center_x": cx,
		"center_y": cy,
		"suitability": suit,
		"attempts": att,
		"accept_p": accp,
		"vitality": vit,
		"size_density": sized,
		"color_r": col_r,
		"color_g": col_g,
		"color_b": col_b,
		"color_a": col_a,
	}
	knobs.merge(host._form_knobs())

	var res: Dictionary = await NativeLoadingTasks.compute(host._world_ext,"detail_scatter",knobs)
	if not (res is Dictionary):
		return false
	if bool(res.get("fallback", true)):
		host._last_rebuild_reason = str(res.get("reason", "native_fallback"))
		return false
	host._last_candidate_count = int(res.get("candidate_count", 0))
	host._last_wrap_edge_copy_count = int(res.get("wrap_edge_copy_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var inst: int = int(res.get("instance_count", 0))
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	# 每实例 stride = transform2d(8) + color(4) + custom(4) = 16 float。
	if inst <= 0 or buffer.size() < inst * 16:
		host.clear()
		host._last_rebuild_reason = "native_empty"
		return true
	if cell_indices.size() < inst:
		host._last_rebuild_reason = "native_missing_cell_indices"
		return false
	var lod_payload = host._lod_reorder_native_payload(buffer, cell_indices, inst)
	buffer = lod_payload.get("buffer", PackedFloat32Array())
	cell_indices = lod_payload.get("cell_indices", PackedInt32Array())
	inst = int(lod_payload.get("instance_count", 0))
	host._far_instance_count = int(lod_payload.get("far_count", inst))

	if host._chunked_multimesh_enabled:
		host._instance_count = inst
		host._instance_cell_indices = cell_indices
		host.visible = cfg.enabled and not host._camera_lod_hidden and inst > 0  # 先定 host.visible，使 _apply_chunk_payload 内的 shadow 镜像取到正确可见性
		await host._apply_chunked_native_full(buffer, cell_indices, inst, true)
		# shadow chunk 已随每个 _apply_chunk_payload 镜像完成（_clear_chunk_nodes 已清旧，无孤儿）
		host._last_scatter_path = "gdext_chunked"
		return true

	host._instance_count = inst
	host._instance_cell_indices = cell_indices
	host._multimesh = MultiMesh.new()
	host._multimesh.transform_format = MultiMesh.TRANSFORM_2D
	host._multimesh.use_colors = true
	host._multimesh.use_custom_data = true
	host._multimesh.mesh = host._cached_detail_mesh()
	host._multimesh.instance_count = inst
	host._multimesh.buffer = buffer
	host._multimesh.visible_instance_count = host._lod_visible_count(inst, host._far_instance_count)
	host._mmi.multimesh = host._multimesh
	host.visible = cfg.enabled and not host._camera_lod_hidden and inst > 0
	host._sync_single_wrap_nodes()
	host._sync_shadow_layer(true)
	return true


# 每格散布配额：x = 投放次数，y = 每次的接受概率基数。
# 期望株数 = x * y = max_per_cell * suitability，对 suitability 线性。
#
# 旧实现是 attempts = ceil(max_per_cell * suit) 再对每次投放以 suit 为概率接受，
# 期望株数正比于 suitability² 而且丢掉了 max_per_cell 这一档，中低适宜度的格子
# 因此变成纯抽签（河边季雨林的单格期望株数只有 0.05）。




