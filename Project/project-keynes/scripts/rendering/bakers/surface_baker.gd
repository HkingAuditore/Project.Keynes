extends RefCounted
class_name DCSurfaceBaker
const SurfaceTileInputs = preload("res://scripts/rendering/bakers/surface_tile_inputs.gd")
const SurfaceHorizonLayers = preload("res://scripts/rendering/bakers/surface_horizon_layers.gd")

const VisualTileLayoutScript = preload("res://scripts/rendering/visual_tile_layout.gd")
const VisualTileSetScript = preload("res://scripts/rendering/visual_tile_set.gd")
const TerrainIndexBakerScript = preload("res://scripts/rendering/bakers/terrain_index_baker.gd")
const DCAtlasEncoders = preload("res://scripts/rendering/bakers/atlas_encoders.gd")





static func _visual_tile_base_knobs(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		seed_val: int, visual_generation_id: int) -> Dictionary:
	return SurfaceTileInputs._visual_tile_base_knobs(baker, map, world, hex_size, seed_val, visual_generation_id)


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
	var last_upload_frame := -1
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
		# The next native computation can start as soon as this tile is
		# uploaded. Even synchronous compatibility paths upload one per frame.
		if Engine.get_process_frames() == last_upload_frame:
			await baker._yield_generation_frame()
		if generation_id != baker._visual_tile_generation_id or (
				baker._loading_frames != null and baker._loading_frames.canceled):
			tiles.clear()
			return false
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
		last_upload_frame = Engine.get_process_frames()
		layer_reports.append({
			"layer": layer_id,
			"bake_ms": float(bundle.get("elapsed_ms", -1.0)),
			"profile": bundle.get("profile", {}),
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
##   ② **固定 7 层** `terrain_surface_tex`（主地形 shader，少占材质 sampler）：
##      layer0=normal、layer1=relief、layer2=detail（来自 world.terrain_detail_tex，
##      R8→RGBA8 resize LINEAR；null→0x80 中性）、layer3=occluder（来自
##      world.gi_occluder_tex，RGBA8 resize NEAREST；null→0xFF 哨兵）、
##      layer4/5=edge_distance/edge_neighbor（同一个 bundle 的 payload）、
##      layer6=boundary_warp（同一个 bundle 的 boundary_warp；缺失→中性 0x80）。
## 失败时返回 false，调用方走 RG8 粗法线兜底（同样建 7 层 array，其余层为中性）。

static func _bake_legacy_static_surface(baker: MapBaker, map: MapData, world: WorldData, hex_size: float,
		seed_val: int, generation_id: int) -> bool:
	if map == null or world == null:
		return false
	# [cell-field 2026-11-18] 本次烘焙的默认结论：**没有**可用的 warp 层。只有完整走到
	# 「7 层 array 建好且 layer6 来自真实 bundle 载荷」才翻成 true。放在这里是为了让下面
	# 每一条 early-return（native pass 缺失 / 尺寸非法 / bundle fallback / 载荷尺寸不符）
	# 都自动保持 false —— 包括调用方紧接着走的最后兜底 `_upload_legacy_surface_fallback`
	# （那条路径没有 world 参数，所以标志由这里负责清干净）。
	world.terrain_warp_layer_bound = false
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
		"emit_surface_edge_neighbor_rgba": true,
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
	# [terrain-web-baked-surface-A 2026-11-01 / -B 2026-11-01 / cell-field 2026-11-18]
	# 一次建 surface 的 7 个 Image，喂两条消费路径：
	#   ① 2D terrain_normal_tex（植被/建筑/资源/贸易等只开 VT_USE_TERRAIN_NORMAL 的层
	#      继续用 2D sampler；内容与 array layer0 相同，normal 数据因此存两份）；
	#   ② 固定 7 层 terrain_surface_tex（主地形 + 水面 shader）：
	#      layer0=normal、layer1=relief、layer2=detail（R=detail,GBA=0）、
	#      layer3=occluder（RGBA8 两个 16-bit cell id，0xFFFF=哨兵）、
	#      layer4=edge_distance（RGBA8：R 格界距离 / G 沟谷 crease / BA 8 邻域水·湖占比）、
	#      layer5=edge_neighbor（RG 次生 cell id 16-bit；B=water_depth R，A 预留）、
	#      layer6=boundary_warp（RG=边界扭曲场 xy 的 RG8 编码，BA 预留）。
	# [surface-array-edge 2026-11-02] layer4/5 的数据本来就在同一个 native tile bundle 里
	# （run_bake_visual_tile_layer_pass 的 edge_distance / edge_neighbor），因此扩层
	# **不增加任何烘焙计算**，只是把已有 payload 多填两层。
	# [cell-field 2026-11-18] layer6 同理：bundle 的 boundary_warp 与 terrain-index pass 的
	# boundary_warp_buffer 逐字节同源（同一个栅格直搬），扩层同样零新增计算。
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
	# [cell-field 2026-11-18] layer6：边界扭曲场。与 edge 两层同一个 bundle、零新增烘焙；
	# 缺失/尺寸不符时这里拿到中性图（RG=0x80 ⇒ 解码后 warp≈0 ⇒ 直边六边形），
	# 层数因此恒为 7，shader 的 terrain_warp_layer_bound 可以保持 true 而不产生垃圾。
	# 第二项 is_real 决定 world.terrain_warp_layer_bound：**不能**用层数推断（中性层也是 7 层之一）。
	var warp_t0 := Time.get_ticks_msec()
	var warp_data: PackedByteArray = bundle.get("boundary_warp", PackedByteArray())
	var warp_layer: Array = _make_surface_warp_layer(bundle, size)
	var warp_img: Image = warp_layer[0]
	var warp_is_real: bool = bool(warp_layer[1])
	var warp_ms := Time.get_ticks_msec() - warp_t0
	var horizon_layers: Array = _make_surface_horizon_layers(world, size, MapBaker.TERRAIN_HORIZON_MAX_ANGLE)
	var gi_sky_img: Image = horizon_layers[0]
	var horizon_dir0_img: Image = horizon_layers[1]
	var horizon_dir1_img: Image = horizon_layers[2]
	var horizon_layers_real: bool = bool(horizon_layers[3])
	world.terrain_surface_tex = baker._create_surface_array(
		[
			normal_img, relief_img, detail_img, occluder_img,
			edge_layers[0], edge_layers[1], warp_img,
			gi_sky_img, horizon_dir0_img, horizon_dir1_img,
		],
		baker.SURFACE_ARRAY_LAYERS)
	# array 没建起来时 layer6 也不存在（terrain_surface_tex == null，pusher 不会绑），
	# 所以只有"真实载荷 + array 成功"两个条件同时成立才置 true。
	world.terrain_warp_layer_bound = warp_is_real and world.terrain_surface_tex != null
	world.terrain_gi_sky_layer_bound = horizon_layers_real and world.terrain_surface_tex != null
	world.terrain_horizon_dir_layers_bound = horizon_layers_real and world.terrain_surface_tex != null
	var layers_ms := Time.get_ticks_msec() - layers_t0
	print(("[terrain-baked-surface] %s single-tile %dx%d relief_supersample=1 surface_array=%s "
		+ "layers=%d detail_layer=%d occluder_layer=%d water_depth=%s edge_layers=%s "
		+ "warp_layer=%s native_ms=%.1f wall_ms=%d layers_ms=%d edge_ms=%d warp_ms=%d "
		+ "normal_bytes=%d relief_bytes=%d water_bytes=%d edge_distance_bytes=%d "
		+ "edge_neighbor_bytes=%d boundary_warp_bytes=%d") % [
		"web" if OS.has_feature("web") else "desktop-legacy",
		size.x, size.y, "ok" if world.terrain_surface_tex != null else "failed",
		baker.SURFACE_ARRAY_LAYERS,
		1 if world.terrain_detail_tex != null else 0,
		1 if world.gi_occluder_tex != null else 0,
		water_depth_state,
		"ok" if int(edge_layers[2]) >= 0 else "neutral",
		"ok" if warp_is_real else "neutral",
		float(bundle.get("elapsed_ms", -1.0)), wall_ms, layers_ms, edge_ms, warp_ms,
		normal_data.size(), relief_data.size(), water_data.size(),
		int(edge_layers[2]), int(edge_layers[3]), warp_data.size()])
	return true


# [terrain-web-baked-surface-B 2026-11-01 / surface-array-edge 2026-11-02 / cell-field 2026-11-18]
# 非 tiled surface array 的固定层数：0 normal / 1 relief / 2 detail / 3 occluder /
# 4 edge_distance / 5 edge_neighbor / 6 boundary_warp。shader 侧 terrain_surface_layer_count
# 由运行期按实际 get_layers() 推送；层数不足时对应 helper 返回中性值（距离=1 无混合、
# 次生 id=0xFFFF、warp=0x80 ⇒ 零偏移）。

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
	# layer5：优先直接使用 native pass 在后台线程交织好的 RGBA8（<0.5 ms，0 帧主线程阻塞）；
	# 旧 DLL 或缺失时回退到分片 GDScript 交织循环。
	var native_layer5_data: PackedByteArray = bundle.get("edge_neighbor_rgba", PackedByteArray())
	var layer5: Image
	if native_layer5_data.size() == n * 4:
		layer5 = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, native_layer5_data)
	else:
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
		layer5 = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, layer5_data)
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


## [cell-field 2026-11-18] surface array layer6（boundary_warp）。
##
## 数据来自**同一个** native tile bundle 的 `boundary_warp` 键（run_bake_visual_tile_layer_pass
## 逐 texel 直搬 terrain-index pass 的 RG8 结果）：尺寸 = layer_size.x*layer_size.y*2，含
## gutter/halo，行主序 `y*W+x`（`[2i]=R=x`、`[2i+1]=G=y`）。载荷是 RG8，而一条
## Texture2DArray 只能同格式同尺寸，所以这里扩成 RGBA8（RG 两个字节原样保留，B=0、A=255
## 来自 RG8→RGBA8 的自然展开；A 是预留通道，没有读者）。
##
## 为什么用 `Image.convert` 而不是逐像素 GDScript 交织：1024×762 实测交织 32 ms /
## convert 0.8 ms，而这条路径在 Web 上是**唯一**的整图单 tile 烘焙路径（单线程 wasm），
## 32 ms × 3–5 会顶穿加载期 100 ms 心跳断言。convert 的目标格式是本项目到处在用的
## RGBA8（不是"单通道加宽"，那条 wasm 坑不适用），RG 通道已 headless 逐字节核对一致。
##
## 尺寸不符（旧 DLL / canal 刷新分片 / 其它中性化路径）⇒ 返回中性图（RG=0x80 ⇒ 解码后
## warp≈0，通道布局见下一个函数）。
## **返回中性图而不是 null**：`_create_surface_array` 要求正好 7 个同尺寸 Image，null 会让
## 整个 array 建不起来，把本来完好的 normal/relief/detail/occluder/edge 一起丢掉——比
## "warp 为 0、格界退化成直边" 严重得多（对照 `terrain_edge_layers_bound=false` 的语义：
## 边缘数据缺失时也是退化成硬边而不是整张地表回退）。
##
## 返回 `[Image, bool]`（与 `_make_surface_edge_layers` 一样用位置约定）：
##   `[0]` 永远可用的 layer6 Image；`[1]` = true 表示像素**真的**来自 bundle 载荷，
##   false 表示中性兜底。调用方据此推 `world.terrain_warp_layer_bound`（渲染器的
##   `terrain_warp_layer_bound` uniform），不能靠"层数够 7"推断——中性层也是 7 层之一。
static func _make_surface_warp_layer(bundle: Dictionary, size: Vector2i) -> Array:
	var n: int = size.x * size.y
	var expected: int = n * 2
	var warp_data: PackedByteArray = bundle.get("boundary_warp", PackedByteArray())
	if n <= 0 or warp_data.size() != expected:
		push_warning(("[terrain-baked-surface] boundary_warp payload mismatch %d/%d; "
			+ "layer6 neutral (hex edges stay straight)") % [warp_data.size(), expected])
		return [_make_neutral_surface_warp_image(size), false]
	var image := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RG8, warp_data)
	image.convert(Image.FORMAT_RGBA8)
	return [image, true]


## [cell-field 2026-11-18] layer6 中性层：R=G=0x80 ⇒ 解码后 (0x80/255*2-1) ≈ +0.4% ⇒
## 世界偏移 ≈ 0.0025×hex_size（契约里的 0x80 约定，视觉上等价于零偏移 = 直边六边形归属）。
## 与真实载荷走同一条 RG8→RGBA8 展开，所以 B=0、A=255 也一致（A 是预留通道，无读者）。
## 尺寸必须与其他 6 层一致，否则 Texture2DArray 建不起来。
static func _make_neutral_surface_warp_image(size: Vector2i) -> Image:
	var w: int = maxi(size.x, 1)
	var h: int = maxi(size.y, 1)
	var data := PackedByteArray()
	data.resize(w * h * 2)
	data.fill(128)
	var image := Image.create_from_data(w, h, false, Image.FORMAT_RG8, data)
	image.convert(Image.FORMAT_RGBA8)
	return image


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
	# 只 R 通道有语义；使用引擎原生 C++ Image.convert 替代逐像素 GDScript 循环，
	# 保留精确的 R 通道字节并消除加载主线程尖峰。
	var img := src.duplicate() as Image
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
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


static func _make_surface_horizon_layers(world: WorldData, size: Vector2i, max_angle: float) -> Array:
	return SurfaceHorizonLayers._make_surface_horizon_layers(world, size, max_angle)


## [terrain-web-baked-surface-B 2026-11-01] 全通道同值的中性 RGBA8 Image（detail=0x80 /
## occluder=0xFF 兜底层）。**不要**用 Image.create_empty+fill(Color)：Color 是 float，
## 0xFFFF 这类 byte 精确值走 float 往返有舍入风险，这里直接填字节。

static func _make_neutral_rgba_image(baker: MapBaker, size: Vector2i, value: int) -> Image:
	var data := PackedByteArray()
	data.resize(size.x * size.y * 4)
	data.fill(value)
	return Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data)


## [terrain-web-baked-surface-A 2026-11-01 / -B 2026-11-01] 把同尺寸同格式的 RGBA8 Image
## 列表建成 Texture2DArray（主地形 non-tiled 路径的 surface array）。层数固定为
## `baker.SURFACE_ARRAY_LAYERS`（[cell-field 2026-11-18] 6 → 7），
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
## [cell-field 2026-11-18] 再补 layer6 中性层（RG=0x80 ⇒ 零 warp 偏移），使层数恒为 7。
## 本函数**没有** world 参数（签名由 map_baker 的委托方法固定），所以
## `world.terrain_warp_layer_bound = false` 由调用它的那次 `_bake_legacy_static_surface`
## 在函数入口就置好了：map_baker 只在 `_bake_legacy_static_surface` 返回 false 之后才走到
## 这条兜底，因此到这里时标志必定已是 false，无需也不应在这里重复设置。
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
	# [cell-field 2026-11-18] layer6 中性：RG=0x80 ⇒ 解码后 warp≈0，格界退化成直边；
	# 层数仍必须是 7，否则整个 array 建不起来（_create_surface_array 会 push_error + null）。
	out["surface_tex"] = baker._create_surface_array([
		normal_img,
		baker._make_neutral_rgba_image(size, 128),   # layer1 relief：0 坡度
		baker._make_neutral_rgba_image(size, 128),   # layer2 detail：解码后 1.0 恒等
		baker._make_neutral_rgba_image(size, 255),   # layer3 occluder：cell id 哨兵
		baker._make_neutral_surface_edge_image(size),      # layer4 距离 1.0 / 无 crease
		baker._make_neutral_surface_neighbor_image(size),  # layer5 次生 id 0xFFFF
		_make_neutral_surface_warp_image(size),            # layer6 边界扭曲 0x80（零偏移）
		SurfaceHorizonLayers._make_neutral_gi_sky_image(size),                  # layer7 预烘天空可见度 + bent normal
		SurfaceHorizonLayers._make_neutral_horizon_dir_image(size),             # layer8 预烘遮蔽角 E/NE/N/NW
		SurfaceHorizonLayers._make_neutral_horizon_dir_image(size),             # layer9 预烘遮蔽角 W/SW/S/SE
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

