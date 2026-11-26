extends RefCounted

## Selects the native enum-atlas path and applies sparse enum-axis patches.


static func _enum_atlas_cpp_pack_disabled_reason(baker: MapBaker) -> String:
	if baker._world_ext == null:
		return "cpp_gate_no_world_ext"
	return ""



static func _enum_atlas_cpp_pack_enabled(baker: MapBaker) -> bool:
	return baker._enum_atlas_cpp_pack_disabled_reason() == ""



static func _ensure_world_cell_pixel_csr(baker: MapBaker, map: MapData, world: WorldData) -> bool:
	if world == null:
		return false
	if not world.cell_first_px_arr.is_empty() and not world.cell_px_count_arr.is_empty() \
			and not world.flat_px_indices_arr.is_empty():
		return true
	if world.cell_pixel_lists.is_empty():
		return false
	var n_cells: int = map.cell_count() if map != null else 0
	if n_cells <= 0:
		for cell_key in world.cell_pixel_lists.keys():
			var cell: HexCell = cell_key
			if cell != null:
				n_cells = maxi(n_cells, int(cell.index) + 1)
	if n_cells <= 0:
		return false
	var first_px_arr := PackedInt32Array()
	var px_count_arr := PackedInt32Array()
	first_px_arr.resize(n_cells)
	px_count_arr.resize(n_cells)
	for i in range(n_cells):
		first_px_arr[i] = -1
		px_count_arr[i] = 0
	var total_px: int = 0
	for cell_key in world.cell_pixel_lists.keys():
		var pixels: PackedInt32Array = world.cell_pixel_lists[cell_key]
		total_px += pixels.size()
	if total_px <= 0:
		return false
	var flat_arr := PackedInt32Array()
	flat_arr.resize(total_px)
	var flat_w: int = 0
	for cell_key in world.cell_pixel_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		var idx: int = int(cell.index)
		if idx < 0 or idx >= n_cells:
			continue
		var pixels: PackedInt32Array = world.cell_pixel_lists[cell_key]
		var count: int = pixels.size()
		if count <= 0:
			continue
		first_px_arr[idx] = flat_w
		px_count_arr[idx] = count
		for p in range(count):
			flat_arr[flat_w + p] = pixels[p]
		flat_w += count
	if flat_w <= 0:
		return false
	if flat_w != total_px:
		flat_arr.resize(flat_w)
	world.cell_first_px_arr = first_px_arr
	world.cell_px_count_arr = px_count_arr
	world.flat_px_indices_arr = flat_arr
	return true



static func _try_cpp_enum_axis_patch(baker: MapBaker, map: MapData, world: WorldData, axis: String, report_t0_us: int) -> bool:
	baker._enum_atlas_cpp_skip_reason = ""
	if world == null:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_world_null"
		return false
	var gate_reason: String = baker._enum_atlas_cpp_pack_disabled_reason()
	if gate_reason != "":
		baker._enum_atlas_cpp_skip_reason = gate_reason
		return false
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var pix_count: int = W * H
	if pix_count <= 0:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_bad_size"
		return false
	if baker._enum_atlas_data_size != Vector2i(W, H) or baker._enum_atlas_data.size() != pix_count * 4:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_enum_data_invalid"
		return false
	if not baker._ensure_world_cell_pixel_csr(map, world):
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_csr_empty"
		return false
	var run_cover: bool = axis == "cover"
	var run_vegetation: bool = axis == "vegetation"
	if not run_cover and not run_vegetation:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_axis_unsupported"
		return false
	var patch_t0_us: int = Time.get_ticks_usec()
	var knobs: Dictionary = {
		"n_cells": world.cell_first_px_arr.size(),
		"n_pix": pix_count,
		"cell_first_px": world.cell_first_px_arr,
		"cell_px_count": world.cell_px_count_arr,
		"flat_px_indices": world.flat_px_indices_arr,
		"enum_atlas_data": baker._enum_atlas_data,
		"run_cover": run_cover,
		"run_vegetation": run_vegetation,
		"cover_buffer": world.cover_buffer,
		"vegetation_buffer": world.vegetation_buffer,
		"prev_cover": baker._last_cover_cell_bytes_packed,
		"prev_vegetation": baker._last_vegetation_cell_bytes_packed,
	}
	var out: Dictionary = baker._world_ext.patch_enum_atlas_axes(knobs)
	if bool(out.get("fallback", true)):
		baker._enum_atlas_cpp_skip_reason = "cpp_native_fallback_" + str(out.get("reason", "unknown"))
		return false
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	baker._enum_atlas_data = out.get("enum_atlas_data", baker._enum_atlas_data)
	var dirty_cells: int = 0
	var dirty_pixels: int = int(out.get("dirty_pixels", 0))
	if run_cover:
		world.cover_buffer = out.get("cover_buffer", world.cover_buffer)
		baker._last_cover_cell_bytes_packed = out.get("prev_cover", baker._last_cover_cell_bytes_packed)
		dirty_cells = int(out.get("cover_dirty", 0))
		baker._cover_cache_size = Vector2i(W, H)
	else:
		world.vegetation_buffer = out.get("vegetation_buffer", world.vegetation_buffer)
		baker._last_vegetation_cell_bytes_packed = out.get("prev_vegetation", baker._last_vegetation_cell_bytes_packed)
		dirty_cells = int(out.get("vegetation_dirty", 0))
		baker._vegetation_cache_size = Vector2i(W, H)
	if dirty_cells <= 0:
		baker._record_enum_atlas_upload_report(axis, "cpp_skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return true
	baker._record_enum_atlas_upload_report(axis, "cpp_lut_only_no_map_index_upload",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
	return true



static func _try_cpp_enum_axes_patch(baker: MapBaker, map: MapData, world: WorldData, report_t0_us: int) -> bool:
	baker._enum_atlas_cpp_skip_reason = ""
	if world == null:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_world_null"
		return false
	var gate_reason: String = baker._enum_atlas_cpp_pack_disabled_reason()
	if gate_reason != "":
		baker._enum_atlas_cpp_skip_reason = gate_reason
		return false
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var pix_count: int = W * H
	if pix_count <= 0:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_bad_size"
		return false
	if baker._enum_atlas_data_size != Vector2i(W, H) or baker._enum_atlas_data.size() != pix_count * 4:
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_enum_data_invalid"
		return false
	if not baker._ensure_world_cell_pixel_csr(map, world):
		baker._enum_atlas_cpp_skip_reason = "cpp_gate_csr_empty"
		return false
	var patch_t0_us: int = Time.get_ticks_usec()
	var out: Dictionary = baker._world_ext.patch_enum_atlas_axes({
		"n_cells": world.cell_first_px_arr.size(),
		"n_pix": pix_count,
		"cell_first_px": world.cell_first_px_arr,
		"cell_px_count": world.cell_px_count_arr,
		"flat_px_indices": world.flat_px_indices_arr,
		"enum_atlas_data": baker._enum_atlas_data,
		"run_biome": true,
		"run_vegetation": true,
		"run_cover": true,
		"biome_buffer": world.biome_buffer,
		"vegetation_buffer": world.vegetation_buffer,
		"cover_buffer": world.cover_buffer,
		"prev_biome": baker._last_biome_cell_bytes_packed,
		"prev_vegetation": baker._last_vegetation_cell_bytes_packed,
		"prev_cover": baker._last_cover_cell_bytes_packed,
	})
	if bool(out.get("fallback", true)):
		baker._enum_atlas_cpp_skip_reason = "cpp_native_fallback_" + str(out.get("reason", "unknown"))
		return false
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	world.biome_buffer = out.get("biome_buffer", world.biome_buffer)
	world.vegetation_buffer = out.get("vegetation_buffer", world.vegetation_buffer)
	world.cover_buffer = out.get("cover_buffer", world.cover_buffer)
	baker._enum_atlas_data = out.get("enum_atlas_data", baker._enum_atlas_data)
	baker._last_biome_cell_bytes_packed = out.get("prev_biome", baker._last_biome_cell_bytes_packed)
	baker._last_vegetation_cell_bytes_packed = out.get("prev_vegetation", baker._last_vegetation_cell_bytes_packed)
	baker._last_cover_cell_bytes_packed = out.get("prev_cover", baker._last_cover_cell_bytes_packed)
	baker._biome_cache_size = Vector2i(W, H)
	baker._vegetation_cache_size = Vector2i(W, H)
	baker._cover_cache_size = Vector2i(W, H)
	var dirty_cells: int = int(out.get("dirty_cells", 0))
	var dirty_pixels: int = int(out.get("dirty_pixels", 0))
	var biome_dirty: int = int(out.get("biome_dirty", 0))
	if dirty_cells <= 0:
		baker._record_enum_atlas_upload_report("biome", "cpp_skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return true
	if biome_dirty <= 0:
		baker._record_enum_atlas_upload_report("biome", "cpp_lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return true
	# plan/sim-2ms-simd-dirty-budget：节流判定（合并 axes 路径用 "biome" 当 key
	# —— 一次合并 patch 等同 biome+veg+cover 三 axis 的整体翻转，所以共用一个
	# 阈值序列即可）。详见 _try_cpp_enum_axis_patch 同名注释。
	if not baker._enum_atlas_throttle_should_flush("biome", dirty_cells):
		baker._record_enum_atlas_upload_report("biome", "cpp_throttle_skipped",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return true
	var image_t0_us: int = Time.get_ticks_usec()
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._enum_atlas_data)
	var image_ms: float = float(Time.get_ticks_usec() - image_t0_us) / 1000.0
	var upload_t0_us: int = Time.get_ticks_usec()
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		world.enum_atlas_tex.update(img)
	else:
		world.enum_atlas_tex = ImageTexture.create_from_image(img)
	var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
	baker._record_enum_atlas_upload_report("biome", "cpp_cached_patch",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, true)
	return true

# 主地图动态状态 atlas：RGBA8，R=temp, G=moisture/wetness, B=snow_cover, A=vegetation_vitality。
# 使用 world.cell_pixel_lists 按 cell dirty 写入，避免每次重新 cube_round / 逐像素取字段。
# [cell-indirect single-path 2026-06-16] flag 开时这组逐像素动态 atlas
# (dynamic_cell_atlas / ecology_visual_atlas / dyn_atlas_smooth / ice_state_atlas)
# 主 shader 已改读 per-cell LUT（dyn_lut/eco_lut，海冰走 dyn_lut.a），不再被采样，
# 故所有 rebake 入口统一返回此 no-op 报告。字段与正常 rebake 报告同构，调用方
# （bake_world / DVA oneshot）的 dirty/ms 累加安全。

static func _indirection_skip_atlas_report(baker: MapBaker) -> Dictionary:
	return {
		"prepared": false,
		"dirty": false,
		"dirty_cells": 0,
		"pixels_written": 0,
		"elapsed_ms": 0.0,
		"skipped_indirection": true,
	}
