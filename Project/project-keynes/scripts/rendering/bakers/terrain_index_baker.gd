extends RefCounted
class_name DCTerrainIndexBaker

const AtlasEncodersScript = preload("res://scripts/rendering/bakers/atlas_encoders.gd")

## Native terrain-index bridge.
##
## This module owns only request packing and result unpacking for the native
## terrain-index pass. C++ remains the computation authority; MapBaker keeps
## lifecycle ordering and all non-terrain texture/object ownership.


static func native_active(world_ext: Object) -> bool:
	return world_ext != null


static func build_cell_inputs(map: MapData) -> Dictionary:
	var n_cells: int = map.cell_count() if map != null else 0
	var elev_arr := PackedFloat32Array()
	elev_arr.resize(maxi(n_cells, 0))
	var moist_arr := PackedFloat32Array()
	moist_arr.resize(maxi(n_cells, 0))
	var terr_arr := PackedByteArray()
	terr_arr.resize(maxi(n_cells, 0))
	var landform_arr := PackedByteArray()
	landform_arr.resize(maxi(n_cells, 0))
	var veg_arr := PackedByteArray()
	veg_arr.resize(maxi(n_cells, 0))
	var cov_arr := PackedByteArray()
	cov_arr.resize(maxi(n_cells, 0))
	var water_depth_arr := PackedFloat32Array()
	water_depth_arr.resize(maxi(n_cells, 0))
	var o2i := PackedInt32Array()
	if map != null:
		o2i.resize(maxi(map.width * map.height, 0))
		o2i.fill(-1)
	var cells_by_index: Array = []
	cells_by_index.resize(maxi(n_cells, 0))
	if map != null:
		for cell in map.all_cells():
			if cell == null:
				continue
			var ci: int = int(cell.index)
			if ci < 0 or ci >= n_cells:
				continue
			elev_arr[ci] = cell.elevation
			moist_arr[ci] = cell.moisture
			terr_arr[ci] = int(cell.terrain) & 0xFF
			landform_arr[ci] = int(cell.landform) & 0xFF
			veg_arr[ci] = int(cell.vegetation) & 0xFF
			cov_arr[ci] = int(cell.cover) & 0xFF
			water_depth_arr[ci] = float(cell.water_depth)
			cells_by_index[ci] = cell
			var off: Vector2i = HexUtils.cube_to_offset(cell.q, cell.r)
			if off.y >= 0 and off.y < map.height and not o2i.is_empty():
				o2i[off.y * map.width + posmod(off.x, map.width)] = ci
	return {
		"n_cells": n_cells,
		"cell_elevation": elev_arr,
		"cell_moisture": moist_arr,
		"cell_terrain": terr_arr,
		"cell_landform": landform_arr,
		"cell_vegetation": veg_arr,
		"cell_cover": cov_arr,
		"cell_water_depth": water_depth_arr,
		"offset_to_index": o2i,
		"cells_by_index": cells_by_index,
	}


# [DEM 地貌 2026-10-09] P0 起伏：山脊网络 + 顺坡沟谷（gdext bake_dem_landform.h）。
# 山地起伏取近邻、区域高差与地貌下限；平原低于 relief_lo 不加，高原内部减弱。
# 最粗一层间距 *_wavelength_hex，逐层减半，最细层由栅格分辨率截断。
const DEM_DEFAULTS := {
	"dem_relief_lo": 0.006,
	"dem_relief_hi": 0.120,
	"dem_relief_cap": 0.25,
	"dem_ridge_amp_per_relief": 0.55,
	"dem_ridge_wavelength_hex": 2.4,
	"dem_ridge_crest_exp": 2.2,
	"dem_mountain_relief_floor": 0.055,
	"dem_peak_relief_floor": 0.080,
	"dem_amp_per_relief": 0.1,
	"dem_base_wavelength_hex": 1.0,
	"dem_octaves": 4,
	"dem_gain_wet": 0.48,
	"dem_gain_dry": 0.62,
	"dem_ridge_gain": 0.40,
	# 汇流刻谷：谷深 = 起伏 × depth_per_relief × smooth(log 汇水面积)，谷壁坡度 = 起伏 × wall_per_relief / 格。
	"dem_valley_depth_per_relief": 1.4,
	"dem_valley_wall_per_relief": 5.0,
	"dem_valley_area_lo": 8.0,
	"dem_valley_area_hi": 4000.0,
	"dem_valley_depth_exp": 0.8,
	"dem_valley_mfd_exponent": 6.0,
	# 河心 flow 不低于它的像素也是汇流出口（>= 1 关闭）。
	"dem_valley_river_outlet_flow": 0.6,
	# ── 侵蚀（契约 §4.1 / 计划 §4.10）：本表是**唯一**的默认值来源，经 dem_landform_knobs()
	# 并入融合 pass knobs，可用 project_keynes/rendering/dem/<去 dem_ 前缀> 逐项覆盖。
	# 三条硬约束，动这些值之前先读：
	#   ① 长度/面积类参数一律以 **hex** 为单位（不是像素、不是归一化高度）：像素量由 C++ 乘
	#      hex_px 换算，分辨率/平台（desktop 1024、Web 512–2048）变化时不改 knob。
	#   ② 迭代次数（dem_spl_iters）只按分辨率分档，**禁止**按耗时自适应或提前退出：同一 seed
	#      必须逐位复现，机器负载只能改变耗时，不能改变地形结果。
	#   ③ C++ 缺省**永远**是 "carve"（逐位回退基线，见 checklist §A1）；"spl" 只能由本表显式
	#      开启，不改 C++。旧 dem_valley_* 在所有模式下语义不变。
	# [P2.7 2026-11-18] 已切换默认模式 carve → spl（计划 §6 P2 验收全部通过后执行）。
	#   要回到改动前的逐位基线：把这里改回 "carve" 即可（无需重编 DLL，C++ 缺省就是 carve）；
	#   也可临时用 ProjectSettings 覆盖 project_keynes/rendering/dem/erosion_mode = "carve"。
	"dem_erosion_mode": "spl",
	"dem_erosion_max_dim": 1024,
	# 隐式 SPL 下切：dem_spl_k = 总侵蚀时间（hex 单位），dem_spl_m = 面积指数（地貌学 0.4–0.6）；
	# 汇水面积低于 dem_spl_min_area_hex 不下切。iters 只切分强度，不改变宏观总量。
	# [P2 标定 2026-11-18] dem_spl_k = 0.50，两条依据（均在真实地图 60×40 / 1024×606 上实测）：
	#   ① 计划 §6 P2 验收带 spl_p99_drop ∈ [0.01, 0.08]：k=0.60 → 0.0843（**出界**，故下调），
	#      k=0.50 → 0.0719（带内，余量 10%）。
	#   ② 计划 §12 Q1「锐度对齐现状」：合成真实起伏图上实测「相对 procedural 高度的总削蚀均值」
	#      carve=0.01382、spl(k=0.50)≈0.0116 → 约 84% 的 carve 强度，观感偏柔和但同量级。
	#   标定扫描（合成图、k → p99_drop）：0.03→0.0070、0.30→0.0419、0.50→0.0586、0.60→0.0694、
	#   0.90→0.0906、1.20→0.1080。p99 对 k 近似线性，改 k 后请按同一验收带复核。
	"dem_spl_iters": 6,
	"dem_spl_k": 0.50,
	"dem_spl_m": 0.45,
	"dem_spl_min_area_hex": 0.03,
	# 限坡：坡度上限 = per_relief × max(relief, relief_floor) / hex；单像素最大削减 = cap × relief。
	# 默认 5.0 与 carve 的 dem_valley_wall_per_relief 相同，锐度对齐现状。
	"dem_slope_limit_per_relief": 5.0,
	"dem_slope_limit_relief_floor": 0.04,
	"dem_slope_limit_cap_per_relief": 1.4,
	# 凸脊磨圆强度（0 = 关闭）：只取负值的 Laplacian，磨圆凸脊、不动谷底。
	"dem_crest_round": 0.0,
	# P3 输运受限沉积（默认关，A/B 后再定）：超搬运能力处按 dem_dep_rate 逐像素填回。
	"dem_dep_enabled": false,
	"dem_dep_kc": 0.02,
	"dem_dep_rate": 0.5,
	"dem_dep_min_area_hex": 0.5,
	# P3b 谷底展宽（默认关）：半宽 = dem_floor_width_hex × A_hex^0.5，dem_floor_slope 为谷底横坡。
	"dem_floor_widen": false,
	"dem_floor_width_hex": 0.04,
	"dem_floor_slope": 0.002,
	"dem_floor_min_area_hex": 2.0,
	# 仅 "spl+carve" 诊断模式：叠加的浅刻谷按此比例缩放谷深。
	"dem_spl_carve_scale": 0.40,
	# 诊断/测试专用：让合并 pipeline 用 count_pits 算 pits_out（缺省关，不改变地形）。
	"dem_erosion_pit_audit": false,
}
const DEM_SETTING_PREFIX := "project_keynes/rendering/dem/"


static func dem_landform_knobs() -> Dictionary:
	var out := {}
	for key in DEM_DEFAULTS:
		out[key] = ProjectSettings.get_setting(
				DEM_SETTING_PREFIX + String(key).trim_prefix("dem_"), DEM_DEFAULTS[key])
	return out


static func build_knobs(map: MapData, world: WorldData, hex_size: float,
		seed_value: int = -1) -> Dictionary:
	var inputs := build_cell_inputs(map)
	var seed := world.bake_seed if seed_value < 0 else seed_value
	var knobs := {
		"width": world.hm_size.x,
		"height": world.hm_size.y,
		"map_width": map.width,
		"map_height": map.height,
		"n_cells": inputs["n_cells"],
		"origin_x": world.world_bounds.position.x,
		"origin_y": world.world_bounds.position.y,
		"size_x": world.world_bounds.size.x,
		"size_y": world.world_bounds.size.y,
		"hex_size": hex_size,
		"wrap_period_x": HexUtils.wrap_period_x(map.width, hex_size),
		"seed": seed,
		"sea_level": world.sea_level,
		"cell_elevation": inputs["cell_elevation"],
		"cell_moisture": inputs["cell_moisture"],
		"cell_terrain": inputs["cell_terrain"],
		"cell_landform": inputs["cell_landform"],
		"cell_vegetation": inputs["cell_vegetation"],
		"cell_cover": inputs["cell_cover"],
		"cell_water_depth": inputs["cell_water_depth"],
		"offset_to_index": inputs["offset_to_index"],
	}
	knobs.merge(dem_landform_knobs())
	return {"knobs": knobs, "inputs": inputs}


static func bake(map: MapData, world: WorldData, hex_size: float,
		world_ext: Object) -> bool:
	if map == null or world == null or not native_active(world_ext):
		return false
	var prepared := build_knobs(map, world, hex_size)
	var rep: Dictionary = world_ext.run_bake_terrain_index_pass(prepared.knobs)
	return apply_result(map, world, world_ext, rep, prepared.inputs)


static func apply_result(map: MapData, world: WorldData, world_ext: Object,
		report: Dictionary, inputs: Dictionary) -> bool:
	if map == null or world == null or report == null \
			or bool(report.get("fallback", true)):
		return false
	var pix_count: int = world.hm_size.x * world.hm_size.y
	if pix_count <= 0:
		return false
	var hbuf: PackedFloat32Array = report.get("height_buffer", PackedFloat32Array())
	var bbuf: PackedByteArray = report.get("biome_buffer", PackedByteArray())
	var mbuf: PackedFloat32Array = report.get("moisture_buffer", PackedFloat32Array())
	var vbuf: PackedByteArray = report.get("vegetation_buffer", PackedByteArray())
	var cbuf: PackedByteArray = report.get("cover_buffer", PackedByteArray())
	if hbuf.size() != pix_count or bbuf.size() != pix_count \
			or mbuf.size() != pix_count or vbuf.size() != pix_count \
			or cbuf.size() != pix_count:
		return false
	world.height_buffer = hbuf
	world.biome_buffer = bbuf
	world.moisture_buffer = mbuf
	world.vegetation_buffer = vbuf
	world.cover_buffer = cbuf
	_upload_edge_textures(world, world_ext, report, pix_count)
	_stash_boundary_warp(world, report, pix_count)
	_apply_csr(world, map, report, inputs)
	return true


static func _upload_edge_textures(world: WorldData, world_ext: Object,
		report: Dictionary, pix_count: int) -> void:
	var secondary: PackedByteArray = report.get(
		"edge_secondary_index_buffer", PackedByteArray())
	var distance: PackedByteArray = report.get(
		"edge_distance_buffer", PackedByteArray())
	if secondary.size() != pix_count * 2 or distance.size() != pix_count:
		world.terrain_edge_neighbor_tex = null
		world.terrain_edge_distance_tex = null
		push_warning("[terrain_edge] native boundary buffers missing/invalid; using hard cell edges.")
		return
	world.terrain_edge_neighbor_tex = AtlasEncodersScript.encode_rg8_tex(
		secondary, world.derived_size, world.terrain_edge_neighbor_tex)
	world.terrain_edge_distance_tex = AtlasEncodersScript.encode_r8_tex(
		distance, world.derived_size, world.terrain_edge_distance_tex, world_ext)


## [cell-field 2026-11-18] 边界扭曲场（方案 §3.5 / 契约 §2）：C++ 顺手输出的 RG8 暂存。
##
## terrain-index pass 的第 1 步本来就在逐像素算双频扭曲（`NW_LO` + `NW_HI * 0.55`），
## C++ 把它按 `v = clamp((warp_x + hi_x) / range, -1, 1)`、`byte = round((v * 0.5 + 0.5) * 255)`
## 编码成 W*H*2 的 RG8 一起返回（R=x、G=y）。这里只做**尺寸校验 + 暂存**，不解码、不上传：
##   - 非 tiled：surface_baker 把它塞进 `terrain_surface_tex` 的 layer6（RGBA8 的 RG 通道）；
##   - tiled：visual tile bundle 自带逐 tile 的 `boundary_warp`（同一个 buffer 直搬），不走这里。
## shader 解码要的两个常量——`range`（本函数记录）与 `map_baker.WARP_AMP`——由渲染器在绑定时
## 从 WorldData 读出来推 `terrain_warp_range` / `terrain_warp_amp`，**不在 shader 里硬编码**。
## 旧 DLL / 融合 pass 未转发（无这三个键）⇒ 保持空/默认值，shader 的 `terrain_warp_layer_bound`
## 为 false，格界退化成直边六边形（仍与 CPU cube_round 逐点一致），不崩、不报错。
static func _stash_boundary_warp(world: WorldData, report: Dictionary, pix_count: int) -> void:
	# world_data.gd 的三个字段由数据侧 agent 提供（本文件不拥有 world_data.gd）。字段缺失时
	# 只警告一次并跳过暂存：写入不存在的属性会在 debug 构建里报 "Invalid set index"。
	if not ("boundary_warp_buf" in world and "boundary_warp_range" in world
			and "boundary_warp_clamped" in world):
		push_warning("[cell-field] WorldData.boundary_warp_{buf,range,clamped} missing; "
			+ "warp field dropped (terrain_surface_tex.layer6 falls back to neutral)")
		return
	var expected: int = pix_count * 2
	var buf: PackedByteArray = report.get("boundary_warp_buffer", PackedByteArray())
	if buf.size() != expected:
		world.boundary_warp_buf = PackedByteArray()
		world.boundary_warp_range = 1.6
		world.boundary_warp_clamped = 0
		push_warning("[cell-field] boundary_warp_buffer size %d != %d (W*H*2); warp field disabled"
			% [buf.size(), expected])
		return
	var clamped: int = int(report.get("boundary_warp_clamped", 0))
	world.boundary_warp_buf = buf
	world.boundary_warp_range = float(report.get("boundary_warp_range", 1.6))
	world.boundary_warp_clamped = clamped
	# 契约：被 clamp 的通道数必须恒为 0（|warp| ≤ 1、hi × 0.55 ⇒ 理论上界 1.55 < 1.6）。
	# 非 0 说明 C++ 的编码分母与真实扭曲上界不一致 ⇒ 值被截断，格界形状会与 CPU 高程 /
	# 海滩坡烘焙错位。正常情况下不打日志（每次生成都会跑，不刷屏）。
	if clamped > 0:
		print(("[cell-field] boundary warp clamped %d channel(s) (expected 0): "
			+ "encoding range %.3f is too small; hex edges will drift from CPU bake")
			% [clamped, world.boundary_warp_range])


static func _apply_csr(world: WorldData, map: MapData, report: Dictionary,
		inputs: Dictionary) -> void:
	var first_px: PackedInt32Array = report.get("cell_first_px", PackedInt32Array())
	var pcount: PackedInt32Array = report.get("cell_px_count", PackedInt32Array())
	var flat: PackedInt32Array = report.get("flat_px_indices", PackedInt32Array())
	world.cell_first_px_arr = first_px
	world.cell_px_count_arr = pcount
	world.flat_px_indices_arr = flat
	var pix_count: int = world.hm_size.x * world.hm_size.y
	var n_cells: int = int(inputs.get("n_cells", map.cell_count()))
	var cells_by_index: Array = inputs.get("cells_by_index", [])
	var p2c: PackedInt32Array = report.get("pixel_to_cell_index", PackedInt32Array())
	world.publish_pixel_lookup_indices(p2c, cells_by_index, pix_count, n_cells)
