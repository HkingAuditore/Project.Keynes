# map_generator.gd v7.1
#
# 改进重点（相比 v6）：
#   1) 大陆形状：保留 v6 的 N 个 continent_centers 距离场骨架（保证"海中 N 个大陆"结构），
#      但在距离场和噪声上都叠加域扭曲，让轮廓不再是圆形/椭圆 blob。
#   2) 河流：弃贪心下坡链，改成 Flow Accumulation（汇流累积）。
#      每个 land cell 找下坡邻居 → 按海拔从高到低逐 cell 累积流量 →
#      流量 >= 高分位的 cell 标 has_river。出来的是真实树状河网 + 支流汇入。
#      配合 _smooth_pit_depressions 平滑 1-cell 局部洼地，避免大量 dead-end。
#   3) 气候：温度用 cos bell 曲线、湿度叠加沿岸补偿（沿海更湿，内陆更干）
#   4) 地形阈值微调，让山地/丘陵分布更鲜明但不过度
#
# 流程：generate → _generate_cells（per-cell 玩法层数据） → MapBaker.bake_world（高分辨率视觉烘焙）

class_name MapGenerator

# ─── 河流参数 ────────────────────────────────────────────────────────────
# 流量分位阈值：超过 land cell 总流量这个 percentile 的格子标 has_river。
# 0.85 = top 15% → 主干 + 大量支流细流
const RIVER_FLOW_PERCENTILE := 0.85

# 沿岸湿度补偿
const COASTAL_MOISTURE_BOOST := 0.20

# 边缘衰减（让地图边界倾向于海洋）
# v7.2：START 从 0.55 拉到 0.40，让海洋深入腹地 → 消除"矩形大陆"感
const EDGE_FALLOFF_START := 0.40
const EDGE_FALLOFF_END := 0.95
const EDGE_FALLOFF_DEPTH := 0.55

# 大陆距离场参数（v7.1 重新引入：让"海中 N 个大陆"结构清晰）
# 域扭曲振幅（在归一化坐标 [0,1] 空间里，把"距离 continent_center 的距离值"扰动 ±这个值）
# v7.5：现在扰动的是距离值本身（不是坐标位置），所以 deep-ocean 的远点不会被拉进 continent。
#       0.06 = 大陆边界轻度波浪；0.12 = 大陆边界明显犬牙；0.20+ = 极不规则但可能产生离岸碎岛。
const CONTINENT_WARP_AMP := 0.10

# 距离场和噪声的混合比例（之和应 ≤ 1，剩余给中频细节）
const DIST_FIELD_WEIGHT := 0.55
const NOISE_WEIGHT := 0.45

# v7.2：山脉脊线 ridge 强度（在距离场之上叠 ridged noise → 大陆出现山脉走向）
# 0 = 不加 ridge，0.20 = 适中山脉密度，0.35 = 多山世界
const RIDGE_BOOST_AMP := 0.2

# ─── 噪声实例 ────────────────────────────────────────────────────────────
var _height_noise:    FastNoiseLite     # 大陆主形态（多频 fbm）
var _height_warp:     FastNoiseLite     # 域扭曲（让大陆形状非圆形）
var _detail_noise:    FastNoiseLite     # 中频细节
var _moisture_noise:  FastNoiseLite     # 湿度
var _continent_centers: Array            # 大陆中心（normalized [0,1]）
var _rng:             RandomNumberGenerator

# ─── 公开接口 ────────────────────────────────────────────────────────────

func generate(cfg: MapConfig, hex_size: float) -> Dictionary:
	cfg.validate()

	var effective_seed: int = cfg.seed if cfg.seed != 0 else randi()
	_rng = RandomNumberGenerator.new()
	_rng.seed = effective_seed
	_init_noise(effective_seed)

	var t_total := Time.get_ticks_msec()
	var map := _generate_cells(cfg)
	print("MapGenerator v7: per-cell %dms (%d cells)" % [Time.get_ticks_msec() - t_total, map.cell_count()])

	var t_bake := Time.get_ticks_msec()
	var baker := MapBaker.new()
	var world := baker.bake_world(map, cfg, hex_size, effective_seed)
	print("MapGenerator v7: bake %dms" % (Time.get_ticks_msec() - t_bake))

	return {"map": map, "world_data": world}

# ─── 内部：per-cell 生成主流程 ───────────────────────────────────────────

func _generate_cells(cfg: MapConfig) -> MapData:
	var map := MapData.new(cfg.width, cfg.height)

	# 0. 大陆中心点（提供"N 个大陆"宏结构骨架）
	_continent_centers = _make_continent_centers(cfg)

	# 1. 海拔（距离场 + 域扭曲多频 fbm + 边缘衰减）
	for row in range(cfg.height):
		for col in range(cfg.width):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			var nx: float = float(col) / float(cfg.width  - 1)
			var ny: float = float(row) / float(cfg.height - 1)
			cell.elevation = _compute_elevation(nx, ny, cfg)
			map.set_cell(cell)
	_normalize_elevation(map)

	# 1.5. 平滑 1-cell 局部洼地（让河流能 downhill 通到海，不被噪声困住）
	_smooth_pit_depressions(map, cfg)

	# 1.6. 山脉脊线：在已确定的陆地上叠 ridge 噪声，只往上抬不改海陆边界
	_apply_mountain_ridges(map, cfg)

	# 2. 初始湿度（噪声基线）
	for cell: HexCell in map.all_cells():
		var nx2: float = float(_cube_to_col(cell, cfg)) / float(cfg.width  - 1)
		var ny2: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		cell.moisture = _compute_moisture_base(nx2, ny2)

	# 3. 初步定地形（用基础湿度）
	for cell: HexCell in map.all_cells():
		var ny3: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		var temp := _compute_temperature(ny3, cell.elevation)
		var terrain := _decide_terrain(cell.elevation, temp, cell.moisture, cfg)
		cell.apply_terrain(terrain)

	# 4. 沿岸湿度补偿（沿海陆地更湿，内陆相对偏干）
	_apply_coastal_moisture_boost(map)

	# 5. 重新决策非山地非冻原的低地，让"沿海森林/草原 vs 内陆沙漠/平原"分布合理
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		# 山地 / 雪 / 冻原 不被湿度二次改写（它们由海拔/温度主导）
		if cell.terrain == TerrainType.TERRAIN.MOUNTAIN \
				or cell.terrain == TerrainType.TERRAIN.SNOW \
				or cell.terrain == TerrainType.TERRAIN.TUNDRA:
			continue
		var ny5: float = float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)
		var temp2 := _compute_temperature(ny5, cell.elevation)
		var new_terrain := _decide_terrain(cell.elevation, temp2, cell.moisture, cfg)
		cell.apply_terrain(new_terrain)

	# 6. 河流：Flow Accumulation 算法
	_generate_rivers_flow_accumulation(map, cfg)

	return map

# ─── 噪声初始化 ──────────────────────────────────────────────────────────

func _init_noise(seed_val: int) -> void:
	# 主噪声：octaves 4（v7 是 6 → 太碎，导致到处是小坑，下坡走不通）
	_height_noise = FastNoiseLite.new()
	_height_noise.noise_type           = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_noise.seed                 = seed_val
	_height_noise.frequency            = 0.014
	_height_noise.fractal_type         = FastNoiseLite.FRACTAL_FBM
	_height_noise.fractal_octaves      = 4
	_height_noise.fractal_lacunarity   = 2.0
	_height_noise.fractal_gain         = 0.5

	# 域扭曲：低频，让大陆轮廓非圆形
	_height_warp = FastNoiseLite.new()
	_height_warp.noise_type            = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_warp.seed                  = seed_val + 13
	_height_warp.frequency             = 0.025
	_height_warp.fractal_type          = FastNoiseLite.FRACTAL_FBM
	_height_warp.fractal_octaves       = 3

	# 中频细节：用于山脉脊线 / 海岸碎边
	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type           = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.seed                 = seed_val + 257
	_detail_noise.frequency            = 0.040
	_detail_noise.fractal_type         = FastNoiseLite.FRACTAL_FBM
	_detail_noise.fractal_octaves      = 3

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.noise_type         = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.seed               = seed_val + 9973
	_moisture_noise.frequency          = 0.022
	_moisture_noise.fractal_type       = FastNoiseLite.FRACTAL_FBM
	_moisture_noise.fractal_octaves    = 4
	_moisture_noise.fractal_lacunarity = 2.0
	_moisture_noise.fractal_gain       = 0.5

# ─── 大陆中心点（提供"海中 N 个大陆"骨架） ──────────────────────────────
# v7.3：弃纯随机（两点可能落很近 → 一个大陆），改成确定性分布+小幅 jitter，
# 保证多大陆之间天然有海洋走廊隔开。

func _make_continent_centers(cfg: MapConfig) -> Array:
	var centers: Array = []
	var n: int = cfg.num_continents
	if n <= 1:
		centers.append(Vector2(
			_rng.randf_range(0.40, 0.60),
			_rng.randf_range(0.40, 0.60)
		))
	elif n == 2:
		# 一西一东，距离 ≈ 0.50（jx 小幅 jitter 保持距离 ≥ 0.46）
		# v7.4：原 0.27/0.73 + ±0.05 jx 可能让距离掉到 0.36，<= 两半径和 → 合并。
		# 改成 0.25/0.75 + ±0.02 jx，最小距离 0.46，超过两半径和保证不合并。
		var jx: float = _rng.randf_range(-0.02, 0.02)
		var jy1: float = _rng.randf_range(0.32, 0.68)
		var jy2: float = _rng.randf_range(0.32, 0.68)
		centers.append(Vector2(0.25 + jx, jy1))
		centers.append(Vector2(0.75 - jx, jy2))
	elif n == 3:
		# 等边三角形，加旋转 jitter
		var rot_jitter: float = _rng.randf_range(0.0, TAU / 6.0)
		for i in range(3):
			var angle: float = TAU * float(i) / 3.0 + rot_jitter
			var r: float = _rng.randf_range(0.22, 0.27)
			centers.append(Vector2(0.5 + r * cos(angle), 0.5 + r * sin(angle)))
	else:
		# 4 个或更多：圆周等距分布 + jitter
		var rot_jitter2: float = _rng.randf_range(0.0, TAU / float(n))
		for i in range(n):
			var angle2: float = TAU * float(i) / float(n) + rot_jitter2
			var r2: float = _rng.randf_range(0.22, 0.30)
			centers.append(Vector2(0.5 + r2 * cos(angle2), 0.5 + r2 * sin(angle2)))
	return centers

# 多大陆模式下，每个大陆的影响半径要相应缩小，否则它们会合并成一片
# v7.4：n=2/3 从 0.65 → 0.55，半径变小，海峡更宽，warp 也不容易瓦解
# 1 大陆：完整半径；2-3 大陆：×0.55；4+：×0.50
func _continent_radius_factor(num_continents: int) -> float:
	if num_continents <= 1:
		return 1.0
	if num_continents <= 3:
		return 0.55
	return 0.50

# ─── 海拔计算（域扭曲距离场 + 多频 fbm + 边缘衰减） ──────────────────────

func _compute_elevation(nx: float, ny: float, cfg: MapConfig) -> float:
	# 1. 算到最近 continent_center 的真实距离（不扭曲坐标，保证 deep-ocean 远点不会被拉进 continent）
	var min_dist: float = 99.0
	for c: Vector2 in _continent_centers:
		var dx: float = nx - c.x
		var dy: float = ny - c.y
		var d: float = sqrt(dx * dx + dy * dy)
		if d < min_dist:
			min_dist = d

	# 2. 扰动距离值本身（不扰动坐标）—— 让大陆边界波浪化但不桥接
	# 公式上：min_dist += noise * amp。如果一个 cell 真实 dist 远大于 radius，
	# 加上 ±amp 后还是 > radius，dist_field=0 → 仍然是海。
	# 只有真实 dist 接近 radius 的 cell 才会因为扰动而在 dist_field=0/正 之间摆动。
	var dist_perturb: float = _height_warp.get_noise_2d(nx * 250.0 + 11.3, ny * 250.0 - 7.1) * CONTINENT_WARP_AMP
	min_dist += dist_perturb

	# 3. 大陆距离场（多大陆模式半径自动缩小避免合并）
	var radius: float = cfg.continent_size * 0.6 * _continent_radius_factor(cfg.num_continents)
	var dist_field: float = clampf(1.0 - (min_dist / radius), 0.0, 1.0)
	dist_field = pow(dist_field, 1.5)  # 让大陆边缘衰减更柔和

	# 3. 多频 fbm（用扭曲坐标），给距离场加自然起伏
	var u: float = nx * 200.0
	var v: float = ny * 200.0
	var u_warp: float = _height_warp.get_noise_2d(u + 11.3, v - 7.1) * 35.0
	var v_warp: float = _height_warp.get_noise_2d(u - 23.7, v + 41.5) * 35.0
	var c1: float = _height_noise.get_noise_2d(u + u_warp, v + v_warp)              # 大陆主形
	var c2: float = _detail_noise.get_noise_2d(u * 1.7 + u_warp, v * 1.7 + v_warp)  # 中频
	var noise_01: float = ((c1 * 0.70 + c2 * 0.30) + 1.0) * 0.5  # → [0, 1]

	# 4. 海岸细碎噪声（让海岸线不规则）
	var coast: float = _height_noise.get_noise_2d(nx * 80.0 + 500.0, ny * 80.0 + 500.0) * 0.06

	# 5. 合成：距离场 + 距离场×噪声 + 海岸细节
	# 关键：noise 必须 × dist_field，否则 noise 的均值（0.5）会给地图每个 cell
	# 永久加 0.5*NOISE_WEIGHT = 0.225，远离大陆的中间海域被错误抬到陆地
	# 把两个 continent_center 的间隙焊死成一整块大陆。
	# 现在 noise 只在 dist_field > 0 的区域起作用 = 只在大陆内部加变化。
	# 注意：ridge 不在这里加！否则会被卷进 _normalize_elevation 的范围里
	# 导致归一化分母变大，把所有非山 cell 压低，损失陆地。
	var raw: float = dist_field * (DIST_FIELD_WEIGHT + noise_01 * NOISE_WEIGHT) + coast

	# 6. 边缘衰减：保证地图边界四周是海
	# v7.3：给"距中心距离"加噪声扰动，否则 maxf 给出的是切比雪夫 L∞ 距离，
	# 等距线是矩形 → 海洋形成方框相框。加噪声后等距线变波浪。
	var edge_dx: float = absf(nx - 0.5) * 2.0
	var edge_dy: float = absf(ny - 0.5) * 2.0
	var edge_d_base: float = maxf(edge_dx, edge_dy)
	var edge_perturb: float = _height_warp.get_noise_2d(nx * 150.0 + 199.0, ny * 150.0 - 73.0) * 0.38
	var edge_d: float = edge_d_base + edge_perturb
	var edge_t: float = smoothstep(EDGE_FALLOFF_START, EDGE_FALLOFF_END, edge_d)
	raw -= edge_t * EDGE_FALLOFF_DEPTH

	return raw

# v7.2 新增：在 normalize 之后单独给陆地 cell 加 ridge 山脉
# - 只动 elevation > sea_level 的 cell（海洋不变 → 海陆边界不动）
# - 加成幅度乘以 land_factor（高地多加，海岸线附近少加）
# - 结果 clamp 到 [0, 1] 防止溢出，不影响其他 cell
func _apply_mountain_ridges(map: MapData, cfg: MapConfig) -> void:
	if RIDGE_BOOST_AMP <= 0.0:
		return
	for cell: HexCell in map.all_cells():
		if cell.elevation < cfg.sea_level:
			continue
		var off := HexUtils.cube_to_offset(cell.q, cell.r)
		var nx2: float = float(off.x) / float(cfg.width - 1)
		var ny2: float = float(off.y) / float(cfg.height - 1)
		# ridge_signal = 1 - |fbm|，[0, 1] 的脊形噪声（脊上 ≈ 1，远离脊 ≈ 0）
		var ridge_raw: float = absf(_detail_noise.get_noise_2d(nx2 * 180.0 + 71.3, ny2 * 180.0 - 33.7))
		var ridge_signal: float = 1.0 - ridge_raw
		# land_factor：高地多加（≈1），海岸线附近少加（≈0）
		var land_factor: float = (cell.elevation - cfg.sea_level) / maxf(1.0 - cfg.sea_level, 0.001)
		# v7.4：从平方降到 1.5 次方
		# 平方过于"惩罚"中等海拔 cell（land_factor=0.4 时 squared=0.16 → 加成几乎看不见），
		# 1.5 次方让中等高度的丘陵也能拿到足够 boost 升级成 mountain，山地数量明显多。
		land_factor = pow(land_factor, 1.5)
		var addition: float = ridge_signal * land_factor * RIDGE_BOOST_AMP
		cell.elevation = clampf(cell.elevation + addition, 0.0, 1.0)

# ─── 局部洼地平滑（让河流的 flow accumulation 能下坡到海） ──────────────
# 不平滑会导致大量"碗形 1-cell pit"，flow 在那里止步，最后过滤剩不了几条河。
# 算法：迭代检查每个陆地 cell，如果它比所有 6 个邻居都低 → 抬到最低邻居 + 0.001。

func _smooth_pit_depressions(map: MapData, cfg: MapConfig) -> void:
	var max_iters := 12
	for it in range(max_iters):
		var changed: bool = false
		for cell: HexCell in map.all_cells():
			if cell.elevation < cfg.sea_level:
				continue  # 水下不需要平滑
			var nbs := map.get_neighbors(cell)
			if nbs.is_empty():
				continue
			var lowest_nb: float = INF
			for nb: HexCell in nbs:
				if nb.elevation < lowest_nb:
					lowest_nb = nb.elevation
			# 如果当前 cell 比所有邻居都低（即它是 pit）→ 抬到刚好高于最低邻居
			if lowest_nb < INF and cell.elevation <= lowest_nb:
				cell.elevation = lowest_nb + 0.001
				changed = true
		if not changed:
			break

func _normalize_elevation(map: MapData) -> void:
	var min_e: float = INF
	var max_e: float = -INF
	for cell: HexCell in map.all_cells():
		if cell.elevation < min_e:
			min_e = cell.elevation
		if cell.elevation > max_e:
			max_e = cell.elevation
	var range_e: float = max_e - min_e
	if range_e < 0.001:
		return
	var inv := 1.0 / range_e
	for cell: HexCell in map.all_cells():
		cell.elevation = (cell.elevation - min_e) * inv

# ─── 温度（cos bell 曲线） ───────────────────────────────────────────────

func _compute_temperature(ny: float, elevation: float) -> float:
	# 用余弦做平滑钟形：赤道（ny=0.5）最高 ~1.0，两极 0
	var lat_signed: float = (ny - 0.5) * 2.0   # [-1, +1]
	var lat_temp: float = pow(cos(lat_signed * PI * 0.5), 1.2)
	var alt_penalty: float = elevation * 0.5
	return clampf(lat_temp - alt_penalty, 0.0, 1.0)

# ─── 湿度（基线噪声） ────────────────────────────────────────────────────

func _compute_moisture_base(nx: float, ny: float) -> float:
	var raw: float = _moisture_noise.get_noise_2d(nx * 250.0, ny * 250.0)
	return (raw + 1.0) * 0.5  # [0, 1]

# 沿岸补偿：陆地 cell 紧贴水域 → 湿度提升；远离海岸的内陆相对降低
func _apply_coastal_moisture_boost(map: MapData) -> void:
	# 每个陆地 cell 检查 6 个邻居：有几个是水域
	for cell: HexCell in map.all_cells():
		if _is_water(cell.terrain):
			continue
		var water_nbs: int = 0
		var total_nbs: int = 0
		for nb: HexCell in map.get_neighbors(cell):
			total_nbs += 1
			if _is_water(nb.terrain):
				water_nbs += 1
		if total_nbs == 0:
			continue
		var coastal_ratio: float = float(water_nbs) / float(total_nbs)
		# 1 个相邻水 ≈ 海岸，加 +0.1；3 个相邻水 ≈ 半岛，加 +0.20
		cell.moisture = clampf(cell.moisture + coastal_ratio * COASTAL_MOISTURE_BOOST, 0.0, 1.0)

# ─── 地形决策（阈值轻调） ───────────────────────────────────────────────

func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig) -> TerrainType.TERRAIN:
	if elevation < cfg.sea_level - 0.06:
		return TerrainType.TERRAIN.OCEAN
	if elevation < cfg.sea_level:
		return TerrainType.TERRAIN.COAST

	var land_height: float = (elevation - cfg.sea_level) / (1.0 - cfg.sea_level)

	# 山地（v7.2：阈值下调到 0.62，配合 ridge boost 和 highland_boost，山地分布合理）
	if land_height > 0.52:
		return TerrainType.TERRAIN.MOUNTAIN
	# 雪山（高海拔 + 低温）
	if land_height > 0.52 and temperature < 0.18:
		return TerrainType.TERRAIN.SNOW
	# 极地雪原
	if temperature < 0.10:
		return TerrainType.TERRAIN.SNOW
	# 冻原
	if temperature < 0.22:
		return TerrainType.TERRAIN.TUNDRA
	# 丘陵（v7.2：阈值 0.40 → 大量丘陵，山脚有过渡）
	if land_height > 0.30:
		return TerrainType.TERRAIN.HILL
	# 沙漠
	if temperature > 0.65 and moisture < 0.32:
		return TerrainType.TERRAIN.DESERT
	# 森林
	if temperature > 0.30 and moisture > 0.55:
		return TerrainType.TERRAIN.FOREST
	# 草原
	if temperature > 0.40 and moisture > 0.38:
		return TerrainType.TERRAIN.GRASSLAND
	return TerrainType.TERRAIN.PLAIN

# ─── 河流：Flow Accumulation（汇流累积） ─────────────────────────────────
#
# 算法：
#   1) 收集所有 land cell 并按海拔从高到低排序
#   2) 每个 land cell 找它的下坡邻居 (downhill_dir)，没有则 null（局部最低点）
#   3) 初始流量 = rainfall（湿度调制）
#   4) 按高→低顺序遍历，把每个 cell 的累积流量加给它的下坡邻居
#   5) 流量分位 >= percentile 的 cell 标 has_river
#   6) 过滤孤立的 river cell（无上下游 river 邻居）

func _generate_rivers_flow_accumulation(map: MapData, _cfg: MapConfig) -> void:
	var land_cells: Array = []
	for cell: HexCell in map.all_cells():
		if not _is_water(cell.terrain):
			land_cells.append(cell)
	if land_cells.is_empty():
		return

	# 海拔从高到低排序，保证流量传递时 upstream 先于 downstream
	land_cells.sort_custom(func(a: HexCell, b: HexCell) -> bool: return a.elevation > b.elevation)

	# 1. 每个 land cell 找下坡邻居
	var downhill: Dictionary = {}
	for cell: HexCell in land_cells:
		var lowest_nb: HexCell = null
		var lowest_elev: float = cell.elevation
		for nb: HexCell in map.get_neighbors(cell):
			if nb.elevation < lowest_elev:
				lowest_elev = nb.elevation
				lowest_nb = nb
		if lowest_nb != null:
			downhill[Vector3i(cell.q, cell.r, cell.s)] = lowest_nb

	# 2. 初始 rainfall（湿度调制：干 0.4，湿 1.6）
	var flow: Dictionary = {}
	for cell: HexCell in land_cells:
		var key := Vector3i(cell.q, cell.r, cell.s)
		flow[key] = lerpf(0.4, 1.6, cell.moisture)

	# 3. 按高→低累积流量
	for cell: HexCell in land_cells:
		var key := Vector3i(cell.q, cell.r, cell.s)
		var dh: HexCell = downhill.get(key, null)
		if dh == null:
			continue  # 局部洼地：流量止于此
		var dh_key := Vector3i(dh.q, dh.r, dh.s)
		var src_flow: float = float(flow.get(key, 0.0))
		# 下坡邻居如果是水域，不再累积（流量入海）
		if _is_water(dh.terrain):
			continue
		flow[dh_key] = float(flow.get(dh_key, 0.0)) + src_flow

	# 4. 计算分位阈值：top (1 - percentile) 的 cell 成为河流
	var flow_values: Array = []
	for v in flow.values():
		flow_values.append(float(v))
	flow_values.sort()  # 升序
	if flow_values.is_empty():
		return
	var threshold_idx: int = int(float(flow_values.size()) * RIVER_FLOW_PERCENTILE)
	threshold_idx = clampi(threshold_idx, 0, flow_values.size() - 1)
	var threshold: float = float(flow_values[threshold_idx])

	# 5. 标 has_river
	for cell: HexCell in land_cells:
		var key := Vector3i(cell.q, cell.r, cell.s)
		if float(flow.get(key, 0.0)) >= threshold:
			cell.has_river = true

	# 6. 过滤：必须能下坡到达水（否则是断头沟）
	_filter_dead_end_rivers(map, downhill)

	# 7. 过滤：单点孤立 river（无相邻 river/water）
	_filter_isolated_rivers(map)

# 检查每条 river chain 能否经下坡链达到水域；不能的 unmark
func _filter_dead_end_rivers(map: MapData, downhill: Dictionary) -> void:
	var reach_water_cache: Dictionary = {}  # cube_key -> bool

	# 内联递归不太行，用迭代+缓存
	var cells_to_check: Array = []
	for cell: HexCell in map.all_cells():
		if cell.has_river and not _is_water(cell.terrain):
			cells_to_check.append(cell)

	for cell: HexCell in cells_to_check:
		var visited: Dictionary = {}
		var current: HexCell = cell
		var max_steps: int = 200
		var reached: bool = false
		for _i in range(max_steps):
			var key := Vector3i(current.q, current.r, current.s)
			if reach_water_cache.has(key):
				reached = bool(reach_water_cache[key])
				break
			if visited.has(key):
				break
			visited[key] = true
			if _is_water(current.terrain):
				reached = true
				break
			var dh: HexCell = downhill.get(key, null)
			if dh == null:
				break
			current = dh
		# 沿路径回填 cache
		for k in visited:
			reach_water_cache[k] = reached
		if not reached:
			cell.has_river = false

func _filter_isolated_rivers(map: MapData) -> void:
	# 单 cell 的 river 若四周没有任何 river/water 邻居，去掉
	var to_unmark: Array = []
	for cell: HexCell in map.all_cells():
		if not cell.has_river:
			continue
		var has_river_or_water_nb: bool = false
		for nb: HexCell in map.get_neighbors(cell):
			if nb.has_river or _is_water(nb.terrain):
				has_river_or_water_nb = true
				break
		if not has_river_or_water_nb:
			to_unmark.append(cell)
	for cell: HexCell in to_unmark:
		cell.has_river = false

# ─── 工具 ────────────────────────────────────────────────────────────────

static func _is_water(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN or t == TerrainType.TERRAIN.COAST

func _cube_to_col(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.x, 0, cfg.width - 1)

func _cube_to_row(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.y, 0, cfg.height - 1)
