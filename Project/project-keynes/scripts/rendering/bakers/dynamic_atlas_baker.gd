extends RefCounted
class_name DCDynamicAtlasBaker

const DCAtlasEncoders = preload("res://scripts/rendering/bakers/atlas_encoders.gd")




## Stateless signatures and small working-set helpers shared by dynamic atlases.

static func dynamic_cell_signature(baker: MapBaker, cell: HexCell, snow_override: float = -1.0) -> int:
	# A 通道双语义（sea-ice-render-source-unify 阶段 C）：
	#   - 水格（is_water=true，等价于 not passable_land）：A = q01_byte_ice(sea_ice_fraction)
	#       让 shader 水路径直接从 dyn_atlas_smooth.A 读取海冰覆盖率；同源于
	#       UI/info_panel.sea_ice_fraction，根除"UI 100% 但画面无冰"类病灶。
	#   - 陆格：A = q01_byte(vegetation_vitality)（保持原语义，陆地植被通道）
	# 关键：用 is_water 而非 passable_sea——SEA_ICE 因冰面阻断航行 passable_sea=false，
	# 但视觉上仍是水域；用 passable_sea 会把 SEA_ICE 误归入陆格写 vit，shader 水路径
	# 拿到错误数据完全看不到冰。
	# SAME_SOURCE：gdext/src/world_ext.cpp::encode_dynamic_cell_atlas / encode_dyn_smooth_atlas /
	#              monolithic atlas pipeline pk_atlas_sig_dynamic（统一用 is_water 语义）。
	var r: int = baker._q01_byte(float(cell.temperature))
	var g: int = baker._q01_byte(float(cell.moisture))
	var snow_val: float = snow_override if snow_override >= 0.0 else float(cell.snow_cover)
	var b: int = baker._q01_byte(snow_val)
	var a: int
	if MapData.terrain_is_water(int(cell.terrain)):
		a = baker._q01_byte_ice(float(cell.sea_ice_fraction))
	else:
		a = baker._q01_byte(float(cell.vegetation_vitality))
	return r | (g << 8) | (b << 16) | (a << 24)

# 生态视觉 atlas：RGBA8，derived_size。
# R=叶量/冠层密度，G=胁迫/干旱，B=植被 enum 变化后的过渡年龄，A=近期生长/受损。

static func ecology_visual_signature(baker: MapBaker, cell: HexCell, transition_age: int, prev_vitality_byte: int, snow_override: float = -1.0) -> int:
	var terrain_id: int = int(cell.terrain)
	var is_water_cell: bool = MapData.terrain_is_water(terrain_id)
	var veg_id: int = int(cell.vegetation)
	var vitality: float = clampf(float(cell.vegetation_vitality), 0.0, 1.0)
	var moist: float = clampf(float(cell.moisture), 0.0, 1.0)
	var temp: float = clampf(float(cell.temperature), 0.0, 1.0)
	var snow_src: float = snow_override if snow_override >= 0.0 else float(cell.snow_cover)
	var snow: float = clampf(snow_src, 0.0, 1.0)

	var foliage: float = 0.0
	if not is_water_cell and veg_id != int(VegetationType.VEG.NONE):
		var cold_loss: float = (1.0 - smoothstep(0.02, 0.18, temp)) * 0.55
		var snow_loss: float = smoothstep(0.12, 0.75, snow) * 0.70
		var dry_loss: float = (1.0 - smoothstep(0.05, 0.35, moist)) * 0.45
		foliage = clampf(vitality * 0.72 + moist * 0.28 - cold_loss - snow_loss - dry_loss, 0.0, 1.0)

	var stress: float = 0.0
	if not is_water_cell:
		var dryness: float = 1.0 - moist
		var heat_stress: float = smoothstep(0.72, 0.95, temp)
		var cold_stress: float = 1.0 - smoothstep(0.03, 0.20, temp)
		var vitality_stress: float = 1.0 - vitality
		stress = clampf(max(dryness * 0.70, max(heat_stress, cold_stress) * 0.65) \
				+ vitality_stress * 0.45, 0.0, 1.0)

	var vitality_delta: float = (float(baker._q01_byte(vitality)) - float(prev_vitality_byte)) / 255.0
	var growth_damage: float = clampf(0.5 + vitality_delta * 5.0 + (foliage - 0.5) * 0.12 \
			- stress * 0.10, 0.0, 1.0)
	var r: int = baker._q01_byte(foliage)
	var g: int = baker._q01_byte(stress)
	var b: int = clampi(transition_age, 0, 255)
	var a: int = baker._q01_byte(growth_damage)
	return r | (g << 8) | (b << 16) | (a << 24)


static func q01_byte(v: float) -> int:
	return clampi(int(round(clampf(v, 0.0, 1.0) * 255.0)), 0, 255)

# 2026-05-19 Plan-C：海冰专用量化（不影响 temp/moist/snow/vitality 等其他通道）。
# 当 fraction > 0 时使用 ceil 并保证至少 byte=1，避免低浓度冰在量化时丢失；
# shader 端再用更高、更宽的 smoothstep 决定可见强度。fraction == 0 仍写 0。
# 仅由 ice_state_atlas_chunk_step 在海冰写入路径调用。

static func q01_byte_ice(v: float) -> int:
	if v <= 0.0:
		return 0
	return clampi(maxi(1, int(ceil(clampf(v, 0.0, 1.0) * 255.0))), 1, 255)

# ─── map-visual-overhaul-v1：3 张新 atlas baker 实现 ─────────────────────────
#
# 设计原则与 rebake_dynamic_cell_atlas_only / rebake_ecology_visual_atlas_only
# 一致：cell-level dirty 缓存 + cell_pixel_lists 像素列表批量写入。新增的"smooth"
# atlas 在 cell 域做一次 hex 邻接 box blur，shader 端单点采样即可得到跨 cell 平滑
# 的连续场（消除"颜色按 hex 块切"的硬阶梯，同时主地图 fragment 采样数严格 ≤ 8）。
#
# 调用约定：
# - rebake_dyn_atlas_smooth 必须在 rebake_dynamic_cell_atlas_only 之后调用
#   （因为它读取 _dynamic_cell_atlas_buf 中已经写入的 byte 作为 blur 输入）。
# - rebake_ice_state_atlas 与气候/天气日 tick 解耦，每日 climate_system 末尾跑一次即可。

# dyn_atlas_smooth：dynamic_cell_atlas 的"沿 hex 邻接 box blur"产物。
# 单 cell 处理成本 = 中心 0.5 + 6 邻居均值 0.5；O(N_cells × 7) 加和。
# 与 rebake_dynamic_cell_atlas_only 同分辨率（derived_size, RGBA8）。
#
# Neighbor-aware sig（方案 C v1）：
# 旧版 sig 用"输出 byte 拼接"做 cache key —— int 除法 + clampi 量化可能淹没真实
# 邻居变动，造成视觉滞后。改造为"自己 4-byte + 6 邻居 4-byte，FNV-1a 哈希"作 cache
# sig，保证邻居 sig 任一 bit 变化都能立刻触发本 cell 重算。

static func report_inc(report: Dictionary, key: String, delta: int = 1) -> void:
	report[key] = int(report.get(key, 0)) + delta



static func cell_range(cells, start_idx: int = 0, end_idx: int = -1) -> Vector2i:
	var count: int = cells.size()
	var s: int = clampi(start_idx, 0, count)
	var e: int = count if end_idx < 0 else clampi(end_idx, s, count)
	return Vector2i(s, e)


# 共享 CSR 打包：把 dirty cells（HexCell Array）转成 4 个 PackedInt32Array。
# - cells: HexCell Array，可能含 null（caller 应已过滤但兼容 null 跳过）
# - world: 用于读 cell_pixel_lists / water_cell_pixel_lists
# - use_water_lists: ice_state pass 走 water_cell_pixel_lists；其他走 cell_pixel_lists
# - n_pix: W*H，用于越界过滤
# 返回 Dictionary：含 cell_indices / cell_first_px / cell_px_count / flat_px_indices /
#                 cell_is_water / valid_count（实际有效 cell 数；剔除 null/idx<0/无 pixel list）
# 如果 valid_count == 0，caller 应直接 return（无需调 cpp）。
#
# sea-ice-render-source-unify 阶段 C：cell_is_water 语义代替原来的 cell_passable_sea。
# is_water = not passable_land，含 OCEAN/COAST/LAKE/SEA_ICE/REEF/KELP 等所有水域；
# 原 passable_sea 仅指“可航行”造成 SEA_ICE 被误归入陆格，是本阶段修复的根因。
#
# P1：当 `world.cell_first_px_arr` 已构建（height/biome/moisture bake 跑过）
# 且 use_water_lists=false 时，走 SoA fast path：
#   - 直接读 `world.cell_first_px_arr[idx]` 拿 flat 起始 / `cell_px_count_arr[idx]`
#     拿长度，不再走 `cell_pixel_lists.has(cell)` + `.get(cell)` 的 K 次 Dict 查找。
#   - is_water 改用 `MapData.is_water_lut()[map.terrain_arr[idx]]`，消除 `cell.is_water`/
#     `cell.passable_land` 字段读取（均需走 GDScript 属性路径，远比 PackedByteArray 索引贵）。
# fallback：use_water_lists=true / SoA 未 build / map==null / terrain_arr 大小不符 →
#           走 Dict + “not cell.passable_land” 旧路径（行为完全一致）。

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



static func get_last_enum_atlas_upload_report(baker: MapBaker) -> Dictionary:
	return baker._last_enum_atlas_upload_report.duplicate(true)


# ─── plan/dirty-push-atlas-encode 阶段 F：C++ encode fast-path helpers ────────
#
# 共享设计：所有 4 个 atlas 走同一 CSR 协议（cell_indices/cell_first_px/
# cell_px_count/flat_px_indices），由 `_pack_csr_for_cells()` 一次构建，按需
# 加上 passable_sea / prev_* / neighbor 等 pass 特有字段后调对应 cpp method。
#
# 失败模式：cpp method 缺失、CSR 打包失败、SoA slot 不匹配等情况下 helper 返回
# false，caller 直接走下方 GDScript loop（透明 fallback）。**不报错、不抛异常**。

# 是否启用 cpp encode pass。使用 helper 集中判断三件事：
#   1. cpp_atlas_encode_enabled flag 为 true（或 climate_profile 缺失时跳过）
#   2. _world_ext 已注入（DCWorld bind 完成）
#   3. ext 实现了对应 method（向前兼容旧 dll）

static func _cpp_atlas_encode_active(baker: MapBaker, method_name: StringName) -> bool:
	return baker._cpp_atlas_encode_disabled_reason(method_name) == ""



static func _cpp_atlas_encode_disabled_reason(baker: MapBaker, method_name: StringName) -> String:
	if baker._climate_profile == null:
		return "no_climate_profile"
	# dots-flag-prune-pr1 round 2 (2026-05-22): cpp_atlas_encode_enabled flag 已删除——
	# C++ atlas encode 现恒走入口，仅受 ext + has_method 探测控制。
	if baker._world_ext == null:
		return "no_world_ext"
	if not baker._world_ext.has_method(method_name):
		return "method_missing"
	return ""



static func _report_inc(baker: MapBaker, report: Dictionary, key: String, delta: int = 1) -> void:
	report_inc(report, key, delta)
	return


static func _cell_range(baker: MapBaker, cells, start_idx: int = 0, end_idx: int = -1) -> Vector2i:
	return cell_range(cells, start_idx, end_idx)


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

static func _enum_atlas_throttle_should_flush(baker: MapBaker, _axis: String, _dirty_cells: int) -> bool:
	return true


# plan/sim-2ms-simd-dirty-budget：强制 flush 入口（season 切换 / save /
# screenshot 等场景必须把累积的 dirty 立即同步到 GPU 避免视觉错位）。
# axis = "" 表示 flush 所有 axis；否则 flush 单 axis。
# Caller 必须在调用本函数后再触发 enum atlas 重烘走完整路径，本函数仅清算计数。

static func force_flush_enum_atlas_throttle(baker: MapBaker, axis: String = "") -> void:
	if axis == "":
		baker._enum_atlas_throttle_pending_dirty.clear()
		baker._enum_atlas_throttle_skipped_uploads.clear()
		baker._enum_atlas_throttle_ticks_since_flush.clear()
	else:
		baker._enum_atlas_throttle_pending_dirty.erase(axis)
		baker._enum_atlas_throttle_skipped_uploads.erase(axis)
		baker._enum_atlas_throttle_ticks_since_flush.erase(axis)



static func _record_enum_atlas_upload_report(baker: MapBaker, axis: String, path: String, elapsed_ms: float,
		dirty_cells: int, dirty_pixels: int, buffer_patch_ms: float,
		image_ms: float, upload_ms: float, cache_valid: bool) -> void:
	var out_path: String = path
	var skip_reason: String = baker._enum_atlas_cpp_skip_reason
	if skip_reason != "" and not path.begins_with("cpp_"):
		out_path = "%s:%s" % [path, skip_reason]
	baker._last_enum_atlas_upload_report = {
		"axis": axis,
		"path": out_path,
		"elapsed_ms": elapsed_ms,
		"dirty_cells": dirty_cells,
		"dirty_pixels": dirty_pixels,
		"buffer_patch_ms": buffer_patch_ms,
		"image_ms": image_ms,
		"upload_ms": upload_ms,
		"cache_valid": cache_valid,
		"cpp_skip_reason": skip_reason,
	}
	baker._enum_atlas_cpp_skip_reason = ""



static func prewarm_dynamic_axis_caches(baker: MapBaker, map: MapData, world: WorldData) -> void:
	if map == null or world == null:
		return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if pix_count <= 0:
		return
	if world.cell_pixel_lists.is_empty():
		return
	if world.cover_buffer.size() != pix_count or world.vegetation_buffer.size() != pix_count \
			or world.biome_buffer.size() != pix_count:
		return
	if baker._enum_atlas_data_size != Vector2i(W, H) or baker._enum_atlas_data.size() != pix_count * 4:
		return

	var cover_cache: Dictionary = {}
	var vegetation_cache: Dictionary = {}
	# J: 同步预热 biome 缓存，让下一次 rebake_biome_axes_only 直接走增量路径
	var biome_cache: Dictionary = {}
	var n_cells: int = map.cell_count()
	baker._last_cover_cell_bytes_packed = PackedByteArray()
	baker._last_vegetation_cell_bytes_packed = PackedByteArray()
	baker._last_biome_cell_bytes_packed = PackedByteArray()
	baker._last_cover_cell_bytes_packed.resize(n_cells)
	baker._last_vegetation_cell_bytes_packed.resize(n_cells)
	baker._last_biome_cell_bytes_packed.resize(n_cells)
	var cells_for_cache: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for cell_key in cells_for_cache:
		var cell: HexCell = cell_key
		if cell == null:
			continue
		var b_cover: int = int(cell.cover) & 0xFF
		var b_veg: int = int(cell.vegetation) & 0xFF
		var b_biome: int = int(cell.terrain) & 0xFF
		cover_cache[cell] = b_cover
		vegetation_cache[cell] = b_veg
		biome_cache[cell] = b_biome
		if cell.index >= 0 and cell.index < n_cells:
			baker._last_cover_cell_bytes_packed[cell.index] = b_cover
			baker._last_vegetation_cell_bytes_packed[cell.index] = b_veg
			baker._last_biome_cell_bytes_packed[cell.index] = b_biome
	baker._last_cover_cell_bytes = cover_cache
	baker._last_vegetation_cell_bytes = vegetation_cache
	baker._last_biome_cell_bytes = biome_cache
	baker._cover_cache_size = Vector2i(W, H)
	baker._vegetation_cache_size = Vector2i(W, H)
	baker._biome_cache_size = Vector2i(W, H)

# Systemic Ocean Currents：重烘洋流 + 上升流 buffer。
# season_phase 只作为切片锁相/兼容参数；运行时风场已经由 C++ SLP/solar
# chain 逐日写入 wind_field_buffer，不再在像素路径叠加独立季节风向偏置。
# 热盐驱动项仍按 cfg 权重叠加。
# 产出：
#   - world.ocean_current_buffer（RG8，重写）
#   - world.ocean_upwelling_buffer（R8，重写）
#   - world.vector_atlas_tex（重编码，包含新 RG = ocean_current）
# 注意：wind_field_buffer 是当前物理风场快照，而不是夏季基线。
