extends RefCounted

## Rebuilds biome axis pixel buffers and publishes their updated textures.

const TerrainBakerScript = preload("res://scripts/rendering/bakers/terrain_baker.gd")
const TerrainGeometryScript = preload("res://scripts/rendering/bakers/terrain_geometry_utils.gd")

static func _rebake_single_axis(baker: MapBaker, map: MapData, world: WorldData, hex_size: float, axis: String) -> void:
	var report_t0_us: int = Time.get_ticks_usec()
	if world == null:
		return
	var target_buf: PackedByteArray
	var fallback_default: int
	match axis:
		"cover":
			if world.cover_buffer.is_empty():
				return
			target_buf = world.cover_buffer
			fallback_default = int(CoverType.CV.NONE)
		"vegetation":
			if world.vegetation_buffer.is_empty():
				return
			target_buf = world.vegetation_buffer
			fallback_default = int(VegetationType.VEG.NONE)
		_:
			return
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if baker._try_cpp_enum_axis_patch(map, world, axis, report_t0_us):
		return

	# Fast path：lookup + cell_pixel_lists 都齐全 → 走增量路径
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()
	if has_lookup and has_cell_lists:
		var cache_dict: Dictionary
		var cache_size_ref: Vector2i
		if axis == "cover":
			cache_dict = baker._last_cover_cell_bytes
			cache_size_ref = baker._cover_cache_size
		else:
			cache_dict = baker._last_vegetation_cell_bytes
			cache_size_ref = baker._vegetation_cache_size

		var cache_valid: bool = (cache_size_ref == Vector2i(W, H) \
				and target_buf.size() == pix_count \
				and not cache_dict.is_empty())

		if not cache_valid:
			# ───── 首次构建：完整 fast path 重写 buffer + 初始化 cell byte 快照 ─────
			var patch_t0_us: int = Time.get_ticks_usec()
			if target_buf.size() != pix_count:
				target_buf.resize(pix_count)
			var lookup_init := world.pixel_to_cell_lookup
			cache_dict = {}
			if axis == "cover":
				for i in range(pix_count):
					var c0: HexCell = lookup_init[i]
					target_buf[i] = (int(c0.cover) if c0 != null else fallback_default) & 0xFF
				# 用 cell_pixel_lists 的 keys 一次性建立 byte 快照（每 cell 只 lookup 一次）
				for cell_key in world.cell_pixel_lists.keys():
					var cc: HexCell = cell_key
					cache_dict[cc] = int(cc.cover) & 0xFF
				baker._last_cover_cell_bytes = cache_dict
				baker._cover_cache_size = Vector2i(W, H)
				world.cover_buffer = target_buf
			else:
				for i in range(pix_count):
					var c1: HexCell = lookup_init[i]
					target_buf[i] = (int(c1.vegetation) if c1 != null else fallback_default) & 0xFF
				for cell_key in world.cell_pixel_lists.keys():
					var cv: HexCell = cell_key
					cache_dict[cv] = int(cv.vegetation) & 0xFF
				baker._last_vegetation_cell_bytes = cache_dict
				baker._vegetation_cache_size = Vector2i(W, H)
				world.vegetation_buffer = target_buf
			var patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
			# vegetation/cover 已由 enum_lut 消费；map-index atlas 不需要上传。
			baker._record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
				float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
				cache_dict.size(), 0, patch_ms, 0.0, 0.0, false)
			return

		# ───── 增量路径：典型每日 ─────
		# 遍历所有 cell，逐 cell 比对 byte。命中 byte 不变 → continue（0 像素操作）。
		# 变了 → 把 cell_pixel_lists[cell] 的所有像素批量写入 target_buf。
		# vegetation/cover 不再写 map-index atlas；只更新 CPU buffer/cache，LUT 刷新消费这些值。
		var any_dirty: bool = false
		var dirty_cells: int = 0
		var dirty_pixels: int = 0
		var cell_lists: Dictionary = world.cell_pixel_lists
		var patch_t0_us: int = Time.get_ticks_usec()
		if axis == "cover":
			for cell_key in cell_lists.keys():
				var cc2: HexCell = cell_key
				var b: int = int(cc2.cover) & 0xFF
				var prev_b: int = int(cache_dict.get(cc2, -1))
				if b == prev_b:
					continue
				cache_dict[cc2] = b
				any_dirty = true
				dirty_cells += 1
				var pixels: PackedInt32Array = cell_lists[cell_key]
				dirty_pixels += pixels.size()
				for px in pixels:
					target_buf[px] = b
			baker._last_cover_cell_bytes = cache_dict
			world.cover_buffer = target_buf
		else:
			for cell_key in cell_lists.keys():
				var cv2: HexCell = cell_key
				var b: int = int(cv2.vegetation) & 0xFF
				var prev_b: int = int(cache_dict.get(cv2, -1))
				if b == prev_b:
					continue
				cache_dict[cv2] = b
				any_dirty = true
				dirty_cells += 1
				var pixels: PackedInt32Array = cell_lists[cell_key]
				dirty_pixels += pixels.size()
				for px in pixels:
					target_buf[px] = b
			baker._last_vegetation_cell_bytes = cache_dict
			world.vegetation_buffer = target_buf
		var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0

		if not any_dirty:
			baker._record_enum_atlas_upload_report(axis, "skipped_no_dirty",
				float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
				0, 0, buffer_patch_ms, 0.0, 0.0, true)
			return  # 所有 cell byte 都没变 → 连 GPU 上传都跳过
		baker._record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return

	# Slow fallback：完整重跑 warp + cube_round（保留兼容性，正常不会走到）
	if baker._warp_noise_lo == null:
		baker._init_noise(world.bake_seed)
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * baker.WARP_AMP
	var wrap_period_x := HexUtils.wrap_period_x(map.width, hex_size)

	var patch_t0_us: int = Time.get_ticks_usec()
	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var warp_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base, wy_base, wrap_period_x, hex_size)
			var warp_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base + 31.7, wy_base - 17.3, wrap_period_x, hex_size, 1.0, 31.7)
			var hi_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base + 91.1, wy_base + 53.7, wrap_period_x, hex_size, 1.0, 91.1) * baker.WARP_HIGH_AMP_RATIO
			var hi_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base - 41.5, wy_base + 23.9, wrap_period_x, hex_size, 1.0, -41.5) * baker.WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale
			var cube_f := TerrainGeometryScript.world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := TerrainGeometryScript.cube_round(cube_f)
			var self_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, rounded)
			var v: int
			if axis == "cover":
				v = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)
			else:
				v = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			target_buf[row + x] = v & 0xFF
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	if axis == "cover":
		world.cover_buffer = target_buf
	else:
		world.vegetation_buffer = target_buf
	baker.prewarm_dynamic_axis_caches(map, world)
	baker._record_enum_atlas_upload_report(axis, "lut_only_no_map_index_upload",
		float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
		world.cell_pixel_lists.size(), 0, buffer_patch_ms, 0.0, 0.0, false)

# Milestone 2 / J 增量：季节切换时同步重烘 biome / vegetation / cover 三张 R8 纹理。
# height / moisture / flow / latitude / wind / ocean 全部不动。
#
# 旧路径（130ms / season）：完整 _rewrite_axis_buffers（620k 像素 × 3 byte）+
# _encode_enum_atlas（620k 像素 × 3 byte 交错 + Image.create + tex.update）。
#
# J 新路径：与 _rebake_single_axis 同结构，把 biome / veg / cover 3 轴的 sig 缓存
# 一起遍历。多数季节切换只翻少数边界 cell 的 terrain，veg / cover 在前序 stage 已
# 部分更新，sig 不变直接跳过；变了才把 cell.pixel 列表批量写到 buf + 直写
# `_enum_atlas_data` 对应通道。最后用 cached interleaved data 做 tex.update()。

static func rebake_biome_axes_only(baker: MapBaker, map: MapData, world: WorldData, hex_size: float) -> void:
	var report_t0_us: int = Time.get_ticks_usec()
	if world == null or world.biome_buffer.is_empty():
		return
	if baker._warp_noise_lo == null:
		baker._init_noise(world.bake_seed)
	elif baker._detail_noise == null or baker._ridge_noise == null:
		baker._init_noise(world.bake_seed)
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	if baker._try_cpp_enum_axes_patch(map, world, report_t0_us):
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(
			world, hex_size, baker._detail_noise, baker._ridge_noise, baker._world_ext,
			baker.TERRAIN_DETAIL_BAKE_MIN, baker.TERRAIN_DETAIL_BAKE_MAX)
		return
	var has_lookup: bool = world.pixel_to_cell_lookup.size() == pix_count
	var has_cell_lists: bool = not world.cell_pixel_lists.is_empty()

	# Cache validity：3 轴 sig + interleaved data 都得齐才走增量。
	var cache_valid: bool = (has_lookup \
			and has_cell_lists \
			and baker._biome_cache_size == Vector2i(W, H) \
			and baker._vegetation_cache_size == Vector2i(W, H) \
			and baker._cover_cache_size == Vector2i(W, H) \
			and baker._enum_atlas_data_size == Vector2i(W, H) \
			and baker._enum_atlas_data.size() == pix_count * 4 \
			and not baker._last_biome_cell_bytes.is_empty() \
			and not baker._last_vegetation_cell_bytes.is_empty() \
			and not baker._last_cover_cell_bytes.is_empty() \
			and world.biome_buffer.size() == pix_count \
			and world.vegetation_buffer.size() == pix_count \
			and world.cover_buffer.size() == pix_count)

	if not cache_valid:
		# Fallback：完整路径（首次 / 任意缓存失效）。同步顺便把 3 轴 sig + interleaved data 都建好。
		var patch_t0_us: int = Time.get_ticks_usec()
		baker._rewrite_axis_buffers(map, hex_size, world)
		var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex = baker._encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex, world, map
		)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		baker.prewarm_dynamic_axis_caches(map, world)
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(
			world, hex_size, baker._detail_noise, baker._ridge_noise, baker._world_ext,
			baker.TERRAIN_DETAIL_BAKE_MIN, baker.TERRAIN_DETAIL_BAKE_MAX)
		baker._record_enum_atlas_upload_report("biome", "fallback_full_rewrite",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			world.cell_pixel_lists.size(), pix_count, buffer_patch_ms, 0.0, upload_ms, false)
		return

	# 增量路径：遍历 ~2400 cell，逐 cell 比 3 轴 byte。
	var biome_buf := world.biome_buffer
	var veg_buf := world.vegetation_buffer
	var cover_buf := world.cover_buffer
	var cell_lists: Dictionary = world.cell_pixel_lists
	var biome_dirty: int = 0
	var veg_dirty: int = 0
	var cover_dirty: int = 0
	var dirty_pixels: int = 0
	var patch_t0_us: int = Time.get_ticks_usec()
	for cell_key in cell_lists.keys():
		var cell: HexCell = cell_key
		if cell == null:
			continue
		var b_t: int = int(cell.terrain) & 0xFF
		var b_v: int = int(cell.vegetation) & 0xFF
		var b_c: int = int(cell.cover) & 0xFF
		var prev_t: int = int(baker._last_biome_cell_bytes.get(cell, -1))
		var prev_v: int = int(baker._last_vegetation_cell_bytes.get(cell, -1))
		var prev_c: int = int(baker._last_cover_cell_bytes.get(cell, -1))
		if b_t == prev_t and b_v == prev_v and b_c == prev_c:
			continue
		var pixels: PackedInt32Array = cell_lists[cell_key]
		if b_t != prev_t:
			baker._last_biome_cell_bytes[cell] = b_t
			biome_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				biome_buf[px] = b_t
				baker._enum_atlas_data[px * 4] = b_t
		if b_v != prev_v:
			baker._last_vegetation_cell_bytes[cell] = b_v
			veg_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				veg_buf[px] = b_v
		if b_c != prev_c:
			baker._last_cover_cell_bytes[cell] = b_c
			cover_dirty += 1
			dirty_pixels += pixels.size()
			for px in pixels:
				cover_buf[px] = b_c
	world.biome_buffer = biome_buf
	world.vegetation_buffer = veg_buf
	world.cover_buffer = cover_buf
	var buffer_patch_ms: float = float(Time.get_ticks_usec() - patch_t0_us) / 1000.0
	var dirty_cells: int = biome_dirty + veg_dirty + cover_dirty

	if dirty_cells == 0:
		baker._record_enum_atlas_upload_report("biome", "skipped_no_dirty",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			0, 0, buffer_patch_ms, 0.0, 0.0, true)
		return  # 全 3 轴 byte 都没变 → 连 GPU 上传都跳过
	if biome_dirty == 0:
		baker._record_enum_atlas_upload_report("biome", "lut_only_no_map_index_upload",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, 0.0, true)
		return

	# tex.update via cached map-index data；只在 biome/R 通道变化时上传。
	if world.enum_atlas_tex != null and world.enum_atlas_tex.get_size() == Vector2(float(W), float(H)):
		var image_t0_us: int = Time.get_ticks_usec()
		var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, baker._enum_atlas_data)
		var image_ms: float = float(Time.get_ticks_usec() - image_t0_us) / 1000.0
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex.update(img)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		baker._record_enum_atlas_upload_report("biome", "cached_full_update",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, true)
	else:
		var upload_t0_us: int = Time.get_ticks_usec()
		world.enum_atlas_tex = baker._encode_enum_atlas(
			world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
			world.derived_size, world.enum_atlas_tex, world, map
		)
		var upload_ms: float = float(Time.get_ticks_usec() - upload_t0_us) / 1000.0
		baker._record_enum_atlas_upload_report("biome", "fallback_full_rewrite",
			float(Time.get_ticks_usec() - report_t0_us) / 1000.0,
			dirty_cells, dirty_pixels, buffer_patch_ms, 0.0, upload_ms, false)
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(
			world, hex_size, baker._detail_noise, baker._ridge_noise, baker._world_ext,
			baker.TERRAIN_DETAIL_BAKE_MIN, baker.TERRAIN_DETAIL_BAKE_MAX)

# 重写 biome / vegetation / cover 三个 buffer，但保持 height/moisture/flow 不动

static func _rewrite_axis_buffers(baker: MapBaker, map: MapData, hex_size: float, world: WorldData) -> void:
	var W := world.derived_size.x
	var H := world.derived_size.y
	var pix_count := W * H
	var biome_buf := world.biome_buffer
	var veg_buf := world.vegetation_buffer
	var cover_buf := world.cover_buffer
	if veg_buf.size() != pix_count:
		veg_buf.resize(pix_count)
	if cover_buf.size() != pix_count:
		cover_buf.resize(pix_count)
	if biome_buf.size() != pix_count:
		biome_buf.resize(pix_count)

	# v9.perf：fast path → 走 pixel_to_cell_lookup，避免 78 万次 noise + cube_round
	if world.pixel_to_cell_lookup.size() == pix_count:
		var lookup := world.pixel_to_cell_lookup
		for i in range(pix_count):
			var c: HexCell = lookup[i]
			if c != null:
				biome_buf[i] = int(c.terrain) & 0xFF
				veg_buf[i] = int(c.vegetation) & 0xFF
				cover_buf[i] = int(c.cover) & 0xFF
			else:
				biome_buf[i] = int(TerrainType.TERRAIN.OCEAN) & 0xFF
				veg_buf[i] = int(VegetationType.VEG.NONE) & 0xFF
				cover_buf[i] = int(CoverType.CV.NONE) & 0xFF
		world.biome_buffer = biome_buf
		world.vegetation_buffer = veg_buf
		world.cover_buffer = cover_buf
		return

	# Slow fallback：完整重跑 warp + cube_round（兼容旧路径）
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * baker.WARP_AMP
	var wrap_period_x := HexUtils.wrap_period_x(map.width, hex_size)

	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x
			var warp_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base, wy_base, wrap_period_x, hex_size)
			var warp_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_lo, wx_base + 31.7, wy_base - 17.3, wrap_period_x, hex_size, 1.0, 31.7)
			var hi_x := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base + 91.1, wy_base + 53.7, wrap_period_x, hex_size, 1.0, 91.1) * baker.WARP_HIGH_AMP_RATIO
			var hi_y := TerrainGeometryScript.cyl_noise(baker._warp_noise_hi, wx_base - 41.5, wy_base + 23.9, wrap_period_x, hex_size, 1.0, -41.5) * baker.WARP_HIGH_AMP_RATIO
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale
			var cube_f := TerrainGeometryScript.world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := TerrainGeometryScript.cube_round(cube_f)
			var self_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, rounded)
			var terrain_self: int = int(self_cell.terrain) if self_cell != null else int(TerrainType.TERRAIN.OCEAN)
			var veg_self: int = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			var cover_self: int = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)
			var idx := row + x
			biome_buf[idx] = terrain_self & 0xFF
			veg_buf[idx] = veg_self & 0xFF
			cover_buf[idx] = cover_self & 0xFF
	world.biome_buffer = biome_buf
	world.vegetation_buffer = veg_buf
	world.cover_buffer = cover_buf

# ─── 内部：分辨率 / 噪声初始化 ──────────────────────────────────────────
