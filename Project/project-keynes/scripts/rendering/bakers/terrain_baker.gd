extends RefCounted
class_name DCTerrainBaker

const TerrainIndexBakerScript = preload("res://scripts/rendering/bakers/terrain_index_baker.gd")
const TerrainGeometryScript = preload("res://scripts/rendering/bakers/terrain_geometry_utils.gd")
const DCAtlasEncoders = preload("res://scripts/rendering/bakers/atlas_encoders.gd")
const AtlasEncodersScript = preload("res://scripts/rendering/bakers/atlas_encoders.gd")





## Terrain/landform/vegetation baking boundary.
##
## Native river SDF and hydraulic erosion requests plus result validation live here.
## C++ owns river topology/geometry and droplet erosion computation.
## Terrain detail R8 generation and encoding also live here; MapBaker owns only
## WorldData assignment and bake ordering. The legacy pixel fallback uses the
## shared stateless geometry utility.
##
## Remaining extraction targets intentionally stay in MapBaker until migrated:
## terrain atlas orchestration only.
##


func _init(_ctx: DCBakerContext) -> void:
	# Native terrain requests are exposed as static APIs; no per-instance state is needed.
	pass



static func bake_river_sdf(map: MapData, hex_size: float, bounds: Rect2, res: Vector2i,
		world_ext: Object, seed_value: int, base_radius_px: float,
		sdf_max_dist_px: float, cr_step: int, wrap_period_x: float) -> PackedFloat32Array:
	var W: int = res.x
	var H: int = res.y
	var empty := PackedFloat32Array()
	empty.resize(maxi(W * H, 0))
	if W <= 0 or H <= 0:
		return empty
	if world_ext == null:
		push_error("[bake_river_sdf] native river SDF pass unavailable")
		return empty
	var size: Vector2 = bounds.size
	var inv_world := Vector2(float(W) / size.x, float(H) / size.y)
	var rep: Dictionary = world_ext.run_bake_river_sdf_pass({
		"width": W,
		"height": H,
		"origin_x": bounds.position.x,
		"origin_y": bounds.position.y,
		"inv_world_x": inv_world.x,
		"inv_world_y": inv_world.y,
		"hex_size": hex_size,
		"seed": seed_value,
		"base_radius_px": base_radius_px,
		"sdf_max_dist_px": sdf_max_dist_px,
		"cr_step": cr_step,
		"wrap_period_x": wrap_period_x,
	})
	var ok: bool = rep != null and typeof(rep) == TYPE_DICTIONARY and not bool(rep.get("fallback", true))
	var out: PackedFloat32Array = rep.get("out_buf", PackedFloat32Array()) if ok else PackedFloat32Array()
	if not ok or out.size() != W * H:
		push_error("[bake_river_sdf] native result invalid (reason=%s)" % (
			String(rep.get("reason", "unknown")) if rep != null and typeof(rep) == TYPE_DICTIONARY else "null"))
		return empty
	return out


static func bake_hydraulic_erosion(height: PackedFloat32Array, size: Vector2i,
		world_ext: Object, seed_value: int, erosion_knobs: Dictionary) -> PackedFloat32Array:
	var width: int = size.x
	var height_px: int = size.y
	if width <= 0 or height_px <= 0:
		return height
	if height.size() != width * height_px:
		push_error("[hydraulic_erosion] input height size invalid")
		return height
	if world_ext == null:
		push_error("[hydraulic_erosion] native erosion pass unavailable")
		return height
	var knobs := erosion_knobs.duplicate(false)
	knobs["width"] = width
	knobs["height"] = height_px
	knobs["height_buffer"] = height
	knobs["seed"] = seed_value
	var rep: Dictionary = world_ext.run_bake_erosion_pass(knobs)
	var ok: bool = rep != null and typeof(rep) == TYPE_DICTIONARY and not bool(rep.get("fallback", true))
	var out: PackedFloat32Array = rep.get("height_out", PackedFloat32Array()) if ok else PackedFloat32Array()
	if not ok or out.size() != width * height_px:
		push_error("[hydraulic_erosion] native result invalid (reason=%s)" % (
			String(rep.get("reason", "unknown")) if rep != null and typeof(rep) == TYPE_DICTIONARY else "null"))
		return height
	return out


static func rebake_terrain_detail_texture(world: WorldData, hex_size: float,
		detail_noise: FastNoiseLite, ridge_noise: FastNoiseLite, world_ext: Object,
		min_detail: float = 0.70, max_detail: float = 1.30) -> ImageTexture:
	if world == null or world.biome_buffer.is_empty() \
			or world.derived_size.x <= 0 or world.derived_size.y <= 0:
		return world.terrain_detail_tex if world != null else null
	if detail_noise == null or ridge_noise == null:
		push_error("[terrain_detail] missing detail noise")
		return world.terrain_detail_tex
	var W: int = world.derived_size.x
	var H: int = world.derived_size.y
	var n: int = W * H
	if world.biome_buffer.size() < n:
		return world.terrain_detail_tex
	var origin: Vector2 = world.world_bounds.position
	var size: Vector2 = world.world_bounds.size
	var step_x: float = size.x / float(W)
	var step_y: float = size.y / float(H)
	var wrap_period_x: float = world.wrap_period_x
	var data := PackedByteArray()
	data.resize(n)
	for y in range(H):
		var wy: float = origin.y + (float(y) + 0.5) * step_y
		var row: int = y * W
		for x in range(W):
			var idx: int = row + x
			var wx: float = origin.x + (float(x) + 0.5) * step_x
			var detail := terrain_detail_bake_scalar(detail_noise, ridge_noise, wx, wy,
					wrap_period_x, hex_size, min_detail, max_detail)
			data[idx] = terrain_detail_to_byte(detail, min_detail, max_detail)
	return AtlasEncodersScript.encode_r8_tex(data, world.derived_size,
			world.terrain_detail_tex, world_ext)


static func terrain_detail_noise01(noise: FastNoiseLite, wx: float, wy: float,
		wrap_period_x: float, hex_size: float, freq: float,
		off_x: float = 0.0, off_y: float = 0.0) -> float:
	var n: float = TerrainGeometryScript.cyl_noise(noise, wx * freq + off_x,
			wy * freq + off_y, wrap_period_x, hex_size, freq, off_x)
	return clampf(n * 0.5 + 0.5, 0.0, 1.0)


static func terrain_detail_bake_scalar(detail_noise: FastNoiseLite,
		ridge_noise: FastNoiseLite, wx: float, wy: float, wrap_period_x: float,
		hex_size: float, min_detail: float, max_detail: float) -> float:
	var n: float = terrain_detail_noise01(detail_noise, wx, wy, wrap_period_x, hex_size, 0.18)
	var micro: float = terrain_detail_noise01(detail_noise, wx, wy, wrap_period_x, hex_size, 0.45, 13.0, -7.0)
	var ridge: float = terrain_detail_noise01(ridge_noise, wx, wy, wrap_period_x, hex_size, 0.22, -19.0, 31.0)
	var detail_signal: float = (n - 0.5) * 0.54 + (ridge - 0.5) * 0.31 + (micro - 0.5) * 0.15
	return clampf(1.0 + detail_signal * 0.34, min_detail, max_detail)


static func terrain_detail_to_byte(detail: float, min_detail: float, max_detail: float) -> int:
	var t: float = inverse_lerp(min_detail, max_detail, clampf(detail, min_detail, max_detail))
	return clampi(int(round(t * 255.0)), 0, 255)


static func bake_height_biome_moisture(
	map: MapData,
	hex_size: float,
	world: WorldData,
	height_buf: PackedFloat32Array,
	biome_buf: PackedByteArray,
	moist_buf: PackedFloat32Array,
	veg_buf: PackedByteArray,
	cover_buf: PackedByteArray,
	warp_noise_lo: FastNoiseLite,
	warp_noise_hi: FastNoiseLite,
	ridge_noise: FastNoiseLite,
	detail_noise: FastNoiseLite,
	bake_knobs: Dictionary
) -> void:
	if map == null or world == null:
		push_error("[terrain_bake] missing map or world")
		return
	var warp_amp: float = float(bake_knobs.get("warp_amp", 0.4))
	var warp_high_amp_ratio: float = float(bake_knobs.get("warp_high_amp_ratio", 0.55))
	var relief_amp: float = float(bake_knobs.get("relief_amp", 0.26))
	var relief_lo: float = float(bake_knobs.get("relief_lo", 0.020))
	var relief_hi: float = float(bake_knobs.get("relief_hi", 0.150))
	var ridge_smear_hex: float = float(bake_knobs.get("ridge_smear_hex", 0.65))
	var k_crest: float = float(bake_knobs.get("k_crest", 1.7))
	var valley_bias: float = float(bake_knobs.get("valley_bias", 0.35))
	var crag_amp: float = float(bake_knobs.get("crag_amp", 0.05))
	var crag_freq_mul: float = float(bake_knobs.get("crag_freq_mul", 1.05))
	var hypsometric_mix: float = float(bake_knobs.get("hypsometric_mix", 0.0))
	var coast_beach: float = float(bake_knobs.get("coast_beach", 0.05))
	var W := world.hm_size.x
	var H := world.hm_size.y
	var origin := world.world_bounds.position
	var size := world.world_bounds.size
	var step_x := size.x / float(W)
	var step_y := size.y / float(H)
	var warp_scale := hex_size * warp_amp
	var wrap_period_x := HexUtils.wrap_period_x(map.width, hex_size)

	# v9.perf：建立 pixel→HexCell lookup，让后续 rebake_*_only / rebake_biome_axes_only
	# 不再需要重跑 noise + cube_round。这里只是 W*H 次引用赋值，开销 ~0
	var pix_count := W * H
	var lookup: Array = []
	lookup.resize(pix_count)
	world.pixel_to_cell_lookup = lookup

	# 阶段 P：桶式收集每个 cell 覆盖的像素 index，循环结束后批量打包成 PackedInt32Array。
	# 与 lookup 同源，零额外的 cube_round / noise 计算开销。
	# 用 Array 收集再 append_array 一次性 memcpy（比逐个 push_back 快一个数量级）。
	var cell_pixel_buckets: Dictionary = {}  # HexCell → Array[int]

	# ── [P0] per-cell 高程梯度 + 局地起伏预计算（六邻居有限差分；与 C++ run_bake_terrain_index_pass 对齐）──
	#    grad 方向供各向异性脊线（沿等高线方向拉长山脊），relief（邻格最大高差）供连续振幅门控。
	var n_cells_g := map.cell_count()
	var cgx := PackedFloat32Array(); cgx.resize(n_cells_g)
	var cgy := PackedFloat32Array(); cgy.resize(n_cells_g)
	var crel := PackedFloat32Array(); crel.resize(n_cells_g)
	# 邻居方向顺序与 C++ NDQ/NDR 一致：E, SE, SW, W, NW, NE（梯度为求和，顺序无关）
	var _grad_dirs: Array = [
		Vector3i(1, 0, -1), Vector3i(0, 1, -1), Vector3i(-1, 1, 0),
		Vector3i(-1, 0, 1), Vector3i(0, -1, 1), Vector3i(1, -1, 0)]
	for gcell in map.all_cells():
		if gcell == null:
			continue
		var gci: int = int(gcell.index)
		if gci < 0 or gci >= n_cells_g:
			continue
		var g_e0: float = gcell.elevation
		var g_s0: Vector2 = HexUtils.cube_to_world(gcell.q, gcell.r, hex_size)
		var g_sxx := 0.0; var g_sxy := 0.0; var g_syy := 0.0; var g_sxz := 0.0; var g_syz := 0.0
		var g_relief := 0.0
		for gi in range(6):
			var gdir: Vector3i = _grad_dirs[gi]
			var g_nqx: int = gcell.q + gdir.x
			var g_nqy: int = gcell.r + gdir.y
			var g_ncube := Vector3i(g_nqx, g_nqy, -g_nqx - g_nqy)
			var gnb: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, g_ncube)
			if gnb == null:
				continue
			var g_dz: float = gnb.elevation - g_e0
			# 用 unwrapped cube 世界坐标算局部偏移（接缝处仍连续，梯度方向正确）
			var g_nw: Vector2 = HexUtils.cube_to_world(g_nqx, g_nqy, hex_size)
			var g_dx := g_nw.x - g_s0.x
			var g_dy := g_nw.y - g_s0.y
			g_sxx += g_dx * g_dx; g_sxy += g_dx * g_dy; g_syy += g_dy * g_dy
			g_sxz += g_dx * g_dz; g_syz += g_dy * g_dz
			var g_adz := absf(g_dz)
			if g_adz > g_relief:
				g_relief = g_adz
		var g_det := g_sxx * g_syy - g_sxy * g_sxy   # 2×2 最小二乘解世界空间梯度
		if g_det > 1e-12 or g_det < -1e-12:
			var g_inv := 1.0 / g_det
			cgx[gci] = float((g_syy * g_sxz - g_sxy * g_syz) * g_inv)
			cgy[gci] = float((g_sxx * g_syz - g_sxy * g_sxz) * g_inv)
		crel[gci] = float(g_relief)

	# [P1 hypsometric Layer A] 构造曲线切线 + 锚定量，循环前一次（与 world_ext.cpp 同源）。
	var hypso_m := TerrainGeometryScript.hypso_make_tangents()
	var hy_sea: float = world.sea_level
	var hy_above: float = 1.0 - hy_sea
	var hy_inv_above: float = (1.0 / hy_above) if hy_above > 1e-6 else 0.0

	for y in range(H):
		var wy_base := origin.y + (float(y) + 0.5) * step_y
		var row := y * W
		for x in range(W):
			var wx_base := origin.x + (float(x) + 0.5) * step_x

			# 1. Warp（双频，让 hex 边界变弯曲 + 犬牙交错）
			var warp_x := TerrainGeometryScript.cyl_noise(warp_noise_lo, wx_base, wy_base, wrap_period_x, hex_size)
			var warp_y := TerrainGeometryScript.cyl_noise(warp_noise_lo, wx_base + 31.7, wy_base - 17.3, wrap_period_x, hex_size, 1.0, 31.7)
			var hi_x := TerrainGeometryScript.cyl_noise(warp_noise_hi, wx_base + 91.1, wy_base + 53.7, wrap_period_x, hex_size, 1.0, 91.1) * warp_high_amp_ratio
			var hi_y := TerrainGeometryScript.cyl_noise(warp_noise_hi, wx_base - 41.5, wy_base + 23.9, wrap_period_x, hex_size, 1.0, -41.5) * warp_high_amp_ratio
			var wx := wx_base + (warp_x + hi_x) * warp_scale
			var wy := wy_base + (warp_y + hi_y) * warp_scale

			# 2. Cube 归属
			var cube_f := TerrainGeometryScript.world_to_cube_f(Vector2(wx, wy), hex_size)
			var rounded := TerrainGeometryScript.cube_round(cube_f)
			var self_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, rounded)

			# 3. 找最近的 sextant 邻居（barycentric 用）
			var self_center := HexUtils.cube_to_world(rounded.x, rounded.y, hex_size)
			var local := Vector2(wx - self_center.x, wy - self_center.y) / hex_size
			var angle := atan2(local.y, local.x)
			var sextant: int = int(floor(fposmod((angle + PI / 6.0) / (PI / 3.0), 6.0)))
			var nb1_dir := TerrainGeometryScript.neighbor_dir(sextant)
			var nb2_dir := TerrainGeometryScript.neighbor_dir((sextant + 1) % 6)
			var nb1_cube := Vector3i(rounded.x + nb1_dir.x, rounded.y + nb1_dir.y, rounded.z + nb1_dir.z)
			var nb2_cube := Vector3i(rounded.x + nb2_dir.x, rounded.y + nb2_dir.y, rounded.z + nb2_dir.z)
			var nb1_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, nb1_cube)
			var nb2_cell: HexCell = TerrainGeometryScript.get_wrapped_cell_by_cube(map, nb2_cube)

			# 4. Barycentric 权重（self + 2 邻居）
			var nb1_center: Vector2 = HexUtils.cube_to_world(nb1_cube.x, nb1_cube.y, hex_size)
			var nb2_center: Vector2 = HexUtils.cube_to_world(nb2_cube.x, nb2_cube.y, hex_size)
			var w_self: float
			var w_nb1: float
			var w_nb2: float
			var bary := TerrainGeometryScript.barycentric(Vector2(wx, wy), self_center, nb1_center, nb2_center)
			w_self = bary.x
			w_nb1 = bary.y
			w_nb2 = bary.z

			# 5. 取 elevation / moisture / terrain
			var elev_self: float = self_cell.elevation if self_cell != null else 0.0
			var elev_nb1: float = nb1_cell.elevation if nb1_cell != null else elev_self
			var elev_nb2: float = nb2_cell.elevation if nb2_cell != null else elev_self
			var moist_self: float = self_cell.moisture if self_cell != null else 0.5
			var moist_nb1: float = nb1_cell.moisture if nb1_cell != null else moist_self
			var moist_nb2: float = nb2_cell.moisture if nb2_cell != null else moist_self
			var terrain_self: int = int(self_cell.terrain) if self_cell != null else int(TerrainType.TERRAIN.OCEAN)
			# Milestone 2：同 cube_round → 同源拿 vegetation / cover 三轴。
			# self_cell.vegetation / cover 在 MapGenerator._sync_axes_for_map 中已经派生齐全。
			var veg_self: int = int(self_cell.vegetation) if self_cell != null else int(VegetationType.VEG.NONE)
			var cover_self: int = int(self_cell.cover) if self_cell != null else int(CoverType.CV.NONE)

			# 6. Barycentric 插值 → 平滑 elevation/moisture
			var elev_blend := elev_self * w_self + elev_nb1 * w_nb1 + elev_nb2 * w_nb2
			var moist_blend := moist_self * w_self + moist_nb1 * w_nb1 + moist_nb2 * w_nb2

			# 6.5 [P1 hypsometric Layer A] 锚定 sea_level 小 mix 残差重映射（重锐化台地边缘，
			#     不重复整条 Layer B 曲线）；relief 随后叠在重塑基底上。
			if hy_inv_above > 0.0 and elev_blend > hy_sea:
				elev_blend = TerrainGeometryScript.hypso_remap_elev(elev_blend, hy_sea, hy_inv_above, hy_above, hypsometric_mix, hypso_m)

			# 6.6 [coast-beach 2026-06-25] 近岸海滩坡：barycentric 水邻居权重作亚格距水近度，对近岸陆地
			#     下压成海滩坡（写进 height → terrain_normal_tex 拿到 crisp 海岸法线）。与 world_ext.cpp 同公式。
			#     water = {OCEAN0,COAST1,LAKE18,REEF19,SEA_ICE20,KELP21}（对齐 pk_is_water_terrain）。
			if terrain_self != int(TerrainType.TERRAIN.OCEAN) and terrain_self != int(TerrainType.TERRAIN.COAST) and elev_blend > hy_sea:
				var water_w := 0.0
				if nb1_cell != null:
					var t1 := int(nb1_cell.terrain)
					if t1 == 0 or t1 == 1 or t1 == 18 or t1 == 19 or t1 == 20 or t1 == 21:
						water_w += w_nb1
				if nb2_cell != null:
					var t2 := int(nb2_cell.terrain)
					if t2 == 0 or t2 == 1 or t2 == 18 or t2 == 19 or t2 == 20 or t2 == 21:
						water_w += w_nb2
				if water_w > 0.0:
					var beach := water_w * water_w * (3.0 - 2.0 * water_w)
					elev_blend = maxf(elev_blend - coast_beach * beach, hy_sea)

			# 7. [P0] per-pixel relief：各向异性脊线（沿等高线拉长）+ 连续振幅(relief 门控)
			#    + 山脊/谷不对称（尖脊缓谷）+ 气候耦合（干→岩屑、湿→圆滑）；不绑 terrain 类别。
			var elev_final := elev_blend
			if terrain_self != int(TerrainType.TERRAIN.OCEAN) and terrain_self != int(TerrainType.TERRAIN.COAST):
				# 插值 per-cell 梯度方向 + 局地起伏（复用 self/nb1/nb2 barycentric 权重）
				var gx := 0.0
				var gy := 0.0
				var relief_p := 0.0
				if self_cell != null:
					gx += cgx[self_cell.index] * w_self
					gy += cgy[self_cell.index] * w_self
					relief_p += crel[self_cell.index] * w_self
				if nb1_cell != null:
					gx += cgx[nb1_cell.index] * w_nb1
					gy += cgy[nb1_cell.index] * w_nb1
					relief_p += crel[nb1_cell.index] * w_nb1
				if nb2_cell != null:
					gx += cgx[nb2_cell.index] * w_nb2
					gy += cgy[nb2_cell.index] * w_nb2
					relief_p += crel[nb2_cell.index] * w_nb2
				# 连续振幅门控：relief 低→趋平（真平原），高→满振幅（无 terrain 硬分档）
				var gate := smoothstep(relief_lo, relief_hi, relief_p)
				# 脊线方向 = 梯度的垂直方向（沿等高线）
				var glen := sqrt(gx * gx + gy * gy)
				var tx := 1.0
				var ty := 0.0
				if glen > 1e-9:
					tx = -gy / glen
					ty = gx / glen
				# 沿脊线 3-tap smear（每 tap 经 _cyl_noise，圆柱接缝安全）→ 沿等高线方向拉长山脊
				var smear_l := hex_size * ridge_smear_hex
				var r0 := TerrainGeometryScript.cyl_noise(ridge_noise, wx_base, wy_base, wrap_period_x, hex_size)
				var rA := TerrainGeometryScript.cyl_noise(ridge_noise, wx_base + tx * smear_l, wy_base + ty * smear_l, wrap_period_x, hex_size, 1.0, tx * smear_l)
				var rB := TerrainGeometryScript.cyl_noise(ridge_noise, wx_base - tx * smear_l, wy_base - ty * smear_l, wrap_period_x, hex_size, 1.0, -tx * smear_l)
				var smeared := (r0 * 2.0 + rA + rB) * 0.25
				var rr := r0 + (smeared - r0) * gate  # 低起伏→各向同性，高起伏→沿脊
				var ridge01 := clampf((rr + 1.0) * 0.5, 0.0, 1.0)
				var shaped := pow(ridge01, k_crest)   # 尖脊 + 缓谷
				var amp := relief_amp * gate
				# 气候耦合：干燥→更多高频岩屑、湿润→圆滑；仅在有起伏处出现（× gate）
				var dryness := 1.0 - moist_blend
				var crag := TerrainGeometryScript.cyl_noise(detail_noise, wx_base * crag_freq_mul + 17.9, wy_base * crag_freq_mul - 11.3,
						wrap_period_x, hex_size, crag_freq_mul, 17.9) * 0.5
				elev_final = elev_blend + (shaped - valley_bias) * amp + crag * crag_amp * (0.4 + 0.6 * dryness) * gate

			var idx := row + x
			height_buf[idx] = clampf(elev_final, 0.0, 1.0)
			biome_buf[idx] = terrain_self & 0xFF
			moist_buf[idx] = clampf(moist_blend, 0.0, 1.0)
			veg_buf[idx] = veg_self & 0xFF
			cover_buf[idx] = cover_self & 0xFF
			# v9.perf：缓存 cell 引用，rebake 时直接 lookup[idx].cover/vegetation
			lookup[idx] = self_cell
			# 阶段 P：同步把该像素 index 收进 cell 桶（仅非空 cell，map 外 None 跳过）
			if self_cell != null:
				if not cell_pixel_buckets.has(self_cell):
					cell_pixel_buckets[self_cell] = []
				(cell_pixel_buckets[self_cell] as Array).push_back(idx)

	# 阶段 P：把桶批量打包成 PackedInt32Array（一次 memcpy，避开 push_back 的反复扩容）。
	# 这就是 rebake_cover_tex_only / rebake_vegetation_tex_only 增量路径的核心反向索引。
	var cell_pixel_lists: Dictionary = {}
	for cell_key in cell_pixel_buckets.keys():
		var packed := PackedInt32Array()
		packed.append_array(cell_pixel_buckets[cell_key] as Array)
		cell_pixel_lists[cell_key] = packed
	world.cell_pixel_lists = cell_pixel_lists

	# P1：同源构建 SoA 镜像（CSR 布局），给 dynamic_visual_atlas 的
	# `_pack_csr_for_cells` fast path 用。Dict 路径保留（finalize/rebake 仍按
	# cell_key 查），SoA 路径只追加，不替换。
	# 长度 N = map 总 cell 数；cell.index 作为 idx 直接 O(1) 查 first_px / px_count。
	var n_cells_csr: int = map.cell_count()
	var first_px_arr: PackedInt32Array = PackedInt32Array(); first_px_arr.resize(n_cells_csr)
	var px_count_arr: PackedInt32Array = PackedInt32Array(); px_count_arr.resize(n_cells_csr)
	# 默认 -1 = 该 idx 无像素（map 外的 hex 占位 / 空 cell）。
	for _ic in range(n_cells_csr):
		first_px_arr[_ic] = -1
		px_count_arr[_ic] = 0
	# 先估算 flat 总长（O(N) 遍历桶）—— 一次性 resize，避免增量扩容的 CoW 拷贝。
	var total_px: int = 0
	for cell_key in cell_pixel_buckets.keys():
		total_px += (cell_pixel_buckets[cell_key] as Array).size()
	var flat_arr: PackedInt32Array = PackedInt32Array(); flat_arr.resize(total_px)
	# 第二次遍历：按 cell.index 升序（map.all_cells() 即按 idx 顺序）填 flat。
	# 这样 cells_subset 是 cells 序列对应 cell.index 的连续段时（很少），SoA 仍可
	# 按 idx 切片读出（4 phase 不要求顺序连续）。
	var flat_w_csr: int = 0
	for _cell_iter in map.all_cells():
		if _cell_iter == null:
			continue
		var _ci_idx: int = int(_cell_iter.index)
		if _ci_idx < 0 or _ci_idx >= n_cells_csr:
			continue
		if not cell_pixel_buckets.has(_cell_iter):
			# 该 cell 无任何像素（map 外或纯逻辑 hex）—— first_px = -1，count = 0
			continue
		var _bucket: Array = cell_pixel_buckets[_cell_iter] as Array
		var _bn: int = _bucket.size()
		first_px_arr[_ci_idx] = flat_w_csr
		px_count_arr[_ci_idx] = _bn
		for _bi in range(_bn):
			flat_arr[flat_w_csr + _bi] = int(_bucket[_bi])
		flat_w_csr += _bn
	# 严格相等的一致性检查：flat_w_csr 必须 == total_px。否则 cell_iter 漏了某个
	# 在桶里的 cell（说明 map.all_cells() 与 cell_pixel_buckets 的 keys 不同源），
	# 此时 SoA 不安全直接使用。这里只校验，不抛错；上层走 Dict fallback 即可。
	# 如果不等，把 flat_arr resize 到实际写入长度，避免末尾留 0。
	if flat_w_csr != total_px:
		flat_arr.resize(flat_w_csr)
	world.cell_first_px_arr = first_px_arr
	world.cell_px_count_arr = px_count_arr
	world.flat_px_indices_arr = flat_arr

static func _resolve_hm_size(baker: MapBaker, bounds: Rect2) -> Vector2i:
	# 按平台和 Web 画质选择静态场精度，详见 _hm_max_dim()。
	var dim_max: int = baker._hm_max_dim()
	if bounds.size.x < 0.01 or bounds.size.y < 0.01:
		return Vector2i(dim_max, dim_max)
	var aspect := bounds.size.x / bounds.size.y
	var w: int
	var h: int
	if aspect >= 1.0:
		w = dim_max
		h = int(round(float(dim_max) / aspect))
	else:
		h = dim_max
		w = int(round(float(dim_max) * aspect))
	w = (w / 2) * 2
	h = (h / 2) * 2
	return Vector2i(maxi(w, 256), maxi(h, 256))


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

	print("    [fused] terrain=%.1fms valley=%.1fms erosion=%.1fms(ok=%s) river=%.1fms(ok=%s) latitude=%.1fms coast_sdf=%.1fms(ok=%s)" % [
		float(rep.get("terrain_ms", -1.0)), float(rep.get("valley_ms", -1.0)),
		float(rep.get("erosion_ms", -1.0)), str(bool(rep.get("erosion_ok", false))),
		float(rep.get("river_ms", -1.0)), str(bool(rep.get("river_ok", false))),
		float(rep.get("latitude_ms", -1.0)),
		float(rep.get("coast_ms", -1.0)), str(bool(rep.get("coast_ok", false)))])
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
	var lookup: Array = []; lookup.resize(pix_count)
	if p2c.size() == pix_count:
		for i in range(pix_count):
			var ci2: int = p2c[i]
			lookup[i] = cells_by_index[ci2] if ci2 >= 0 and ci2 < n_cells else null
	world.pixel_to_cell_lookup = lookup
	var lists: Dictionary = {}
	if first_px.size() >= n_cells and pcount.size() >= n_cells:
		var flat_n: int = flat.size()
		for ci3 in range(n_cells):
			var cnt: int = pcount[ci3]
			if cnt <= 0:
				continue
			var st: int = first_px[ci3]
			if st < 0 or st + cnt > flat_n:
				continue
			var cell2: HexCell = cells_by_index[ci3]
			if cell2 == null:
				continue
			lists[cell2] = flat.slice(st, st + cnt)
	world.cell_pixel_lists = lists
	return true


# ─── 轻度侵蚀（仅做边界自然平滑） ────────────────────────────────────────


# ─── 河流：native SDF 结果的 legacy height carve ─────────────────────────

# [river-carve-bake 2026-06-25] #2a GDScript 镜像：按 flow SDF 逐像素刻 V 形河谷（crisp 河岸法线）。
#   与 world_ext.cpp run_bake_geometry_fields_pass 内 carve 同公式；仅 legacy(fused 失败)路径调用
#   （fused 成功时 C++ 已 carve 并跳过本路径）。height_buffer=hm_size、flow_buffer=derived_size，
#   分辨率不同则按归一化坐标最近邻取 flow。

static func _carve_river_into_height(baker: MapBaker, world: WorldData) -> void:
	var hb := world.height_buffer
	var fb := world.flow_buffer
	var hw: int = world.hm_size.x
	var hh: int = world.hm_size.y
	var fw: int = world.derived_size.x
	var fh: int = world.derived_size.y
	if hb.size() != hw * hh or fb.size() != fw * fh or hw <= 0 or hh <= 0 or fw <= 0 or fh <= 0:
		return
	var sea: float = world.sea_level
	var same_res: bool = (hw == fw and hh == fh)
	for y in range(hh):
		var row := y * hw
		var fy: int = clampi(int(float(y) / float(hh) * float(fh)), 0, fh - 1)
		var frow := fy * fw
		for x in range(hw):
			var hi := row + x
			var f: float
			if same_res:
				f = fb[hi]
			else:
				var fx: int = clampi(int(float(x) / float(hw) * float(fw)), 0, fw - 1)
				f = fb[frow + fx]
			if f <= 0.02:
				continue
			var e: float = hb[hi]
			if e <= sea:
				continue
			var notch := f * f * (3.0 - 2.0 * f)
			e -= baker.BAKE_RIVER_INCISE * notch
			if e < 0.0:
				e = 0.0
			hb[hi] = e
	world.height_buffer = hb


# ─── 纹理编码 ────────────────────────────────────────────────────────────


static func _encode_height_tex(baker: MapBaker, buf: PackedFloat32Array, size: Vector2i) -> ImageTexture:
	return DCAtlasEncoders.encode_height_tex(buf, size, baker._world_ext)



static func _is_water_biome_id(baker: MapBaker, biome: int) -> bool:
	return biome == int(TerrainType.TERRAIN.OCEAN) \
		or biome == int(TerrainType.TERRAIN.COAST) \
		or biome == int(TerrainType.TERRAIN.LAKE) \
		or biome == int(TerrainType.TERRAIN.REEF) \
		or biome == int(TerrainType.TERRAIN.SEA_ICE) \
		or biome == int(TerrainType.TERRAIN.KELP)



static func _terrain_detail_is_forest_like(baker: MapBaker, biome: int) -> bool:
	return biome == int(TerrainType.TERRAIN.FOREST) \
		or biome == int(TerrainType.TERRAIN.JUNGLE) \
		or biome == int(TerrainType.TERRAIN.TAIGA) \
		or biome == int(TerrainType.TERRAIN.SAVANNA) \
		or biome == int(TerrainType.TERRAIN.SHRUBLAND) \
		or biome == int(TerrainType.TERRAIN.MANGROVE) \
		or biome == int(TerrainType.TERRAIN.CHAPARRAL)



static func _terrain_detail_is_rock_like(baker: MapBaker, biome: int) -> bool:
	return biome == int(TerrainType.TERRAIN.HILL) \
		or biome == int(TerrainType.TERRAIN.MOUNTAIN) \
		or biome == int(TerrainType.TERRAIN.BADLANDS) \
		or biome == int(TerrainType.TERRAIN.MESA) \
		or biome == int(TerrainType.TERRAIN.GLACIER)



static func _terrain_detail_is_desert_like(baker: MapBaker, biome: int) -> bool:
	return biome == int(TerrainType.TERRAIN.DESERT) \
		or biome == int(TerrainType.TERRAIN.COLD_DESERT) \
		or biome == int(TerrainType.TERRAIN.SALT_FLAT)



static func _terrain_detail_is_wetland_like(baker: MapBaker, biome: int) -> bool:
	return biome == int(TerrainType.TERRAIN.SWAMP) \
		or biome == int(TerrainType.TERRAIN.DELTA) \
		or biome == int(TerrainType.TERRAIN.OASIS) \
		or biome == int(TerrainType.TERRAIN.MOOR) \
		or biome == int(TerrainType.TERRAIN.FLOODPLAIN)


# ─── v9.atlas：合并通道编码 ─────────────────────────────────────────────
# 把原先多张 derived 贴图（biome/veg/cover/moist/flow/lat/ocean/wind）
# 按"采样模式 + 数据语义"分到 3 张 atlas，shader 端只需 3 次 texture() 即可
# 拿到所有 derived 数据。height_tex 因分辨率/精度独立保留。


static func _landform_bytes_for_map(baker: MapBaker, map: MapData) -> PackedByteArray:
	if map == null:
		return PackedByteArray()
	var n: int = map.cell_count()
	if map.landform_arr.size() >= n:
		return map.landform_arr
	var out: PackedByteArray = PackedByteArray()
	out.resize(n)
	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		var ci: int = int(cell.index)
		if ci >= 0 and ci < n:
			out[ci] = int(cell.landform) & 0xFF
	return out


# map_index_atlas: RGBA8 NEAREST (R=biome, G=cell index low, B=cell index high, A=landform)
# v9.perf：existing 非 null 时走 ImageTexture.update() 复用 GPU RID，
# 避免每天 rebake 时反复 alloc/free GPU buffer + 重新绑定 shader uniform

static func _encode_enum_atlas(baker: MapBaker, biome_buf: PackedByteArray, _veg_buf: PackedByteArray,
		_cover_buf: PackedByteArray, size: Vector2i,
		existing: ImageTexture = null, world: WorldData = null, map: MapData = null) -> ImageTexture:
	var payload: Dictionary = DCAtlasEncoders.encode_enum_atlas_payload(
		biome_buf, _veg_buf, _cover_buf, size, existing, world, baker._world_ext,
		baker._landform_bytes_for_map(map)
	)
	# 阶段 P2：缓存 RGBA8 data。后续 biome 变化只局部写 R 通道；G/B cell index 不变。
	baker._enum_atlas_data = payload.get("data", PackedByteArray())
	baker._enum_atlas_data_size = payload.get("size", Vector2i.ZERO)
	return payload.get("texture", existing)



# ═══════════════════════════════════════════════════════════════════════
# Cell-index 间接寻址（province-ID indirection）烘焙
# plan: cell-index atlas indirection。bake_world 一次性烘出静态索引图 + per-cell LUT。
#   - cell index 已合入 map_index_atlas.g/b；
#   - LUT 由 daily 路径增量刷新（refresh_cell_luts_daily）。
# 全程 feature-flag（DCFeatureFlags.cell_indirection_active）：flag 关时本组函数
# 不被 bake_world 调用，旧 per-pixel atlas 路径逐字节不变。
# ═══════════════════════════════════════════════════════════════════════
