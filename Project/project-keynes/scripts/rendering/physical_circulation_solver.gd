# physical_circulation_solver.gd
#
# 物理化大气 / 海洋环流求解器（hex 域）。
#
# 设计目标：把风场与洋流从纯 ny-only 像素函数升级为"二维海陆耦合 + 海盆环流"
# 的简化物理模型——求解粒度落在 hex 中心，结果写入 HexCell 字段（slp /
# wind_vector / wind_speed / wind_stress_curl / ocean_psi / ocean_current /
# upwelling_strength），再由 MapBaker 用 pixel_to_cell_lookup 光栅化为
# 像素 buffer，shader 完全零改动。
#
# 全静态、无内部状态。MapBaker 在烘焙路径里直接调用各 solve_* 方法。
#
# 调用顺序（一轮完整求解）：
#   1. solve_slp_field          —— 海陆压力场 + 6 邻域扩散平滑
#   2. solve_wind_field         —— 地转风 + 沿海压差响应 + 地形扰动
#   3. solve_wind_stress_curl   —— 风应力旋度（ψ 求解的源项）
#   4. solve_ocean_psi          —— SOR 迭代 ∇²ψ = -curl(τ)/β + 西边界强化
#   5. psi_to_ocean_current     —— u = -∂ψ/∂y, v = ∂ψ/∂x
#   6. solve_upwelling          —— 沿岸 Ekman 抽吸 + 高纬冷沉叠加
#
# 任意一步可被关闭：当 ClimateProfile.physical_circulation_enabled = false
# 时 MapBaker 自己跳过这整条路径走旧 ny-only 算法；
# enable_ocean_heat_transport = false 时步骤 3~5 跳过、ocean_current
# 由 nyOnly Ekman 直接写出。

class_name PhysicalCirculationSolver

const HexUtilsScript = preload("res://scripts/geography/hex_utils.gd")
const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")
const DCClimateMath = preload("res://scripts/simulation/climate/climate_math.gd")

# ─── 几何常量：六个邻居方向在屏幕坐标系下的"世界向量"（pointy-top 六边形）─────
# 对应 HexUtils.CUBE_DIRECTIONS 顺序：0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE
# 取自 HexUtils.cube_to_world(dq, dr, size=1)，仅记单位"邻居偏移方向"，
# 求解时 × hex_size 还原物理距离。注意 +x=东，+y=南（与 wind_at 同约定）。
const SQRT3_HALF := 0.8660254037844387        # √3 / 2
const NEIGHBOR_DIRS: Array[Vector2] = [
	Vector2( SQRT3_HALF * 2.0,  0.0),    # 0 E
	Vector2( SQRT3_HALF,       -1.5),    # 1 NE
	Vector2(-SQRT3_HALF,       -1.5),    # 2 NW
	Vector2(-SQRT3_HALF * 2.0,  0.0),    # 3 W
	Vector2(-SQRT3_HALF,        1.5),    # 4 SW
	Vector2( SQRT3_HALF,        1.5),    # 5 SE
]

# ─── ny / lat_signed 推导 ─────────────────────────────────────────────────
#
# 与现有 MapBaker 中各处计算保持一致：ny = (cell_world_y - bounds.y) / bounds.h
# clampf 到 [0,1]。lat_signed = (ny - 0.5) * 2 ∈ [-1, +1]，正南半球、负北半球。
# lat_temp = DCClimateMath.lat_temp_bell(|lat_signed|) 是温度钟形曲线代理（全工程单一来源）。
static func _ny_for_cell(cell: HexCell, hex_size: float, world_bounds: Rect2) -> float:
	if world_bounds.size.y <= 0.001:
		return 0.5
	var wp: Vector2 = HexUtilsScript.cube_to_world(cell.q, cell.r, hex_size)
	var ny: float = (wp.y - world_bounds.position.y) / world_bounds.size.y
	return clampf(ny, 0.0, 1.0)

static func _lat_signed_for(ny: float) -> float:
	return (ny - 0.5) * 2.0

static func _lat_temp_for(lat_signed_abs: float) -> float:
	# 纬度温度钟形统一走 DCClimateMath.lat_temp_bell（全工程单一来源）。
	return DCClimateMath.lat_temp_bell(lat_signed_abs)

# 水域判断：与 MapBaker._is_water 同语义（OCEAN/COAST/REEF/KELP）。
# 注意：LAKE 不算入海盆环流（水文层独立处理），SEA_ICE 在覆盖物层翻转。
static func _is_water_terrain(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP

static func _cell_idx(map: MapData, cell: HexCell) -> int:
	if map == null or cell == null:
		return -1
	if cell.index >= 0:
		return cell.index
	if map.has_indices():
		return map.index_of(cell)
	return -1

static func _read_temp_anomaly(map: MapData, cell: HexCell) -> float:
	var idx: int = _cell_idx(map, cell)
	if idx >= 0 and map.temp_anomaly_arr.size() > idx:
		return map.temp_anomaly_arr[idx]
	return cell.temp_dev_from_annual if cell != null else 0.0

static func _read_snow_cover(map: MapData, cell: HexCell) -> float:
	var idx: int = _cell_idx(map, cell)
	if idx >= 0 and map.snow_cover_arr.size() > idx:
		return map.snow_cover_arr[idx]
	return cell.snow_cover if cell != null else 0.0

static func _read_sea_ice_frac(map: MapData, cell: HexCell) -> float:
	var idx: int = _cell_idx(map, cell)
	if idx >= 0 and map.sea_ice_frac_arr.size() > idx:
		return map.sea_ice_frac_arr[idx]
	return cell.sea_ice_fraction if cell != null else 0.0

static func _density_proxy(map: MapData, cell: HexCell, cold_weight: float,
		ice_weight: float) -> float:
	if cell == null or not _is_water_terrain(int(cell.terrain)):
		return 0.0
	var temp_now: float = clampf(cell.temperature, 0.0, 1.0)
	var temp_anom: float = _read_temp_anomaly(map, cell)
	var ice: float = clampf(_read_sea_ice_frac(map, cell), 0.0, 1.0)
	return cold_weight * (1.0 - temp_now) + ice_weight * ice - temp_anom

static func _profile_float(profile: ClimateProfile, prop_name: StringName, fallback: float) -> float:
	if profile == null:
		return fallback
	var value = profile.get(prop_name)
	return fallback if value == null else float(value)

static func _insolation_dev_for(ny: float, season_phase: float,
		profile: ClimateProfile = null) -> float:
	var tilt_deg: float = _profile_float(profile, &"axial_tilt_deg", 23.5)
	var daylen_amp: float = _profile_float(profile, &"insolation_daylen_amp", 0.35)
	return DCClimateMath.compute_insolation_dev(ny, season_phase, tilt_deg, daylen_amp)

# ═══════════════════════════════════════════════════════════════════════════
# 任务 2：海陆压力场（SLP）求解器
# ═══════════════════════════════════════════════════════════════════════════
#
# 物理模型（极简）：
#   slp = base_lat(ny) + landsea(insolation_dev, lat_temp, is_water, continentality)
#   ↓ 1~3 次 6 邻域扩散平滑
#
# 1) 纬度基线 base_lat(ny)：
#    - 赤道带（|lat_signed| < 0.15）→ 副热带辐合带 ITCZ → 低压（slp ↓）
#    - 副热带（0.25~0.45） → 副热带高压 → 高压（slp ↑）
#    - 副极地（0.55~0.75） → 副极地低压 → 低压（slp ↓）
#    - 极地（> 0.85） → 极地高压 → 高压（slp ↑）
#    用 4 段余弦插值合成连续曲线，幅度归一到 ±0.4。
#
# 2) 海陆性 landsea：
#    - season_phase 只作为年内轨道相位进入太阳直射点、日照和昼长计算。
#    - 当前日照相对年均值的偏差 solar_dev 代表当地辐射加热异常。
#    - 陆地：landsea = -solar_dev * land_amp * lat_temp_factor
#       lat_temp_factor 在中纬最强（~0.7）、赤道极地都低（避免不切实际的"赤道大陆冬高压"）
#    - 水域：弱缩放（0.2x），体现水体热惯性，避免被周围陆地拖拽出伪压力中心
#    - 大陆性（continentality）：用沿陆距离近似——内陆 cell 海陆效应 × 1.3，沿海 × 0.6
#
# 3) 6 邻域扩散平滑：
#    用六边形 box filter 做 N 次 Jacobi 平滑（N=2 默认）。每次：
#       slp_new = (slp + Σ slp_neighbor) / (1 + count_neighbor)
#    平滑后压力中心连贯，无单格噪点。

const _SLP_LAT_AMP := 0.26              # 纬度基线幅度（±）。提高三圈环流压差，避免 SLP range 被压到 0.1 量级。
const _SLP_LAND_AMP := 0.55             # 陆地海陆性幅度（夏低冬高峰值）
const _SLP_WATER_DAMP := 0.35           # 水域海陆季节响应缩放；水面也需保留足够压差驱动风应力。
const _SLP_SMOOTH_PASSES := 1           # 默认 6 邻域 Jacobi 平滑次数（2026-05：2→1，少磨一次保留陆地细节）
const _SLP_INTERIOR_BOOST := 1.30       # 内陆 cell 海陆性系数
const _SLP_COAST_DAMP := 0.60           # 沿海 cell 海陆性系数

## solve_slp_field —— 求解海陆压力场，写入 cell.slp。
##
## 入参：
##   map:           MapData
##   hex_size:      float           —— 用于 hex → world 坐标换算
##   world_bounds:  Rect2           —— 用于推 ny
##   season_phase:  float ∈ [0, 4)  —— 年内轨道相位，只用于计算太阳直射点/日照
##   smooth_passes: int             —— 邻域 Jacobi 平滑次数（默认 _SLP_SMOOTH_PASSES）
##
## 输出：写入 cell.slp ∈ ~[-1, 1]（不严格 clamp）。
static func solve_slp_field(map: MapData, hex_size: float, world_bounds: Rect2, \
		season_phase: float, smooth_passes: int = _SLP_SMOOTH_PASSES,
		profile: ClimateProfile = null) -> void:
	if map == null:
		return
	var cells: Array = map.all_cells()
	if cells.is_empty():
		return
	var thermal_weight: float = profile.wind_thermal_slp_weight if profile != null else 0.0
	var ice_high_weight: float = profile.slp_ice_high_weight if profile != null else 0.0
	var snow_high_weight: float = profile.slp_snow_high_weight if profile != null else 0.0

	# Pass A：基线 + 海陆性写入 cell.slp（先存第一遍，后续平滑会原地迭代）。
	for cell: HexCell in cells:
		if cell == null:
			continue
		var ny: float = _ny_for_cell(cell, hex_size, world_bounds)
		var ls: float = _lat_signed_for(ny)
		var ls_abs: float = absf(ls)
		# 纬度基线：赤道低压、副热带高压、副极地低压、极地高压。
		# 使用 -cos(3π * ls_abs) 精确锁定三圈环流节点：
		#   ls_abs=0.00 → -1.0 (ITCZ 低压) ✓
		#   ls_abs=0.33 → +1.0 (30°副热带高压) ✓
		#   ls_abs=0.67 → -1.0 (60°副极地低压) ✓
		#   ls_abs=1.00 → +1.0 (极地高压) ✓
		var base_lat: float = -_SLP_LAT_AMP * cos(ls_abs * PI * 3.0)

		# 中纬最敏感：lat_temp_factor 用 sin²(π*ls_abs) 在 |lat|=0.5 处 = 1，赤道极地 = 0
		var lat_temp_factor: float = sin(ls_abs * PI)
		lat_temp_factor *= lat_temp_factor

		var is_water: bool = _is_water_terrain(int(cell.terrain))
		var solar_dev: float = _insolation_dev_for(ny, season_phase, profile)
		var solar_heat: float = solar_dev * lat_temp_factor
		var landsea: float = 0.0
		if is_water:
			# 水域热惯性强，响应弱于陆地。
			landsea = -solar_heat * _SLP_LAND_AMP * _SLP_WATER_DAMP
		else:
			# 陆地：检查是否沿海（任一邻居是水）
			var is_coast: bool = false
			for nb: HexCell in map.get_neighbors(cell):
				if nb != null and _is_water_terrain(int(nb.terrain)):
					is_coast = true
					break
			var continentality: float = _SLP_COAST_DAMP if is_coast else _SLP_INTERIOR_BOOST
			landsea = -solar_heat * _SLP_LAND_AMP * continentality

		var temp_anomaly: float = _read_temp_anomaly(map, cell)
		var thermal_response: float = 0.55 if is_water else 1.0
		var thermal_src: float = temp_anomaly if absf(temp_anomaly) > 0.000001 else solar_heat
		var thermal_slp: float = -thermal_weight * thermal_src * thermal_response
		var ice_high: float = ice_high_weight * clampf(_read_sea_ice_frac(map, cell), 0.0, 1.0)
		var snow_high: float = snow_high_weight * clampf(_read_snow_cover(map, cell), 0.0, 1.0)
		cell.slp = base_lat + landsea + thermal_slp + ice_high + snow_high

	# Pass B：6 邻域 Jacobi 平滑 N 次。每次先把所有 cell 的新值读入临时数组，
	# 再一次性写回，避免传播顺序依赖。
	var n_cells: int = cells.size()
	if smooth_passes > 0:
		var buf := PackedFloat32Array()
		buf.resize(n_cells)
		for pass_idx in range(smooth_passes):
			for i in range(n_cells):
				var c: HexCell = cells[i]
				if c == null:
					buf[i] = 0.0
					continue
				var sum_slp: float = c.slp
				var cnt: int = 1
				for nb: HexCell in map.get_neighbors(c):
					if nb == null:
						continue
					sum_slp += nb.slp
					cnt += 1
				buf[i] = sum_slp / float(cnt)
			# 写回
			for i in range(n_cells):
				var c2: HexCell = cells[i]
				if c2 != null:
					c2.slp = buf[i]

	var mean_slp: float = 0.0
	var valid_count: int = 0
	for cell: HexCell in cells:
		if cell == null:
			continue
		mean_slp += cell.slp
		valid_count += 1
	if valid_count <= 0:
		return
	mean_slp /= float(valid_count)
	var abs_vals: Array[float] = []
	abs_vals.resize(valid_count)
	var wi: int = 0
	for cell: HexCell in cells:
		if cell == null:
			continue
		cell.slp -= mean_slp
		abs_vals[wi] = absf(cell.slp)
		wi += 1
	abs_vals.sort()
	var p95_idx: int = clampi(int(floor(float(valid_count - 1) * 0.95)), 0, valid_count - 1)
	var p95: float = abs_vals[p95_idx]
	if p95 > 0.00001:
		var scale: float = clampf(0.32 / p95, 0.75, 3.60)
		for cell: HexCell in cells:
			if cell != null:
				cell.slp *= scale


# ═══════════════════════════════════════════════════════════════════════════
# 任务 3：物理化风场 hex 求解器
# ═══════════════════════════════════════════════════════════════════════════
#
# 物理模型：
#   v_grad_rot = rotate(-∇slp / f, coriolis_angle(lat))     # 压力梯度风做科氏偏转
#   v_wind = w_lat * v_baseline(ny, orbital_phase)          # 自由大气基线（已是地转风结果）
#          + w_grad * v_grad_rot                            # 偏转后的压力梯度风
#          + coastal_weight * pressure-gradient response    # 沿海热力环流由 SLP 梯度体现
#   |v|    = wind_speed_at(ny, phase) × terrain_damp(landform)
#
# 关键修正（2026-05）：
#   早期版本对 v_sum 整体做科氏旋转，导致 WindBelt baseline（已经是地转风结果）
#   被二次偏转，中纬西风带（向东）拗成了偏南风，overlay 出现错误的绿/蓝条带。
#   现在 baseline 直接使用，只对刚算的 -∇slp 做科氏旋转。
#
# 6 邻域离散梯度：用"加权差分向量和"近似 ∇slp。
#   ∇slp ≈ (2/N) * Σ_i (slp_nb_i - slp_self) * d_i_unit
#   其中 d_i_unit 是邻居 i 的单位方向向量（六边形顶点方向，2/N 规范化系数）。
#   这是六边形几何下经典"中心差分"算子的离散形式，无方向偏置。
#
# 科氏偏转：北半球（lat_signed < 0）右偏 → 数学正向 = 顺时针（屏幕坐标 +y=南）。
#   屏幕坐标系下，对向量 (x, y) 顺时针旋转 θ 角度：
#       x' = x*cos - y*sin,  y' = x*sin + y*cos
#   北半球用 +θ_hemi（顺时针 = 右偏）；南半球用 -θ_hemi。
#   |θ_hemi| 随 |lat_signed| 从 0 → 0.78（约 45°）非线性增长，赤道无偏转。

# SLP 公式已修复 → 梯度风方向正确。压力梯度和天气尺度扰动决定本地风，
# WindBelt 提供三圈环流背景。
const _WIND_W_LAT := 0.45              # 纬度基线权重，作为大尺度三圈环流背景
const _WIND_W_GRAD := 1.05             # 压力梯度风权重，强压差时主导本地风向
const _WIND_W_COAST_THERMAL := 0.58    # 沿海热力压差权重，不指定季节性风向
const _WIND_COAST_THERMAL_MAX_DIST := 5 # 沿海热力影响向内陆渗透的格数
const _WIND_CORIOLIS_MAX_RAD := 1.20   # 最大科氏偏转角（仅作用于压力梯度风）
const _WIND_PRESSURE_GRAD_WEAK := 0.006
const _WIND_PRESSURE_GRAD_STRONG := 0.055
const _WIND_PRESSURE_BASE_W := 0.55
const _WIND_PRESSURE_GRAD_W := 2.55
const _WIND_LAT_GRAD_SUPPRESS := 0.75
const _WIND_TERRAIN_MOUNTAIN_DAMP := 0.55  # 山地风速衰减
const _WIND_TERRAIN_HILL_DAMP := 0.85      # 丘陵风速衰减
const _WIND_LAND_FRICTION := 0.85          # 陆地摩擦：风速 × 此系数
# 山脉绕流：检测当前 cell 周围 "山地邻居" 的合成方向，对风向做沿山脉切向的偏转。
# 物理上对应 "风遇山被迫绕流" 现象（山前堆积、山后焚风、迎风面减速、绕侧加速）。
const _WIND_MOUNTAIN_DEFLECT_W := 0.85   # 上游山脉绕流偏转权重（0.45 → 0.85：山脉旁的风向应清晰沿等高线弯折）
const _WIND_MOUNTAIN_UPSTREAM_DAMP := 0.55  # 山脉迎风格的额外速度衰减（0.80 → 0.55：迎风面失速更明显）
# 几何海风(thermal sea breeze)：海陆连续 onshore——陆地侧朝内陆(-coast_sea) + 海洋侧朝陆(sea_land)，
# 拼成"深海→近岸→海岸→内陆"水汽输送带。方向用几何(弃用 SLP 梯度：海陆温差弱→只 ~56% 指向内陆)。
# 只抽陆地侧(W=1.5→陆地 onshore 99%)会断链：海洋补不进、沿海被抽干、海洋堆积成永雨；故 W=1.0
# (hop1~78%) + 海洋侧补充更平衡。此系数是相对本地风量级的比例(海风 = W×dist_w×|v_sum|)，与地转风解耦。
const _WIND_SEA_BREEZE_W := 1.0
const _SEA_BREEZE_SEA_MAX_DIST := 5   # 海洋侧海风延伸格数(朝陆，与陆地侧 5 格对称)

## solve_wind_field —— 求解物理化风场，写入 cell.wind_vector / cell.wind_speed。
##
## 入参：
##   map:           MapData
##   hex_size:      float
##   world_bounds:  Rect2
##   season_phase:  float ∈ [0, 4)，年内轨道相位
##   terrain_aware: bool   —— 是否启用地形偏转（对应 ClimateProfile.enable_terrain_aware_wind）
##
## 前置条件：cell.slp 已由 solve_slp_field 写入。
##
## 输出：cell.wind_vector ∈ 单位向量；cell.wind_speed ∈ 物理量级（约 [0.1, 2.0]）。
static func solve_wind_field(map: MapData, hex_size: float, world_bounds: Rect2, \
		season_phase: float, terrain_aware: bool = true,
		profile: ClimateProfile = null) -> void:
	if map == null:
		return
	var cells: Array = map.all_cells()
	if cells.is_empty():
		return
	var response_rate: float = clampf(profile.wind_response_rate if profile != null else 1.0, 0.0, 1.0)

	# Pass 0：BFS 计算每个陆地 cell 到最近海岸的距离（格数），用于沿海热力压差权重。
	# 距离限制为 _WIND_COAST_THERMAL_MAX_DIST，超出范围视为远内陆。
	var coast_dist: Dictionary = {}     # HexCell → int（0 = 沿海陆地，>0 = 内陆距海岸格数）
	var coast_sea: Dictionary = {}      # HexCell → Vector2（朝海单位向量，从最近海岸继承；镜像 C++ coast_sea_x/y）
	var bfs_queue: Array = []
	for cell0: HexCell in cells:
		if cell0 == null:
			continue
		if _is_water_terrain(int(cell0.terrain)):
			continue
		# 沿海陆地（任一邻居是水）：距离 = 0，朝海方向 = 指向水邻居的合成单位向量
		var sea_v0: Vector2 = Vector2.ZERO
		for nb0: HexCell in map.get_neighbors(cell0):
			if nb0 == null:
				continue
			if not _is_water_terrain(int(nb0.terrain)):
				continue
			var dq0: int = nb0.q - cell0.q
			var dr0: int = nb0.r - cell0.r
			for i0 in range(6):
				var d0: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[i0]
				if d0.x == dq0 and d0.y == dr0:
					sea_v0 += NEIGHBOR_DIRS[i0]
					break
		if sea_v0.length_squared() > 0.0001:
			coast_dist[cell0] = 0
			coast_sea[cell0] = sea_v0.normalized()
			bfs_queue.append(cell0)
	# BFS 层扩展，最远到 _WIND_COAST_THERMAL_MAX_DIST。朝海方向沿途继承最近海岸的值。
	var bfs_head: int = 0
	while bfs_head < bfs_queue.size():
		var cur: HexCell = bfs_queue[bfs_head]
		bfs_head += 1
		var cur_d: int = int(coast_dist[cur])
		if cur_d >= _WIND_COAST_THERMAL_MAX_DIST:
			continue
		var cur_sea: Vector2 = coast_sea[cur]
		for nb_b: HexCell in map.get_neighbors(cur):
			if nb_b == null:
				continue
			if _is_water_terrain(int(nb_b.terrain)):
				continue
			if coast_dist.has(nb_b):
				continue
			coast_dist[nb_b] = cur_d + 1
			coast_sea[nb_b] = cur_sea
			bfs_queue.append(nb_b)

	# Pass 0b：海洋侧 BFS — sea_dist(海洋 cell 距最近陆地格数) + sea_land(朝陆单位向量)。
	# 用于海洋侧几何海风(朝陆)，与陆地侧拼成海陆连续 onshore，修复"海洋水汽补不进沿海"断链。
	var sea_dist: Dictionary = {}       # HexCell → int（0 = 紧邻陆地的海洋）
	var sea_land: Dictionary = {}       # HexCell → Vector2（朝陆单位向量，从沿岸继承；镜像 C++ sea_land_x/y）
	var sea_queue: Array = []
	for cellS: HexCell in cells:
		if cellS == null:
			continue
		if not _is_water_terrain(int(cellS.terrain)):
			continue
		# 沿岸海洋（任一邻居是陆地）：sea_dist = 0，朝陆方向 = 指向陆地邻居的合成单位向量
		var land_vS: Vector2 = Vector2.ZERO
		for nbS: HexCell in map.get_neighbors(cellS):
			if nbS == null:
				continue
			if _is_water_terrain(int(nbS.terrain)):
				continue
			var dqS: int = nbS.q - cellS.q
			var drS: int = nbS.r - cellS.r
			for iS in range(6):
				var dS: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[iS]
				if dS.x == dqS and dS.y == drS:
					land_vS += NEIGHBOR_DIRS[iS]
					break
		if land_vS.length_squared() > 0.0001:
			sea_dist[cellS] = 0
			sea_land[cellS] = land_vS.normalized()
			sea_queue.append(cellS)
	var sea_head: int = 0
	while sea_head < sea_queue.size():
		var curS: HexCell = sea_queue[sea_head]
		sea_head += 1
		var cur_dS: int = int(sea_dist[curS])
		if cur_dS >= _SEA_BREEZE_SEA_MAX_DIST:
			continue
		var cur_landS: Vector2 = sea_land[curS]
		for nb_s: HexCell in map.get_neighbors(curS):
			if nb_s == null:
				continue
			if not _is_water_terrain(int(nb_s.terrain)):
				continue
			if sea_dist.has(nb_s):
				continue
			sea_dist[nb_s] = cur_dS + 1
			sea_land[nb_s] = cur_landS
			sea_queue.append(nb_s)

	for cell: HexCell in cells:
		if cell == null:
			continue
		var ny: float = _ny_for_cell(cell, hex_size, world_bounds)
		var ls: float = _lat_signed_for(ny)
		var ls_abs: float = absf(ls)

		# (a) 纬度基线
		var v_base: Vector2 = WindBeltScript.wind_at(ny, season_phase)

		# (b) 压力梯度风：6 邻域离散梯度。dir_i 用 NEIGHBOR_DIRS（hex 中心相对位移
		# 的单位方向，已与 HexUtils 顺序对齐）。
		var grad_slp: Vector2 = Vector2.ZERO
		var nb_count: int = 0
		var nbs: Array = map.get_neighbors(cell)
		# 找到每个邻居在 NEIGHBOR_DIRS 中的索引：用 cube 坐标差分识别方向
		# 因为 get_neighbors 不保证返回顺序与 CUBE_DIRECTIONS 一致，先重建对应。
		for nb: HexCell in nbs:
			if nb == null:
				continue
			var dq: int = nb.q - cell.q
			var dr: int = nb.r - cell.r
			var dir_idx: int = -1
			for i in range(6):
				var d: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[i]
				if d.x == dq and d.y == dr:
					dir_idx = i
					break
			if dir_idx < 0:
				continue
			var d_unit: Vector2 = NEIGHBOR_DIRS[dir_idx]
			# 离散梯度贡献：(slp_nb - slp_self) × d_unit
			# d_unit 长度并非严格 1（六边形顶点距离），但作为"方向加权"足够
			grad_slp += (nb.slp - cell.slp) * d_unit
			nb_count += 1
		if nb_count > 0:
			# 规范化系数：六边形 6 邻域差分 ≈ 3 倍真实梯度（六边形对称性），
			# 这里用 1/3 简单缩放即可。
			grad_slp /= 3.0
		var grad_mag: float = grad_slp.length()
		var grad_w: float = smoothstep(_WIND_PRESSURE_GRAD_WEAK, _WIND_PRESSURE_GRAD_STRONG, grad_mag)
		# 压力梯度风方向：- ∇slp（高 → 低）
		var v_grad_raw: Vector2 = -grad_slp
		if grad_mag > 0.00000001:
			v_grad_raw /= grad_mag
		else:
			v_grad_raw = Vector2.ZERO

		# (d) 科氏偏转：对压力梯度风分量旋转。
		# 注意：WindBelt.wind_at() 输出的纬度基线本身就是地转风结果（西风带、信风带等
		# 已经体现了科氏偏转），如果对 v_sum 整体再次旋转 30°+，等于二次偏转，会把
		# 中纬西风带（向东）拗成偏南风，导致 overlay 出现错误的绿/蓝条带。
		# 因此这里只对刚算出来的 v_grad 做科氏偏转，再与 baseline 加权合成。
		# rot：有符号顺时针弧度。北半球（ls < 0）取 +|θ|（右偏 = 顺时针）；
		# 南半球取 -|θ|（左偏 = 逆时针）。
		var coriolis_angle: float = _WIND_CORIOLIS_MAX_RAD * pow(ls_abs, 0.55)
		var rot: float = coriolis_angle * (1.0 if ls < 0.0 else -1.0)
		var cos_r: float = cos(rot)
		var sin_r: float = sin(rot)
		# 屏幕坐标系下顺时针 θ：x' = x cos θ + y sin θ, y' = -x sin θ + y cos θ
		var v_grad: Vector2 = Vector2(
			v_grad_raw.x * cos_r + v_grad_raw.y * sin_r,
			-v_grad_raw.x * sin_r + v_grad_raw.y * cos_r
		)
		var ageo_w: float = 1.0 - smoothstep(0.10, 0.55, ls_abs)
		v_grad = v_grad_raw * ageo_w + v_grad * (1.0 - ageo_w)
		if v_grad.length_squared() > 0.0001:
			v_grad = v_grad.normalized()

		# (c) 沿海热力环流权重：方向由 SLP 梯度决定，不再由季节符号指定。
		var is_water: bool = _is_water_terrain(int(cell.terrain))
		var coast_pressure_w: float = 0.0
		if not is_water and coast_dist.has(cell):
			var md: int = int(coast_dist[cell])
			coast_pressure_w = 1.0 - float(md) / float(_WIND_COAST_THERMAL_MAX_DIST)
			coast_pressure_w = clampf(coast_pressure_w, 0.0, 1.0)

		# 加权合成（baseline 已是地转风、v_grad 已做科氏偏转，直接相加）
		var lat_w: float = _WIND_W_LAT * (1.0 - _WIND_LAT_GRAD_SUPPRESS * grad_w)
		var pressure_w: float = _WIND_W_GRAD * (_WIND_PRESSURE_BASE_W + _WIND_PRESSURE_GRAD_W * grad_w) \
				* (1.0 + _WIND_W_COAST_THERMAL * coast_pressure_w)
		var v_sum: Vector2 = lat_w * v_base + pressure_w * v_grad
		# (c2) 几何海风 → 海陆连续 onshore 水汽输送（见 _WIND_SEA_BREEZE_W 注释）。
		# 陆地侧朝内陆(-coast_sea) + 海洋侧朝陆(sea_land)，拼成"深海→近岸→海岸→内陆"连续带。
		# 只抽陆地侧会把沿海抽干、海洋补不进(hop0→hop1 vapor 断崖)；海洋侧朝陆把海洋水汽推上岸。
		var vs_mag: float = v_sum.length()
		if not is_water and coast_pressure_w > 0.0 and coast_sea.has(cell):
			v_sum += (_WIND_SEA_BREEZE_W * coast_pressure_w * vs_mag) * (-(coast_sea[cell] as Vector2))
		elif is_water and sea_dist.has(cell):
			var sea_pw: float = 1.0 - float(int(sea_dist[cell])) / float(_SEA_BREEZE_SEA_MAX_DIST)
			v_sum += (_WIND_SEA_BREEZE_W * sea_pw * vs_mag) * (sea_land[cell] as Vector2)
		if v_sum.length_squared() < 0.0001:
			# 退化保护：用纬度基线
			v_sum = v_base

		# 方向 / 速度分离
		var dir: Vector2 = v_sum.normalized() if v_sum.length_squared() > 0.0001 else Vector2(1.0, 0.0)
		var spd: float = WindBeltScript.wind_speed_at(ny, season_phase)
		spd += clampf(grad_mag * 9.0, 0.0, 0.65)
		if coast_pressure_w > 0.0:
			spd += coast_pressure_w * grad_w * 0.22

		# (e) 地形 / 摩擦衰减
		if not is_water:
			spd *= _WIND_LAND_FRICTION
		if profile != null and profile.get("wind_belt_only_debug") != null and bool(profile.wind_belt_only_debug):
			dir = v_base.normalized() if v_base.length_squared() > 0.0001 else Vector2(1.0, 0.0)
			cell.wind_vector = dir
			cell.wind_speed = spd
			var idx_wb: int = _cell_idx(map, cell)
			if idx_wb >= 0:
				if map.wind_x_arr.size() > idx_wb:
					map.wind_x_arr[idx_wb] = dir.x
				if map.wind_y_arr.size() > idx_wb:
					map.wind_y_arr[idx_wb] = dir.y
				if map.wind_speed_arr.size() > idx_wb:
					map.wind_speed_arr[idx_wb] = spd
			continue
		if terrain_aware:
			# (e1) 山脉绕流：检查邻居中是否存在山地/peak。如有，沿其切向偏转风向，
			# 风"撞向山"时被推向沿等高线方向。
			# 实现：mtn_dir_sum = 指向山脉合成方向（陆地的 mountain 邻居 → 累加方向）。
			# 若风方向与 mtn_dir_sum 同向（dot > 0，朝山吹），则把风沿 mtn_dir_sum 的
			# 90° 切向（左右取与原方向夹角更小的那个）混入，模拟绕流。
			var mtn_dir_sum: Vector2 = Vector2.ZERO
			var has_mtn_nb: bool = false
			if not is_water:
				for nb_m: HexCell in nbs:
					if nb_m == null:
						continue
					var lf_m: int = int(nb_m.landform)
					if lf_m == LandformType.LF.MOUNTAIN or lf_m == LandformType.LF.PEAK:
						var dqm: int = nb_m.q - cell.q
						var drm: int = nb_m.r - cell.r
						for im in range(6):
							var dm: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[im]
							if dm.x == dqm and dm.y == drm:
								mtn_dir_sum += NEIGHBOR_DIRS[im]
								break
						has_mtn_nb = true
			if has_mtn_nb and mtn_dir_sum.length_squared() > 0.0001:
				var mtn_n: Vector2 = mtn_dir_sum.normalized()
				var dot_m: float = dir.dot(mtn_n)
				if dot_m > 0.0:
					# 风正在吹向山脉。算两个切向，挑与当前 dir 更接近的那个。
					var tan_a: Vector2 = Vector2(-mtn_n.y, mtn_n.x)
					var tan_b: Vector2 = Vector2(mtn_n.y, -mtn_n.x)
					var tan_pick: Vector2 = tan_a if dir.dot(tan_a) >= dir.dot(tan_b) else tan_b
					var blend_w: float = _WIND_MOUNTAIN_DEFLECT_W * dot_m  # dot 越大（越正面撞）越偏
					dir = ((1.0 - blend_w) * dir + blend_w * tan_pick).normalized()
					# 迎风格风速额外衰减
					spd *= lerp(1.0, _WIND_MOUNTAIN_UPSTREAM_DAMP, dot_m)
			match int(cell.landform):
				LandformType.LF.MOUNTAIN, LandformType.LF.PEAK:
					spd *= _WIND_TERRAIN_MOUNTAIN_DAMP
					# 山地 cell 受周围 ∇slp 拽得更厉害；这里给压力梯度多一份权重
					var mtn_pull: Vector2 = -grad_slp
					if mtn_pull.length_squared() > 0.0001:
						dir = (dir + 0.4 * mtn_pull.normalized()).normalized()
				LandformType.LF.HILL:
					spd *= _WIND_TERRAIN_HILL_DAMP
				_:
					pass

		var old_dir: Vector2 = cell.wind_vector
		var old_spd: float = cell.wind_speed
		var effective_rate: float = response_rate
		if old_dir.length_squared() < 0.0001 or old_spd <= 0.0001:
			effective_rate = 1.0
		var old_flux: Vector2 = Vector2.ZERO
		if old_dir.length_squared() > 0.0001:
			old_flux = old_dir.normalized() * old_spd
		var target_flux: Vector2 = dir * spd
		var final_flux: Vector2 = old_flux.lerp(target_flux, effective_rate)
		var final_spd: float = lerpf(old_spd, spd, effective_rate)
		var final_dir: Vector2 = final_flux.normalized() if final_flux.length_squared() > 0.0001 else dir
		cell.wind_vector = final_dir
		cell.wind_speed = final_spd
		var idx_w: int = _cell_idx(map, cell)
		if idx_w >= 0:
			if map.wind_x_arr.size() > idx_w:
				map.wind_x_arr[idx_w] = final_dir.x
			if map.wind_y_arr.size() > idx_w:
				map.wind_y_arr[idx_w] = final_dir.y
			if map.wind_speed_arr.size() > idx_w:
				map.wind_speed_arr[idx_w] = final_spd


# ═══════════════════════════════════════════════════════════════════════════
# 任务 4：风应力旋度 + 流函数（ψ）海盆求解器
# ═══════════════════════════════════════════════════════════════════════════
#
# 物理模型（β-plane Stommel 简化）：
#   风应力 τ(cell) = wind_speed² × wind_vector             # 量级 ~ |v|², 方向同风向
#   旋度   ω(cell) = (curl τ)_z = ∂τ_y/∂x - ∂τ_x/∂y
#   ψ 满足  ∇²ψ + R · ∂ψ/∂x = -ω / β                       # Stommel 简化
#     边界  ψ|land = 0
#
# 求解：SOR 迭代（带松弛因子 ω_sor ∈ [1.0, 1.5]）。每次更新规则：
#   对水域 cell：
#     avg_nb_psi = (1/N) * Σ ψ_nb               # N = 邻居 cell 数（陆地邻居用 0）
#     adv_term   = R_lat * (ψ_E - ψ_W) / 2      # 西边界强化的非对称项
#     target     = avg_nb_psi - adv_term + h² * source(cell) / β
#     ψ_new      = (1 - ω_sor) * ψ_old + ω_sor * target
#
# 西边界强化原理：Stommel 模型证明在 ∇²ψ + R*∂ψ/∂x = source 中，
#   - 西岸 (∂ψ/∂x 由海岸带向洋盆) 等高线密集 → 流速大
#   - 东岸等高线稀疏 → 流速小
#   现实对应：黑潮、湾流（西岸暖流强）；加州、秘鲁（东岸冷流弱）。
#
# 半球极性：β = df/dy（科氏参数随纬度变化），北半球 β > 0、南半球 β < 0。
# 但 Stommel R 的符号在两个半球都为正——西岸都强，与现实一致。
# 我们直接用 |β| 替代真实的有符号 β，然后让 source 自带半球符号。
#
# 性能：
#   - 状态封装在 PsiSolverState（轻量 RefCounted），可以由 MapBaker / OceanCurrentsJob
#     在多个 slice 里复用、跨 slice 累加迭代次数。
#   - 一次完整求解通常 30~80 次 SOR 即可稳态收敛。
#   - 单次迭代 O(N_water_hex × 6)，常规图 ~5000 水格 × 6 = 30k 浮点操作 → < 1ms。

const _PSI_SOR_OMEGA := 1.4            # SOR 松弛因子（1.0 = Gauss-Seidel）
const _PSI_R_BASE := 0.18              # Stommel 西边界强化系数基准
const _PSI_BETA_FLOOR := 0.05          # |β| 下限（赤道附近避免除零放大）
const _PSI_SOURCE_SCALE := 0.08        # 源项整体缩放
const _PSI_DEFAULT_ITERS := 40         # 默认 step 次数（一次性求解时）
# 调优记录：60 次 SOR 残差 ≈1%，40 次 ≈3%，30 次 ≈7%。
# 抑制到 40 次让一次性求解从 ~30ms 降到 ~20ms，玩家不可见。

## PsiSolverState —— ψ 求解器跨 slice 的可重入状态。
##
## 字段：
##   water_cells : Array[HexCell]            水域 cell 列表（顺序固定，作为 idx）
##   water_idx   : Dictionary HexCell→int    水域 cell → 索引（用于邻居查找）
##   psi         : PackedFloat32Array        当前 ψ 值（与 water_cells 同序）
##   source      : PackedFloat32Array        源项缓存 = -curl(τ) / |β|（一次写入，迭代复用）
##   nb_idx      : PackedInt32Array          邻居索引（N_water × 6，-1 = 陆地或地图外）
##   r_factor    : PackedFloat32Array        每个水格的 R（西边界强化系数，~lat 依赖）
##   beta_abs    : PackedFloat32Array        每个水格的 |β|
##   total_iters : int                       已迭代次数（diagnostic 用）
class PsiSolverState extends RefCounted:
	var water_cells: Array = []
	var water_idx: Dictionary = {}
	var psi: PackedFloat32Array = PackedFloat32Array()
	var source: PackedFloat32Array = PackedFloat32Array()
	var nb_idx: PackedInt32Array = PackedInt32Array()
	var r_factor: PackedFloat32Array = PackedFloat32Array()
	var beta_abs: PackedFloat32Array = PackedFloat32Array()
	var total_iters: int = 0

	func size() -> int:
		return water_cells.size()

## init_psi_solver —— 构建 ψ 求解器状态：识别水域 cell、预算 source、邻居索引。
##
## 前置条件：cell.wind_vector / cell.wind_speed 已由 solve_wind_field 写入。
##
## 副作用：把 cell.wind_stress_curl 写入水域 cell（陆地保持 0）。
static func init_psi_solver(map: MapData, hex_size: float, world_bounds: Rect2) -> PsiSolverState:
	var st := PsiSolverState.new()
	if map == null:
		return st
	var cells: Array = map.all_cells()

	# Pass 1：列出水域 cell
	for cell: HexCell in cells:
		if cell == null:
			continue
		if _is_water_terrain(int(cell.terrain)):
			st.water_idx[cell] = st.water_cells.size()
			st.water_cells.append(cell)
		else:
			# 陆地清零，保持边界条件 ψ=0 的语义连续
			cell.wind_stress_curl = 0.0
			cell.ocean_psi = 0.0
	var n: int = st.water_cells.size()
	if n == 0:
		return st
	st.psi.resize(n)
	st.source.resize(n)
	st.nb_idx.resize(n * 6)
	st.r_factor.resize(n)
	st.beta_abs.resize(n)

	# Pass 2：邻居索引、风应力旋度、Stommel R / β
	# 风应力 τ = wind_speed² × wind_vector
	# 用与 SLP 相同的"6 邻域离散梯度"思路计算 curl τ：
	#   curl_z(τ) ≈ (1/3) * Σ_i (τ_nb_i - τ_self) × d_i_unit （取 z 分量）
	#   z 分量 = a.x*b.y - a.y*b.x
	# 把陆地邻居的 τ 视为 0（无风应力穿透）。
	for k in range(n):
		var c: HexCell = st.water_cells[k]
		var tau_self: Vector2 = (c.wind_speed * c.wind_speed) * c.wind_vector
		var curl_sum: float = 0.0
		var base_idx: int = k * 6
		for d in range(6):
			var dv: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[d]
			var nb_cube := Vector3i(c.q + dv.x, c.r + dv.y, c.s + dv.z)
			var nb: HexCell = map.get_cell_by_cube(nb_cube)
			var nb_idx_val: int = -1
			var tau_nb: Vector2 = Vector2.ZERO
			if nb != null and _is_water_terrain(int(nb.terrain)):
				nb_idx_val = int(st.water_idx.get(nb, -1))
				tau_nb = (nb.wind_speed * nb.wind_speed) * nb.wind_vector
			st.nb_idx[base_idx + d] = nb_idx_val
			# (τ_nb - τ_self) × d_unit 的 z 分量 = a.x*b.y - a.y*b.x
			var dtau: Vector2 = tau_nb - tau_self
			var d_unit: Vector2 = NEIGHBOR_DIRS[d]
			curl_sum += dtau.x * d_unit.y - dtau.y * d_unit.x
		# 规范化：六边形 6 邻域差分 → 1/3 系数
		var curl_val: float = curl_sum / 3.0
		c.wind_stress_curl = curl_val

		# β 与 R：依赖 lat_signed
		var ny: float = _ny_for_cell(c, hex_size, world_bounds)
		var ls: float = _lat_signed_for(ny)
		var ls_abs: float = absf(ls)
		# β-plane 简化：|β| ≈ cos(lat)，赤道最大、极地最小。底数防除零。
		var beta_a: float = max(_PSI_BETA_FLOOR, cos(ls_abs * PI * 0.5))
		st.beta_abs[k] = beta_a
		# R 在中纬偏强，赤道与极地稍弱
		st.r_factor[k] = _PSI_R_BASE * (0.5 + sin(ls_abs * PI))

		# source = -curl(τ) / |β|（hex_size² 项与系数一并并入 _PSI_SOURCE_SCALE）
		st.source[k] = -curl_val / beta_a * _PSI_SOURCE_SCALE
		st.psi[k] = 0.0
	return st

## step_psi_solver —— 推进 SOR 迭代 n_iters 次。
##
## 返回：本次迭代结束时的最大 |Δψ|（残差 proxy）。
##
## 注意：内部直接读写 state.psi；调用方负责把它分摊到多个 slice。
## 使用 Gauss-Seidel 顺序更新（in-place），SOR 松弛系数 = _PSI_SOR_OMEGA。
static func step_psi_solver(state: PsiSolverState, n_iters: int = _PSI_DEFAULT_ITERS) -> float:
	if state == null or state.size() == 0:
		return 0.0
	var n: int = state.size()
	var max_delta: float = 0.0
	for it in range(n_iters):
		max_delta = 0.0
		for k in range(n):
			var base_i: int = k * 6
			# 邻居 ψ 累加（陆地邻居 ψ = 0，因为 nb_idx = -1）
			var sum_psi: float = 0.0
			# 用于西边界强化项：东向（dir 0）和西向（dir 3）邻居 ψ
			var psi_e: float = 0.0
			var psi_w: float = 0.0
			for d in range(6):
				var ni: int = state.nb_idx[base_i + d]
				var psi_nb: float = state.psi[ni] if ni >= 0 else 0.0
				sum_psi += psi_nb
				if d == 0:
					psi_e = psi_nb
				elif d == 3:
					psi_w = psi_nb
			var avg_nb: float = sum_psi / 6.0
			var adv_term: float = state.r_factor[k] * (psi_e - psi_w) * 0.5
			var target: float = avg_nb - adv_term + state.source[k]
			var old_v: float = state.psi[k]
			var new_v: float = (1.0 - _PSI_SOR_OMEGA) * old_v + _PSI_SOR_OMEGA * target
			state.psi[k] = new_v
			var delta: float = absf(new_v - old_v)
			if delta > max_delta:
				max_delta = delta
		state.total_iters += 1
	return max_delta

## solve_psi_one_shot —— 一次性把 ψ 解到稳态（一次性求解路径，非切片化）。
##
## 内部：init → step _PSI_DEFAULT_ITERS 次 → 返回 state（caller 负责 commit_psi）。
static func solve_psi_one_shot(map: MapData, hex_size: float, world_bounds: Rect2) -> PsiSolverState:
	var st := init_psi_solver(map, hex_size, world_bounds)
	step_psi_solver(st, _PSI_DEFAULT_ITERS)
	return st

## commit_psi_to_cells —— 把 state.psi 写回 cell.ocean_psi。
##
## 仅在迭代收敛后（或 slice 收尾）调用一次。
static func commit_psi_to_cells(state: PsiSolverState) -> void:
	if state == null:
		return
	for k in range(state.size()):
		var c: HexCell = state.water_cells[k]
		if c != null:
			c.ocean_psi = state.psi[k]


# ═══════════════════════════════════════════════════════════════════════════
# 任务 5：ψ → hex 流速 + 副极地 / 高纬热盐叠加
# ═══════════════════════════════════════════════════════════════════════════
#
# 物理：
#   u = -∂ψ/∂y,  v = +∂ψ/∂x        # 流函数定义（屏幕坐标系下 +y=南）
#   等价于：ocean_current = rotate90_ccw(∇ψ)
#
# 6 邻域离散梯度（与前面 SLP/curl 算子同源）：
#   ∇ψ(cell) ≈ (1/3) * Σ_i (ψ_nb_i - ψ_self) * d_i_unit
#
# 副极地 / 高纬热盐叠加（保留旧语义、降权）：
#   高纬冷沉点（|lat_signed| > _UPWELLING_HIGHLAT_ABS 且 lat_temp 较低）
#   会在 y 方向（朝极方向 = sign(lat_signed)，屏幕 +y=南）叠加一个小幅修正，
#   权重 ≤ 0.2，避免改造前的"极地大尺度向极冷流"语义彻底消失。
#
# 数值缩放：ψ 的量级取决于 source 与 R/β，迭代后 |ψ| 通常落在 [0, 数十] 范围。
# ocean_current 期望幅度 ~ [0, 1]（与现有 RG8 编码 [-1, 1] 兼容）。
# 这里用 _OCEAN_CURRENT_SCALE 经验缩放，再 clamp。

const _UPWELLING_HIGHLAT_ABS_SOLVER := 0.75 	# 冷沉仅限极圈内(|lat|>67.5°)
const _OCEAN_CURRENT_SCALE := 0.30      # ψ 梯度 → ocean_current 量级缩放，目标把全球 ocean_mag 拉回 0.18~0.35。
const _THERMOHALINE_WEIGHT := 0.25      # 高纬热盐 y 修正权重，补足弱风应力下的高纬密度流。

static func _limit_ocean_current(cur: Vector2, max_mag: float) -> Vector2:
	var limit: float = clampf(max_mag, 0.01, 1.4142136)
	var len_sq: float = cur.length_squared()
	if len_sq > limit * limit:
		cur *= limit / sqrt(len_sq)
	cur.x = clampf(cur.x, -1.0, 1.0)
	cur.y = clampf(cur.y, -1.0, 1.0)
	return cur

## psi_to_ocean_current —— 把 ψ 场转为 cell.ocean_current。
##
## 同时叠加副极地 / 高纬冷沉的 thermohaline 小幅修正，保留旧语义。
##
## 入参：
##   state         —— init_psi_solver / step_psi_solver 后的状态
##   map           —— 用于查邻居（state.water_cells / nb_idx 已带索引，但要查
##                    实际邻居 cell 的 ψ 时复用 state.psi 即可，不需要 map；
##                    map 仅保留接口对称性 + 未来扩展）
##   hex_size      —— 用于推 ny
##   world_bounds  —— 用于推 ny
##   cfg           —— MapConfig，可选（提供 COLD_SINK_TEMP）
static func psi_to_ocean_current(state: PsiSolverState, map: MapData, hex_size: float, \
		world_bounds: Rect2, cfg: MapConfig = null, profile: ClimateProfile = null) -> void:
	if state == null or state.size() == 0:
		return
	var n: int = state.size()
	var cold_sink_temp: float = cfg.COLD_SINK_TEMP if cfg != null else -0.05
	var response_rate: float = clampf(profile.ocean_current_response_rate if profile != null else 1.0, 0.0, 1.0)
	var thermal_weight: float = profile.ocean_thermal_current_weight if profile != null else _THERMOHALINE_WEIGHT
	var density_cold_weight: float = profile.ocean_density_cold_weight if profile != null else 0.35
	var density_ice_weight: float = profile.ocean_density_ice_weight if profile != null else 0.20
	var current_scale: float = clampf(profile.ocean_current_scale if profile != null and profile.get("ocean_current_scale") != null else _OCEAN_CURRENT_SCALE, 0.0, 2.0)
	var current_max_mag: float = clampf(profile.ocean_current_max_magnitude if profile != null and profile.get("ocean_current_max_magnitude") != null else 0.50, 0.01, 1.4142136)

	var ocx_arr: PackedFloat32Array = map.ocean_current_x_arr
	var ocy_arr: PackedFloat32Array = map.ocean_current_y_arr
	# SoA 写路径要求：索引已 build（cell.index >= 0）+ 两个数组都已按 soa_size 预分配。
	# bake 初始烤制阶段 _build_indices 尚未跑（在 MapGenerator.generate 末尾才调用），
	# 此时 soa_size()=0 但 cell.index=-1，必须 fallback 到 cell.ocean_current 写路径，
	# 否则 ocx_arr[-1] 会越界（issue: psi_to_ocean_current OOB at index -1）。
	var soa_ok: bool = map.has_indices() \
			and ocx_arr.size() >= map.soa_size() \
			and ocy_arr.size() >= map.soa_size() \
			and map.soa_size() > 0

	for land_cell: HexCell in map.all_cells():
		if land_cell == null or _is_water_terrain(int(land_cell.terrain)):
			continue
		land_cell.ocean_current = Vector2.ZERO
		var land_idx: int = _cell_idx(map, land_cell)
		if land_idx >= 0 and soa_ok:
			ocx_arr[land_idx] = 0.0
			ocy_arr[land_idx] = 0.0

	for k in range(n):
		var c: HexCell = state.water_cells[k]
		if c == null:
			continue
		var psi_self: float = state.psi[k]
		var grad_psi: Vector2 = Vector2.ZERO
		var base_i: int = k * 6
		for d in range(6):
			var ni: int = state.nb_idx[base_i + d]
			var psi_nb: float = state.psi[ni] if ni >= 0 else 0.0  # 陆地 ψ=0 边界
			grad_psi += (psi_nb - psi_self) * NEIGHBOR_DIRS[d]
		grad_psi /= 3.0   # 与 SLP / curl 一致的六邻域规范化系数

		# 旋转 90° 逆时针：(x, y) → (-y, x) 等价于 (u, v) = (-∂ψ/∂y, ∂ψ/∂x)
		var target_cur: Vector2 = Vector2(-grad_psi.y, grad_psi.x) * current_scale

		var density_self: float = _density_proxy(map, c, density_cold_weight, density_ice_weight)
		var grad_density: Vector2 = Vector2.ZERO
		for d_den in range(6):
			var dv_den: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[d_den]
			var nb_den: HexCell = map.get_cell_by_cube(Vector3i(c.q + dv_den.x, c.r + dv_den.y, c.s + dv_den.z))
			if nb_den == null or not _is_water_terrain(int(nb_den.terrain)):
				continue
			var density_nb: float = _density_proxy(map, nb_den, density_cold_weight, density_ice_weight)
			grad_density += (density_nb - density_self) * NEIGHBOR_DIRS[d_den]
		grad_density /= 3.0
		var thermal_cur: Vector2 = -grad_density * thermal_weight
		target_cur += thermal_cur

		# 副极地 / 高纬热盐叠加（保留旧"高纬向极冷流"语义）
		var ny: float = _ny_for_cell(c, hex_size, world_bounds)
		var ls: float = _lat_signed_for(ny)
		var ls_abs: float = absf(ls)
		var lat_temp: float = _lat_temp_for(ls_abs)
		var temp_rel: float = lat_temp - 0.5
		if ls_abs > _UPWELLING_HIGHLAT_ABS_SOLVER and temp_rel < cold_sink_temp:
			var pole_dir_y: float = signf(ls)         # 北半球 ls<0 → -1 = 向北/向极
			var grad_mag: float = sin(ls_abs * PI)
			target_cur.y += pole_dir_y * grad_mag * thermal_weight

		var old_cur: Vector2 = c.ocean_current
		var idx_cur: int = _cell_idx(map, c)
		if idx_cur >= 0 and soa_ok:
			old_cur = Vector2(ocx_arr[idx_cur], ocy_arr[idx_cur])
		var cur: Vector2 = old_cur.lerp(target_cur, response_rate)

		cur = _limit_ocean_current(cur, current_max_mag)
		c.ocean_current = cur
		if idx_cur >= 0 and soa_ok:
			ocx_arr[idx_cur] = cur.x
			ocy_arr[idx_cur] = cur.y

## solve_ocean_current_fallback —— 当 enable_ocean_heat_transport = false 时使用。
##
## 跳过 ψ 求解，直接把每个水域 cell 的 ocean_current 用风向 + Ekman ±45° + 高纬热盐
## 写出（与旧像素路径同语义，只是落到 hex 域）。
##
## 注意：此路径不写 cell.wind_stress_curl / cell.ocean_psi，下游 overlay 看不到。
const _EKMAN_DEFLECTION_RAD := PI * 0.25  # ±45°

static func solve_ocean_current_fallback(map: MapData, hex_size: float, \
		world_bounds: Rect2, cfg: MapConfig = null, profile: ClimateProfile = null) -> void:
	if map == null:
		return
	var cold_sink_temp: float = cfg.COLD_SINK_TEMP if cfg != null else -0.05
	var current_max_mag: float = clampf(profile.ocean_current_max_magnitude if profile != null and profile.get("ocean_current_max_magnitude") != null else 0.50, 0.01, 1.4142136)
	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		if not _is_water_terrain(int(cell.terrain)):
			cell.wind_stress_curl = 0.0
			cell.ocean_psi = 0.0
			continue
		var ny: float = _ny_for_cell(cell, hex_size, world_bounds)
		var ls: float = _lat_signed_for(ny)
		var ls_abs: float = absf(ls)
		var ekman_sign: float = -1.0 if ls < 0.0 else 1.0  # 北半球 -45°，南半球 +45°
		var rot: float = ekman_sign * _EKMAN_DEFLECTION_RAD
		var w: Vector2 = cell.wind_vector * cell.wind_speed
		var cos_r: float = cos(rot)
		var sin_r: float = sin(rot)
		var cur := Vector2(
			w.x * cos_r - w.y * sin_r,
			w.x * sin_r + w.y * cos_r
		)
		# 高纬热盐
		var lat_temp: float = _lat_temp_for(ls_abs)
		var temp_rel: float = lat_temp - 0.5
		if ls_abs > _UPWELLING_HIGHLAT_ABS_SOLVER and temp_rel < cold_sink_temp:
			var pole_dir_y: float = signf(ls)
			var grad_mag: float = sin(ls_abs * PI)
			cur.y += pole_dir_y * grad_mag * _THERMOHALINE_WEIGHT
		cur = _limit_ocean_current(cur, current_max_mag)
		cell.ocean_current = cur
		cell.wind_stress_curl = 0.0
		cell.ocean_psi = 0.0


# ═══════════════════════════════════════════════════════════════════════════
# 任务 6：沿岸 Ekman 上升流（hex 域）
# ═══════════════════════════════════════════════════════════════════════════
#
# 物理：
#   coast_tangent ≈ rotate90_ccw( -Σ_dir(land_neighbor)_unit )
#   ekman_pump  = dot(wind_dir, coast_tangent) × hemi_sign × wind_speed
#     正值 = 上升流（沿岸 Ekman 抽吸 → 富营养、冷水涌升）
#     负值 = 下沉流
#   半球符号 hemi_sign：北半球（ls<0）+1；南半球（ls>0）-1。
#     现实里：北半球加州沿岸（西海岸朝东陆地）夏季北风 → 上升流；
#     北半球东海岸朝西陆地夏季南风 → 下沉。
#
#   hi_lat 冷沉叠加：保留旧 _UPWELLING_HIGHLAT_ABS / cold_sink_temp 阈值
#     的"高纬冷水下沉"语义，作为 Ekman 抽吸结果之上的负向修正。
#
# 写入：cell.upwelling_strength ∈ [-1, 1]。陆地维持 0。
#
# Ekman 主项的标定：dot 已在 [-1,1]，乘以 wind_speed（典型 [0.1, 1.7]），
# 用 _UPWELLING_EKMAN_GAIN 缩放。

const _UPWELLING_EKMAN_GAIN := 0.6     # Ekman 主项整体缩放
const _UPWELLING_COLD_SINK_GAIN := 0.15 # 高纬冷沉叠加的负向幅度（原 0.5 压制了所有上升流）

## solve_upwelling —— hex 域沿岸 Ekman 上升流求解。
##
## 前置条件：cell.wind_vector / cell.wind_speed 已由 solve_wind_field 写入。
##
## 入参：cfg 可选，提供 COLD_SINK_TEMP（默认 -0.05）。
##
## 输出：cell.upwelling_strength ∈ [-1, 1]，陆地清零。
static func solve_upwelling(map: MapData, hex_size: float, world_bounds: Rect2, \
		cfg: MapConfig = null) -> void:
	if map == null:
		return
	var cold_sink_temp: float = cfg.COLD_SINK_TEMP if cfg != null else -0.05
	for cell: HexCell in map.all_cells():
		if cell == null:
			continue
		if not _is_water_terrain(int(cell.terrain)):
			cell.upwelling_strength = 0.0
			continue
		var ny: float = _ny_for_cell(cell, hex_size, world_bounds)
		var ls: float = _lat_signed_for(ny)
		var ls_abs: float = absf(ls)
		var lat_temp: float = _lat_temp_for(ls_abs)
		var temp_rel: float = lat_temp - 0.5

		# (a) 沿岸 Ekman 主项：检查是否海岸（任一陆地邻居）
		var land_dir_sum: Vector2 = Vector2.ZERO
		var has_land_nb: bool = false
		var nbs: Array = map.get_neighbors(cell)
		for nb: HexCell in nbs:
			if nb == null:
				continue
			if not _is_water_terrain(int(nb.terrain)):
				var dq: int = nb.q - cell.q
				var dr: int = nb.r - cell.r
				for i in range(6):
					var d: Vector3i = HexUtilsScript.CUBE_DIRECTIONS[i]
					if d.x == dq and d.y == dr:
						land_dir_sum += NEIGHBOR_DIRS[i]
						break
				has_land_nb = true

		var ekman_main: float = 0.0
		if has_land_nb and land_dir_sum.length_squared() > 0.0001:
			# coast_tangent = rotate90_ccw(-land_dir_sum)
			# 屏幕坐标系下 90° 逆时针：(x, y) → (-y, x)
			# -land_dir_sum 指向"远离陆地"（即指向开放海洋）
			# 取它的 90°ccw 作为切向（沿海岸"右手在陆"方向）
			var off_shore: Vector2 = -land_dir_sum.normalized()
			var coast_tan: Vector2 = Vector2(-off_shore.y, off_shore.x)
			# 北半球 (ls<0) hemi_sign = +1：上升流出现在风沿 +coast_tan 方向时
			var hemi_sign: float = 1.0 if ls < 0.0 else -1.0
			var dot_v: float = cell.wind_vector.dot(coast_tan)
			ekman_main = dot_v * hemi_sign * cell.wind_speed * _UPWELLING_EKMAN_GAIN

		# (b) 高纬冷沉叠加（保留旧语义，作为负向修正）
		var cold_sink_neg: float = 0.0
		if ls_abs > _UPWELLING_HIGHLAT_ABS_SOLVER and temp_rel < cold_sink_temp:
			# 冷沉强度：温度越低、纬度越高，越强
			var t_cold: float = clampf((cold_sink_temp - temp_rel) / 0.3, 0.0, 1.0)
			cold_sink_neg = -t_cold * _UPWELLING_COLD_SINK_GAIN

		var up: float = ekman_main + cold_sink_neg
		cell.upwelling_strength = clampf(up, -1.0, 1.0)
