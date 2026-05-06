# map_generator.gd
# 程序化六边形地图生成器
#
# 生成管线：
#   1. 根据 seed 初始化 FastNoiseLite
#   2. 生成高度图  (continent_noise + distance_field → elevation)
#   3. 生成温度图  (latitude_gradient + elevation_penalty)
#   4. 生成湿度图  (moisture_noise)
#   5. 地形决策    (elevation × temperature × moisture → TerrainType)
#   6. 河流生成    (从山地向低处流，标记 has_river)
#   7. 写入通行性  (apply_terrain 触发 passable_land/sea)

class_name MapGenerator

# ─── 内部噪声实例 ───────────────────────────────────────────────────────
var _height_noise:   FastNoiseLite
var _moisture_noise: FastNoiseLite
var _rng:            RandomNumberGenerator

# ─── 公开接口 ────────────────────────────────────────────────────────────

## 根据 MapConfig 生成并返回一个填充完毕的 MapData
func generate(cfg: MapConfig) -> MapData:
	cfg.validate()

	# 初始化随机源
	_rng = RandomNumberGenerator.new()
	var effective_seed: int = cfg.seed if cfg.seed != 0 else randi()
	_rng.seed = effective_seed

	_init_noise(effective_seed)

	# 创建空地图
	var map := MapData.new(cfg.width, cfg.height)

	# 预计算大陆核心点（归一化坐标 [0,1]）
	var continent_centers: Array = _make_continent_centers(cfg)

	# 逐格生成
	for row in range(cfg.height):
		for col in range(cfg.width):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)

			# 归一化坐标 [0, 1]
			var nx: float = float(col) / float(cfg.width  - 1)
			var ny: float = float(row) / float(cfg.height - 1)

			# 1. 高度图
			cell.elevation = _compute_elevation(nx, ny, continent_centers, cfg)

			map.set_cell(cell)

	# 2. 归一化高度到 [0, 1]（使 sea_level 阈值语义一致）
	_normalize_elevation(map)

	# 3. 地形决策
	for cell in map.all_cells():
		var nx := float(_cube_to_col(cell, cfg)) / float(cfg.width  - 1)
		var ny := float(_cube_to_row(cell, cfg)) / float(cfg.height - 1)

		var temp     := _compute_temperature(ny, cell.elevation, cfg)
		var moisture := _compute_moisture(nx, ny)
		var terrain  := _decide_terrain(cell.elevation, temp, moisture, cfg)
		cell.apply_terrain(terrain)

	# 4. 河流生成
	_generate_rivers(map, cfg)

	return map

# ─── 初始化噪声 ──────────────────────────────────────────────────────────

func _init_noise(seed_val: int) -> void:
	_height_noise = FastNoiseLite.new()
	_height_noise.noise_type  = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_height_noise.seed        = seed_val
	_height_noise.frequency   = 0.018
	_height_noise.fractal_type        = FastNoiseLite.FRACTAL_FBM
	_height_noise.fractal_octaves     = 6
	_height_noise.fractal_lacunarity  = 2.0
	_height_noise.fractal_gain        = 0.5

	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.noise_type  = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.seed        = seed_val + 9973   # 偏移种子，保持独立
	_moisture_noise.frequency   = 0.025
	_moisture_noise.fractal_type        = FastNoiseLite.FRACTAL_FBM
	_moisture_noise.fractal_octaves     = 4
	_moisture_noise.fractal_lacunarity  = 2.0
	_moisture_noise.fractal_gain        = 0.5

# ─── 大陆核心点 ──────────────────────────────────────────────────────────

func _make_continent_centers(cfg: MapConfig) -> Array:
	var centers: Array = []
	for _i in range(cfg.num_continents):
		# 在中间 60% 区域内随机放置核心，避免紧贴边缘
		var cx: float = _rng.randf_range(0.20, 0.80)
		var cy: float = _rng.randf_range(0.20, 0.80)
		centers.append(Vector2(cx, cy))
	return centers

# ─── 高度图计算 ──────────────────────────────────────────────────────────

func _compute_elevation(nx: float, ny: float, centers: Array, cfg: MapConfig) -> float:
	# 噪声基础值 [-1, 1] → [0, 1]
	var noise_val: float = (_height_noise.get_noise_2d(nx * 200.0, ny * 200.0) + 1.0) * 0.5

	# 距离场：取与最近大陆核心的距离
	var min_dist: float = 99.0
	for c in centers:
		var d := sqrt(pow(nx - c.x, 2) + pow(ny - c.y, 2))
		min_dist = minf(min_dist, d)

	# 距离场转 [0,1]：越近值越高
	var radius: float = cfg.continent_size * 0.6
	var dist_field: float = clampf(1.0 - (min_dist / radius), 0.0, 1.0)
	dist_field = pow(dist_field, 1.5)   # 使大陆边缘更平缓

	# 混合：大陆距离场权重 0.55 + 噪声权重 0.45
	var elevation: float = dist_field * 0.55 + noise_val * 0.45

	# 海岸线周围添加轻微噪声，使海岸线不规则
	elevation += _height_noise.get_noise_2d(nx * 80.0 + 500.0, ny * 80.0 + 500.0) * 0.06

	return elevation

# ─── 高度归一化 ──────────────────────────────────────────────────────────

func _normalize_elevation(map: MapData) -> void:
	var min_e := 99.0
	var max_e := -99.0
	for cell in map.all_cells():
		min_e = minf(min_e, cell.elevation)
		max_e = maxf(max_e, cell.elevation)
	var range_e := max_e - min_e
	if range_e < 0.001:
		return
	for cell in map.all_cells():
		cell.elevation = (cell.elevation - min_e) / range_e

# ─── 温度图 ──────────────────────────────────────────────────────────────
# 返回归一化温度 [0, 1]，0 = 极寒，1 = 赤道炎热

func _compute_temperature(ny: float, elevation: float, cfg: MapConfig) -> float:
	# 纬度温度：以赤道（ny=0.5）为最高，两极为 0
	var latitude_temp: float = 1.0 - abs(ny - 0.5) * 2.0   # [0, 1]

	# 高度惩罚：高山更冷
	var altitude_penalty: float = elevation * 0.4

	var temp: float = clampf(latitude_temp - altitude_penalty, 0.0, 1.0)
	return temp

# ─── 湿度图 ──────────────────────────────────────────────────────────────
# 返回归一化湿度 [0, 1]，0 = 极干，1 = 极湿

func _compute_moisture(nx: float, ny: float) -> float:
	var raw: float = _moisture_noise.get_noise_2d(nx * 300.0, ny * 300.0)
	return (raw + 1.0) * 0.5   # [-1,1] → [0,1]

# ─── 地形决策 ────────────────────────────────────────────────────────────

func _decide_terrain(elevation: float, temperature: float, moisture: float, cfg: MapConfig) -> TerrainType.TERRAIN:
	# 1. 深海
	if elevation < cfg.sea_level - 0.06:
		return TerrainType.TERRAIN.OCEAN

	# 2. 浅海 / 海岸带
	if elevation < cfg.sea_level:
		return TerrainType.TERRAIN.COAST

	# 以下为陆地
	var land_height: float = (elevation - cfg.sea_level) / (1.0 - cfg.sea_level)  # 陆地内部归一化高度 [0,1]

	# 3. 山地（极高）
	if land_height > 0.78:
		return TerrainType.TERRAIN.MOUNTAIN

	# 4. 雪地（高海拔 or 极地低温）
	if land_height > 0.60 and temperature < 0.18:
		return TerrainType.TERRAIN.SNOW
	if temperature < 0.10:
		return TerrainType.TERRAIN.SNOW

	# 5. 冻原（极地，低温）
	if temperature < 0.22:
		return TerrainType.TERRAIN.TUNDRA

	# 6. 丘陵
	if land_height > 0.55:
		return TerrainType.TERRAIN.HILL

	# 7. 沙漠（热带干旱）
	if temperature > 0.65 and moisture < 0.35:
		return TerrainType.TERRAIN.DESERT

	# 8. 森林（适中温度、高湿度）
	if temperature > 0.30 and moisture > 0.60:
		return TerrainType.TERRAIN.FOREST

	# 9. 草地（温暖适中）
	if temperature > 0.40 and moisture > 0.40:
		return TerrainType.TERRAIN.GRASSLAND

	# 10. 默认：平原
	return TerrainType.TERRAIN.PLAIN

# ─── 河流生成 ────────────────────────────────────────────────────────────

func _generate_rivers(map: MapData, cfg: MapConfig) -> void:
	# 收集可作为河流源头的高海拔陆地格（丘陵/山地）
	var sources: Array = []
	for cell in map.all_cells():
		if cell.terrain == TerrainType.TERRAIN.HILL or \
		   cell.terrain == TerrainType.TERRAIN.MOUNTAIN:
			sources.append(cell)

	if sources.is_empty():
		return

	sources.shuffle()   # 随机化起点顺序
	var rivers_done := 0
	var max_steps   := cfg.width + cfg.height   # 防止无限循环

	for source in sources:
		if rivers_done >= cfg.river_count:
			break
		if source.has_river:
			continue

		var current: HexCell = source
		var visited: Dictionary = {}
		var success := false

		for _step in range(max_steps):
			if visited.has(Vector3i(current.q, current.r, current.s)):
				break
			visited[Vector3i(current.q, current.r, current.s)] = true
			current.has_river = true

			# 到达海岸/海洋则结束
			if current.terrain == TerrainType.TERRAIN.COAST or \
			   current.terrain == TerrainType.TERRAIN.OCEAN:
				success = true
				break

			# 寻找高度最低的邻居（河流向低处流）
			var neighbors := map.get_neighbors(current)
			var next: HexCell = null
			var lowest := current.elevation

			for nb in neighbors:
				if not visited.has(Vector3i(nb.q, nb.r, nb.s)) and nb.elevation < lowest:
					lowest = nb.elevation
					next = nb

			if next == null:
				break   # 陷入洼地，放弃此条河流
			current = next

		if success:
			rivers_done += 1

# ─── 辅助：cube 坐标反查 offset 行列 ─────────────────────────────────────

func _cube_to_col(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.x, 0, cfg.width - 1)

func _cube_to_row(cell: HexCell, cfg: MapConfig) -> int:
	var off := HexUtils.cube_to_offset(cell.q, cell.r)
	return clampi(off.y, 0, cfg.height - 1)
