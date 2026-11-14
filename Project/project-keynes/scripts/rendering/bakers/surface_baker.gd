extends RefCounted
class_name DCSurfaceBaker

const VisualTileLayoutScript = preload("res://scripts/rendering/visual_tile_layout.gd")
const VisualTileSetScript = preload("res://scripts/rendering/visual_tile_set.gd")
const TerrainIndexBakerScript = preload("res://scripts/rendering/bakers/terrain_index_baker.gd")
const DCAtlasEncoders = preload("res://scripts/rendering/bakers/atlas_encoders.gd")





static func _visual_tile_base_knobs(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		seed_val: int, visual_generation_id: int) -> Dictionary:
	if map == null or world == null:
		return {}
	var n_cells := map.cell_count()
	var elev := PackedFloat32Array(); elev.resize(n_cells)
	var moist := PackedFloat32Array(); moist.resize(n_cells)
	var terrain := PackedByteArray(); terrain.resize(n_cells)
	var vegetation := PackedByteArray(); vegetation.resize(n_cells)
	var cover := PackedByteArray(); cover.resize(n_cells)
	var water_surface := PackedFloat32Array(); water_surface.resize(n_cells)
	var canal_mask: PackedByteArray = map.canal_edge_mask_arr
	var cell_pos_x: PackedFloat32Array = map.cell_pos_x_arr
	var cell_pos_y: PackedFloat32Array = map.cell_pos_y_arr
	var offset_to_index := PackedInt32Array()
	offset_to_index.resize(map.width * map.height)
	offset_to_index.fill(-1)
	for cell in map.all_cells():
		if cell == null:
			continue
		var ci := int(cell.index)
		if ci < 0 or ci >= n_cells:
			continue
		elev[ci] = cell.elevation
		moist[ci] = cell.moisture
		terrain[ci] = int(cell.terrain) & 0xFF
		vegetation[ci] = int(cell.vegetation) & 0xFF
		cover[ci] = int(cell.cover) & 0xFF
		water_surface[ci] = float(cell.water_depth)
		var off := HexUtils.cube_to_offset(cell.q, cell.r)
		if off.y >= 0 and off.y < map.height:
			offset_to_index[off.y * map.width + posmod(off.x, map.width)] = ci

	var base_knobs := {
		"generation_id": visual_generation_id,
		"map_width": map.width,
		"map_height": map.height,
		"n_cells": n_cells,
		"hex_size": hex_size,
		"seed": seed_val,
		"wrap_period_x": world.wrap_period_x,
		"sea_level": world.sea_level,
		"cell_elevation": elev,
		"cell_moisture": moist,
		"cell_terrain": terrain,
		"cell_vegetation": vegetation,
		"cell_cover": cover,
		"cell_water_depth": water_surface,
		"cell_canal_edge_mask": canal_mask,
		"cell_pos_x": cell_pos_x,
		"cell_pos_y": cell_pos_y,
		"neighbor_indices": map.neighbor_indices_packed(),
		"canal_stroke_hex_factor": 0.045,
		"cell_landform": baker._landform_bytes_for_map(map),
		"offset_to_index": offset_to_index,
		"baseline_width": world.hm_size.x,
		"baseline_height": world.hm_size.y,
		"baseline_origin_x": world.world_bounds.position.x,
		"baseline_origin_y": world.world_bounds.position.y,
		"baseline_size_x": world.world_bounds.size.x,
		"baseline_size_y": world.world_bounds.size.y,
		"baseline_height_buffer": world.height_buffer,
		"baseline_procedural_height_buffer": baker._baseline_procedural_height,
		"baseline_flow_buffer": world.flow_buffer,
		"baseline_water_depth_buffer": world.water_depth_buffer,
		"algorithm_halo_px": 8,
		# [normal-soften 2026-07-31] 默认 0.035→0.01：高频 residual 写进 height 后被运行期
		# 1-texel 细节法线 × slope_gain=8 放大成全图砂砾。滤半径同步放宽，残差更平滑。
		"residual_amp": float(ProjectSettings.get_setting(
			"project_keynes/rendering/map_tiles/residual_amp", 0.01)),
		"residual_filter_hex": float(ProjectSettings.get_setting(
			"project_keynes/rendering/map_tiles/residual_filter_hex", 0.06)),
		"procedural_detail_gain": float(ProjectSettings.get_setting(
			"project_keynes/rendering/map_tiles/procedural_detail_gain", 1.0)),
		"river_stroke_hex_factor": baker.RIVER_STROKE_HEX_FACTOR,
		"sdf_max_dist_px": baker.SDF_MAX_DIST_PX,
		"shore_carve_amp": baker.SHORE_CARVE_AMP,
		"shore_carve_band": baker.SHORE_CARVE_BAND,
		"coast_sdf_max_dist_px": baker.COAST_SDF_MAX_DIST_PX,
		"normal_sample_radius_hex": baker.TERRAIN_NORMAL_SAMPLE_RADIUS_HEX,
		"normal_height_scale_hex": baker.TERRAIN_NORMAL_HEIGHT_SCALE_HEX,
	}
	base_knobs.merge(TerrainIndexBakerScript.dem_landform_knobs())
	return base_knobs


## [terrain-web-baked-surface 2026-11-01] 单张静态地表烘焙的目标分辨率。
##
## 以 world_bounds 的宽高比为准，最长边封顶 cap；边长取偶数（纹理半 texel 中心 +
## 与 hm_size 的比例对齐都更干净）。world_bounds 非法时退化成 cap×cap。
## 纯静态，给测试单独覆盖「Web LOW 512 / Web MID/HIGH 1024 / 桌面 legacy 1024」三种上限。

static func _bake_visual_tiles(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		seed_val: int, generation_id: int) -> bool:
	baker._visual_tile_base_knobs_cache.clear()
	baker._visual_tile_refresh_layers.clear()
	if map == null or world == null:
		return false
	# Web exports run the whole baker on the browser's single WASM thread. The
	# Compatibility Texture2DArray path allocates and uploads static field arrays before
	# yielding, which can make WebGL2 appear hung during map generation.
	# [terrain-web-baked-surface 2026-11-01] Web 改为整图单 tile 静态烘焙 normal/relief
	# （见 _bake_legacy_static_surface），避免 Texture2DArray 生成期卡顿；tiled 才有的
	# edge/water/detail 通道在 Web 上不绑（shader 侧对应宏已裁掉）。
	if OS.has_feature("web"):
		world.visual_tiles = null
		print("  visual tiles: legacy (web_single_thread_fallback; whole-map single-tile static bake)")
		return false
	var quality := baker._visual_tile_quality_setting()
	var layout = VisualTileLayoutScript.resolve(
		world.world_bounds, world.wrap_period_x, quality, OS.has_feature("mobile"),
		{"generation_id": generation_id, "hex_size": hex_size}
	)
	# [mobile-density 2026-11-03] 真机验收日志：layout 一解析完就打印，**先于** native pass。
	# 这样即使后面回退 legacy（末行的 bake_report 只在成功时打印），也能在 adb logcat 里
	# 直接看到手机实际拿到的档位 / 请求密度 / 生效密度 / 层数与稳态显存。
	print("  visual tile layout: profile=%s requested=%.2f effective=%.2f hex_grid=%s layers=%d resident=%.2fMB peak=%.2fMB degrade=%s"
		% [layout.profile, layout.requested_texels_per_hex, layout.effective_texels_per_hex,
			str(layout.grid_size), layout.layer_count,
			float(layout.estimated_resident_bytes) / 1048576.0,
			float(layout.estimated_peak_bytes) / 1048576.0,
			layout.degradation_reason if not layout.degradation_reason.is_empty() else "none"])
	if layout.mode == VisualTileLayoutScript.MODE_LEGACY:
		world.visual_tiles = null
		print("  visual tiles: legacy (%s)" % layout.fallback_reason)
		return false
	if baker._world_ext == null or not baker._world_ext.has_method("run_bake_visual_tile_layer_pass"):
		layout.mode = VisualTileLayoutScript.MODE_LEGACY
		layout.fallback_reason = "native_visual_tile_pass_missing"
		world.visual_tiles = null
		push_warning("[visual-tiles] native pass unavailable; using legacy textures")
		return false

	var tiles = VisualTileSetScript.new()
	if not tiles.initialize_empty(layout):
		layout.mode = VisualTileLayoutScript.MODE_LEGACY
		layout.fallback_reason = tiles.fallback_reason
		world.visual_tiles = tiles
		push_warning("[visual-tiles] Texture2DArray allocation failed: %s" % tiles.fallback_reason)
		return false

	# [terrain-web-baked-surface 2026-11-01] 公共 knob 组装抽成 _visual_tile_base_knobs()：
	# tiled 逐层烘焙与 legacy/Web 整图单 tile 烘焙必须用**同一份**基线/邻域契约，
	# 否则两条路径产出的 normal/relief 会不一致。relief_supersample 由调用方覆盖。
	var base_knobs: Dictionary = baker._visual_tile_base_knobs(
		map, world, hex_size, seed_val, generation_id)
	base_knobs["relief_supersample"] = layout.relief_scale
	var texel_world: Vector2 = layout.visual_domain.size / Vector2(layout.logical_size)
	var layer_reports: Array[Dictionary] = []
	var bake_t0 := Time.get_ticks_usec()
	for layer_id in range(layout.layer_count):
		if generation_id != baker._visual_tile_generation_id:
			tiles.fallback_reason = "stale_generation"
			tiles.clear()
			world.visual_tiles = tiles
			return false
		var tile_xy := Vector2i(layer_id % layout.grid_size.x,
			layer_id / layout.grid_size.x)
		var interior_origin: Vector2 = layout.visual_domain.position + Vector2(
			tile_xy.x * layout.interior_size.x,
			tile_xy.y * layout.interior_size.y) * texel_world
		var physical_origin: Vector2 = interior_origin - Vector2.ONE * layout.gutter_px * texel_world
		var physical_size: Vector2 = Vector2(layout.layer_size) * texel_world
		var knobs: Dictionary = base_knobs.duplicate(false)
		knobs.merge({
			"layer_id": layer_id,
			"width": layout.layer_size.x,
			"height": layout.layer_size.y,
			"origin_x": physical_origin.x,
			"origin_y": physical_origin.y,
			"size_x": physical_size.x,
			"size_y": physical_size.y,
		}, true)
		var layer_t0 := Time.get_ticks_usec()
		var bundle: Dictionary = await NativeLoadingTasks.compute(baker._world_ext,"visual_tile",knobs, baker._loading_frames)
		if bundle == null or bool(bundle.get("fallback", true)) \
				or int(bundle.get("generation_id", -1)) != generation_id:
			tiles.fallback_reason = "native_layer_failed:%d:%s" % [
				layer_id, String(bundle.get("reason", "invalid_bundle"))]
			tiles.clear()
			layout.mode = VisualTileLayoutScript.MODE_LEGACY
			layout.fallback_reason = tiles.fallback_reason
			world.visual_tiles = tiles
			push_warning("[visual-tiles] %s; using complete legacy path" % tiles.fallback_reason)
			return false
		var upload_t0 := Time.get_ticks_usec()
		if not tiles.upload_layer_bundle(layer_id, bundle):
			tiles.clear()
			layout.mode = VisualTileLayoutScript.MODE_LEGACY
			layout.fallback_reason = tiles.fallback_reason
			world.visual_tiles = tiles
			push_warning("[visual-tiles] layer upload failed: %s" % tiles.fallback_reason)
			return false
		layer_reports.append({
			"layer": layer_id,
			"bake_ms": float(bundle.get("elapsed_ms", -1.0)),
			"upload_ms": float(Time.get_ticks_usec() - upload_t0) / 1000.0,
			"wall_ms": float(Time.get_ticks_usec() - layer_t0) / 1000.0,
			"normal_radius_px": Vector2i(
				int(bundle.get("normal_radius_x_px", 0)),
				int(bundle.get("normal_radius_y_px", 0))),
			"raster_scale": Vector2(
				float(bundle.get("raster_scale_x", 1.0)),
				float(bundle.get("raster_scale_y", 1.0))),
			"distance_scale": float(bundle.get("distance_scale", 1.0)),
			"river_sdf_max_dist_px": float(bundle.get("river_sdf_max_dist_px", baker.SDF_MAX_DIST_PX)),
			"coast_sdf_max_dist_px": float(bundle.get("coast_sdf_max_dist_px", baker.COAST_SDF_MAX_DIST_PX)),
			"shore_carve_band_px": int(bundle.get("shore_carve_band_px", baker.SHORE_CARVE_BAND)),
			"edge_distance_units": String(bundle.get("edge_distance_units", "normalized_hex_center_gap")),
			"edge_distance_saturate_hex": float(bundle.get("edge_distance_saturate_hex", 0.90)),
			"hashes": bundle.get("hashes", {}),
		})
		await baker._yield_generation_frame()

	tiles.static_ready = true
	# Horizon starts neutral. The renderer's asynchronous tiled horizon module replaces
	# all layers atomically; until then no partially baked shadow field is exposed.
	tiles.horizon_ready = false
	tiles.ready = true
	tiles.bake_report = layout.diagnostic_report()
	tiles.bake_report.merge({
		"path": "visual_tiled_static",
		"renderer": RenderingServer.get_current_rendering_method(),
		"total_ms": float(Time.get_ticks_usec() - bake_t0) / 1000.0,
		"layers": layer_reports,
		"horizon_path": "neutral_pending",
	}, true)
	world.visual_tiles = tiles
	baker._visual_tile_base_knobs_cache = base_knobs
	print("  visual tiles: %s" % JSON.stringify(tiles.bake_report))
	return true


## [terrain-web-baked-surface 2026-11-01 / -A 2026-11-01 / -B 2026-11-01] Web 全部档位 +
## 桌面 legacy 回退的**单张静态地表**烘焙。
##
## 用户硬诉求：桌面与 Web 都不允许再跑"运行期高度差分法线"。tiled 桌面路径已由
## visual_terrain_normal/relief_tiles 数组提供；这里复用同一个 native pass
## （run_bake_visual_tile_layer_pass），把整张地图当作**一个 tile** 烘：
##   - origin/size = world.world_bounds（整图）
##   - width/height 取封顶尺寸（Lead 真机探针：1024 单张 ~265 ms native，wasm 3–5× 可接受）
##   - relief_supersample = 1（normal / relief 同尺寸，才能合进同一个 Texture2DArray）
## native pass 输出（见 world_ext_bake.cpp 布局注释）：
##   terrain_normal : RG=粗法线 xy（0.5+n*0.5），BA=近景高度细节坡度 encode_slope
##   terrain_relief : RG=粗段细节坡度，BA=细段细节坡度 encode_slope
## 一次上传两条消费路径：
##   ① 2D `terrain_normal_tex`（仅 normal，给植被/建筑/资源/贸易等其它层）；
##   ② **固定 4 层** `terrain_surface_tex`（主地形 shader，少占材质 sampler）：
##      layer0=normal、layer1=relief、layer2=detail（来自 world.terrain_detail_tex，
##      R8→RGBA8 resize LINEAR；null→0x80 中性）、layer3=occluder（来自
##      world.gi_occluder_tex，RGBA8 resize NEAREST；null→0xFF 哨兵）。
## 失败时返回 false，调用方走 RG8 粗法线兜底（同样建 4 层 array，detail/occluder 为中性）。

static func _bake_legacy_static_surface(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		seed_val: int, generation_id: int) -> bool:
	if map == null or world == null:
		return false
	if baker._world_ext == null or not baker._world_ext.has_method("run_bake_visual_tile_layer_pass"):
		push_warning("[terrain-baked-surface] native visual tile pass unavailable; using RG8 normal fallback")
		return false
	var cap := baker.LEGACY_STATIC_SURFACE_MAX_DIM_WEB if OS.has_feature("web") \
		else baker.LEGACY_STATIC_SURFACE_MAX_DIM
	var size := baker.resolve_legacy_static_surface_size(
		world.world_bounds.size, world.hm_size, cap)
	if size.x < 2 or size.y < 2:
		push_warning("[terrain-baked-surface] invalid target size %s" % str(size))
		return false
	var knobs: Dictionary = baker._visual_tile_base_knobs(map, world, hex_size, seed_val, generation_id)
	if knobs.is_empty():
		push_warning("[terrain-baked-surface] base knobs unavailable")
		return false
	# 整图单 tile：宽高/世界矩形都覆盖基线的 tile 分片参数；halo 仍由 native pass 自己加，
	# 这样法线/relief 采样在图像四边也有正确的邻域（wrap 由 wrap_period_x 处理）。
	knobs.merge({
		"layer_id": 0,
		"width": size.x,
		"height": size.y,
		"origin_x": world.world_bounds.position.x,
		"origin_y": world.world_bounds.position.y,
		"size_x": world.world_bounds.size.x,
		"size_y": world.world_bounds.size.y,
		"relief_supersample": 1,
		"algorithm_halo_px": 8,
	}, true)
	var t0 := Time.get_ticks_msec()
	var bundle: Dictionary = await NativeLoadingTasks.compute(baker._world_ext, "visual_tile", knobs, baker._loading_frames)
	var wall_ms := Time.get_ticks_msec() - t0
	if bundle == null or bool(bundle.get("fallback", true)):
		push_warning("[terrain-baked-surface] single-tile bake failed: %s"
			% String(bundle.get("reason", "invalid_bundle") if bundle != null else "null_bundle"))
		return false
	if int(bundle.get("generation_id", generation_id)) != generation_id:
		push_warning("[terrain-baked-surface] stale generation %s (want %d)"
			% [str(bundle.get("generation_id", -1)), generation_id])
		return false
	var normal_data: PackedByteArray = bundle.get("terrain_normal", PackedByteArray())
	var relief_data: PackedByteArray = bundle.get("terrain_relief", PackedByteArray())
	var expected := size.x * size.y * 4
	if normal_data.size() != expected or relief_data.size() != expected:
		push_warning("[terrain-baked-surface] payload size mismatch normal=%d relief=%d expected=%d (%dx%d)"
			% [normal_data.size(), relief_data.size(), expected, size.x, size.y])
		return false
	# [terrain-web-baked-surface-A 2026-11-01 / -B 2026-11-01] 一次建 surface 的 6 个 Image，
	# 喂两条消费路径：
	#   ① 2D terrain_normal_tex（植被/建筑/资源/贸易等只开 VT_USE_TERRAIN_NORMAL 的层
	#      继续用 2D sampler；内容与 array layer0 相同，normal 数据因此存两份）；
	#   ② 固定 6 层 terrain_surface_tex（主地形 + 水面 shader）：
	#      layer0=normal、layer1=relief、layer2=detail（R=detail,GBA=0）、
	#      layer3=occluder（RGBA8 两个 16-bit cell id，0xFFFF=哨兵）、
	#      layer4=edge_distance（RGBA8：R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比）、
	#      layer5=edge_neighbor（RG 次生 cell id 16-bit；B=water_depth R，A 预留）。
	# [surface-array-edge 2026-11-02] layer4/5 的数据本来就在同一个 native tile bundle 里
	# （run_bake_visual_tile_layer_pass 的 edge_distance / edge_neighbor），因此扩层
	# **不增加任何烘焙计算**，只是把已有 payload 多填两层。
	var normal_img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, normal_data)
	var relief_img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, relief_data)
	var layers_t0 := Time.get_ticks_msec()
	var detail_img := baker._make_surface_detail_layer(world, size)
	var occluder_img := baker._make_surface_occluder_layer(world, size)
	if world.terrain_normal_tex != null \
			and world.terrain_normal_tex.get_size() == Vector2(float(size.x), float(size.y)) \
			and world.terrain_normal_tex.get_format() == Image.FORMAT_RGBA8:
		world.terrain_normal_tex.update(normal_img)
	else:
		world.terrain_normal_tex = ImageTexture.create_from_image(normal_img)
	# [C 2026-11-01] 非 tiled 水深升级 RGBA8：native pass 同一个 bundle 里已经有
	# water_depth（RGBA8：R=水深，G/B/A=湖/礁/海带 3×3 软权重），直接上传成世界纹理。
	# compact water 用 max(二元权重, 软权重)；GBA=0 时自动退化为旧二元行为。
	# [surface-array-edge 2026-11-02] 同一份 water_data 的 R 也塞进 layer5.B，
	# 陆地侧因此能在没有 water_depth sampler 的预算程序里拿到水深覆盖场。
	var water_depth_state := "off"
	var water_data: PackedByteArray = bundle.get("water_depth", PackedByteArray())
	if water_data.size() == expected:
		world.water_depth_tex = DCAtlasEncoders._upload_rgba8(
			water_data, size.x, size.y, world.water_depth_tex)
		water_depth_state = "RGBA8"
	else:
		world.water_depth_tex = null
		push_warning("[terrain-baked-surface] water_depth payload mismatch %d/%d; water depth disabled"
			% [water_data.size(), expected])
	var edge_t0 := Time.get_ticks_msec()
	var edge_layers: Array = await baker._make_surface_edge_layers(bundle, size, water_data, expected)
	var edge_ms := Time.get_ticks_msec() - edge_t0
	world.terrain_surface_tex = baker._create_surface_array(
		[normal_img, relief_img, detail_img, occluder_img, edge_layers[0], edge_layers[1]],
		baker.SURFACE_ARRAY_LAYERS)
	var layers_ms := Time.get_ticks_msec() - layers_t0
	print(("[terrain-baked-surface] %s single-tile %dx%d relief_supersample=1 surface_array=%s "
		+ "layers=%d detail_layer=%d occluder_layer=%d water_depth=%s edge_layers=%s "
		+ "native_ms=%.1f wall_ms=%d layers_ms=%d edge_ms=%d normal_bytes=%d relief_bytes=%d "
		+ "water_bytes=%d edge_distance_bytes=%d edge_neighbor_bytes=%d") % [
		"web" if OS.has_feature("web") else "desktop-legacy",
		size.x, size.y, "ok" if world.terrain_surface_tex != null else "failed",
		baker.SURFACE_ARRAY_LAYERS,
		1 if world.terrain_detail_tex != null else 0,
		1 if world.gi_occluder_tex != null else 0,
		water_depth_state,
		"ok" if int(edge_layers[2]) >= 0 else "neutral",
		float(bundle.get("elapsed_ms", -1.0)), wall_ms, layers_ms, edge_ms,
		normal_data.size(), relief_data.size(), water_data.size(),
		int(edge_layers[2]), int(edge_layers[3])])
	return true


# [terrain-web-baked-surface-B 2026-11-01 / surface-array-edge 2026-11-02] 非 tiled
# surface array 的固定层数：0 normal / 1 relief / 2 detail / 3 occluder /
# 4 edge_distance / 5 edge_neighbor。shader 侧 terrain_surface_layer_count 由运行期按实际
# get_layers() 推送；层数不足时对应 helper 返回中性值（距离=1 无混合、次生 id=0xFFFF）。

static func _make_surface_edge_layers(baker: MapBaker, bundle: Dictionary, size: Vector2i,
		water_data: PackedByteArray, water_expected: int) -> Array:
	var n := size.x * size.y
	var distance_bytes := int(size.x) * int(size.y) * 4
	var neighbor_bytes := int(size.x) * int(size.y) * 2
	var distance_data: PackedByteArray = bundle.get("edge_distance", PackedByteArray())
	var neighbor_data: PackedByteArray = bundle.get("edge_neighbor", PackedByteArray())
	var has_distance := distance_data.size() == distance_bytes
	var has_neighbor := neighbor_data.size() == neighbor_bytes
	if not has_distance:
		push_warning("[terrain-baked-surface] edge_distance payload mismatch %d/%d; layer4 neutral"
			% [distance_data.size(), distance_bytes])
	if not has_neighbor:
		push_warning("[terrain-baked-surface] edge_neighbor payload mismatch %d/%d; layer5 neutral"
			% [neighbor_data.size(), neighbor_bytes])
	# layer4：逐字节搬运（不做格式转换，避免 8-bit 量化二次误差）。
	var layer4: Image
	if has_distance:
		layer4 = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, distance_data)
	else:
		layer4 = baker._make_neutral_surface_edge_image(size)
	# layer5：一次循环把 RG8 的次生 id 与 water_depth.R 交织成 RGBA8。
	# [surface-array-edge 2026-11-02] 分片写 + 每片 await 一帧：桌面 1024×762 实测
	# 全量一次跑是 58 ms，wasm 按 3–5× 估会到 200–300 ms —— 那会把加载主线程卡穿
	# （cooperative_world_generation_test 的 100 ms 心跳断言）。分片后单片 ≈ 8–12 ms。
	var layer5_data := PackedByteArray()
	layer5_data.resize(n * 4)
	var has_depth := water_data.size() == water_expected and water_expected > 0
	var slice_pixels := 65536
	for slice_start in range(0, n, slice_pixels):
		var slice_end: int = mini(slice_start + slice_pixels, n)
		for i in range(slice_start, slice_end):
			var o := i * 4
			if has_neighbor:
				layer5_data[o] = neighbor_data[i * 2]
				layer5_data[o + 1] = neighbor_data[i * 2 + 1]
			else:
				layer5_data[o] = 255
				layer5_data[o + 1] = 255
			layer5_data[o + 2] = water_data[o] if has_depth else 0
			layer5_data[o + 3] = 0
		if slice_end < n:
			await baker._yield_generation_frame()
	var layer5 := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, layer5_data)
	return [layer4, layer5,
		distance_bytes if has_distance else 0, neighbor_bytes if has_neighbor else 0]


## [surface-array-edge 2026-11-02] layer4 中性层：R=255（次生权重 0）、G/B/A=0。
## **不能**用 `_make_neutral_rgba_image(size, 255)`：那会把 crease 与海岸占比也填成 1.0。

static func _make_neutral_surface_edge_image(baker: MapBaker, size: Vector2i) -> Image:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	for i in range(size.x * size.y):
		data[i * 4] = 255
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)


## [surface-array-edge 2026-11-02] layer5 中性层：RG=0xFFFF（次生 id 哨兵 = 无次生格）、
## B=0（水深 0）、A=0（预留）。

static func _make_neutral_surface_neighbor_image(baker: MapBaker, size: Vector2i) -> Image:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	for i in range(size.x * size.y):
		data[i * 4] = 255
		data[i * 4 + 1] = 255
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)


## [terrain-web-baked-surface-B 2026-11-01] surface array layer2（detail）：
## world.terrain_detail_tex（R8；Compatibility 下被加宽成 RG8）→ 只取 R 通道 →
## RGBA8（GBA=0）→ resize 到 surface 尺寸（BILINEAR，连续噪声平滑放大）。
## null/空图 → 全 0x80（shader 解码后 detail=1.0 恒等）。

static func _make_surface_detail_layer(baker: MapBaker, world: WorldData, size: Vector2i) -> Image:
	var src: Image = null
	if world != null and world.terrain_detail_tex != null:
		src = world.terrain_detail_tex.get_image()
	if src == null or src.is_empty():
		return baker._make_neutral_rgba_image(size, 128)
	var W := src.get_width()
	var H := src.get_height()
	if W <= 0 or H <= 0:
		return baker._make_neutral_rgba_image(size, 128)
	var fmt := src.get_format()
	var sdata := src.get_data()
	var rgba := PackedByteArray()
	rgba.resize(W * H * 4)
	if fmt == Image.FORMAT_RG8:
		for i in range(W * H):
			var o := i * 4
			rgba[o] = sdata[i * 2]
		# GBA 保持 0（只 R 通道有语义）。
	elif fmt == Image.FORMAT_R8 or fmt == Image.FORMAT_L8:
		for i in range(W * H):
			rgba[i * 4] = sdata[i]
	elif fmt == Image.FORMAT_RGBA8:
		for i in range(W * H):
			rgba[i * 4] = sdata[i * 4]
	else:
		# 未知格式：转 RGBA8 兜底（detail 是低频噪声，格式转换的精度损失可接受）。
		var tmp := src.duplicate() as Image
		tmp.convert(Image.FORMAT_RGBA8)
		W = tmp.get_width()
		H = tmp.get_height()
		sdata = tmp.get_data()
		rgba.resize(W * H * 4)
		for i in range(W * H):
			rgba[i * 4] = sdata[i * 4]
	var img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, rgba)
	if W != size.x or H != size.y:
		# detail 是连续噪声，双线性放大即可（Godot 4 枚举名是 BILINEAR，没有 LINEAR）。
		img.resize(size.x, size.y, Image.INTERPOLATE_BILINEAR)
	return img


## [terrain-web-baked-surface-B 2026-11-01] surface array layer3（GI 遮挡源 cell id）：
## world.gi_occluder_tex（RGBA8，hm 分辨率；每个 texel = 两个 16-bit cell.index，
## 0xFFFF=无）→ resize 到 surface 尺寸。**必须 NEAREST**：16-bit id 的两个字节一旦被
## 线性插值就会变成别的 cell（`Image.resize` 的 NEAREST 对字节无污染，已 headless 验证）。
## null/空图 → 全 0xFF（哨兵 65535 = 无遮挡源，shader GI bounce 关闭）。

static func _make_surface_occluder_layer(baker: MapBaker, world: WorldData, size: Vector2i) -> Image:
	var src: Image = null
	if world != null and world.gi_occluder_tex != null:
		src = world.gi_occluder_tex.get_image()
	if src == null or src.is_empty() or src.get_format() != Image.FORMAT_RGBA8:
		return baker._make_neutral_rgba_image(size, 255)
	if src.get_width() != size.x or src.get_height() != size.y:
		src.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
	return src


## [terrain-web-baked-surface-B 2026-11-01] 全通道同值的中性 RGBA8 Image（detail=0x80 /
## occluder=0xFF 兜底层）。**不要**用 Image.create_empty+fill(Color)：Color 是 float，
## 0xFFFF 这类 byte 精确值走 float 往返有舍入风险，这里直接填字节。

static func _make_neutral_rgba_image(baker: MapBaker, size: Vector2i, value: int) -> Image:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	data.fill(value)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)


## [terrain-web-baked-surface-A 2026-11-01 / -B 2026-11-01] 把同尺寸同格式的 RGBA8 Image
## 列表建成 Texture2DArray（主地形 non-tiled 路径的 surface array）。B 方案固定 4 层，
## 所以这里显式校验层数：层数不符说明有 layer 没造出来，push_error 返回 null
## （调用方据此把 terrain_baked_normals 置 false，shader 用平地法线）。

static func _create_surface_array(baker: MapBaker, images: Array, expected_layers: int = 2) -> Texture2DArray:
	if images.size() != expected_layers:
		push_error("[terrain-baked-surface] surface array needs %d layers, got %d"
			% [expected_layers, images.size()])
		return null
	var array := Texture2DArray.new()
	var err := array.create_from_images(images)
	if err != OK:
		push_error("[terrain-baked-surface] terrain_surface_tex create_from_images failed: %s"
			% error_string(err))
		return null
	return array


## [terrain-web-baked-surface-A 2026-11-01 / -B 2026-11-01] 单 tile 烘焙失败时的 RG8 粗法线兜底。
## 把 RG8 数据扩成 RGBA8（R,G=原法线；B,A=128=零坡度）作为 2D normal 也作为 array layer0；
## layer1 填全 128 的中性 relief，layer2 detail=0x80（解码后=1.0），layer3 occluder=0xFF
## （cell id 哨兵 65535）。shader 因此仍走完整烘焙法线/relief 路径、detail/occluder 为中性 ——
## 等价于旧的"仅粗法线"兜底，而不是退回运行期高度差分。
## [surface-array-edge 2026-11-02] 同步补 layer4/5 中性层：R=255（距离 1.0 ⇒ 次生权重 0）、
## G/BA=0；次生 id 全 0xFFFF（65535 哨兵 ⇒ decode 返回 -1，硬主 cell 边界）。
## 返回 {"normal_tex": ImageTexture 或 null, "surface_tex": Texture2DArray 或 null}。

static func _upload_legacy_surface_fallback(baker: MapBaker, rg8_data: PackedByteArray, size: Vector2i,
		existing_normal: ImageTexture) -> Dictionary:
	var out := {"normal_tex": null, "surface_tex": null}
	var W := size.x
	var H := size.y
	var expected := W * H * 2
	if W <= 0 or H <= 0 or rg8_data.size() != expected:
		push_warning("[terrain-baked-surface] RG8 normal fallback payload invalid: %d bytes (want %d for %dx%d)"
			% [rg8_data.size(), expected, W, H])
		return out
	var n := W * H
	var rgba := PackedByteArray(); rgba.resize(n * 4)
	for i in range(n):
		var o := i * 4
		rgba[o] = rg8_data[i * 2]
		rgba[o + 1] = rg8_data[i * 2 + 1]
		rgba[o + 2] = 128
		rgba[o + 3] = 128
	var normal_img := Image.create_from_data(W, H, false, Image.FORMAT_RGBA8, rgba)
	if existing_normal != null \
			and existing_normal.get_size() == Vector2(float(W), float(H)) \
			and existing_normal.get_format() == Image.FORMAT_RGBA8:
		existing_normal.update(normal_img)
		out["normal_tex"] = existing_normal
	else:
		out["normal_tex"] = ImageTexture.create_from_image(normal_img)
	# layer4 中性：只有 R=255，其余通道 0（不能用 _make_neutral_rgba_image(size, 255)，
	# 那会把 G/BA 也填成 1.0 ⇒ 假 crease + 假海岸占比）。
	out["surface_tex"] = baker._create_surface_array([
		normal_img,
		baker._make_neutral_rgba_image(size, 128),   # layer1 relief：0 坡度
		baker._make_neutral_rgba_image(size, 128),   # layer2 detail：解码后 1.0 恒等
		baker._make_neutral_rgba_image(size, 255),   # layer3 occluder：cell id 哨兵
		baker._make_neutral_surface_edge_image(size),      # layer4 距离 1.0 / 无 crease
		baker._make_neutral_surface_neighbor_image(size),  # layer5 次生 id 0xFFFF
	], baker.SURFACE_ARRAY_LAYERS)
	return out


## [C 2026-11-01] 非 tiled 水深兜底：单 tile 烘焙失败时没有 bundle.water_depth，
## 用旧 R8 `water_depth_buffer` 扩成 RGBA8（R=水深、GBA=0 无软权重）上传。
## compact water 的 `max(二元权重, 软权重)` 因此退化为旧的二元行为，画质与 B 回合等价。

static func _upload_legacy_water_depth_fallback(baker: MapBaker, world: WorldData) -> ImageTexture:
	if world == null or world.water_depth_buffer.is_empty():
		return null
	var W := world.derived_size.x
	var H := world.derived_size.y
	if W <= 0 or H <= 0 or world.water_depth_buffer.size() < W * H:
		push_warning("[terrain-baked-surface] water depth fallback buffer invalid (%d bytes for %dx%d)"
			% [world.water_depth_buffer.size(), W, H])
		return null
	var n := W * H
	var rgba := PackedByteArray()
	rgba.resize(n * 4)
	for i in range(n):
		rgba[i * 4] = world.water_depth_buffer[i]
		# GBA 保持 0：没有软权重数据。
	return DCAtlasEncoders._upload_rgba8(rgba, W, H, world.water_depth_tex)



static func queue_canal_visual_refresh(baker: MapBaker, map: MapData, world: WorldData,
		dirty_cells: PackedInt32Array) -> Dictionary:
	var out := {"ok": false, "queued_layers": 0, "reason": "visual_tiles_unavailable"}
	if map == null or world == null or dirty_cells.is_empty() \
			or world.visual_tiles == null or not world.visual_tiles.ready \
			or baker._visual_tile_base_knobs_cache.is_empty() or baker._world_ext == null:
		return out
	var layout = world.visual_tiles.layout
	if layout == null or layout.generation_id != baker._visual_tile_generation_id:
		out["reason"] = "visual_tile_generation_stale"
		return out
	var positions := PackedInt32Array()
	positions.append_array(dirty_cells)
	var neighbors: PackedInt32Array = map.neighbor_indices_packed()
	for cell in dirty_cells:
		if cell < 0 or cell >= map.cell_count():
			continue
		for direction in range(6):
			var neighbor: int = neighbors[cell * 6 + direction]
			if neighbor >= 0:
				positions.append(neighbor)
	for cell in positions:
		if cell < 0 or cell >= map.cell_pos_x_arr.size() \
				or cell >= map.cell_pos_y_arr.size():
			continue
		var address: Dictionary = layout.world_to_tile_address(Vector2(
			map.cell_pos_x_arr[cell], map.cell_pos_y_arr[cell]))
		if not bool(address.get("valid", false)):
			continue
		var tile: Vector2i = address.get("tile", Vector2i.ZERO)
		# Include the one-layer ring so the SDF/normal halo remains seam-free.
		for oy in range(-1, 2):
			for ox in range(-1, 2):
				var tx: int = tile.x + ox
				var ty: int = tile.y + oy
				if layout.wrap_x:
					tx = posmod(tx, layout.grid_size.x)
				if tx < 0 or tx >= layout.grid_size.x or ty < 0 or ty >= layout.grid_size.y:
					continue
				baker._visual_tile_refresh_layers[ty * layout.grid_size.x + tx] = true
	out["ok"] = true
	out["reason"] = "ok"
	out["queued_layers"] = baker._visual_tile_refresh_layers.size()
	if not baker._visual_tile_refresh_running:
		baker._drain_canal_visual_refresh(map, world)
	return out



static func _drain_canal_visual_refresh(baker: MapBaker, map: MapData, world: WorldData) -> void:
	baker._visual_tile_refresh_running = true
	while not baker._visual_tile_refresh_layers.is_empty():
		await baker._yield_generation_frame()
		if map == null or world == null or world.visual_tiles == null \
				or world.visual_tiles.layout == null \
				or world.visual_tiles.layout.generation_id != baker._visual_tile_generation_id:
			break
		var layer_ids: Array = baker._visual_tile_refresh_layers.keys()
		layer_ids.sort()
		var layer_id: int = int(layer_ids[0])
		if baker._rebake_canal_visual_layer(map, world, layer_id):
			baker._visual_tile_refresh_layers.erase(layer_id)
		else:
			push_warning("[canal-visual] layer %d rebake failed; retained for retry" % layer_id)
	baker._visual_tile_refresh_running = false



static func _rebake_canal_visual_layer(baker: MapBaker, map: MapData, world: WorldData, layer_id: int) -> bool:
	var tiles = world.visual_tiles
	var layout = tiles.layout
	if layer_id < 0 or layer_id >= layout.layer_count:
		return true
	var knobs: Dictionary = baker._visual_tile_base_knobs_cache.duplicate(false)
	knobs["cell_canal_edge_mask"] = map.canal_edge_mask_arr
	knobs["canal_refresh_only"] = true
	var texel_world: Vector2 = layout.visual_domain.size / Vector2(layout.logical_size)
	var tile_xy := Vector2i(layer_id % layout.grid_size.x,
		layer_id / layout.grid_size.x)
	var interior_origin: Vector2 = layout.visual_domain.position + Vector2(
		tile_xy.x * layout.interior_size.x,
		tile_xy.y * layout.interior_size.y) * texel_world
	var physical_origin: Vector2 = interior_origin - \
		Vector2.ONE * layout.gutter_px * texel_world
	var physical_size: Vector2 = Vector2(layout.layer_size) * texel_world
	knobs.merge({
		"layer_id": layer_id,
		"width": layout.layer_size.x,
		"height": layout.layer_size.y,
		"origin_x": physical_origin.x,
		"origin_y": physical_origin.y,
		"size_x": physical_size.x,
		"size_y": physical_size.y,
	}, true)
	var bundle: Dictionary = baker._world_ext.run_bake_visual_tile_layer_pass(knobs)
	return bundle != null and not bool(bundle.get("fallback", true)) \
		and int(bundle.get("generation_id", -1)) == baker._visual_tile_generation_id \
		and tiles.upload_layer_bundle(layer_id, bundle)



static func _visual_tile_quality_setting(baker: MapBaker) -> String:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return "auto"
	var settings := tree.root.get_node_or_null("GameSettings")
	if settings == null or not settings.has_method("values"):
		return "auto"
	return String(settings.values().get("render_quality", "auto"))

# ─── Phase 2：增量重新烘焙 biome_tex ────────────────────────────────────────
# 季节切换时只需重画 biome（其他 buffer 不变），单次只跑 ~80ms。
# 注意：调用此方法前必须保证 `_warp_noise_lo/hi` 等已 init（一般通过先跑过 bake_world）。
# 若 baker 是新建的实例，请先调用 `_init_noise(seed_val)`。


static func rebake_biome_tex_only(baker: MapBaker, map: MapData, world: WorldData, hex_size: float) -> void:
	baker.rebake_biome_axes_only(map, world, hex_size)

# Milestone 3：仅重烘 cover_tex（biome/vegetation 不动），给 day-tick 用。
# 跑同一遍 warp + cube_round，但只写 cover_buffer + 编码一张 R8 tex。
# 比 rebake_biome_axes_only 快 ~3 倍（~25-30ms vs 80ms）。

static func rebake_cover_tex_only(baker: MapBaker, map: MapData, world: WorldData, hex_size: float) -> void:
	baker._rebake_single_axis(map, world, hex_size, "cover")

# Milestone 4：仅重烘 vegetation_tex（biome/cover 不动），给植被演替触发用。
# 同样的 warp + cube_round + 单 R8 编码路径，开销与 cover-only 相同。

static func rebake_vegetation_tex_only(baker: MapBaker, map: MapData, world: WorldData, hex_size: float) -> void:
	baker._rebake_single_axis(map, world, hex_size, "vegetation")

static func compute_world_bounds(width: int, height: int, hex_size: float) -> Rect2:
	if width <= 0 or height <= 0:
		return Rect2()
	var w := float(width)
	var h := float(height)
	var px := sqrt(3.0) * hex_size * (w + 0.5)
	var py := 1.5 * hex_size * h + 0.5 * hex_size
	return Rect2(
		Vector2(-hex_size * 2.0, -hex_size * 2.0),
		Vector2(px + hex_size * 4.0, py + hex_size * 4.0)
	)

