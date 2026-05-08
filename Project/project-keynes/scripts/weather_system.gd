# weather_system.gd
# Milestone 3：天气子系统主类（按 day_changed 推进）。
#
# 职责：
#   1. 维护一个最多 MAX_FRONTS 个活动 WeatherFront 的队列
#   2. 每天 tick：
#      a) 推进所有 front（advect by wind_field, decay intensity, age++）
#      b) 回收 dead front
#      c) 按 season + 全球气候 spawn 新 front（带类型分布）
#      d) 把每个 cell 的"被覆盖到的最强 front"写到 cell.current_state.weather/intensity
#      e) 根据 weather 临时调整 cell.moisture / temperature（覆盖 current_state.*）
#      f) 必要时短期改写 cell.cover（BLIZZARD → SNOW、MONSOON/STORM → FLOODING）
#   3. 提供 query_at(world_pos) 与 pack_to_uniforms() 让 UI / shader 直接复用
#
# 设计原则：
#   - 不写回 base_*：天气是临时性的，年度漂移（Phase 8）只看 base_moisture，
#     这样 weather 不会污染长期生态记忆，玩家手感 = "天气是表层、生态是底层"
#   - max-merge 而非线性叠加：避免双暴雨之类的数值爆炸
#   - 与 WorldClock seed 解耦：自己持有 RNG，可独立 seed → 复盘 / 多人同步友好
#   - 仅 max 16 fronts：可一次塞进 shader uniform 数组，每 fragment 16 次距离测试
#     就能完整渲染所有天气效果

class_name WeatherSystem
extends RefCounted

const MAX_FRONTS := 16
# 每天 spawn 检查次数（每次都按概率 spawn 一个；MAX_FRONTS 已满则跳过）
const SPAWN_TRIES_PER_DAY := 2
# 不同季节的 spawn 概率（让冬天天气更频繁）
const SPAWN_PROB_BY_SEASON := [0.40, 0.50, 0.45, 0.55]  # 春 / 夏 / 秋 / 冬

var _rng: RandomNumberGenerator
var _active_fronts: Array[WeatherFront] = []
var _world_bounds: Rect2 = Rect2()
var _hex_size: float = 22.0
var _day_counter: int = 0
# Phase D：当前游戏季节相位（连续浮点，0=春 1=夏 2=秋 3=冬）。
# 在 tick_one_day 里由调用方写入，用于动态计算季风偏置——
# 静态烘焙的 wind_field_buffer 是夏季基线，加上当前季节的 monsoon offset
# 才能让"夏吹向极、冬吹向赤道"的季风真正在 GPU/CPU 同步可见。
var _season_phase: float = 1.0
# Milestone 3：上次 tick 是否改写过任何 cell.cover（给 baker 决定要不要 rebake cover_tex）
var _cover_dirty: bool = false

# --- 初始化 ---

func init(seed_val: int, world_bounds: Rect2, hex_size: float) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_val ^ 0xBEEF1234
	_world_bounds = world_bounds
	_hex_size = hex_size
	_active_fronts.clear()
	_day_counter = 0

# --- 每日 tick（由 MapGenerator.refresh_daily 调用） ---

# season_idx: 0=春 1=夏 2=秋 3=冬
# climate_anomaly: 全球长期温度偏移 [-0.2, +0.2]
# season_phase: 连续浮点 [0,4)；如果 caller 不传则 fallback 到 season_idx + 0.5。
# 返回当前活动 front 的快照（给 main / renderer 上传 shader uniform 用）
func tick_one_day(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0) -> Array[WeatherFront]:
	if map == null or world == null:
		return _active_fronts
	_day_counter += 1
	# Phase D：缓存当前 season_phase 给 wind_fn / spawn 用。
	# fallback：如果 caller 没提供（旧调用方兼容），按 season_idx 取季中点。
	_season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5

	# Phase D：wind_fn 在静态 buffer 风的基础上叠加当季 monsoon 偏置。
	# 这样 dry summer→winter 切换时，已存在的 MONSOON front 会立刻顺着新季风方向飘转，
	# 而不是被困在夏季基线方向上。
	var bounds := _world_bounds
	var sp := _season_phase
	var wind_fn := func(pos: Vector2) -> Vector2:
		var base: Vector2 = world.sample_wind(pos)
		var ny: float = 0.5
		if bounds.size.y > 0.001:
			ny = clampf((pos.y - bounds.position.y) / bounds.size.y, 0.0, 1.0)
		return base + WindBelt.monsoon_offset_at(ny, sp)

	# 1) 推进所有 front
	for front in _active_fronts:
		front.advance_one_day(wind_fn)

	# 2) 回收 dead 与出图 front
	var alive: Array[WeatherFront] = []
	for front in _active_fronts:
		if not front.is_alive():
			continue
		# 飘出地图边界 + 1 倍 radius 也算出图
		if not _world_bounds.grow(front.bounding_radius()).has_point(front.center):
			continue
		alive.append(front)
	_active_fronts = alive

	# 3) Spawn 新 front
	var spawn_prob: float = float(SPAWN_PROB_BY_SEASON[season_idx % 4])
	for i in range(SPAWN_TRIES_PER_DAY):
		if _active_fronts.size() >= MAX_FRONTS:
			break
		if _rng.randf() < spawn_prob:
			var f := _spawn_random_front(world, season_idx, climate_anomaly)
			if f != null:
				_active_fronts.append(f)

	# 4) 把当前所有 front 影响分发到每个 cell
	_distribute_to_cells(map)

	return _active_fronts

# --- 内部：按 season + 经纬度 spawn 一个新 front ---

func _spawn_random_front(world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
	# 在地图内随机选一个 spawn 点
	var origin := _world_bounds.position
	var size := _world_bounds.size
	var sx: float = _rng.randf_range(origin.x, origin.x + size.x)
	var sy: float = _rng.randf_range(origin.y, origin.y + size.y)
	var spawn_pos := Vector2(sx, sy)

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
	var wt: int = _pick_weather_type(season_idx, abs_lat, on_water, climate_anomaly)
	if wt == WeatherType.WT.CLEAR:
		return null  # CLEAR 不需要 front 实例

	var front := WeatherFront.new()
	front.center = spawn_pos
	front.type = wt
	front.intensity = _rng.randf_range(0.55, 1.0)
	# 半径以 hex_size 为基准；不同天气大小不同
	var radius_mul: float = 1.0
	match wt:
		WeatherType.WT.RAIN:     radius_mul = _rng.randf_range(6.0, 12.0)
		WeatherType.WT.STORM:    radius_mul = _rng.randf_range(5.0, 9.0)
		WeatherType.WT.BLIZZARD: radius_mul = _rng.randf_range(7.0, 13.0)
		WeatherType.WT.DROUGHT:  radius_mul = _rng.randf_range(10.0, 18.0)
		WeatherType.WT.FOG:      radius_mul = _rng.randf_range(4.0, 8.0)
		WeatherType.WT.HEATWAVE: radius_mul = _rng.randf_range(8.0, 14.0)
		WeatherType.WT.MONSOON:  radius_mul = _rng.randf_range(8.0, 14.0)
		_:                       radius_mul = 8.0
	front.radius = _hex_size * radius_mul
	front.edge_seed = _rng.randf_range(0.0, 1000.0)
	# 寿命与衰减：DROUGHT/HEATWAVE 较慢，雷暴较快
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = _rng.randi_range(20, 40)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = _rng.randi_range(8, 16)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			front.ttl_days = _rng.randi_range(2, 5)
			front.decay_per_day = 0.20
		WeatherType.WT.BLIZZARD:
			front.ttl_days = _rng.randi_range(3, 7)
			front.decay_per_day = 0.16
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(2, 4)
			front.decay_per_day = 0.30
		_:
			front.ttl_days = _rng.randi_range(4, 8)
			front.decay_per_day = 0.14
	# 初始速度沿当前 spawn 点风向
	# Phase D：与 wind_fn 同源——叠加当季 monsoon 偏置，让新生 MONSOON front
	# 一出生就朝向真正的当季季风方向，而不是夏季基线方向。
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((sy - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = world.sample_wind(spawn_pos) + WindBelt.monsoon_offset_at(ny_spawn, _season_phase)
	if wind.length() > 0.05:
		var wind_axis := wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		front.velocity = wind_axis * (front.radius * 0.4)
	else:
		var a := _rng.randf_range(0.0, TAU)
		front.axis = Vector2(cos(a), sin(a))
		front.stable_axis = front.axis
	_apply_front_shape_by_type(front)
	front.refresh_visual_lifecycle()
	return front

func _apply_front_shape_by_type(front: WeatherFront) -> void:
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
#   on_water：海面禁用 HEATWAVE / DROUGHT；MONSOON 仅低纬度 + 夏季
#   climate_anomaly：全球暖化 → HEATWAVE/DROUGHT 概率上调；冷化 → BLIZZARD 上调
func _pick_weather_type(season_idx: int, abs_lat: float, on_water: bool, climate_anomaly: float) -> int:
	var weights: Dictionary = {
		WeatherType.WT.RAIN:     1.0,
		WeatherType.WT.STORM:    0.5,
		WeatherType.WT.FOG:      0.3,
		WeatherType.WT.BLIZZARD: 0.0,
		WeatherType.WT.DROUGHT:  0.0,
		WeatherType.WT.HEATWAVE: 0.0,
		WeatherType.WT.MONSOON:  0.0,
	}

	# 季节调权
	match season_idx % 4:
		0:  # 春
			weights[WeatherType.WT.RAIN]     = 1.4
			weights[WeatherType.WT.STORM]    = 0.6
			weights[WeatherType.WT.FOG]      = 0.5
		1:  # 夏
			weights[WeatherType.WT.STORM]    = 1.2
			weights[WeatherType.WT.HEATWAVE] = 0.7 if not on_water else 0.0
			weights[WeatherType.WT.DROUGHT]  = 0.5 if not on_water else 0.0
			# 夏季低纬度大量 MONSOON
			if abs_lat < 0.45:
				weights[WeatherType.WT.MONSOON] = 1.0
		2:  # 秋
			weights[WeatherType.WT.RAIN]     = 1.2
			weights[WeatherType.WT.STORM]    = 0.7
			weights[WeatherType.WT.FOG]      = 0.6
		3:  # 冬
			weights[WeatherType.WT.RAIN]     = 0.6
			weights[WeatherType.WT.STORM]    = 0.4
			# 冬季高纬度大量 BLIZZARD
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
	var pick: float = _rng.randf() * total
	var acc: float = 0.0
	for k in weights.keys():
		acc += float(weights[k])
		if pick <= acc:
			return int(k)
	return WeatherType.WT.CLEAR

# --- 把活跃 front 的影响分发到每个 cell ---

func _distribute_to_cells(map: MapData) -> void:
	_cover_dirty = false
	for cell: HexCell in map.all_cells():
		var pos := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		var result := query_at(pos)
		var wt: int = int(result.get("type", WeatherType.WT.CLEAR))
		var intensity: float = float(result.get("intensity", 0.0))
		# 把 weather 状态写到 current_state
		cell.current_state["weather"] = wt
		cell.current_state["weather_intensity"] = intensity
		# 应用临时湿度 / 温度扰动（不写回 base_*）
		var moist_now: float = float(cell.current_state.get("moisture", cell.moisture))
		var temp_now: float = float(cell.current_state.get("temperature", 0.5))
		moist_now = clampf(moist_now + WeatherType.moisture_delta(wt) * intensity, 0.0, 1.0)
		temp_now = clampf(temp_now + WeatherType.temp_delta(wt) * intensity, 0.0, 1.0)
		cell.current_state["moisture"] = moist_now
		cell.current_state["temperature"] = temp_now
		# 临时覆盖物：BLIZZARD + 陆地 + 冷温 → SNOW；STORM/MONSOON + 低地 → FLOODING
		# 只在天气足够强（intensity > 0.4）时改写，避免微弱天气频繁翻覆盖物
		if intensity > 0.4 and not LandformType.is_water(cell.landform):
			var new_cover: int = cell.cover
			if WeatherType.can_form_snow(wt) and temp_now < 0.30:
				new_cover = CoverType.CV.SNOW
			elif WeatherType.can_form_flood(wt) and cell.elevation < 0.55 and moist_now > 0.65:
				new_cover = CoverType.CV.FLOODING
			if new_cover != cell.cover:
				cell.cover = new_cover
				cell.current_state["cover"] = int(cell.cover)
				_cover_dirty = true

func has_cover_dirty() -> bool:
	return _cover_dirty

# --- 查询接口（给 UI / 其他子系统） ---
# 返回 { "type": int(WT), "intensity": float [0,1] }；max-merge：取覆盖到该点的最强 front。
func query_at(world_pos: Vector2) -> Dictionary:
	var best_type: int = WeatherType.WT.CLEAR
	var best_intensity: float = 0.0
	for front in _active_fronts:
		var c: float = front.coverage_at(world_pos)
		if c > best_intensity:
			best_intensity = c
			best_type = front.type
	return {"type": best_type, "intensity": best_intensity}

# --- shader uniform 打包 ---
# 返回 { "centers": Array[Vector4(cx, cy, radius, intensity)], "types": Array[int], "count": int }
# 由 HexRenderer.set_weather_fronts 取用，组装成 shader uniform 数组。
func pack_to_uniforms() -> Dictionary:
	var centers: Array = []
	var types: Array = []
	var shapes: Array = []
	var visuals: Array = []
	for front in _active_fronts:
		centers.append(Vector4(front.center.x, front.center.y, front.radius, front.intensity))
		types.append(int(front.type))
		var ax := front.normalized_axis()
		shapes.append(Vector4(ax.x, ax.y, front.major_scale, front.minor_scale))
		visuals.append(Vector4(
			front.cloud_amount,
			front.precip_amount,
			front.dissolve_amount,
			front.life_progress
		))
	return {
		"centers": centers,
		"types": types,
		"shapes": shapes,
		"visuals": visuals,
		"count": _active_fronts.size()
	}

func active_fronts() -> Array[WeatherFront]:
	return _active_fronts
