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
# Phase E（方案 A）：寿命整体翻倍后，相同 spawn 频率会让池子常态打满，
# 新生 front 在边界排队 → 还是看起来像"忽闪"。这里把 spawn 概率统一 ×0.7，
# 与寿命延长相抵后，池子里的 front 数量大致与改动前持平，但每个个体都
# 待得更久、走得更远。
const SPAWN_PROB_BY_SEASON := [0.28, 0.35, 0.32, 0.39]  # 春 / 夏 / 秋 / 冬
# Phase E（方案 A）：寿命整体翻倍后，相同 spawn 频率会让池子常态打满，
# 新生 front 在边界排队 → 还是看起来

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

# Systemic Ocean Currents：台风尾迹扰动（可选，由 MapConfig.enable_cyclone_wake 开关控制）。
# 结构：{ cell_id (int "q*10000+r"): { "vec": Vector2, "days_left": int, "init_days": int } }。
# 每天 _tick_cyclone_wake 对 days_left 递减，days_left<=0 时移除；vec 幅度按比例衰减。
# 消费方：未来可由 HexRenderer 上传为 RG8 overlay uniform 供 shader 与主流场相加；
# 目前仅暴露只读 API cell_perturbation(cell) 供逻辑层直读（例如航运 AI）。
var ocean_current_perturbation: Dictionary = {}
# 下列两个字段由外部（MapGenerator/main）在 init 时写入一次，tick 时读。
# 为避免循环依赖，这里只保存基本数值。
var _cyclone_wake_enabled: bool = false
var _cyclone_wake_days: int = 3

# Emergent Climate Coupling：开关 + 子参数。
# 由外部 MapGenerator 在 init/refresh_daily 前写入，tick_one_day 内消费。
# 关闭时所有耦合行为退回到旧的均匀/季节硬切路径（兼容回退）。
var _emergent_coupling: bool = false
var _emergent_rain_shadow_threshold: float = 0.12
var _emergent_rain_shadow_factor: float = 0.55
var _emergent_orographic_boost: float = 1.5

# v11 地形—水汽耦合：开启后，weather 锁面 advection / spawn 优先采样
# HexCell.wind_vector（地形扰动后的六边形尺度实际风），而不是纣红度基线
# wind_field_buffer，让恶天镹面能被山脈裁引、微原。由 MapGenerator 在初始化时
# 通过 configure_terrain_wind() 推送。关闭后完全走旧路径（便于回滚验证）。
var _use_wind_vector_for_advect: bool = true

# Ocean current → weather event spawn bias：寒流/暖流海岸对降水类天气的
# spawn 概率偏置。bias > 0 时 spawn 评分中读取候选 cell 邻水 anomaly：
#   - 显著负 anomaly（寒流） → RAIN/STORM/MONSOON 权重乘 max(0.1, 1+bias×anomaly)
#   - 显著正 anomaly（暖流） → 同类型权重乘 (1+bias×anomaly) 提升
# BLIZZARD/FOG 不受影响。bias = 0 时退回 legacy 行为。
# 由 MapGenerator 在 init/configure 时通过 configure_ocean_spawn_bias 写入。
var _ocean_spawn_bias: float = 0.0

# Grid weather field solver. This is the primary weather logic when enabled:
# each hex owns vapor/cloud/precip/instability/type/intensity, and legacy fronts
# are rebuilt as a compact visual summary after the field solve.
var _weather_field_enabled: bool = true
var _field_advect_steps: int = 2
var _field_diffusion: float = 0.08
var _field_condensation_gain: float = 0.55
var _field_precip_decay: float = 0.35
var _field_orographic_lift_gain: float = 0.35
var _field_convergence_gain: float = 0.25
var _field_ocean_evap_gain: float = 0.40
var _field_summary_limit: int = MAX_FRONTS
var _weather_field: Dictionary = {}
var _last_map_for_query: MapData = null

# v11 在 tick_one_day 期间缓存当前 MapData 引用，供同一 tick 内部的 spawn
# 分支（_spawn_random_front / _build_front_at）复用，避免从调用链中到处透传。
# tick 结束后置 null，不跨帧持有弱引用 → 与旧生命周期一致。
var _current_map_for_tick: MapData = null

# Daily-sim perf instrumentation：tick_one_day 内部分段耗时快照。
# main.gd / map_generator.refresh_daily 可调 last_breakdown() 读取。
# 字段：advance_ms / spawn_ms / distribute_ms / cyclone_ms
var _last_breakdown: Dictionary = {}

func last_breakdown() -> Dictionary:
	return _last_breakdown

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
	_current_map_for_tick = map
	# Phase D：缓存当前 season_phase 给 wind_fn / spawn 用。
	# fallback：如果 caller 没提供（旧调用方兼容），按 season_idx 取季中点。
	_season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5

	# Phase D：wind_fn 在静态 buffer 风的基础上叠加当季 monsoon 偏置。
	# 这样 dry summer→winter 切换时，已存在的 MONSOON front 会立刻顺着新季风方向飘转，
	# 而不是被困在夏季基线方向上。
	var bounds := _world_bounds
	var sp := _season_phase
	var map_ref := map
	var self_ref := self
	var wind_fn := func(pos: Vector2) -> Vector2:
		var ny: float = 0.5
		if bounds.size.y > 0.001:
			ny = clampf((pos.y - bounds.position.y) / bounds.size.y, 0.0, 1.0)
		return self_ref._sample_terrain_wind(map_ref, world, pos, ny, sp)

	if _weather_field_enabled:
		var t_us0_field: int = Time.get_ticks_usec()
		_solve_weather_field(map, world, season_idx, climate_anomaly)
		var solve_ms: float = (Time.get_ticks_usec() - t_us0_field) / 1000.0

		t_us0_field = Time.get_ticks_usec()
		_distribute_weather_field_to_cells(map)
		var distribute_ms_field: float = (Time.get_ticks_usec() - t_us0_field) / 1000.0

		t_us0_field = Time.get_ticks_usec()
		_active_fronts = _build_field_summary_fronts(map, world)
		var summary_ms: float = (Time.get_ticks_usec() - t_us0_field) / 1000.0

		var cyclone_ms_field: float = 0.0
		if _cyclone_wake_enabled:
			t_us0_field = Time.get_ticks_usec()
			_tick_cyclone_wake(map)
			cyclone_ms_field = (Time.get_ticks_usec() - t_us0_field) / 1000.0

		_last_breakdown = {
			"advance_ms": solve_ms,
			"spawn_ms": summary_ms,
			"distribute_ms": distribute_ms_field,
			"cyclone_ms": cyclone_ms_field,
			"field_solve_ms": solve_ms,
			"field_summary_ms": summary_ms,
		}
		_last_map_for_query = map
		_current_map_for_tick = null
		return _active_fronts

	# Daily-sim perf instrumentation：带埋点的 advance / spawn / distribute / cyclone 四段。
	var t_us0: int = Time.get_ticks_usec()

	# 1) 推进所有 front
	# Emergent Climate Coupling：推进前先按 front 当前中心 cell 的 local 状态
	# 临时缩放本日衰减。类型与本地温湿带匹配 → ×0.7（长寿命）；
	# 不匹配 → ×1.5（更快耗尽）。缩放只影响本次 advance_one_day 的 decay 消耗。
	# 不持久化到 front.decay_per_day 自身，避免跨日连锁放大。
	for front in _active_fronts:
		var decay_mul: float = 1.0
		var precip_bonus: float = 0.0
		if _emergent_coupling and map != null:
			var cube := HexUtils.world_to_cube(front.center, _hex_size)
			var at_cell: HexCell = map.get_cell_by_cube(cube)
			if at_cell != null:
				decay_mul = _front_decay_modifier(front, at_cell)
				precip_bonus = _front_orographic_precip_bonus(front, at_cell, map)
		var saved_decay: float = front.decay_per_day
		front.decay_per_day = saved_decay * decay_mul
		front.advance_one_day(wind_fn)
		front.decay_per_day = saved_decay
		# 推进后如果地形给出迎风坡加成：把本日 precip_amount 拉高（视觉 + 后续分发用）
		if precip_bonus > 0.0:
			front.precip_amount = clampf(front.precip_amount + precip_bonus, 0.0, 1.0)

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
	var advance_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 3) Spawn 新 front
	t_us0 = Time.get_ticks_usec()
	var spawn_prob: float = float(SPAWN_PROB_BY_SEASON[season_idx % 4])
	for i in range(SPAWN_TRIES_PER_DAY):
		if _active_fronts.size() >= MAX_FRONTS:
			break
		if _rng.randf() < spawn_prob:
			var f: WeatherFront
			if _emergent_coupling:
				f = _spawn_emergent_front(map, world, season_idx, climate_anomaly)
			else:
				f = _spawn_random_front(world, season_idx, climate_anomaly)
			if f != null:
				_active_fronts.append(f)
	var spawn_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 4) 把当前所有 front 影响分发到每个 cell
	t_us0 = Time.get_ticks_usec()
	_distribute_to_cells(map)
	var distribute_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 5) Systemic Ocean Currents：台风尾迹扰动（可选，默认关闭）
	# 在强海上风暴（STORM + on_water + intensity > 0.8）点注入旋转扰动向量，
	# 随后每天线性衰减，_cyclone_wake_days 后清零。仅 CPU 端维护；渲染消费方
	# 可按需扩展（例如上传 RG8 overlay 让 shader 与主流场相加）。
	var cyclone_ms: float = 0.0
	if _cyclone_wake_enabled:
		t_us0 = Time.get_ticks_usec()
		_tick_cyclone_wake(map)
		cyclone_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	_last_breakdown = {
		"advance_ms": advance_ms,
		"spawn_ms": spawn_ms,
		"distribute_ms": distribute_ms,
		"cyclone_ms": cyclone_ms,
	}
	_current_map_for_tick = null
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
	# Phase E（方案 A）：寿命整体 ~×2，decay 减半。短命类型（STORM/FOG/BLIZZARD）
	# 在快推进档位下原本 2~4 天就消失，肉眼上是"突现突灭"；现在 RAIN ~14 天、
	# STORM ~9 天、FOG ~8 天、BLIZZARD ~12 天，配合更慢衰减让强度曲线变缓，
	# 表现层有充足时间做 birth/dissolve 渐变。DROUGHT/HEATWAVE 已是长寿命，
	# 仅微调以维持相对比例。
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = _rng.randi_range(30, 56)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = _rng.randi_range(12, 22)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			front.ttl_days = _rng.randi_range(6, 11)
			front.decay_per_day = 0.10
		WeatherType.WT.BLIZZARD:
			front.ttl_days = _rng.randi_range(8, 14)
			front.decay_per_day = 0.08
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			front.ttl_days = _rng.randi_range(10, 16)
			front.decay_per_day = 0.07
	# 初始速度沿当前 spawn 点风向
	# Phase D：与 wind_fn 同源——叠加当季 monsoon 偏置，让新生 MONSOON front
	# 一出生就朝向真正的当季季风方向，而不是夏季基线方向。
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((sy - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = _sample_terrain_wind(_map_for_spawn(world), world, spawn_pos, ny_spawn, _season_phase)
	if wind.length() > 0.05:
		var wind_axis := wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		# Phase E（方案 A）：把每天行进距离从 0.4×radius 提到 0.65×radius。
		# 配合寿命翻倍，front 总位移从 ~2×radius 提到 ~5×radius，
		# 视觉上是“持续飘过来再飘过去”，而不是“原地附近晃动”。
		front.velocity = wind_axis * (front.radius * 0.65)
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
		# 把 weather 状态写到 current_state（weather/intensity 仍是离散字段，保留字典）
		cell.current_state["weather"] = wt
		cell.current_state["weather_intensity"] = intensity
		# 应用临时湿度 / 温度扰动（不写回 base_*）
		# Fast-tick perf opt (C)：moisture / temperature 已升级为强类型成员，直接读写。
		var moist_now: float = cell.moisture
		var temp_now: float = cell.temperature
		moist_now = clampf(moist_now + WeatherType.moisture_delta(wt) * intensity, 0.0, 1.0)
		temp_now = clampf(temp_now + WeatherType.temp_delta(wt) * intensity, 0.0, 1.0)
		cell.moisture = moist_now
		cell.temperature = temp_now
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

func _solve_weather_field(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> void:
	var cells: Array = map.all_cells()
	var prev_vapor: Dictionary = {}
	var prev_precip: Dictionary = {}
	for cell: HexCell in cells:
		var prev: Dictionary = _weather_field.get(cell, {})
		prev_vapor[cell] = float(prev.get("vapor", cell.moisture))
		prev_precip[cell] = float(prev.get("precip", 0.0))

	var next_field: Dictionary = {}
	for cell: HexCell in cells:
		var pos: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		var temp: float = clampf(cell.temperature + climate_anomaly + cell.air_mass_temp_anomaly, 0.0, 1.0)
		var base_m: float = clampf(cell.moisture, 0.0, 1.0)
		var ocean_an: float = _avg_ocean_anomaly_at(cell, map)
		var on_water: bool = _is_water_terrain(int(cell.terrain))

		var wind: Vector2 = cell.wind_vector
		if wind.length_squared() < 0.0001:
			var ny: float = 0.5
			if _world_bounds.size.y > 0.001:
				ny = clampf((pos.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0)
			wind = _sample_terrain_wind(map, world, pos, ny, _season_phase)
		var wind_dir: Vector2 = wind.normalized() if wind.length_squared() > 0.0001 else Vector2.RIGHT

		var advected_vapor: float = _upstream_vapor(cell, map, prev_vapor, wind_dir)
		var neighbor_vapor: float = _neighbor_average_vapor(cell, map, prev_vapor)
		var vapor: float = lerpf(base_m, advected_vapor, 0.48)
		vapor = lerpf(vapor, neighbor_vapor, _field_diffusion)

		var evap: float = _evaporation_for_cell(cell, map, temp, base_m, ocean_an, on_water)
		vapor = clampf(vapor + evap, 0.0, 1.0)

		var lift: float = _orographic_lift_for_cell(cell, map, wind_dir)
		var convergence: float = _wind_convergence_for_cell(cell, map)
		if lift < 0.0:
			vapor = clampf(vapor + lift * 0.22, 0.0, 1.0)

		var saturation: float = clampf(0.40 + temp * 0.30, 0.34, 0.76)
		var humid_excess: float = maxf(vapor - saturation, 0.0)
		var cloud: float = clampf(
			humid_excess * _field_condensation_gain * 3.0
			+ maxf(lift, 0.0) * _field_orographic_lift_gain
			+ convergence * _field_convergence_gain
			+ maxf(ocean_an, 0.0) * 0.18,
			0.0, 1.0
		)
		var instability: float = clampf(
			(temp - 0.45) * 1.15
			+ vapor * 0.55
			+ cloud * 0.35
			+ convergence * _field_convergence_gain
			+ maxf(lift, 0.0) * _field_orographic_lift_gain
			+ maxf(ocean_an, 0.0) * 0.25,
			0.0, 1.0
		)
		var precip_raw: float = cloud * (0.30 + instability * 0.70) + maxf(lift, 0.0) * 0.18 - maxf(-lift, 0.0) * 0.45
		var old_precip: float = float(prev_precip.get(cell, 0.0))
		var precip: float = clampf(maxf(precip_raw, old_precip * (1.0 - _field_precip_decay)), 0.0, 1.0)

		var wt: int = _classify_field_weather(cell, season_idx, temp, vapor, cloud, precip, instability, ocean_an)
		var intensity: float = _field_intensity_for_type(wt, temp, vapor, cloud, precip, instability, ocean_an)
		next_field[cell] = {
			"vapor": vapor,
			"cloud": cloud,
			"precip": precip,
			"instability": instability,
			"type": wt,
			"intensity": intensity,
		}
	_weather_field = next_field

func _upstream_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary, wind_dir: Vector2) -> float:
	var current: HexCell = cell
	var sum_v: float = float(prev_vapor.get(cell, cell.moisture))
	var weight: float = 1.0
	for step in range(_field_advect_steps):
		var upstream: HexCell = _neighbor_aligned(current, map, -wind_dir)
		if upstream == null:
			break
		var w: float = 1.0 / float(step + 2)
		sum_v += float(prev_vapor.get(upstream, upstream.moisture)) * w
		weight += w
		current = upstream
	return sum_v / maxf(weight, 0.001)

func _neighbor_average_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary) -> float:
	var sum_v: float = float(prev_vapor.get(cell, cell.moisture))
	var n: int = 1
	for nb: HexCell in map.get_neighbors(cell):
		if nb == null:
			continue
		sum_v += float(prev_vapor.get(nb, nb.moisture))
		n += 1
	return sum_v / float(maxi(n, 1))

func _evaporation_for_cell(cell: HexCell, map: MapData, temp: float, moisture: float, ocean_an: float, on_water: bool) -> float:
	var evap: float = 0.028 if on_water else 0.006
	evap += maxf(moisture - 0.45, 0.0) * 0.018
	evap += _vegetation_transpiration_factor(cell) * 0.012
	if not on_water:
		for nb: HexCell in map.get_neighbors(cell):
			if nb != null and _is_water_terrain(int(nb.terrain)):
				evap += 0.018
				break
	var ocean_mul: float = clampf(1.0 + _field_ocean_evap_gain * ocean_an, 0.20, 1.80)
	var temp_mul: float = clampf(0.35 + temp * 1.05, 0.12, 1.35)
	return evap * ocean_mul * temp_mul

func _vegetation_transpiration_factor(cell: HexCell) -> float:
	var veg: int = int(cell.vegetation)
	if veg == VegetationType.VEG.NONE:
		return 0.0
	if veg == VegetationType.VEG.TROPICAL_RAINFOREST or veg == VegetationType.VEG.SWAMP or veg == VegetationType.VEG.MANGROVE:
		return 1.0
	if veg == VegetationType.VEG.TEMPERATE_DECIDUOUS or veg == VegetationType.VEG.TAIGA or veg == VegetationType.VEG.SUBTROPICAL_FOREST:
		return 0.65
	if veg == VegetationType.VEG.TEMPERATE_GRASSLAND or veg == VegetationType.VEG.SAVANNA or veg == VegetationType.VEG.MARSH:
		return 0.35
	return 0.18

func _orographic_lift_for_cell(cell: HexCell, map: MapData, wind_dir: Vector2) -> float:
	var upstream: HexCell = _neighbor_aligned(cell, map, -wind_dir)
	if upstream == null:
		return 0.0
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0

func _wind_convergence_for_cell(cell: HexCell, map: MapData) -> float:
	var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	var incoming: float = 0.0
	var checked: int = 0
	for nb: HexCell in map.get_neighbors(cell):
		if nb == null:
			continue
		var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _hex_size)
		var dir_to_self: Vector2 = self_wp - nb_wp
		if dir_to_self.length_squared() <= 0.0001:
			continue
		var wind: Vector2 = nb.wind_vector
		if wind.length_squared() <= 0.0001:
			continue
		incoming += maxf(0.0, dir_to_self.normalized().dot(wind.normalized()))
		checked += 1
	if checked == 0:
		return 0.0
	return clampf(incoming / float(checked), 0.0, 1.0)

func _neighbor_aligned(cell: HexCell, map: MapData, dir: Vector2) -> HexCell:
	if cell == null or map == null or dir.length_squared() <= 0.0001:
		return null
	var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	var best: HexCell = null
	var best_dot: float = 0.18
	var ndir: Vector2 = dir.normalized()
	for nb: HexCell in map.get_neighbors(cell):
		if nb == null:
			continue
		var nb_wp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _hex_size)
		var to_nb: Vector2 = nb_wp - self_wp
		if to_nb.length_squared() <= 0.0001:
			continue
		var d: float = to_nb.normalized().dot(ndir)
		if d > best_dot:
			best_dot = d
			best = nb
	return best

func _classify_field_weather(cell: HexCell, season_idx: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> int:
	var lat_abs: float = 0.5
	if _world_bounds.size.y > 0.001:
		var pos: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		lat_abs = absf(clampf((pos.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0) * 2.0 - 1.0)
	var warm: bool = temp > 0.58
	var cold: bool = temp < 0.32
	var humid: bool = vapor > 0.55
	var summerish: bool = (season_idx % 4) == 1
	var low_lat: bool = lat_abs < 0.48

	if cold and (precip > 0.18 or (cloud > 0.48 and vapor > 0.56)):
		return WeatherType.WT.BLIZZARD
	if warm and humid and instability > 0.68 and precip > 0.30:
		return WeatherType.WT.STORM
	if warm and humid and low_lat and (summerish or _season_phase > 0.75 and _season_phase < 2.25) and precip > 0.24:
		return WeatherType.WT.MONSOON
	if precip > 0.20 or (cloud > 0.54 and vapor > 0.52):
		return WeatherType.WT.RAIN
	if vapor > 0.58 and cloud > 0.28 and precip < 0.15 and temp < 0.50:
		return WeatherType.WT.FOG
	if temp > 0.73 and vapor < 0.35 and cloud < 0.20:
		return WeatherType.WT.HEATWAVE
	if vapor < 0.30 and cloud < 0.14 and (temp > 0.52 or ocean_an < -0.08):
		return WeatherType.WT.DROUGHT
	return WeatherType.WT.CLEAR

func _field_intensity_for_type(wt: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> float:
	match wt:
		WeatherType.WT.STORM:
			return clampf(maxf(precip, instability) * 0.82 + cloud * 0.18, 0.0, 1.0)
		WeatherType.WT.MONSOON:
			return clampf(precip * 0.72 + vapor * 0.18 + cloud * 0.18, 0.0, 1.0)
		WeatherType.WT.RAIN, WeatherType.WT.BLIZZARD:
			return clampf(precip * 0.78 + cloud * 0.30, 0.0, 1.0)
		WeatherType.WT.FOG:
			return clampf(cloud * 0.75 + vapor * 0.20, 0.0, 1.0)
		WeatherType.WT.HEATWAVE:
			return clampf((temp - 0.65) * 2.2 + maxf(0.32 - vapor, 0.0), 0.0, 1.0)
		WeatherType.WT.DROUGHT:
			return clampf((0.35 - vapor) * 2.0 + (0.16 - cloud) + maxf(-ocean_an, 0.0) * 0.6, 0.0, 1.0)
	return 0.0

func _distribute_weather_field_to_cells(map: MapData) -> void:
	_cover_dirty = false
	for cell: HexCell in map.all_cells():
		var f: Dictionary = _weather_field.get(cell, {})
		var wt: int = int(f.get("type", WeatherType.WT.CLEAR))
		var intensity: float = float(f.get("intensity", 0.0))
		var cloud: float = float(f.get("cloud", 0.0))
		var precip: float = float(f.get("precip", 0.0))
		var vapor: float = float(f.get("vapor", cell.moisture))
		var instability: float = float(f.get("instability", 0.0))
		cell.current_state["weather"] = wt
		cell.current_state["weather_intensity"] = intensity
		cell.current_state["weather_cloud"] = cloud
		cell.current_state["weather_precip"] = precip
		cell.current_state["weather_vapor"] = vapor
		cell.current_state["weather_instability"] = instability

		var moist_now: float = clampf(cell.moisture + WeatherType.moisture_delta(wt) * intensity, 0.0, 1.0)
		var temp_now: float = clampf(cell.temperature + WeatherType.temp_delta(wt) * intensity, 0.0, 1.0)
		cell.moisture = moist_now
		cell.temperature = temp_now

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

func _build_field_summary_fronts(map: MapData, world: WorldData) -> Array[WeatherFront]:
	var components: Array = []
	var visited: Dictionary = {}
	for seed: HexCell in map.all_cells():
		if visited.has(seed):
			continue
		var sf: Dictionary = _weather_field.get(seed, {})
		var wt: int = int(sf.get("type", WeatherType.WT.CLEAR))
		var intensity: float = float(sf.get("intensity", 0.0))
		if intensity < 0.18 or wt == WeatherType.WT.CLEAR:
			visited[seed] = true
			continue
		var queue: Array = [seed]
		visited[seed] = true
		var cells: Array = []
		var sum_pos := Vector2.ZERO
		var sum_axis := Vector2.ZERO
		var sum_cloud: float = 0.0
		var sum_precip: float = 0.0
		var max_i: float = 0.0
		while not queue.is_empty():
			var cell: HexCell = queue.pop_front()
			var cf: Dictionary = _weather_field.get(cell, {})
			var cwt: int = int(cf.get("type", WeatherType.WT.CLEAR))
			var ci: float = float(cf.get("intensity", 0.0))
			if cwt != wt or ci < 0.18:
				continue
			cells.append(cell)
			sum_pos += HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
			sum_axis += cell.wind_vector
			sum_cloud += float(cf.get("cloud", 0.0))
			sum_precip += float(cf.get("precip", 0.0))
			max_i = maxf(max_i, ci)
			for nb: HexCell in map.get_neighbors(cell):
				if nb == null or visited.has(nb):
					continue
				var nf: Dictionary = _weather_field.get(nb, {})
				if int(nf.get("type", WeatherType.WT.CLEAR)) == wt and float(nf.get("intensity", 0.0)) >= 0.18:
					visited[nb] = true
					queue.append(nb)
		if cells.is_empty():
			continue
		var count: float = float(cells.size())
		components.append({
			"type": wt,
			"center": sum_pos / count,
			"axis": sum_axis / count,
			"cloud": sum_cloud / count,
			"precip": sum_precip / count,
			"intensity": max_i,
			"area": cells.size(),
			"score": max_i * sqrt(count),
		})
	components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var limit: int = mini(_field_summary_limit, components.size())
	for i in range(limit):
		var c: Dictionary = components[i]
		var front := WeatherFront.new()
		front.type = int(c.get("type", WeatherType.WT.CLEAR))
		front.center = c.get("center", Vector2.ZERO)
		front.intensity = clampf(float(c.get("intensity", 0.0)), 0.0, 1.0)
		front.radius = _hex_size * (1.35 + sqrt(float(c.get("area", 1))) * 0.78)
		var axis: Vector2 = c.get("axis", Vector2.RIGHT)
		if axis.length_squared() <= 0.0001:
			axis = Vector2.RIGHT
		front.axis = axis.normalized()
		front.stable_axis = front.axis
		front.major_scale = 1.10
		front.minor_scale = 0.92
		front.ttl_days = 2
		front.age_days = 0
		front.decay_per_day = 0.0
		front.edge_seed = float((i + 1) * 37 + int(front.center.x) * 3 + int(front.center.y) * 5)
		front.cloud_amount = clampf(float(c.get("cloud", 0.0)), 0.0, 1.0)
		front.precip_amount = clampf(float(c.get("precip", 0.0)), 0.0, 1.0)
		front.dissolve_amount = 0.0
		front.life_progress = 0.2
		fronts.append(front)
	return fronts

func has_cover_dirty() -> bool:
	return _cover_dirty

# --- 查询接口（给 UI / 其他子系统） ---
# 返回 { "type": int(WT), "intensity": float [0,1] }；max-merge：取覆盖到该点的最强 front。
func query_at(world_pos: Vector2) -> Dictionary:
	if _weather_field_enabled:
		var map_ref: MapData = _current_map_for_tick if _current_map_for_tick != null else _last_map_for_query
		if map_ref != null:
			var cube := HexUtils.world_to_cube(world_pos, _hex_size)
			var cell: HexCell = map_ref.get_cell_by_cube(cube)
			if cell != null and _weather_field.has(cell):
				var f: Dictionary = _weather_field[cell]
				return {
					"type": int(f.get("type", WeatherType.WT.CLEAR)),
					"intensity": float(f.get("intensity", 0.0)),
					"cloud": float(f.get("cloud", 0.0)),
					"precip": float(f.get("precip", 0.0)),
					"vapor": float(f.get("vapor", 0.0)),
					"instability": float(f.get("instability", 0.0)),
				}
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

# ─── Systemic Ocean Currents：台风尾迹扰动（可选） ──────────────────────

# 由外部在初始化时调用，把 MapConfig.enable_cyclone_wake / CYCLONE_WAKE_DAYS 写入。
func configure_cyclone_wake(enabled: bool, wake_days: int) -> void:
	_cyclone_wake_enabled = enabled
	_cyclone_wake_days = max(1, wake_days)
	if not enabled:
		ocean_current_perturbation.clear()

# Emergent Climate Coupling：由 MapGenerator 在 refresh_daily 之前调用。
# 启用时 tick_one_day 内会做 4 项耦合：
#   1. 推进前按 front 中心 cell 的 local 状态调整本日 decay_per_day（类型匹配 ×0.7、不匹配 ×1.5）
#   2. 推进时如经过山脉迎风坡：本格 precip 强度叠加；经过背风坡：额外衰减
#   3. spawn 概率按本地 1 环温湿梯度加权（梯度大处更易生成 front）
#   4. spawn 类型由 (本地温度带, 湿度带, season_phase) 三者联合决定
# 关闭时所有耦合行为退回旧的均匀/季节硬切路径（兼容回退）。
func configure_emergent_coupling(enabled: bool, rain_shadow_threshold: float, rain_shadow_factor: float, orographic_boost: float) -> void:
	_emergent_coupling = enabled
	_emergent_rain_shadow_threshold = rain_shadow_threshold
	_emergent_rain_shadow_factor = rain_shadow_factor
	_emergent_orographic_boost = orographic_boost

# v11 由 MapGenerator 在初始化时推送。控制 advect / spawn 是否优先采样
# HexCell.wind_vector（地形扰动后的实际风）。
func configure_terrain_wind(enabled: bool) -> void:
	_use_wind_vector_for_advect = enabled

# Ocean spawn bias：由 MapGenerator 在 init/refresh_daily 推送 ClimateProfile
# 中的 ocean_weather_spawn_bias。0 = 关闭（legacy 行为），>0 = 寒流海岸抑制
# 降水类天气 spawn、暖流海岸促进。详见 _spawn_emergent_front 内的偏置公式。
func configure_ocean_spawn_bias(bias: float) -> void:
	_ocean_spawn_bias = maxf(0.0, bias)

func configure_weather_field(
		enabled: bool,
		advect_steps: int,
		diffusion: float,
		condensation_gain: float,
		precip_decay: float,
		orographic_lift_gain: float,
		convergence_gain: float,
		ocean_evap_gain: float,
		summary_limit: int) -> void:
	_weather_field_enabled = enabled
	_field_advect_steps = clampi(advect_steps, 0, 6)
	_field_diffusion = clampf(diffusion, 0.0, 0.5)
	_field_condensation_gain = maxf(0.0, condensation_gain)
	_field_precip_decay = clampf(precip_decay, 0.0, 1.0)
	_field_orographic_lift_gain = maxf(0.0, orographic_lift_gain)
	_field_convergence_gain = maxf(0.0, convergence_gain)
	_field_ocean_evap_gain = maxf(0.0, ocean_evap_gain)
	_field_summary_limit = clampi(summary_limit, 1, MAX_FRONTS)
	if not enabled:
		_weather_field.clear()

# v11 风场采样统一入口：
#   - 开关为 true 且能反查到 cell 且 cell.wind_vector 足够大 → 直接返回 cell.wind_vector。
#     这是地形扰动后的 per-cell 实际风，本身已含山脈绕流与海岸热力加速，
#     另外包含了费老的季节偏移资源 → 不再叠加 monsoon offset（避免双重叠加）。
#   - fallback（开关为 false / 反查失败 / wind_vector 太小）
#     走旧路径 world.sample_wind(pos) + WindBelt.monsoon_offset_at(ny, season_phase)。
func _sample_terrain_wind(map: MapData, world: WorldData, world_pos: Vector2, ny: float, season_phase: float) -> Vector2:
	if _use_wind_vector_for_advect and map != null:
		var cube := HexUtils.world_to_cube(world_pos, _hex_size)
		var cell: HexCell = map.get_cell_by_cube(cube)
		if cell != null:
			var wv: Vector2 = cell.wind_vector
			if wv.length() > 0.01:
				return wv
	var base: Vector2 = world.sample_wind(world_pos)
	return base + WindBelt.monsoon_offset_at(ny, season_phase)

# spawn 路径（_spawn_random_front / _build_front_at）复用 _current_map_for_tick 取 map
# 引用；if tick 未运行（外部直接调 _build_front_at）则返回 null → _sample_terrain_wind
# 会优雅 fallback。
func _map_for_spawn(_world: WorldData) -> MapData:
	return _current_map_for_tick

# 只读查询：返回某 cell 当前的扰动向量（无则 Vector2.ZERO）。给航运 AI / 未来 shader 上传用。
func cell_perturbation(cell: HexCell) -> Vector2:
	if cell == null:
		return Vector2.ZERO
	var key: int = cell.q * 10000 + cell.r
	if not ocean_current_perturbation.has(key):
		return Vector2.ZERO
	var d: Dictionary = ocean_current_perturbation[key]
	return d.get("vec", Vector2.ZERO)

# 每日推进：
#   1) 对已有扰动 days_left - 1，days_left <= 0 则移除；
#      vec 幅度按 days_left / init_days 线性衰减。
#   2) 遍历当前活跃 front，找 STORM + on_water + intensity > 0.8 的"强海上风暴"，
#      在其中心 cell 注入旋转扰动（与风速正交，按 intensity 缩放）。
func _tick_cyclone_wake(map: MapData) -> void:
	# 1) 衰减 / 移除
	var to_remove: Array = []
	for key in ocean_current_perturbation.keys():
		var d: Dictionary = ocean_current_perturbation[key]
		var days_left: int = int(d.get("days_left", 0)) - 1
		if days_left <= 0:
			to_remove.append(key)
			continue
		var init_days: int = int(d.get("init_days", _cyclone_wake_days))
		var scale: float = float(days_left) / float(maxi(init_days, 1))
		var vec0: Vector2 = d.get("vec_init", d.get("vec", Vector2.ZERO))
		d["days_left"] = days_left
		d["vec"] = vec0 * scale
		ocean_current_perturbation[key] = d
	for key in to_remove:
		ocean_current_perturbation.erase(key)

	# 2) 注入新的扰动（基于当前活跃 front）
	for front in _active_fronts:
		if front.type != WeatherType.WT.STORM:
			continue
		if front.intensity < 0.8:
			continue
		# 找 front 中心所在 cell
		var center := front.center
		var cube := HexUtils.world_to_cube(center, _hex_size)
		var cell: HexCell = map.get_cell_by_cube(cube)
		if cell == null:
			continue
		# 仅海面 cell 注入
		if not _is_water_terrain(int(cell.terrain)):
			continue
		# 扰动向量：风向顺时针旋 90° 得切向，按 intensity 缩放到 [-0.6, 0.6] 范围
		var wind: Vector2 = front.velocity
		if wind.length_squared() < 1e-4:
			wind = Vector2(1.0, 0.0)
		var tangent := Vector2(-wind.y, wind.x).normalized()
		var perturb := tangent * front.intensity * 0.6
		var key2: int = cell.q * 10000 + cell.r
		ocean_current_perturbation[key2] = {
			"vec": perturb,
			"vec_init": perturb,
			"days_left": _cyclone_wake_days,
			"init_days": _cyclone_wake_days,
		}

static func _is_water_terrain(t: int) -> bool:
	return t == TerrainType.TERRAIN.OCEAN \
			or t == TerrainType.TERRAIN.COAST \
			or t == TerrainType.TERRAIN.REEF \
			or t == TerrainType.TERRAIN.KELP \
			or t == TerrainType.TERRAIN.SEA_ICE \
			or t == TerrainType.TERRAIN.LAKE

# ─── Emergent Climate Coupling：本地耦合辅助函数 ────────────────────────

# 按 front 类型 vs 当前 cell 温湿带的匹配度返回衰减倍率：
#   匹配 → 0.7（长寿命，例如 RAIN 走暖湿海岸）
#   中性 → 1.0
#   不匹配 → 1.5（例如 STORM 走干冷沙漠、BLIZZARD 走暖带）
func _front_decay_modifier(front: WeatherFront, cell: HexCell) -> float:
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

# 迎风坡降水加成 / 背风坡额外衰减：
#   沿 front.velocity 方向找上风 cell：若上风 cell 海拔比本格高出阈值 → 迎风坡（返回正 bonus）
#   若本格海拔比上风 cell 高出阈值 → 背风坡（返回负 bonus，作衰减）
# 仅对降水型 front 生效（RAIN / STORM / MONSOON / BLIZZARD）。
func _front_orographic_precip_bonus(front: WeatherFront, cell: HexCell, map: MapData) -> float:
	var t: int = front.type
	if t != WeatherType.WT.RAIN and t != WeatherType.WT.STORM \
	and t != WeatherType.WT.MONSOON and t != WeatherType.WT.BLIZZARD:
		return 0.0
	var v: Vector2 = front.velocity
	if v.length_squared() < 1e-6:
		return 0.0
	# 从本格向上风（-v）方向找最对齐邻居
	var w_dir: Vector2 = -v.normalized()
	var self_wp: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	var best_nb: HexCell = null
	var best_dot: float = 0.1
	for nb: HexCell in map.get_neighbors(cell):
		if nb == null:
			continue
		var nbwp: Vector2 = HexUtils.cube_to_world(nb.q, nb.r, _hex_size)
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
	if h_diff < -_emergent_rain_shadow_threshold:
		# 本格比上风低很多 → 迎风爬坡 → 加成
		return 0.08 * _emergent_orographic_boost
	if h_diff > _emergent_rain_shadow_threshold:
		# 本格比上风高很多 → 背风 → 衰减（通过负 bonus 在分发时减少降水）
		return -0.08
	return 0.0

# Emergent spawn：按本地 1 环温湿梯度加权抽 1 个 cell 作为 spawn 源，
# 类型由 (本地温度带 × 湿度带 × season_phase) 联合决定。
func _spawn_emergent_front(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> WeatherFront:
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
		var c: HexCell = all_cells[_rng.randi_range(0, all_cells.size() - 1)]
		if c == null:
			continue
		var w: float = _local_temp_moist_gradient(c, map) + 0.05  # 底噪避免全 0
		# Ocean spawn bias：寒流邻水抑制候选 cell 的 spawn 权重，暖流提升。
		# 仅对陆地 / 海岸有 ≥1 个水域邻居的 cell 生效；远海面与内陆不变。
		# 偏置因子整体作用于"权重通道"，与具体 weather type 无关；
		# 类型抑制（寒流海岸 RAIN→CLEAR 之类）由 _pick_weather_type_emergent
		# 内部独立处理，避免双重惩罚。
		if _ocean_spawn_bias > 0.0:
			var w_mul: float = _ocean_weight_multiplier(c, map)
			w *= w_mul
		cands.append(c)
		weights.append(w)
		total_w += w
	if total_w <= 0.001 or cands.is_empty():
		return null
	var pick: float = _rng.randf() * total_w
	var acc: float = 0.0
	for i in range(cands.size()):
		acc += float(weights[i])
		if pick <= acc:
			best_cell = cands[i]
			break
	if best_cell == null:
		return null
	# Step 2：用该 cell 的温湿 + season_phase 决定类型
	var wt: int = _pick_weather_type_emergent(best_cell, season_idx, climate_anomaly, map)
	if wt == WeatherType.WT.CLEAR:
		return null
	# Step 3：复用 _spawn_random_front 的参数化流程，但强制 spawn 位置为 best_cell 的世界坐标
	var spawn_pos: Vector2 = HexUtils.cube_to_world(best_cell.q, best_cell.r, _hex_size)
	return _build_front_at(spawn_pos, wt, world)

# 本地 1 环温湿梯度最大值（温度差 + 湿度差取 max）
func _local_temp_moist_gradient(cell: HexCell, map: MapData) -> float:
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var t0: float = cell.temperature
	var m0: float = cell.moisture
	var max_dt: float = 0.0
	var max_dm: float = 0.0
	for nb: HexCell in map.get_neighbors(cell):
		if nb == null:
			continue
		var dt: float = absf(nb.temperature - t0)
		var dm: float = absf(nb.moisture - m0)
		if dt > max_dt: max_dt = dt
		if dm > max_dm: max_dm = dm
	return maxf(max_dt, max_dm)

# 由本地温度带/湿度带 + season_phase 决定 front 类型。
# 规则（Plan B 日历对齐：本地夏 = 各半球本地 hemi_phase ≈ 1）：
#   暖湿陆地 + 本地夏 → STORM
#   寒冷海面          → BLIZZARD
#   暖干陆地 + 本地夏 → HEATWAVE
#   暖干陆地 + 非本地夏 → DROUGHT
#   寒湿 / 暖湿海岸   → RAIN
#   低温湿 + 本地秋冬  → FOG
# 其余返回 CLEAR（不 spawn）。
func _pick_weather_type_emergent(cell: HexCell, season_idx: int, climate_anomaly: float, map: MapData = null) -> int:
	# Fast-tick perf opt (C)：temperature / moisture 已升级为强类型成员，直接读。
	var t: float = cell.temperature + climate_anomaly
	var m: float = cell.moisture
	# Plan B：按 cell 所在半球把全局 season_phase 映射为 "本地季节 phase"
	# (本地春=0, 本地夏=1, 本地秋=2, 本地冬=3)；赤道按北半球近似。
	var cell_world: Vector2 = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
	var lat_norm: float = 0.5
	if _world_bounds.size.y > 0.001:
		lat_norm = clampf((cell_world.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0)
	var lat_signed: float = lat_norm * 2.0 - 1.0
	var phase: float
	if lat_signed < 0.0:
		phase = fposmod(_season_phase - 1.0, 4.0)  # 北半球
	else:
		phase = fposmod(_season_phase + 1.0, 4.0)  # 南半球（含赤道）
	var is_summer: bool = (phase >= 0.5 and phase < 1.5)
	var is_winter: bool = (phase >= 2.5 and phase < 3.5)
	var on_water: bool = _is_water_terrain(int(cell.terrain))
	var warm: bool = t > 0.55
	var cold: bool = t < 0.30
	var humid: bool = m > 0.55
	var dry: bool = m < 0.35

	if on_water:
		if cold:
			return WeatherType.WT.BLIZZARD
		# 暖湿海面：STORM（台风/热带风暴）
		if warm and humid:
			return _ocean_filter_precip(cell, map, WeatherType.WT.STORM)
		return _ocean_filter_precip(cell, map, WeatherType.WT.RAIN)
	# 陆地路径
	if warm and humid and is_summer:
		return _ocean_filter_precip(cell, map, WeatherType.WT.STORM)
	if warm and dry:
		if is_summer:
			return WeatherType.WT.HEATWAVE
		return WeatherType.WT.DROUGHT
	if cold and (is_winter or phase < 0.3):
		return WeatherType.WT.BLIZZARD
	if humid:
		# 暖湿陆地（非夏）→ RAIN；低纬夏季内陆湿带 → MONSOON
		if warm and is_summer and m > 0.65:
			return _ocean_filter_precip(cell, map, WeatherType.WT.MONSOON)
		return _ocean_filter_precip(cell, map, WeatherType.WT.RAIN)
	# 低温中湿 + 秋冬 → FOG
	if t < 0.45 and m > 0.40 and (phase > 1.8):
		return WeatherType.WT.FOG
	return WeatherType.WT.CLEAR

# Ocean spawn bias helpers：当 _ocean_spawn_bias > 0 时启用。
# 实现"洋流温度异常 → 沿岸天气事件偏置"通路：
#   - 寒流海岸（邻水 anomaly < 0）→ 抑制 RAIN/STORM/MONSOON 的 spawn 权重
#     与类型保留概率，让寒流海岸沙漠在天气层也表现为"少雨多雾"。
#   - 暖流海岸（邻水 anomaly > 0）→ 同类型权重提升，模拟湾流型多雨气候。
#   - 内陆 cell（无水邻居）与远海面（cell 自身就是水）→ 无影响。
#   - BLIZZARD/FOG/HEATWAVE/DROUGHT 不受影响（与"降水/对流"无直接因果）。

# 候选 cell 的 spawn 权重乘子：> 1 表示更易被抽中、< 1 表示更难。
# 仅对"邻水 ≥ 1 的陆地 / 海岸"生效。范围 clamp 到 [0.1, 1 + bias]。
func _ocean_weight_multiplier(cell: HexCell, map: MapData) -> float:
	if cell == null or map == null or _ocean_spawn_bias <= 0.0:
		return 1.0
	var avg_an: float = _avg_ocean_anomaly_at(cell, map)
	if absf(avg_an) < 0.005:
		return 1.0
	# bias × anomaly 直接影响乘子。anomaly ∈ ~[-0.3, +0.3]，bias 1.2 →
	# 寒流极端 ×0.64 / 暖流极端 ×1.36；clamp 防止退化为 0。
	var mul: float = 1.0 + _ocean_spawn_bias * avg_an
	return clampf(mul, 0.1, 1.0 + _ocean_spawn_bias)

# 寒流海岸 RAIN/STORM/MONSOON → CLEAR/FOG 软降级；暖流海岸不动作。
# 用累计概率：寒流强度越大、邻水占比越高，降级概率越大。
func _ocean_filter_precip(cell: HexCell, map: MapData, wt: int) -> int:
	if map == null or _ocean_spawn_bias <= 0.0:
		return wt
	var avg_an: float = _avg_ocean_anomaly_at(cell, map)
	if avg_an >= -0.01:
		return wt  # 不冷或暖流 → 不动
	# 降级概率 = bias × |anomaly|，clamp [0, 0.85]。
	var p_demote: float = clampf(_ocean_spawn_bias * (-avg_an), 0.0, 0.85)
	if _rng.randf() < p_demote:
		# 极冷（|anomaly| 大）→ FOG；中冷 → CLEAR。让"沿岸冷雾"在寒流海岸涌现。
		if -avg_an > 0.15:
			return WeatherType.WT.FOG
		return WeatherType.WT.CLEAR
	return wt

# 取 cell 1 环邻水的平均 temperature_transport_anomaly。无水邻居返回 0。
# 海面 cell 直接返回自身 anomaly（因为本身就是洋流体）。
func _avg_ocean_anomaly_at(cell: HexCell, map: MapData) -> float:
	if cell == null or map == null:
		return 0.0
	# 海面 cell：直接读自身洋流偏差
	if _is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	for nb: HexCell in map.get_neighbors(cell):
		if nb != null and _is_water_terrain(int(nb.terrain)):
			sum_an += nb.temperature_transport_anomaly
			n_water += 1
	if n_water == 0:
		return 0.0
	return sum_an / float(n_water)

# 基于给定 spawn_pos + 类型 wt 构造 front（从 _spawn_random_front 提炼），
# 避免重复类型抽样逻辑。
func _build_front_at(spawn_pos: Vector2, wt: int, world: WorldData) -> WeatherFront:
	var front := WeatherFront.new()
	front.center = spawn_pos
	front.type = wt
	front.intensity = _rng.randf_range(0.55, 1.0)
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
	# Phase E（方案 A）：与 _spawn_random_front 同步——寿命 ~×2、decay 减半。
	match wt:
		WeatherType.WT.DROUGHT:
			front.ttl_days = _rng.randi_range(30, 56)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.8
		WeatherType.WT.HEATWAVE:
			front.ttl_days = _rng.randi_range(12, 22)
			front.decay_per_day = 1.0 / float(front.ttl_days) * 0.9
		WeatherType.WT.STORM, WeatherType.WT.MONSOON:
			front.ttl_days = _rng.randi_range(6, 11)
			front.decay_per_day = 0.10
		WeatherType.WT.BLIZZARD:
			front.ttl_days = _rng.randi_range(8, 14)
			front.decay_per_day = 0.08
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			front.ttl_days = _rng.randi_range(10, 16)
			front.decay_per_day = 0.07
	var origin := _world_bounds.position
	var size := _world_bounds.size
	var ny_spawn: float = 0.5
	if size.y > 0.001:
		ny_spawn = clampf((spawn_pos.y - origin.y) / size.y, 0.0, 1.0)
	var wind: Vector2 = _sample_terrain_wind(_map_for_spawn(world), world, spawn_pos, ny_spawn, _season_phase)
	if wind.length() > 0.05:
		var wind_axis := wind.normalized()
		front.axis = wind_axis
		front.stable_axis = wind_axis
		# Phase E（方案 A）：行进距离 0.4 → 0.65 倍 radius/天。
		front.velocity = wind_axis * (front.radius * 0.65)
	else:
		var a := _rng.randf_range(0.0, TAU)
		front.axis = Vector2(cos(a), sin(a))
		front.stable_axis = front.axis
	_apply_front_shape_by_type(front)
	front.refresh_visual_lifecycle()
	return front
