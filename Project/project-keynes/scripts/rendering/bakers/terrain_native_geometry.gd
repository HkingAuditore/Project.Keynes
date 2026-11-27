extends RefCounted

## Requests native terrain geometry and installs the associated buffers.

const TerrainIndexBakerScript = preload("res://scripts/rendering/bakers/terrain_index_baker.gd")


static func _init_noise(baker: MapBaker, seed_val: int) -> void:
	baker._warp_noise_lo = FastNoiseLite.new()
	baker._warp_noise_lo.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	baker._warp_noise_lo.seed = seed_val + 71
	baker._warp_noise_lo.frequency = baker.WARP_FREQ
	baker._warp_noise_lo.fractal_type = FastNoiseLite.FRACTAL_FBM
	baker._warp_noise_lo.fractal_octaves = 3

	baker._warp_noise_hi = FastNoiseLite.new()
	baker._warp_noise_hi.noise_type = FastNoiseLite.TYPE_SIMPLEX
	baker._warp_noise_hi.seed = seed_val + 233
	baker._warp_noise_hi.frequency = baker.WARP_FREQ * baker.WARP_HIGH_FREQ_MUL
	baker._warp_noise_hi.fractal_type = FastNoiseLite.FRACTAL_FBM
	baker._warp_noise_hi.fractal_octaves = 3

	baker._detail_noise = FastNoiseLite.new()
	baker._detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	baker._detail_noise.seed = seed_val + 503
	baker._detail_noise.frequency = baker.DETAIL_FREQ_BASE
	baker._detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	baker._detail_noise.fractal_octaves = 4

	baker._ridge_noise = FastNoiseLite.new()
	baker._ridge_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	baker._ridge_noise.seed = seed_val + 977
	# [山体去点阵 2026-06-25] 频率 ×2.0→×1.15、octave 4→3：让山脊更宽、峰谷起伏更连绵，
	# 减少写进 height_tex 的高频细脊（避免被 hillshade slope_gain 放大成逐像素"点阵"）。
	baker._ridge_noise.frequency = baker.DETAIL_FREQ_BASE * 1.15
	baker._ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	baker._ridge_noise.fractal_octaves = 3

# ─── C++ terrain-index bake pass wrapper（硬主格 + 静态材质边界数据）─────────
# 复刻 height/biome/moisture fallback 逐像素循环并下移到 C++（run_bake_terrain_index_pass）。
# 成功时设 world 的 5 个 buffer + CSR 三件套 + pixel_to_cell_lookup + cell_pixel_lists，
# 返回 true；ext/方法缺失或返回 fallback / 尺寸不符时返回 false → caller 回退 GDScript。
# dots-total-cpp step2（2026-06-25）：bake 期几何场编排下沉 C++。
# 一次请求 run_bake_geometry_fields_pass → C++ 进程内串起 terrain-index → erosion →
# river → latitude sub-pass（中间 height buffer 不跨语言往返），一次返回完整几何 bundle，
# GDScript 只解包到 world.* + 重建对象侧 lookup。
# 返回 true=融合成功（world 所有几何场已填）；false=ext/方法缺失或返回 fallback → caller
# 回退旧 per-pass 编排（_bake_terrain_index_native + 各单 pass / GDScript ground-truth）。

static func _bake_geometry_fields_native(baker: MapBaker, map: MapData, hex_size: float, world: WorldData, seed_val: int) -> bool:
	if map == null or world == null:
		return false
	if baker._world_ext == null:
		return false
	if not TerrainIndexBakerScript.native_active(baker._world_ext):
		return false
	if baker._warp_noise_lo == null:
		baker._init_noise(world.bake_seed)
	var W: int = world.hm_size.x
	var H: int = world.hm_size.y
	var pix_count: int = W * H
	if pix_count <= 0:
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return false

	# Cell SoA and object lookup are shared with the standalone native path.
	await map.build_indices_cooperative(baker._loading_frames)
	var terrain_inputs: Dictionary = TerrainIndexBakerScript.build_cell_inputs(map)

	# ── 几何参数（合并 sub-pass 所需 knob，origin/hex_size/seed/W/H 共用）──
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var inv_world := Vector2(float(W) / size.x, float(H) / size.y)
	var stroke_radius_px := maxf(hex_size * baker.RIVER_STROKE_HEX_FACTOR * inv_world.x, 0.5)
	var knobs := {
		# 共用
		"width": W, "height": H,
		"origin_x": origin.x, "origin_y": origin.y,
		"hex_size": hex_size, "seed": seed_val,
		# terrain-index
		"map_width": map.width, "map_height": map.height,
		"n_cells": n_cells,
		"size_x": size.x, "size_y": size.y,
		"wrap_period_x": HexUtils.wrap_period_x(map.width, hex_size),
		"sea_level": world.sea_level,
			"cell_elevation": terrain_inputs.get("cell_elevation", PackedFloat32Array()),
			"cell_moisture": terrain_inputs.get("cell_moisture", PackedFloat32Array()),
			"cell_terrain": terrain_inputs.get("cell_terrain", PackedByteArray()),
			"cell_landform": terrain_inputs.get("cell_landform", PackedByteArray()),
			"cell_vegetation": terrain_inputs.get("cell_vegetation", PackedByteArray()),
			"cell_cover": terrain_inputs.get("cell_cover", PackedByteArray()),
			"cell_water_depth": terrain_inputs.get("cell_water_depth", PackedFloat32Array()),
			"offset_to_index": terrain_inputs.get("offset_to_index", PackedInt32Array()),
		# erosion
		"num_drops": baker.EROSION_DROPS,
		"max_steps": baker.EROSION_MAX_STEPS,
		"inertia": baker.EROSION_INERTIA,
		"capacity_factor": baker.EROSION_CAPACITY_FACTOR,
		"min_capacity": baker.EROSION_MIN_CAPACITY,
		"deposit_speed": baker.EROSION_DEPOSIT_SPEED,
		"erode_speed": baker.EROSION_ERODE_SPEED,
		"evaporation": baker.EROSION_EVAPORATION,
		"gravity": baker.EROSION_GRAVITY,
		"brush_radius": baker.EROSION_RADIUS,
		# river SDF
		"inv_world_x": inv_world.x, "inv_world_y": inv_world.y,
		"base_radius_px": stroke_radius_px,
		"sdf_max_dist_px": baker.SDF_MAX_DIST_PX,
		"cr_step": baker.RIVER_CR_STEP,
		# coast SDF carve（water-bodies systemic：海/湖统一岸坡，river carve 之后作用于 height_final）
		"shore_carve_amp": baker.SHORE_CARVE_AMP,
		"shore_carve_band": baker.SHORE_CARVE_BAND,
		"coast_sdf_max_dist_px": baker.COAST_SDF_MAX_DIST_PX,
	}
	knobs.merge(TerrainIndexBakerScript.dem_landform_knobs())
	var rep: Dictionary = await NativeLoadingTasks.compute(baker._world_ext,"geometry",knobs, baker._loading_frames)
	if bool(rep.get("canceled", false)):
		return false
	if rep == null or typeof(rep) != TYPE_DICTIONARY or bool(rep.get("fallback", true)):
		push_warning("[bake_geometry_fields] 融合 pass 返回 fallback（reason=%s）；回退旧 per-pass 编排。"
			% (String(rep.get("reason", "?")) if rep != null and typeof(rep) == TYPE_DICTIONARY else "null"))
		return false

	if not TerrainIndexBakerScript.apply_result(map, world, baker._world_ext, rep, terrain_inputs):
		push_warning("[bake_geometry_fields] terrain buffer/CSR result invalid; falling back.")
		return false

	# ── 解包其余几何场 ──
	var flow: PackedFloat32Array = rep.get("flow_buffer", PackedFloat32Array())
	world.flow_buffer = flow if flow.size() == pix_count else PackedFloat32Array()
	if world.flow_buffer.is_empty():
		world.flow_buffer.resize(pix_count)
	var lat: PackedFloat32Array = rep.get("latitude_buffer", PackedFloat32Array())
	world.latitude_buffer = lat if lat.size() == pix_count else PackedFloat32Array()
	if world.latitude_buffer.is_empty():
		world.latitude_buffer.resize(pix_count)
	# [water-depth-tex] 海/湖统一水深 R8（空 = C++ 未产出 → encode 时退化为空 tex，shader 回退旧路径）。
	var wd_buf: PackedByteArray = rep.get("water_depth_buffer", PackedByteArray())
	world.water_depth_buffer = wd_buf if wd_buf.size() == pix_count else PackedByteArray()
	var proc_h: PackedFloat32Array = rep.get("procedural_height_buffer", PackedFloat32Array())
	baker._baseline_procedural_height = proc_h if proc_h.size() == pix_count else PackedFloat32Array()

	print("    [fused] terrain=%.1fms valley=%.1fms erosion=%.1fms(ok=%s mode=%s grid=%dx%d flow=%.1fms spl=%.1fms x%d dep=%.1fms limit=%.1fms p99=%.6f) river=%.1fms(ok=%s) latitude=%.1fms coast_sdf=%.1fms(ok=%s)" % [
		float(rep.get("terrain_ms", -1.0)), float(rep.get("valley_ms", -1.0)), float(rep.get("erosion_ms", -1.0)), str(bool(rep.get("erosion_ok", false))), String(rep.get("erosion_mode", "?")),
		int(rep.get("erosion_grid_w", -1)), int(rep.get("erosion_grid_h", -1)), float(rep.get("flow_ms", -1.0)), float(rep.get("spl_ms", -1.0)), int(rep.get("spl_iters_effective", -1)),
		float(rep.get("dep_ms", -1.0)), float(rep.get("limit_ms", -1.0)), float(rep.get("spl_p99_drop", -1.0)), float(rep.get("river_ms", -1.0)),
		str(bool(rep.get("river_ok", false))), float(rep.get("latitude_ms", -1.0)), float(rep.get("coast_ms", -1.0)), str(bool(rep.get("coast_ok", false)))])
	if String(rep.get("erosion_mode", "carve")) != "carve" and not bool(rep.get("erosion_ok", false)): push_warning("[bake_geometry_fields] %s 侵蚀分支未执行（日志分项为 -1 即此因）：%s" % [rep.get("erosion_mode", "?"), rep.get("erosion_reason", "")])
	if not bool(rep.get("river_ok", false)):
		push_warning("[bake_geometry_fields] river sub-pass fallback（reason=%s）→ flow 置空（无河流或拓扑缺失）。"
			% String(rep.get("river_reason", "?")))
	return true


static func _bake_terrain_index_native(baker: MapBaker, map: MapData, hex_size: float, world: WorldData) -> bool:
	return TerrainIndexBakerScript.bake(map, world, hex_size, baker._world_ext)


# Isolated compatibility mirror retained until the native/fallback soak closes.

static func _bake_terrain_index_native_legacy(baker: MapBaker, map: MapData, hex_size: float, world: WorldData) -> bool:
	if map == null or world == null:
		return false
	if not TerrainIndexBakerScript.native_active(baker._world_ext):
		return false
	if baker._warp_noise_lo == null:
		baker._init_noise(world.bake_seed)
	var W: int = world.hm_size.x
	var H: int = world.hm_size.y
	var pix_count: int = W * H
	if pix_count <= 0:
		return false
	var n_cells: int = map.cell_count()
	if n_cells <= 0:
		return false
	# 现场从 cell 属性构建 cell SoA（by cell.index）+ offset→index + index→HexCell。
	# 不依赖 has_soa()：bake 期 SoA 可能尚未构建。~n_cells 次（≈2400），零成本。
	var elev_arr := PackedFloat32Array(); elev_arr.resize(n_cells)
	var moist_arr := PackedFloat32Array(); moist_arr.resize(n_cells)
	var terr_arr := PackedByteArray(); terr_arr.resize(n_cells)
	var veg_arr := PackedByteArray(); veg_arr.resize(n_cells)
	var cov_arr := PackedByteArray(); cov_arr.resize(n_cells)
	var o2i := PackedInt32Array(); o2i.resize(map.width * map.height); o2i.fill(-1)
	var cells_by_index: Array = []; cells_by_index.resize(n_cells)
	for cell in map.all_cells():
		if cell == null:
			continue
		var ci: int = int(cell.index)
		if ci < 0 or ci >= n_cells:
			continue
		elev_arr[ci] = cell.elevation
		moist_arr[ci] = cell.moisture
		terr_arr[ci] = int(cell.terrain) & 0xFF
		veg_arr[ci] = int(cell.vegetation) & 0xFF
		cov_arr[ci] = int(cell.cover) & 0xFF
		cells_by_index[ci] = cell
		var off: Vector2i = HexUtils.cube_to_offset(cell.q, cell.r)
		if off.y >= 0 and off.y < map.height:
			o2i[off.y * map.width + posmod(off.x, map.width)] = ci
	var knobs := {
		"width": W, "height": H,
		"map_width": map.width, "map_height": map.height,
		"n_cells": n_cells,
		"origin_x": world.world_bounds.position.x,
		"origin_y": world.world_bounds.position.y,
		"size_x": world.world_bounds.size.x,
		"size_y": world.world_bounds.size.y,
		"hex_size": hex_size,
		"wrap_period_x": HexUtils.wrap_period_x(map.width, hex_size),
		"seed": world.bake_seed,
		"sea_level": world.sea_level,
		"cell_elevation": elev_arr,
		"cell_moisture": moist_arr,
		"cell_terrain": terr_arr,
		"cell_vegetation": veg_arr,
		"cell_cover": cov_arr,
		"offset_to_index": o2i,
	}
	var rep: Dictionary = baker._world_ext.run_bake_terrain_index_pass(knobs)
	if rep == null or bool(rep.get("fallback", true)):
		return false
	var hbuf: PackedFloat32Array = rep.get("height_buffer", PackedFloat32Array())
	var bbuf: PackedByteArray = rep.get("biome_buffer", PackedByteArray())
	var mbuf: PackedFloat32Array = rep.get("moisture_buffer", PackedFloat32Array())
	var vbuf: PackedByteArray = rep.get("vegetation_buffer", PackedByteArray())
	var cbuf: PackedByteArray = rep.get("cover_buffer", PackedByteArray())
	if hbuf.size() != pix_count or bbuf.size() != pix_count or mbuf.size() != pix_count \
			or vbuf.size() != pix_count or cbuf.size() != pix_count:
		return false
	world.height_buffer = hbuf
	world.biome_buffer = bbuf
	world.moisture_buffer = mbuf
	world.vegetation_buffer = vbuf
	world.cover_buffer = cbuf
	TerrainIndexBakerScript._upload_edge_textures(world, baker._world_ext, rep, pix_count)
	# CSR（by cell.index）直接接 encode_bake_enum_atlas_payload；G/B/A 均由硬主 cell 驱动。
	var first_px: PackedInt32Array = rep.get("cell_first_px", PackedInt32Array())
	var pcount: PackedInt32Array = rep.get("cell_px_count", PackedInt32Array())
	var flat: PackedInt32Array = rep.get("flat_px_indices", PackedInt32Array())
	world.cell_first_px_arr = first_px
	world.cell_px_count_arr = pcount
	world.flat_px_indices_arr = flat
	# 重建 GDScript 对象侧反向索引（rebake_*_only / dynamic / eco atlas 路径消费）：
	#   pixel_to_cell_lookup（Array[HexCell]）+ cell_pixel_lists（Dict HexCell→PackedInt32Array）。
	# 两者均按无抖动硬主 cell 归属，保证动态 LUT 与交互索引一致。
	var p2c: PackedInt32Array = rep.get("pixel_to_cell_index", PackedInt32Array())
	world.publish_pixel_lookup_indices(p2c, cells_by_index, pix_count, n_cells)
	return true


# ─── 轻度侵蚀（仅做边界自然平滑） ────────────────────────────────────────
