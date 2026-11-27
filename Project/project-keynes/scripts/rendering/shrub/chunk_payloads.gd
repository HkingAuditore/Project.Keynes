extends RefCounted

## Builds, caches, and uploads vegetation chunk instance payloads.

const FogDrawBounds = preload("res://scripts/rendering/fog_draw_bounds.gd")


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
		"max_per_cell": host.ShrubScatter._max_per_cell(host),
		"quality_density_scale": host.ShrubScatter._quality_density_scale(host),
		"river_clear_threshold": cfg.river_clear_threshold,
		"river_edge_density": cfg.river_edge_density,
		"river_valley_boost": cfg.river_valley_boost,
		"biomass_floor": cfg.biomass_floor,
		"biomass_ceil": cfg.biomass_ceil,
		"biomass_exponent": cfg.biomass_exponent,
		"spawn_domain": host.ShrubScatter._spawn_domain(host),
		"rotation_mode": host.ShrubScatter._rotation_mode(host),
		"random_rotation_strength": host.ShrubScatter._random_rotation_strength(host),
		"upright_jitter_radians": deg_to_rad(host.ShrubScatter._upright_jitter_degrees(host)),
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



static func _prepare_chunk_multimesh(host, chunk_id: int, inst: int, far_count: int = -1) -> MultiMesh:

	var node = host.Chunk_nodes._ensure_chunk_node(host, chunk_id)
	var mm = node.multimesh
	if mm == null:
		mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		node.multimesh = mm
	mm.mesh = host.ShrubScatter._cached_detail_mesh(host)
	mm.instance_count = inst
	host._chunk_instance_counts[chunk_id] = inst
	host._chunk_far_instance_counts[chunk_id] = clampi(far_count if far_count >= 0 else inst, 0, inst)
	host._active_instance_count_valid = false
	# [viewport-budget 2026-11-03] chunk 计数被重建 → 视口优先分配必须重算，
	# 否则这里写回的均匀 LOD 前缀会盖掉加权结果。
	host.invalidate_viewport_budget_cache()
	mm.visible_instance_count = host.Chunk_budget._lod_visible_count(host, inst, int(host._chunk_far_instance_counts[chunk_id]))
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

	var lod_order = host._lod_order_sources(src_indices, cell_indices, buffer)
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
		FogDrawBounds.upload(mm, chunk_buffer, FogDrawBounds.Kind.VEGETATION)
		_cache_chunk_cell_payloads(host, chunk_id, chunk_buffer, ordered_cells, inst)
		host.Chunk_nodes._mirror_shadow_chunk(host, chunk_id, chunk_buffer, inst)
	else:
		mm.buffer = PackedFloat32Array()
		host._chunk_cell_payloads[chunk_id] = {}
		host._chunk_assembled_payloads.erase(chunk_id)
		host.Chunk_nodes._mirror_shadow_chunk(host, chunk_id, PackedFloat32Array(), 0)



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
		var lod_order = host._lod_order_sources(src_indices, cell_indices, buffer)
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
		FogDrawBounds.upload(mm, buffer, FogDrawBounds.Kind.VEGETATION)
		if not cache_already_updated:
			_cache_chunk_cell_payloads(host, chunk_id, buffer, cell_indices, inst)
		host.Chunk_nodes._mirror_shadow_chunk(host, chunk_id, buffer, inst)
	else:
		mm.buffer = PackedFloat32Array()
		host._chunk_cell_payloads[chunk_id] = {}
		host._chunk_assembled_payloads.erase(chunk_id)
		host.Chunk_nodes._mirror_shadow_chunk(host, chunk_id, PackedFloat32Array(), 0)



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
		var chunk_id = host.Chunk_nodes._chunk_id_for_cell_idx(host, int(cell_indices[i]))
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
