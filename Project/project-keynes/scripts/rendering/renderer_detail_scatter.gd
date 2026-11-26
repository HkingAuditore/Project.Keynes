extends RefCounted

const DetailBudget = preload("res://scripts/rendering/renderer_detail_budget.gd")

## Stateless collaborator for ShrubLayer.

static func _effective_detail_enqueue_coalesce_ms(host) -> float:

	var base_ms := maxf(0.0, host.detail_scatter_enqueue_coalesce_ms)
	if host._simulation_speed_multiplier >= 20.0:
		return maxf(base_ms, 400.0)
	if host._simulation_speed_multiplier >= 5.0:
		return maxf(base_ms, 250.0)
	return base_ms

static func queue_detail_scatter_refresh(host, indices: PackedInt32Array) -> void:

	var changes = host.DetailScatterChangeSetScript.new()
	for raw_idx in indices:
		changes.append_change(int(raw_idx), host.DetailScatterChangeSetScript.AXIS_UNKNOWN, 0, 0, 0, 0, 0, 0)
	queue_detail_scatter_changes(host, changes)



static func _detail_all_family_mask(host) -> int:

	var mask = 0
	for layer in host._detail_layers:
		if layer != null and is_instance_valid(layer) and layer.has_method("detail_render_family_mask"):
			mask |= int(layer.detail_render_family_mask())
	return mask if mask != 0 else 0x1F



static func _detail_family_mask_for_change(host, changes, row: int) -> int:

	var axis_mask = int(changes.axis_masks[row])
	if (axis_mask & host.DetailScatterChangeSetScript.AXIS_UNKNOWN) != 0:
		return _detail_all_family_mask(host)
	var mask = 0
	for layer in host._detail_layers:
		if layer == null or not is_instance_valid(layer) \
				or not layer.has_method("detail_change_affects_profile"):
			continue
		if bool(layer.detail_change_affects_profile(
				axis_mask,
				int(changes.old_vegetation[row]), int(changes.new_vegetation[row]),
				int(changes.old_landform[row]), int(changes.new_landform[row]),
				int(changes.old_cover[row]), int(changes.new_cover[row])
		)):
			mask |= int(layer.detail_render_family_mask())
	return mask



static func _detail_profile_mask_for_change(host, changes, row: int) -> int:

	var axis_mask = int(changes.axis_masks[row])
	if (axis_mask & host.DetailScatterChangeSetScript.AXIS_UNKNOWN) != 0:
		return (1 << host._detail_layers.size()) - 1
	var mask = 0
	for layer_idx in range(host._detail_layers.size()):
		var layer = host._detail_layers[layer_idx]
		if layer == null or not is_instance_valid(layer) \
				or not layer.has_method("detail_change_affects_profile"):
			continue
		if bool(layer.detail_change_affects_profile(
				axis_mask,
				int(changes.old_vegetation[row]), int(changes.new_vegetation[row]),
				int(changes.old_landform[row]), int(changes.new_landform[row]),
				int(changes.old_cover[row]), int(changes.new_cover[row])
		)):
			mask |= 1 << layer_idx
	return mask



static func queue_detail_scatter_changes(host, changes) -> void:

	if changes == null or host._detail_layers.is_empty() \
			or not changes.has_method("is_well_formed") \
			or not bool(changes.is_well_formed()) or bool(changes.is_empty()):
		return
	var affected_families = 0
	for row in range(changes.cell_indices.size()):
		var ci = int(changes.cell_indices[row])
		if ci < 0:
			continue
		var generation = int(changes.generation)
		var previous_generation = int(host._scatter_cell_generations.get(ci, -1))
		if generation >= 0 and previous_generation > generation:
			host._detail_stale_generation_drops += 1
			continue
		host._scatter_cell_generations[ci] = maxi(previous_generation, generation)
		var family_mask = _detail_family_mask_for_change(host, changes, row)
		var profile_mask = _detail_profile_mask_for_change(host, changes, row)
		if family_mask == 0 or profile_mask == 0:
			continue
		affected_families |= family_mask
		# A layer can receive its first succession change before the camera has
		# published a view. Treat that as offscreen until the view is known; this
		# keeps the change deferred instead of eagerly rebuilding every family.
		if not host._detail_layers.is_empty():
			var probe = host._detail_layers[0]
			if probe != null and is_instance_valid(probe) \
					and probe.has_method("detail_chunk_id_for_cell") \
					and probe.has_method("detail_chunk_is_in_prefetch"):
				var chunk_id = int(probe.detail_chunk_id_for_cell(ci))
				if chunk_id >= 0 and not bool(probe.detail_chunk_is_in_prefetch(chunk_id)):
					host._detail_deferred_chunks[chunk_id] = int(
						host._detail_deferred_chunks.get(chunk_id, 0)) | family_mask
					host._detail_deferred_profile_masks[chunk_id] = int(
						host._detail_deferred_profile_masks.get(chunk_id, 0)) | profile_mask
					host._detail_offscreen_deferred_cells += 1
					continue
		var previous_mask = int(host._scatter_cell_family_masks.get(ci, 0))
		host._scatter_cell_family_masks[ci] = previous_mask | family_mask
		var previous_profile_mask = int(host._scatter_cell_profile_masks.get(ci, 0))
		host._scatter_cell_profile_masks[ci] = previous_profile_mask | profile_mask
		if host._scatter_pending_seen.has(ci):
			host._detail_coalesced_cells += 1
			continue
		if host._scatter_inflight.has(ci):
			# 当前 batch 已经按旧 generation 建好任务；完成后只补跑一次最新状态。
			host._scatter_requeue_cells[ci] = true
			host._scatter_enqueue_dedup_skips += 1
			continue
		host._scatter_pending_seen[ci] = true
		host._scatter_inflight[ci] = true
		host._scatter_pending_cells.append(ci)
	host._detail_affected_family_count = _count_set_bits(host, affected_families)
	var now_msec = Time.get_ticks_msec()
	var window_due = host._scatter_last_enqueue_msec <= 0 or \
		float(now_msec - host._scatter_last_enqueue_msec) >= host._effective_detail_enqueue_coalesce_ms()
	if not window_due and host._scatter_pending_cells.size() < host.detail_scatter_enqueue_max_pending_cells:
		return
	host._scatter_last_enqueue_msec = now_msec
	var flushed = host._scatter_pending_cells
	host._scatter_pending_cells = PackedInt32Array()
	host._scatter_pending_seen.clear()
	if host._detail_refresh_batches.size() >= maxi(2, host.detail_scatter_merge_batch_threshold):
		flushed = _merge_pending_detail_refresh_batches(host, flushed)
	_enqueue_detail_refresh_batches(host, _dedup_detail_refresh_indices(host, flushed))
	if host._detail_refresh_queue.is_empty():
		_start_next_detail_refresh_batch(host)
	host._last_detail_refresh_report = {
		"queued_chunks": host._detail_refresh_queue.size(),
		"queued_layers": host._detail_layers.size(),
		"dirty_cells": host._detail_refresh_indices.size(),
		"pending_batches": host._detail_refresh_batches.size(),
		"chunks_done": 0,
		"layers_done": 0,
		"batch_chunks": int(host._last_detail_refresh_report.get("batch_chunks", 0)),
		"elapsed_ms": 0.0,
	}
	if host.detail_scatter_refresh_log_enabled and PKLog.enabled:
		print("[detail_scatter/QUEUE] succession active_cells=%d pending_batches=%d queued_chunks=%d chunks_per_frame=%d chunk_ms_budget=%.2f cells_per_batch=%d" % [
			host._detail_refresh_indices.size(),
			host._detail_refresh_batches.size(),
			host._detail_refresh_queue.size(),
			maxi(1, host.detail_scatter_refresh_chunks_per_frame),
			maxf(0.0, host.detail_scatter_refresh_apply_budget_ms),
			maxi(1, host.detail_scatter_refresh_cells_per_batch),
		])



static func _count_set_bits(host, value: int) -> int:

	var count = 0
	var bits = value
	while bits != 0:
		count += bits & 1
		bits >>= 1
	return count



static func _dedup_detail_refresh_indices(host, indices: PackedInt32Array) -> PackedInt32Array:

	var seen = {}
	var out = PackedInt32Array()
	for v in indices:
		var idx = int(v)
		if seen.has(idx):
			continue
		seen[idx] = true
		out.append(idx)
	return out



static func _enqueue_detail_refresh_batches(host, indices: PackedInt32Array) -> void:

	if indices.is_empty():
		return
	var batch_size = maxi(1, host.detail_scatter_refresh_cells_per_batch)
	var current = PackedInt32Array()
	for idx in indices:
		current.append(int(idx))
		if current.size() >= batch_size:
			host._detail_refresh_batches.append(current)
			current = PackedInt32Array()
	if not current.is_empty():
		host._detail_refresh_batches.append(current)


# 积压合并：把待处理批次与新单元整体去重后返回一条流，调用方负责重新切批。
# 已在 chunk 队列中的批次不动（本批即将 drain 完）。

static func _merge_pending_detail_refresh_batches(host, extra: PackedInt32Array) -> PackedInt32Array:

	var seen = {}
	var merged = PackedInt32Array()
	for batch in host._detail_refresh_batches:
		for raw in batch:
			var ci = int(raw)
			if seen.has(ci):
				continue
			seen[ci] = true
			merged.append(ci)
	for raw in extra:
		var ci = int(raw)
		if seen.has(ci):
			continue
		seen[ci] = true
		merged.append(ci)
	host._detail_refresh_batches.clear()
	return merged



static func _release_detail_refresh_inflight(host, cells: PackedInt32Array) -> void:

	if host._scatter_inflight.is_empty():
		return
	var requeue = PackedInt32Array()
	for raw in cells:
		var ci = int(raw)
		host._scatter_inflight.erase(ci)
		if host._scatter_requeue_cells.has(ci):
			host._scatter_requeue_cells.erase(ci)
			host._scatter_inflight[ci] = true
			requeue.append(ci)
			continue
		host._scatter_cell_family_masks.erase(ci)
		host._scatter_cell_profile_masks.erase(ci)
	if not requeue.is_empty():
		_enqueue_detail_refresh_batches(host, _dedup_detail_refresh_indices(host, requeue))



static func _reset_detail_refresh_plan(host) -> void:

	host._detail_plan_phase = host.DETAIL_PLAN_IDLE
	host._detail_plan_probe = null
	host._detail_plan_cursor = 0
	host._detail_plan_key_cursor = 0
	host._detail_plan_chunk_cursor = 0
	host._detail_plan_layer_cursor = 0
	host._detail_plan_dirty_chunks.clear()
	host._detail_plan_chunk_keys.clear()
	host._detail_plan_chunks.clear()
	host._detail_plan_had_chunk_plan = false
	host._detail_plan_fallback_profile_mask = 0
	host._detail_plan_all_family_mask = 0
	host._detail_plan_all_profile_mask = 0



static func _begin_detail_refresh_plan(host) -> void:

	host._detail_refresh_indices = host._detail_refresh_batches.pop_front()
	host._detail_refresh_queue.clear()
	_reset_detail_refresh_plan(host)
	host._detail_plan_all_family_mask = _detail_all_family_mask(host)
	host._detail_plan_all_profile_mask = (1 << host._detail_layers.size()) - 1
	if host.detail_scatter_chunked_multimesh_enabled:
		for layer in host._detail_layers:
			if layer != null and is_instance_valid(layer) \
					and layer.has_method("detail_chunk_id_for_cell") \
					and layer.has_method("detail_chunk_cells"):
				host._detail_plan_probe = layer
				break
	host._detail_plan_phase = host.DETAIL_PLAN_COLLECT \
		if host._detail_plan_probe != null else host.DETAIL_PLAN_FALLBACK_COLLECT



static func _detail_plan_should_yield(host, deadline_usec: int, items_done: int, max_items: int) -> bool:

	if max_items > 0 and items_done >= max_items:
		return true
	return deadline_usec > 0 and items_done > 0 and Time.get_ticks_usec() >= deadline_usec



static func _continue_detail_refresh_plan(host, deadline_usec: int, max_items: int) -> void:

	var items_done = 0
	var enqueued_msec = Time.get_ticks_msec()
	while host._detail_plan_phase != host.DETAIL_PLAN_IDLE:
		match host._detail_plan_phase:
			host.DETAIL_PLAN_COLLECT:
				if host._detail_plan_cursor < host._detail_refresh_indices.size():
					var cell_idx = int(host._detail_refresh_indices[host._detail_plan_cursor])
					host._detail_plan_cursor += 1
					var chunk_id = int(host._detail_plan_probe.detail_chunk_id_for_cell(cell_idx))
					if chunk_id >= 0:
						var dirty_indices: PackedInt32Array = host._detail_plan_dirty_chunks.get(
							chunk_id, PackedInt32Array())
						dirty_indices.append(cell_idx)
						host._detail_plan_dirty_chunks[chunk_id] = dirty_indices
					items_done += 1
					if _detail_plan_should_yield(host, deadline_usec, items_done, max_items):
						return
					continue
				host._detail_plan_chunk_keys = host._detail_plan_dirty_chunks.keys()
				host._detail_plan_chunk_keys.sort()
				host._detail_plan_had_chunk_plan = not host._detail_plan_chunk_keys.is_empty()
				host._detail_plan_phase = host.DETAIL_PLAN_BUILD_CHUNKS \
					if host._detail_plan_had_chunk_plan else host.DETAIL_PLAN_FALLBACK_COLLECT
				host._detail_plan_cursor = 0

			host.DETAIL_PLAN_BUILD_CHUNKS:
				if host._detail_plan_key_cursor < host._detail_plan_chunk_keys.size():
					var chunk_id = int(host._detail_plan_chunk_keys[host._detail_plan_key_cursor])
					host._detail_plan_key_cursor += 1
					var dirty_indices: PackedInt32Array = host._detail_plan_dirty_chunks[chunk_id]
					var family_mask = 0
					var profile_mask = 0
					for raw_idx in dirty_indices:
						family_mask |= int(host._scatter_cell_family_masks.get(
							int(raw_idx), host._detail_plan_all_family_mask))
						profile_mask |= int(host._scatter_cell_profile_masks.get(
							int(raw_idx), host._detail_plan_all_profile_mask))
					if family_mask == 0:
						family_mask = host._detail_plan_all_family_mask
					if profile_mask == 0:
						profile_mask = host._detail_plan_all_profile_mask
					var in_prefetch = true
					if host._detail_plan_probe.has_method("detail_chunk_is_in_prefetch"):
						in_prefetch = bool(host._detail_plan_probe.detail_chunk_is_in_prefetch(chunk_id))
					if not in_prefetch:
						host._detail_deferred_chunks[chunk_id] = int(
							host._detail_deferred_chunks.get(chunk_id, 0)) | family_mask
						host._detail_deferred_profile_masks[chunk_id] = int(
							host._detail_deferred_profile_masks.get(chunk_id, 0)) | profile_mask
						host._detail_offscreen_deferred_cells += dirty_indices.size()
					else:
						var cell_indices: PackedInt32Array = host._detail_plan_probe.detail_chunk_cells(chunk_id)
						var visible = bool(host._detail_plan_probe.detail_chunk_is_render_visible(chunk_id)) \
							if host._detail_plan_probe.has_method("detail_chunk_is_render_visible") else true
						host._detail_plan_chunks.append({
							"chunk_id": chunk_id,
							"cell_indices": cell_indices,
							"dirty_indices": dirty_indices,
							"dirty_cells": dirty_indices.size(),
							"family_mask": family_mask,
							"profile_mask": profile_mask,
							"visible_priority": visible,
							"distance_sq": host._detail_chunk_center_from_cells(
								cell_indices).distance_squared_to(host._camera_world_center),
						})
					items_done += 1
					if _detail_plan_should_yield(host, deadline_usec, items_done, max_items):
						return
					continue
				host._detail_plan_chunks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
					var a_visible = bool(a.get("visible_priority", true))
					var b_visible = bool(b.get("visible_priority", true))
					if a_visible != b_visible:
						return a_visible
					return float(a.get("distance_sq", 0.0)) < float(b.get("distance_sq", 0.0))
				)
				host._detail_plan_phase = host.DETAIL_PLAN_BEGIN_LAYERS
				host._detail_plan_layer_cursor = 0

			host.DETAIL_PLAN_BEGIN_LAYERS:
				if host._detail_plan_layer_cursor < host._detail_layers.size():
					var layer = host._detail_layers[host._detail_plan_layer_cursor]
					host._detail_plan_layer_cursor += 1
					if layer != null and is_instance_valid(layer) \
							and layer.has_method("begin_detail_chunk_refresh"):
						layer.begin_detail_chunk_refresh()
					items_done += 1
					if _detail_plan_should_yield(host, deadline_usec, items_done, max_items):
						return
					continue
				host._detail_plan_phase = host.DETAIL_PLAN_BUILD_TASKS
				host._detail_plan_chunk_cursor = 0
				host._detail_plan_layer_cursor = 0

			host.DETAIL_PLAN_BUILD_TASKS:
				if host._detail_plan_chunk_cursor >= host._detail_plan_chunks.size():
					host._detail_plan_phase = host.DETAIL_PLAN_FINALIZE
					continue
				var chunk: Dictionary = host._detail_plan_chunks[host._detail_plan_chunk_cursor]
				if host._detail_plan_layer_cursor >= host._detail_layers.size():
					host._detail_plan_chunk_cursor += 1
					host._detail_plan_layer_cursor = 0
					continue
				var layer_idx = host._detail_plan_layer_cursor
				host._detail_plan_layer_cursor += 1
				var profile_mask = int(chunk.get("profile_mask", host._detail_plan_all_profile_mask))
				if (profile_mask & (1 << layer_idx)) != 0:
					var layer = host._detail_layers[layer_idx]
					if layer != null and is_instance_valid(layer) \
							and layer.has_method("refresh_chunk_for_succession"):
						host._detail_refresh_queue.append({
							"layer": layer,
							"chunk_id": int(chunk.get("chunk_id", -1)),
							"cell_indices": chunk.get("cell_indices", PackedInt32Array()),
							"dirty_indices": chunk.get("dirty_indices", PackedInt32Array()),
							"dirty_cells": int(chunk.get("dirty_cells", 0)),
							"family_mask": int(chunk.get(
								"family_mask", host._detail_plan_all_family_mask)),
							"family": int(layer.detail_render_family()) \
								if layer.has_method("detail_render_family") else 0,
							"profile_index": layer_idx,
							"enqueued_msec": enqueued_msec,
							"visible_priority": bool(chunk.get("visible_priority", true)),
						})
				items_done += 1
				if _detail_plan_should_yield(host, deadline_usec, items_done, max_items):
					return

			host.DETAIL_PLAN_FALLBACK_COLLECT:
				if host._detail_plan_cursor < host._detail_refresh_indices.size():
					var cell_idx = int(host._detail_refresh_indices[host._detail_plan_cursor])
					host._detail_plan_cursor += 1
					host._detail_plan_fallback_profile_mask |= int(host._scatter_cell_profile_masks.get(
						cell_idx, host._detail_plan_all_profile_mask))
					items_done += 1
					if _detail_plan_should_yield(host, deadline_usec, items_done, max_items):
						return
					continue
				if host._detail_plan_fallback_profile_mask == 0:
					host._detail_plan_fallback_profile_mask = host._detail_plan_all_profile_mask
				host._detail_plan_layer_cursor = 0
				host._detail_plan_phase = host.DETAIL_PLAN_FALLBACK_TASKS

			host.DETAIL_PLAN_FALLBACK_TASKS:
				if host._detail_plan_layer_cursor >= host._detail_layers.size():
					host._detail_plan_phase = host.DETAIL_PLAN_FINALIZE
					continue
				var layer_idx = host._detail_plan_layer_cursor
				host._detail_plan_layer_cursor += 1
				if (host._detail_plan_fallback_profile_mask & (1 << layer_idx)) != 0:
					var layer = host._detail_layers[layer_idx]
					if layer != null and is_instance_valid(layer):
						host._detail_refresh_queue.append({
							"layer": layer,
							"profile_index": layer_idx,
							"cell_indices": host._detail_refresh_indices,
							"enqueued_msec": enqueued_msec,
							"visible_priority": true,
						})
				items_done += 1
				if _detail_plan_should_yield(host, deadline_usec, items_done, max_items):
					return

			host.DETAIL_PLAN_FINALIZE:
				var batch_chunk_count = host._detail_plan_chunks.size()
				host._last_detail_refresh_report = {
					"queued_chunks": host._detail_refresh_queue.size(),
					"queued_layers": host._detail_layers.size(),
					"dirty_cells": host._detail_refresh_indices.size(),
					"pending_batches": host._detail_refresh_batches.size(),
					"chunks_done": 0,
					"layers_done": 0,
					"batch_chunks": batch_chunk_count,
					"elapsed_ms": 0.0,
				}
				_reset_detail_refresh_plan(host)
				if host._detail_refresh_queue.is_empty():
					_release_detail_refresh_inflight(host, host._detail_refresh_indices)
					host._detail_refresh_indices = PackedInt32Array()



static func _start_next_detail_refresh_batch(host, 
		deadline_usec: int = 0, max_plan_items: int = 0) -> bool:

	if not host._detail_refresh_queue.is_empty():
		return true
	if host._detail_plan_phase == host.DETAIL_PLAN_IDLE:
		if host._detail_refresh_batches.is_empty():
			_release_detail_refresh_inflight(host, host._detail_refresh_indices)
			host._detail_refresh_indices = PackedInt32Array()
			return false
		_begin_detail_refresh_plan(host)
	# queue_detail_scatter_changes 可在仿真 tick 内调用；零预算调用只初始化状态，
	# 真正规划统一留到 HexRenderer._process 的帧尾预算段。
	if deadline_usec != 0 or max_plan_items > 0:
		_continue_detail_refresh_plan(host, deadline_usec, max_plan_items)
	return not host._detail_refresh_queue.is_empty() \
		or host._detail_plan_phase != host.DETAIL_PLAN_IDLE \
		or not host._detail_refresh_batches.is_empty()



static func _drain_detail_refresh_queue(host) -> void:

	host._last_detail_task_count = 0
	host._last_detail_forced_task_count = 0
	host._last_detail_max_task_ms = 0.0
	host._last_detail_plan_ms = 0.0
	host._last_detail_encode_ms = 0.0
	host._last_detail_cache_update_ms = 0.0
	host._last_detail_assemble_ms = 0.0
	host._last_detail_upload_ms = 0.0
	var chunk_budget = maxi(1, host.detail_scatter_refresh_chunks_per_frame)
	var ms_budget = maxf(0.01, host.detail_scatter_refresh_apply_budget_ms - host._resource_visual_cpu_ms) \
		if host.detail_scatter_refresh_apply_budget_ms > 0.0 else 0.0
	# Reserve one of three shared upload opportunities for resources. Vegetation
	# source/family work never uploads another buffer in the same opportunity.
	if host._resource_visual_layer != null and Engine.get_process_frames() % 3 == 0 \
			and host._resource_visual_layer.drain_one_upload():
		return
	# 信用制预算：每帧累积 ms_budget（上限 2× 防暴饮暴食）。严格闸门：信用不足
	# 一整份预算时不启动新 chunk——单个 chunk 成本可超预算（water cache ≈4ms），
	# 宽闸门（信用>0 即放行）会让贵 chunk 几乎每帧漏过，实测排水 3.5ms/帧远超
	# 2.5ms 预算。防饿死：30 帧无进度则强制放行一个 chunk（兜底预算 < chunk 成本
	# 的极端配置）。历史上该闸门曾与可视回归同时出现，事后查明回归根因是
	# GDExt DLL 与烘焙源码版本错配，与本闸门无关。
	var detail_work_pending = not host._detail_refresh_queue.is_empty() \
		or host._detail_plan_phase != host.DETAIL_PLAN_IDLE \
		or not host._detail_refresh_batches.is_empty()
	if ms_budget > 0.0 and detail_work_pending:
		host._drain_credit_ms = minf(host._drain_credit_ms + ms_budget, ms_budget * 2.0)
	if not host._drain_cfg_logged:
		host._drain_cfg_logged = true
		if host.detail_scatter_refresh_log_enabled and PKLog.enabled:
			print("[detail_scatter/DRAIN_CFG] budget_ms=%.2f chunks_per_frame=%d plan_items=%d cells_per_batch=%d chunk_size=%d" % [
				ms_budget, chunk_budget,
				maxi(1, host.detail_scatter_refresh_plan_items_per_frame),
				maxi(1, host.detail_scatter_refresh_cells_per_batch),
				maxi(2, host.detail_scatter_chunk_size_cells),
			])
	var t0 = Time.get_ticks_usec()
	if host._detail_refresh_queue.is_empty():
		var has_pending_work = detail_work_pending
		var can_plan = ms_budget <= 0.0 or host._drain_credit_ms > 0.0
		if can_plan:
			var plan_t0 = Time.get_ticks_usec()
			var plan_deadline_usec = 0
			if ms_budget > 0.0:
				var plan_budget_ms = minf(ms_budget, maxf(host._drain_credit_ms, 0.0))
				plan_deadline_usec = t0 + int(plan_budget_ms * 1000.0)
			has_pending_work = _start_next_detail_refresh_batch(host, 
				plan_deadline_usec, maxi(1, host.detail_scatter_refresh_plan_items_per_frame))
			host._last_detail_plan_ms = float(Time.get_ticks_usec() - plan_t0) / 1000.0
			if ms_budget > 0.0:
				host._drain_credit_ms -= host._last_detail_plan_ms
		if host._detail_refresh_queue.is_empty():
			host._last_detail_refresh_report["plan_ms"] = host._last_detail_plan_ms
			host._last_detail_refresh_report["plan_active"] = host._detail_plan_phase != host.DETAIL_PLAN_IDLE
			host._last_detail_refresh_report["remaining_chunks"] = 0
			host._last_detail_refresh_report["pending_batches"] = host._detail_refresh_batches.size()
			host._last_detail_refresh_report["elapsed_ms"] = float(
				host._last_detail_refresh_report.get("elapsed_ms", 0.0)) + host._last_detail_plan_ms
			if not has_pending_work:
				# succession 队列排空后继续完成尚未结束的 family/budget 分层下发。
				if _drain_one_detail_family_upload(host):
					_mark_detail_budget_total_dirty(host)
				_apply_detail_global_budget(host, false, true)
			return
	var done = 0
	var forced_one = false
	while done < chunk_budget and not host._detail_refresh_queue.is_empty():
		if ms_budget > 0.0:
			var head: Dictionary = host._detail_refresh_queue[0]
			var head_wait_msec = Time.get_ticks_msec() - int(
				head.get("enqueued_msec", Time.get_ticks_msec()))
			# 超时只授权这一帧推进一个任务，不能让后续所有超时任务一起绕过预算。
			# 旧逻辑会在 chunks_per_frame=4 时把约 15ms 的任务叠成稳定 60ms 尾耗时。
			var force_progress = done == 0 and bool(head.get("visible_priority", true)) \
				and head_wait_msec >= 100
			if not force_progress:
				if host._drain_credit_ms < ms_budget:
					break
				if done > 0 and float(Time.get_ticks_usec() - t0) / 1000.0 >= ms_budget:
					break
			else:
				forced_one = true
		var task: Dictionary = host._detail_refresh_queue.pop_front()
		var task_t0 = Time.get_ticks_usec()
		var layer = task.get("layer", null)
		if layer != null and is_instance_valid(layer):
			var task_family_mask = int(task.get("family_mask", _detail_all_family_mask(host)))
			for raw_idx in task.get("dirty_indices", PackedInt32Array()):
				task_family_mask |= int(host._scatter_cell_family_masks.get(int(raw_idx), 0))
			var layer_family_mask = int(layer.detail_render_family_mask()) \
				if layer.has_method("detail_render_family_mask") else _detail_all_family_mask(host)
			if (task_family_mask & layer_family_mask) == 0:
				continue
			var layer_t0 = Time.get_ticks_usec()
			if task.has("chunk_id") and layer.has_method("refresh_chunk_for_succession"):
				var refreshed = bool(layer.refresh_chunk_for_succession(
					int(task.get("chunk_id", -1)),
					task.get("cell_indices", PackedInt32Array()),
					int(task.get("dirty_cells", 0)),
					task.get("dirty_indices", PackedInt32Array())
				))
				if refreshed and host.detail_scatter_family_renderer_enabled \
						and layer.has_method("detail_render_family"):
					var family = int(layer.detail_render_family())
					var chunk_id = int(task.get("chunk_id", -1))
					host._detail_family_dirty_chunks["%d:%d" % [family, chunk_id]] = {
						"source": layer,
						"chunk_id": chunk_id,
					}
			elif layer.has_method("refresh_for_succession"):
				layer.refresh_for_succession(task.get("cell_indices", host._detail_refresh_indices))
			var layer_elapsed = float(Time.get_ticks_usec() - layer_t0) / 1000.0
			host._last_detail_task_count += 1
			if layer.has_method("get_scatter_diagnostics"):
				var timing: Dictionary = layer.get_scatter_diagnostics()
				host._last_detail_encode_ms += float(timing.get("native_context_ms", 0.0)) \
					+ float(timing.get("native_knobs_ms", 0.0)) \
					+ float(timing.get("native_call_ms", 0.0))
				host._last_detail_cache_update_ms += float(timing.get("cache_update_ms", 0.0))
				host._last_detail_assemble_ms += float(timing.get("assemble_ms", 0.0))
				host._last_detail_upload_ms += float(timing.get("native_apply_ms", 0.0))
			if host.detail_scatter_refresh_log_enabled and PKLog.enabled and layer.has_method("get_scatter_diagnostics"):
				var d: Dictionary = layer.get_scatter_diagnostics()
				if layer_elapsed >= host.detail_scatter_slow_layer_ms or float(d.get("rebuild_ms", 0.0)) >= host.detail_scatter_slow_layer_ms:
					print("[detail_scatter/SLOW_CHUNK] name=%s wall=%.2fms update=%.2fms path=%s inst=%d cand=%d wrap=%d cells=%d chunks=%d sampled=%d active=%d water=%.2fms ctx=%.2fms knobs=%.2fms native=%.2fms apply=%.2fms remaining=%d missing=%d dropped=%d reason=%s" % [
						str(d.get("name", layer.name)),
						layer_elapsed,
						float(d.get("rebuild_ms", 0.0)),
						str(d.get("path", "")),
						int(d.get("instances", 0)),
						int(d.get("candidates", 0)),
						int(d.get("wrap_edge_copies", 0)),
						int(d.get("incremental_cells", 0)),
						int(d.get("dirty_chunks", 0)),
						int(d.get("native_sampled_cells", 0)),
						int(d.get("native_active_cells", 0)),
						float(d.get("native_water_cache_ms", 0.0)),
						float(d.get("native_context_ms", 0.0)),
						float(d.get("native_knobs_ms", 0.0)),
						float(d.get("native_call_ms", 0.0)),
						float(d.get("native_apply_ms", 0.0)),
						host._detail_refresh_queue.size(),
					int(d.get("missing_slots", 0)),
					int(d.get("dropped_instances", 0)),
					str(d.get("reason", "")),
				])
		done += 1
		host._drain_last_progress_frame = Engine.get_process_frames()
		if ms_budget > 0.0:
			var task_elapsed_ms = float(Time.get_ticks_usec() - task_t0) / 1000.0
			host._last_detail_max_task_ms = maxf(host._last_detail_max_task_ms, task_elapsed_ms)
			host._drain_credit_ms -= task_elapsed_ms
		else:
			host._last_detail_max_task_ms = maxf(
				host._last_detail_max_task_ms,
				float(Time.get_ticks_usec() - task_t0) / 1000.0)
		if forced_one:
			host._last_detail_forced_task_count = 1
			break
	var elapsed = float(Time.get_ticks_usec() - t0) / 1000.0
	# source payload 本帧已写过一个 MultiMesh 时，把 family 合并上传留到空闲帧，
	# 严格维持运行期每帧最多一次 MultiMesh buffer 赋值。
	if done == 0:
		if _drain_one_detail_family_upload(host):
			_mark_detail_budget_total_dirty(host)
	else:
		_mark_detail_budget_total_dirty(host)
	host._last_detail_refresh_report["chunks_done"] = int(host._last_detail_refresh_report.get("chunks_done", 0)) + done
	host._last_detail_refresh_report["layers_done"] = int(host._last_detail_refresh_report.get("chunks_done", 0))
	host._last_detail_refresh_report["elapsed_ms"] = float(host._last_detail_refresh_report.get("elapsed_ms", 0.0)) + elapsed
	host._last_detail_refresh_report["remaining_chunks"] = host._detail_refresh_queue.size()
	host._last_detail_refresh_report["pending_batches"] = host._detail_refresh_batches.size()
	host._last_detail_refresh_report["plan_ms"] = host._last_detail_plan_ms
	host._last_detail_refresh_report["plan_active"] = host._detail_plan_phase != host.DETAIL_PLAN_IDLE
	# 一个昂贵 chunk 已经消耗本帧信用时，不再叠加全层 visible-count 同步；
	# 无 chunk 的帧按 layers_per_frame 渐进推进，避免 20+ 层一次性尖峰。
	_apply_detail_global_budget(host, false, done == 0)
	if host._detail_refresh_queue.is_empty() and host._detail_plan_phase == host.DETAIL_PLAN_IDLE:
		if host.detail_scatter_refresh_log_enabled and PKLog.enabled:
			print("[detail_scatter/DONE] batch_cells=%d chunks=%d batch_chunks=%d elapsed=%.2fms pending_batches=%d budget=%s" % [
				int(host._last_detail_refresh_report.get("dirty_cells", 0)),
				int(host._last_detail_refresh_report.get("chunks_done", 0)),
				int(host._last_detail_refresh_report.get("batch_chunks", 0)),
				float(host._last_detail_refresh_report.get("elapsed_ms", 0.0)),
				host._detail_refresh_batches.size(),
				str(host._last_detail_budget_report),
			])
		_release_detail_refresh_inflight(host, host._detail_refresh_indices)
		host._detail_refresh_indices = PackedInt32Array()



static func _drain_one_detail_family_upload(host) -> bool:

	if _drain_one_vegetation_family_upload(host):
		return true
	return bool(host._resource_visual_layer.drain_one_upload()) if host._resource_visual_layer != null else false



static func _drain_one_vegetation_family_upload(host) -> bool:

	if not host.detail_scatter_family_renderer_enabled \
			or host._detail_family_layer == null or not is_instance_valid(host._detail_family_layer):
		return false
	if host._detail_family_dirty_chunks.is_empty():
		return bool(host._detail_family_layer.drain_one_shadow_upload()) \
			if host._detail_family_layer.has_method("drain_one_shadow_upload") else false
	var keys: Array = host._detail_family_dirty_chunks.keys()
	keys.sort()
	var key = ""
	for candidate in keys:
		if not _detail_family_upload_has_pending_source(host, str(candidate)):
			key = str(candidate)
			break
	if key.is_empty():
		return false
	var task: Dictionary = host._detail_family_dirty_chunks[key]
	host._detail_family_dirty_chunks.erase(key)
	var source = task.get("source", null)
	if source != null and is_instance_valid(source):
		host._detail_family_layer.rebuild_source_chunk(source, int(task.get("chunk_id", -1)))
		return true
	return false



static func _detail_family_upload_has_pending_source(host, key: String) -> bool:
	return DetailBudget._detail_family_upload_has_pending_source(host, key)


static func detail_scatter_refresh_report(host) -> Dictionary:
	return DetailBudget.detail_scatter_refresh_report(host)


static func _oldest_visible_detail_task_wait_ms(host) -> int:
	return DetailBudget._oldest_visible_detail_task_wait_ms(host)


static func detail_scatter_layer_reports(host) -> Array:
	return DetailBudget.detail_scatter_layer_reports(host)


static func _detail_total_instance_budget(host) -> int:
	return DetailBudget._detail_total_instance_budget(host)


static func _detail_budget_fraction_needs_apply(host, next_fraction: float) -> bool:
	return DetailBudget._detail_budget_fraction_needs_apply(host, next_fraction)


static func _begin_detail_budget_apply(host, fraction: float) -> void:
	DetailBudget._begin_detail_budget_apply(host, fraction)


static func _note_detail_budget_applied_view(host) -> void:
	DetailBudget._note_detail_budget_applied_view(host)


static func _detail_budget_view_moved(host) -> bool:
	return DetailBudget._detail_budget_view_moved(host)


static func _apply_detail_budget_to_layer(host, layer, fraction: float) -> bool:
	return DetailBudget._apply_detail_budget_to_layer(host, layer, fraction)


static func _drain_detail_budget_apply(host, force_complete: bool) -> void:
	DetailBudget._drain_detail_budget_apply(host, force_complete)


static func _apply_detail_global_budget(host, force_complete: bool = false, allow_apply: bool = true) -> void:
	DetailBudget._apply_detail_global_budget(host, force_complete, allow_apply)


static func detail_scatter_budget_report(host) -> Dictionary:
	return DetailBudget.detail_scatter_budget_report(host)


static func _mark_detail_budget_total_dirty(host) -> void:
	DetailBudget._mark_detail_budget_total_dirty(host)


static func _log_detail_scatter_rebuild_summary(host, reason: String) -> void:
	DetailBudget._log_detail_scatter_rebuild_summary(host, reason)
