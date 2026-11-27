extends RefCounted

## Packs native atlas working sets and dispatches platform encoders.


static func _pack_csr_for_cells(baker: MapBaker, world: WorldData, cells, use_water_lists: bool, n_pix: int,
		start_idx: int = 0, end_idx: int = -1, map: MapData = null) -> Dictionary:
	# ── P1 SoA fast path ──────────────────────────────────────────────
	if (not use_water_lists) and world != null and world.cell_first_px_arr.size() > 0:
		var _soa_n: int = world.cell_first_px_arr.size()
		# terrain_arr / is_water_render_lut 二选一：map 若没传或 size 不符则退化为
		# “not cell.passable_land + SEA_ICE 兜底”字段读取（仍比走 Dict 快）。
		# 阶段 D：渲染语义专用 LUT（SEA_ICE 强制视为水），与 gameplay is_water_lut 解耦。
		var _have_lut: bool = map != null \
				and map.terrain_arr.size() == _soa_n \
				and MapData.is_water_render_lut().size() >= 256
		var _terrain_arr: PackedByteArray = map.terrain_arr if _have_lut else PackedByteArray()
		var _iw_lut: PackedByteArray = MapData.is_water_render_lut() if _have_lut else PackedByteArray()
		var _span_fast: Vector2i = baker._cell_range(cells, start_idx, end_idx)
		var _kmax_fast: int = _span_fast.y - _span_fast.x
		var _ci_fast: PackedInt32Array = PackedInt32Array(); _ci_fast.resize(_kmax_fast)
		var _fpx_fast: PackedInt32Array = PackedInt32Array(); _fpx_fast.resize(_kmax_fast)
		var _pxc_fast: PackedInt32Array = PackedInt32Array(); _pxc_fast.resize(_kmax_fast)
		var _iw_fast: PackedByteArray = PackedByteArray(); _iw_fast.resize(_kmax_fast)
		# [perf 2026-05-20] 方案 B：flat_px 整图静态复用。
		# 之前注释提到"caller 期望 flat_px_indices 是按 K 个 cell 顺序串接的紧凑数组"——
		# 实际上 C++ 端 parse_csr_common 只校验 `last_first + last_count <= total_px`，
		# 完全允许 flat_px 大于 sum(cnt)。直接复用 `world.flat_px_indices_arr`（整图全 flat）
		# 并让 `_fpx_fast[k] = _src_first[cell_idx]`（指向整图 flat 里该 cell 的原始 offset），
		# CSR 语义等价。收益巨大：
		#   - 不再做 O(total_px) 的 int 拷贝循环（2400 cell × 30~100 px = 7.2万~24万 int/call）
		#   - 不再做 PackedInt32Array.resize（avoid GDScript 内存分配 + COW detach）
		#   - flat_px_indices_arr 是 WorldData 持有的稳定数组，传递只是引用计数 +1
		# 风险评估：
		#   - SoA 端用 `first==-1 / count==0` 表示空 cell —— 此时 _fpx_fast[k]=-1，C++ CNT[k]=0
		#     不会真正去 FIRST 访问；为防越界 sanity，在 _cnt==0 时把 _first 归零（安全索引）。
		var _src_flat: PackedInt32Array = world.flat_px_indices_arr
		var _src_first: PackedInt32Array = world.cell_first_px_arr
		var _src_count: PackedInt32Array = world.cell_px_count_arr
		var _k_fast: int = 0
		for _i in range(_span_fast.x, _span_fast.y):
			var _cell: HexCell = cells[_i]
			if _cell == null:
				continue
			var _idx: int = int(_cell.index)
			if _idx < 0 or _idx >= _soa_n:
				continue
			var _first: int = _src_first[_idx]
			var _cnt: int = _src_count[_idx]
			# 与 Dict 路径完全一致的语义：has(cell)=false → 视为"该 cell 无像素"。
			_ci_fast[_k_fast] = _idx
			# 空 cell：把 first 归零（避免 C++ parse_csr_common 看到 first=-1 误判 out-of-bounds）
			if _cnt <= 0 or _first < 0:
				_fpx_fast[_k_fast] = 0
				_pxc_fast[_k_fast] = 0
			else:
				_fpx_fast[_k_fast] = _first
				_pxc_fast[_k_fast] = _cnt
			# is_water：LUT 查表 / 字段 fallback。
			# 阶段 D：使用 is_water_render_lut（含 SEA_ICE）→ 不再需要 `or _t_idx == 20` 散点兜底；
			# fallback 路径保留 SEA_ICE 兜底以确保 LUT 不可用时（极不应触发）仍正确。
			if _have_lut:
				_iw_fast[_k_fast] = _iw_lut[_terrain_arr[_idx]]
			else:
				var _t_fb: int = int(_cell.terrain) & 0xFF
				_iw_fast[_k_fast] = MapData.terrain_is_water_u8(_t_fb)
			_k_fast += 1
		_ci_fast.resize(_k_fast)
		_fpx_fast.resize(_k_fast)
		_pxc_fast.resize(_k_fast)
		_iw_fast.resize(_k_fast)
		# flat_px_indices 直接传整图（不再拷贝；C++ 用 FIRST/CNT 索引即可）。
		return {
			"cell_indices": _ci_fast,
			"cell_first_px": _fpx_fast,
			"cell_px_count": _pxc_fast,
			"flat_px_indices": _src_flat,
			"cell_is_water": _iw_fast,
			"valid_count": _k_fast,
		}

	# ── Dict fallback path（旧行为，保留） ──────────────────────────────
	var lists: Dictionary
	if use_water_lists:
		lists = world.water_cell_pixel_lists if world != null else {}
	else:
		lists = world.cell_pixel_lists if world != null else {}

	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	var k_max: int = span.y - span.x
	var cell_indices: PackedInt32Array = PackedInt32Array()
	cell_indices.resize(k_max)
	var first_px: PackedInt32Array = PackedInt32Array()
	first_px.resize(k_max)
	var px_count: PackedInt32Array = PackedInt32Array()
	px_count.resize(k_max)
	var is_water_arr: PackedByteArray = PackedByteArray()
	is_water_arr.resize(k_max)

	var flat_px: PackedInt32Array = PackedInt32Array()
	# 估算 flat_px 容量：典型每 cell 30-100 px。先粗占 64×k_max；resize 仅在结尾一次校准。
	flat_px.resize(k_max * 64)
	var flat_w: int = 0
	var k: int = 0
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null or cell.index < 0:
			continue
		var pixels: PackedInt32Array
		if lists != null and lists.has(cell):
			pixels = lists.get(cell, PackedInt32Array())
		else:
			pixels = PackedInt32Array()
		# 跳过 0-pixel cell：cpp 端 byte fill 也是 no-op，但保留会拉长 K 影响 sig cache 命中。
		# 但 ecology pass 即使 0-pixel 也要更新 prev_*/transition_age 状态——这种情况
		# caller 会传 use_water_lists=false 同时确保 cells 已过滤 null。这里保留写入。
		cell_indices[k] = cell.index
		first_px[k] = flat_w
		px_count[k] = pixels.size()
		# sea-ice-render-source-unify 阶段 C：is_water = not passable_land，含 SEA_ICE 等所有水域。
		is_water_arr[k] = MapData.terrain_is_water_u8(int(cell.terrain))
		# 拷贝 pixel idx 到 flat 数组
		var nx: int = pixels.size()
		if flat_w + nx > flat_px.size():
			flat_px.resize(maxi(flat_w + nx, flat_px.size() * 2))
		for p in range(nx):
			flat_px[flat_w + p] = pixels[p]
		flat_w += nx
		k += 1

	cell_indices.resize(k)
	first_px.resize(k)
	px_count.resize(k)
	is_water_arr.resize(k)
	flat_px.resize(flat_w)

	return {
		"cell_indices": cell_indices,
		"cell_first_px": first_px,
		"cell_px_count": px_count,
		"flat_px_indices": flat_px,
		"cell_is_water": is_water_arr,
		"valid_count": k,
	}


# dynamic_cell_atlas C++ fast-path。返回 true = 成功消费，caller 直接 return。
# P1：增加 map 参数以启用 _pack_csr_for_cells 的 SoA fast path。

static func _try_cpp_dynamic_cell_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = baker._pack_csr_for_cells(world, cells, false, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		baker._report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	# [perf 2026-05-20 sig-diff-skip] 与 GDScript fallback 对齐：
	#   GD 路径 line 727: `if cache_valid and _last_dynamic_cell_sigs.get(cell, -1) == sig: continue`
	#   现在打包 prev_sigs 给 cpp，让 cpp 端命中 sig 一致就跳过 pixel fan-out（热点）。
	#   按 cell_indices 顺序回查 _last_dynamic_cell_sigs（key 是 HexCell 引用），
	#   不命中（首次/驱逐）填 -1（uint32 cast 不会等于任何真实 sig）。
	var cache_valid: bool = bool(ctx.get("cache_valid", false))
	var prev_sigs: PackedInt32Array = PackedInt32Array()
	if cache_valid and not baker._last_dynamic_cell_sigs.is_empty():
		prev_sigs.resize(k)
		var ci_pre: PackedInt32Array = csr["cell_indices"]
		var k_idx2: int = 0
		for i in range(span.x, span.y):
			var cell_pre: HexCell = cells[i]
			if cell_pre == null or cell_pre.index < 0:
				continue
			if k_idx2 >= k:
				break
			# csr 端按 cells 顺序写入，cell_indices[k_idx2] 必然 == cell_pre.index
			# （_pack_csr_for_cells 跳过 null/index<0，与本循环同步）。
			if cell_pre.index == ci_pre[k_idx2]:
				prev_sigs[k_idx2] = int(baker._last_dynamic_cell_sigs.get(cell_pre, -1))
			else:
				prev_sigs[k_idx2] = -1
			k_idx2 += 1
	var knobs := {
		"n_pix": n,
		"stride_bytes": 4,
		"atlas_buffer": baker._dynamic_cell_atlas_buf,
		"cell_indices": csr["cell_indices"],
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		"cell_is_water": csr["cell_is_water"],
		"cache_valid": cache_valid,
		"prev_sigs": prev_sigs,
	}
	var out: Dictionary = baker._world_ext.call("encode_dynamic_cell_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	# 取回 buffer（C++ 端通过 PackedByteArray 直写后返回；GDScript 端 PackedByteArray
	# 是 COW，需要重新赋值才能让"GDScript 后续 finalize 看到新 byte"）。
	baker._dynamic_cell_atlas_buf = out["atlas_buffer"]
	# 写回 sig cache（caller 路径下 _last_dynamic_cell_sigs[cell] = sig）。
	# C++ 没有 sig cache 命中 skip，所以所有进入的 cell 都视为 dirty 并刷 cache。
	var new_sigs: PackedInt32Array = out.get("new_sigs", PackedInt32Array())
	if new_sigs.size() == k:
		var ci: PackedInt32Array = csr["cell_indices"]
		var k_idx: int = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			if cell.index == ci[k_idx]:
				baker._last_dynamic_cell_sigs[cell] = new_sigs[k_idx]
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	baker._report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# ecology_visual_atlas C++ fast-path。
# P1：增加 map 参数以启用 _pack_csr_for_cells 的 SoA fast path。

static func _try_cpp_ecology_visual_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	var cache_valid: bool = bool(ctx.cache_valid)
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = baker._pack_csr_for_cells(world, cells, false, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		baker._report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	# 打包 prev_veg / prev_vitality / prev_transition（按 cells 顺序）
	var ci: PackedInt32Array = csr["cell_indices"]
	var prev_veg: PackedByteArray = PackedByteArray()
	prev_veg.resize(k)
	var prev_vit: PackedByteArray = PackedByteArray()
	prev_vit.resize(k)
	var prev_tr: PackedByteArray = PackedByteArray()
	prev_tr.resize(k)
	# 拿取 cell 的本 stride 之前的状态（首次访问时取 cur 作 fallback 与 GDScript loop 同义）
	# P1-E：改用 PackedByteArray SoA，cell.index 直查 O(1)，消除 Dict.get 哈希。
	# baseline 已在 ecology_visual_atlas_chunk_begin 的 cache_invalid 路径里灌入 cur，
	# 所以这里"首次访问 == 拿到 cur"的旧语义被透明保留；不再需要 cur_veg/cur_vit_byte fallback。
	var soa_n: int = baker._eco_veg_bytes_arr.size()
	var k_idx: int = 0
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null or cell.index < 0:
			continue
		if k_idx >= k:
			break
		var ci_idx: int = cell.index
		if ci_idx < soa_n:
			prev_veg[k_idx] = baker._eco_veg_bytes_arr[ci_idx]
			prev_vit[k_idx] = baker._eco_vitality_bytes_arr[ci_idx]
			prev_tr[k_idx] = baker._eco_transition_age_arr[ci_idx]
		else:
			# 边界 fallback：SoA 容量不足时退化到 cur（与旧 Dict.get(cell, cur) 等价）
			prev_veg[k_idx] = int(cell.vegetation) & 0xFF
			prev_vit[k_idx] = baker._q01_byte(float(cell.vegetation_vitality))
			prev_tr[k_idx] = 0
		k_idx += 1
	var knobs := {
		"n_pix": n,
		"stride_bytes": 4,
		"atlas_buffer": baker._ecology_visual_atlas_buf,
		"cell_indices": ci,
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		"cell_is_water": csr["cell_is_water"],
		"prev_veg": prev_veg,
		"prev_vitality": prev_vit,
		"prev_transition": prev_tr,
		"cache_valid": cache_valid,
		"terrain_lake": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice": int(TerrainType.TERRAIN.SEA_ICE),
		"veg_none": int(VegetationType.VEG.NONE),
	}
	var out: Dictionary = baker._world_ext.call("encode_ecology_visual_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	baker._ecology_visual_atlas_buf = out["atlas_buffer"]
	var new_veg: PackedByteArray = out.get("new_veg", PackedByteArray())
	var new_vit: PackedByteArray = out.get("new_vitality", PackedByteArray())
	var new_tr: PackedByteArray = out.get("new_transition", PackedByteArray())
	var new_sigs: PackedInt32Array = out.get("new_sigs", PackedInt32Array())
	if new_veg.size() == k and new_vit.size() == k and new_tr.size() == k:
		k_idx = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			# P1-E：辅助状态必须每 cell 都写（无论是否 dirty；GDScript loop 同理）
			# 走 SoA cell.index 直查；旧 Dict 不再维护。
			var ci_idx2: int = cell.index
			if ci_idx2 < baker._eco_veg_bytes_arr.size():
				baker._eco_veg_bytes_arr[ci_idx2] = int(new_veg[k_idx]) & 0xFF
				baker._eco_vitality_bytes_arr[ci_idx2] = int(new_vit[k_idx]) & 0xFF
				baker._eco_transition_age_arr[ci_idx2] = int(new_tr[k_idx]) & 0xFF
			# 维护 active decay set（保留 Dict 形态，外部消费方依赖 contract）
			if int(new_tr[k_idx]) > 0:
				baker._eco_active_decay_set[cell] = true
			else:
				baker._eco_active_decay_set.erase(cell)
			if k_idx < new_sigs.size():
				baker._last_ecology_visual_sigs[cell] = new_sigs[k_idx]
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	baker._report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# dyn_atlas_smooth C++ fast-path。需要 neighbor_indices（n_cells*6）+ neighbor_is_water（K*6）。

static func _try_cpp_dyn_smooth_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = baker._pack_csr_for_cells(world, cells, false, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		baker._report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	# 邻居 SoA：neighbor_indices 已由 MapData 持有（rebuild 时建好），尺寸 = cell_count * 6。
	var nb_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_method("neighbor_indices_packed") else PackedInt32Array()
	if nb_indices.size() <= 0:
		# 没有 neighbor SoA 不能走 cpp（fallback 到 GDScript 的 map.get_neighbors）
		report["fallback_reason"] = "neighbor_indices_missing"
		return false
	# neighbor_is_water：长度 K*6，按 cells 顺序对每个 dirty cell 的 6 邻居打包 is_water。
	# sea-ice-render-source-unify 阶段 C：语义从 passable_sea 切换为 is_water（含 SEA_ICE）。
	var nb_iws: PackedByteArray = PackedByteArray()
	nb_iws.resize(k * 6)
	# P1-D：K*6 邻居 is_water 走 terrain_arr + is_water_lut 查表，消除
	# K*6 次 `map.cell_at(ni)` (Dictionary 哈希反查) + 字段读取双开销。
	# fallback 路径保持原 cell_at + `not passable_land` 字段读取行为。
	var _smooth_terrain_arr: PackedByteArray = map.terrain_arr if map != null else PackedByteArray()
	# 阶段 D：渲染语义专用 LUT（含 SEA_ICE）取代 is_water_lut，与 cpp / fast path 对齐。
	var _smooth_iw_lut: PackedByteArray = MapData.is_water_render_lut()
	var _smooth_have_lut: bool = _smooth_terrain_arr.size() > 0 \
			and _smooth_iw_lut.size() >= 256 \
			and _smooth_terrain_arr.size() == map.cell_count()
	var k_idx: int = 0
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null or cell.index < 0:
			continue
		if k_idx >= k:
			break
		var ci_idx: int = cell.index
		var base_g: int = ci_idx * 6
		var base_l: int = k_idx * 6
		if _smooth_have_lut:
			# Fast path：纯 PackedArray 索引；is_water_render_lut 已含 SEA_ICE，零分支。
			for d in range(6):
				var ni_f: int = nb_indices[base_g + d] if base_g + d < nb_indices.size() else -1
				if ni_f >= 0 and ni_f < _smooth_terrain_arr.size():
					nb_iws[base_l + d] = _smooth_iw_lut[_smooth_terrain_arr[ni_f]]
				else:
					nb_iws[base_l + d] = 0
		else:
			# Fallback：cell_at + `not passable_land + SEA_ICE 兜底` 字段读取。
			for d in range(6):
				var ni: int = nb_indices[base_g + d] if base_g + d < nb_indices.size() else -1
				var nb_iw: int = 0
				if ni >= 0:
					var nb_cell: HexCell = map.cell_at(ni)
					if nb_cell != null:
						var _t_nb: int = int(nb_cell.terrain) & 0xFF
						if MapData.terrain_is_water(_t_nb):
							nb_iw = 1
				nb_iws[base_l + d] = nb_iw
		k_idx += 1
	var knobs := {
		"n_pix": n,
		"stride_bytes": 4,
		"atlas_buffer": baker._dyn_atlas_smooth_buf,
		"cell_indices": csr["cell_indices"],
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		"cell_is_water": csr["cell_is_water"],
		"neighbor_indices": nb_indices,
		"neighbor_is_water": nb_iws,
	}
	var out: Dictionary = baker._world_ext.call("encode_dyn_smooth_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	baker._dyn_atlas_smooth_buf = out["atlas_buffer"]
	# 写回 hood-aware sig cache（FNV-1a hash, 与 GDScript 1:1）
	var new_sigs: PackedInt32Array = out.get("new_sigs", PackedInt32Array())
	if new_sigs.size() == k:
		k_idx = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			baker._last_dyn_smooth_cell_sigs[cell] = new_sigs[k_idx]
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	baker._report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# ice_state_atlas C++ fast-path。caller 负责只把水域 cell 喂入；cpp 端不再过滤。
# P1：增加 map 参数（即便 ice 走 use_water_lists=true → Dict fallback 路径，
# 也保持 4 个 try_cpp_* 的签名一致，便于阅读）。

static func _try_cpp_ice_state_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	var n: int = int(ctx.n)
	if n <= 0:
		report["fallback_reason"] = "empty_texture"
		return false
	# ice 走 water_cell_pixel_lists（caller 已交集水域 cell；fallback 时 caller 传非水域 cell
	# 也安全：cpp 端按 _q01_byte_ice 对 sea_ice_frac 量化，陆地 cell 该字段恒 0 → byte=0）。
	var use_water: bool = bool(ctx.get("use_water_lists", false))
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	var csr: Dictionary = baker._pack_csr_for_cells(world, cells, use_water, n, span.x, span.y, map)
	var k: int = int(csr.get("valid_count", 0))
	if k <= 0:
		baker._report_inc(report, "empty_calls")
		report["path"] = "cpp_empty"
		report["fallback_reason"] = ""
		return true
	var knobs := {
		"n_pix": n,
		"stride_bytes": 1,
		"atlas_buffer": baker._ice_state_buf,
		"cell_indices": csr["cell_indices"],
		"cell_first_px": csr["cell_first_px"],
		"cell_px_count": csr["cell_px_count"],
		"flat_px_indices": csr["flat_px_indices"],
		# ice pass 不需要 is_water，但为了 CSR parse 共享 sanity（C++ 端会校验 K 匹配）
		# 仍然把 cell_is_water 字段塞进去（C++ ice 路径不读取）。
		"cell_is_water": csr["cell_is_water"],
	}
	var out: Dictionary = baker._world_ext.call("encode_ice_state_atlas", knobs)
	if bool(out.get("fallback", true)):
		report["fallback_reason"] = str(out.get("reason", "cpp_fallback"))
		return false
	baker._ice_state_buf = out["atlas_buffer"]
	# 写回 _last_ice_state_cell_bytes
	var new_bytes: PackedByteArray = out.get("new_bytes", PackedByteArray())
	if new_bytes.size() == k:
		var k_idx: int = 0
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or cell.index < 0:
				continue
			if k_idx >= k:
				break
			baker._last_ice_state_cell_bytes[cell] = int(new_bytes[k_idx])
			k_idx += 1
	report.dirty_cells = int(report.dirty_cells) + k
	report.pixels_written = int(report.pixels_written) + int(out.get("pixels_written", 0))
	baker._report_inc(report, "cpp_calls")
	report["path"] = "cpp"
	report["fallback_reason"] = ""
	return true


# plan/sim-2ms-simd-dirty-budget：enum atlas upload 节流核心判定。
# dots-flag-prune-pr1 round 2 (2026-05-22): use_atlas_dirty_throttle flag 已删除——
# 节流逻辑整体退役，函数退化为透明 passthrough（恒返 true 表示每次都 flush）。
# axis / dirty_cells 参数保留以兼容 caller 签名。
