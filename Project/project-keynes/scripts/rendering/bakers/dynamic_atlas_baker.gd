extends RefCounted
class_name DCDynamicAtlasBaker

const EnumAtlasPatch = preload("res://scripts/rendering/bakers/enum_atlas_patch.gd")
const DynamicAtlasTileUpdates = preload("res://scripts/rendering/bakers/dynamic_atlas_tile_updates.gd")
const WeatherAtlasTileUpdates = preload("res://scripts/rendering/bakers/weather_atlas_tile_updates.gd")
const DynamicAtlasNativeEncoding = preload("res://scripts/rendering/bakers/dynamic_atlas_native_encoding.gd")

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
	return EnumAtlasPatch._enum_atlas_cpp_pack_disabled_reason(baker)

static func _enum_atlas_cpp_pack_enabled(baker: MapBaker) -> bool:
	return EnumAtlasPatch._enum_atlas_cpp_pack_enabled(baker)

static func _ensure_world_cell_pixel_csr(baker: MapBaker, map: MapData, world: WorldData) -> bool:
	return EnumAtlasPatch._ensure_world_cell_pixel_csr(baker, map, world)

static func _try_cpp_enum_axis_patch(baker: MapBaker, map: MapData, world: WorldData, axis: String, report_t0_us: int) -> bool:
	return EnumAtlasPatch._try_cpp_enum_axis_patch(baker, map, world, axis, report_t0_us)

static func _try_cpp_enum_axes_patch(baker: MapBaker, map: MapData, world: WorldData, report_t0_us: int) -> bool:
	return EnumAtlasPatch._try_cpp_enum_axes_patch(baker, map, world, report_t0_us)

static func _indirection_skip_atlas_report(baker: MapBaker) -> Dictionary:
	return EnumAtlasPatch._indirection_skip_atlas_report(baker)


static func rebake_dynamic_cell_atlas_only(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasTileUpdates.rebake_dynamic_cell_atlas_only(baker, map, world)

static func dynamic_cell_atlas_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasTileUpdates.dynamic_cell_atlas_chunk_begin(baker, map, world)

static func dynamic_cell_atlas_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	DynamicAtlasTileUpdates.dynamic_cell_atlas_chunk_step(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func dynamic_cell_atlas_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	DynamicAtlasTileUpdates.dynamic_cell_atlas_chunk_finalize(baker, world, ctx, report)

static func rebake_ecology_visual_atlas_only(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasTileUpdates.rebake_ecology_visual_atlas_only(baker, map, world)

static func ecology_visual_atlas_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasTileUpdates.ecology_visual_atlas_chunk_begin(baker, map, world)

static func ecology_visual_atlas_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	DynamicAtlasTileUpdates.ecology_visual_atlas_chunk_step(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func ecology_visual_atlas_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	DynamicAtlasTileUpdates.ecology_visual_atlas_chunk_finalize(baker, world, ctx, report)


static func rebake_dyn_atlas_smooth(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return WeatherAtlasTileUpdates.rebake_dyn_atlas_smooth(baker, map, world)

static func dyn_atlas_smooth_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return WeatherAtlasTileUpdates.dyn_atlas_smooth_chunk_begin(baker, map, world)

static func dyn_atlas_smooth_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	WeatherAtlasTileUpdates.dyn_atlas_smooth_chunk_step(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func dyn_atlas_smooth_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	WeatherAtlasTileUpdates.dyn_atlas_smooth_chunk_finalize(baker, world, ctx, report)

static func rebake_ice_state_atlas(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return WeatherAtlasTileUpdates.rebake_ice_state_atlas(baker, map, world)

static func ice_state_atlas_chunk_begin(baker: MapBaker, map: MapData, world: WorldData) -> Dictionary:
	return WeatherAtlasTileUpdates.ice_state_atlas_chunk_begin(baker, map, world)

static func ice_state_atlas_default_cell_source(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary) -> Array:
	return WeatherAtlasTileUpdates.ice_state_atlas_default_cell_source(baker, map, world, ctx)

static func ice_state_atlas_chunk_step(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	WeatherAtlasTileUpdates.ice_state_atlas_chunk_step(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func ice_state_atlas_chunk_finalize(baker: MapBaker, world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	WeatherAtlasTileUpdates.ice_state_atlas_chunk_finalize(baker, world, ctx, report)


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
	return DynamicAtlasNativeEncoding._pack_csr_for_cells(baker, world, cells, use_water_lists, n_pix, start_idx, end_idx, map)

static func _try_cpp_dynamic_cell_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasNativeEncoding._try_cpp_dynamic_cell_atlas_encode(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func _try_cpp_ecology_visual_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasNativeEncoding._try_cpp_ecology_visual_atlas_encode(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func _try_cpp_dyn_smooth_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasNativeEncoding._try_cpp_dyn_smooth_atlas_encode(baker, map, world, ctx, cells, report, start_idx, end_idx)

static func _try_cpp_ice_state_atlas_encode(baker: MapBaker, map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasNativeEncoding._try_cpp_ice_state_atlas_encode(baker, map, world, ctx, cells, report, start_idx, end_idx)


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
