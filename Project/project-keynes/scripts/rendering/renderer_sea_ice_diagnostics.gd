extends RefCounted

## Read-only sea-ice visual diagnostics; world/map lifetimes remain on the renderer.

static func debug_sea_ice_probe(_world: WorldData, _map: MapData, cell) -> Dictionary:
	var report := {
		"ok": false,
		"reason": "",
		"sea_ice_fraction_cpu": 0.0,
		"dyn_smooth_a_byte": -1,
		"dyn_smooth_a_norm": 0.0,
		"biome": -1,
		"px_idx": -1,
	}
	if cell == null:
		report.reason = "cell is null"
		print("[sea-ice/probe] %s" % report.reason)
		return report
	if _world == null or _map == null:
		report.reason = "world/map not bound"
		print("[sea-ice/probe] %s" % report.reason)
		return report
	report.sea_ice_fraction_cpu = float(cell.sea_ice_fraction)
	if "terrain" in cell:
		report.biome = int(cell.terrain)
	report.reason = "sea ice visual source moved to dyn_lut.a; per-pixel probe retired"
	report.ok = true
	print("[sea-ice/probe] cell=%s frac_cpu=%.4f biome=%d %s" % [
		str(cell), report.sea_ice_fraction_cpu, report.biome, report.reason])
	return report
	# 取该 cell 第一个 derived 像素的 dyn_atlas_smooth.A 字节
	var pixels: PackedInt32Array = PackedInt32Array()
	if not _world.cell_pixel_lists.is_empty() and _world.cell_pixel_lists.has(cell):
		pixels = _world.cell_pixel_lists[cell]
	if pixels.size() <= 0:
		report.reason = "cell has no pixels in cell_pixel_lists"
		print("[sea-ice/probe] cell=%s frac_cpu=%.4f biome=%d %s" % [
			str(cell), report.sea_ice_fraction_cpu, report.biome, report.reason])
		return report
	var px_idx: int = pixels[0]
	report.px_idx = px_idx
	var buf: PackedByteArray = _world.dyn_atlas_smooth_buffer
	# sea-ice-render-source-unify 阶段 C 探针扩展：
	# 同时读 dynamic_cell_atlas（未 smooth 的源 buffer）的 A 字节，便于区分
	# A_byte 错误是发生在 dynamic phase 还是 smooth phase。
	var raw_buf: PackedByteArray = _world.dynamic_cell_atlas_buffer
	var W: int = int(_world.derived_size.x)
	var H: int = int(_world.derived_size.y)
	var n_pix: int = W * H
	if buf.size() < n_pix * 4:
		report.reason = "dyn_atlas_smooth_buffer not ready (size=%d expected=%d)" % [buf.size(), n_pix * 4]
		print("[sea-ice/probe] %s" % report.reason)
		return report
	if px_idx < 0 or px_idx >= n_pix:
		report.reason = "px_idx out of range (%d not in [0,%d))" % [px_idx, n_pix]
		print("[sea-ice/probe] %s" % report.reason)
		return report
	var a_byte: int = int(buf[px_idx * 4 + 3])
	var raw_r: int = -1
	var raw_g: int = -1
	var raw_b: int = -1
	var raw_a_byte: int = -1
	if raw_buf.size() >= n_pix * 4:
		raw_r = int(raw_buf[px_idx * 4 + 0])
		raw_g = int(raw_buf[px_idx * 4 + 1])
		raw_b = int(raw_buf[px_idx * 4 + 2])
		raw_a_byte = int(raw_buf[px_idx * 4 + 3])
	report.dyn_smooth_a_byte = a_byte
	report.dyn_smooth_a_norm = float(a_byte) / 255.0
	report.ok = true
	# 同源校验：水格上 a_byte 应 == q01_byte_ice(sea_ice_fraction_cpu)。
	var expected_byte: int = 0
	var v: float = report.sea_ice_fraction_cpu
	if v > 0.0:
		expected_byte = clampi(maxi(1, int(ceil(clampf(v, 0.0, 1.0) * 255.0))), 1, 255)
	var passable_sea_str: String = "?"
	if "passable_sea" in cell:
		passable_sea_str = "true" if bool(cell.passable_sea) else "false"
	var passable_land_str: String = "?"
	if "passable_land" in cell:
		passable_land_str = "true" if bool(cell.passable_land) else "false"
	# 双源 SIF 对照：facade getter (cell.sea_ice_fraction) vs cpp read_f32 (cell_sea_ice_frac slot)
	# 理论上 facade 已直读 cpp slot，这里再调一次 read_f32 直读 cpp，能确认 cpp slot 在探针时刻的真值。
	var sif_via_facade: float = float(cell.sea_ice_fraction)
	var sif_via_ext: float = -1.0
	# 从 cell 里反射拿 _world_ext（HexCell facade 已存有该 ext 引用）
	var ext = null
	if "_world_ext" in cell:
		ext = cell.get("_world_ext")
	# 同时读 MapData.terrain_arr[idx]（cpp pipeline 用来查 is_water_lut 的源）
	# 与 cell.terrain（HexCell facade 实时值）对比，验证 SoA 是否陈旧。
	var terrain_via_facade: int = int(cell.terrain) if "terrain" in cell else -1
	var terrain_via_soa: int = -1
	# 探针使用 hex_renderer 已有的 _map 字段（不要走 world.map_data —— world_data.gd
	# 没有 map_data 字段，会返回 null）。
	var map_data_ref: MapData = _map
	if map_data_ref != null and "index" in cell:
		var tarr: PackedByteArray = map_data_ref.terrain_arr
		var tidx: int = int(cell.index)
		if tidx >= 0 and tidx < tarr.size():
			terrain_via_soa = int(tarr[tidx])
	var iw_via_lut: int = -1
	var iw_via_render_lut: int = -1
	if map_data_ref != null and terrain_via_soa >= 0:
		var iwlut: PackedByteArray = MapData.is_water_lut()
		if terrain_via_soa < iwlut.size():
			iw_via_lut = int(iwlut[terrain_via_soa])
		var iwlut_render: PackedByteArray = MapData.is_water_render_lut()
		if terrain_via_soa < iwlut_render.size():
			iw_via_render_lut = int(iwlut_render[terrain_via_soa])
	if ext != null and ext.has_method(&"read_f32"):
		# component_id 反查 cell_sea_ice_frac slot
		var sif_cid: int = -1
		if ext.has_method(&"component_id"):
			sif_cid = int(ext.call(&"component_id", &"cell_sea_ice_frac"))
		if sif_cid >= 0 and "index" in cell:
			sif_via_ext = float(ext.call(&"read_f32", sif_cid, int(cell.index)))
	# RGBA 全字节打印：raw_r/g/b 应是 q01(temp)/q01(moist)/q01(snow)
	# raw_a 应是 q01_byte_ice(sif) for water cells
	# 预期 R~q01(temp=0)=0, G~q01(moist≈适中)≈?, B~q01(snow=0)=0, A=q01_byte_ice(1.0)=255
	print("[sea-ice/probe] cell=%s idx=%s passable_sea=%s passable_land=%s biome=%d" % [
		str(cell), str(cell.index) if "index" in cell else "?",
		passable_sea_str, passable_land_str, report.biome])
	print("  SIF: facade=%.4f  cpp_slot=%.4f  → expected_a=%d" % [
		sif_via_facade, sif_via_ext, expected_byte])
	print("  terrain: facade=%d  soa(MapData.terrain_arr)=%d  → is_water_lut[soa]=%d render_lut[soa]=%d (1=water,0=land)" % [
		terrain_via_facade, terrain_via_soa, iw_via_lut, iw_via_render_lut])
	print("  raw_dyn RGBA = (%d, %d, %d, %d)  smooth.A = %d (norm=%.4f)  match=%s" % [
		raw_r, raw_g, raw_b, raw_a_byte, a_byte, report.dyn_smooth_a_norm,
		"YES" if a_byte == expected_byte else "MISMATCH"])
	# [TEMP DIAG sea-ice probe-cpp-known]
	# cpp [PHASE-D-SMO-OA] 已知写过 first_px=8584/4586/4843/5091/719/5245/274/961
	# 且 oa=255。这里直接读 buf 这些位置的 A 字节，验证 cpp 写入是否真的到达了
	# world.dyn_atlas_smooth_buffer 这个对象。
	var _check_pxs: Array = [8584, 4586, 4843, 5091, 719, 5245, 274, 961]
	var _check_str: String = "  cpp_written_check buf[smo].A @ "
	for _px in _check_pxs:
		var _i: int = int(_px)
		if _i >= 0 and _i < n_pix:
			_check_str += "%d=%d " % [_i, int(buf[_i * 4 + 3])]
	print(_check_str)
	# raw_dyn 同样位置 A 字节（cpp dyn 应该写 sig.A=255）
	if raw_buf.size() >= n_pix * 4:
		var _check_raw: String = "  cpp_written_check buf[dyn].A @ "
		for _px in _check_pxs:
			var _i: int = int(_px)
			if _i >= 0 and _i < n_pix:
				_check_raw += "%d=%d " % [_i, int(raw_buf[_i * 4 + 3])]
		print(_check_raw)
	return report
