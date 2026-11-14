extends RefCounted
class_name DCWeatherBaker
## Weather field fallback baking and static wind baseline generation.
##
## Mutable caches remain on MapBaker and are passed through the explicit host argument.

const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")

static func bake_weather_field_only(baker: MapBaker, map: MapData, world: WorldData) -> void:
	# DEPRECATED（DOTS-Total-CPP 任务 7）：本函数沿用 GDScript 像素填充路径，
	# fast tick 主路径 set_weather_field_texture(null) 已不再实际烘焙整张纹理；
	# 仅保留兜底用途（手动 reset / regenerate 后首帧）。后续将由 weather_baker.gd
	# 接管 dirty-tile pack；新代码路径**不要**调用此函数。
	if world == null or map == null:
		return
	# Daily-sim perf opt（dirty 增量路径，与 bake_sea_ice_fraction_only / cover / vegetation
	# 同构）：weather_field_tex 是 hex-constant 数据（每个 hex 内部颜色完全一致）。
	#
	# 旧路径：每天扫 ~2400 cell + 写整张 RGBA8（~250k–600k bytes，27ms）。
	# 新路径：
	#   1) 首次或 size 变化 → 完整重建 baker._weather_field_buf + 填 sig 缓存（一次性 ~27ms）；
	#   2) 后续 → 遍历 ~2400 cell：sig 不变 ⇒ 直接 continue；变了才把 4 byte 写到那个
	#      cell 的所有像素 + 更新 sig。典型日 < 50 个 cell 翻面 → 写盘 ~5k 字节。
	#   3) 若任一 cell 翻面 → 触发整张 Image.create_from_data + tex.update（GPU 上传必经；
	#      但循环 / 写盘开销骤降到 < 5ms）。全无变化 ⇒ 连 image 创建也省。
	var W := world.derived_size.x
	var H := world.derived_size.y
	if W <= 0 or H <= 0:
		return
	var n := W * H
	if n <= 0:
		return
	var cell_lists: Dictionary = world.cell_pixel_lists
	if cell_lists.is_empty():
		push_warning("MapBaker.bake_weather_field_only: cell_pixel_lists missing; weather field empty")
		return

	var need_bytes: int = n * 4
	var cache_size_match: bool = (baker._weather_field_cache_size == Vector2i(W, H) \
			and baker._weather_field_buf.size() == need_bytes \
			and not baker._last_weather_field_cell_sigs.is_empty())

	if not cache_size_match:
		# 全重建路径：清状态 → 全图写一次 → 填 sig 缓存。
		baker._weather_field_buf = PackedByteArray()
		baker._weather_field_buf.resize(need_bytes)
		baker._last_weather_field_cell_sigs = {}
		baker._weather_field_cache_size = Vector2i(W, H)
		for cell_key in cell_lists.keys():
			var cell: HexCell = cell_key
			if cell == null:
				continue
			var wt0: int = cell.weather_type if cell.weather_field_initialized else int(cell.current_state.get("weather", WeatherType.WT.CLEAR))
			var intensity0: float = cell.weather_intensity if cell.weather_field_initialized else float(cell.current_state.get("weather_intensity", 0.0))
			var cloud0: float = cell.weather_cloud if cell.weather_field_initialized else float(cell.current_state.get("weather_cloud", 0.0))
			var vapor0: float = cell.weather_vapor if cell.weather_field_initialized else float(cell.current_state.get("weather_vapor", 0.0))
			var b00: int = clampi(wt0, 0, 255)
			var b10: int = clampi(int(round(clampf(intensity0, 0.0, 1.0) * 255.0)), 0, 255)
			var b20: int = clampi(int(round(clampf(cloud0, 0.0, 1.0) * 255.0)), 0, 255)
			var b30: int = clampi(int(round(clampf(vapor0, 0.0, 1.0) * 255.0)), 0, 255)
			var sig0: int = b00 | (b10 << 8) | (b20 << 16) | (b30 << 24)
			baker._last_weather_field_cell_sigs[cell] = sig0
			var pixels0: PackedInt32Array = cell_lists[cell_key]
			for px in pixels0:
				var di0: int = px * 4
				baker._weather_field_buf[di0] = b00
				baker._weather_field_buf[di0 + 1] = b10
				baker._weather_field_buf[di0 + 2] = b20
				baker._weather_field_buf[di0 + 3] = b30
		world.weather_field_buffer = baker._weather_field_buf
		var img0 := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._weather_field_buf)
		if world.weather_field_tex != null and world.weather_field_tex.get_size() == Vector2(float(W), float(H)):
			world.weather_field_tex.update(img0)
		else:
			world.weather_field_tex = ImageTexture.create_from_image(img0)
		return

	# 增量路径：遍历 cell，比 sig，仅写翻面的。
	var dirty_count: int = 0
	var weather_dirty_mask: PackedByteArray = map.weather_dirty_mask
	var use_weather_dirty: bool = weather_dirty_mask.size() == map.cell_count()
	var has_weather_dirty: bool = false
	if use_weather_dirty:
		for _wd in weather_dirty_mask:
			if int(_wd) != 0:
				has_weather_dirty = true
				break
	for cell_key in cell_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		if use_weather_dirty and has_weather_dirty:
			var cell_idx: int = map.index_of(cell)
			if cell_idx < 0 or cell_idx >= weather_dirty_mask.size() or weather_dirty_mask[cell_idx] == 0:
				continue
		var wt: int = cell.weather_type if cell.weather_field_initialized else int(cell.current_state.get("weather", WeatherType.WT.CLEAR))
		var intensity: float = cell.weather_intensity if cell.weather_field_initialized else float(cell.current_state.get("weather_intensity", 0.0))
		var cloud: float = cell.weather_cloud if cell.weather_field_initialized else float(cell.current_state.get("weather_cloud", 0.0))
		var vapor: float = cell.weather_vapor if cell.weather_field_initialized else float(cell.current_state.get("weather_vapor", 0.0))
		var b0: int = clampi(wt, 0, 255)
		var b1: int = clampi(int(round(clampf(intensity, 0.0, 1.0) * 255.0)), 0, 255)
		var b2: int = clampi(int(round(clampf(cloud, 0.0, 1.0) * 255.0)), 0, 255)
		var b3: int = clampi(int(round(clampf(vapor, 0.0, 1.0) * 255.0)), 0, 255)
		var sig: int = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
		var prev_sig_var = baker._last_weather_field_cell_sigs.get(cell, -1)
		if int(prev_sig_var) == sig:
			continue
		baker._last_weather_field_cell_sigs[cell] = sig
		var pixels: PackedInt32Array = cell_lists[cell_key]
		for px in pixels:
			var di: int = px * 4
			baker._weather_field_buf[di] = b0
			baker._weather_field_buf[di + 1] = b1
			baker._weather_field_buf[di + 2] = b2
			baker._weather_field_buf[di + 3] = b3
		dirty_count += 1

	world.weather_field_buffer = baker._weather_field_buf
	# H 诊断：累计 dirty 比例。每 30 次调用打一行，命中率高于 80% 时考虑回滚 F。
	baker._wf_diag_calls += 1
	baker._wf_diag_dirty_sum += dirty_count
	baker._wf_diag_total_cells = cell_lists.size()
	if dirty_count == 0:
		baker._wf_diag_skipped_full += 1
	if baker._wf_diag_calls >= 30:
		var avg_dirty: float = float(baker._wf_diag_dirty_sum) / float(baker._wf_diag_calls)
		var dirty_ratio: float = avg_dirty / float(maxi(baker._wf_diag_total_cells, 1))
		print("  [field_bake] last %d calls: avg dirty=%.0f/%d (%.1f%%), full-skip=%d" % [
			baker._wf_diag_calls, avg_dirty, baker._wf_diag_total_cells, dirty_ratio * 100.0, baker._wf_diag_skipped_full
		])
		baker._wf_diag_calls = 0
		baker._wf_diag_dirty_sum = 0
		baker._wf_diag_skipped_full = 0
	if dirty_count == 0:
		# 全图无变化：连 Image.update 也省。weather_field_tex 维持上一帧不变。
		return
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._weather_field_buf)
	if world.weather_field_tex != null and world.weather_field_tex.get_size() == Vector2(float(W), float(H)):
		world.weather_field_tex.update(img)
	else:
		world.weather_field_tex = ImageTexture.create_from_image(img)

# ─── Phase 1：纬度 buffer（每像素 ny ∈ [0, 1]） ──────────────────────────
# shader 用来算半球（lat_signed = ny * 2 - 1）以及纬度温度钟形曲线。

## Legacy compatibility helper retained for diagnostics comparison only.
## Production bake_world uses DCClimateBaker.bake_latitude_buffer above.

# ─── Phase 6：风带 buffer（每像素盛行风向，RG8） ──────────────────────────
# 用 WindBelt.wind_at(ny, season_phase, lat_jitter) 算每像素风向。
# 加 baker._warp_noise_lo 给 ny 做小扰动（±0.04），避免风带边界呈现明显纬向条纹。
# season_phase 仅保留给 WindBelt.wind_at 的旧签名；运行时物理风场由 C++ SLP/pressure
# chain 每日写入，静态 wind_field bake 只作为缺失物理风时的纬向基线。


static func bake_wind_field(baker: MapBaker, bounds: Rect2, size: Vector2i, season_phase: float) -> PackedByteArray:
	var W := size.x
	var H := size.y
	var origin := bounds.position
	var step_x := bounds.size.x / float(W)
	var step_y := bounds.size.y / float(H)
	var buf := PackedByteArray()
	buf.resize(W * H * 2)
	for y in range(H):
		var ny := float(y) / float(maxi(H - 1, 1))
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var jitter: float = baker._warp_noise_lo.get_noise_2d(wx_base * 0.3, wy_base * 0.3) * 0.04
			var w: Vector2 = WindBeltScript.wind_at(ny, season_phase, jitter)
			var idx := (y * W + x) * 2
			buf[idx]     = clampi(int(round((w.x * 0.5 + 0.5) * 255.0)), 0, 255)
			buf[idx + 1] = clampi(int(round((w.y * 0.5 + 0.5) * 255.0)), 0, 255)
	return buf

# ─── Phase 3 + Phase 6：洋流向量场（风驱动 + Ekman 偏转） ─────────────────
# 现实里海面洋流方向 ≈ 风向旋转 ±45°（北半球右偏，南半球左偏）。
# 算法：
#   1) 读 wind_field_buffer 的盛行风向当主驱动力
#   2) 按半球做 Ekman 偏转
#   3) 大陆反射：靠近陆地的海面被推离陆地
#   4) 噪声扰动
# 仅海洋像素有意义；陆地像素填中性 (0.5, 0.5) = 零向量。
# 编码：dx, dy ∈ [-1, 1] → 字节 [0, 255]。

const EKMAN_DEFLECTION_RAD := 0.7854  # ~45°

# Systemic Ocean Currents：热盐驱动 / Ekman 抽吸用到的几何常量
const _THERMOHALINE_DEFAULT := 0.25
const _UPWELLING_COAST_TANGENT_MIN := 0.55   # 风向与海岸切向的对齐阈值（|dot| > this）
const _UPWELLING_HIGHLAT_ABS := 0.6          # |lat_signed| > this 且 lat_temp 够低 → 下沉候选
