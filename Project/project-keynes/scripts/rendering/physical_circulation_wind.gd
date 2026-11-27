extends RefCounted

const WindBeltScript = preload("res://scripts/weather/wind_belt.gd")


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
	var coast_sea_anchor: Dictionary = {} # HexCell → 最近海洋锚点（热力季风 fallback）
	var bfs_queue: Array = []
	for cell0: HexCell in cells:
		if cell0 == null:
			continue
		if PhysicalCirculationSolver._is_water_terrain(int(cell0.terrain)):
			continue
		# 沿海陆地（任一邻居是水）：距离 = 0，朝海方向 = 指向水邻居的合成单位向量
		var sea_v0: Vector2 = Vector2.ZERO
		var sea_anchor0: HexCell = null
		for nb0: HexCell in map.get_neighbors(cell0):
			if nb0 == null:
				continue
			if not PhysicalCirculationSolver._is_water_terrain(int(nb0.terrain)):
				continue
			var i0 := PhysicalCirculationSolver._neighbor_dir_index(map, cell0, nb0)
			if i0 >= 0:
				sea_v0 += PhysicalCirculationSolver.NEIGHBOR_DIRS[i0]
				if sea_anchor0 == null or PhysicalCirculationSolver._cell_idx(map, nb0) < PhysicalCirculationSolver._cell_idx(map, sea_anchor0):
					sea_anchor0 = nb0
		if sea_v0.length_squared() > 0.0001:
			coast_dist[cell0] = 0
			coast_sea[cell0] = sea_v0.normalized()
			coast_sea_anchor[cell0] = sea_anchor0
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
		var cur_sea_anchor: HexCell = coast_sea_anchor.get(cur, null)
		for nb_b: HexCell in map.get_neighbors(cur):
			if nb_b == null:
				continue
			if PhysicalCirculationSolver._is_water_terrain(int(nb_b.terrain)):
				continue
			if coast_dist.has(nb_b):
				continue
			coast_dist[nb_b] = cur_d + 1
			coast_sea[nb_b] = cur_sea
			coast_sea_anchor[nb_b] = cur_sea_anchor
			bfs_queue.append(nb_b)

	# Pass 0b：海洋侧 BFS — sea_dist(海洋 cell 距最近陆地格数) + sea_land(朝陆单位向量)。
	# 用于海洋侧几何海风(朝陆)，与陆地侧拼成海陆连续 onshore，修复"海洋水汽补不进沿海"断链。
	var sea_dist: Dictionary = {}       # HexCell → int（0 = 紧邻陆地的海洋）
	var sea_land: Dictionary = {}       # HexCell → Vector2（朝陆单位向量，从沿岸继承；镜像 C++ sea_land_x/y）
	var sea_land_anchor: Dictionary = {} # HexCell → 最近陆地锚点（热力季风 fallback）
	var sea_queue: Array = []
	for cellS: HexCell in cells:
		if cellS == null:
			continue
		if not PhysicalCirculationSolver._is_water_terrain(int(cellS.terrain)):
			continue
		# 沿岸海洋（任一邻居是陆地）：sea_dist = 0，朝陆方向 = 指向陆地邻居的合成单位向量
		var land_vS: Vector2 = Vector2.ZERO
		var land_anchor_s: HexCell = null
		for nbS: HexCell in map.get_neighbors(cellS):
			if nbS == null:
				continue
			if PhysicalCirculationSolver._is_water_terrain(int(nbS.terrain)):
				continue
			var iS := PhysicalCirculationSolver._neighbor_dir_index(map, cellS, nbS)
			if iS >= 0:
				land_vS += PhysicalCirculationSolver.NEIGHBOR_DIRS[iS]
				if land_anchor_s == null or PhysicalCirculationSolver._cell_idx(map, nbS) < PhysicalCirculationSolver._cell_idx(map, land_anchor_s):
					land_anchor_s = nbS
		if land_vS.length_squared() > 0.0001:
			sea_dist[cellS] = 0
			sea_land[cellS] = land_vS.normalized()
			sea_land_anchor[cellS] = land_anchor_s
			sea_queue.append(cellS)
	var sea_head: int = 0
	while sea_head < sea_queue.size():
		var curS: HexCell = sea_queue[sea_head]
		sea_head += 1
		var cur_dS: int = int(sea_dist[curS])
		if cur_dS >= _SEA_BREEZE_SEA_MAX_DIST:
			continue
		var cur_landS: Vector2 = sea_land[curS]
		var cur_land_anchor: HexCell = sea_land_anchor.get(curS, null)
		for nb_s: HexCell in map.get_neighbors(curS):
			if nb_s == null:
				continue
			if not PhysicalCirculationSolver._is_water_terrain(int(nb_s.terrain)):
				continue
			if sea_dist.has(nb_s):
				continue
			sea_dist[nb_s] = cur_dS + 1
			sea_land[nb_s] = cur_landS
			sea_land_anchor[nb_s] = cur_land_anchor
			sea_queue.append(nb_s)

	# ─── NS 化 Phase 1 结构镜像(近似级 stale-DLL fallback,不要求逐位)───────
	# SAME_SOURCE 数学定义:C++ gdext/src/world_ext_physical.cpp::run_wind_field_pass
	# 动量段。transp = 旧动量 + 自平流增量(轨迹三点插值) + 扩散增量(6 邻居 Laplacian);
	# final = transp.lerp(target, r)。本镜像缺 synoptic/移动低压本就近似,轨迹表按
	# 调用内即时构建(无 C++ 成员缓存),knob 默认 0 → 旧行为逐位不变。
	var momentum_advect_w: float = clampf(
		float(profile.get("wind_momentum_advect_w")) if profile != null and profile.get("wind_momentum_advect_w") != null else 0.0,
		0.0, 0.5)
	var momentum_diffuse_w_daily: float = clampf(
		float(profile.get("wind_momentum_diffuse_w_daily")) if profile != null and profile.get("wind_momentum_diffuse_w_daily") != null else 0.0,
		0.0, 0.5)
	var momentum_active: bool = (momentum_advect_w > 0.0 or momentum_diffuse_w_daily > 0.0)
	var snap_flux: Array = []          # idx → Vector2 旧通量快照(并行/乱序安全的前提)
	var traj_rows: Array = []          # idx → {i0,i1,i2,w0,w1,w2}(仅 advect>0 时构建)
	var diffuse_w: float = 0.0
	if momentum_active:
		var n_cells_m: int = cells.size()
		snap_flux.resize(n_cells_m)
		traj_rows.resize(n_cells_m)
		var grid_s: float = sqrt(float(n_cells_m) / 15000.0)
		if momentum_diffuse_w_daily > 0.0:
			# fallback 路径无 wind_elapsed_days 语义(C++ 按真实间隔换算),按 dt=1 近似。
			diffuse_w = minf(momentum_diffuse_w_daily * grid_s * grid_s, 0.5)
		var cell_pos_m := PackedVector2Array()
		cell_pos_m.resize(n_cells_m)
		for cell_m: HexCell in cells:
			var idx_m: int = PhysicalCirculationSolver._cell_idx(map, cell_m)
			if idx_m < 0:
				continue
			var f := Vector2.ZERO
			if cell_m.wind_vector.length_squared() > 0.0001 and cell_m.wind_speed > 0.0001:
				f = cell_m.wind_vector.normalized() * cell_m.wind_speed
			snap_flux[idx_m] = f
			cell_pos_m[idx_m] = Vector2(
				map.cell_pos_x_arr[idx_m] if map.cell_pos_x_arr.size() > idx_m else 0.0,
				map.cell_pos_y_arr[idx_m] if map.cell_pos_y_arr.size() > idx_m else 0.0)
		if momentum_advect_w > 0.0:
			var nb_idx_m: PackedInt32Array = map.neighbor_indices_packed()
			var wrap_m: float = HexUtils.wrap_period_cell_pos_x(map.width)
			var traj_scale: float = clampf(
				float(profile.get("wind_traj_pos_scale")) if profile != null and profile.get("wind_traj_pos_scale") != null else 0.65,
				0.0, 4.0)
			var traj_dt: float = clampf(
				float(profile.get("wind_traj_dt_days")) if profile != null and profile.get("wind_traj_dt_days") != null else 10.0,
				0.25, 60.0)
			var step_len: float = traj_scale * grid_s * traj_dt
			for cell_t: HexCell in cells:
				var idx_t: int = PhysicalCirculationSolver._cell_idx(map, cell_t)
				if idx_t < 0:
					continue
				var flux_t: Vector2 = snap_flux[idx_t]
				var sp_t: float = flux_t.length()
				if sp_t < 0.000001 or step_len <= 0.0:
					traj_rows[idx_t] = {"i0": idx_t, "i1": idx_t, "i2": idx_t, "w0": 1.0, "w1": 0.0, "w2": 0.0}
					continue
				var dist_t: float = minf(sp_t * step_len, 12.0)
				var target_t: Vector2 = cell_pos_m[idx_t] - flux_t.normalized() * dist_t
				# walk:推进宿主到终点所在 cell(≤12 跳,与 C++ 构建器同策略)
				var cur_t: int = idx_t
				for _hop in range(12):
					var delta_t: Vector2 = target_t - cell_pos_m[cur_t]
					if wrap_m > 0.001:
						var half_m: float = wrap_m * 0.5
						if delta_t.x > half_m:
							delta_t.x -= wrap_m
						elif delta_t.x < -half_m:
							delta_t.x += wrap_m
					if delta_t.length_squared() <= 0.75:
						break
					var best_t: int = -1
					var best_dot_t: float = 0.5
					var base_t: int = cur_t * 6
					for d_t in range(6):
						var ni_t: int = nb_idx_m[base_t + d_t]
						if ni_t < 0:
							continue
						var nd_t: Vector2 = cell_pos_m[ni_t] - cell_pos_m[cur_t]
						if wrap_m > 0.001:
							var half_n: float = wrap_m * 0.5
							if nd_t.x > half_n:
								nd_t.x -= wrap_m
							elif nd_t.x < -half_n:
								nd_t.x += wrap_m
						if nd_t.length_squared() < 0.000001:
							continue
						var dot_t: float = nd_t.normalized().dot(delta_t.normalized())
						if dot_t > best_dot_t:
							best_dot_t = dot_t
							best_t = ni_t
					if best_t < 0:
						break
					cur_t = best_t
				traj_rows[idx_t] = DCWeatherFieldSolver.hex_sextant_barycentric(
					cur_t, target_t, cell_pos_m, nb_idx_m, wrap_m)

	var thermal_monsoon_enabled: bool = profile != null and profile.thermal_monsoon_enabled
	var monsoon_lat_limit: float = clampf(profile.thermal_monsoon_lat_limit if profile != null else 0.45, 0.0, 1.0)
	var monsoon_deadband: float = clampf(profile.thermal_monsoon_deadband if profile != null else 0.015, 0.0, 0.10)
	var monsoon_full: float = maxf(monsoon_deadband + 0.001, profile.thermal_monsoon_full_contrast if profile != null else 0.08)
	var monsoon_gain: float = clampf(profile.thermal_monsoon_gain if profile != null else 0.85, 0.0, 1.5)
	var monsoon_floor: float = clampf(profile.thermal_monsoon_breeze_floor if profile != null else 0.20, 0.0, 0.5)
	for cell: HexCell in cells:
		if cell == null:
			continue
		var ny: float = PhysicalCirculationSolver._ny_for_cell(cell, hex_size, world_bounds, map.height if map != null else 0)
		var ls: float = PhysicalCirculationSolver._lat_signed_for(ny)
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
			var dir_idx := PhysicalCirculationSolver._neighbor_dir_index(map, cell, nb)
			if dir_idx < 0:
				continue
			var d_unit: Vector2 = PhysicalCirculationSolver.NEIGHBOR_DIRS[dir_idx]
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
		# 屏幕坐标 x=东、y=南（北在 y<0），故 R(+θ) 把东转向南 = 地图上顺时针 = 右偏。
		# 北半球（ls < 0）右偏取 +|θ|；南半球左偏取 -|θ|。
		var coriolis_angle: float = _WIND_CORIOLIS_MAX_RAD * pow(ls_abs, 0.55)
		var rot: float = coriolis_angle * (1.0 if ls < 0.0 else -1.0)
		var cos_r: float = cos(rot)
		var sin_r: float = sin(rot)
		var v_grad: Vector2 = Vector2(
			v_grad_raw.x * cos_r - v_grad_raw.y * sin_r,
			v_grad_raw.x * sin_r + v_grad_raw.y * cos_r
		)
		var ageo_w: float = 1.0 - smoothstep(0.10, 0.55, ls_abs)
		v_grad = v_grad_raw * ageo_w + v_grad * (1.0 - ageo_w)
		if v_grad.length_squared() > 0.0001:
			v_grad = v_grad.normalized()

		# (c) 沿海热力环流权重：方向由 SLP 梯度决定，不再由季节符号指定。
		var is_water: bool = PhysicalCirculationSolver._is_water_terrain(int(cell.terrain))
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
		var monsoon_thermal: float = 0.0
		if thermal_monsoon_enabled and ls_abs <= monsoon_lat_limit:
			var anchor: HexCell = sea_land_anchor.get(cell, null) if is_water else coast_sea_anchor.get(cell, null)
			if anchor != null:
				var land_minus_sea: float = anchor.temperature - cell.temperature if is_water else cell.temperature - anchor.temperature
				if absf(land_minus_sea) > monsoon_deadband:
					monsoon_thermal = signf(land_minus_sea) * smoothstep(monsoon_deadband, monsoon_full, absf(land_minus_sea))
		var breeze_sign: float = clampf(monsoon_floor + monsoon_gain * monsoon_thermal, -0.65, 1.05) \
				if thermal_monsoon_enabled else 1.0
		if not is_water and coast_pressure_w > 0.0 and coast_sea.has(cell):
			v_sum += (_WIND_SEA_BREEZE_W * coast_pressure_w * vs_mag * breeze_sign) * (-(coast_sea[cell] as Vector2))
		elif is_water and sea_dist.has(cell):
			var sea_pw: float = 1.0 - float(int(sea_dist[cell])) / float(_SEA_BREEZE_SEA_MAX_DIST)
			v_sum += (_WIND_SEA_BREEZE_W * sea_pw * vs_mag * breeze_sign) * (sea_land[cell] as Vector2)
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
			var idx_wb: int = PhysicalCirculationSolver._cell_idx(map, cell)
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
						var im := PhysicalCirculationSolver._neighbor_dir_index(map, cell, nb_m)
						if im >= 0:
							mtn_dir_sum += PhysicalCirculationSolver.NEIGHBOR_DIRS[im]
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
		# NS 化 Phase 1 结构镜像:transp = 旧动量 + 自平流增量 + 扩散增量;
		# final = transp.lerp(target, r)。momentum 关闭时 transp==old_flux 逐位不变。
		var transp: Vector2 = old_flux
		if momentum_active and old_dir.length_squared() > 0.0001 and old_spd > 0.0001:
			var idx_mom: int = PhysicalCirculationSolver._cell_idx(map, cell)
			if idx_mom >= 0:
				if momentum_advect_w > 0.0 and traj_rows[idx_mom] != null:
					var row: Dictionary = traj_rows[idx_mom]
					var sl: Vector2 = float(row["w0"]) * snap_flux[int(row["i0"])] \
						+ float(row["w1"]) * snap_flux[int(row["i1"])] \
						+ float(row["w2"]) * snap_flux[int(row["i2"])]
					transp += momentum_advect_w * (sl - old_flux)
				if diffuse_w > 0.0:
					var sum_nb := Vector2.ZERO
					var cnt_nb: int = 0
					for nb_d: HexCell in nbs:
						if nb_d == null:
							continue
						var idx_nb: int = PhysicalCirculationSolver._cell_idx(map, nb_d)
						if idx_nb < 0:
							continue
						sum_nb += snap_flux[idx_nb]
						cnt_nb += 1
					if cnt_nb > 0:
						transp += diffuse_w * (sum_nb / float(cnt_nb) - old_flux)
		var final_flux: Vector2 = transp.lerp(target_flux, effective_rate)
		var final_spd: float = lerpf(old_spd, spd, effective_rate)
		var final_dir: Vector2 = final_flux.normalized() if final_flux.length_squared() > 0.0001 else dir
		cell.wind_vector = final_dir
		cell.wind_speed = final_spd
		var idx_w: int = PhysicalCirculationSolver._cell_idx(map, cell)
		if idx_w >= 0:
			if map.wind_x_arr.size() > idx_w:
				map.wind_x_arr[idx_w] = final_dir.x
			if map.wind_y_arr.size() > idx_w:
				map.wind_y_arr[idx_w] = final_dir.y
			if map.wind_speed_arr.size() > idx_w:
				map.wind_speed_arr[idx_w] = final_spd
