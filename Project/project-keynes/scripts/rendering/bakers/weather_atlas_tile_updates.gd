extends RefCounted

## Stages smooth weather and sea-ice atlas updates and publishes finalized tiles.

const DCAtlasEncoders = preload("res://scripts/rendering/bakers/atlas_encoders.gd")

static func rebake_dyn_atlas_smooth(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 间接寻址 dyn_lut 跨 cell 平滑接管，跳过 box-blur 重烤。
	if DCFeatureFlags.cell_indirection_active():
		return baker._indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容。
	var report := {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
	}
	if map == null or world == null:
		return report
	var t_us: int = Time.get_ticks_usec()
	var ctx: Dictionary = baker.dyn_atlas_smooth_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	baker.dyn_atlas_smooth_chunk_step(map, world, ctx, map.all_cells(), report)
	baker.dyn_atlas_smooth_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── dyn_atlas_smooth chunk API ───────────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 cpp_atlas_pipeline_enabled = true 时不会被调用（DOTS C++ pipeline 取代）。
# fallback 路径保留 1 跳邻居膨胀逻辑（baker_dirty_helpers.dilate_dirty_one_hop）。

static func dyn_atlas_smooth_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (baker._dyn_atlas_smooth_cache_size == Vector2i(W, H) \
			and baker._dyn_atlas_smooth_buf.size() == n * 4)
	if not cache_valid:
		baker._dyn_atlas_smooth_buf = PackedByteArray()
		baker._dyn_atlas_smooth_buf.resize(n * 4)
		# 同 dynamic_cell_atlas：全 0 起步，shader 端 dyn_valid step 退回 derived 路径。
		baker._dyn_atlas_smooth_buf.fill(0)
		baker._dyn_atlas_smooth_cache_size = Vector2i(W, H)
		baker._last_dyn_smooth_cell_sigs = {}
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	# 复用 _last_dynamic_cell_sigs 加速邻居 sig 查询：调度器保证 dyn_smooth 跑在
	# dynamic_cell phase 完整完成之后，dict 内值就是本 stride 最新。
	ctx["cache_dynamic_fresh"] = not baker._last_dynamic_cell_sigs.is_empty()
	return ctx



static func dyn_atlas_smooth_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		baker._report_inc(report, "empty_calls")
		return
	var cpp_reason: String = baker._cpp_atlas_encode_disabled_reason(&"encode_dyn_smooth_atlas")
	if cpp_reason == "":
		if baker._try_cpp_dyn_smooth_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	baker._report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	var cache_dynamic_fresh: bool = bool(ctx.get("cache_dynamic_fresh", false))
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null:
			continue
		# 中心 sig（与 dynamic_cell_atlas 完全相同的 R/G/B/A 量化）。
		var c_sig: int = baker._dynamic_cell_signature(cell)
		var cr: int = c_sig & 0xFF
		var cg: int = (c_sig >> 8) & 0xFF
		var cb: int = (c_sig >> 16) & 0xFF
		var ca: int = (c_sig >> 24) & 0xFF
		# 邻居均值（最多 6 个；缺失方向不补 0，按实际邻居数取均值，避免边界 cell 被压暗）。
		var nr: int = 0
		var ng: int = 0
		var nb: int = 0
		var na: int = 0
		var nc: int = 0
		var na_c: int = 0  # A 通道独立邻居计数：仅累加非海域邻居（D 项修复）
		# 同时累积 neighbor-aware cache sig：FNV-1a 32-bit，吃 7×4=28 bytes。
		var hood_h: int = 0x811C9DC5
		hood_h = ((hood_h ^ (c_sig & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		hood_h = ((hood_h ^ ((c_sig >> 8) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		hood_h = ((hood_h ^ ((c_sig >> 16) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		hood_h = ((hood_h ^ ((c_sig >> 24) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
		for nb_cell in map.get_neighbors(cell):
			if nb_cell == null:
				continue
			# 复用 dynamic_cell phase 刚写好的 cache；冷启用 fallback。
			var n_sig: int
			if cache_dynamic_fresh:
				n_sig = int(baker._last_dynamic_cell_sigs.get(nb_cell, -1))
				if n_sig == -1:
					n_sig = baker._dynamic_cell_signature(nb_cell)
			else:
				n_sig = baker._dynamic_cell_signature(nb_cell)
			nr += n_sig & 0xFF
			ng += (n_sig >> 8) & 0xFF
			nb += (n_sig >> 16) & 0xFF
			nc += 1
			# A 通道水陆分裂语义（sea-ice-render-source-unify 阶段 C）：
			#   - 中心是陆格：A=vitality，仅累加陆地邻居（sea-ice 邻居恒持 ice_byte，
			#     若纳入会污染陆地 vitality blur）；保持 2026-05-21 既有修复语义。
			#   - 中心是水格：A=sea_ice_fraction，仅累加水域邻居（陆地邻居 A=vit
			#     与海冰物理无关，纳入会拖偏冰边界）。陆地邻居恒持 vit，对中心海
			#     冰 box blur 是噪声源，必须排除。
			# 关键：水陆分类必须用 is_water 语义（含 SEA_ICE），不能用 passable_sea，
			# 否则 SEA_ICE 邻居会被错归"陆地邻居"导致 A 通道污染。
			# SAME_SOURCE：gdext/src/world_ext.cpp::encode_dyn_smooth_atlas /
			#              monolithic atlas pipeline smooth phase。
			var center_is_water: bool = MapData.terrain_is_water(int(cell.terrain))
			var nb_is_water: bool = MapData.terrain_is_water(int(nb_cell.terrain))
			if center_is_water:
				if nb_is_water:
					na += (n_sig >> 24) & 0xFF
					na_c += 1
			else:
				if not nb_is_water:
					na += (n_sig >> 24) & 0xFF
					na_c += 1
			hood_h = ((hood_h ^ (n_sig & 0xFF)) * 0x01000193) & 0xFFFFFFFF
			hood_h = ((hood_h ^ ((n_sig >> 8) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
			hood_h = ((hood_h ^ ((n_sig >> 16) & 0xFF)) * 0x01000193) & 0xFFFFFFFF
			hood_h = ((hood_h ^ ((n_sig >> 24) & 0xFF)) * 0x01000193) & 0xFFFFFFFF

		# Cache 比对：用 neighbor-aware hood_h（不再用 smooth_sig output byte）。
		if cache_valid and int(baker._last_dyn_smooth_cell_sigs.get(cell, -2)) == hood_h:
			continue
		baker._last_dyn_smooth_cell_sigs[cell] = hood_h

		# Cache miss → 真正算 smooth 输出 byte 并写 buffer。
		var or_: int
		var og: int
		var ob: int
		var oa: int
		if nc > 0:
			# 中心 0.5 + 邻居均值 0.5（R/G）
			# 2026-05-21 修复：B 通道（snow_cover）是阈值型现象，不做邻居平均，
			# 否则单格 95% 雪盖会被无雪邻居拖到 ~47.5% 后被 shader 后段压不可见。
			# A 通道仅平均非海域邻居（见上面 for 循环内的 SAME_SOURCE 注释）。
			# SAME_SOURCE 见 gdext/src/world_ext.cpp::encode_dyn_smooth_atlas。
			or_ = clampi((cr + nr / nc) / 2, 0, 255)
			og = clampi((cg + ng / nc) / 2, 0, 255)
			ob = clampi(cb, 0, 255)  # snow passthrough：保留 cell 真值
			if na_c > 0:
				oa = clampi((ca + na / na_c) / 2, 0, 255)
			else:
				oa = clampi(ca, 0, 255)  # 全是海邻 → 退回中心值
		else:
			or_ = cr
			og = cg
			ob = cb
			oa = ca
		var pixels: PackedInt32Array = PackedInt32Array()
		if use_pixel_lists:
			pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
		# [TEMP DIAG sea-ice GD-smo-write]
		if cell != null and MapData.terrain_is_water(int(cell.terrain)) and float(cell.sea_ice_fraction) > 0.5:
			if not Engine.has_meta("_diag_gd_smo_dumped"):
				Engine.set_meta("_diag_gd_smo_dumped", 0)
			var _diag_n: int = int(Engine.get_meta("_diag_gd_smo_dumped"))
			if _diag_n < 8:
				print("[GD-SMO-WRITE] cell=", cell, " ICE=", float(cell.sea_ice_fraction),
					" ca=", ca, " oa=", oa, " nc=", nc, " na_c=", na_c, " na=", na,
					" px0=", (pixels[0] if pixels.size() > 0 else -1))
				Engine.set_meta("_diag_gd_smo_dumped", _diag_n + 1)
		for px_idx in pixels:
			if px_idx < 0 or px_idx >= n:
				continue
			var base_px: int = px_idx * 4
			baker._dyn_atlas_smooth_buf[base_px] = or_
			baker._dyn_atlas_smooth_buf[base_px + 1] = og
			baker._dyn_atlas_smooth_buf[base_px + 2] = ob
			baker._dyn_atlas_smooth_buf[base_px + 3] = oa
		report.dirty_cells = int(report.dirty_cells) + 1
		report.pixels_written = int(report.pixels_written) + pixels.size()



static func dyn_atlas_smooth_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.dyn_atlas_smooth_tex == null
	world.dyn_atlas_smooth_buffer = baker._dyn_atlas_smooth_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._dyn_atlas_smooth_buf)
		if world.dyn_atlas_smooth_tex != null and world.dyn_atlas_smooth_tex.get_size() == Vector2(float(W), float(H)):
			world.dyn_atlas_smooth_tex.update(img)
		else:
			world.dyn_atlas_smooth_tex = ImageTexture.create_from_image(img)


# ice_state_atlas：R8，每像素 = 该 cell.sea_ice_frac × 255。仅水域 cell 写非零，
# 陆地恒 0。shader 据此替换原 lat-driven 静态 ice mask（病灶 A 解药）。
# 走 cell-level byte dirty 缓存（与 bake_sea_ice_fraction_only 同构但本路径独立，
# 因为目标 buffer 不同 + shader uniform 不同）。

static func rebake_ice_state_atlas(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 海冰随 dyn_lut.a 迁移，ice_state_atlas 无消费者，跳过。
	if DCFeatureFlags.cell_indirection_active():
		return baker._indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容。
	var report := {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
	}
	if map == null or world == null:
		return report
	var t_us: int = Time.get_ticks_usec()
	var ctx: Dictionary = baker.ice_state_atlas_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	# Cell 来源：优先 water_cell_pixel_lists.keys()；fallback 走 all_cells + 过滤。
	var cells = baker.ice_state_atlas_default_cell_source(map, world, ctx)
	baker.ice_state_atlas_chunk_step(map, world, ctx, cells, report)
	baker.ice_state_atlas_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── ice_state_atlas chunk API ────────────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 cpp_atlas_pipeline_enabled = true 时不会被调用（DOTS C++ pipeline 取代）。
# fallback 路径仍走 water_cell_pixel_lists（cpp 路径走整图 SoA + cell_psea 过滤，
# bit-equal 因陆地 cell sea_ice_frac=0 → byte=0 而成立）。

static func ice_state_atlas_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (baker._ice_state_cache_size == Vector2i(W, H) \
			and baker._ice_state_buf.size() == n)
	if not cache_valid:
		baker._ice_state_buf = PackedByteArray()
		baker._ice_state_buf.resize(n)
		baker._ice_state_buf.fill(0)
		baker._ice_state_cache_size = Vector2i(W, H)
		baker._last_ice_state_cell_bytes = {}
	var lists: Dictionary = world.water_cell_pixel_lists
	var use_water_lists: bool = lists != null and not lists.is_empty()
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_water_lists"] = use_water_lists
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	return ctx


# 默认 cell 数据源：根据 ctx 选择 water_cell_pixel_lists 或 all_cells。
# 调度器（DynamicVisualAtlasUploadSystem）会在 phase 入口快照这份序列做切片。

static func ice_state_atlas_default_cell_source(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary) -> Array:
	if not bool(ctx.get("prepared", false)):
		return []
	if bool(ctx.use_water_lists):
		return world.water_cell_pixel_lists.keys()
	return map.all_cells()



static func ice_state_atlas_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		baker._report_inc(report, "empty_calls")
		return
	var cpp_reason: String = baker._cpp_atlas_encode_disabled_reason(&"encode_ice_state_atlas")
	if cpp_reason == "":
		if baker._try_cpp_ice_state_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	baker._report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_water_lists: bool = bool(ctx.use_water_lists)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	if use_water_lists:
		var lists: Dictionary = world.water_cell_pixel_lists
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null:
				continue
			var byte_v: int = baker._q01_byte_ice(float(cell.sea_ice_fraction))
			if cache_valid and int(baker._last_ice_state_cell_bytes.get(cell, -1)) == byte_v:
				continue
			baker._last_ice_state_cell_bytes[cell] = byte_v
			var pixels: PackedInt32Array = lists.get(cell, PackedInt32Array())
			for px_idx in pixels:
				if px_idx < 0 or px_idx >= n:
					continue
				baker._ice_state_buf[px_idx] = byte_v
			report.dirty_cells = int(report.dirty_cells) + 1
			report.pixels_written = int(report.pixels_written) + pixels.size()
	else:
		# Fallback：扫所有 cell 但只处理水格。
		# sea-ice-render-source-unify 阶段 C：用 is_water (not passable_land) 而非
		# passable_sea，否则 SEA_ICE cell 会被漏掉（passable_sea=false），
		# ice_state atlas 拿不到它的 sea_ice_fraction。与 cpp monolithic
		# pipeline cell_is_ice_renderable 语义一致。
		for i in range(span.x, span.y):
			var cell: HexCell = cells[i]
			if cell == null or not MapData.terrain_is_water(int(cell.terrain)):
				continue
			var byte_v: int = baker._q01_byte_ice(float(cell.sea_ice_fraction))
			if cache_valid and int(baker._last_ice_state_cell_bytes.get(cell, -1)) == byte_v:
				continue
			baker._last_ice_state_cell_bytes[cell] = byte_v
			var pixels: PackedInt32Array = PackedInt32Array()
			if use_pixel_lists:
				pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
			for px_idx in pixels:
				if px_idx < 0 or px_idx >= n:
					continue
				baker._ice_state_buf[px_idx] = byte_v
			report.dirty_cells = int(report.dirty_cells) + 1
			report.pixels_written = int(report.pixels_written) + pixels.size()



static func ice_state_atlas_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.ice_state_tex == null
	world.ice_state_buffer = baker._ice_state_buf
	if bool(report.dirty):
		world.ice_state_tex = DCAtlasEncoders.upload_single_channel(
			baker._ice_state_buf, W, H, world.ice_state_tex)
