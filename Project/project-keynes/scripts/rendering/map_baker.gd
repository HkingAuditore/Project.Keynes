class_name MapBaker
extends "res://scripts/rendering/map_bake_cache.gd"

const InitialTerrainBake = preload("res://scripts/rendering/initial_terrain_bake.gd")
const MapBakeCacheReset = preload("res://scripts/rendering/map_bake_cache_reset.gd")

# 生成期阶段进度信号。main.gd 的 splash overlay 接此信号显示阶段提示，
# 避免开场 ~13 秒黑屏体感。fraction 是该阶段相对总耗时的估计值（0.0..1.0
# 累积），不是精确百分比；目的是让用户知道在跑哪一步、还差多少。
# stage 取值（按 emit 顺序）：
#   "terrain"    — height/biome/moisture fallback / erosion / river SDF / latitude
#   "physical"   — _bake_initial_physical_circulation / vector buffers
#   "atlas"      — dynamic / ecology / smooth / ice atlas 初始化
#   "encode"     — _encode_*_tex / atlas 整体编码
#   "done"       — bake_world 全部完成（fraction=1.0）
signal stage_progress(stage: String, fraction: float)

const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
const VisualTileLayoutScript = preload("res://scripts/rendering/visual_tile_layout.gd")
const VisualTileSetScript = preload("res://scripts/rendering/visual_tile_set.gd")
const ClimateBakerScript = preload("res://scripts/rendering/bakers/climate_baker.gd")
const TerrainBakerScript = preload("res://scripts/rendering/bakers/terrain_baker.gd")
const TerrainIndexBakerScript = preload("res://scripts/rendering/bakers/terrain_index_baker.gd")
const TerrainGeometryScript = preload("res://scripts/rendering/bakers/terrain_geometry_utils.gd")
const DynamicAtlasBakerScript = preload("res://scripts/rendering/bakers/dynamic_atlas_baker.gd")
const OceanCurrentBakerScript = preload("res://scripts/rendering/bakers/ocean_current_baker.gd")
const PhysicalCirculationBakerScript = preload("res://scripts/rendering/bakers/physical_circulation_baker.gd")
const SurfaceBakerScript = preload("res://scripts/rendering/bakers/surface_baker.gd")
const CellLutBakerScript = preload("res://scripts/rendering/bakers/cell_lut_baker.gd")
const PhysicalSolveBakerScript = preload("res://scripts/rendering/bakers/physical_solve_baker.gd")
# Physical Wind & Ocean Circulation：hex 域物理化求解器。当
# ClimateProfile.physical_circulation_enabled = true 时，bake_world / 切片烘焙
# 路径用它替换 ny-only 风场 + Ekman 洋流的旧实现，输出从 hex 字段（cell.wind_vector
# / cell.ocean_current / cell.upwelling_strength 等）光栅化到现有 buffer，shader 零改动。
const PhysCircSolverScript = preload("res://scripts/rendering/physical_circulation_solver.gd")

func _physical_cell_slice_enabled(profile: ClimateProfile) -> bool:
	return PhysicalCirculationBakerScript._physical_cell_slice_enabled(self, profile)
func _physical_cell_slice_divisor(profile: ClimateProfile) -> int:
	return PhysicalCirculationBakerScript._physical_cell_slice_divisor(self, profile)
func _bake_initial_physical_circulation(map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> void:
	return PhysicalCirculationBakerScript._bake_initial_physical_circulation(self, map, world, hex_size, cfg)
func _bake_initial_vector_buffers(map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> void:
	return PhysicalCirculationBakerScript._bake_initial_vector_buffers(self, map, world, hex_size, cfg)
func _update_ocean_current_flow_texture(world: WorldData) -> void:
	return PhysicalCirculationBakerScript._update_ocean_current_flow_texture(self, world)
func run_deferred_initial_physical_circulation(map: MapData, world: WorldData, hex_size: float, cfg: MapConfig) -> bool:
	return PhysicalCirculationBakerScript.run_deferred_initial_physical_circulation(self, map, world, hex_size, cfg)
func run_deferred_initial_cell_luts(map: MapData, world: WorldData) -> Dictionary:
	return PhysicalCirculationBakerScript.run_deferred_initial_cell_luts(self, map, world)
static func compute_world_bounds(width: int, height: int, hex_size: float) -> Rect2:
	return SurfaceBakerScript.compute_world_bounds(width, height, hex_size)
func bake_world(map: MapData, cfg: MapConfig, hex_size: float, seed_val: int) -> WorldData:
	_visual_tile_generation_id += 1
	var visual_generation_id := _visual_tile_generation_id
	_last_bake_map = map
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_val
	_init_noise(seed_val)

	MapBakeCacheReset.reset_for_bake(self)

	var world := WorldData.new()
	world.world_bounds = compute_world_bounds(map.width, map.height, hex_size)
	world.wrap_period_x = HexUtils.wrap_period_x(map.width, hex_size)
	world.hm_size = _resolve_hm_size(world.world_bounds)
	world.derived_size = world.hm_size  # 统一分辨率
	world.sea_level = cfg.sea_level
	world.bake_seed = seed_val

	var t_total := Time.get_ticks_msec()
	print("MapBaker v6: hm=%s seed=%d" % [world.hm_size, seed_val])
	# 安卓黑屏体感修复：bake_world 一次性 ~13s 期间 main.gd 的 splash overlay
	# 接 stage_progress 信号显示阶段进度。fraction 是按 logcat 实测耗时估的累积
	# 进度（不是精确百分比）。
	stage_progress.emit("terrain", 0.0)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null

	# dots-total-cpp step2（2026-06-25）：bake 期几何场编排下沉 C++——一次
	# run_bake_geometry_fields_pass 在 C++ 进程内串起 terrain-index → erosion → river →
	# latitude（中间 height buffer 不跨语言往返），GDScript 只解包。融合不可用 /
	# 返回 fallback 时回退到下方旧 per-pass 编排（terrain-index native / GDScript ground-truth）。
	var t := Time.get_ticks_msec()
	var pix_count := world.hm_size.x * world.hm_size.y
	_baseline_procedural_height = PackedFloat32Array()
	var fused: bool = await _bake_geometry_fields_native(map, hex_size, world, seed_val)
	if _loading_frames != null and _loading_frames.canceled:
		return null
	if fused:
		print("  geometry fields (fused C++): %dms" % (Time.get_ticks_msec() - t))
	else:
		InitialTerrainBake.bake_geometry_fallback(self, map, world, hex_size, seed_val, pix_count, t)

	# 风/洋流/上升流像素 buffer：先在 hex 域求解物理场，再把 per-cell 真值
	# 光栅化回 vector_atlas，供主地图海洋 tint / 水面风驱细节和 WeatherLayer advection 消费。

	stage_progress.emit("physical", 0.62)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null
	_bake_initial_physical_circulation(map, world, hex_size, cfg)
	_bake_initial_vector_buffers(map, world, hex_size, cfg)

	# Emergent Climate Coupling：sea_ice_fraction buffer 保持兼容数据通道。
	# 主地图海冰视觉已改为 shader 直接按水温派生，不依赖此贴图光栅化。
	# [sea-ice-atlas-skip 2026-06-16] flag 关（默认）→ 不再分配空 R8 buffer（无采样者，
	# 仅 dots_soak_dump 调试哈希读它，n==0 时自有兜底）。
	world.sea_ice_fraction_buffer = PackedByteArray()
	if DCFeatureFlags.sea_ice_atlas_active():
		world.sea_ice_fraction_buffer.resize(world.derived_size.x * world.derived_size.y)

	# 动态视觉状态统一由 map_index_atlas + LUT 提供，不再初始化逐像素 dynamic/smooth/eco/ice atlas。
	stage_progress.emit("atlas", 0.82)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null

	# 编码纹理：height+flow 打进同一张 RGBA8（RG=16-bit height，B=flow）；map_index 独立；
	# 动态视觉走 LUT。hm_size==derived_size，分辨率可合；Web 省 1 个材质 sampler。
	stage_progress.emit("encode", 0.88)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null
	t = Time.get_ticks_msec()
	world.height_tex = await DCAtlasEncoders.encode_height_flow_tex_async(
		world.height_buffer, world.flow_buffer, world.hm_size, world.height_tex, _world_ext, _loading_frames)
	# 独立 flow_tex 退役：legacy shader 从 height_tex.B 读 flow。字段保留以兼容旧诊断/存档读。
	world.flow_tex = null
	# [terrain-web-baked-surface 2026-11-01] 旧的 RG8 粗法线烘焙已移到 _bake_visual_tiles 之后：
	# 单张 normal/relief 由 _bake_legacy_static_surface（整图单 tile native pass）产出；
	# 只有那条路径失败时才回退这里的老 RG8 编码（无 BA/relief 通道，shader 只用粗法线）。
	stage_progress.emit("encode", 0.90)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null
	# [terrain-web-baked-surface-B 2026-11-01] enum atlas 提前到 horizon 之前烘：
	# Web 的 horizon bundle 要同时产出 GI 遮挡源 cell id（occluder），而 occluder 需要
	# map_index bytes 里的 G/B（cell.index 低/高字节）把命中像素反查成 cell。
	# _encode_enum_atlas 会把 RGBA8 payload 缓存在 _enum_atlas_data，Web 分支直接复用。
	world.enum_atlas_tex = _encode_enum_atlas(
		world.biome_buffer, world.vegetation_buffer, world.cover_buffer,
		world.derived_size, null, world, map
	)
	InitialTerrainBake.bake_horizon(self, world, hex_size)
	prewarm_dynamic_axis_caches(map, world)
	stage_progress.emit("encode", 0.93)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null
	world.scalar_atlas_tex = null
	# flow 已在 encode_height_flow_tex 打进 height_tex.B；此处不再单独 encode_flow_tex。
	world.sea_ice_tex = null
	# [water-depth-tex 2026-06-26 / C 2026-11-01] 海/湖统一水深。
	# tiled 路径：主地形走 visual_water_depth_tiles，这里保留旧 2D R8 上传（见下方 tiled 分支）。
	# 非 tiled 路径：水深改由 _bake_legacy_static_surface 从 native bundle 上传 **RGBA8**
	# （R=水深，GBA=湖/礁/海带软权重），upload 已移到 static surface bake 之后。
	var detail_payload: Dictionary = await NativeLoadingTasks.compute(_world_ext,"terrain_detail",{
		"width":world.derived_size.x,"height":world.derived_size.y,"seed":seed_val,
		"origin_x":world.world_bounds.position.x,"origin_y":world.world_bounds.position.y,
		"size_x":world.world_bounds.size.x,"size_y":world.world_bounds.size.y,
		"wrap_period_x":world.wrap_period_x,"hex_size":hex_size,
		"min_detail":TERRAIN_DETAIL_BAKE_MIN,"max_detail":TERRAIN_DETAIL_BAKE_MAX}, _loading_frames)
	if not bool(detail_payload.get("fallback",true)):
		world.terrain_detail_tex = DCAtlasEncoders.encode_r8_tex(detail_payload.data,world.derived_size,world.terrain_detail_tex,_world_ext)
	else:
		world.terrain_detail_tex = TerrainBakerScript.rebake_terrain_detail_texture(world,hex_size,_detail_noise,_ridge_noise,_world_ext,TERRAIN_DETAIL_BAKE_MIN,TERRAIN_DETAIL_BAKE_MAX)
	# [terrain-web-baked-surface 2026-11-01 / -A 2026-11-01 / -B 2026-11-01] 静态地表
	# normal/relief/detail/occluder 的最终来源：
	#   ① tiled 桌面：visual_tiles 的 normal/relief/detail/water 数组（tiled 烘焙时已上传）→
	#      非 tiled 字段（2D normal / surface array）置 null；
	#   ② Web 全部档位 / 桌面 legacy 回退：整图单 tile native pass 烘 normal+relief，
	#      上传 2D terrain_normal_tex（其它层用）+ 固定 7 层 terrain_surface_tex（主地形与
	#      水面程序共用：layer0=normal / 1=relief / 2=detail / 3=occluder ids /
	#      4=edge_distance / 5=edge_neighbor+water_depth / 6=boundary_warp，[cell-field
	#      2026-11-18] 6 → 7）；layer4/5/6 直接取自同一 bundle；
	#   ③ 单 tile 也失败：旧 RG8 粗法线兜底 —— 扩成 RGBA8（BA=128=0 坡度）2D + 7 层中性
	#      array（relief/detail=0x80、occluder=0xFF、edge 距离=1.0、次生 id=0xFFFF、
	#      warp=0x80 零偏移）：
	#      shader 走完整路径但细节/次生混合为 0，等价于原来的"仅粗法线"，
	#      绝不回退运行期高度差分。
	var tiled_ok: bool = await _bake_visual_tiles(map, world, hex_size, seed_val, visual_generation_id)
	if tiled_ok:
		# 数组路径已经带 normal/relief：非 tiled 字段必须为 null（避免白占显存，shader 也不会读）。
		world.terrain_normal_tex = null
		world.terrain_surface_tex = null
		# [C 2026-11-01] tiled 主地形水深走 visual_water_depth_tiles（RGBA8 数组）；
		# 这里保留旧的 2D R8 上传（与原逻辑一致，非 tiled 路径不再走这条）。
		world.water_depth_tex = DCAtlasEncoders.encode_r8_tex(
			world.water_depth_buffer, world.derived_size, world.water_depth_tex, _world_ext) \
			if not world.water_depth_buffer.is_empty() else null
	else:
		stage_progress.emit("encode", 0.95)
		await _yield_generation_frame()
		if _loading_frames != null and _loading_frames.canceled:
			return null
		var legacy_surface_ok: bool = await _bake_legacy_static_surface(
			map, world, hex_size, seed_val, visual_generation_id)
		if not legacy_surface_ok:
			# 兜底：旧的 RG8 粗法线包（无 BA/relief 通道）。
			var normal_data: Dictionary = await NativeLoadingTasks.compute(_world_ext,"normal",{
				"buffer":world.height_buffer,"width":world.hm_size.x,"height":world.hm_size.y,
				"coarse_radius":4,"slope_gain":8.0,"wrap_x":true,"world_size_x":world.world_bounds.size.x,
				"world_size_y":world.world_bounds.size.y,"hex_size":hex_size,
				"sample_radius_hex":TERRAIN_NORMAL_SAMPLE_RADIUS_HEX,"height_scale_hex":TERRAIN_NORMAL_HEIGHT_SCALE_HEX}, _loading_frames)
			var rg8_bytes := PackedByteArray()
			var gd_normal_tex: ImageTexture = null
			if not bool(normal_data.get("fallback",true)):
				rg8_bytes = normal_data.get("data", PackedByteArray())
			else:
				gd_normal_tex = DCAtlasEncoders.encode_terrain_normal_tex(world.height_buffer,world.hm_size,4,8.0,true,_world_ext,world.world_bounds.size,hex_size,TERRAIN_NORMAL_SAMPLE_RADIUS_HEX,TERRAIN_NORMAL_HEIGHT_SCALE_HEX)
				if gd_normal_tex != null and gd_normal_tex.get_image() != null \
						and gd_normal_tex.get_image().get_format() == Image.FORMAT_RG8:
					rg8_bytes = gd_normal_tex.get_image().get_data()
			var fallback := _upload_legacy_surface_fallback(
				rg8_bytes, world.hm_size, world.terrain_normal_tex)
			world.terrain_normal_tex = fallback.get("normal_tex", null)
			if world.terrain_normal_tex == null:
				# 无 DLL 环境（GDScript 编码器）拿不到 RG8 字节时，至少保留 2D 法线给其它层。
				world.terrain_normal_tex = gd_normal_tex
			world.terrain_surface_tex = fallback.get("surface_tex", null)
			# [C 2026-11-01] 水深兜底也升级 RGBA8：R=旧 buffer 水深、GBA=0（无软权重）→
			# compact water 的 max(二元权重, 软权重) 自动退化为旧二元行为。
			world.water_depth_tex = _upload_legacy_water_depth_fallback(world)
			print("[terrain-baked-surface] fallback water_depth=RGBA8 tex=%s derived=%s" % [
				world.water_depth_tex != null, str(world.derived_size)])
	stage_progress.emit("encode", 0.96)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null

	world.vector_atlas_tex = null
	# 方案 0：upwelling_tex 仅 F6 调试 shader 分支采样，主路径不读；这里不再无条件烘，
	# F6 切到 debug 模式时由 rebake_upwelling_tex_for_debug() lazy 建一张。
	# 保留 world.upwelling_tex 为 null：shader 在 ocean_current_debug=false 时不采样此 tex，
	# 不绑定不会渲染异常（hex_renderer 也已改为仅在 debug 开启时 set_shader_parameter）。
	world.upwelling_tex = null
	# v10.noise-pack：共享 RGBA 噪声包（首次调用时 lazy 烘焙，之后所有 world 复用同一张）
	await prepare_shared_materials_async(_loading_frames)
	if _loading_frames != null and _loading_frames.canceled:
		return null
	world.noise_tex = get_or_build_shared_noise_tex()
	# [terrain-material-tiles] Shared static material array. B 方案起固定 5 层
	# （0..3 原材质族 + 4=micro，见 _build_terrain_material_tex）。A missing import /
	# unsupported array allocation / mipmap failure is non-fatal: the renderer keeps
	# terrain_material_tex_bound=false and uses the old 2D micro path.
	var terrain_material_size := _terrain_material_size()
	if _terrain_materials_supported():
		world.terrain_material_tex = get_or_build_shared_terrain_material_tex(terrain_material_size)
	else:
		world.terrain_material_tex = null
		_shared_terrain_material_error_by_size[terrain_material_size] = "unsupported"
	world.terrain_material_tex_bound = world.terrain_material_tex != null
	if world.terrain_material_tex_bound:
		# e2e 对账用：material array 层数（B 方案期望 5；micro 源缺失时会退回 4 层）。
		print("[terrain-material-tiles] layers=%d target=%d micro_layer=%d" % [
			world.terrain_material_tex.get_layers(),
			terrain_material_size,
			TERRAIN_MATERIAL_MICRO_LAYER if world.terrain_material_tex.get_layers() >= 5 else -1])
	else:
		print("[terrain-material-tiles] disabled (%s)" %
			shared_terrain_material_error(terrain_material_size))
	stage_progress.emit("encode", 0.98)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null
	# 视野静态场（view_height / view_block）：地形一旦定型就不再变，烘一次即可。
	# 必须排在 bake_cell_luts 之前——LUT 的 A 通道要带当前迷雾值，而首解算需要
	# 这两张表。此刻 map SoA 尚未 init_soa_from_bake，VisionSolver 会自动走 AoS。
	var vision_bake: Dictionary = VisionSolver.bake_static_fields(map, world)
	if not bool(vision_bake.get("ok", false)):
		push_warning("MapBaker: vision static bake failed - %s" % String(vision_bake.get("reason", "")))
	_ensure_cell_lut_dims(map, world)
	# 此刻 DCWorldExt 必然未 bind（bind_map_data 在 bake_world 返回后才跑），就地烘
	# 只能走 GDScript。推迟到 bind 之后补烘，那时 encode_cell_luts 可用，且读到的是
	# 原生温度场 publish 之后的权威气候值。gdext 整个类都不存在时没有可等的 bind，
	# 就地烘作为无 DLL 环境的兜底。
	if ClassDB.class_exists("DCWorldExt"):
		_initial_cell_luts_deferred = true
		print("  cell LUT encode: deferred until DCWorldExt bind")
	else:
		_initial_cell_luts_deferred = false
		bake_cell_luts(map, world)
	print("  encode: %dms" % (Time.get_ticks_msec() - t))

	print("MapBaker v6: total %dms" % (Time.get_ticks_msec() - t_total))
	stage_progress.emit("done", 1.0)
	await _yield_generation_frame()
	if _loading_frames != null and _loading_frames.canceled:
		return null
	return world

## 见 map_generator.gd 的同名函数：多等的 3 帧在没有动画需求时只是把墙钟乘以 4。
## 浏览器单帧 31–34 ms，57 个调用点累计 3.5–5.3 秒纯等待。
var _loading_frames

func set_loading_frame_gate(frame_gate) -> void:
	_loading_frames = frame_gate

func _yield_generation_frame():
	if _loading_frames != null:
		return _loading_frames.next_frame()
	var tree := Engine.get_main_loop() as SceneTree
	return tree.process_frame if tree != null else null

## [terrain-web-baked-surface 2026-11-01] 组装 native `visual_tile` pass 的公共 knobs。
##
## 从 _bake_visual_tiles 里原样抽出，**行为零变化**：tiled 逐层烘焙与 legacy/Web 整图
## 单 tile 烘焙共用同一份逐 cell 输入（elevation/moisture/terrain/vegetation/cover/
## water_depth/landform/邻接/offset 映射）与同一批 bake 旋钮（残差、河流/海岸 SDF、
## 法线半径与高度夸张）。差异项由调用方 merge：
##   - tiled：`relief_supersample = layout.relief_scale`；
##   - legacy/Web 单张：`layer_id/width/height/origin_*/size_*` 覆盖成整图单 tile，
##     `relief_supersample = 1`（normal/relief 同尺寸）。
func _visual_tile_base_knobs(map: MapData, world: WorldData, hex_size: float,
		seed_val: int, visual_generation_id: int) -> Dictionary:
	return SurfaceBakerScript._visual_tile_base_knobs(self, map, world, hex_size, seed_val, visual_generation_id)
static func resolve_legacy_static_surface_size(world_bounds_size: Vector2,
		hm_size: Vector2i, cap: int) -> Vector2i:
	var limit := maxi(2, cap)
	var hm_max := maxi(maxi(hm_size.x, hm_size.y), 2)
	var longest := mini(limit, hm_max)
	if world_bounds_size.x < 0.01 or world_bounds_size.y < 0.01:
		return Vector2i(longest, longest)
	var aspect := world_bounds_size.x / world_bounds_size.y
	var w: int
	var h: int
	if aspect >= 1.0:
		w = longest
		h = int(round(float(longest) / aspect))
	else:
		h = longest
		w = int(round(float(longest) * aspect))
	# 偶数边长：至少 2，奇数减 1（不跨过封顶）。
	w = maxi(2, w - (w & 1))
	h = maxi(2, h - (h & 1))
	return Vector2i(w, h)

func _bake_visual_tiles(map: MapData, world: WorldData, hex_size: float,
		seed_val: int, generation_id: int) -> bool:
	return await SurfaceBakerScript._bake_visual_tiles(self, map, world, hex_size, seed_val, generation_id)
func _bake_legacy_static_surface(map: MapData, world: WorldData, hex_size: float,
		seed_val: int, generation_id: int) -> bool:
	return await SurfaceBakerScript._bake_legacy_static_surface(self, map, world, hex_size, seed_val, generation_id)
# [cell-field 2026-11-18] 6 → 7：新增 layer6 = boundary_warp（RG=边界扭曲场 xy 的 RG8
# 编码，BA 预留）。层序契约见 surface_baker.gd 的 SURFACE_ARRAY 注释块与
# docs/plans/terrain-cell-field-contract.md §4.2；shader 侧按 get_layers() 推
# terrain_surface_layer_count，warp 层是否可用由 terrain_warp_layer_bound 单独门控。
const SURFACE_ARRAY_LAYERS := 7
func _make_surface_edge_layers(bundle: Dictionary, size: Vector2i,
		water_data: PackedByteArray, water_expected: int) -> Array:
	return await SurfaceBakerScript._make_surface_edge_layers(self, bundle, size, water_data, water_expected)
func _make_neutral_surface_edge_image(size: Vector2i) -> Image:
	return SurfaceBakerScript._make_neutral_surface_edge_image(self, size)
func _make_neutral_surface_neighbor_image(size: Vector2i) -> Image:
	return SurfaceBakerScript._make_neutral_surface_neighbor_image(self, size)
func _make_surface_detail_layer(world: WorldData, size: Vector2i) -> Image:
	return SurfaceBakerScript._make_surface_detail_layer(self, world, size)
func _make_surface_occluder_layer(world: WorldData, size: Vector2i) -> Image:
	return SurfaceBakerScript._make_surface_occluder_layer(self, world, size)
func _make_neutral_rgba_image(size: Vector2i, value: int) -> Image:
	return SurfaceBakerScript._make_neutral_rgba_image(self, size, value)
func _create_surface_array(images: Array, expected_layers: int = 2) -> Texture2DArray:
	return SurfaceBakerScript._create_surface_array(self, images, expected_layers)
func _upload_legacy_surface_fallback(rg8_data: PackedByteArray, size: Vector2i,
		existing_normal: ImageTexture) -> Dictionary:
	return SurfaceBakerScript._upload_legacy_surface_fallback(self, rg8_data, size, existing_normal)
func _upload_legacy_water_depth_fallback(world: WorldData) -> ImageTexture:
	return SurfaceBakerScript._upload_legacy_water_depth_fallback(self, world)
func queue_canal_visual_refresh(map: MapData, world: WorldData,
		dirty_cells: PackedInt32Array) -> Dictionary:
	return SurfaceBakerScript.queue_canal_visual_refresh(self, map, world, dirty_cells)
func _drain_canal_visual_refresh(map: MapData, world: WorldData) -> void:
	await SurfaceBakerScript._drain_canal_visual_refresh(self, map, world)
func _rebake_canal_visual_layer(map: MapData, world: WorldData, layer_id: int) -> bool:
	return SurfaceBakerScript._rebake_canal_visual_layer(self, map, world, layer_id)
func _visual_tile_quality_setting() -> String:
	return SurfaceBakerScript._visual_tile_quality_setting(self)
func rebake_biome_tex_only(map: MapData, world: WorldData, hex_size: float) -> void:
	return SurfaceBakerScript.rebake_biome_tex_only(self, map, world, hex_size)
func rebake_cover_tex_only(map: MapData, world: WorldData, hex_size: float) -> void:
	return SurfaceBakerScript.rebake_cover_tex_only(self, map, world, hex_size)
func rebake_vegetation_tex_only(map: MapData, world: WorldData, hex_size: float) -> void:
	return SurfaceBakerScript.rebake_vegetation_tex_only(self, map, world, hex_size)
func _enum_atlas_cpp_pack_disabled_reason() -> String:
	return DynamicAtlasBakerScript._enum_atlas_cpp_pack_disabled_reason(self)
func _enum_atlas_cpp_pack_enabled() -> bool:
	return DynamicAtlasBakerScript._enum_atlas_cpp_pack_enabled(self)
func _ensure_world_cell_pixel_csr(map: MapData, world: WorldData) -> bool:
	return DynamicAtlasBakerScript._ensure_world_cell_pixel_csr(self, map, world)
func _try_cpp_enum_axis_patch(map: MapData, world: WorldData, axis: String, report_t0_us: int) -> bool:
	return DynamicAtlasBakerScript._try_cpp_enum_axis_patch(self, map, world, axis, report_t0_us)
func _try_cpp_enum_axes_patch(map: MapData, world: WorldData, report_t0_us: int) -> bool:
	return DynamicAtlasBakerScript._try_cpp_enum_axes_patch(self, map, world, report_t0_us)
func _indirection_skip_atlas_report() -> Dictionary:
	return DynamicAtlasBakerScript._indirection_skip_atlas_report(self)
func rebake_dynamic_cell_atlas_only(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.rebake_dynamic_cell_atlas_only(self, map, world)
func dynamic_cell_atlas_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.dynamic_cell_atlas_chunk_begin(self, map, world)
func dynamic_cell_atlas_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	return DynamicAtlasBakerScript.dynamic_cell_atlas_chunk_step(self, map, world, ctx, cells, report, start_idx, end_idx)
func dynamic_cell_atlas_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	return DynamicAtlasBakerScript.dynamic_cell_atlas_chunk_finalize(self, world, ctx, report)
func _dynamic_cell_signature(cell: HexCell, snow_override: float = -1.0) -> int:
	return DynamicAtlasBakerScript.dynamic_cell_signature(self, cell, snow_override)

func rebake_ecology_visual_atlas_only(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.rebake_ecology_visual_atlas_only(self, map, world)
func ecology_visual_atlas_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.ecology_visual_atlas_chunk_begin(self, map, world)
func ecology_visual_atlas_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	return DynamicAtlasBakerScript.ecology_visual_atlas_chunk_step(self, map, world, ctx, cells, report, start_idx, end_idx)
func ecology_visual_atlas_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	return DynamicAtlasBakerScript.ecology_visual_atlas_chunk_finalize(self, world, ctx, report)
func _ecology_visual_signature(cell: HexCell, transition_age: int, prev_vitality_byte: int,
		snow_override: float = -1.0) -> int:
	return DynamicAtlasBakerScript.ecology_visual_signature(self, cell, transition_age, prev_vitality_byte, snow_override)

static func _q01_byte(v: float) -> int:
	return DynamicAtlasBakerScript.q01_byte(v)

static func _q01_byte_ice(v: float) -> int:
	return DynamicAtlasBakerScript.q01_byte_ice(v)

func rebake_dyn_atlas_smooth(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.rebake_dyn_atlas_smooth(self, map, world)
func dyn_atlas_smooth_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.dyn_atlas_smooth_chunk_begin(self, map, world)
func dyn_atlas_smooth_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	return DynamicAtlasBakerScript.dyn_atlas_smooth_chunk_step(self, map, world, ctx, cells, report, start_idx, end_idx)
func dyn_atlas_smooth_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	return DynamicAtlasBakerScript.dyn_atlas_smooth_chunk_finalize(self, world, ctx, report)
func rebake_ice_state_atlas(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.rebake_ice_state_atlas(self, map, world)
func ice_state_atlas_chunk_begin(map: MapData, world: WorldData) -> Dictionary:
	return DynamicAtlasBakerScript.ice_state_atlas_chunk_begin(self, map, world)
func ice_state_atlas_default_cell_source(map: MapData, world: WorldData, ctx: Dictionary) -> Array:
	return DynamicAtlasBakerScript.ice_state_atlas_default_cell_source(self, map, world, ctx)
func ice_state_atlas_chunk_step(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> void:
	return DynamicAtlasBakerScript.ice_state_atlas_chunk_step(self, map, world, ctx, cells, report, start_idx, end_idx)
func ice_state_atlas_chunk_finalize(world: WorldData, ctx: Dictionary, report: Dictionary) -> void:
	return DynamicAtlasBakerScript.ice_state_atlas_chunk_finalize(self, world, ctx, report)
func get_last_enum_atlas_upload_report() -> Dictionary:
	return DynamicAtlasBakerScript.get_last_enum_atlas_upload_report(self)
func _cpp_atlas_encode_active(method_name: StringName) -> bool:
	return DynamicAtlasBakerScript._cpp_atlas_encode_active(self, method_name)
func _cpp_atlas_encode_disabled_reason(method_name: StringName) -> String:
	return DynamicAtlasBakerScript._cpp_atlas_encode_disabled_reason(self, method_name)
func _report_inc(report: Dictionary, key: String, delta: int = 1) -> void:
	return DynamicAtlasBakerScript._report_inc(self, report, key, delta)
func _cell_range(cells, start_idx: int = 0, end_idx: int = -1) -> Vector2i:
	return DynamicAtlasBakerScript._cell_range(self, cells, start_idx, end_idx)
func _pack_csr_for_cells(world: WorldData, cells, use_water_lists: bool, n_pix: int,
		start_idx: int = 0, end_idx: int = -1, map: MapData = null) -> Dictionary:
	return DynamicAtlasBakerScript._pack_csr_for_cells(self, world, cells, use_water_lists, n_pix, start_idx, end_idx, map)
func _try_cpp_dynamic_cell_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasBakerScript._try_cpp_dynamic_cell_atlas_encode(self, map, world, ctx, cells, report, start_idx, end_idx)
func _try_cpp_ecology_visual_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasBakerScript._try_cpp_ecology_visual_atlas_encode(self, map, world, ctx, cells, report, start_idx, end_idx)
func _try_cpp_dyn_smooth_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasBakerScript._try_cpp_dyn_smooth_atlas_encode(self, map, world, ctx, cells, report, start_idx, end_idx)
func _try_cpp_ice_state_atlas_encode(map: MapData, world: WorldData, ctx: Dictionary, cells,
		report: Dictionary, start_idx: int = 0, end_idx: int = -1) -> bool:
	return DynamicAtlasBakerScript._try_cpp_ice_state_atlas_encode(self, map, world, ctx, cells, report, start_idx, end_idx)
func _enum_atlas_throttle_should_flush(_axis: String, _dirty_cells: int) -> bool:
	return DynamicAtlasBakerScript._enum_atlas_throttle_should_flush(self, _axis, _dirty_cells)
func force_flush_enum_atlas_throttle(axis: String = "") -> void:
	return DynamicAtlasBakerScript.force_flush_enum_atlas_throttle(self, axis)
func _record_enum_atlas_upload_report(axis: String, path: String, elapsed_ms: float,
		dirty_cells: int, dirty_pixels: int, buffer_patch_ms: float,
		image_ms: float, upload_ms: float, cache_valid: bool) -> void:
	return DynamicAtlasBakerScript._record_enum_atlas_upload_report(self, axis, path, elapsed_ms, dirty_cells, dirty_pixels, buffer_patch_ms, image_ms, upload_ms, cache_valid)
func prewarm_dynamic_axis_caches(map: MapData, world: WorldData) -> void:
	return DynamicAtlasBakerScript.prewarm_dynamic_axis_caches(self, map, world)
func rebake_ocean_currents(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	return OceanCurrentBakerScript.rebake_ocean_currents(self, map, world, hex_size, cfg, season_phase)
func _ensure_pending_currents_size(world: WorldData) -> void:
	return OceanCurrentBakerScript._ensure_pending_currents_size(self, world)
func _ensure_pending_upwelling_size(world: WorldData) -> void:
	return OceanCurrentBakerScript._ensure_pending_upwelling_size(self, world)
func _ensure_upwelling_rows_mask(world: WorldData, y_start: int, y_end_inclusive: int) -> void:
	return OceanCurrentBakerScript._ensure_upwelling_rows_mask(self, world, y_start, y_end_inclusive)
func bake_ocean_currents_slice(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float,
		start_idx: int, end_idx: int) -> Dictionary:
	return OceanCurrentBakerScript.bake_ocean_currents_slice(self, map, world, hex_size, cfg, season_phase, start_idx, end_idx)
func bake_ocean_upwelling_slice(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float,
		start_idx: int, end_idx: int) -> Dictionary:
	return OceanCurrentBakerScript.bake_ocean_upwelling_slice(self, map, world, hex_size, cfg, season_phase, start_idx, end_idx)
func commit_ocean_buffers(world: WorldData, update_textures: bool = true) -> Dictionary:
	return OceanCurrentBakerScript.commit_ocean_buffers(self, world, update_textures)
func rebake_upwelling_tex_for_debug(world: WorldData) -> bool:
	return OceanCurrentBakerScript.rebake_upwelling_tex_for_debug(self, world)
func discard_ocean_buffers() -> void:
	return OceanCurrentBakerScript.discard_ocean_buffers(self)
func _rebake_single_axis(map: MapData, world: WorldData, hex_size: float, axis: String) -> void:
	return OceanCurrentBakerScript._rebake_single_axis(self, map, world, hex_size, axis)
func rebake_biome_axes_only(map: MapData, world: WorldData, hex_size: float) -> void:
	return OceanCurrentBakerScript.rebake_biome_axes_only(self, map, world, hex_size)
func _rewrite_axis_buffers(map: MapData, hex_size: float, world: WorldData) -> void:
	return OceanCurrentBakerScript._rewrite_axis_buffers(self, map, hex_size, world)
func _resolve_hm_size(bounds: Rect2) -> Vector2i:
	return TerrainBakerScript._resolve_hm_size(self, bounds)
func _init_noise(seed_val: int) -> void:
	return TerrainBakerScript._init_noise(self, seed_val)
func _bake_geometry_fields_native(map: MapData, hex_size: float, world: WorldData, seed_val: int) -> bool:
	return await TerrainBakerScript._bake_geometry_fields_native(self, map, hex_size, world, seed_val)
func _bake_terrain_index_native(map: MapData, hex_size: float, world: WorldData) -> bool:
	return TerrainBakerScript._bake_terrain_index_native(self, map, hex_size, world)
func _bake_terrain_index_native_legacy(map: MapData, hex_size: float, world: WorldData) -> bool:
	return TerrainBakerScript._bake_terrain_index_native_legacy(self, map, hex_size, world)
func _carve_river_into_height(world: WorldData) -> void:
	return TerrainBakerScript._carve_river_into_height(self, world)
func _landform_bytes_for_map(map: MapData) -> PackedByteArray:
	return TerrainBakerScript._landform_bytes_for_map(self, map)
func _encode_enum_atlas(biome_buf: PackedByteArray, _veg_buf: PackedByteArray,
		_cover_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null, world: WorldData = null, map: MapData = null) -> ImageTexture:
	return TerrainBakerScript._encode_enum_atlas(self, biome_buf, _veg_buf, _cover_buf, size, existing, world, map)
func _ensure_cell_lut_dims(map: MapData, world: WorldData) -> void:
	return CellLutBakerScript._ensure_cell_lut_dims(self, map, world)
const _BOUNCE_ALBEDO: Array = [
	Color(0.10, 0.16, 0.26),  # OCEAN
	Color(0.16, 0.28, 0.36),  # COAST
	Color(0.48, 0.50, 0.34),  # PLAIN
	Color(0.42, 0.52, 0.28),  # GRASSLAND
	Color(0.22, 0.34, 0.20),  # FOREST
	Color(0.45, 0.42, 0.30),  # HILL
	Color(0.46, 0.44, 0.42),  # MOUNTAIN
	Color(0.76, 0.66, 0.44),  # DESERT
	Color(0.48, 0.48, 0.44),  # TUNDRA
	Color(0.84, 0.87, 0.92),  # SNOW
	Color(0.30, 0.36, 0.26),  # SWAMP
	Color(0.18, 0.32, 0.16),  # JUNGLE
	Color(0.56, 0.52, 0.28),  # SAVANNA
	Color(0.24, 0.32, 0.24),  # TAIGA
	Color(0.52, 0.50, 0.32),  # STEPPE
	Color(0.44, 0.44, 0.30),  # SHRUBLAND
	Color(0.22, 0.34, 0.24),  # MANGROVE
	Color(0.82, 0.88, 0.94),  # GLACIER
	Color(0.14, 0.24, 0.34),  # LAKE
	Color(0.24, 0.44, 0.44),  # REEF
	Color(0.80, 0.86, 0.92),  # SEA_ICE
	Color(0.18, 0.32, 0.30),  # KELP
	Color(0.38, 0.44, 0.30),  # DELTA
	Color(0.40, 0.50, 0.30),  # OASIS
	Color(0.84, 0.82, 0.76),  # SALT_FLAT
	Color(0.60, 0.42, 0.32),  # BADLANDS
	Color(0.62, 0.60, 0.52),  # COLD_DESERT
	Color(0.46, 0.44, 0.28),  # CHAPARRAL
	Color(0.34, 0.34, 0.26),  # MOOR
	Color(0.42, 0.48, 0.30),  # FLOODPLAIN
	Color(0.58, 0.44, 0.34),  # MESA
]
const _BOUNCE_FALLBACK := Color(0.45, 0.45, 0.42)
const _BOUNCE_SNOW := Color(0.86, 0.89, 0.95)
const _BOUNCE_DRY := Color(0.58, 0.50, 0.32)
# 水面漫弹射可忽略（反照率 ~0.06 且以镜面反射为主），A=0 直接排除。海冰/冰川是陆相
# 高反照率面，保留参与——雪山邻谷的色彩溢出正是最容易看出效果的场景之一。
const _BOUNCE_WATER_TERRAINS: Array = [0, 1, 18, 19, 21]

# 弹射色从已编码的 enum/dyn 字节派生，包含 LUT 尾部填充格。C++ 执行字节循环，
# GDScript 保留参考/回退；两条路径都从上面的同一组颜色与水面定义取参数。
func _publish_bounce_lut(enum_data: PackedByteArray, dyn_data: PackedByteArray,
		world: WorldData, lw: int, lh: int,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full: bool = true) -> bool:
	return CellLutBakerScript._publish_bounce_lut(self, enum_data, dyn_data, world, lw, lh, dirty_indices, force_full)
func set_river_atlas_probe_enabled(enabled: bool, map: MapData = null) -> Dictionary:
	return CellLutBakerScript.set_river_atlas_probe_enabled(self, enabled, map)
func get_river_atlas_probe_state() -> Dictionary:
	return CellLutBakerScript.get_river_atlas_probe_state(self)
func set_river_atlas_probe_context(context: Dictionary) -> void:
	return CellLutBakerScript.set_river_atlas_probe_context(self, context)
func dump_river_atlas_probe() -> Dictionary:
	return CellLutBakerScript.dump_river_atlas_probe(self)
func _csv_escape(value: String) -> String:
	return CellLutBakerScript._csv_escape(self, value)
func _ensure_river_atlas_probe_cells(map: MapData) -> void:
	return CellLutBakerScript._ensure_river_atlas_probe_cells(self, map)
func _record_river_atlas_probe(map: MapData, out: Dictionary, dyn_data: PackedByteArray,
		eco_data: PackedByteArray) -> void:
	return CellLutBakerScript._record_river_atlas_probe(self, map, out, dyn_data, eco_data)
func _probe_float(values: PackedFloat32Array, idx: int) -> float:
	return CellLutBakerScript._probe_float(self, values, idx)
func bake_cell_luts(map: MapData, world: WorldData, cache_valid: bool = false,
		publish_weather_lut: bool = true,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true) -> Dictionary:
	return CellLutBakerScript.bake_cell_luts(self, map, world, cache_valid, publish_weather_lut, dirty_indices, force_full_encode)
func _lut_tex_from_data(data: PackedByteArray, w: int, h: int, fmt: int, existing: ImageTexture) -> ImageTexture:
	return CellLutBakerScript._lut_tex_from_data(self, data, w, h, fmt, existing)
func _publish_weather_lut_bytes(data: PackedByteArray, world: WorldData, lw: int, lh: int, force_changed: bool = false) -> Dictionary:
	return CellLutBakerScript._publish_weather_lut_bytes(self, data, world, lw, lh, force_changed)
func publish_weather_lut_bytes_from_native(data: PackedByteArray, world: WorldData, force_changed: bool = false) -> Dictionary:
	return CellLutBakerScript.publish_weather_lut_bytes_from_native(self, data, world, force_changed)
func refresh_weather_lut_from_weather(map: MapData, world: WorldData) -> Dictionary:
	return CellLutBakerScript.refresh_weather_lut_from_weather(self, map, world)
func refresh_cell_luts_daily(map: MapData, world: WorldData,
		dirty_indices: PackedInt32Array = PackedInt32Array(),
		force_full_encode: bool = true,
		publish_weather_lut: bool = false) -> Dictionary:
	return CellLutBakerScript.refresh_cell_luts_daily(self, map, world, dirty_indices, force_full_encode, publish_weather_lut)
func cell_lut_active_transition_pending() -> bool:
	return CellLutBakerScript.cell_lut_active_transition_pending(self)
func bake_sea_ice_fraction_only(map: MapData, world: WorldData) -> void:
	return DCClimateBaker.bake_sea_ice_fraction_only(self, map, world)

func prepare_sea_ice_fraction_atlas(map: MapData, world: WorldData) -> Dictionary:
	return DCClimateBaker.prepare_sea_ice_fraction_atlas(self, map, world)

func upload_prepared_sea_ice_fraction_atlas(world: WorldData) -> Dictionary:
	return DCClimateBaker.upload_prepared_sea_ice_fraction_atlas(self, world)

func _ensure_sea_ice_pixel_to_cell_index(map: MapData, world: WorldData) -> void:
	return DCClimateBaker.ensure_sea_ice_pixel_to_cell_index(self, map, world)

func _prepare_sea_ice_fraction_atlas_gd(map: MapData, world: WorldData, W: int, H: int, n: int) -> Dictionary:
	return DCClimateBaker.prepare_sea_ice_fraction_atlas_gd(self, map, world, W, H, n)

func bake_weather_field_only(map: MapData, world: WorldData) -> void:
	return DCWeatherBaker.bake_weather_field_only(self, map, world)

func _bake_wind_field(bounds: Rect2, size: Vector2i, season_phase: float) -> PackedByteArray:
	return DCWeatherBaker.bake_wind_field(self, bounds, size, season_phase)

func _bake_ocean_currents(map: MapData, hex_size: float, world: WorldData, cfg: MapConfig = null, season_phase: float = 2.0) -> PackedByteArray:
	return OceanCurrentBakerScript.bake_ocean_currents(self, map, hex_size, world, cfg, season_phase)

func _bake_ocean_upwelling(map: MapData, hex_size: float, world: WorldData, cfg: MapConfig = null, season_phase: float = 2.0) -> PackedByteArray:
	return OceanCurrentBakerScript.bake_ocean_upwelling(self, map, hex_size, world, cfg, season_phase)

static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP

# ═══════════════════════════════════════════════════════════════════════════
# Physical Wind & Ocean Circulation：hex 求解 + 像素光栅化辅助
# ═══════════════════════════════════════════════════════════════════════════
#
# 本块不引入新调度——只是封装"hex 求解器结果如何写进既有 4 个 buffer
# (wind_field / ocean_current / ocean_upwelling / per-cell)"的统一入口。
# 切片化路径与一次性路径都复用同一组 helper，避免双份维护。

# 是否启用物理化路径的开关读取。失败时（cfg 不存在 / 字段缺失）默认关闭，
# 走旧 ny-only 路径，最大化向后兼容。
func _use_physical_circulation(cfg: MapConfig) -> bool:
	return PhysicalCirculationBakerScript.use_physical_circulation(self, cfg)

func _calendar_days_per_year(profile = null) -> int:
	return PhysicalCirculationBakerScript.calendar_days_per_year(self, profile)

func _season_phase_to_day_of_year(season_phase: float, days_per_year: int = 0) -> int:
	return PhysicalCirculationBakerScript.season_phase_to_day_of_year(self, season_phase, days_per_year)

func _phys_resolve_abs_sim_day(season_phase: float, days_per_year: int,
		override_day: int = -1) -> int:
	return PhysicalCirculationBakerScript.resolve_abs_sim_day(self, season_phase, days_per_year, override_day)

func _phys_take_wind_elapsed_days(sim_day: int) -> float:
	return PhysicalCirculationBakerScript.take_wind_elapsed_days(self, sim_day)

func set_world_ext(ext) -> void:
	return PhysicalCirculationBakerScript.set_world_ext(self, ext)
func set_climate_profile(cp) -> void:
	_climate_profile = cp

func set_world_clock_ref(world_clock_node) -> void:
	_world_clock_ref = world_clock_node

## 只固定已提交的视觉输入，不计算物理、不重建或释放 GPU 资源。
func begin_runtime_physics_visual(map: MapData, world: WorldData, view: Dictionary, phase: float) -> bool:
	return PhysicalCirculationBakerScript.begin_runtime_physics_visual(self, map, world, view, phase)
func reset_physical_solve_state() -> void:
	return PhysicalCirculationBakerScript.reset_physical_solve_state(self)
func get_slp_path_str() -> String:
	return PhysicalCirculationBakerScript.get_slp_path_str(self)
func get_slp_native_ms() -> float:
	return PhysicalCirculationBakerScript.get_slp_native_ms(self)
func get_psi_path_str() -> String:
	return PhysicalCirculationBakerScript.get_psi_path_str(self)
func get_psi_native_ms() -> float:
	return PhysicalCirculationBakerScript.get_psi_native_ms(self)
func get_psi_iters_run() -> int:
	return PhysicalCirculationBakerScript.get_psi_iters_run(self)
func get_psi_residual_final() -> float:
	return PhysicalCirculationBakerScript.get_psi_residual_final(self)
func get_psi_early_exit() -> bool:
	return PhysicalCirculationBakerScript.get_psi_early_exit(self)
func get_psi_mode() -> String:
	return PhysicalCirculationBakerScript.get_psi_mode(self)
func get_slp_thermal_p95() -> float:
	return PhysicalCirculationBakerScript.get_slp_thermal_p95(self)
func get_slp_delta_p95() -> float:
	return PhysicalCirculationBakerScript.get_slp_delta_p95(self)
func get_wind_delta_p95() -> float:
	return PhysicalCirculationBakerScript.get_wind_delta_p95(self)
func get_wind_dir_delta_p95() -> float:
	return PhysicalCirculationBakerScript.get_wind_dir_delta_p95(self)
func get_wind_dir_flip_count() -> int:
	return PhysicalCirculationBakerScript.get_wind_dir_flip_count(self)
func get_ocean_delta_p95() -> float:
	return PhysicalCirculationBakerScript.get_ocean_delta_p95(self)
func get_thermal_current_p95() -> float:
	return PhysicalCirculationBakerScript.get_thermal_current_p95(self)
func get_ocean_current_preclamp_p95() -> float:
	return PhysicalCirculationBakerScript.get_ocean_current_preclamp_p95(self)
func get_ocean_current_preclamp_max() -> float:
	return PhysicalCirculationBakerScript.get_ocean_current_preclamp_max(self)
func get_ocean_current_clamp_count() -> int:
	return PhysicalCirculationBakerScript.get_ocean_current_clamp_count(self)
func get_ocean_current_clamp_ratio() -> float:
	return PhysicalCirculationBakerScript.get_ocean_current_clamp_ratio(self)
func get_ocean_current_max_magnitude() -> float:
	return PhysicalCirculationBakerScript.get_ocean_current_max_magnitude(self)
func _physical_stage_name(stage: int) -> String:
	return PhysicalCirculationBakerScript.physical_stage_name(self, stage)

func get_physical_circulation_diag() -> Dictionary:
	return PhysicalCirculationBakerScript.get_physical_circulation_diag(self)
func run_daily_wind_field_update(map: MapData, world: WorldData, cfg: MapConfig,
		hex_size: float, season_phase: float, sim_day_override: int = -1,
		stage: String = "both") -> Dictionary:
	return PhysicalCirculationBakerScript.run_daily_wind_field_update(self, map, world, cfg, hex_size, season_phase, sim_day_override, stage)
func prime_physical_solve_from_current_wind(map: MapData, season_phase: float) -> bool:
	return PhysicalCirculationBakerScript.prime_physical_solve_from_current_wind(self, map, season_phase)
const _PHYS_LANE_KNOB_KEYS: Array[StringName] = [
	&"neighbor_indices", &"water_terrain_ids", &"cell_pos", &"cell_q_arr",
	&"cell_r_arr", &"prev_slp_arr", &"slp_arr", &"wind_x_arr", &"wind_y_arr",
	&"wind_speed_arr", &"n_cells",
]

## B8 P2：四个物理 stage base dict 的标量投影（worker 侧 prepass 用）。
## 返回 {"slp": {...}, "wind": {...}, "psi": {...}, "upwelling": {...}}；
## 未构建过 base（bake 还没跑）时返回空 dict，调用方按"未就绪"处理。
func runtime_physics_knobs() -> Dictionary:
	return PhysicalCirculationBakerScript.runtime_physics_knobs(self)
func _phys_scalar_knob_projection(src: Dictionary) -> Dictionary:
	return PhysicalCirculationBakerScript._phys_scalar_knob_projection(self, src)
func _phys_ensure_knob_cache(map: MapData, hex_size: float, bounds: Rect2,
		profile: ClimateProfile, cfg: MapConfig) -> void:
	return PhysicalCirculationBakerScript._phys_ensure_knob_cache(self, map, hex_size, bounds, profile, cfg)
func _physical_solve_step_one(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float, solve_ocean: bool = true) -> bool:
	return PhysicalSolveBakerScript._physical_solve_step_one(self, map, world, hex_size, cfg, season_phase, solve_ocean)
func _physical_solve_for_phase(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> void:
	return PhysicalSolveBakerScript._physical_solve_for_phase(self, map, world, hex_size, cfg, season_phase)
func _physical_solve_native_oneshot(map: MapData, world: WorldData, hex_size: float,
		cfg: MapConfig, season_phase: float) -> bool:
	return PhysicalSolveBakerScript._physical_solve_native_oneshot(self, map, world, hex_size, cfg, season_phase)
func _ensure_pending_wind_size(world: WorldData) -> void:
	return PhysicalSolveBakerScript._ensure_pending_wind_size(self, world)
func _rasterize_wind_slice_from_hex(world: WorldData, buf: PackedByteArray,
		s: int, e: int) -> void:
	return PhysicalSolveBakerScript._rasterize_wind_slice_from_hex(self, world, buf, s, e)
func _rasterize_ocean_current_slice_from_hex(world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	return PhysicalSolveBakerScript._rasterize_ocean_current_slice_from_hex(self, world, dst, s, e)
func _rasterize_upwelling_slice_from_hex(world: WorldData, dst: PackedByteArray,
		s: int, e: int) -> void:
	return PhysicalSolveBakerScript._rasterize_upwelling_slice_from_hex(self, world, dst, s, e)
func _ensure_ocean_pixel_to_cell_index(map: MapData, world: WorldData) -> void:
	return PhysicalSolveBakerScript._ensure_ocean_pixel_to_cell_index(self, map, world)
func run_ocean_field_rasterize_full(map: MapData, world: WorldData, _cfg: MapConfig,
		p_start_idx: int = -1, p_end_idx: int = -1) -> Dictionary:
	return PhysicalSolveBakerScript.run_ocean_field_rasterize_full(self, map, world, _cfg, p_start_idx, p_end_idx)
func run_wind_field_rasterize_full(map: MapData, world: WorldData, _cfg: MapConfig) -> Dictionary:
	return PhysicalSolveBakerScript.run_wind_field_rasterize_full(self, map, world, _cfg)
func cancel_loading_work() -> void:
	_visual_tile_generation_id += 1
	if _world_ext != null:
		_world_ext.cancel_all_loading_tasks()
