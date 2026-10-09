extends RefCounted
class_name DCTerrainBaker

const TerrainGeometryScript = preload("res://scripts/rendering/bakers/terrain_geometry_utils.gd")
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
	if world_ext == null or not world_ext.has_method("run_bake_river_sdf_pass"):
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
	if world_ext == null or not world_ext.has_method("run_bake_erosion_pass"):
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
