extends RefCounted

const _SHADOW_BUFFER_STRIDE := 16  # 2D transform(8) + color(4) + custom(4)

## Stateless collaborator for ShrubLayer.

static func _clear_chunk_nodes(host) -> void:

	host.VegetationNodeLifecycle.clear_chunks(host)



static func _clear_wrap_node_groups(host, groups: Dictionary) -> void:

	host.VegetationNodeLifecycle.clear_wrap_nodes(groups)



static func _wrap_period_x(host) -> float:

	if host._map == null:
		return 0.0
	return HexUtils.wrap_period_x(host._map.width, host._hex_size)


# 循环副本只增加渲染节点，不复制 MultiMesh buffer。分块节点仍由 Godot 按各自 AABB 剔除。

static func _sync_wrap_nodes(host, source: MultiMeshInstance2D, nodes: Array, name_prefix: String) -> void:

	var period_x = _wrap_period_x(host, )
	if source == null or not is_instance_valid(source) or source.multimesh == null \
			or period_x <= 0.0001:
		for node_value in nodes:
			var disabled_node = node_value as MultiMeshInstance2D
			if disabled_node != null and is_instance_valid(disabled_node):
				disabled_node.visible = false
				disabled_node.multimesh = source.multimesh if source != null \
					and is_instance_valid(source) else null
		return
	var offsets = PackedFloat32Array([-period_x, period_x])
	for i in range(offsets.size()):
		var node: MultiMeshInstance2D = null
		if i < nodes.size():
			node = nodes[i] as MultiMeshInstance2D
		if node == null or not is_instance_valid(node):
			node = MultiMeshInstance2D.new()
			node.name = "%s_%s" % [name_prefix, "Left" if i == 0 else "Right"]
			host.add_child(node)
			if i < nodes.size():
				nodes[i] = node
			else:
				nodes.append(node)
		node.position = Vector2(offsets[i], 0.0)
		node.z_index = source.z_index
		node.material = source.material
		node.multimesh = source.multimesh
		node.visible = source.visible and source.multimesh != null \
			and source.multimesh.visible_instance_count != 0



static func _sync_single_wrap_nodes(host) -> void:

	_sync_wrap_nodes(host, host._mmi, host._single_wrap_nodes, "DetailWrap")



static func _sync_single_shadow_wrap_nodes(host) -> void:

	_sync_wrap_nodes(host, host._shadow_mmi, host._single_shadow_wrap_nodes, "DetailShadowWrap")



static func _sync_chunk_wrap_nodes(host, chunk_id: int) -> void:

	var source: MultiMeshInstance2D = host._chunk_nodes.get(chunk_id, null)
	var nodes: Array = host._chunk_wrap_nodes.get(chunk_id, [])
	_sync_chunk_wrap_group(host, source, nodes, "DetailChunkWrap_%d" % chunk_id, chunk_id)
	host._chunk_wrap_nodes[chunk_id] = nodes



static func _sync_shadow_chunk_wrap_nodes(host, chunk_id: int) -> void:

	var source: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
	var nodes: Array = host._shadow_chunk_wrap_nodes.get(chunk_id, [])
	_sync_chunk_wrap_group(host, source, nodes, "DetailShadowChunkWrap_%d" % chunk_id, chunk_id)
	host._shadow_chunk_wrap_nodes[chunk_id] = nodes



static func _sync_chunk_wrap_group(host, 
		source: MultiMeshInstance2D,
		nodes: Array,
		name_prefix: String,
		chunk_id: int
) -> void:

	var period_x = _wrap_period_x(host, )
	var bounds = _chunk_world_bounds(host, chunk_id)
	var offsets = PackedFloat32Array([-period_x, period_x])
	for i in range(offsets.size()):
		var should_show = source != null and is_instance_valid(source) \
			and source.multimesh != null and source.visible and period_x > 0.0001
		if should_show and host._camera_view_initialized:
			var shifted = Rect2(bounds.position + Vector2(offsets[i], 0.0), bounds.size)
			should_show = shifted.intersects(host._camera_view_rect, true)
		var node: MultiMeshInstance2D = nodes[i] as MultiMeshInstance2D if i < nodes.size() else null
		if not should_show:
			if node != null and is_instance_valid(node):
				node.visible = false
			continue
		if node == null or not is_instance_valid(node):
			node = MultiMeshInstance2D.new()
			node.name = "%s_%s" % [name_prefix, "Left" if i == 0 else "Right"]
			host.add_child(node)
			if i < nodes.size():
				nodes[i] = node
			else:
				nodes.append(node)
		node.position = Vector2(offsets[i], 0.0)
		node.z_index = source.z_index
		node.material = source.material
		node.multimesh = source.multimesh
		node.visible = true


# 为某植株 chunk 准备/复用对应的 shadow chunk 节点（blob 网格 + shadow 材质 + 低 z）。

static func _ensure_shadow_chunk_node(host, chunk_id: int) -> MultiMeshInstance2D:

	var snode: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
	if snode != null and is_instance_valid(snode):
		return snode
	if host._shadow_material == null or host._shadow_blob_mesh == null:
		host._ensure_resources()
	snode = MultiMeshInstance2D.new()
	snode.name = "DetailShadowChunk_%d" % chunk_id
	snode.material = host._shadow_material
	snode.z_index = -1  # 地形之上、植株(z=0)之下
	var smm = MultiMesh.new()
	smm.transform_format = MultiMesh.TRANSFORM_2D
	smm.use_colors = true
	smm.use_custom_data = true
	smm.mesh = host._shadow_blob_mesh
	smm.instance_count = 0
	smm.visible_instance_count = 0
	snode.multimesh = smm
	snode.visible = false
	if not host._family_batch_suppressed:
		host.add_child(snode)
	host._shadow_chunk_nodes[chunk_id] = snode
	return snode


# 把某植株 chunk 的 buffer/count 镜像到对应 shadow chunk（仅该 chunk，O(chunk)）。
# 投影方向/长度/强度/尺寸由 shadow 顶点着色器按 TOD 太阳方位实时算，故这里只需共享 transform+uv。

static func _mirror_shadow_chunk(host, chunk_id: int, buffer: PackedFloat32Array, inst: int) -> void:

	if not _shadow_resources_enabled(host, ):
		var ex: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
		if ex != null and is_instance_valid(ex):
			ex.visible = false
			_sync_shadow_chunk_wrap_nodes(host, chunk_id)
		return
	var snode = _ensure_shadow_chunk_node(host, chunk_id)
	var smm = snode.multimesh
	smm.instance_count = inst
	if inst > 0:
		smm.buffer = buffer
		var far_count = int(host._chunk_far_instance_counts.get(chunk_id, inst))
		smm.visible_instance_count = host._lod_visible_count(inst, far_count)
	else:
		smm.visible_instance_count = 0
	snode.visible = _shadow_should_render(host, ) and host.visible and smm.visible_instance_count > 0
	_sync_shadow_chunk_wrap_nodes(host, chunk_id)


# 门控/全量重建时：把所有植株 chunk 重新镜像到 shadow chunk；门控关则全部隐藏。

static func _refresh_all_shadow_chunks(host) -> void:

	if _shadow_resources_enabled(host, ):
		for cid in host._shadow_chunk_nodes.keys():
			if not host._chunk_nodes.has(cid):
				var orphan: MultiMeshInstance2D = host._shadow_chunk_nodes[cid]
				if orphan != null and is_instance_valid(orphan):
					orphan.queue_free()
				host._shadow_chunk_nodes.erase(cid)
				var orphan_wrap_nodes: Array = host._shadow_chunk_wrap_nodes.get(cid, [])
				for node_value in orphan_wrap_nodes:
					var orphan_wrap = node_value as MultiMeshInstance2D
					if orphan_wrap != null and is_instance_valid(orphan_wrap):
						orphan_wrap.queue_free()
				host._shadow_chunk_wrap_nodes.erase(cid)
		for cid in host._chunk_nodes.keys():
			var pnode: MultiMeshInstance2D = host._chunk_nodes[cid]
			if pnode != null and is_instance_valid(pnode) and pnode.multimesh != null:
				_mirror_shadow_chunk(host, int(cid), pnode.multimesh.buffer, pnode.multimesh.instance_count)
	else:
		for cid in host._shadow_chunk_nodes.keys():
			var snode: MultiMeshInstance2D = host._shadow_chunk_nodes[cid]
			if snode != null and is_instance_valid(snode):
				snode.visible = false
				_sync_shadow_chunk_wrap_nodes(host, int(cid))


# 单节点(非分块)回退模式的投影同步：仅在实例数变化(或强制)时复制 _multimesh.buffer。

static func _sync_single_shadow(host, force_rebuild: bool = false) -> void:

	if host._shadow_mmi == null or host._shadow_multimesh == null:
		return
	if not _shadow_resources_enabled(host, ):
		host._shadow_multimesh.visible_instance_count = 0
		host._shadow_mmi.visible = false
		_sync_single_shadow_wrap_nodes(host, )
		return
	var total = (host._multimesh.instance_count if host._multimesh != null else 0)
	if force_rebuild or total != host._shadow_built_total:
		if host._multimesh != null and total > 0:
			host._shadow_multimesh.instance_count = total
			host._shadow_multimesh.buffer = host._multimesh.buffer
		else:
			host._shadow_multimesh.instance_count = 0
		host._shadow_built_total = total
	if not _shadow_should_render(host, ) or not host.visible:
		host._shadow_multimesh.visible_instance_count = 0
		host._shadow_mmi.visible = false
		_sync_single_shadow_wrap_nodes(host, )
		return
	if host._shadow_built_total <= 0:
		host._shadow_multimesh.visible_instance_count = 0
		host._shadow_mmi.visible = false
		_sync_single_shadow_wrap_nodes(host, )
		return
	var combined_fraction = host._effective_visible_instance_fraction()
	var vis = clampi(
		int(floor(float(host._shadow_built_total) * combined_fraction)),
		0,
		host._shadow_built_total)
	host._shadow_multimesh.visible_instance_count = vis
	host._shadow_mmi.visible = vis > 0
	_sync_single_shadow_wrap_nodes(host, )


# ─── [veg-cast-shadow] 投影 pass：blob 网格 + 单节点 buffer 复制 + 门控 ───────────
# 单位圆盘扇形：中心顶点(0,0, UV 中心) + 边缘顶点(cos,sin, UV 在半径 0.5 圆上)。
# VERTEX 直接是单位圆坐标(供 shader 拉成椭圆)；UV 仅备用。三角扇连接。

static func _build_shadow_blob_mesh(host) -> ArrayMesh:

	var seg = 20
	var verts = PackedVector2Array()
	var uvs = PackedVector2Array()
	var cols = PackedColorArray()
	var idx = PackedInt32Array()
	verts.append(Vector2.ZERO)
	uvs.append(Vector2(0.5, 0.5))
	cols.append(Color(1.0, 1.0, 1.0, 1.0))
	for i in range(seg):
		var a = TAU * float(i) / float(seg)
		var p = Vector2(cos(a), sin(a))
		verts.append(p)
		uvs.append(Vector2(p.x * 0.5 + 0.5, p.y * 0.5 + 0.5))
		cols.append(Color(1.0, 1.0, 1.0, 1.0))
	for i in range(seg):
		idx.append(0)
		idx.append(1 + i)
		idx.append(1 + ((i + 1) % seg))
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh



static func _archetype_casts_shadow(host) -> bool:

	# 有高度的俯视 form 投影；水下（海带/珊瑚）和贴地（地衣/泥炭/草/雪堆）跳过。
	match host.detail_visual_form():
		host.ProfileScript.FORM_KELP, host.ProfileScript.FORM_CORAL, host.ProfileScript.FORM_LICHEN, \
				host.ProfileScript.FORM_PEAT_TUFT:
			return false
		host.ProfileScript.FORM_ROCK:
			return true
	match host._detail_kind():
		host.DETAIL_TREE, host.DETAIL_SHRUB, host.DETAIL_CONIFER, host.DETAIL_PALM, host.DETAIL_CACTUS, host.DETAIL_REED, host.DETAIL_DEAD_SNAG, host.DETAIL_ALPINE_FLOWER:
			return true
		_:
			return false



static func _shadow_resources_enabled(host) -> bool:

	var cfg = host._profile()
	if not cfg.enabled:
		return false
	var on = cfg.get("cast_shadow_enabled")
	if on != null and not bool(on):
		return false
	# Performance tiers: desktop LOW off, MID/HIGH zoom gated; mobile only HIGH.
	if OS.has_feature("mobile"):
		if host._active_quality_tier() < 2:
			return false
	elif host._active_quality_tier() < 1:
		return false
	return _archetype_casts_shadow(host, )



static func _shadow_min_zoom(host) -> float:

	var cfg = host._profile()
	var configured_min = cfg.get("shadow_min_zoom")
	# Profiles default shadow_min_zoom to a negative value meaning "use the tier default".
	if (configured_min is float or configured_min is int) and float(configured_min) > 0.0:
		return float(configured_min)
	if OS.has_feature("mobile"):
		return 1.25
	# [veg-lod-high 2026-10-18] 高画质在总览 zoom 也保留树影：树木在 0.45 以上仍有 89% 密度，
	# 影子却到 0.80 才出现，拉远后整片森林没有投影，画面立刻变平。
	return 0.45 if host._active_quality_tier() >= 2 else 0.70


# [shadow-zoom-fade 2026-10-18] 投影不在某个 zoom 上硬开关：门槛就是开始淡入的位置，
# 之后 0.15 zoom 内升到全强度。拉远时影子变淡而不是整片消失——原先 1.10 的硬门控会让
# 森林投影在一步之内全部消失，画面立刻变平。

static func _shadow_zoom_gain(host) -> float:

	var min_zoom = _shadow_min_zoom(host, )
	if min_zoom <= 0.0:
		return 1.0
	return smoothstep(min_zoom, min_zoom + 0.15, host._camera_zoom)



static func _push_shadow_strength(host) -> void:

	if host._shadow_material == null:
		return
	host._shadow_material.set_shader_parameter(
		"shadow_strength", host._shadow_strength_base * _shadow_zoom_gain(host, ))



static func _shadow_should_render(host) -> bool:

	if not _shadow_resources_enabled(host, ) or host._camera_lod_hidden:
		return false
	# Node visibility follows the same ramp as strength: no draw calls for shadows
	# that would be multiplied down to nothing anyway.
	return _shadow_zoom_gain(host, ) > 0.001




# 投影层同步分发：分块模式下 buffer 已在 _apply_chunk_payload* 逐 chunk 镜像，这里只在 force
# （门控/全量重建）时整体重镜像；单节点回退模式走 _sync_single_shadow。逐帧 LOD 在
# apply_visible_instance_fraction 内联同步 shadow chunk 的 visible_instance_count（无 buffer 操作）。

static func _sync_shadow_layer(host, force_rebuild: bool = false) -> void:

	if not host._chunk_nodes.is_empty():
		if host._shadow_mmi != null:
			host._shadow_mmi.visible = false  # 分块模式不使用单节点投影
		if force_rebuild:
			_refresh_all_shadow_chunks(host, )
		return
	_sync_single_shadow(host, force_rebuild)



static func _chunk_id_for_cell_idx(host, cell_idx: int) -> int:

	if host._map == null or cell_idx < 0:
		return -1
	var cell = host._map.cell_at(cell_idx)
	if cell == null:
		return -1
	var off = HexUtils.cube_to_offset(int(cell.q), int(cell.r))
	var cx = int(floor(float(off.x) / float(maxi(1, host._chunk_size_cells))))
	var cy = int(floor(float(off.y) / float(maxi(1, host._chunk_size_cells))))
	return cy * 100000 + cx



static func _cell_indices_for_chunk(host, chunk_id: int) -> PackedInt32Array:

	if host._chunk_cell_indices_cache.has(chunk_id):
		return host._chunk_cell_indices_cache[chunk_id]
	var out = PackedInt32Array()
	if host._map == null or chunk_id < 0:
		return out
	var chunk_x = chunk_id % 100000
	var chunk_y = int(floor(float(chunk_id) / 100000.0))
	var x0 = chunk_x * host._chunk_size_cells
	var y0 = chunk_y * host._chunk_size_cells
	var x1 = mini(int(host._map.width), x0 + host._chunk_size_cells)
	var y1 = mini(int(host._map.height), y0 + host._chunk_size_cells)
	for row in range(y0, y1):
		for col in range(x0, x1):
			var cube = HexUtils.offset_to_cube(col, row)
			var cell = host._map.get_cell(cube.x, cube.y)
			if cell != null:
				out.append(int(cell.index))
	host._chunk_cell_indices_cache[chunk_id] = out
	host._chunk_cell_cache_builds += 1
	return out



static func detail_chunk_cells(host, chunk_id: int) -> PackedInt32Array:

	return _cell_indices_for_chunk(host, chunk_id)



static func detail_chunk_id_for_cell(host, cell_idx: int) -> int:

	return _chunk_id_for_cell_idx(host, cell_idx)



static func _chunk_world_bounds(host, chunk_id: int) -> Rect2:

	if host._chunk_world_bounds_cache.has(chunk_id):
		return host._chunk_world_bounds_cache[chunk_id]
	var indices = _cell_indices_for_chunk(host, chunk_id)
	if indices.is_empty() or host._map == null:
		return Rect2()
	var min_pos = Vector2(INF, INF)
	var max_pos = Vector2(-INF, -INF)
	for raw_idx in indices:
		var idx = int(raw_idx)
		if idx < 0 or idx >= host._map.cell_pos_x_arr.size() or idx >= host._map.cell_pos_y_arr.size():
			continue
		var p = Vector2(host._map.cell_pos_x_arr[idx], host._map.cell_pos_y_arr[idx]) * host._hex_size
		min_pos.x = minf(min_pos.x, p.x)
		min_pos.y = minf(min_pos.y, p.y)
		max_pos.x = maxf(max_pos.x, p.x)
		max_pos.y = maxf(max_pos.y, p.y)
	if min_pos.x == INF:
		return Rect2()
	var pad = Vector2.ONE * host._hex_size * 1.5
	var bounds = Rect2(min_pos - pad, max_pos - min_pos + pad * 2.0)
	host._chunk_world_bounds_cache[chunk_id] = bounds
	host._chunk_bounds_cache_builds += 1
	return bounds



static func _invalidate_chunk_spatial_cache(host) -> void:

	host._chunk_cell_indices_cache.clear()
	host._chunk_world_bounds_cache.clear()



static func _chunk_intersects_rect(host, chunk_id: int, rect: Rect2) -> bool:

	if not host._camera_view_initialized:
		return true
	var bounds = _chunk_world_bounds(host, chunk_id)
	if bounds.size == Vector2.ZERO:
		return false
	if bounds.intersects(rect, true):
		return true
	var period = _wrap_period_x(host, )
	if period <= 0.0001:
		return false
	return Rect2(bounds.position + Vector2(-period, 0.0), bounds.size).intersects(rect, true) \
		or Rect2(bounds.position + Vector2(period, 0.0), bounds.size).intersects(rect, true)



static func detail_chunk_is_in_prefetch(host, chunk_id: int) -> bool:

	return not host._camera_view_initialized or _chunk_intersects_rect(host, chunk_id, host._camera_prefetch_rect)



static func detail_chunk_is_render_visible(host, chunk_id: int) -> bool:

	return not host._camera_view_initialized or _chunk_intersects_rect(host, chunk_id, host._camera_view_rect)



static func detail_chunk_plan_for_view(host, world_rect: Rect2) -> Array:

	var out: Array = []
	if host._map == null:
		return out
	var chunks_x = int(ceil(float(host._map.width) / float(maxi(1, host._chunk_size_cells))))
	var chunks_y = int(ceil(float(host._map.height) / float(maxi(1, host._chunk_size_cells))))
	for cy in range(chunks_y):
		for cx in range(chunks_x):
			var chunk_id = cy * 100000 + cx
			if _chunk_intersects_rect(host, chunk_id, world_rect):
				out.append({
					"chunk_id": chunk_id,
					"cell_indices": _cell_indices_for_chunk(host, chunk_id),
				})
	return out



static func detail_prefetch_chunk_plan(host) -> Array:

	return detail_chunk_plan_for_view(host, host._camera_prefetch_rect) if host._camera_view_initialized else []



static func detail_chunk_has_resident_cache(host, chunk_id: int) -> bool:

	return host._chunk_cell_payloads.has(chunk_id)



static func evict_dormant_detail_chunks(host, now_msec: int, retention_msec: int) -> int:

	var evicted = 0
	for raw_chunk_id in host._chunk_cell_payloads.keys():
		var chunk_id = int(raw_chunk_id)
		if detail_chunk_is_in_prefetch(host, chunk_id):
			host._chunk_dormant_since_msec.erase(chunk_id)
			continue
		if not host._chunk_dormant_since_msec.has(chunk_id):
			host._chunk_dormant_since_msec[chunk_id] = now_msec
			continue
		if now_msec - int(host._chunk_dormant_since_msec[chunk_id]) < retention_msec:
			continue
		host._chunk_cell_payloads.erase(chunk_id)
		host._chunk_assembled_payloads.erase(chunk_id)
		host._chunk_dormant_since_msec.erase(chunk_id)
		host._chunk_instance_counts.erase(chunk_id)
		host._chunk_far_instance_counts.erase(chunk_id)
		var node: MultiMeshInstance2D = host._chunk_nodes.get(chunk_id, null)
		if node != null and is_instance_valid(node) and node.multimesh != null:
			node.visible = false
			node.multimesh.instance_count = 0
		var shadow: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
		if shadow != null and is_instance_valid(shadow) and shadow.multimesh != null:
			shadow.visible = false
			shadow.multimesh.instance_count = 0
		evicted += 1
	if evicted > 0:
		host._refresh_instance_totals_from_chunks()
		host.invalidate_viewport_budget_cache()
	return evicted



static func _refresh_chunk_visibility(host) -> void:

	if not host._chunked_multimesh_enabled:
		return
	var any_visible = false
	host._visible_chunk_count = 0
	host._prefetch_chunk_count = 0
	for raw_chunk_id in host._chunk_nodes.keys():
		var chunk_id = int(raw_chunk_id)
		var node: MultiMeshInstance2D = host._chunk_nodes[raw_chunk_id]
		if node == null or not is_instance_valid(node) or node.multimesh == null:
			continue
		var in_render = detail_chunk_is_render_visible(host, chunk_id)
		var in_prefetch = detail_chunk_is_in_prefetch(host, chunk_id)
		if in_prefetch:
			host._prefetch_chunk_count += 1
		var count = node.multimesh.visible_instance_count
		node.visible = not host._family_batch_suppressed and in_render \
			and host._profile().enabled and not host._camera_lod_hidden and count > 0
		if node.visible:
			host._visible_chunk_count += 1
			any_visible = true
		_sync_chunk_wrap_nodes(host, chunk_id)
		var snode: MultiMeshInstance2D = host._shadow_chunk_nodes.get(chunk_id, null)
		if snode != null and is_instance_valid(snode):
			snode.visible = node.visible and _shadow_should_render(host, ) \
				and snode.multimesh != null and snode.multimesh.visible_instance_count > 0
			_sync_shadow_chunk_wrap_nodes(host, chunk_id)
	host.visible = not host._family_batch_suppressed and host._profile().enabled \
		and not host._camera_lod_hidden and any_visible



static func _ensure_chunk_node(host, chunk_id: int) -> MultiMeshInstance2D:

	var node: MultiMeshInstance2D = host._chunk_nodes.get(chunk_id, null)
	if node != null and is_instance_valid(node):
		return node
	node = MultiMeshInstance2D.new()
	node.name = "DetailChunk_%d" % chunk_id
	node.material = host._material
	if not host._family_batch_suppressed:
		host.add_child(node)
	host._chunk_nodes[chunk_id] = node
	return node



