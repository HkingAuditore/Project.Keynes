extends "res://scripts/weather/weather_context.gd"
class_name DCWeatherFrontSpawn


func _init(weather_system) -> void:
	_weather_system = weather_system


func _spawn_random_front(host, world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	# 在地图内随机选一个 spawn 点
	var origin = host._world_bounds.position
	var size = host._world_bounds.size
	var sx: float = host._rng.randf_range(origin.x, origin.x + size.x)
	var sy: float = host._rng.randf_range(origin.y, origin.y + size.y)
	var spawn_pos = Vector2(sx, sy)

	# 该点的 latitude_norm（用于决定可生成的天气类型）。
	# latitude_buffer 直接给的是 [0,1] 的 ny，转成 [-1, 1] 表示南北纬。
	var lat_norm: float = world.sample_moisture(spawn_pos)  # placeholder if no helper
	# 安全用法：直接复用 _world_to_uv 思路 → 自己算
	if size.y > 0.001:
		lat_norm = clampf((sy - origin.y) / size.y, 0.0, 1.0)
	var lat_signed: float = lat_norm * 2.0 - 1.0   # -1 = 南极, +1 = 北极
	var abs_lat: float = absf(lat_signed)

	# 在水面 spawn 的天气类型受限（HEATWAVE/DROUGHT 不在海上 spawn）
	var on_water: bool = false
	var biome_at_spawn: int = world.sample_biome(spawn_pos)
	if biome_at_spawn == 0 or biome_at_spawn == 1 or biome_at_spawn == 18 \
			or biome_at_spawn == 19 or biome_at_spawn == 20 or biome_at_spawn == 21:
		# OCEAN/COAST/LAKE/REEF/SEA_ICE/KELP（与 world_map.gdshader B_* 常量同序）
		on_water = true

	# 类型抽样：按 (season, latitude, on_water) 加权
	var wt: int = host._pick_weather_type(season_idx, abs_lat, on_water, climate_anomaly)
	if wt == WeatherType.WT.CLEAR:
		return null  # CLEAR 不需要 front 实例

	var front = WeatherFront.new()
	front.center = spawn_pos
	front.type = wt
	front.intensity = host._rng.randf_range(0.55, 1.0)
	# 半径以 hex_size 为基准；不同天气大小不同
	var radius_mul: float = 1.0
	match wt:
		WeatherType.WT.RAIN:     radius_mul = host._rng.randf_range(6.0, 12.0)
		WeatherType.WT.STORM:    radius_mul = host._rng.randf_range(5.0, 9.0)
		WeatherType.WT.BLIZZARD: radius_mul = host._rng.randf_range(7.0, 13.0)
		WeatherType.WT.DROUGHT:  radius_mul = host._rng.randf_range(10.0, 18.0)
		WeatherType.WT.FOG:      radius_mul = host._rng.randf_range(4.0, 8.0)
		WeatherType.WT.HEATWAVE: radius_mul = host._rng.randf_range(8.0, 14.0)
		WeatherType.WT.MONSOON:  radius_mul = host._rng.randf_range(8.0, 14.0)
		_:                       radius_mul = 8.0
	front.radius = host._hex_size * radius_mul
	front.edge_seed = host._rng.randf_range(0.0, 1000.0)
	# 寿命与衰减：DROUGHT/HEATWAVE 较慢，雷暴较快
	# Phase E（方案 A）：寿命整体 ~×2，decay 减半。短命类型（STORM/FOG/BLIZZARD）
	# 在快推进档位下原本 2~4 天就消失，肉眼上是"突现突灭"；现在 RAIN ~14 天、
	# STORM ~9 天、FOG ~8 天、BLIZZARD ~12 天，配合更慢衰减让强度曲线变缓，
	# 表现层有充足时间做 birth/dissolve 渐变。DROUGHT/HEATWAVE 已是长寿命，
	# 仅微调以维持相对比例。
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = host._rng.randi_range(30, 56)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = host._rng.randi_range(12, 22)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			# 强对流/热带暴雨：原 6-11 天 → 4-8 天，避免单地连下一周
			front.ttl_days = host._rng.randi_range(4, 8)
			front.decay_per_day = 0.14
		WeatherType.WT.BLIZZARD:
			# 暴雪：原 8-14 天 → 5-10 天
			front.ttl_days = host._rng.randi_range(5, 10)
			front.decay_per_day = 0.12
		WeatherType.WT.FOG:
			front.ttl_days = host._rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			# RAIN：原 10-16 天 → 6-11 天
			front.ttl_days = host._rng.randi_range(6, 11)
			front.decay_per_day = 0.07
	# 初始速度沿当前 spawn 点风向。
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((sy - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = host._sample_terrain_wind(host._map_for_spawn(world), world, spawn_pos, ny_spawn, host._season_phase)
	if wind.length() > 0.05:
		var wind_axis = wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		# Phase E（方案 A）：把每天行进距离从 0.4×radius 提到 0.65×radius。
		# 配合寿命翻倍，front 总位移从 ~2×radius 提到 ~5×radius，
		# 视觉上是“持续飘过来再飘过去”，而不是“原地附近晃动”。
		front.velocity = wind_axis * (front.radius * 0.65)
	else:
		var a = host._rng.randf_range(0.0, TAU)
		front.axis = Vector2(cos(a), sin(a))
		front.stable_axis = front.axis
	host._apply_front_shape_by_type(front)
	front.refresh_visual_lifecycle()
	return front


func _apply_front_shape_by_type(host, front: WeatherFront) -> void:
	if front == null:
		return
	match front.type:
		WeatherType.WT.RAIN:
			front.major_scale = 1.65
			front.minor_scale = 0.68
		WeatherType.WT.STORM:
			front.major_scale = 1.18
			front.minor_scale = 0.72
		WeatherType.WT.BLIZZARD:
			front.major_scale = 1.85
			front.minor_scale = 0.48
		WeatherType.WT.DROUGHT:
			front.major_scale = 1.42
			front.minor_scale = 0.86
		WeatherType.WT.FOG:
			front.major_scale = 1.35
			front.minor_scale = 1.05
		WeatherType.WT.HEATWAVE:
			front.major_scale = 1.55
			front.minor_scale = 0.82
		WeatherType.WT.MONSOON:
			front.major_scale = 2.05
			front.minor_scale = 0.56
		_:
			front.major_scale = 1.0
			front.minor_scale = 1.0

# 加权类型抽样：
#   abs_lat ∈ [0, 1]：0=赤道, 1=极地
#   on_water：海面禁用 HEATWAVE / DROUGHT；WT.MONSOON 作为强热带降水兼容类型
#   climate_anomaly：全球暖化 → HEATWAVE/DROUGHT 概率上调；冷化 → BLIZZARD 上调

func _pick_weather_type(host, season_idx: int, abs_lat: float, on_water: bool, climate_anomaly: float) -> int:
	season_idx = -1
	var weights: Dictionary = {
		WeatherType.WT.RAIN:     1.0,
		WeatherType.WT.STORM:    0.5,
		WeatherType.WT.FOG:      0.3,
		WeatherType.WT.BLIZZARD: 0.0,
		WeatherType.WT.DROUGHT:  0.0,
		WeatherType.WT.HEATWAVE: 0.0,
		WeatherType.WT.MONSOON:  0.0,
	}

	# 旧季节调权分支已禁用；front 类型不再由 season_idx 直接指定。
	match -1:
		0:  # 春
			weights[WeatherType.WT.RAIN]     = 1.4
			weights[WeatherType.WT.STORM]    = 0.6
			weights[WeatherType.WT.FOG]      = 0.5
		1:  # 夏
			weights[WeatherType.WT.STORM]    = 1.2
			weights[WeatherType.WT.HEATWAVE] = 0.7 if not on_water else 0.0
			weights[WeatherType.WT.DROUGHT]  = 0.5 if not on_water else 0.0
			# Legacy only：旧夏季低纬强降水权重，当前分支不会进入。
			if abs_lat < 0.45:
				weights[WeatherType.WT.MONSOON] = 1.0
		2:  # 秋
			weights[WeatherType.WT.RAIN]     = 1.2
			weights[WeatherType.WT.STORM]    = 0.7
			weights[WeatherType.WT.FOG]      = 0.6
		3:  # 冬
			weights[WeatherType.WT.RAIN]     = 0.6
			weights[WeatherType.WT.STORM]    = 0.4
			# Legacy only：旧冬季高纬暴雪权重，当前分支不会进入。
			if abs_lat > 0.45:
				weights[WeatherType.WT.BLIZZARD] = 1.6
			weights[WeatherType.WT.FOG] = 0.7

	# 高纬度永远禁掉 HEATWAVE/MONSOON
	if abs_lat > 0.55:
		weights[WeatherType.WT.HEATWAVE] = 0.0
		weights[WeatherType.WT.MONSOON]  = 0.0
	# 低纬度永远禁掉 BLIZZARD
	if abs_lat < 0.30:
		weights[WeatherType.WT.BLIZZARD] = 0.0

	# 全球气候异常调权
	if climate_anomaly > 0.05:
		weights[WeatherType.WT.HEATWAVE] *= 1.0 + climate_anomaly * 4.0
		weights[WeatherType.WT.DROUGHT]  *= 1.0 + climate_anomaly * 3.0
		weights[WeatherType.WT.BLIZZARD] *= 0.5
	elif climate_anomaly < -0.05:
		weights[WeatherType.WT.BLIZZARD] *= 1.0 + (-climate_anomaly) * 4.0
		weights[WeatherType.WT.HEATWAVE] *= 0.4
		weights[WeatherType.WT.DROUGHT]  *= 0.6

	# 累计概率抽样
	var total: float = 0.0
	for v in weights.values():
		total += float(v)
	if total <= 0.001:
		return WeatherType.WT.CLEAR
	var pick: float = host._rng.randf() * total
	var acc: float = 0.0
	for k in weights.keys():
		acc += float(weights[k])
		if pick <= acc:
			return int(k)
	return WeatherType.WT.CLEAR

# --- 把活跃 front 的影响分发到每个 cell ---


func _front_decay_modifier(host, front: WeatherFront, cell: HexCell) -> float:
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var temp: float = cell.temperature
	var moist: float = cell.moisture
	var warm: bool = temp > 0.55
	var cold: bool = temp < 0.30
	var humid: bool = moist > 0.55
	var dry: bool = moist < 0.35
	match front.type:
		WeatherType.WT.RAIN:
			if humid: return 0.7
			if dry and warm: return 1.5
		WeatherType.WT.STORM:
			if humid and warm: return 0.7
			if dry or cold: return 1.5
		WeatherType.WT.MONSOON:
			if humid and warm: return 0.7
			if dry: return 1.5
		WeatherType.WT.BLIZZARD:
			if cold: return 0.7
			if warm: return 1.5
		WeatherType.WT.HEATWAVE:
			if warm and dry: return 0.7
			if cold or humid: return 1.5
		WeatherType.WT.DROUGHT:
			if dry and warm: return 0.7
			if humid: return 1.5
		WeatherType.WT.FOG:
			if humid and cold: return 0.7
	return 1.0


func _cold_precip_should_snow(host, temp: float, vapor: float, cloud: float, precip: float, meaningful_precip: bool) -> bool:
	if not host._cold_precip_as_blizzard or not meaningful_precip:
		return false
	if temp <= host.SNOW_FREEZE_T:
		return true
	return temp < host.SNOW_MELT_T + host._snow_classification_margin \
			and cloud > 0.18 and vapor > 0.20 and precip > 0.04

# 迎风坡降水加成 / 背风坡额外衰减：
#   沿 front.velocity 方向找上风 cell：若上风 cell 海拔比本格高出阈值 → 迎风坡（返回正 bonus）
#   若本格海拔比上风 cell 高出阈值 → 背风坡（返回负 bonus，作衰减）
# 仅对降水型 front 生效（RAIN / STORM / MONSOON / BLIZZARD）。

func _front_orographic_precip_bonus(host, front: WeatherFront, cell: HexCell, map: MapData) -> float:
	var t: int = front.type
	if t != WeatherType.WT.RAIN and t != WeatherType.WT.STORM \
	and t != WeatherType.WT.MONSOON and t != WeatherType.WT.BLIZZARD:
		return 0.0
	var v: Vector2 = front.velocity
	if v.length_squared() < 1e-6:
		return 0.0
	# 从本格向上风（-v）方向找最对齐邻居
	var w_dir: Vector2 = -v.normalized()
	var self_wp: Vector2 = host._cell_world_pos(cell)
	var best_nb: HexCell = null
	var best_dot: float = 0.1
	for nb: HexCell in host._cell_neighbors(cell, map):
		if nb == null:
			continue
		var nbwp: Vector2 = host._cell_world_pos(nb)
		var d: Vector2 = (nbwp - self_wp)
		if d.length_squared() < 1e-6:
			continue
		var dv: float = d.normalized().dot(w_dir)
		if dv > best_dot:
			best_dot = dv
			best_nb = nb
	if best_nb == null:
		return 0.0
	var h_diff: float = cell.elevation - best_nb.elevation
	if h_diff < -host._emergent_rain_shadow_threshold:
		# 本格比上风低很多 → 迎风爬坡 → 加成
		return 0.08 * host._emergent_orographic_boost
	if h_diff > host._emergent_rain_shadow_threshold:
		# 本格比上风高很多 → 背风 → 衰减（通过负 bonus 在分发时减少降水）
		return -0.08
	return 0.0

# Emergent spawn：按本地 1 环温湿梯度加权抽 1 个 cell 作为 spawn 源，
# 类型由本地温度带、湿度带、水陆条件和实际气候异常共同决定。

func _spawn_emergent_front(host, map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	if map == null:
		return null
	# Step 1：采样一批候选 cell（32 个），按 1 环温湿梯度最大值加权选取
	var all_cells: Array = map.all_cells()
	if all_cells.is_empty():
		return null
	var samples: int = mini(32, all_cells.size())
	var best_cell: HexCell = null
	# 累计权重抽样：先算 total，再用 randf*total 抽
	var cands: Array = []
	var weights: Array = []
	var total_w: float = 0.0
	for i in range(samples):
		var c: HexCell = all_cells[host._rng.randi_range(0, all_cells.size() - 1)]
		if c == null:
			continue
		var w: float = host._local_temp_moist_gradient(c, map) + 0.05  # 底噪避免全 0
		# Ocean spawn bias：寒流邻水抑制候选 cell 的 spawn 权重，暖流提升。
		# 仅对陆地 / 海岸有 ≥1 个水域邻居的 cell 生效；远海面与内陆不变。
		# 偏置因子整体作用于"权重通道"，与具体 weather type 无关；
		# 类型抑制（寒流海岸 RAIN→CLEAR 之类）由 host._pick_weather_type_emergent# 类型抑制（寒流海岸 RAIN→CLEAR 之类）由 _pick_weather_type_emergent
		# 内部独立处理，避免双重惩罚。
		if host._ocean_spawn_bias > 0.0:
			var w_mul: float = host._ocean_weight_multiplier(c, map)
			w *= w_mul
		cands.append(c)
		weights.append(w)
		total_w += w
	if total_w <= 0.001 or cands.is_empty():
		return null
	var pick: float = host._rng.randf() * total_w
	var acc: float = 0.0
	for i in range(cands.size()):
		acc += float(weights[i])
		if pick <= acc:
			best_cell = cands[i]
			break
	if best_cell == null:
		return null
	# Step 2：用该 cell 的温湿、水陆条件和实际气候异常决定类型。
	var wt: int = host._pick_weather_type_emergent(best_cell, season_idx, climate_anomaly, map)
	if wt == WeatherType.WT.CLEAR:
		return null
	# Step 3：复用 host._spawn_random_front 的参数化流程，但强制 spawn 位置为 best_cell 的世界坐标# Step 3：复用 _spawn_random_front 的参数化流程，但强制 spawn 位置为 best_cell 的世界坐标
	var spawn_pos: Vector2 = HexUtils.cube_to_world(best_cell.q, best_cell.r, host._hex_size)
	return host._build_front_at(spawn_pos, wt, world)

# 本地 1 环温湿梯度最大值（温度差 + 湿度差取 max）

func _local_temp_moist_gradient(host, cell: HexCell, map: MapData) -> float:
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var t0: float = cell.temperature
	var m0: float = cell.moisture
	var max_dt: float = 0.0
	var max_dm: float = 0.0
	for nb: HexCell in host._cell_neighbors(cell, map):
		if nb == null:
			continue
		var dt: float = absf(nb.temperature - t0)
		var dm: float = absf(nb.moisture - m0)
		if dt > max_dt: max_dt = dt
		if dm > max_dm: max_dm = dm
	return maxf(max_dt, max_dm)

# 由本地温度带、湿度带、水陆条件和实际气候异常决定 front 类型。
# 规则：
#   暖湿陆地 + 强实际升温 → STORM
#   寒冷海面          → BLIZZARD
#   暖干陆地 + 高温     → HEATWAVE
#   暖干陆地           → DROUGHT
#   寒湿 / 暖湿海岸   → RAIN
#   低温湿             → FOG
# 其余返回 CLEAR（不 spawn）。

func _pick_weather_type_emergent(host, cell: HexCell, season_idx: int, climate_anomaly: float, map: MapData = null) -> int:
	season_idx = -1
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var t: float = cell.temperature + climate_anomaly
	var m: float = cell.moisture
	var cell_world: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, host._hex_size)
	var lat_norm: float = 0.5
	if host._world_bounds.size.y > 0.001:
		lat_norm = clampf((cell_world.y - host._world_bounds.position.y) / host._world_bounds.size.y, 0.0, 1.0)
	var lat_signed: float = lat_norm * 2.0 - 1.0
	var low_lat: bool = absf(lat_signed) < 0.42
	var on_water: bool = host._is_water_terrain(int(cell.terrain))
	var warm: bool = t > 0.55
	var hot: bool = t > 0.68
	var cold: bool = t < 0.30
	var humid: bool = m > 0.55
	var dry: bool = m < 0.35

	if on_water:
		if cold:
			return WeatherType.WT.BLIZZARD
		# 暖湿海面：STORM（台风/热带风暴）
		if warm and humid:
			return host._ocean_filter_precip(cell, map, WeatherType.WT.STORM)
		return host._ocean_filter_precip(cell, map, WeatherType.WT.RAIN)
	# 陆地路径
	if hot and humid:
		return host._ocean_filter_precip(cell, map, WeatherType.WT.STORM)
	if warm and dry:
		if hot:
			return WeatherType.WT.HEATWAVE
		return WeatherType.WT.DROUGHT
	if cold:
		return WeatherType.WT.BLIZZARD
	if humid:
		if warm and low_lat and m > 0.65:
			return host._ocean_filter_precip(cell, map, WeatherType.WT.MONSOON)
		return host._ocean_filter_precip(cell, map, WeatherType.WT.RAIN)
	if t < 0.45 and m > 0.40:
		return WeatherType.WT.FOG
	return WeatherType.WT.CLEAR

# Ocean spawn bias helpers：当 host._ocean_spawn_bias > 0 时启用。# Ocean spawn bias helpers：当 _ocean_spawn_bias > 0 时启用。
# 实现"洋流温度异常 → 沿岸天气事件偏置"通路：
#   - 寒流海岸（邻水 anomaly < 0）→ 抑制 RAIN/STORM/MONSOON 的 spawn 权重
#     与类型保留概率，让寒流海岸沙漠在天气层也表现为"少雨多雾"。
#   - 暖流海岸（邻水 anomaly > 0）→ 同类型权重提升，模拟湾流型多雨气候。
#   - 内陆 cell（无水邻居）与远海面（cell 自身就是水）→ 无影响。
#   - BLIZZARD/FOG/HEATWAVE/DROUGHT 不受影响（与"降水/对流"无直接因果）。

# 候选 cell 的 spawn 权重乘子：> 1 表示更易被抽中、< 1 表示更难。
# 仅对"邻水 ≥ 1 的陆地 / 海岸"生效。范围 clamp 到 [0.1, 1 + bias]。

func _ocean_weight_multiplier(host, cell: HexCell, map: MapData) -> float:
	if cell == null or map == null or host._ocean_spawn_bias <= 0.0:
		return 1.0
	var avg_an: float = host._avg_ocean_anomaly_at(cell, map)
	if absf(avg_an) < 0.005:
		return 1.0
	# bias × anomaly 直接影响乘子。anomaly ∈ ~[-0.3, +0.3]，bias 1.2 →
	# 寒流极端 ×0.64 / 暖流极端 ×1.36；clamp 防止退化为 0。
	var mul: float = 1.0 + host._ocean_spawn_bias * avg_an
	return clampf(mul, 0.1, 1.0 + host._ocean_spawn_bias)

# 寒流海岸 RAIN/STORM/MONSOON → CLEAR/FOG 软降级；暖流海岸不动作。
# 用累计概率：寒流强度越大、邻水占比越高，降级概率越大。

func _ocean_filter_precip(host, cell: HexCell, map: MapData, wt: int) -> int:
	if map == null or host._ocean_spawn_bias <= 0.0:
		return wt
	var avg_an: float = host._avg_ocean_anomaly_at(cell, map)
	if avg_an >= -0.01:
		return wt  # 不冷或暖流 → 不动
	# 降级概率 = bias × |anomaly|，clamp [0, 0.85]。
	var p_demote: float = clampf(host._ocean_spawn_bias * (-avg_an), 0.0, 0.85)
	if host._rng.randf() < p_demote:
		# 极冷（|anomaly| 大）→ FOG；中冷 → CLEAR。让"沿岸冷雾"在寒流海岸涌现。
		if -avg_an > 0.15:
			return WeatherType.WT.FOG
		return WeatherType.WT.CLEAR
	return wt

# 取 cell 1 环邻水的平均 temperature_transport_anomaly。无水邻居返回 0。
# 海面 cell 直接返回自身 anomaly（因为本身就是洋流体）。
# dots-monolith-split §1.2 / PR-3：搬迁到 field_solver.gd（薄转发）。

func _avg_ocean_anomaly_at(host, cell: HexCell, map: MapData) -> float:
	return host._field_solver._avg_ocean_anomaly_at(cell, map)

# 基于给定 spawn_pos + 类型 wt 构造 front（从 host._spawn_random_front 提炼），# 基于给定 spawn_pos + 类型 wt 构造 front（从 _spawn_random_front 提炼），
# 避免重复类型抽样逻辑。

func _build_front_at(host, spawn_pos: Vector2, wt: int, world: WorldData) -> WeatherFront:
	var front = WeatherFront.new()
	front.center = spawn_pos
	front.type = wt
	front.intensity = host._rng.randf_range(0.55, 1.0)
	var radius_mul: float = 1.0
	match wt:
		WeatherType.WT.RAIN:     radius_mul = host._rng.randf_range(6.0, 12.0)
		WeatherType.WT.STORM:    radius_mul = host._rng.randf_range(5.0, 9.0)
		WeatherType.WT.BLIZZARD: radius_mul = host._rng.randf_range(7.0, 13.0)
		WeatherType.WT.DROUGHT:  radius_mul = host._rng.randf_range(10.0, 18.0)
		WeatherType.WT.FOG:      radius_mul = host._rng.randf_range(4.0, 8.0)
		WeatherType.WT.HEATWAVE: radius_mul = host._rng.randf_range(8.0, 14.0)
		WeatherType.WT.MONSOON:  radius_mul = host._rng.randf_range(8.0, 14.0)
		_:                       radius_mul = 8.0
	front.radius = host._hex_size * radius_mul
	front.edge_seed = host._rng.randf_range(0.0, 1000.0)
	# Phase E（方案 A）：与 host._spawn_random_front 同步——寿命 ~×2、decay 减半。# Phase E（方案 A）：与 _spawn_random_front 同步——寿命 ~×2、decay 减半。
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = host._rng.randi_range(30, 56)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = host._rng.randi_range(12, 22)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			# 强对流/热带暴雨：原 6-11 天 → 4-8 天，避免单地连下一周
			front.ttl_days = host._rng.randi_range(4, 8)
			front.decay_per_day = 0.14
		WeatherType.WT.BLIZZARD:
			# 暴雪：原 8-14 天 → 5-10 天
			front.ttl_days = host._rng.randi_range(5, 10)
			front.decay_per_day = 0.12
		WeatherType.WT.FOG:
			front.ttl_days = host._rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			# RAIN：原 10-16 天 → 6-11 天
			front.ttl_days = host._rng.randi_range(6, 11)
			front.decay_per_day = 0.07
	var origin = host._world_bounds.position
	var size = host._world_bounds.size
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((spawn_pos.y - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = host._sample_terrain_wind(host._map_for_spawn(world), world, spawn_pos, ny_spawn, host._season_phase)
	if wind.length() > 0.05:
		var wind_axis = wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		# Phase E（方案 A）：行进距离 0.4 → 0.65 倍 radius/天。
		front.velocity = wind_axis * (front.radius * 0.65)
	else:
		var a = host._rng.randf_range(0.0, TAU)
		front.axis = Vector2(cos(a), sin(a))
		front.stable_axis = front.axis
	host._apply_front_shape_by_type(front)
	front.refresh_visual_lifecycle()
	return front

func try_spawn(_world: WorldData, _season_idx: int, _climate_anomaly: float) -> WeatherFront:
	return null

func describe() -> String:
	return "DCWeatherFrontSpawn(owner=%s)" % ("ws" if _weather_system != null else "(null)")
