extends RefCounted

## Stateless collaborator for ShrubLayer.

static func pixel_world_size(host) -> float:

	return host._pixel_world_size


## [pixel-scale-detail 2026-11-03] 验收探针：当前一个 hex / 一个数据 texel 在屏幕上
## 各占多少**物理**像素。放大到底时用它区分两种"糊"：
##   - px_per_texel 很大（>10）→ 数据密度不够，要加 texels_per_hex 或分块高精度；
##   - px_per_texel 正常但画面仍平 → shader 缺屏幕空间高频细节层。
## 真机上把这条打进日志即可判断，不需要猜。

static func pixel_scale_report(host) -> Dictionary:

	var px_per_world = 1.0 / maxf(host._pixel_world_size, 0.000001)
	var texels_per_hex = 0.0
	var texel_world = 0.0
	var tile_mode = "none"
	if host._world != null:
		var tiles = host._world.visual_tiles
		if tiles != null and tiles.layout != null:
			tile_mode = String(tiles.layout.mode)
			texels_per_hex = float(tiles.layout.effective_texels_per_hex)
			texel_world = float(tiles.layout.effective_world_units_per_texel.x)
		elif host._world.hm_size.x > 0 and host._world.world_bounds.size.x > 0.0001:
			tile_mode = "legacy"
			texel_world = host._world.world_bounds.size.x / float(host._world.hm_size.x)
			texels_per_hex = host.hex_size / maxf(texel_world, 0.000001)
	return {
		"tile_mode": tile_mode,
		"camera_zoom": host._camera_zoom,
		"pixel_world_size": host._pixel_world_size,
		"px_per_world_unit": px_per_world,
		"hex_px": host.hex_size * px_per_world,
		"texels_per_hex": texels_per_hex,
		"texel_world_size": texel_world,
		"px_per_texel": texel_world * px_per_world,
	}



static func _refresh_pixel_world_size(host) -> float:

	# get_global_transform_with_canvas 同时含本节点局部缩放与 Camera2D/content_scale；
	# 场景里 _world_quad 是单位变换，所以它等于 canvas 缩放。树外的调用（构建期、
	# 材质预热）拿不到 canvas，退回 camera_zoom，避免把 1.0 写进 uniform。
	var scale_x = maxf(host._camera_zoom, 0.0001)
	if host.is_inside_tree():
		var canvas_scale = host.get_global_transform_with_canvas().get_scale().x
		if is_finite(canvas_scale) and canvas_scale > 0.000001:
			scale_x = canvas_scale
	host._pixel_world_size = clampf(1.0 / scale_x, 0.00001, 1024.0)
	return host._pixel_world_size



static func set_camera_zoom(host, value: float) -> void:

	var next_zoom = clampf(value, 0.01, 16.0)
	if absf(next_zoom - host._camera_zoom) < 0.001:
		return
	host._camera_zoom = next_zoom
	_refresh_pixel_world_size(host, )
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_camera_view(host._camera_world_rect, host._camera_world_center, host._camera_zoom)
	if host._shader_mat != null:
		host._push_world_uniform("camera_zoom", host._camera_zoom)
		host._push_world_uniform("pixel_world_size", host._pixel_world_size)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_camera_zoom(host._camera_zoom)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		layer.set_camera_zoom(host._camera_zoom)
	)
	host._mark_detail_budget_total_dirty()



static func set_camera_view(host, world_rect: Rect2, center: Vector2, zoom_value: float) -> void:

	var t0_us = Time.get_ticks_usec()
	host._camera_world_rect = world_rect
	host._camera_world_center = center
	host._camera_view_initialized = world_rect.size.x > 0.0 and world_rect.size.y > 0.0
	host._camera_zoom = clampf(zoom_value, 0.01, 16.0)
	if host._shader_mat != null:
		host._push_world_uniform("pixel_world_size", _refresh_pixel_world_size(host, ))
	else:
		_refresh_pixel_world_size(host, )
	if host._resource_visual_layer != null:
		host._resource_visual_layer.set_camera_view(world_rect, center, host._camera_zoom)
	if host._building_visual_layer != null:
		host._building_visual_layer.set_camera_view(world_rect, center, host._camera_zoom)
	host._for_each_vegetation_layer(func(layer: ShrubLayer) -> void:
		if layer.has_method("set_camera_view"):
			layer.set_camera_view(world_rect, center, host._camera_zoom)
	)
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer):
		host._detail_family_layer.set_camera_view(world_rect, center, host._camera_zoom)
	if host.detail_scatter_family_renderer_enabled:
		_queue_missing_prefetch_detail_chunks(host, )
	else:
		host._detail_render_chunk_count = 0
		host._detail_prefetch_chunk_count = 0
	if not host.detail_scatter_family_renderer_enabled and not host._detail_layers.is_empty():
		var probe = host._detail_layers[0]
		if probe != null and is_instance_valid(probe) and probe.has_method("get_scatter_diagnostics"):
			var d: Dictionary = probe.get_scatter_diagnostics()
			host._detail_render_chunk_count = int(d.get("visible_chunks", 0))
			host._detail_prefetch_chunk_count = int(d.get("prefetch_chunks", 0))
	_reactivate_deferred_detail_chunks(host, )
	host._mark_detail_budget_total_dirty()
	host._detail_visibility_last_ms = float(Time.get_ticks_usec() - t0_us) / 1000.0



static func _queue_missing_prefetch_detail_chunks(host) -> void:

	if not host.detail_scatter_family_renderer_enabled or host._detail_layers.is_empty() or host._map == null:
		return
	var probe = host._detail_layers[0]
	if probe == null or not is_instance_valid(probe) \
			or not probe.has_method("detail_prefetch_chunk_plan"):
		return
	var plan: Array = probe.detail_prefetch_chunk_plan()
	plan.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_cells: PackedInt32Array = a.get("cell_indices", PackedInt32Array())
		var b_cells: PackedInt32Array = b.get("cell_indices", PackedInt32Array())
		var a_pos = _detail_chunk_center_from_cells(host, a_cells)
		var b_pos = _detail_chunk_center_from_cells(host, b_cells)
		return a_pos.distance_squared_to(host._camera_world_center) \
			< b_pos.distance_squared_to(host._camera_world_center)
	)
	host._detail_prefetch_chunk_count = plan.size()
	host._detail_render_chunk_count = 0
	for chunk in plan:
		var chunk_id = int(chunk.get("chunk_id", -1))
		if chunk_id < 0:
			continue
		if probe.has_method("detail_chunk_is_render_visible") \
				and bool(probe.detail_chunk_is_render_visible(chunk_id)):
			host._detail_render_chunk_count += 1
		var resident = true
		for layer in host._detail_layers:
			if layer == null or not is_instance_valid(layer) \
					or not layer.has_method("detail_chunk_has_resident_cache") \
					or not bool(layer.detail_chunk_has_resident_cache(chunk_id)):
				resident = false
				break
		if not resident:
			host._detail_deferred_chunks[chunk_id] = host._detail_all_family_mask()
			host._detail_deferred_profile_masks[chunk_id] = (1 << host._detail_layers.size()) - 1



static func _detail_chunk_center_from_cells(host, cells: PackedInt32Array) -> Vector2:

	if host._map == null or cells.is_empty():
		return Vector2.ZERO
	var sum = Vector2.ZERO
	var count = 0
	for raw_idx in cells:
		var idx = int(raw_idx)
		if idx < 0 or idx >= host._map.cell_pos_x_arr.size() or idx >= host._map.cell_pos_y_arr.size():
			continue
		sum += Vector2(host._map.cell_pos_x_arr[idx], host._map.cell_pos_y_arr[idx]) * host.hex_size
		count += 1
	return sum / float(count) if count > 0 else Vector2.ZERO



static func _reactivate_deferred_detail_chunks(host) -> void:

	if host._detail_deferred_chunks.is_empty() or host._detail_layers.is_empty():
		return
	var probe = host._detail_layers[0]
	if probe == null or not is_instance_valid(probe) \
			or not probe.has_method("detail_chunk_is_in_prefetch") \
			or not probe.has_method("detail_chunk_cells"):
		return
	var resumed = PackedInt32Array()
	for raw_chunk_id in host._detail_deferred_chunks.keys():
		var chunk_id = int(raw_chunk_id)
		if not bool(probe.detail_chunk_is_in_prefetch(chunk_id)):
			continue
		var family_mask = int(host._detail_deferred_chunks[raw_chunk_id])
		var profile_mask = int(host._detail_deferred_profile_masks.get(
			raw_chunk_id, (1 << host._detail_layers.size()) - 1))
		var cells: PackedInt32Array = probe.detail_chunk_cells(chunk_id)
		for raw_idx in cells:
			var ci = int(raw_idx)
			host._scatter_cell_family_masks[ci] = int(host._scatter_cell_family_masks.get(ci, 0)) | family_mask
			host._scatter_cell_profile_masks[ci] = int(
				host._scatter_cell_profile_masks.get(ci, 0)) | profile_mask
			if host._scatter_inflight.has(ci):
				continue
			host._scatter_inflight[ci] = true
			resumed.append(ci)
		host._detail_deferred_chunks.erase(raw_chunk_id)
		host._detail_deferred_profile_masks.erase(raw_chunk_id)
	if resumed.is_empty():
		return
	host._enqueue_detail_refresh_batches(host._dedup_detail_refresh_indices(resumed))
	if host._detail_refresh_queue.is_empty():
		host._start_next_detail_refresh_batch()



