extends RefCounted

## Stateless collaborator for ShrubLayer.

static func begin_detail_chunk_refresh(host) -> void:

	host._last_native_water_cache_ms = 0.0
	host._last_native_context_ms = 0.0
	host._last_native_knobs_ms = 0.0
	host._last_native_call_ms = 0.0
	host._last_native_apply_ms = 0.0
	host._last_cache_update_ms = 0.0
	host._last_assemble_ms = 0.0
	host._native_delta_common_knobs = {}



static func _build_native_delta_common_knobs(host) -> Dictionary:

	var t0_us = Time.get_ticks_usec()
	if host._map == null:
		host._last_native_context_ms = 0.0
		return {}
	var grid_w: int = int(host._map.width) if "width" in host._map else 0
	var grid_h: int = int(host._map.height) if "height" in host._map else 0
	if grid_w <= 0 or grid_h <= 0:
		host._last_native_context_ms = 0.0
		return {}
	var cfg = host._profile()
	var veg_tables = host._vegetation_climate_tables()
	var override_color: Color = cfg.base_color_override
	var common = {
		"cell_pos_x": host._map.cell_pos_x_arr,
		"cell_pos_y": host._map.cell_pos_y_arr,
		"temp_arr": host._map.temp_arr,
		"moisture_arr": host._map.moisture_arr,
		"snow_cover_arr": host._map.snow_cover_arr,
		"weather_intensity_arr": host._map.weather_intensity_arr,
		"vegetation_vitality_arr": host._map.vegetation_vitality_arr,
		"vegetation_heat_stress_arr": host._map.vegetation_heat_stress_arr,
		"vegetation_drought_stress_arr": host._map.vegetation_drought_stress_arr,
		"vegetation_cold_stress_arr": host._map.vegetation_cold_stress_arr,
		"landform_arr": host._map.landform_arr,
		"vegetation_arr": host._map.vegetation_arr,
		"cover_arr": host._map.cover_arr,
		"weather_type_arr": host._map.weather_type_arr,
		"elevation_arr": host._map.elevation_arr,
		"soil_moisture_arr": host._map.soil_moisture_arr,
		"river_discharge_arr": host._map.river_discharge_arr,
		"wind_speed_arr": host._map.wind_speed_arr,
		"is_water_arr": host._map.is_water_arr,
		"has_river_arr": host._map.has_river_arr,
		"settlement_core_buckets": host._settlement_core_buckets,
		"veg_ideal_temp": veg_tables.get("ideal_temp", PackedFloat32Array()),
		"veg_ideal_moist": veg_tables.get("ideal_moist", PackedFloat32Array()),
		"veg_temp_tol": veg_tables.get("temp_tol", PackedFloat32Array()),
		"veg_moist_tol": veg_tables.get("moist_tol", PackedFloat32Array()),
		"veg_biomass": VegetationType.foliage_biomass_table(),
		"hex_size": host._hex_size,
		"origin_x": host._bounds.position.x,
		"origin_y": host._bounds.position.y,
		"size_x": host._bounds.size.x,
		"size_y": host._bounds.size.y,
		"wrap_period_x": HexUtils.wrap_period_x(grid_w, host._hex_size),
		"wrap_edge_margin": 0.0,
		"grid_w": grid_w,
		"grid_h": grid_h,
		"offset_is_water": host._native_offset_is_water(grid_w, grid_h),
		"flow_buffer": host._world.flow_buffer if host._world != null else PackedFloat32Array(),
		"flow_w": int(host._world.derived_size.x) if host._world != null else 0,
		"flow_h": int(host._world.derived_size.y) if host._world != null else 0,
		"detail_kind": host._detail_kind(),
		"max_per_cell": host._max_per_cell(),
		"quality_density_scale": host._quality_density_scale(),
		"river_clear_threshold": cfg.river_clear_threshold,
		"river_edge_density": cfg.river_edge_density,
		"river_valley_boost": cfg.river_valley_boost,
		"biomass_floor": cfg.biomass_floor,
		"biomass_ceil": cfg.biomass_ceil,
		"biomass_exponent": cfg.biomass_exponent,
		"spawn_domain": host._spawn_domain(),
		"rotation_mode": host._rotation_mode(),
		"random_rotation_strength": host._random_rotation_strength(),
		"upright_jitter_radians": deg_to_rad(host._upright_jitter_degrees()),
		"base_color_override_enabled": bool(cfg.base_color_override_enabled),
		"base_color_r": override_color.r,
		"base_color_g": override_color.g,
		"base_color_b": override_color.b,
		"base_color_a": override_color.a,
		"vegetation_weight_overrides": cfg.vegetation_weight_overrides,
		"landform_weight_overrides": cfg.landform_weight_overrides,
		"cover_weight_overrides": cfg.cover_weight_overrides,
		"spawn_radius_factor": host._effective_spawn_radius_factor(),
		"world_noise_warp_strength": cfg.world_noise_warp_strength,
		"patch_frequency": cfg.patch_frequency,
		"patch_cutoff": cfg.patch_cutoff,
		"patch_contrast": cfg.patch_contrast,
		"world_noise_mid_mix": cfg.world_noise_mid_mix,
		"world_noise_fine_mix": cfg.world_noise_fine_mix,
		"micro_gap_threshold": cfg.micro_gap_threshold,
		"world_noise_acceptance": cfg.world_noise_acceptance,
		"moisture_corridor_boost": cfg.moisture_corridor_boost,
		"vitality_patch_boost": cfg.vitality_patch_boost,
		"stress_hide_strength": cfg.stress_hide_strength,
		"snow_hide_strength": cfg.snow_hide_strength,
		"min_size_factor": minf(cfg.min_size_factor, cfg.max_size_factor),
		"max_size_factor": maxf(cfg.min_size_factor, cfg.max_size_factor),
		"size_scale": host._quality_size_scale(),
		"vitality_dead_threshold": cfg.vitality_dead_threshold,
		"vitality_sparse_threshold": cfg.vitality_sparse_threshold,
		"vitality_healthy_threshold": cfg.vitality_healthy_threshold,
		"vitality_density_power": cfg.vitality_density_power,
		"vitality_alpha_power": cfg.vitality_alpha_power,
		"vitality_dieback_noise_strength": cfg.vitality_dieback_noise_strength,
		# LOD 前缀排序下沉：原生 encode 直接返回按 _lod_order_sources 语义排好序的
		# buffer + far_count，chunk apply 免 GDScript 排序 + 免整段 buffer 重排。
		"lod_order_enabled": host.native_lod_order_enabled,
		"lod_near_density_multiplier": host._resolved_lod_near_density_multiplier(),
	}
	common.merge(host._form_knobs())
	host._last_native_context_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	return common



static func _ensure_incremental_multimesh(host) -> void:

	host._ensure_resources()
	if host._multimesh != null:
		return
	host._multimesh = MultiMesh.new()
	host._multimesh.transform_format = MultiMesh.TRANSFORM_2D
	host._multimesh.use_colors = true
	host._multimesh.use_custom_data = true
	host._multimesh.mesh = host._cached_detail_mesh()
	host._multimesh.instance_count = 0
	host._multimesh.visible_instance_count = 0
	host._mmi.multimesh = host._multimesh



static func _rebuild_cell_instance_lookup(host) -> void:

	host._cell_instance_lookup.clear()
	for i in range(host._instance_cell_indices.size()):
		var ci = int(host._instance_cell_indices[i])
		if ci < 0:
			continue
		var slots: Array = host._cell_instance_lookup.get(ci, [])
		slots.append(i)
		host._cell_instance_lookup[ci] = slots



static func _append_instance_slots(host, cell_idx: int, count: int) -> Array:

	var slots: Array = []
	if count <= 0 or host._multimesh == null:
		return slots
	var old_count = host._instance_count
	var next_count = old_count + count
	var buffer = host._multimesh.buffer
	buffer.resize(next_count * 16)
	host._multimesh.instance_count = next_count
	host._multimesh.buffer = buffer
	host._multimesh.visible_instance_count = next_count
	host._instance_count = next_count
	for i in range(old_count, next_count):
		slots.append(i)
		host._instance_cell_indices.append(cell_idx)
	return slots



static func _generate_cell_instance_payload(host, cell, idx: int) -> Dictionary:

	var state = host._sample_cell_state(idx, cell)
	var key = host._cell_hash_key(cell, idx)
	var suitability = host._cell_suitability(cell, idx, key, state)
	var transforms: Array = []
	var colors: Array = []
	var customs: Array = []
	if suitability <= 0.0:
		return {"transforms": transforms, "colors": colors, "customs": customs}
	var quota = host._cell_quota(suitability, maxi(1, host._max_per_cell()))
	var attempts = int(quota.x)
	var accept_p = quota.y

	var saved_cell_indices = host._instance_cell_indices
	var saved_positions = host._instance_positions
	var saved_rotations = host._instance_rotations
	var saved_sizes = host._instance_sizes
	var saved_seeds = host._instance_seeds
	var saved_variants = host._instance_variants
	var saved_forms = host._instance_forms
	var saved_scores = host._instance_scores
	var saved_cells = host._instance_cells.duplicate()

	host._instance_cell_indices = PackedInt32Array()
	host._instance_positions = PackedVector2Array()
	host._instance_rotations = PackedFloat32Array()
	host._instance_sizes = PackedFloat32Array()
	host._instance_seeds = PackedFloat32Array()
	host._instance_variants = PackedFloat32Array()
	host._instance_forms = PackedFloat32Array()
	host._instance_scores = PackedFloat32Array()
	host._instance_cells = []

	for attempt in range(attempts):
		host._try_append_instance(cell, idx, key, attempt, suitability, accept_p, state)
	for i in range(host._instance_cell_indices.size()):
		var inst_idx = int(host._instance_cell_indices[i])
		var inst_cell = host._instance_cells[i]
		var inst_state = host._sample_cell_state(inst_idx, inst_cell)
		transforms.append(host._instance_transform(i))
		colors.append(host._base_color_for_state(inst_state, host._instance_variants[i]))
		var uv = host._world_uv(host._instance_positions[i])
		customs.append(Color(uv.x, uv.y, host._instance_seeds[i], host._instance_forms[i]))

	host._instance_cell_indices = saved_cell_indices
	host._instance_positions = saved_positions
	host._instance_rotations = saved_rotations
	host._instance_sizes = saved_sizes
	host._instance_seeds = saved_seeds
	host._instance_variants = saved_variants
	host._instance_forms = saved_forms
	host._instance_scores = saved_scores
	host._instance_cells = saved_cells

	return {"transforms": transforms, "colors": colors, "customs": customs}



static func refresh_for_succession(host, indices: PackedInt32Array) -> void:

	if host._map == null or indices.is_empty():
		return
	if host._chunked_multimesh_enabled and host._refresh_chunked_for_succession(indices):
		return  # 分块：shadow chunk 已在 _apply_chunk_payload 内逐 chunk 镜像（O(脏chunk)）
	host._ensure_incremental_multimesh()
	if host._multimesh == null:
		return
	if host._refresh_for_succession_native(indices):
		host._sync_single_shadow()
		return
	var t0_us := Time.get_ticks_usec()
	var cells_done := 0
	var missing_slots := 0
	var dropped := 0
	var generated := 0
	for ci in indices:
		var idx := int(ci)
		var cell: Variant = host._map.cell_at(idx)
		if cell == null:
			missing_slots += 1
			continue
		var payload: Dictionary = host._generate_cell_instance_payload(cell, idx)
		var transforms: Array = payload.get("transforms", [])
		var colors: Array = payload.get("colors", [])
		var customs: Array = payload.get("customs", [])
		var next_count := transforms.size()
		generated += next_count
		var slots: Array = host._cell_instance_lookup.get(idx, [])
		if slots.size() < next_count:
			var new_slots: Array = host._append_instance_slots(idx, next_count - slots.size())
			for slot in new_slots:
				slots.append(slot)
			host._cell_instance_lookup[idx] = slots
		var write_count := mini(slots.size(), next_count)
		for j in range(write_count):
			var slot := int(slots[j])
			host._multimesh.set_instance_transform_2d(slot, transforms[j])
			host._multimesh.set_instance_color(slot, colors[j])
			host._multimesh.set_instance_custom_data(slot, customs[j])
		for j in range(write_count, slots.size()):
			var slot := int(slots[j])
			host._multimesh.set_instance_color(slot, Color(0, 0, 0, 0))
		if next_count > slots.size():
			dropped += next_count - slots.size()
		cells_done += 1
	host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	host._last_candidate_count = generated
	host._last_rebuild_reason = "incremental_cell_update"
	host._last_incremental_cells = cells_done
	host._last_incremental_missing_slots = missing_slots
	host._last_incremental_dropped_instances = dropped
	host.visible = host._profile().enabled and not host._camera_lod_hidden and host._instance_count > 0
	host._sync_single_wrap_nodes()
	host._sync_single_shadow()



static func _refresh_for_succession_native(host, indices: PackedInt32Array) -> bool:

	if host._map == null or host._multimesh == null:
		return false
	var t0_us := Time.get_ticks_usec()
	var payload: Dictionary = host._encode_native_payload_for_indices(indices, 0)
	if not bool(payload.get("ok", false)):
		host._last_rebuild_reason = str(payload.get("reason", "native_delta_fallback"))
		return false
	var res: Dictionary = payload.get("res", {})
	var inst := int(res.get("instance_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	if inst > 0 and (buffer.size() < inst * 16 or cell_indices.size() < inst):
		host._last_rebuild_reason = "native_delta_bad_payload"
		return false
	host._apply_native_delta_payload(
		payload.get("valid_indices", indices),
		buffer,
		cell_indices,
		inst,
		int(res.get("candidate_count", 0)),
		int(res.get("wrap_edge_copy_count", 0)),
		t0_us
	)
	return true



static func _apply_native_delta_payload(
		host,
		valid_indices: PackedInt32Array,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int,
		candidate_count: int,
		wrap_count: int,
		t0_us: int) -> void:

	var by_cell := {}
	for i in range(inst):
		var ci := int(cell_indices[i])
		var srcs: Array = by_cell.get(ci, [])
		srcs.append(i)
		by_cell[ci] = srcs

	var cells_done := 0
	var missing_slots := 0
	var dropped := 0
	var generated := 0
	for raw_idx in valid_indices:
		var idx := int(raw_idx)
		var src_indices: Array = by_cell.get(idx, [])
		var slots: Array = host._cell_instance_lookup.get(idx, [])
		generated += src_indices.size()
		if slots.size() < src_indices.size():
			var new_slots: Array = host._append_instance_slots(idx, src_indices.size() - slots.size())
			for slot in new_slots:
				slots.append(slot)
			host._cell_instance_lookup[idx] = slots
		var write_count := mini(slots.size(), src_indices.size())
		for j in range(write_count):
			host._set_slot_from_native_buffer(int(slots[j]), buffer, int(src_indices[j]))
		for j in range(write_count, slots.size()):
			host._multimesh.set_instance_color(int(slots[j]), Color(0, 0, 0, 0))
		if src_indices.size() > slots.size():
			dropped += src_indices.size() - slots.size()
		if slots.is_empty() and src_indices.is_empty():
			missing_slots += 1
		cells_done += 1

	host._last_scatter_path = "gdext_delta"
	host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	host._last_candidate_count = maxi(candidate_count, generated)
	host._last_wrap_edge_copy_count = wrap_count
	host._last_rebuild_reason = "incremental_cell_update"
	host._last_incremental_cells = cells_done
	host._last_incremental_missing_slots = missing_slots
	host._last_incremental_dropped_instances = dropped
	host.visible = host._profile().enabled and not host._camera_lod_hidden and host._instance_count > 0
	host._sync_single_wrap_nodes()
	host._sync_single_shadow()



static func _set_slot_from_native_buffer(
		host, slot: int, buffer: PackedFloat32Array, src: int) -> void:

	var b := src * 16
	var xf := Transform2D(
		Vector2(buffer[b + 0], buffer[b + 4]),
		Vector2(buffer[b + 1], buffer[b + 5]),
		Vector2(buffer[b + 3], buffer[b + 7])
	)
	host._multimesh.set_instance_transform_2d(slot, xf)
	host._multimesh.set_instance_color(slot, Color(buffer[b + 8], buffer[b + 9], buffer[b + 10], buffer[b + 11]))
	host._multimesh.set_instance_custom_data(slot, Color(buffer[b + 12], buffer[b + 13], buffer[b + 14], buffer[b + 15]))



static func _lod_order_sources(host, 
		src_indices: Array,
		cell_indices: PackedInt32Array,
		buffer: PackedFloat32Array) -> Dictionary:

	# MultiMesh.visible_instance_count only exposes a prefix. Build that prefix as a
	# stable, cell-stratified far field, then append per-cell near-detail layers.
	# This prevents storage order (or nth_element cap order) from making whole hexes
	# disappear while adjacent hexes retain every instance.
	var by_cell = {}
	for raw_src in src_indices:
		var src = int(raw_src)
		if src < 0 or src >= cell_indices.size():
			continue
		var cell_idx = int(cell_indices[src])
		var group: Array = by_cell.get(cell_idx, [])
		group.append(src)
		by_cell[cell_idx] = group
	var cell_ids: Array = by_cell.keys()
	cell_ids.sort()
	for raw_cell_id in cell_ids:
		var group: Array = by_cell[raw_cell_id]
		group.sort_custom(func(a, b) -> bool:
			var ai = int(a) * 16 + 14
			var bi = int(b) * 16 + 14
			var av = buffer[ai] if ai >= 0 and ai < buffer.size() else float(a)
			var bv = buffer[bi] if bi >= 0 and bi < buffer.size() else float(b)
			return av < bv
		)
		# East/west wrap copies share the exact same seed. Keep them in one atomic
		# cluster so a LOD prefix never shows the source without its seam copy.
		var clusters: Array = []
		var last_seed = -2.0
		for raw_src in group:
			var src = int(raw_src)
			var seed_idx = src * 16 + 14
			var seed = buffer[seed_idx] if seed_idx >= 0 and seed_idx < buffer.size() else float(src)
			if clusters.is_empty() or absf(seed - last_seed) > 0.000001:
				clusters.append([])
			var cluster: Array = clusters[clusters.size() - 1]
			cluster.append(src)
			clusters[clusters.size() - 1] = cluster
			last_seed = seed
		by_cell[raw_cell_id] = clusters

	var multiplier = maxf(host._resolved_lod_near_density_multiplier(), 1.0)
	var far_counts = {}
	var max_far = 0
	var max_total = 0
	for raw_cell_id in cell_ids:
		var clusters: Array = by_cell[raw_cell_id]
		var far_count = mini(clusters.size(), maxi(1, int(ceil(float(clusters.size()) / multiplier))))
		far_counts[raw_cell_id] = far_count
		max_far = maxi(max_far, far_count)
		max_total = maxi(max_total, clusters.size())

	var ordered: Array = []
	# Round-robin by cell: under an emergency global budget, one representative
	# survives in as many occupied cells as possible before second/third instances.
	for rank in range(max_far):
		for raw_cell_id in cell_ids:
			var clusters: Array = by_cell[raw_cell_id]
			if rank < int(far_counts[raw_cell_id]):
				var cluster: Array = clusters[rank]
				for raw_src in cluster:
					ordered.append(int(raw_src))
	var far_total = ordered.size()
	for rank in range(max_total):
		for raw_cell_id in cell_ids:
			var clusters: Array = by_cell[raw_cell_id]
			var far_count = int(far_counts[raw_cell_id])
			var local_idx = far_count + rank
			if local_idx < clusters.size():
				var cluster: Array = clusters[local_idx]
				for raw_src in cluster:
					ordered.append(int(raw_src))
	return {
		"order": ordered,
		"far_count": far_total,
	}



static func _lod_reorder_native_payload(host, 
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> Dictionary:

	var src_indices: Array = []
	for i in range(inst):
		src_indices.append(i)
	var lod_order = _lod_order_sources(host, src_indices, cell_indices, buffer)
	var ordered_sources: Array = lod_order.get("order", [])
	inst = mini(inst, ordered_sources.size())
	var ordered_buffer = PackedFloat32Array()
	var ordered_cells = PackedInt32Array()
	ordered_buffer.resize(inst * 16)
	ordered_cells.resize(inst)
	for dst in range(inst):
		var src = int(ordered_sources[dst])
		ordered_cells[dst] = cell_indices[src]
		for k in range(16):
			ordered_buffer[dst * 16 + k] = buffer[src * 16 + k]
	return {
		"buffer": ordered_buffer,
		"cell_indices": ordered_cells,
		"instance_count": inst,
		"far_count": mini(int(lod_order.get("far_count", inst)), inst),
	}



static func _reorder_generated_instances_for_lod(host) -> void:

	var n = host._instance_cell_indices.size()
	if n <= 0:
		host._far_instance_count = 0
		return
	var src_indices: Array = []
	var seed_buffer = PackedFloat32Array()
	seed_buffer.resize(n * 16)
	for i in range(n):
		src_indices.append(i)
		seed_buffer[i * 16 + 14] = host._instance_seeds[i]
	var lod_order = _lod_order_sources(host, src_indices, host._instance_cell_indices, seed_buffer)
	var order: Array = lod_order.get("order", [])
	var next_cell_indices = PackedInt32Array()
	var next_positions = PackedVector2Array()
	var next_rotations = PackedFloat32Array()
	var next_sizes = PackedFloat32Array()
	var next_seeds = PackedFloat32Array()
	var next_variants = PackedFloat32Array()
	var next_forms = PackedFloat32Array()
	var next_scores = PackedFloat32Array()
	var next_cells: Array = []
	for raw_src in order:
		var src = int(raw_src)
		next_cell_indices.append(host._instance_cell_indices[src])
		next_positions.append(host._instance_positions[src])
		next_rotations.append(host._instance_rotations[src])
		next_sizes.append(host._instance_sizes[src])
		next_seeds.append(host._instance_seeds[src])
		next_variants.append(host._instance_variants[src])
		next_forms.append(host._instance_forms[src])
		next_scores.append(host._instance_scores[src])
		next_cells.append(host._instance_cells[src])
	host._instance_cell_indices = next_cell_indices
	host._instance_positions = next_positions
	host._instance_rotations = next_rotations
	host._instance_sizes = next_sizes
	host._instance_seeds = next_seeds
	host._instance_variants = next_variants
	host._instance_forms = next_forms
	host._instance_scores = next_scores
	host._instance_cells = next_cells
	host._far_instance_count = mini(int(lod_order.get("far_count", n)), n)



static func _prepare_chunk_multimesh(host, chunk_id: int, inst: int, far_count: int = -1) -> MultiMesh:

	var node = host._ensure_chunk_node(chunk_id)
	var mm = node.multimesh
	if mm == null:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		node.multimesh = mm
	mm.mesh = host._cached_detail_mesh()
	mm.instance_count = inst
	host._chunk_instance_counts[chunk_id] = inst
	host._chunk_far_instance_counts[chunk_id] = clampi(far_count if far_count >= 0 else inst, 0, inst)
	host._active_instance_count_valid = false
	# [viewport-budget 2026-11-03] chunk 计数被重建 → 视口优先分配必须重算，
	# 否则这里写回的均匀 LOD 前缀会盖掉加权结果。
	host.invalidate_viewport_budget_cache()
	mm.visible_instance_count = host._lod_visible_count(inst, int(host._chunk_far_instance_counts[chunk_id]))
	node.visible = not host._family_batch_suppressed and host.detail_chunk_is_render_visible(chunk_id) \
		and host._profile().enabled and not host._camera_lod_hidden and mm.visible_instance_count > 0
	host._sync_chunk_wrap_nodes(chunk_id)
	return mm



static func _apply_chunk_payload(host, 
		chunk_id: int,
		buffer: PackedFloat32Array,
		src_indices: Array,
		cell_indices: PackedInt32Array,
		inst: int) -> void:

	var lod_order = _lod_order_sources(host, src_indices, cell_indices, buffer)
	var ordered_sources: Array = lod_order.get("order", [])
	inst = mini(inst, ordered_sources.size())
	var far_count = mini(int(lod_order.get("far_count", inst)), inst)
	var mm = _prepare_chunk_multimesh(host, chunk_id, inst, far_count)
	if inst > 0:
		var chunk_buffer = PackedFloat32Array()
		chunk_buffer.resize(inst * 16)
		var ordered_cells = PackedInt32Array()
		ordered_cells.resize(inst)
		for dst in range(inst):
			var src = int(ordered_sources[dst])
			var src_b = src * 16
			var dst_b = dst * 16
			for k in range(16):
				chunk_buffer[dst_b + k] = buffer[src_b + k]
			ordered_cells[dst] = int(cell_indices[src])
		mm.buffer = chunk_buffer
		_cache_chunk_cell_payloads(host, chunk_id, chunk_buffer, ordered_cells, inst)
		host._mirror_shadow_chunk(chunk_id, chunk_buffer, inst)
	else:
		mm.buffer = PackedFloat32Array()
		host._chunk_cell_payloads[chunk_id] = {}
		host._chunk_assembled_payloads.erase(chunk_id)
		host._mirror_shadow_chunk(chunk_id, PackedFloat32Array(), 0)



static func _apply_chunk_payload_direct(host, 
		chunk_id: int,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int,
		native_far_count: int = -1,
		cache_already_updated: bool = false) -> void:

	var far_count = mini(native_far_count, inst)
	if native_far_count < 0:
		# 旧 DLL（无 lod_ordered）：GDScript 复刻排序兜底，与原生序同一语义契约。
		var src_indices: Array = []
		for i in range(inst):
			src_indices.append(i)
		var lod_order = _lod_order_sources(host, src_indices, cell_indices, buffer)
		var ordered_sources: Array = lod_order.get("order", [])
		inst = mini(inst, ordered_sources.size())
		far_count = mini(int(lod_order.get("far_count", inst)), inst)
		if inst > 0:
			var ordered_buffer = PackedFloat32Array()
			ordered_buffer.resize(inst * 16)
			var ordered_cell_indices = PackedInt32Array()
			ordered_cell_indices.resize(inst)
			for dst in range(inst):
				var src = int(ordered_sources[dst])
				for k in range(16):
					ordered_buffer[dst * 16 + k] = buffer[src * 16 + k]
				ordered_cell_indices[dst] = int(cell_indices[src])
			buffer = ordered_buffer
			cell_indices = ordered_cell_indices
	if host._family_batch_suppressed:
		host._chunk_instance_counts[chunk_id] = inst
		host._chunk_far_instance_counts[chunk_id] = clampi(far_count, 0, inst)
		host._active_instance_count_valid = false
		if not cache_already_updated:
			_cache_chunk_cell_payloads(host, chunk_id, buffer, cell_indices, inst)
		host._chunk_assembled_payloads[chunk_id] = {
			"buffer": buffer,
			"cell_indices": cell_indices,
			"instance_count": inst,
			"far_count": far_count,
		}
		return
	var mm = _prepare_chunk_multimesh(host, chunk_id, inst, far_count)
	if inst > 0:
		mm.buffer = buffer
		if not cache_already_updated:
			_cache_chunk_cell_payloads(host, chunk_id, buffer, cell_indices, inst)
		host._mirror_shadow_chunk(chunk_id, buffer, inst)
	else:
		mm.buffer = PackedFloat32Array()
		host._chunk_cell_payloads[chunk_id] = {}
		host._chunk_assembled_payloads.erase(chunk_id)
		host._mirror_shadow_chunk(chunk_id, PackedFloat32Array(), 0)



static func _cache_chunk_cell_payloads(host, 
		chunk_id: int,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> void:

	var by_cell: Dictionary = {}
	var safe_count = mini(inst, mini(cell_indices.size(), int(buffer.size() / 16)))
	var run_start = 0
	while run_start < safe_count:
		var cell_idx = int(cell_indices[run_start])
		var run_end = run_start + 1
		while run_end < safe_count and int(cell_indices[run_end]) == cell_idx:
			run_end += 1
		var cell_buffer: PackedFloat32Array = by_cell.get(cell_idx, PackedFloat32Array())
		cell_buffer.append_array(buffer.slice(run_start * 16, run_end * 16))
		by_cell[cell_idx] = cell_buffer
		run_start = run_end
	host._chunk_cell_payloads[chunk_id] = by_cell
	host._chunk_assembled_payloads[chunk_id] = {
		"buffer": buffer,
		"cell_indices": cell_indices,
		"instance_count": safe_count,
		"far_count": int(host._chunk_far_instance_counts.get(chunk_id, safe_count)),
	}



static func _replace_chunk_cell_payloads(host, 
		chunk_id: int,
		dirty_indices: PackedInt32Array,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> Dictionary:

	var cache_t0_us = Time.get_ticks_usec()
	# 该缓存只由主线程的本 layer 持有；原地替换脏 cell 即可。旧实现 deep-copy
	# 整个 superchunk 的所有 PackedFloat32Array，单格变化也会复制完整 chunk。
	var by_cell: Dictionary = host._chunk_cell_payloads.get(chunk_id, {})
	for raw_idx in dirty_indices:
		by_cell[int(raw_idx)] = PackedFloat32Array()
	var safe_count = mini(inst, mini(cell_indices.size(), int(buffer.size() / 16)))
	var run_start = 0
	while run_start < safe_count:
		var cell_idx = int(cell_indices[run_start])
		var run_end = run_start + 1
		while run_end < safe_count and int(cell_indices[run_end]) == cell_idx:
			run_end += 1
		var cell_buffer: PackedFloat32Array = by_cell.get(cell_idx, PackedFloat32Array())
		cell_buffer.append_array(buffer.slice(run_start * 16, run_end * 16))
		by_cell[cell_idx] = cell_buffer
		run_start = run_end
	host._chunk_cell_payloads[chunk_id] = by_cell
	host._last_cache_update_ms = float(Time.get_ticks_usec() - cache_t0_us) / 1000.0
	var assembled = _assemble_chunk_cell_payloads(host, by_cell)
	host._chunk_assembled_payloads[chunk_id] = assembled
	return assembled



static func _assemble_chunk_cell_payloads(host, by_cell: Dictionary) -> Dictionary:

	var assemble_t0_us = Time.get_ticks_usec()
	var ordered_cells: Array = by_cell.keys()
	ordered_cells.sort()
	var clusters_by_cell: Dictionary = {}
	var far_clusters_by_cell: Dictionary = {}
	var max_far_clusters = 0
	var max_near_clusters = 0
	var total_instances = 0
	var multiplier = maxf(host._resolved_lod_near_density_multiplier(), 1.0)
	for raw_idx in ordered_cells:
		var cell_buffer: PackedFloat32Array = by_cell[raw_idx]
		var cell_count = int(cell_buffer.size() / 16)
		total_instances += cell_count
		var clusters = PackedInt32Array()
		var cluster_start = 0
		while cluster_start < cell_count:
			var seed = cell_buffer[cluster_start * 16 + 14]
			var cluster_end = cluster_start + 1
			while cluster_end < cell_count \
					and absf(cell_buffer[cluster_end * 16 + 14] - seed) <= 0.000001:
				cluster_end += 1
			clusters.append(cluster_start)
			clusters.append(cluster_end - cluster_start)
			cluster_start = cluster_end
		clusters_by_cell[raw_idx] = clusters
		var cluster_count = int(clusters.size() / 2)
		var far_clusters = mini(
			cluster_count, maxi(1, int(ceil(float(cluster_count) / multiplier)))) \
			if cluster_count > 0 else 0
		far_clusters_by_cell[raw_idx] = far_clusters
		max_far_clusters = maxi(max_far_clusters, far_clusters)
		max_near_clusters = maxi(max_near_clusters, cluster_count - far_clusters)

	# 一次性分配最终 buffer，并直接生成 cell-stratified LOD 前缀；避免随后再
	# sort/copy 全 chunk，也避免每追加一株就 resize PackedArray。
	var merged = PackedFloat32Array()
	var merged_cell_indices = PackedInt32Array()
	var write_instance = 0
	for rank in range(max_far_clusters):
		for raw_idx in ordered_cells:
			var cell_idx = int(raw_idx)
			var cell_buffer: PackedFloat32Array = by_cell[raw_idx]
			var far_clusters = int(far_clusters_by_cell.get(raw_idx, 0))
			if rank >= far_clusters:
				continue
			var clusters: PackedInt32Array = clusters_by_cell[raw_idx]
			var start = int(clusters[rank * 2])
			var count = int(clusters[rank * 2 + 1])
			merged.append_array(cell_buffer.slice(start * 16, (start + count) * 16))
			for _local_instance in range(count):
				merged_cell_indices.append(cell_idx)
			write_instance += count
	var far_instance_count = write_instance
	for rank in range(max_near_clusters):
		for raw_idx in ordered_cells:
			var cell_idx = int(raw_idx)
			var clusters: PackedInt32Array = clusters_by_cell[raw_idx]
			var cluster_idx = int(far_clusters_by_cell.get(raw_idx, 0)) + rank
			if cluster_idx >= int(clusters.size() / 2):
				continue
			var cell_buffer: PackedFloat32Array = by_cell[raw_idx]
			var start = int(clusters[cluster_idx * 2])
			var count = int(clusters[cluster_idx * 2 + 1])
			merged.append_array(cell_buffer.slice(start * 16, (start + count) * 16))
			for _local_instance in range(count):
				merged_cell_indices.append(cell_idx)
			write_instance += count
	host._last_assemble_ms = float(Time.get_ticks_usec() - assemble_t0_us) / 1000.0
	return {
		"buffer": merged,
		"cell_indices": merged_cell_indices,
		"instance_count": write_instance,
		"far_count": far_instance_count,
	}



static func _apply_chunked_native_full(host, buffer: PackedFloat32Array, cell_indices: PackedInt32Array, inst: int, cooperative: bool = false) -> void:

	var slice_start = Time.get_ticks_usec()
	host._clear_chunk_nodes()
	host._mmi.multimesh = null
	host._multimesh = null
	host._sync_single_wrap_nodes()
	var by_chunk = {}
	for i in range(inst):
		if cooperative and Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await host.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
		var chunk_id = host._chunk_id_for_cell_idx(int(cell_indices[i]))
		if chunk_id < 0:
			continue
		var srcs: Array = by_chunk.get(chunk_id, [])
		srcs.append(i)
		by_chunk[chunk_id] = srcs
	for chunk_id in by_chunk.keys():
		if cooperative and Time.get_ticks_usec()-slice_start >= UITokens.LOADING_MAIN_SLICE_USEC:
			await host.get_tree().process_frame
			slice_start = Time.get_ticks_usec()
		var src_indices: Array = by_chunk[chunk_id]
		_apply_chunk_payload(host, int(chunk_id), buffer, src_indices, cell_indices, src_indices.size())
	_refresh_instance_totals_from_chunks(host)
	host._last_dirty_chunks = by_chunk.size()


static func _refresh_instance_totals_from_chunks(host) -> void:

	host._instance_count = 0
	host._far_instance_count = 0
	for chunk_id in host._chunk_instance_counts.keys():
		host._instance_count += int(host._chunk_instance_counts[chunk_id])
		host._far_instance_count += int(host._chunk_far_instance_counts.get(chunk_id, host._chunk_instance_counts[chunk_id]))
	host._active_instance_count_valid = false



static func detail_chunk_plan_for_indices(host, indices: PackedInt32Array) -> Array:

	var dirty_chunks = {}
	for raw_idx in indices:
		var chunk_id = host._chunk_id_for_cell_idx(int(raw_idx))
		if chunk_id < 0:
			continue
		var dirty_indices: PackedInt32Array = dirty_chunks.get(chunk_id, PackedInt32Array())
		dirty_indices.append(int(raw_idx))
		dirty_chunks[chunk_id] = dirty_indices
	var keys: Array = dirty_chunks.keys()
	keys.sort()
	var out: Array = []
	for chunk_id in keys:
		var dirty_indices: PackedInt32Array = dirty_chunks[chunk_id]
		out.append({
			"chunk_id": int(chunk_id),
			"cell_indices": host._cell_indices_for_chunk(int(chunk_id)),
			"dirty_indices": dirty_indices,
			"dirty_cells": dirty_indices.size(),
		})
	return out



static func refresh_chunk_for_succession(host, 
		chunk_id: int,
		chunk_cells: PackedInt32Array,
		dirty_cell_count: int = 0,
		dirty_indices: PackedInt32Array = PackedInt32Array()) -> bool:

	if host._map == null or chunk_id < 0:
		return false
	if chunk_cells.is_empty():
		chunk_cells = host._cell_indices_for_chunk(chunk_id)
	var t0_us = Time.get_ticks_usec()
	var has_resident_cache = host._chunk_cell_payloads.has(chunk_id)
	var sample_indices = dirty_indices if has_resident_cache and not dirty_indices.is_empty() else chunk_cells
	var payload = _encode_native_payload_for_indices(host, sample_indices, 0)
	if not bool(payload.get("ok", false)):
		payload = _encode_gdscript_payload_for_indices(host, sample_indices)
		if not bool(payload.get("ok", false)):
			host._last_rebuild_reason = str(payload.get("reason", "chunk_fallback_failed"))
			return false
	var res: Dictionary = payload.get("res", {})
	var inst = int(res.get("instance_count", 0))
	var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
	var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
	var cache_already_updated = false
	var assembled_far_count = -1
	if inst > 0 and (buffer.size() < inst * 16 or cell_indices.size() < inst):
		host._last_rebuild_reason = "chunk_native_bad_payload"
		return false
	if has_resident_cache and sample_indices.size() < chunk_cells.size():
		var assembled = _replace_chunk_cell_payloads(host, 
			chunk_id, sample_indices, buffer, cell_indices, inst)
		buffer = assembled.get("buffer", PackedFloat32Array())
		cell_indices = assembled.get("cell_indices", PackedInt32Array())
		inst = int(assembled.get("instance_count", 0))
		assembled_far_count = int(assembled.get("far_count", -1))
		cache_already_updated = true
	var apply_t0_us = Time.get_ticks_usec()
	var native_far = assembled_far_count if cache_already_updated else (
		int(res.get("far_count", -1)) if bool(res.get("lod_ordered", false)) else -1)
	_apply_chunk_payload_direct(host, 
		chunk_id, buffer, cell_indices, inst, native_far, cache_already_updated)
	host._last_native_apply_ms = float(Time.get_ticks_usec() - apply_t0_us) / 1000.0
	_refresh_instance_totals_from_chunks(host)
	host._last_scatter_path = str(payload.get("path", "gdext_event_cells"))
	host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	host._last_candidate_count = int(res.get("candidate_count", 0))
	host._last_wrap_edge_copy_count = int(res.get("wrap_edge_copy_count", 0))
	host._last_native_sampled_cells = int(res.get("sampled_cell_count", sample_indices.size()))
	host._last_native_active_cells = int(res.get("active_cell_count", 0))
	host._last_rebuild_reason = "chunked_event_update"
	host._last_incremental_cells = dirty_cell_count if dirty_cell_count > 0 else sample_indices.size()
	host._last_dirty_chunks = 1
	host.visible = host._profile().enabled and not host._camera_lod_hidden and host._instance_count > 0
	# 分块：shadow chunk 已在 _apply_chunk_payload_direct 内镜像（O(该chunk)）
	return true



static func _encode_native_payload_for_indices(host, indices: PackedInt32Array, instance_cap: int = 0) -> Dictionary:

	var t0_us = Time.get_ticks_usec()
	var out = {"ok": false, "valid_indices": PackedInt32Array(), "res": {}}
	if host._world_ext == null or (false \
			and false):
		out["reason"] = "missing_detail_scatter_cell_encoder"
		return out
	if host._map == null:
		out["reason"] = "map_null"
		return out
	if host._native_delta_common_knobs.is_empty():
		host._native_delta_common_knobs = _build_native_delta_common_knobs(host, )
	if host._native_delta_common_knobs.is_empty():
		out["reason"] = "bad_native_common_knobs"
		return out
	var knobs = host._native_delta_common_knobs.duplicate(false)
	knobs["sample_cell_indices"] = indices
	knobs["instance_cap"] = instance_cap
	knobs["family"] = host.detail_render_family()
	knobs["style_id"] = host._family_style_id
	host._last_native_knobs_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	var native_t0_us = Time.get_ticks_usec()
	var res
	var native_path = "gdext_event_cells"
	var family_res = host._world_ext.call("encode_detail_scatter_family_cells", {
		"requests": [knobs],
	})
	if family_res is Dictionary:
		var payloads: Array = family_res.get("payloads", [])
		if not payloads.is_empty():
			res = payloads[0]
			native_path = "gdext_family_cells"
	if res == null:
		res = host._world_ext.call("encode_detail_scatter_delta", knobs)
	host._last_native_call_ms = float(Time.get_ticks_usec() - native_t0_us) / 1000.0
	if not (res is Dictionary):
		out["reason"] = "bad_native_result"
		return out
	if bool(res.get("fallback", true)):
		out["reason"] = str(res.get("reason", "native_delta_fallback"))
		out["res"] = res
		return out
	out["ok"] = true
	out["path"] = native_path
	out["valid_indices"] = res.get("valid_indices", indices)
	out["res"] = res
	return out



static func _encode_gdscript_payload_for_indices(host, indices: PackedInt32Array) -> Dictionary:

	var transforms: Array = []
	var colors: Array = []
	var customs: Array = []
	var cell_indices = PackedInt32Array()
	for raw_idx in indices:
		var cell_idx = int(raw_idx)
		var cell = host._map.cell_at(cell_idx) if host._map != null else null
		if cell == null:
			continue
		var payload = _generate_cell_instance_payload(host, cell, cell_idx)
		var cell_transforms: Array = payload.get("transforms", [])
		var cell_colors: Array = payload.get("colors", [])
		var cell_customs: Array = payload.get("customs", [])
		var count = mini(cell_transforms.size(), mini(cell_colors.size(), cell_customs.size()))
		for i in range(count):
			transforms.append(cell_transforms[i])
			colors.append(cell_colors[i])
			customs.append(cell_customs[i])
			cell_indices.append(cell_idx)
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform_2d(i, transforms[i])
		mm.set_instance_color(i, colors[i])
		mm.set_instance_custom_data(i, customs[i])
	return {
		"ok": true,
		"path": "gdscript_event_cells",
		"res": {
			"fallback": false,
			"instance_count": transforms.size(),
			"buffer": mm.buffer,
			"cell_indices": cell_indices,
			"sampled_cell_count": indices.size(),
			"active_cell_count": cell_indices.size(),
		},
	}



static func _refresh_chunked_for_succession(host, indices: PackedInt32Array) -> bool:

	if host._map == null or indices.is_empty():
		return false
	var dirty_chunks = {}
	for raw_idx in indices:
		var chunk_id = host._chunk_id_for_cell_idx(int(raw_idx))
		if chunk_id >= 0:
			dirty_chunks[chunk_id] = true
	if dirty_chunks.is_empty():
		return false
	var t0_us = Time.get_ticks_usec()
	var chunk_count = 0
	var total_inst = 0
	var total_candidates = 0
	var total_wrap = 0
	var total_sampled = 0
	var total_active = 0
	for chunk_id in dirty_chunks.keys():
		var chunk_cells = host._cell_indices_for_chunk(int(chunk_id))
		var payload = _encode_native_payload_for_indices(host, chunk_cells, 0)
		if not bool(payload.get("ok", false)):
			host._last_rebuild_reason = str(payload.get("reason", "chunk_native_failed"))
			return false
		var res: Dictionary = payload.get("res", {})
		var inst = int(res.get("instance_count", 0))
		var buffer: PackedFloat32Array = res.get("buffer", PackedFloat32Array())
		var cell_indices: PackedInt32Array = res.get("cell_indices", PackedInt32Array())
		if inst > 0 and (buffer.size() < inst * 16 or cell_indices.size() < inst):
			host._last_rebuild_reason = "chunk_native_bad_payload"
			return false
		var native_far = int(res.get("far_count", -1)) if bool(res.get("lod_ordered", false)) else -1
		_apply_chunk_payload_direct(host, int(chunk_id), buffer, cell_indices, inst, native_far)
		total_inst += inst
		total_candidates += int(res.get("candidate_count", 0))
		total_wrap += int(res.get("wrap_edge_copy_count", 0))
		total_sampled += int(res.get("sampled_cell_count", chunk_cells.size()))
		total_active += int(res.get("active_cell_count", 0))
		chunk_count += 1
	_refresh_instance_totals_from_chunks(host)
	host._last_scatter_path = "gdext_event_chunk"
	host._last_rebuild_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0
	host._last_candidate_count = total_candidates
	host._last_wrap_edge_copy_count = total_wrap
	host._last_native_sampled_cells = total_sampled
	host._last_native_active_cells = total_active
	host._last_rebuild_reason = "chunked_event_update"
	host._last_incremental_cells = indices.size()
	host._last_dirty_chunks = chunk_count
	host.visible = host._profile().enabled and not host._camera_lod_hidden and host._instance_count > 0
	# 分块：各脏 chunk 的 shadow 已在 _apply_chunk_payload 内镜像（O(脏chunk)）
	return true



