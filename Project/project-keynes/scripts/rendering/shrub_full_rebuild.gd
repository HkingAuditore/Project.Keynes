extends RefCounted

## Rebuilds shrub instance buffers and nodes from the native or script scatter results.

static func _native_offset_is_water(layer: ShrubLayer, grid_w: int, grid_h: int) -> PackedByteArray:
	if layer._native_offset_cache_dims == Vector2i(grid_w, grid_h) and layer._native_offset_is_water_cache.size() == grid_w * grid_h:
		layer._last_native_water_cache_ms = 0.0
		return layer._native_offset_is_water_cache
	var t0_us := Time.get_ticks_usec()
	var map_id := layer._map.get_instance_id() if layer._map != null else 0
	var cache_key := "%d:%d:%d" % [map_id, grid_w, grid_h]
	var shared: PackedByteArray = ShrubLayer._shared_offset_is_water_cache.get(cache_key, PackedByteArray())
	if shared.size() == grid_w * grid_h:
		layer._native_offset_is_water_cache = shared
		layer._native_offset_cache_dims = Vector2i(grid_w, grid_h)
		layer._last_native_water_cache_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return layer._native_offset_is_water_cache
	layer._native_offset_is_water_cache = PackedByteArray()
	layer._native_offset_is_water_cache.resize(grid_w * grid_h)
	layer._native_offset_is_water_cache.fill(1)
	if layer._map == null:
		layer._last_native_water_cache_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return layer._native_offset_is_water_cache
	var cells: Array = layer._map.iter_cells()
	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := layer._cell_index(cell, order)
		var off := HexUtils.cube_to_offset(int(cell.q), int(cell.r))
		if off.x >= 0 and off.x < grid_w and off.y >= 0 and off.y < grid_h:
			layer._native_offset_is_water_cache[off.y * grid_w + off.x] = (1 if layer._is_water_cell(cell, idx) else 0)
	layer._native_offset_cache_dims = Vector2i(grid_w, grid_h)
	ShrubLayer._shared_offset_is_water_cache[cache_key] = layer._native_offset_is_water_cache
	layer._last_native_water_cache_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return layer._native_offset_is_water_cache


static func _vegetation_climate_tables(layer: ShrubLayer) -> Dictionary:
	if not layer._native_veg_climate_tables.is_empty():
		return layer._native_veg_climate_tables
	var n_veg: int = VegetationType.VEG.size()
	var ideal_temp := PackedFloat32Array()
	var ideal_moist := PackedFloat32Array()
	var temp_tol := PackedFloat32Array()
	var moist_tol := PackedFloat32Array()
	ideal_temp.resize(n_veg)
	ideal_moist.resize(n_veg)
	temp_tol.resize(n_veg)
	moist_tol.resize(n_veg)
	for v in range(n_veg):
		var p = ShrubLayer.VegetationProfileRegistryScript.get_profile(v)
		ideal_temp[v] = float(p.ideal_temp) if p != null else 0.5
		ideal_moist[v] = float(p.ideal_moist) if p != null else 0.5
		temp_tol[v] = maxf(float(p.temp_tolerance), 0.01) if p != null else 0.28
		moist_tol[v] = maxf(float(p.moist_tolerance), 0.01) if p != null else 0.28
	layer._native_veg_climate_tables = {
		"ideal_temp": ideal_temp,
		"ideal_moist": ideal_moist,
		"temp_tol": temp_tol,
		"moist_tol": moist_tol,
	}
	return layer._native_veg_climate_tables


static func _rebuild_instances(layer: ShrubLayer) -> void:
	layer._ensure_resources()
	var t0_us := Time.get_ticks_usec()
	layer._last_candidate_count = 0
	layer._last_wrap_edge_copy_count = 0
	layer._last_rebuild_reason = ""
	layer._last_incremental_cells = 0
	layer._last_incremental_missing_slots = 0
	layer._last_incremental_dropped_instances = 0
	layer._last_dirty_chunks = 0
	layer._last_native_sampled_cells = 0
	layer._last_native_active_cells = 0
	layer.clear()
	var cfg := layer._profile()
	if not cfg.enabled or layer._map == null or layer._map.cell_count() <= 0:
		layer._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		return

	var cells: Array = layer._map.iter_cells()
	if cells.is_empty():
		cells = layer._map.all_cells()
	if cells.is_empty():
		layer._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		layer._last_rebuild_reason = "no_cells"
		return

	var cell_attempts := PackedInt32Array()
	cell_attempts.resize(cells.size())
	var cell_accepts := PackedFloat32Array()
	cell_accepts.resize(cells.size())
	var cell_states: Array = []
	cell_states.resize(cells.size())
	var cell_suitabilities := PackedFloat32Array()
	cell_suitabilities.resize(cells.size())
	var total_attempts: int = 0
	var max_per_cell: int = maxi(1, ShrubLayer.ShrubScatter._max_per_cell(layer))
	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := layer._cell_index(cell, order)
		var key := ShrubLayer.ShrubScatter._cell_hash_key(layer, cell, order)
		var state := ShrubLayer.ShrubScatter._sample_cell_state(layer, idx, cell)
		var suitability := ShrubLayer.ShrubScatter._cell_suitability(layer, cell, idx, key, state)
		if suitability <= 0.0:
			continue
		cell_states[order] = state
		cell_suitabilities[order] = suitability
		var quota := ShrubLayer.ShrubScatter._cell_quota(layer, suitability, max_per_cell)
		var attempts: int = int(quota.x)
		cell_attempts[order] = attempts
		cell_accepts[order] = quota.y
		total_attempts += attempts

	if total_attempts <= 0:
		layer._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		layer._last_rebuild_reason = "no_attempts"
		return

	# C++ 优先：把"每实例候选生成 + 噪声门 + 接受 + cap + MultiMesh buffer 组装"
	# 整段热循环下沉 DCWorldExt.encode_detail_scatter，GDScript 仅做上面这段
	# per-cell（N≤2400）廉价预计算。失败 / 旧 DLL 无该方法时回退到下方 GDScript 路径。
	if layer._rebuild_via_native(cells, cell_states, cell_suitabilities, cell_attempts, cell_accepts):
		if layer._last_scatter_path.is_empty():
			layer._last_scatter_path = "gdext"
		layer._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		ShrubLayer.Chunk_refresh._rebuild_cell_instance_lookup(layer)
		return
	layer._last_scatter_path = "gdscript"

	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := layer._cell_index(cell, order)
		var key := ShrubLayer.ShrubScatter._cell_hash_key(layer, cell, order)
		var suitability := cell_suitabilities[order]
		if suitability <= 0.0:
			continue
		var state: Dictionary = cell_states[order]
		var accept_p := cell_accepts[order]
		for attempt in range(cell_attempts[order]):
			ShrubLayer.ShrubScatter._try_append_instance(layer, cell, idx, key, attempt, suitability, accept_p, state)

	ShrubLayer.ShrubScatter._apply_instance_cap(layer)
	ShrubLayer.Chunk_refresh._reorder_generated_instances_for_lod(layer)
	layer._instance_count = layer._instance_cell_indices.size()
	ShrubLayer.Chunk_refresh._rebuild_cell_instance_lookup(layer)
	if layer._instance_count <= 0:
		layer._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
		layer._last_rebuild_reason = "no_instances"
		return

	layer._multimesh = MultiMesh.new()
	layer._multimesh.transform_format = MultiMesh.TRANSFORM_2D
	layer._multimesh.use_colors = true
	layer._multimesh.use_custom_data = true
	layer._multimesh.mesh = ShrubLayer.ShrubScatter._cached_detail_mesh(layer)
	layer._multimesh.instance_count = layer._instance_count
	layer._multimesh.visible_instance_count = ShrubLayer.Chunk_budget._lod_visible_count(layer, layer._instance_count, layer._far_instance_count)
	layer._mmi.multimesh = layer._multimesh

	for i in range(layer._instance_count):
		var xf := ShrubLayer.ShrubScatter._instance_transform(layer, i)
		layer._multimesh.set_instance_transform_2d(i, xf)
		var idx := layer._instance_cell_indices[i]
		var state := ShrubLayer.ShrubScatter._sample_cell_state(layer, idx, layer._instance_cells[i])
		layer._multimesh.set_instance_color(i, ShrubLayer.ShrubScatter._base_color_for_state(layer, state, layer._instance_variants[i]))
		var uv := ShrubLayer.Diagnostics._world_uv(layer, layer._instance_positions[i])
		layer._multimesh.set_instance_custom_data(i, Color(
			uv.x,
			uv.y,
			layer._instance_seeds[i],
			layer._instance_forms[i]
		))
	layer.visible = cfg.enabled and not layer._camera_lod_hidden and layer._instance_count > 0
	layer._sync_single_wrap_nodes()
	ShrubLayer.Chunk_nodes._sync_shadow_layer(layer, true)
	layer._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	layer._last_candidate_count = layer._instance_scores.size()


static func _rebuild_via_native(layer: ShrubLayer,
		cells: Array,
		cell_states: Array,
		cell_suitabilities: PackedFloat32Array,
		cell_attempts: PackedInt32Array,
		cell_accepts: PackedFloat32Array) -> bool:
	if layer._world_ext == null:
		return false
	if layer._map == null:
		return false
	var grid_w: int = int(layer._map.width) if "width" in layer._map else 0
	var grid_h: int = int(layer._map.height) if "height" in layer._map else 0
	if grid_w <= 0 or grid_h <= 0:
		return false
	var cfg := layer._profile()

	# offset 网格（odd-r）用于 C++ 端精确复刻 world_to_wrapped_cell：
	# world_to_cube → cube_to_offset → 越界 / 横向环绕。水域空位预置 1
	# （拒绝），cell 索引空位预置 -1。
	var offset_is_water := PackedByteArray()
	offset_is_water.resize(grid_w * grid_h)
	offset_is_water.fill(1)
	var offset_cell_indices := PackedInt32Array()
	offset_cell_indices.resize(grid_w * grid_h)
	offset_cell_indices.fill(-1)

	# 每个"活跃 cell"（suitability>0 且 climate_presence>0.02）的廉价 per-cell 数据。
	var keys := PackedInt32Array()
	var native_cell_indices := PackedInt32Array()
	var cx := PackedFloat32Array()
	var cy := PackedFloat32Array()
	var suit := PackedFloat32Array()
	var att := PackedInt32Array()
	var accp := PackedFloat32Array()
	var vit := PackedFloat32Array()
	var sized := PackedFloat32Array()
	var col_r := PackedFloat32Array()
	var col_g := PackedFloat32Array()
	var col_b := PackedFloat32Array()
	var col_a := PackedFloat32Array()

	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var idx := layer._cell_index(cell, order)
		# 填 is_water 栅格（所有 cell，含水域）。
		var off := HexUtils.cube_to_offset(int(cell.q), int(cell.r))
		if off.x >= 0 and off.x < grid_w and off.y >= 0 and off.y < grid_h:
			offset_is_water[off.y * grid_w + off.x] = (1 if layer._is_water_cell(cell, idx) else 0)
			offset_cell_indices[off.y * grid_w + off.x] = idx
		var suitability := cell_suitabilities[order]
		if suitability <= 0.0:
			continue
		var state: Dictionary = cell_states[order]
		if not (state is Dictionary):
			continue
		if ShrubLayer.ShrubScatter._scatter_presence(layer, state) <= 0.02:
			continue
		var veg := int(state.get("vegetation", VegetationType.VEG.NONE))
		var lf := int(state.get("landform", LandformType.LF.PLAIN))
		var cover := int(state.get("cover", CoverType.CV.NONE))
		var center := layer._cell_center(cell, idx)
		var base := ShrubLayer.ShrubScatter._base_color_for_vegetation(layer, veg)
		keys.append(ShrubLayer.ShrubScatter._cell_hash_key(layer, cell, order))
		native_cell_indices.append(idx)
		cx.append(center.x)
		cy.append(center.y)
		suit.append(suitability)
		att.append(cell_attempts[order])
		accp.append(cell_accepts[order])
		vit.append(clampf(float(state.get("vitality", 0.7)), 0.0, 1.0))
		sized.append(ShrubLayer.ShrubScatter._vegetation_weight(layer, veg) * ShrubLayer.ShrubScatter._landform_weight(layer, lf) * ShrubLayer.ShrubScatter._cover_weight(layer, cover))
		col_r.append(base.r)
		col_g.append(base.g)
		col_b.append(base.b)
		col_a.append(base.a)

	if keys.is_empty():
		return false

	var knobs := {
		"hex_size": layer._hex_size,
		"origin_x": layer._bounds.position.x,
		"origin_y": layer._bounds.position.y,
		"size_x": layer._bounds.size.x,
		"size_y": layer._bounds.size.y,
		"wrap_period_x": HexUtils.wrap_period_x(grid_w, layer._hex_size),
		"wrap_edge_margin": 0.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": offset_is_water,
		"offset_cell_indices": offset_cell_indices,
		"flow_buffer": layer._world.flow_buffer if layer._world != null else PackedFloat32Array(),
		"flow_w": int(layer._world.derived_size.x) if layer._world != null else 0,
		"flow_h": int(layer._world.derived_size.y) if layer._world != null else 0,
		"river_clear_threshold": cfg.river_clear_threshold,
		"spawn_domain": ShrubLayer.ShrubScatter._spawn_domain(layer),
		"rotation_mode": ShrubLayer.ShrubScatter._rotation_mode(layer),
		"random_rotation_strength": ShrubLayer.ShrubScatter._random_rotation_strength(layer),
		"upright_jitter_radians": deg_to_rad(ShrubLayer.ShrubScatter._upright_jitter_degrees(layer)),
		"spawn_radius_factor": layer._effective_spawn_radius_factor(),
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
		"size_scale": layer._quality_size_scale(),
		"vitality_dead_threshold": cfg.vitality_dead_threshold,
		"vitality_dieback_noise_strength": cfg.vitality_dieback_noise_strength,
		"instance_cap": ShrubLayer.ShrubScatter._instance_cap(layer),
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
	knobs.merge(layer._form_knobs())

	var res = layer._world_ext.call("encode_detail_scatter", knobs)
	if not (res is Dictionary):
		return false
	if bool(res.get("fallback", true)):
		layer._last_rebuild_reason = str(res.get("reason", "native_fallback"))
		return false
	layer._last_candidate_count = int(res.get("candidate_count", 0))
	layer._last_wrap_edge_copy_count = int(res.get("wrap_edge_copy_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var inst: int = int(res.get("instance_count", 0))
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	# 每实例 stride = transform2d(8) + color(4) + custom(4) = 16 float。
	if inst <= 0 or buffer.size() < inst * 16:
		layer.clear()
		layer._last_rebuild_reason = "native_empty"
		return true
	if cell_indices.size() < inst:
		layer._last_rebuild_reason = "native_missing_cell_indices"
		return false
	var lod_payload := ShrubLayer.Chunk_refresh._lod_reorder_native_payload(layer, buffer, cell_indices, inst)
	buffer = lod_payload.get("buffer", PackedFloat32Array())
	cell_indices = lod_payload.get("cell_indices", PackedInt32Array())
	inst = int(lod_payload.get("instance_count", 0))
	layer._far_instance_count = int(lod_payload.get("far_count", inst))

	if layer._chunked_multimesh_enabled:
		layer._instance_count = inst
		layer._instance_cell_indices = cell_indices
		layer.visible = cfg.enabled and not layer._camera_lod_hidden and inst > 0  # 先定 visible，使 _apply_chunk_payload 内的 shadow 镜像取到正确可见性
		layer._apply_chunked_native_full(buffer, cell_indices, inst)
		# shadow chunk 已随每个 _apply_chunk_payload 镜像完成（_clear_chunk_nodes 已清旧，无孤儿）
		layer._last_scatter_path = "gdext_chunked"
		return true

	layer._instance_count = inst
	layer._instance_cell_indices = cell_indices
	layer._multimesh = MultiMesh.new()
	layer._multimesh.transform_format = MultiMesh.TRANSFORM_2D
	layer._multimesh.use_colors = true
	layer._multimesh.use_custom_data = true
	layer._multimesh.mesh = ShrubLayer.ShrubScatter._cached_detail_mesh(layer)
	layer._multimesh.instance_count = inst
	layer._multimesh.buffer = buffer
	layer._multimesh.visible_instance_count = ShrubLayer.Chunk_budget._lod_visible_count(layer, inst, layer._far_instance_count)
	layer._mmi.multimesh = layer._multimesh
	layer.visible = cfg.enabled and not layer._camera_lod_hidden and inst > 0
	layer._sync_single_wrap_nodes()
	ShrubLayer.Chunk_nodes._sync_shadow_layer(layer, true)
	return true


# 每格散布配额：x = 投放次数，y = 每次的接受概率基数。
# 期望株数 = x * y = max_per_cell * suitability，对 suitability 线性。
#
# 旧实现是 attempts = ceil(max_per_cell * suit) 再对每次投放以 suit 为概率接受，
# 期望株数正比于 suitability² 而且丢掉了 max_per_cell 这一档，中低适宜度的格子
# 因此变成纯抽签（河边季雨林的单格期望株数只有 0.05）。
