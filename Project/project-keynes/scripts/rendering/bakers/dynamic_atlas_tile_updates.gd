extends RefCounted

## Stages dynamic and ecology cell atlas updates and finalizes dirty-tile uploads.


static func rebake_dynamic_cell_atlas_only(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 间接寻址 dyn_lut 接管，跳过逐像素重烤。
	if DCFeatureFlags.cell_indirection_active():
		return baker._indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容（synthesize_world 初始烘走这条）。
	# 走完整 chunk_begin → chunk_step(all_cells) → chunk_finalize 三段。
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
	var ctx: Dictionary = baker.dynamic_cell_atlas_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	baker.dynamic_cell_atlas_chunk_step(map, world, ctx, map.all_cells(), report)
	baker.dynamic_cell_atlas_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── dynamic_cell_atlas chunk API ─────────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 climate_profile.cpp_atlas_pipeline_enabled = true 时，本函数 + chunk_step
# + chunk_finalize 组合不会被调用：dynamic_visual_atlas_upload_system 直接调
# DCWorldExt.run_atlas_pipeline_step 拿 atlas_buffers 后做 ImageTexture.update。
# 此函数仅在 flag=false（fallback / 调试 / bit-equal 测试）时保留可用。

static func dynamic_cell_atlas_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (baker._dynamic_cell_atlas_cache_size == Vector2i(W, H) \
			and baker._dynamic_cell_atlas_buf.size() == n * 4)
	if not cache_valid:
		baker._dynamic_cell_atlas_buf = PackedByteArray()
		baker._dynamic_cell_atlas_buf.resize(n * 4)
		# 全 0 起步：shader 端 dyn_valid = step(0.02, dyn_temp) 在未写入时退回 derived 路径，
		# 避免把 G/A 通道的"中性默认"误判为真实数据。
		baker._dynamic_cell_atlas_buf.fill(0)
		baker._dynamic_cell_atlas_cache_size = Vector2i(W, H)
		baker._last_dynamic_cell_sigs = {}
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	return ctx



static func dynamic_cell_atlas_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		baker._report_inc(report, "empty_calls")
		return
	var cpp_reason: String = baker._cpp_atlas_encode_disabled_reason(&"encode_dynamic_cell_atlas")
	if cpp_reason == "":
		if baker._try_cpp_dynamic_cell_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	baker._report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null:
			continue
		var sig: int = baker._dynamic_cell_signature(cell)
		if cache_valid and int(baker._last_dynamic_cell_sigs.get(cell, -1)) == sig:
			continue
		baker._last_dynamic_cell_sigs[cell] = sig
		var r: int = sig & 0xFF
		var g: int = (sig >> 8) & 0xFF
		var b: int = (sig >> 16) & 0xFF
		var a: int = (sig >> 24) & 0xFF
		var pixels: PackedInt32Array = PackedInt32Array()
		if use_pixel_lists:
			pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
		for px_idx in pixels:
			if px_idx < 0 or px_idx >= n:
				continue
			var base_px: int = px_idx * 4
			baker._dynamic_cell_atlas_buf[base_px] = r
			baker._dynamic_cell_atlas_buf[base_px + 1] = g
			baker._dynamic_cell_atlas_buf[base_px + 2] = b
			baker._dynamic_cell_atlas_buf[base_px + 3] = a
		report.dirty_cells = int(report.dirty_cells) + 1
		report.pixels_written = int(report.pixels_written) + pixels.size()



static func dynamic_cell_atlas_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.dynamic_cell_atlas_tex == null
	world.dynamic_cell_atlas_buffer = baker._dynamic_cell_atlas_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._dynamic_cell_atlas_buf)
		if world.dynamic_cell_atlas_tex != null and world.dynamic_cell_atlas_tex.get_size() == Vector2(float(W), float(H)):
			world.dynamic_cell_atlas_tex.update(img)
		else:
			world.dynamic_cell_atlas_tex = ImageTexture.create_from_image(img)


static func rebake_ecology_visual_atlas_only(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	# [cell-indirect single-path] flag 开 → 间接寻址 eco_lut 接管，跳过逐像素重烤。
	if DCFeatureFlags.cell_indirection_active():
		return baker._indirection_skip_atlas_report()
	# Thin wrapper：保持旧签名 100% 兼容。chunk_step 走 all_cells，一次性完成。
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
	var ctx: Dictionary = baker.ecology_visual_atlas_chunk_begin(map, world)
	if not bool(ctx.get("prepared", false)):
		return report
	baker.ecology_visual_atlas_chunk_step(map, world, ctx, map.all_cells(), report)
	baker.ecology_visual_atlas_chunk_finalize(world, ctx, report)
	report.elapsed_ms = float(Time.get_ticks_usec() - t_us) / 1000.0
	return report


# ─── ecology_visual_atlas chunk API ───────────────────────────────────────────
# [deprecated 2026-05-20 atlas-pipeline-cpp]
# 当 cpp_atlas_pipeline_enabled = true 时不会被调用（DOTS C++ pipeline 取代）。
# fallback 路径仍可用；首次 cpp 路径启用前需调 migrate_eco_persistent_from_gd
# 把 _eco_active_decay_set / _eco_transition_age_arr 灌到 C++。

static func ecology_visual_atlas_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	var ctx: Dictionary = {"prepared": false}
	if map == null or world == null:
		return ctx
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if n <= 0:
		return ctx
	var cache_valid: bool = (baker._ecology_visual_atlas_cache_size == Vector2i(W, H) \
			and baker._ecology_visual_atlas_buf.size() == n * 4)
	if not cache_valid:
		baker._ecology_visual_atlas_buf = PackedByteArray()
		baker._ecology_visual_atlas_buf.resize(n * 4)
		baker._ecology_visual_atlas_buf.fill(0)
		baker._ecology_visual_atlas_cache_size = Vector2i(W, H)
		baker._last_ecology_visual_sigs = {}
		baker._last_ecology_veg_bytes = {}
		baker._last_ecology_vitality_bytes = {}
		baker._ecology_transition_age_bytes = {}
		# P1-E：SoA 镜像同步 invalid。按 cell.index 寻址，所以 size = map.cell_count()。
		# 首帧 baseline 设为 cur（cell.vegetation / vitality），等价于旧的
		# Dict.get(cell, cur) 首次 fallback 语义；transition_age 清 0。
		# 该 O(N_cells) 灌注一次性成本远低于后续每 stride K*Dict.get 的累计开销。
		var cell_count: int = map.cell_count()
		if cell_count <= 0:
			cell_count = map.all_cells().size()
		baker._eco_veg_bytes_arr = PackedByteArray()
		baker._eco_veg_bytes_arr.resize(cell_count)
		baker._eco_vitality_bytes_arr = PackedByteArray()
		baker._eco_vitality_bytes_arr.resize(cell_count)
		baker._eco_transition_age_arr = PackedByteArray()
		baker._eco_transition_age_arr.resize(cell_count)
		baker._eco_transition_age_arr.fill(0)
		var _all_cells_baseline: Array = map.all_cells()
		for _bc in _all_cells_baseline:
			if _bc == null or _bc.index < 0 or _bc.index >= cell_count:
				continue
			baker._eco_veg_bytes_arr[_bc.index] = int(_bc.vegetation) & 0xFF
			baker._eco_vitality_bytes_arr[_bc.index] = baker._q01_byte(float(_bc.vegetation_vitality))
		baker._eco_soa_initialized = true
		baker._eco_active_decay_set = {}  # plan/dirty-push-atlas-encode 阶段 E：cache 失效时一并清空
	ctx["prepared"] = true
	ctx["W"] = W
	ctx["H"] = H
	ctx["n"] = n
	ctx["cache_valid"] = cache_valid
	ctx["use_pixel_lists"] = world.cell_pixel_lists != null and not world.cell_pixel_lists.is_empty()
	return ctx



static func ecology_visual_atlas_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var span: Vector2i = baker._cell_range(cells, start_idx, end_idx)
	if span.x >= span.y:
		baker._report_inc(report, "empty_calls")
		return
	var cpp_reason: String = baker._cpp_atlas_encode_disabled_reason(&"encode_ecology_visual_atlas")
	if cpp_reason == "":
		if baker._try_cpp_ecology_visual_atlas_encode(map, world, ctx, cells, report, span.x, span.y):
			return
		cpp_reason = str(report.get("fallback_reason", "cpp_fallback"))
	report["path"] = "gdscript"
	if cpp_reason != "":
		report["fallback_reason"] = cpp_reason
	baker._report_inc(report, "gd_calls")
	var n: int = int(ctx.n)
	var cache_valid: bool = bool(ctx.cache_valid)
	var use_pixel_lists: bool = bool(ctx.use_pixel_lists)
	for i in range(span.x, span.y):
		var cell: HexCell = cells[i]
		if cell == null:
			continue
		var cur_veg: int = int(cell.vegetation) & 0xFF
		var cur_vitality_byte: int = baker._q01_byte(float(cell.vegetation_vitality))
		# P1-E：SoA cell.index 直查替代 Dict.get；index 越界时退回 cur（baseline 等价）
		var ci_idx_gd: int = cell.index
		var soa_n_gd: int = baker._eco_veg_bytes_arr.size()
		var prev_veg: int
		var prev_vitality_byte: int
		var transition_age: int
		if ci_idx_gd >= 0 and ci_idx_gd < soa_n_gd:
			prev_veg = baker._eco_veg_bytes_arr[ci_idx_gd]
			prev_vitality_byte = baker._eco_vitality_bytes_arr[ci_idx_gd]
			transition_age = baker._eco_transition_age_arr[ci_idx_gd]
		else:
			prev_veg = cur_veg
			prev_vitality_byte = cur_vitality_byte
			transition_age = 0
		if cache_valid:
			if cur_veg != prev_veg:
				transition_age = 255
			elif transition_age > 0:
				transition_age = maxi(0, transition_age - 18)
		else:
			transition_age = 0

		var sig: int = baker._ecology_visual_signature(cell, transition_age, prev_vitality_byte)
		# P1-E：辅助状态必须每 cell 都写（无论是否 dirty），否则 transition_age 衰减会丢。
		# 走 SoA cell.index 直查；旧 Dict 不再维护。
		if ci_idx_gd >= 0 and ci_idx_gd < soa_n_gd:
			baker._eco_veg_bytes_arr[ci_idx_gd] = cur_veg
			baker._eco_vitality_bytes_arr[ci_idx_gd] = cur_vitality_byte
			baker._eco_transition_age_arr[ci_idx_gd] = transition_age & 0xFF
		# plan/dirty-push-atlas-encode 阶段 E：维护 active decay set。
		# 该 set 让调度器在下 stride 即使没收到 sim dirty，也能把"transition_age
		# 还在衰减"的 cell 重新喂进 chunk_step，避免衰减卡在 stale byte。
		# 注意：cache_invalid 路径下 transition_age 被强制清 0（上方 else 分支），
		# 这里 erase 是正确的。
		if transition_age > 0:
			baker._eco_active_decay_set[cell] = true
		else:
			baker._eco_active_decay_set.erase(cell)
		if cache_valid and int(baker._last_ecology_visual_sigs.get(cell, -1)) == sig:
			continue
		baker._last_ecology_visual_sigs[cell] = sig
		var r: int = sig & 0xFF
		var g: int = (sig >> 8) & 0xFF
		var b: int = (sig >> 16) & 0xFF
		var a: int = (sig >> 24) & 0xFF
		var pixels: PackedInt32Array = PackedInt32Array()
		if use_pixel_lists:
			pixels = world.cell_pixel_lists.get(cell, PackedInt32Array())
		for px_idx in pixels:
			if px_idx < 0 or px_idx >= n:
				continue
			var base_px: int = px_idx * 4
			baker._ecology_visual_atlas_buf[base_px] = r
			baker._ecology_visual_atlas_buf[base_px + 1] = g
			baker._ecology_visual_atlas_buf[base_px + 2] = b
			baker._ecology_visual_atlas_buf[base_px + 3] = a
		report.dirty_cells = int(report.dirty_cells) + 1
		report.pixels_written = int(report.pixels_written) + pixels.size()



static func ecology_visual_atlas_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	if not bool(ctx.get("prepared", false)):
		return
	var W: int = int(ctx.W)
	var H: int = int(ctx.H)
	report.prepared = true
	report.dirty = int(report.dirty_cells) > 0 or world.ecology_visual_atlas_tex == null
	world.ecology_visual_atlas_buffer = baker._ecology_visual_atlas_buf
	if bool(report.dirty):
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._ecology_visual_atlas_buf)
		if world.ecology_visual_atlas_tex != null and world.ecology_visual_atlas_tex.get_size() == Vector2(float(W), float(H)):
			world.ecology_visual_atlas_tex.update(img)
		else:
			world.ecology_visual_atlas_tex = ImageTexture.create_from_image(img)
