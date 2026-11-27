extends RefCounted

const ChunkPayloads = preload("res://scripts/rendering/shrub/chunk_payloads.gd")

const FogDrawBounds = preload("res://scripts/rendering/fog_draw_bounds.gd")

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
	return ChunkPayloads._build_native_delta_common_knobs(host)


static func _ensure_incremental_multimesh(host) -> void:

	host._ensure_resources()
	if host._multimesh != null:
		return
	host._multimesh = MultiMesh.new()
	host._multimesh.transform_format = MultiMesh.TRANSFORM_2D
	host._multimesh.use_colors = true
	host._multimesh.use_custom_data = true
	host._multimesh.mesh = host.ShrubScatter._cached_detail_mesh(host)
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

	var state = host.ShrubScatter._sample_cell_state(host, idx, cell)
	var key = host.ShrubScatter._cell_hash_key(host, cell, idx)
	var suitability = host.ShrubScatter._cell_suitability(host, cell, idx, key, state)
	var transforms: Array = []
	var colors: Array = []
	var customs: Array = []
	if suitability <= 0.0:
		return {"transforms": transforms, "colors": colors, "customs": customs}
	var quota = host.ShrubScatter._cell_quota(host, suitability, maxi(1, host.ShrubScatter._max_per_cell(host)))
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
		host.ShrubScatter._try_append_instance(host, cell, idx, key, attempt, suitability, accept_p, state)
	for i in range(host._instance_cell_indices.size()):
		var inst_idx = int(host._instance_cell_indices[i])
		var inst_cell = host._instance_cells[i]
		var inst_state = host.ShrubScatter._sample_cell_state(host, inst_idx, inst_cell)
		transforms.append(host.ShrubScatter._instance_transform(host, i))
		colors.append(host.ShrubScatter._base_color_for_state(host, inst_state, host._instance_variants[i]))
		var uv = host.Diagnostics._world_uv(host, host._instance_positions[i])
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
	if host._chunked_multimesh_enabled and _refresh_chunked_for_succession(host, indices):
		return  # 分块：shadow chunk 已在 _apply_chunk_payload 内逐 chunk 镜像（O(脏chunk)）
	_ensure_incremental_multimesh(host)
	if host._multimesh == null:
		return
	if _refresh_for_succession_native(host, indices):
		host.Chunk_nodes._sync_single_shadow(host)
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
		var payload: Dictionary = _generate_cell_instance_payload(host, cell, idx)
		var transforms: Array = payload.get("transforms", [])
		var colors: Array = payload.get("colors", [])
		var customs: Array = payload.get("customs", [])
		var next_count := transforms.size()
		generated += next_count
		var slots: Array = host._cell_instance_lookup.get(idx, [])
		if slots.size() < next_count:
			var new_slots: Array = _append_instance_slots(host, idx, next_count - slots.size())
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
	host.Chunk_nodes._sync_single_shadow(host)



static func _refresh_for_succession_native(host, indices: PackedInt32Array) -> bool:

	if host._map == null or host._multimesh == null:
		return false
	var t0_us := Time.get_ticks_usec()
	var payload: Dictionary = _encode_native_payload_for_indices(host, indices, 0)
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
			var new_slots: Array = _append_instance_slots(host, idx, src_indices.size() - slots.size())
			for slot in new_slots:
				slots.append(slot)
			host._cell_instance_lookup[idx] = slots
		var write_count := mini(slots.size(), src_indices.size())
		for j in range(write_count):
			_set_slot_from_native_buffer(host, int(slots[j]), buffer, int(src_indices[j]))
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
	host.Chunk_nodes._sync_single_shadow(host)



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
	return ChunkPayloads._prepare_chunk_multimesh(host, chunk_id, inst, far_count)


static func _apply_chunk_payload(host, 
		chunk_id: int,
		buffer: PackedFloat32Array,
		src_indices: Array,
		cell_indices: PackedInt32Array,
		inst: int) -> void:
	ChunkPayloads._apply_chunk_payload(host, chunk_id, buffer, src_indices, cell_indices, inst)


static func _apply_chunk_payload_direct(host, 
		chunk_id: int,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int,
		native_far_count: int = -1,
		cache_already_updated: bool = false) -> void:
	ChunkPayloads._apply_chunk_payload_direct(host, chunk_id, buffer, cell_indices, inst, native_far_count, cache_already_updated)


static func _cache_chunk_cell_payloads(host, 
		chunk_id: int,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> void:
	ChunkPayloads._cache_chunk_cell_payloads(host, chunk_id, buffer, cell_indices, inst)


static func _replace_chunk_cell_payloads(host, 
		chunk_id: int,
		dirty_indices: PackedInt32Array,
		buffer: PackedFloat32Array,
		cell_indices: PackedInt32Array,
		inst: int) -> Dictionary:
	return ChunkPayloads._replace_chunk_cell_payloads(host, chunk_id, dirty_indices, buffer, cell_indices, inst)


static func _assemble_chunk_cell_payloads(host, by_cell: Dictionary) -> Dictionary:
	return ChunkPayloads._assemble_chunk_cell_payloads(host, by_cell)


static func _apply_chunked_native_full(host, buffer: PackedFloat32Array, cell_indices: PackedInt32Array, inst: int, cooperative: bool = false) -> void:
	await ChunkPayloads._apply_chunked_native_full(host, buffer, cell_indices, inst, cooperative)


static func _refresh_instance_totals_from_chunks(host) -> void:
	ChunkPayloads._refresh_instance_totals_from_chunks(host)


static func detail_chunk_plan_for_indices(host, indices: PackedInt32Array) -> Array:

	var dirty_chunks = {}
	for raw_idx in indices:
		var chunk_id = host.Chunk_nodes._chunk_id_for_cell_idx(host, int(raw_idx))
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
			"cell_indices": host.Chunk_nodes._cell_indices_for_chunk(host, int(chunk_id)),
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
		chunk_cells = host.Chunk_nodes._cell_indices_for_chunk(host, chunk_id)
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
	mm.mesh = host.ShrubScatter._cached_detail_mesh(host)
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
		var chunk_id = host.Chunk_nodes._chunk_id_for_cell_idx(host, int(raw_idx))
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
		var chunk_cells = host.Chunk_nodes._cell_indices_for_chunk(host, int(chunk_id))
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
