extends RefCounted

## Stateless collaborator for ShrubLayer.

static func get_scatter_diagnostics(host) -> Dictionary:

	return {
		"name": host.name,
		"path": host._last_scatter_path,
		"instances": host._instance_count,
		"candidates": host._last_candidate_count,
		"wrap_edge_copies": host._last_wrap_edge_copy_count,
		"rebuild_ms": host._last_rebuild_ms,
		"reason": host._last_rebuild_reason,
		"incremental_cells": host._last_incremental_cells,
		"dirty_chunks": host._last_dirty_chunks,
		"native_sampled_cells": host._last_native_sampled_cells,
		"native_active_cells": host._last_native_active_cells,
		"native_water_cache_ms": host._last_native_water_cache_ms,
		"native_context_ms": host._last_native_context_ms,
		"native_knobs_ms": host._last_native_knobs_ms,
		"native_call_ms": host._last_native_call_ms,
		"native_apply_ms": host._last_native_apply_ms,
		"cache_update_ms": host._last_cache_update_ms,
		"assemble_ms": host._last_assemble_ms,
		"chunk_cell_cache_entries": host._chunk_cell_indices_cache.size(),
		"chunk_bounds_cache_entries": host._chunk_world_bounds_cache.size(),
		"chunk_cell_cache_builds": host._chunk_cell_cache_builds,
		"chunk_bounds_cache_builds": host._chunk_bounds_cache_builds,
		"active_instance_count_scans": host._active_instance_count_scans,
		"chunked": host._chunked_multimesh_enabled,
		"chunk_size_cells": host._chunk_size_cells,
		"missing_slots": host._last_incremental_missing_slots,
		"dropped_instances": host._last_incremental_dropped_instances,
		"spawn_domain": host._spawn_domain(),
		"detail_kind": host._detail_kind(),
		"render_family": host.detail_render_family(),
		"camera_view_initialized": host._camera_view_initialized,
		"visible_chunks": host._visible_chunk_count,
		"prefetch_chunks": host._prefetch_chunk_count,
		"lod_near_density_multiplier": host._resolved_lod_near_density_multiplier(),
		"lod_far_visible_fraction": host._lod_far_visible_fraction,
		"lod_far_instance_count": host._far_instance_count,
		"lod_zoom_t": host._lod_zoom_t,
		"lod_effective_visible_fraction": host._effective_visible_instance_fraction(),
		"seamless_spawn_radius": host._effective_spawn_radius_factor(),
	}


# 可见性现场探针：实例存在但屏幕全无时用于区分 数据缺失 / 节点隐藏 / 可见数
# 归零 / mesh 缺失 / profile 关闭 等失败模式。只读，不改变任何状态。

static func detail_visibility_probe(host) -> Dictionary:

	var chunk_nodes = 0
	var chunk_nodes_visible = 0
	var chunk_mm_valid = 0
	var chunk_mesh_valid = 0
	var visible_sum = 0
	var inst_sum = 0
	var origin_samples: Array = []
	for raw_id in host._chunk_nodes.keys():
		var node: MultiMeshInstance2D = host._chunk_nodes[raw_id]
		if node == null or not is_instance_valid(node):
			continue
		chunk_nodes += 1
		if node.visible:
			chunk_nodes_visible += 1
		var mm = node.multimesh
		if mm == null:
			continue
		chunk_mm_valid += 1
		if mm.mesh != null:
			chunk_mesh_valid += 1
		visible_sum += mm.visible_instance_count
		inst_sum += mm.instance_count
		# 采样前几个实例的 origin（TRANSFORM_2D buffer: ox 在 +3、oy 在 +7），
		# 用于区分"实例不可见"与"实例被放到屏幕外/原点"。
		# 同时抽样编码器写入的存储 uv（world_ext_detail.cpp 布局：origin=buf[3]/buf[7]，
		# custom uv=buf[12]/buf[13]）。uv 是 shader 实际消费的输入，与世界坐标分离采样
		# 可直接区分"存储 uv 错"与"uniform/寻址错"。
		if origin_samples.size() < 3 and mm.instance_count > 0:
			var buf = mm.buffer
			var take: int = mini(3 - origin_samples.size(), mm.instance_count)
			for k in range(take):
				if buf.size() >= (k + 1) * 16:
					origin_samples.append({
						"pos": Vector2(buf[k * 16 + 3], buf[k * 16 + 7]),
						"uv": Vector2(buf[k * 16 + 12], buf[k * 16 + 13]),
					})
	return {
		"name": host.name,
		"in_tree": host.is_inside_tree(),
		"layer_visible": host.visible,
		"profile_enabled": bool(host._profile().enabled),
		"camera_lod_hidden": host._camera_lod_hidden,
		"shadow_fraction": host._shadow_fraction,
		"lod_zoom_t": host._lod_zoom_t,
		"lod_alpha": host._lod_alpha,
		"camera_zoom": host._camera_zoom,
		"instance_count": host._instance_count,
		"chunk_nodes": chunk_nodes,
		"chunk_nodes_visible": chunk_nodes_visible,
		"chunk_mm_valid": chunk_mm_valid,
		"chunk_mesh_valid": chunk_mesh_valid,
		"chunk_visible_sum": visible_sum,
		"chunk_inst_sum": inst_sum,
		"origin_samples": origin_samples,
		"spawn_domain": host._spawn_domain(),
		"cid_probe": _cid_probe(host, origin_samples),
		# [DEBUG-TEMP] chunk 材质 shader 变体 / 纹理绑定核查：duplicate(true) 深拷贝的
		# chunk 材质在 _refresh_shader_variants 后可能滞留旧 shader 变体或缺纹理绑定。
		"chunk_material_probe": _chunk_material_probe(host, ),
	}


# [DEBUG-TEMP] 一次性检查：chunk 节点共享材质 / shader 变体 / 关键纹理参数绑定核查。

static func _chunk_material_probe(host) -> Dictionary:

	var out = {
		"tiled_active": host._visual_tiles_active(),
		"base_shader_tiled": false,
		"map_index_param": false,
		"grid_size_param": "",
		"interior_param": "",
		"domain_origin_param": "",
		"world_size_param": "",
		"wrap_param": 0.0,
		"chunk_count": host._chunk_nodes.size(),
		"chunk_material_shared": 0,
		"chunk_material_other": 0,
	}
	if host._material == null or host._material.shader == null:
		return out
	out["base_shader_tiled"] = host._material.shader.code.begins_with(
		"#define MAP_VISUAL_TILED")
	if bool(out["base_shader_tiled"]):
		var tiles_param = host._material.get_shader_parameter("visual_map_index_tiles")
		out["map_index_param"] = tiles_param != null
		if tiles_param != null:
			out["map_index_layers"] = tiles_param.get_layers() if tiles_param.has_method("get_layers") else -1
		out["grid_size_param"] = str(host._material.get_shader_parameter(
			"visual_grid_size"))
		out["interior_param"] = str(host._material.get_shader_parameter(
			"visual_interior_size"))
		out["domain_origin_param"] = str(host._material.get_shader_parameter(
			"visual_domain_origin"))
	else:
		out["map_index_param"] = host._material.get_shader_parameter(
			"map_index_atlas") != null
	out["world_size_param"] = str(host._material.get_shader_parameter(
		"world_size"))
	out["wrap_param"] = float(host._material.get_shader_parameter(
		"wrap_period_x"))
	for chunk_id in host._chunk_nodes.keys():
		var node: MultiMeshInstance2D = host._chunk_nodes[chunk_id]
		if node != null and is_instance_valid(node):
			if node.material == host._material:
				out["chunk_material_shared"] += 1
			else:
				out["chunk_material_other"] += 1
	return out


# tiled 模式端到端解码探针：对实例世界坐标按 shader 的 visual_tile_address 逻辑
# 逐步寻址，从 map_index 数组读回 G/B 解码 cid，并与期望 cell 对照。cid=-1 或
# 与期望不符即复现"presence=0 全灭"链路；同时抽样 normal/height 验证内容。

static func _cid_probe(host, samples: Array) -> Array:

	var out: Array = []
	if not host._visual_tiles_active() or host._map == null or samples.is_empty():
		return out
	var tiles = host._world.visual_tiles
	var layout = tiles.layout
	var take: int = mini(2, samples.size())
	for k in range(take):
		var sample: Dictionary = samples[k]
		var world_pos: Vector2 = sample["pos"]
		var stored_uv: Vector2 = sample["uv"]
		# 与原生编码器一致的世界坐标 → map_uv（world_ext_detail.cpp uvx/uvy 公式）。
		var sample_x = world_pos.x
		if host._world.wrap_period_x > 0.0001:
			sample_x = fposmod(world_pos.x, host._world.wrap_period_x)
		var map_uv = Vector2(
			(sample_x - host._bounds.position.x) / maxf(host._bounds.size.x, 0.0001),
			(world_pos.y - host._bounds.position.y) / maxf(host._bounds.size.y, 0.0001))
		# 与 visual_tile_sampling.gdshaderinc::visual_tile_address 一致的寻址。
		var wp = host._bounds.position + map_uv * host._bounds.size
		if host._world.wrap_period_x > 0.0001:
			wp.x = fposmod(wp.x, host._world.wrap_period_x)
		var domain_uv: Vector2 = (wp - layout.visual_domain.position) / layout.visual_domain.size
		domain_uv.x = fposmod(domain_uv.x, 1.0) if host._world.wrap_period_x > 0.0001 else clampf(domain_uv.x, 0.0, 1.0)
		domain_uv.y = clampf(domain_uv.y, 0.0, 1.0)
		var scaled: Vector2 = domain_uv * Vector2(layout.grid_size)
		var tile_xy = Vector2i(mini(int(floor(scaled.x)), layout.grid_size.x - 1),
			mini(int(floor(scaled.y)), layout.grid_size.y - 1))
		var local01: Vector2 = scaled - Vector2(tile_xy)
		var gutter = float(layout.gutter_px)
		var physical_px = Vector2(gutter, gutter) + local01 * Vector2(layout.interior_size)
		var layer: int = tile_xy.y * layout.grid_size.x + tile_xy.x
		var entry: Dictionary = {"world_pos": world_pos, "tile_xy": tile_xy,
			"layer": layer, "physical_px": physical_px,
			# 输入与中间量全量转储：静态推演与观测矛盾时的最终事实来源。
			"in_bounds": str(host._bounds),
			"in_wrap": host._world.wrap_period_x,
			"in_grid": str(layout.grid_size), "in_interior": str(layout.interior_size),
			"in_domain": str(layout.visual_domain),
			"wp": wp, "domain_uv": domain_uv, "scaled": scaled, "local01": local01,
			"stored_uv": stored_uv}
		if tiles.map_index != null:
			var img = RenderingServer.texture_2d_layer_get(tiles.map_index.get_rid(), layer)
			if img != null:
				var px = img.get_pixelv(Vector2i(physical_px))
				var lo = int(px.g * 255.0 + 0.5)
				var hi = int(px.b * 255.0 + 0.5)
				var cid = lo + hi * 256
				entry["map_index_px"] = px
				entry["cid"] = -1 if cid >= 65535 else cid
				# 期望 cell：用地图最近 cell 对照（粗校验，容差一个 hex）。
				entry["expect_cell"] = _nearest_cell_index(host, world_pos)
			# 对照组：按"世界坐标→domain_uv 直接换算"的期望地址再采一次。
			# 若此 cid ≈ expect_cell，则内容与公式正确，断裂在实例存储 uv；
			# 若同样不符，则烘焙内容或 layout 契约本身有错。
			var ref_uv = Vector2(
				fposmod(world_pos.x, host._world.wrap_period_x) / layout.visual_domain.size.x,
				(world_pos.y - layout.visual_domain.position.y) / layout.visual_domain.size.y)
			var ref_scaled: Vector2 = ref_uv * Vector2(layout.grid_size)
			var ref_tile = Vector2i(mini(int(floor(ref_scaled.x)), layout.grid_size.x - 1),
				mini(int(floor(ref_scaled.y)), layout.grid_size.y - 1))
			var ref_local: Vector2 = ref_scaled - Vector2(ref_tile)
			var ref_px = Vector2(gutter, gutter) + ref_local * Vector2(layout.interior_size)
			var ref_layer: int = ref_tile.y * layout.grid_size.x + ref_tile.x
			var ref_img = RenderingServer.texture_2d_layer_get(tiles.map_index.get_rid(), ref_layer)
			if ref_img != null:
				var rpx = ref_img.get_pixelv(Vector2i(ref_px))
				var rcid = int(rpx.g * 255.0 + 0.5) + int(rpx.b * 255.0 + 0.5) * 256
				entry["ref_tile_px"] = [ref_tile, ref_px]
				entry["cid_ref"] = -1 if rcid >= 65535 else rcid
			# shader 真实消费链：用实例存储 uv（编码器写入 buf[12]/[13]）走 uniform 寻址。
			# 与 world_pos 链对照可区分"存储 uv 错"与"uniform/layout 错"。
			var swp = host._bounds.position + stored_uv * host._bounds.size
			if host._world.wrap_period_x > 0.0001:
				swp.x = fposmod(swp.x, host._world.wrap_period_x)
			var sdomain: Vector2 = (swp - layout.visual_domain.position) / layout.visual_domain.size
			sdomain.x = fposmod(sdomain.x, 1.0) if host._world.wrap_period_x > 0.0001 else clampf(sdomain.x, 0.0, 1.0)
			sdomain.y = clampf(sdomain.y, 0.0, 1.0)
			var sscaled: Vector2 = sdomain * Vector2(layout.grid_size)
			var stile = Vector2i(mini(int(floor(sscaled.x)), layout.grid_size.x - 1),
				mini(int(floor(sscaled.y)), layout.grid_size.y - 1))
			var slocal: Vector2 = sscaled - Vector2(stile)
			var spx = Vector2(gutter, gutter) + slocal * Vector2(layout.interior_size)
			var slayer: int = stile.y * layout.grid_size.x + stile.x
			var simg = RenderingServer.texture_2d_layer_get(tiles.map_index.get_rid(), slayer)
			if simg != null:
				var spp = simg.get_pixelv(Vector2i(spx))
				var scid = int(spp.g * 255.0 + 0.5) + int(spp.b * 255.0 + 0.5) * 256
				entry["shader_tile_px"] = [stile, spx]
				entry["cid_shader"] = -1 if scid >= 65535 else scid
		if tiles.terrain_normal != null:
			var nimg = RenderingServer.texture_2d_layer_get(tiles.terrain_normal.get_rid(), layer)
			if nimg != null:
				entry["normal_px"] = nimg.get_pixelv(Vector2i(physical_px))
		if tiles.height != null:
			var himg = RenderingServer.texture_2d_layer_get(tiles.height.get_rid(), layer)
			if himg != null:
				entry["height_px"] = himg.get_pixelv(Vector2i(physical_px))
		out.append(entry)
	return out



static func _nearest_cell_index(host, world_pos: Vector2) -> int:

	var best = -1
	var best_d = INF
	if host._map == null:
		return best
	for cell in host._map.all_cells():
		if cell == null:
			continue
		var center = HexUtils.cube_to_world(cell.q, cell.r, host._hex_size)
		var d: float = center.distance_squared_to(world_pos)
		if d < best_d:
			best_d = d
			best = int(cell.index)
	return best



static func _world_uv(host, world_pos: Vector2) -> Vector2:

	var size = host._bounds.size
	if size.x <= 0.001 or size.y <= 0.001:
		return Vector2.ZERO
	var period_x = HexUtils.wrap_period_x(host._map.width, host._hex_size) if host._map != null else 0.0
	var sample_x = world_pos.x
	if period_x > 0.0001:
		sample_x = fposmod(sample_x, period_x)
	return Vector2(
		clampf((sample_x - host._bounds.position.x) / size.x, 0.0, 1.0),
		clampf((world_pos.y - host._bounds.position.y) / size.y, 0.0, 1.0)
	)



static func _f32(host, arr: PackedFloat32Array, idx: int, fallback: float) -> float:

	if idx >= 0 and idx < arr.size():
		return float(arr[idx])
	return fallback



static func _u8(host, arr: PackedByteArray, idx: int, fallback: int) -> int:

	if idx >= 0 and idx < arr.size():
		return int(arr[idx])
	return fallback



static func _hash01(host, idx: int, salt: int) -> float:

	var x = sin(float(idx * 127 + salt * 311) * 12.9898) * 43758.5453123
	return x - floor(x)



static func _value_noise2(host, x: float, y: float, salt: int) -> float:

	var ix = floori(x)
	var iy = floori(y)
	var fx = x - float(ix)
	var fy = y - float(iy)
	var sx = fx * fx * (3.0 - 2.0 * fx)
	var sy = fy * fy * (3.0 - 2.0 * fy)
	var a = _hash2i(host, ix, iy, salt)
	var b = _hash2i(host, ix + 1, iy, salt)
	var c = _hash2i(host, ix, iy + 1, salt)
	var d = _hash2i(host, ix + 1, iy + 1, salt)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)



static func _hash2i(host, x: int, y: int, salt: int) -> float:

	var n = x * 374761393 + y * 668265263 + salt * 1442695041
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x00ffffff) / float(0x01000000)


# ─── web 首次绘制编译成本探针（2026-10-31）───────────────────────────────────
# Shader.code 赋值就是 Compatibility(GLES3/WebGL2) 后端同步编译 GLSL 的地方，
# 所以这一行的耗时≈"首帧那份 vegetation shader 编译"。只做内存聚合（按变体一行），
# 不写文件、不 dump JSON；真正发事件在 _report_veg_shader_cost()，每个变体最多
# 一条 WebTelemetry("veg_shader")，web 上整次加载一般只有 2–4 条。


## Web 预热用：返回运行期在 web 上真正会编译的 shader 源码（body / shadow / family）。
## 单一事实来源放在这里，避免 web_shader_warmup.gd 自己去拼前缀——拼错一个宏
## 驱动就不认缓存，预热白做（这个坑已经踩过两次）。

static func _report_veg_shader_cost(host) -> void:

	if host._shader_compile_stats.is_empty():
		return
	if not WebTelemetry.enabled():
		return
	var share_layers = _shader_share_layer_count(host)
	var keys: Array = host._shader_compile_stats.keys()
	keys.sort()
	for key in keys:
		if host._shader_compile_reported.has(key):
			continue
		host._shader_compile_reported[key] = true
		var record: Dictionary = host._shader_compile_stats[key]
		WebTelemetry.emit("veg_shader", {
			"s": String(record.get("s", "body")),
			"ms": snappedf(float(record.get("ms", 0.0)), 0.01),
			"n": int(record.get("n", 0)),
			"layers": share_layers,
			"near": String(record.get("near", "full")),
			"tier": host._mobile_quality_tier,
			"tiled": bool(record.get("tiled", false)),
			"h": int(record.get("h", 0)),
			"l": int(record.get("l", 0)),
		})


# 共享同一份 vegetation shader 的层数：同一父节点下的 ShrubLayer 数量。只在首次
# 编译上报时数一次，不逐帧调用。

static func _shader_share_layer_count(host) -> int:

	var parent = host.get_parent()
	if parent == null:
		return 1
	var count = 0
	for child in parent.get_children():
		if child is ShrubLayer:
			count += 1
	return maxi(count, 1)


# Generated single-tree crown and hardscape-rock sprites (resource_art/crown_atlas);
# the body shader falls back to procedural forms when the art is missing.

