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
var _field_advect_steps: int = 1
var _field_diffusion: float = 0.08
var _field_condensation_gain: float = 0.28
# 衰减系数：每天 precip 至少损失这么多比例（max 公式：保留率 = 1 - decay）
# v5：再降到 0.82（保留 18%）+ 强风时几乎全部刷新 → 彻底打破 STORM 持留
var _field_precip_decay: float = 0.82
var _field_orographic_lift_gain: float = 0.35
var _field_convergence_gain: float = 0.25
var _field_convergence_refresh_stride: int = 4
var _field_solve_tick: int = 0
var _field_ocean_evap_gain: float = 0.30
var _field_summary_limit: int = 12
var _weather_field: Dictionary = {}
var _last_map_for_query: MapData = null

var _field_slice_active: bool = false
var _field_slice_map: MapData = null
var _field_slice_world: WorldData = null
var _field_slice_season_idx: int = 0
var _field_slice_climate_anomaly: float = 0.0
var _field_slice_cursor: int = 0
var _field_slice_refresh_convergence: bool = false
var _field_slice_cells: Array = []
var _field_slice_cell_pos: PackedVector2Array = PackedVector2Array()
var _field_slice_neighbor_indices: PackedInt32Array = PackedInt32Array()
var _field_slice_fast_indexed: bool = false
var _field_slice_prev_vapor: PackedFloat32Array = PackedFloat32Array()
var _field_slice_prev_precip: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_vapor: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_cloud: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_precip: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_instability: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_intensity: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_convergence: PackedFloat32Array = PackedFloat32Array()
var _field_slice_next_type: PackedInt32Array = PackedInt32Array()
var _field_slice_solve_ms: float = 0.0
var _field_slice_last_ms: float = 0.0

# v11 在 tick_one_day 期间缓存当前 MapData 引用，供同一 tick 内部的 spawn
# 分支（_spawn_random_front / _build_front_at）复用，避免从调用链中到处透传。
# tick 结束后置 null，不跨帧持有弱引用 → 与旧生命周期一致。
var _current_map_for_tick: MapData = null

# Daily-sim perf instrumentation：tick_one_day 内部分段耗时快照。
# main.gd / map_generator.refresh_daily 可调 last_breakdown() 读取。
# 字段：advance_ms / spawn_ms / distribute_ms / cyclone_ms
var _last_breakdown: Dictionary = {}

# Tick-scoped 预计算缓存：每次 _solve_weather_field 进入时一次性把全图 cell
# 的世界坐标和 1 环邻居数组算好；helper 函数（_neighbor_aligned / _upstream_vapor /
# _wind_convergence_for_cell / _orographic_lift_for_cell / _neighbor_average_vapor /
# _avg_ocean_anomaly_at）通过下面两个 accessor 读取，避免在 ~2400 cell × 多次内层
# 循环里反复调用 HexUtils.cube_to_world() 与 map.get_neighbors()。
# tick 结束时清空，避免跨帧弱引用残留。
var _tick_cell_pos: Dictionary = {}
var _tick_cell_neighbors: Dictionary = {}

# Continuity-fix（2026-05-10）：summary front 的跨 tick 身份继承状态。
# 解决"前沿每 tick 重新出生 + 边界 cell 抖动 → 视觉跳变"的根因。
#   _prev_summary_membership: HexCell → cluster_idx，记录上 tick flood-fill 时
#                              每个 cell 的归属，给本 tick 的阈值滞回（hysteresis）
#                              判定使用——上 tick 在某簇内的 cell 用 0.06 阈值
#                              留在簇里，新加入的需要 ≥ 0.10 才能进簇。
#   _prev_summary_seeds:       Array of {type, center, age, area}，记录上 tick 的
#                              聚合中心，本 tick BFS 时优先以这些点为种子，让
#                              cluster 在 split / merge / 边界漂移下仍保持身份。
# 在 init() 与 setup 路径中清零；每次 _build_field_summary_fronts 末尾刷新。
var _prev_summary_membership: Dictionary = {}
var _prev_summary_seeds: Array = []

# Drift-debug（2026-05-10）：set true 后每次 _build_field_summary_fronts 调用都打印
# 顶 3 个 cluster 的 (type, prev_center → new_center, observed_drift, EMA velocity)。
# 用于诊断"云不会动"——可以直观看到 sim 端是否真的产出了非零 velocity。
# 验证完成后改回 false 关日志。
const DRIFT_DEBUG_LOG: bool = false

func _cell_world_pos(cell: HexCell) -> Vector2:
	if _tick_cell_pos.has(cell):
		return _tick_cell_pos[cell]
	return HexUtils.cube_to_world(cell.q, cell.r, _hex_size)

func _cell_neighbors(cell: HexCell, map: MapData) -> Array:
	if _tick_cell_neighbors.has(cell):
		return _tick_cell_neighbors[cell]
	if map == null:
		return []
	return map.get_neighbors(cell)

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
	# Continuity-fix：换地图/重 init 时必须清掉跨 tick 继承状态，
	# 否则旧地图的 HexCell 弱引用 + 旧 cluster 中心会污染新地图的首帧聚类。
	_prev_summary_membership.clear()
	_prev_summary_seeds.clear()

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
		begin_weather_field_solve(map, world, season_idx, climate_anomaly, _season_phase, false)
		while true:
			var slice_result: Dictionary = run_weather_field_solve_slice(2147483647)
			if bool(slice_result.get("done", true)):
				break
		return commit_weather_field_solve()

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
			# 暴风/季风：原 6-11 天 → 4-8 天，避免单地连下一周
			front.ttl_days = _rng.randi_range(4, 8)
			front.decay_per_day = 0.14
		WeatherType.WT.BLIZZARD:
			# 暴雪：原 8-14 天 → 5-10 天
			front.ttl_days = _rng.randi_range(5, 10)
			front.decay_per_day = 0.12
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			# RAIN：原 10-16 天 → 6-11 天
			front.ttl_days = _rng.randi_range(6, 11)
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
		# 临时覆盖物：FLOODING 仍走即时写入；SNOW 改走 _apply_snow_accumulation 累积式
		# 累积式好处：(1) 雪不再随单帧 BLIZZARD 闪烁出现；(2) 温升时按节律消融
		if not LandformType.is_water(cell.landform):
			# 1) 雪：累积 / 融化
			if _apply_snow_accumulation(cell, wt, temp_now, intensity):
				_cover_dirty = true
			# 2) 洪涝：保留即时写入。放宽条件 + 高强度直接淹（让暴雨真的导致洪涝）
			# 修：原条件 intensity>0.4 + elev<0.55 + moist>0.65 太严，从未触发
			# 现：低洼+中强度，或任意海拔下的极端暴雨都能淹
			if cell.cover != CoverType.CV.SNOW and WeatherType.can_form_flood(wt):
				var precip_now: float = float(cell.current_state.get("weather_precip", 0.0))
				var heavy_flood: bool = intensity > 0.55 and precip_now > 0.55  # 极端暴雨：任意海拔
				var lowland_flood: bool = intensity > 0.32 and cell.elevation < 0.50 and moist_now > 0.60
				if (heavy_flood or lowland_flood) and cell.cover != CoverType.CV.FLOODING:
					cell.cover = CoverType.CV.FLOODING
					cell.current_state["cover"] = int(cell.cover)
					_cover_dirty = true

func uses_weather_field() -> bool:
	return _weather_field_enabled

func is_weather_field_solve_active() -> bool:
	return _field_slice_active

func begin_weather_field_solve(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float, season_phase: float = -1.0, count_day: bool = true) -> void:
	_clear_weather_field_slice_state()
	if map == null or world == null:
		return
	if count_day:
		_day_counter += 1
	_current_map_for_tick = map
	_season_phase = season_phase if season_phase >= 0.0 else float(season_idx) + 0.5
	_field_solve_tick += 1
	_field_slice_active = true
	_field_slice_map = map
	_field_slice_world = world
	_field_slice_season_idx = season_idx
	_field_slice_climate_anomaly = climate_anomaly
	_field_slice_cursor = 0
	_field_slice_solve_ms = 0.0
	_field_slice_last_ms = 0.0
	_field_slice_refresh_convergence = ((_field_solve_tick - 1) % _field_convergence_refresh_stride) == 0
	_field_slice_cells = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = _field_slice_cells.size()
	_field_slice_neighbor_indices = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	_field_slice_fast_indexed = _field_slice_neighbor_indices.size() >= n_cells * 6
	_field_slice_cell_pos = PackedVector2Array()
	_field_slice_cell_pos.resize(n_cells)
	_tick_cell_pos.clear()
	_tick_cell_neighbors.clear()
	for i in range(n_cells):
		var cell: HexCell = _field_slice_cells[i]
		_field_slice_cell_pos[i] = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)

	_field_slice_prev_vapor = PackedFloat32Array()
	_field_slice_prev_precip = PackedFloat32Array()
	_field_slice_next_vapor = PackedFloat32Array()
	_field_slice_next_cloud = PackedFloat32Array()
	_field_slice_next_precip = PackedFloat32Array()
	_field_slice_next_instability = PackedFloat32Array()
	_field_slice_next_intensity = PackedFloat32Array()
	_field_slice_next_convergence = PackedFloat32Array()
	_field_slice_next_type = PackedInt32Array()
	_field_slice_prev_vapor.resize(n_cells)
	_field_slice_prev_precip.resize(n_cells)
	_field_slice_next_vapor.resize(n_cells)
	_field_slice_next_cloud.resize(n_cells)
	_field_slice_next_precip.resize(n_cells)
	_field_slice_next_instability.resize(n_cells)
	_field_slice_next_intensity.resize(n_cells)
	_field_slice_next_convergence.resize(n_cells)
	_field_slice_next_type.resize(n_cells)
	for i in range(n_cells):
		var prev_cell: HexCell = _field_slice_cells[i]
		_field_slice_prev_vapor[i] = prev_cell.weather_vapor if prev_cell.weather_field_initialized else prev_cell.moisture
		_field_slice_prev_precip[i] = prev_cell.weather_precip if prev_cell.weather_field_initialized else 0.0

func run_weather_field_solve_slice(cell_budget: int) -> Dictionary:
	if not _field_slice_active:
		return { "done": true, "work_done": 0, "elapsed_ms": 0.0, "progress_ratio": 1.0 }
	var t_us0: int = Time.get_ticks_usec()
	var map: MapData = _field_slice_map
	var world: WorldData = _field_slice_world
	var cells: Array = _field_slice_cells
	var n_cells: int = cells.size()
	var start_i: int = _field_slice_cursor
	var end_i: int = mini(n_cells, start_i + maxi(1, cell_budget))
	var cell_pos: PackedVector2Array = _field_slice_cell_pos
	var neighbor_indices: PackedInt32Array = _field_slice_neighbor_indices
	var fast_indexed: bool = _field_slice_fast_indexed
	var prev_vapor: PackedFloat32Array = _field_slice_prev_vapor
	var prev_precip: PackedFloat32Array = _field_slice_prev_precip
	var next_vapor: PackedFloat32Array = _field_slice_next_vapor
	var next_cloud: PackedFloat32Array = _field_slice_next_cloud
	var next_precip: PackedFloat32Array = _field_slice_next_precip
	var next_instability: PackedFloat32Array = _field_slice_next_instability
	var next_intensity: PackedFloat32Array = _field_slice_next_intensity
	var next_convergence: PackedFloat32Array = _field_slice_next_convergence
	var next_type: PackedInt32Array = _field_slice_next_type
	var season_idx: int = _field_slice_season_idx
	var climate_anomaly: float = _field_slice_climate_anomaly
	var refresh_convergence: bool = _field_slice_refresh_convergence
	for i in range(start_i, end_i):
		var cell: HexCell = cells[i]
		var pos: Vector2 = cell_pos[i]
		var temp: float = clampf(cell.temperature + climate_anomaly + cell.air_mass_temp_anomaly, 0.0, 1.0)
		var base_m: float = clampf(cell.moisture, 0.0, 1.0)
		var ocean_an: float = _avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else _avg_ocean_anomaly_at(cell, map)
		var on_water: bool = _is_water_terrain(int(cell.terrain))

		var wind: Vector2 = cell.wind_vector
		if wind.length_squared() < 0.0001:
			var ny: float = 0.5
			if _world_bounds.size.y > 0.001:
				ny = clampf((pos.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0)
			wind = _sample_terrain_wind(map, world, pos, ny, _season_phase)
		var wind_dir: Vector2 = wind.normalized() if wind.length_squared() > 0.0001 else Vector2.RIGHT

		var upstream_idx: int = _neighbor_aligned_idx(i, -wind_dir, cell_pos, neighbor_indices) if fast_indexed and _field_advect_steps > 0 else -1
		var advected_vapor: float = _upstream_vapor_idx_from_first(i, upstream_idx, cell_pos, neighbor_indices, prev_vapor, wind_dir) if fast_indexed else _upstream_vapor_cached(cell, map, prev_vapor, wind_dir)
		var neighbor_vapor: float = _neighbor_average_vapor_idx(i, neighbor_indices, prev_vapor) if fast_indexed else _neighbor_average_vapor_cached(cell, map, prev_vapor)
		var wind_mag: float = clampf(wind.length() / 1.2, 0.0, 1.0)
		var advect_w: float = clampf(0.65 + wind_mag * 0.30, 0.65, 0.95)
		var is_lake: bool = int(cell.terrain) == TerrainType.TERRAIN.LAKE
		var has_river: bool = (not is_lake) and cell.has_river and not on_water
		if is_lake:
			advect_w = clampf(advect_w * 0.5, 0.20, 0.50)
		elif has_river:
			advect_w = clampf(advect_w * 0.85, 0.55, 0.85)
		var vapor: float = lerpf(base_m, advected_vapor, advect_w)
		vapor = lerpf(vapor, neighbor_vapor, _field_diffusion)

		var effective_ocean_an: float = ocean_an
		if is_lake:
			effective_ocean_an = 0.20
		elif has_river:
			effective_ocean_an = maxf(ocean_an, 0.08)
		var evap: float = _evaporation_for_cell_idx(i, cells, neighbor_indices, temp, base_m, effective_ocean_an, on_water) if fast_indexed else _evaporation_for_cell(cell, map, temp, base_m, effective_ocean_an, on_water)
		vapor = clampf(vapor + evap, 0.0, 1.0)

		var lift: float = _orographic_lift_from_upstream_idx(i, upstream_idx, cells) if fast_indexed else _orographic_lift_for_cell(cell, map, wind_dir)
		var convergence: float = cell.weather_convergence
		if refresh_convergence:
			convergence = _wind_convergence_idx(i, cells, cell_pos, neighbor_indices) if fast_indexed else _wind_convergence_for_cell(cell, map)
		if lift < 0.0:
			vapor = clampf(vapor + lift * 0.22, 0.0, 1.0)

		var saturation: float = clampf(0.40 + temp * 0.30, 0.34, 0.74)
		var humid_excess: float = maxf(vapor - saturation, 0.0)
		var lift_supply: float = maxf(lift, 0.0) * clampf((vapor - 0.10) / 0.40, 0.0, 1.0)
		var cloud: float = clampf(
			humid_excess * _field_condensation_gain * 2.2
			+ lift_supply * _field_orographic_lift_gain
			+ convergence * _field_convergence_gain
			+ maxf(effective_ocean_an, 0.0) * 0.12,
			0.0, 1.0
		)
		var instability: float = clampf(
			(temp - 0.45) * 1.15
			+ vapor * 0.55
			+ cloud * 0.35
			+ convergence * _field_convergence_gain
			+ lift_supply * _field_orographic_lift_gain
			+ maxf(effective_ocean_an, 0.0) * 0.25,
			0.0, 1.0
		)
		var precip_raw: float = cloud * (0.30 + instability * 0.70) + lift_supply * 0.18 - maxf(-lift, 0.0) * 0.45
		var old_precip: float = prev_precip[i]
		var vapor_floor_factor: float = clampf((vapor - 0.10) / 0.40, 0.0, 1.0)
		var dyn_decay: float = _field_precip_decay + wind_mag * 0.25
		var precip_floor: float = old_precip * (1.0 - dyn_decay) * vapor_floor_factor
		var precip: float = clampf(maxf(precip_raw, precip_floor), 0.0, 1.0)

		var wt: int = _classify_field_weather_at(pos, season_idx, temp, vapor, cloud, precip, instability, ocean_an) if fast_indexed else _classify_field_weather(cell, season_idx, temp, vapor, cloud, precip, instability, ocean_an)
		var intensity: float = _field_intensity_for_type(wt, temp, vapor, cloud, precip, instability, ocean_an)
		next_vapor[i] = vapor
		next_cloud[i] = cloud
		next_precip[i] = precip
		next_instability[i] = instability
		next_type[i] = wt
		next_intensity[i] = intensity
		next_convergence[i] = convergence
	_field_slice_cursor = end_i
	var elapsed_ms: float = (Time.get_ticks_usec() - t_us0) / 1000.0
	_field_slice_solve_ms += elapsed_ms
	_field_slice_last_ms = elapsed_ms
	return {
		"done": _field_slice_cursor >= n_cells,
		"work_done": end_i - start_i,
		"elapsed_ms": elapsed_ms,
		"progress_ratio": float(_field_slice_cursor) / float(maxi(n_cells, 1)),
	}

func commit_weather_field_solve() -> Array[WeatherFront]:
	if not _field_slice_active:
		return _active_fronts
	var map: MapData = _field_slice_map
	var world: WorldData = _field_slice_world
	var cells: Array = _field_slice_cells
	for i in range(cells.size()):
		var out_cell: HexCell = cells[i]
		out_cell.weather_field_initialized = true
		out_cell.weather_vapor = _field_slice_next_vapor[i]
		out_cell.weather_cloud = _field_slice_next_cloud[i]
		out_cell.weather_precip = _field_slice_next_precip[i]
		out_cell.weather_instability = _field_slice_next_instability[i]
		out_cell.weather_type = _field_slice_next_type[i]
		out_cell.weather_intensity = _field_slice_next_intensity[i]
		out_cell.weather_convergence = _field_slice_next_convergence[i]
	if _field_slice_refresh_convergence:
		_apply_frontal_convergence_boost(map, cells, _field_slice_climate_anomaly, _field_slice_neighbor_indices, _field_slice_fast_indexed)

	var t_us0_field: int = Time.get_ticks_usec()
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

	var solve_ms: float = _field_slice_solve_ms
	var last_solve_ms: float = _field_slice_last_ms
	_last_breakdown = {
		"advance_ms": last_solve_ms,
		"spawn_ms": summary_ms,
		"distribute_ms": distribute_ms_field,
		"cyclone_ms": cyclone_ms_field,
		"field_solve_ms": last_solve_ms,
		"field_solve_total_ms": solve_ms,
		"field_summary_ms": summary_ms,
		"weather_tick_ms": last_solve_ms + distribute_ms_field + summary_ms + cyclone_ms_field,
	}
	_last_map_for_query = map
	_current_map_for_tick = null
	_tick_cell_pos.clear()
	_tick_cell_neighbors.clear()
	_clear_weather_field_slice_state()
	return _active_fronts

func _clear_weather_field_slice_state() -> void:
	_field_slice_active = false
	_field_slice_map = null
	_field_slice_world = null
	_field_slice_season_idx = 0
	_field_slice_climate_anomaly = 0.0
	_field_slice_cursor = 0
	_field_slice_refresh_convergence = false
	_field_slice_fast_indexed = false
	_field_slice_cells = []
	_field_slice_cell_pos = PackedVector2Array()
	_field_slice_neighbor_indices = PackedInt32Array()
	_field_slice_prev_vapor = PackedFloat32Array()
	_field_slice_prev_precip = PackedFloat32Array()
	_field_slice_next_vapor = PackedFloat32Array()
	_field_slice_next_cloud = PackedFloat32Array()
	_field_slice_next_precip = PackedFloat32Array()
	_field_slice_next_instability = PackedFloat32Array()
	_field_slice_next_intensity = PackedFloat32Array()
	_field_slice_next_convergence = PackedFloat32Array()
	_field_slice_next_type = PackedInt32Array()
	_field_slice_solve_ms = 0.0
	_field_slice_last_ms = 0.0

func _solve_weather_field(map: MapData, world: WorldData, season_idx: int, climate_anomaly: float) -> void:
	begin_weather_field_solve(map, world, season_idx, climate_anomaly, _season_phase)
	while true:
		var slice_result: Dictionary = run_weather_field_solve_slice(2147483647)
		if bool(slice_result.get("done", true)):
			break
	commit_weather_field_solve()
	return

	_field_solve_tick += 1
	var refresh_convergence: bool = ((_field_solve_tick - 1) % _field_convergence_refresh_stride) == 0
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	var n_cells: int = cells.size()
	var neighbor_indices: PackedInt32Array = map.neighbor_indices_packed() if map.has_indices() else PackedInt32Array()
	var fast_indexed: bool = neighbor_indices.size() >= n_cells * 6
	var cell_pos := PackedVector2Array()
	cell_pos.resize(n_cells)
	# Solver hot path uses local indexed arrays. Avoid filling tick-scoped
	# dictionaries here; summary/front code can fall back to direct helpers.
	_tick_cell_pos.clear()
	_tick_cell_neighbors.clear()
	for i in range(n_cells):
		var cell: HexCell = cells[i]
		cell_pos[i] = HexUtils.cube_to_world(cell.q, cell.r, _hex_size)

	var prev_vapor := PackedFloat32Array()
	var prev_precip := PackedFloat32Array()
	var next_vapor := PackedFloat32Array()
	var next_cloud := PackedFloat32Array()
	var next_precip := PackedFloat32Array()
	var next_instability := PackedFloat32Array()
	var next_intensity := PackedFloat32Array()
	var next_convergence := PackedFloat32Array()
	var next_type := PackedInt32Array()
	prev_vapor.resize(n_cells)
	prev_precip.resize(n_cells)
	next_vapor.resize(n_cells)
	next_cloud.resize(n_cells)
	next_precip.resize(n_cells)
	next_instability.resize(n_cells)
	next_intensity.resize(n_cells)
	next_convergence.resize(n_cells)
	next_type.resize(n_cells)
	for i in range(n_cells):
		var prev_cell: HexCell = cells[i]
		prev_vapor[i] = prev_cell.weather_vapor if prev_cell.weather_field_initialized else prev_cell.moisture
		prev_precip[i] = prev_cell.weather_precip if prev_cell.weather_field_initialized else 0.0

	for i in range(n_cells):
		var cell: HexCell = cells[i]
		var pos: Vector2 = cell_pos[i]
		var temp: float = clampf(cell.temperature + climate_anomaly + cell.air_mass_temp_anomaly, 0.0, 1.0)
		var base_m: float = clampf(cell.moisture, 0.0, 1.0)
		var ocean_an: float = _avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else _avg_ocean_anomaly_at(cell, map)
		var on_water: bool = _is_water_terrain(int(cell.terrain))

		var wind: Vector2 = cell.wind_vector
		if wind.length_squared() < 0.0001:
			var ny: float = 0.5
			if _world_bounds.size.y > 0.001:
				ny = clampf((pos.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0)
			wind = _sample_terrain_wind(map, world, pos, ny, _season_phase)
		var wind_dir: Vector2 = wind.normalized() if wind.length_squared() > 0.0001 else Vector2.RIGHT

		var upstream_idx: int = _neighbor_aligned_idx(i, -wind_dir, cell_pos, neighbor_indices) if fast_indexed and _field_advect_steps > 0 else -1
		var advected_vapor: float = _upstream_vapor_idx_from_first(i, upstream_idx, cell_pos, neighbor_indices, prev_vapor, wind_dir) if fast_indexed else _upstream_vapor_cached(cell, map, prev_vapor, wind_dir)
		var neighbor_vapor: float = _neighbor_average_vapor_idx(i, neighbor_indices, prev_vapor) if fast_indexed else _neighbor_average_vapor_cached(cell, map, prev_vapor)
		# 修（v3）：advection 函数已修正为纯上游链。这里 lerp 权重对应"风带强度"
		# wind 越强 → vapor 越像上游（advect 主导，雨云被吹走）
		# wind 弱 → vapor 越像 base_moisture（静止湿度场，本地蒸发）
		# 修（v5）：风权重再上调 → advect 主导更彻底
		# wind_mag=1 时 advect_w=0.95（base 5%）；wind_mag=0 时 advect_w=0.65
		var wind_mag: float = clampf(wind.length() / 1.2, 0.0, 1.0)
		var advect_w: float = clampf(0.65 + wind_mag * 0.30, 0.65, 0.95)
		# v9c：内陆湖面修复——LAKE 上风方向是陆地（vapor 低），
		# 高 advect_w 把湖面 vapor 摊薄到陆地值 → 湖面没有云。
		# 对 LAKE 大幅降权（最高 0.50），让 base_moisture 主导。
		var is_lake: bool = int(cell.terrain) == TerrainType.TERRAIN.LAKE
		# v9d：河流走温和路线——河流只占 cell 面积一小部分（陆地 + 河带），
		# 给它湖泊那套强度会让"河流穿过的整片陆地"湿润化。
		# 只做轻度 advect 降权（最低 0.55），让风仍能带走云但 base 也起作用。
		var has_river: bool = (not is_lake) and cell.has_river and not on_water
		if is_lake:
			advect_w = clampf(advect_w * 0.5, 0.20, 0.50)
		elif has_river:
			advect_w = clampf(advect_w * 0.85, 0.55, 0.85)
		var vapor: float = lerpf(base_m, advected_vapor, advect_w)
		vapor = lerpf(vapor, neighbor_vapor, _field_diffusion)

		# v9c：LAKE 没有 ocean_current → ocean_an=0 → ocean_mul 卡在 1.0；
		# 给湖面一个虚拟正异常 +0.20 让 evap 略高于平均海面（湖泊夏季蒸发其实很强）。
		# v9d：河流给一个更轻的虚拟异常 +0.08（河岸蒸发真实存在但远弱于湖面）。
		var effective_ocean_an: float = ocean_an
		if is_lake:
			effective_ocean_an = 0.20
		elif has_river:
			effective_ocean_an = maxf(ocean_an, 0.08)
		var evap: float = _evaporation_for_cell_idx(i, cells, neighbor_indices, temp, base_m, effective_ocean_an, on_water) if fast_indexed else _evaporation_for_cell(cell, map, temp, base_m, effective_ocean_an, on_water)
		vapor = clampf(vapor + evap, 0.0, 1.0)

		var lift: float = _orographic_lift_from_upstream_idx(i, upstream_idx, cells) if fast_indexed else _orographic_lift_for_cell(cell, map, wind_dir)
		var convergence: float = cell.weather_convergence
		if refresh_convergence:
			convergence = _wind_convergence_idx(i, cells, cell_pos, neighbor_indices) if fast_indexed else _wind_convergence_for_cell(cell, map)
		if lift < 0.0:
			vapor = clampf(vapor + lift * 0.22, 0.0, 1.0)

		# 修（v9b）：v6 砍到 *1.8 + v7 lift 门控 (vapor-0.20) 双重削弱后，
		# 雨云锐减——中等湿度（0.3-0.5）的常态海上区域几乎不再生云。
		# 现在做两处回调：
		#   - 凝结倍数 1.8 → 2.2（仍比 v5 的 *3.0 低 27%，紫带不会回归）
		#   - lift 门控曲线放缓：(vapor-0.10)/0.40 → vapor=0.5 即拿满
		var saturation: float = clampf(0.40 + temp * 0.30, 0.34, 0.74)
		var humid_excess: float = maxf(vapor - saturation, 0.0)
		# v9b：lift 门控曲线放缓——保留"vapor=0 不能生雨"的物理底线，
		# 但中等湿度（0.3-0.5）已能拿到正常 lift 贡献。
		var lift_supply: float = maxf(lift, 0.0) * clampf((vapor - 0.10) / 0.40, 0.0, 1.0)
		var cloud: float = clampf(
			humid_excess * _field_condensation_gain * 2.2
			+ lift_supply * _field_orographic_lift_gain
			+ convergence * _field_convergence_gain
			+ maxf(effective_ocean_an, 0.0) * 0.12,
			0.0, 1.0
		)
		var instability: float = clampf(
			(temp - 0.45) * 1.15
			+ vapor * 0.55
			+ cloud * 0.35
			+ convergence * _field_convergence_gain
			+ lift_supply * _field_orographic_lift_gain
			+ maxf(effective_ocean_an, 0.0) * 0.25,
			0.0, 1.0
		)
		# v7：precip_raw 的 lift 直贡献也门控在 vapor 上（同上理由）。
		# 同时把 max-decay 的 floor 改为乘 vapor——vapor 跌到 0 时旧 precip 必须放掉。
		var precip_raw: float = cloud * (0.30 + instability * 0.70) + lift_supply * 0.18 - maxf(-lift, 0.0) * 0.45
		var old_precip: float = prev_precip[i]
		# 修（v7+v9b）：decay 同时受风速与 vapor 双重加压：
		#   - 强风带：保留率 ≈ 5%（继承 v3）
		#   - vapor 跌到 0.10 以下：旧 precip 强制放空（断绝持留环路）
		# v9b：曲线与 lift 门控同步放缓 (0.20→0.10 起步)，
		# 避免常态海风带（vapor 0.3-0.5）的雨云被 floor 误掐。
		var vapor_floor_factor: float = clampf((vapor - 0.10) / 0.40, 0.0, 1.0)
		var dyn_decay: float = _field_precip_decay + wind_mag * 0.25
		var precip_floor: float = old_precip * (1.0 - dyn_decay) * vapor_floor_factor
		var precip: float = clampf(maxf(precip_raw, precip_floor), 0.0, 1.0)

		var wt: int = _classify_field_weather_at(pos, season_idx, temp, vapor, cloud, precip, instability, ocean_an) if fast_indexed else _classify_field_weather(cell, season_idx, temp, vapor, cloud, precip, instability, ocean_an)
		var intensity: float = _field_intensity_for_type(wt, temp, vapor, cloud, precip, instability, ocean_an)
		next_vapor[i] = vapor
		next_cloud[i] = cloud
		next_precip[i] = precip
		next_instability[i] = instability
		next_type[i] = wt
		next_intensity[i] = intensity
		next_convergence[i] = convergence
	for i in range(n_cells):
		var out_cell: HexCell = cells[i]
		out_cell.weather_field_initialized = true
		out_cell.weather_vapor = next_vapor[i]
		out_cell.weather_cloud = next_cloud[i]
		out_cell.weather_precip = next_precip[i]
		out_cell.weather_instability = next_instability[i]
		out_cell.weather_type = next_type[i]
		out_cell.weather_intensity = next_intensity[i]
		out_cell.weather_convergence = next_convergence[i]
	# Phase 3b：锋面散度 + 温差升降级。
	# 在主循环结束、_weather_field 已落定之后做一次"锋面后处理"：
	#   - 对每个 cell 重读其周边温度差（max - min over neighbors），
	#     用 wind_convergence 作为辐合强度 → 二者相乘得到 frontal_score
	#   - 高 frontal_score（强辐合 + 大温差）：强制把 cloud / precip / instability
	#     拉到 RAIN 以上阈值，并按温差判定升 STORM 或降 RAIN
	#   - 这保证"锋面"在地图上是物理可见的：哪里有冷暖气流交汇，哪里就下雨
	if refresh_convergence:
		_apply_frontal_convergence_boost(map, cells, climate_anomaly, neighbor_indices, fast_indexed)

func _apply_frontal_convergence_boost(map: MapData, cells: Array, climate_anomaly: float, neighbor_indices: PackedInt32Array, fast_indexed: bool) -> void:
	# 锋面温差阈值（temperature 归一化为 [0,1]，0.28 ≈ 14°C，0.06 ≈ 3°C）。
	# 修（v4）：v3 的 0.20/0.32 在中纬度风带几乎全境触发 → STORM 横贯地图。
	# 现在大幅收紧：温差需 14°C 以上、辐合需更强，才进入"真正的锋面带"。
	const STORM_TEMP_DIFF: float = 0.28
	const WEAK_TEMP_DIFF: float = 0.06
	const CONVERGENCE_THRESHOLD: float = 0.45
	for i in range(cells.size()):
		var cell: HexCell = cells[i]
		if not cell.weather_field_initialized:
			continue
		var conv: float = cell.weather_convergence
		if conv < CONVERGENCE_THRESHOLD:
			continue
		# 计算 cell 邻域的温差 max - min（含 cell 自身）。
		var t_self: float = clampf(cell.temperature + climate_anomaly + cell.air_mass_temp_anomaly, 0.0, 1.0)
		var t_min: float = t_self
		var t_max: float = t_self
		if fast_indexed:
			var base: int = i * 6
			for d in range(6):
				var nb_idx: int = neighbor_indices[base + d]
				if nb_idx < 0:
					continue
				var nb: HexCell = cells[nb_idx]
				var t_nb: float = clampf(nb.temperature + climate_anomaly + nb.air_mass_temp_anomaly, 0.0, 1.0)
				if t_nb < t_min:
					t_min = t_nb
				if t_nb > t_max:
					t_max = t_nb
		else:
			for nb: HexCell in _cell_neighbors(cell, map):
				if nb == null:
					continue
				var t_nb: float = clampf(nb.temperature + climate_anomaly + nb.air_mass_temp_anomaly, 0.0, 1.0)
				if t_nb < t_min:
					t_min = t_nb
				if t_nb > t_max:
					t_max = t_nb
		var temp_diff: float = t_max - t_min
		# frontal_score：辐合强度 × 温差强度（温差 0.20 时为 1.0）。
		var frontal_score: float = clampf(
			(conv - CONVERGENCE_THRESHOLD) / (1.0 - CONVERGENCE_THRESHOLD)
			* clampf(temp_diff / STORM_TEMP_DIFF, 0.0, 1.0),
			0.0, 1.0
		)
		if frontal_score < 0.45:
			continue
		# 修（v5）：boost 进一步弱化——只让锋面带"略多云"，不再硬推 precip / inst 过阈值
		# 让 STORM 等强对流完全由 _classify 的物理条件决定，不再被锋面后处理强制锁
		var cloud0: float = cell.weather_cloud
		var precip0: float = cell.weather_precip
		var inst0: float = cell.weather_instability
		var cloud1: float = clampf(maxf(cloud0, 0.25 + frontal_score * 0.20), 0.0, 1.0)
		var precip1: float = clampf(maxf(precip0, 0.05 + frontal_score * 0.12), 0.0, 1.0)
		var inst1: float = clampf(maxf(inst0, 0.25 + frontal_score * 0.15), 0.0, 1.0)
		cell.weather_cloud = cloud1
		cell.weather_precip = precip1
		cell.weather_instability = inst1
		# 修（v5）：彻底取消温差升级到 STORM/BLIZZARD 的锁定逻辑。
		# 锋面只做云的"轻推"，不再改 type。强对流完全交给 classify 物理条件判断。
		# 仅保留：温差极小时把残余 STORM/MONSOON 降级 RAIN（防止旧 STORM 持留）
		var wt0: int = cell.weather_type
		var new_wt: int = wt0
		if temp_diff < WEAK_TEMP_DIFF and (wt0 == WeatherType.WT.STORM or wt0 == WeatherType.WT.MONSOON):
			new_wt = WeatherType.WT.RAIN
		cell.weather_type = new_wt
		# 重算 intensity（沿用同套公式，确保下游可视化一致）。
		var ocean_an: float = _avg_ocean_anomaly_at_idx(i, cells, neighbor_indices) if fast_indexed else _avg_ocean_anomaly_at(cell, map)
		var vapor1: float = cell.weather_vapor
		cell.weather_intensity = _field_intensity_for_type(new_wt, t_self, vapor1, cloud1, precip1, inst1, ocean_an)

# Phase 3c：积雪累积与融化（共享方法）
# ------------------------------------------------------------------------
# 目的：把"BLIZZARD/SNOW 一发生立刻 cover=SNOW"换成累积式累计 + 温升融化。
# 字段约定（hex_cell.gd 已新增）：
#   accumulated_snow_days: int  —— 当前连续可降雪天数，>=SNOW_ACCUM_DAYS 时落地为 SNOW
#   pre_snow_cover: int         —— 备份覆盖前的 cover；融化时恢复（-1 表示未备份）
# 写入策略：
#   1) 可降雪条件（can_form_snow 且 temp<冰点 且 intensity>0.4）→ accumulated_snow_days += 1
#   2) 否则若 temp 高于解冻阈值 → accumulated_snow_days -= 1（不再降雪即缓慢消融）
#   3) 累计达阈值且当前不是 SNOW → 备份原 cover，写 cover=SNOW
#   4) 累计回零且当前是 SNOW 且有备份 → 恢复 cover=pre_snow_cover
const SNOW_ACCUM_DAYS_REQ: int = 3      # 连续 N 天才落地积雪
const SNOW_FREEZE_T: float = 0.30       # 低于此温度才算"可降雪冷度"
const SNOW_MELT_T: float = 0.34         # 高于此温度开始消融（带一点滞回防抖）

func _apply_snow_accumulation(cell: HexCell, wt: int, temp_now: float, intensity: float) -> bool:
	# 返回 true 表示本调用改写了 cell.cover（caller 据此设置 _cover_dirty）。
	if LandformType.is_water(cell.landform):
		return false
	var changed: bool = false
	var snowing: bool = WeatherType.can_form_snow(wt) and temp_now < SNOW_FREEZE_T and intensity > 0.4
	if snowing:
		cell.accumulated_snow_days += 1
	elif temp_now > SNOW_MELT_T:
		cell.accumulated_snow_days = max(0, cell.accumulated_snow_days - 1)
	# 升级：累积够了且当前还不是 SNOW → 备份并覆盖
	if cell.accumulated_snow_days >= SNOW_ACCUM_DAYS_REQ and cell.cover != CoverType.CV.SNOW:
		cell.pre_snow_cover = int(cell.cover)
		cell.cover = CoverType.CV.SNOW
		cell.current_state["cover"] = int(cell.cover)
		changed = true
	# 融化：累积清零且当前是 SNOW → 恢复（无备份则置 NONE）
	elif cell.accumulated_snow_days <= 0 and cell.cover == CoverType.CV.SNOW:
		var restored: int = cell.pre_snow_cover if cell.pre_snow_cover >= 0 else int(CoverType.CV.NONE)
		cell.cover = restored
		cell.current_state["cover"] = int(cell.cover)
		cell.pre_snow_cover = -1
		changed = true
	return changed

func _upstream_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary, wind_dir: Vector2) -> float:
	# 修（v3）：原版以 cell 自身为锚（weight=1.0）+ 上游 1/2,1/3,1/4 → cell 自己占 48%
	# → 上游链根本拽不动场，这是"风动不明显"的真凶（lerp 权重再高也救不回来）。
	# 现在：完全不含自己，仅看上游链，权重高 → 远 → 低，让 vapor 真正随风迁移。
	var current: HexCell = cell
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_field_advect_steps):
		var upstream: HexCell = _neighbor_aligned(current, map, -wind_dir)
		if upstream == null:
			break
		sum_v += float(prev_vapor.get(upstream, upstream.moisture)) * w_decay
		weight += w_decay
		w_decay *= 0.75  # 1.0 → 0.75 → 0.56 → 0.42 → 0.32 → 0.24，6 跳更长尾
		current = upstream
	if weight < 0.001:
		# 边缘格子无上游：fallback 到自身（避免 0 vapor）
		return float(prev_vapor.get(cell, cell.moisture))
	return sum_v / weight

func _neighbor_average_vapor(cell: HexCell, map: MapData, prev_vapor: Dictionary) -> float:
	var sum_v: float = float(prev_vapor.get(cell, cell.moisture))
	var n: int = 1
	for nb: HexCell in _cell_neighbors(cell, map):
		if nb == null:
			continue
		sum_v += float(prev_vapor.get(nb, nb.moisture))
		n += 1
	return sum_v / float(maxi(n, 1))

func _prev_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	var idx: int = map.index_of(cell)
	if idx >= 0 and idx < prev_vapor.size():
		return prev_vapor[idx]
	return cell.weather_vapor if cell.weather_field_initialized else cell.moisture

func _upstream_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	var current: HexCell = cell
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_field_advect_steps):
		var upstream: HexCell = _neighbor_aligned(current, map, -wind_dir)
		if upstream == null:
			break
		sum_v += _prev_vapor_cached(upstream, map, prev_vapor) * w_decay
		weight += w_decay
		w_decay *= 0.75
		current = upstream
	if weight < 0.001:
		return _prev_vapor_cached(cell, map, prev_vapor)
	return sum_v / weight

func _neighbor_average_vapor_cached(cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	var sum_v: float = _prev_vapor_cached(cell, map, prev_vapor)
	var n: int = 1
	for nb: HexCell in _cell_neighbors(cell, map):
		if nb == null:
			continue
		sum_v += _prev_vapor_cached(nb, map, prev_vapor)
		n += 1
	return sum_v / float(maxi(n, 1))

func _neighbor_aligned_idx(idx: int, dir: Vector2, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> int:
	if idx < 0 or idx >= cell_pos.size() or dir.length_squared() <= 0.0001:
		return -1
	var self_wp: Vector2 = cell_pos[idx]
	var best_idx: int = -1
	var best_dot: float = _hex_size * 0.31176915 # sqrt(3) * 0.18
	var ndir: Vector2 = dir.normalized()
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var to_nb: Vector2 = cell_pos[nb_idx] - self_wp
		var dot: float = to_nb.dot(ndir)
		if dot > best_dot:
			best_dot = dot
			best_idx = nb_idx
	return best_idx

func _upstream_vapor_idx(idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	var current_idx: int = idx
	var sum_v: float = 0.0
	var weight: float = 0.0
	var w_decay: float = 1.0
	for step in range(_field_advect_steps):
		var upstream_idx: int = _neighbor_aligned_idx(current_idx, -wind_dir, cell_pos, neighbor_indices)
		if upstream_idx < 0:
			break
		sum_v += prev_vapor[upstream_idx] * w_decay
		weight += w_decay
		w_decay *= 0.75
		current_idx = upstream_idx
	if weight < 0.001:
		return prev_vapor[idx]
	return sum_v / weight

func _upstream_vapor_idx_from_first(idx: int, first_upstream_idx: int, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array, wind_dir: Vector2) -> float:
	if first_upstream_idx < 0 or _field_advect_steps <= 0:
		return prev_vapor[idx]
	var current_idx: int = first_upstream_idx
	var sum_v: float = prev_vapor[current_idx]
	var weight: float = 1.0
	var w_decay: float = 0.75
	for step in range(1, _field_advect_steps):
		var upstream_idx: int = _neighbor_aligned_idx(current_idx, -wind_dir, cell_pos, neighbor_indices)
		if upstream_idx < 0:
			break
		sum_v += prev_vapor[upstream_idx] * w_decay
		weight += w_decay
		w_decay *= 0.75
		current_idx = upstream_idx
	return sum_v / weight

func _neighbor_average_vapor_idx(idx: int, neighbor_indices: PackedInt32Array, prev_vapor: PackedFloat32Array) -> float:
	var sum_v: float = prev_vapor[idx]
	var n: int = 1
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		sum_v += prev_vapor[nb_idx]
		n += 1
	return sum_v / float(n)

func _avg_ocean_anomaly_at_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array) -> float:
	var cell: HexCell = cells[idx]
	if _is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var nb: HexCell = cells[nb_idx]
		if _is_water_terrain(int(nb.terrain)):
			sum_an += nb.temperature_transport_anomaly
			n_water += 1
	if n_water == 0:
		return 0.0
	return sum_an / float(n_water)

func _evaporation_for_cell_idx(idx: int, cells: Array, neighbor_indices: PackedInt32Array, temp: float, moisture: float, ocean_an: float, on_water: bool) -> float:
	var cell: HexCell = cells[idx]
	var evap: float = 0.028 if on_water else 0.006
	evap += maxf(moisture - 0.45, 0.0) * 0.018
	evap += _vegetation_transpiration_factor(cell) * 0.012
	if not on_water:
		if cell.has_river:
			evap += 0.012
		var base: int = idx * 6
		for d in range(6):
			var nb_idx: int = neighbor_indices[base + d]
			if nb_idx < 0:
				continue
			var nb: HexCell = cells[nb_idx]
			if _is_water_terrain(int(nb.terrain)):
				evap += 0.018
				break
	var ocean_mul: float = clampf(1.0 + _field_ocean_evap_gain * ocean_an, 0.20, 1.80)
	var temp_mul: float = clampf(0.35 + temp * 1.05, 0.12, 1.35)
	return evap * ocean_mul * temp_mul

func _evaporation_for_cell(cell: HexCell, map: MapData, temp: float, moisture: float, ocean_an: float, on_water: bool) -> float:
	var evap: float = 0.028 if on_water else 0.006
	evap += maxf(moisture - 0.45, 0.0) * 0.018
	evap += _vegetation_transpiration_factor(cell) * 0.012
	if not on_water:
		# v9d：自身有河 → 给固定 +0.012（比"邻居有水"的 +0.018 略低，
		# 因为河只占 cell 面积一小部分）。这是叠加在 base 0.006 上，
		# 让河流穿过的陆地实际 evap 接近 0.018，介于陆地与海面之间。
		if cell.has_river:
			evap += 0.012
		for nb: HexCell in _cell_neighbors(cell, map):
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

func _orographic_lift_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array, wind_dir: Vector2) -> float:
	var upstream_idx: int = _neighbor_aligned_idx(idx, -wind_dir, cell_pos, neighbor_indices)
	if upstream_idx < 0:
		return 0.0
	var cell: HexCell = cells[idx]
	var upstream: HexCell = cells[upstream_idx]
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0

func _orographic_lift_from_upstream_idx(idx: int, upstream_idx: int, cells: Array) -> float:
	if upstream_idx < 0:
		return 0.0
	var cell: HexCell = cells[idx]
	var upstream: HexCell = cells[upstream_idx]
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0

func _wind_convergence_for_cell(cell: HexCell, map: MapData) -> float:
	var self_wp: Vector2 = _cell_world_pos(cell)
	var incoming: float = 0.0
	var checked: int = 0
	for nb: HexCell in _cell_neighbors(cell, map):
		if nb == null:
			continue
		var nb_wp: Vector2 = _cell_world_pos(nb)
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

func _wind_convergence_idx(idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> float:
	var self_wp: Vector2 = cell_pos[idx]
	var incoming: float = 0.0
	var checked: int = 0
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var dir_to_self: Vector2 = self_wp - cell_pos[nb_idx]
		if dir_to_self.length_squared() <= 0.0001:
			continue
		var nb: HexCell = cells[nb_idx]
		var wind: Vector2 = nb.wind_vector
		if wind.length_squared() <= 0.0001:
			continue
		incoming += maxf(0.0, dir_to_self.normalized().dot(wind.normalized()))
		checked += 1
	if checked == 0:
		return 0.0
	return clampf(incoming / float(checked), 0.0, 1.0)

func _neighbor_aligned(cell: HexCell, map: MapData, dir: Vector2) -> HexCell:
	if cell == null or dir.length_squared() <= 0.0001:
		return null
	var neighbors: Array = _cell_neighbors(cell, map)
	if neighbors.is_empty():
		return null
	var self_wp: Vector2 = _cell_world_pos(cell)
	var best: HexCell = null
	var best_dot: float = 0.18
	var ndir: Vector2 = dir.normalized()
	for nb: HexCell in neighbors:
		if nb == null:
			continue
		var nb_wp: Vector2 = _cell_world_pos(nb)
		var to_nb: Vector2 = nb_wp - self_wp
		if to_nb.length_squared() <= 0.0001:
			continue
		var d: float = to_nb.normalized().dot(ndir)
		if d > best_dot:
			best_dot = d
			best = nb
	return best

func _classify_field_weather_at(pos: Vector2, season_idx: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> int:
	var lat_abs: float = 0.5
	if _world_bounds.size.y > 0.001:
		lat_abs = absf(clampf((pos.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0) * 2.0 - 1.0)
	var warm: bool = temp > 0.58
	var cold: bool = temp < 0.32
	var humid: bool = vapor > 0.55
	var summerish: bool = (season_idx % 4) == 1
	var low_lat: bool = lat_abs < 0.48

	if cold and (precip > 0.50 or (cloud > 0.78 and vapor > 0.75)):
		return WeatherType.WT.BLIZZARD
	if warm and humid and instability > 0.85 and precip > 0.58:
		return WeatherType.WT.STORM
	if warm and humid and low_lat and (summerish or _season_phase > 0.75 and _season_phase < 2.25) and precip > 0.48:
		return WeatherType.WT.MONSOON
	if precip > 0.52 or (cloud > 0.82 and vapor > 0.72):
		return WeatherType.WT.RAIN
	if vapor > 0.58 and cloud > 0.28 and precip < 0.15 and temp < 0.50:
		return WeatherType.WT.FOG
	if temp > 0.73 and vapor < 0.35 and cloud < 0.20:
		return WeatherType.WT.HEATWAVE
	if vapor < 0.30 and cloud < 0.14 and (temp > 0.52 or ocean_an < -0.08):
		return WeatherType.WT.DROUGHT
	return WeatherType.WT.CLEAR

func _classify_field_weather(cell: HexCell, season_idx: int, temp: float, vapor: float, cloud: float, precip: float, instability: float, ocean_an: float) -> int:
	var lat_abs: float = 0.5
	if _world_bounds.size.y > 0.001:
		var pos: Vector2 = _cell_world_pos(cell)
		lat_abs = absf(clampf((pos.y - _world_bounds.position.y) / _world_bounds.size.y, 0.0, 1.0) * 2.0 - 1.0)
	var warm: bool = temp > 0.58
	var cold: bool = temp < 0.32
	var humid: bool = vapor > 0.55
	var summerish: bool = (season_idx % 4) == 1
	var low_lat: bool = lat_abs < 0.48

	# 修（v5）：STORM 必须真正"猛"才触发，不再让中纬度风带普通湿天气也进 STORM
	if cold and (precip > 0.50 or (cloud > 0.78 and vapor > 0.75)):
		return WeatherType.WT.BLIZZARD
	if warm and humid and instability > 0.85 and precip > 0.58:
		return WeatherType.WT.STORM
	if warm and humid and low_lat and (summerish or _season_phase > 0.75 and _season_phase < 2.25) and precip > 0.48:
		return WeatherType.WT.MONSOON
	if precip > 0.52 or (cloud > 0.82 and vapor > 0.72):
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
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()
	for cell: HexCell in cells:
		var wt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var intensity: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		if wt == WeatherType.WT.CLEAR or intensity <= 0.001:
			if not LandformType.is_water(cell.landform) \
					and (cell.accumulated_snow_days > 0 or cell.cover == CoverType.CV.SNOW):
				if _apply_snow_accumulation(cell, wt, cell.temperature, 0.0):
					_cover_dirty = true
			continue
		var precip: float = cell.weather_precip if cell.weather_field_initialized else 0.0

		var moist_now: float = clampf(cell.moisture + WeatherType.moisture_delta(wt) * intensity, 0.0, 1.0)
		var temp_now: float = clampf(cell.temperature + WeatherType.temp_delta(wt) * intensity, 0.0, 1.0)
		cell.moisture = moist_now
		cell.temperature = temp_now

		if not LandformType.is_water(cell.landform):
			# 雪：累积式（同 fronts 路径，避免两条分支不一致）
			if _apply_snow_accumulation(cell, wt, temp_now, intensity):
				_cover_dirty = true
			# 洪涝：放宽条件 + 高强度直接淹（与 fronts 路径同步）
			if cell.cover != CoverType.CV.SNOW and WeatherType.can_form_flood(wt):
				var heavy_flood: bool = intensity > 0.55 and precip > 0.55
				var lowland_flood: bool = intensity > 0.32 and cell.elevation < 0.50 and moist_now > 0.60
				if (heavy_flood or lowland_flood) and cell.cover != CoverType.CV.FLOODING:
					cell.cover = CoverType.CV.FLOODING
					cell.current_state["cover"] = int(cell.cover)
					_cover_dirty = true

func _build_field_summary_fronts(map: MapData, world: WorldData) -> Array[WeatherFront]:
	# Continuity-fix（2026-05-10）：完全重写聚类阶段，根治"天气特效跳变"。
	#
	# 旧实现的问题：
	#   1. 每 tick 都用 flood-fill 从零聚类，没有跨 tick 身份；视觉层只能靠
	#      (type, 距离 ≤ 1.5×r) 反推同一性，split/merge/边界 cell 翻 type 时
	#      匹配失败 → 旧 front 淡出 + 新 front 在另一处淡入 = 跳变。
	#   2. 单一硬阈值 0.10 → 边界 cell 在 0.08~0.12 之间抖动 → 聚类形态每 tick 漂移。
	#   3. summary front 的 velocity 字段从未填写 → weather_layer._predict 外推位移恒为 0
	#      → 跳日间云完全静止，下次 snapshot 来时是位移阶跃。
	#
	# 现在的修法：
	#   Step 1（C）以 _prev_summary_seeds 为优先种子做 BFS，让 cluster 跨 tick 保身份。
	#   Step 2（D）阈值滞回：上 tick 在某簇内的 cell 用 _HOLD=0.06 留簇里；新加入需 ≥ _ENTER=0.10。
	#   Step 3（A）给每个 front 设 velocity = axis × radius × 0.4（与 _spawn_random_front 同源），
	#                   weather_layer 外推预测就能让云在跳日/blend 阶段顺风继续飘。
	#   Step 4 inherited cluster 的 life_progress 按继承代数前进，让 birth/dissolve 曲线
	#                   只在真正"新生云"上触发；老簇保持 mature 不再每 tick 复位为 0.2。
	const _SUMMARY_INTENSITY_ENTER: float = 0.10
	const _SUMMARY_INTENSITY_HOLD: float = 0.06
	var components: Array = []
	var visited: Dictionary = {}
	var new_membership: Dictionary = {}
	var cells: Array = map.iter_cells() if map.has_indices() else map.all_cells()

	# Step 1：先用上 tick 的 cluster 中心做 BFS 种子，保持身份。
	# 按 area 降序处理：大 cluster 优先认领，避免被相邻的小 cluster 抢走中心 cell。
	var prev_seed_list: Array = _prev_summary_seeds.duplicate()
	prev_seed_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("area", 1)) > int(b.get("area", 1))
	)
	for prev in prev_seed_list:
		var prev_type: int = int(prev.get("type", WeatherType.WT.CLEAR))
		var prev_center: Vector2 = prev.get("center", Vector2.ZERO)
		var cube := HexUtils.world_to_cube(prev_center, _hex_size)
		var seed_cell: HexCell = map.get_cell_by_cube(cube)
		if seed_cell == null:
			continue
		# 找到合格种子：优先 prev_center 所在 cell；若 type 改变或强度跌穿 hold，
		# 再在 1 环邻居里寻找同型且 ≥ hold 阈值的 cell 作为继承种子。
		var picked_seed: HexCell = _pick_inheritance_seed(
			seed_cell, prev_type, map, visited,
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if picked_seed == null:
			continue
		var component := _flood_fill_field_component(
			picked_seed, prev_type, map, visited, new_membership, components.size(),
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if not component.is_empty():
			component["inherited_age"] = int(prev.get("age", 0)) + 1
			# Drift-fix（2026-05-10）：把上 tick 的中心 + 速度透传给本 tick 的 component，
			# 用于在 build front 阶段计算实测每-snapshot 位移（observed_drift）。
			# 这是让"云会飘"真正生效的关键：之前 axis × radius × 0.4 是凭空给的常数，
			# weather_layer 外推又跑不到，所以视觉位移恒为 0。
			component["inherited_from_center"] = prev_center
			component["inherited_from_velocity"] = prev.get("velocity", Vector2.ZERO)
			components.append(component)

	# Step 2：剩下未访问的 cell 自起新 cluster（age=0 → 走 birth 渐入曲线）。
	for seed_cell: HexCell in cells:
		if visited.has(seed_cell):
			continue
		var wt: int = seed_cell.weather_type if seed_cell.weather_field_initialized else WeatherType.WT.CLEAR
		var intensity: float = seed_cell.weather_intensity if seed_cell.weather_field_initialized else 0.0
		var thresh: float = _SUMMARY_INTENSITY_HOLD if _prev_summary_membership.has(seed_cell) else _SUMMARY_INTENSITY_ENTER
		if intensity < thresh or wt == WeatherType.WT.CLEAR:
			visited[seed_cell] = true
			continue
		var component := _flood_fill_field_component(
			seed_cell, wt, map, visited, new_membership, components.size(),
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if not component.is_empty():
			component["inherited_age"] = 0
			components.append(component)

	# 跨 tick 状态更新（在 _merge_nearby_components 重排前记录 cell 归属）。
	_prev_summary_membership = new_membership

	# dramatic-fx：同型相邻合并 pass。flood-fill 后仍可能存在"被一两格 CLEAR 隔开"
	# 的同型团块（云之间的过渡空隙），这些在视觉上是连续的一片云，但作为两个 front
	# 下发会被 shader 各自做包络衰减 → 边界处出现"双圆叠加 + 中间空"的诡异形态。
	# 这里 O(n²) 扫一遍，把同型且圆心距 < (r1+r2)*0.65 的两个 component 合并，
	# 中心按 area 加权平均、area 累加、intensity 取 max。
	components = _merge_nearby_components(components)

	components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var next_seeds: Array = []
	var limit: int = mini(_field_summary_limit, components.size())
	for i in range(limit):
		var c: Dictionary = components[i]
		var front := WeatherFront.new()
		front.type = int(c.get("type", WeatherType.WT.CLEAR))
		front.center = c.get("center", Vector2.ZERO)
		front.intensity = clampf(float(c.get("intensity", 0.0)), 0.0, 1.0)
		# dramatic-fx：sqrt(area) 系数 0.78 → 1.05；基底 1.35 → 1.6。
		# 单 front 半径整体 +35%，配合下方拉长的 major_scale，覆盖面积约 ×2.
		front.radius = _hex_size * (1.6 + sqrt(float(c.get("area", 1))) * 1.05)
		var axis: Vector2 = c.get("axis", Vector2.RIGHT)
		if axis.length_squared() <= 0.0001:
			axis = Vector2.RIGHT
		front.axis = axis.normalized()
		front.stable_axis = front.axis
		# Drift-fix（2026-05-10，替代 Continuity-fix A）：
		# velocity 改为"实测每-snapshot 位移"——继承 cluster 用 (new_center - prev_center)，
		# 新生 cluster 用 avg_wind 作 fallback。weather_layer 在 set_weather_fronts 内
		# 会用这个 velocity 给 lerp target 做 forward-bias，让 lerp 终点本身就是
		# "下次 snapshot 到达时云应该在的位置"，避免回弹 + 让中间帧持续向前飘。
		# EMA 平滑 (lerp 0.5)：单帧 BFS 抖动产生的伪位移会被前一 tick 的 velocity 拉回。
		# 位移上限 = radius × 0.6：避免重聚类质心阶跃造成 visual 飞窜。
		var fallback_velocity: Vector2 = front.axis * front.radius * 0.4
		var measured_velocity: Vector2 = fallback_velocity
		var debug_observed_drift: Vector2 = Vector2.ZERO
		var debug_prev_center: Vector2 = Vector2.ZERO
		var debug_inherited: bool = false
		if c.has("inherited_from_center"):
			debug_inherited = true
			var prev_center_pos: Vector2 = c["inherited_from_center"]
			debug_prev_center = prev_center_pos
			var prev_velocity: Vector2 = c.get("inherited_from_velocity", Vector2.ZERO)
			var observed_drift: Vector2 = front.center - prev_center_pos
			var max_drift: float = front.radius * 0.6
			if observed_drift.length() > max_drift:
				observed_drift = observed_drift.normalized() * max_drift
			debug_observed_drift = observed_drift
			# EMA：50% 历史 + 50% 当前，缓和单 tick 的随机漂移
			measured_velocity = prev_velocity.lerp(observed_drift, 0.5)
		front.velocity = measured_velocity
		if DRIFT_DEBUG_LOG and i < 3:
			if debug_inherited:
				print("[weather-drift] day=%d c%d type=%d r=%.0f prev=%s new=%s drift=%s |drift|=%.1f vel=%s |vel|=%.1f" % [
					_day_counter, i, front.type, front.radius,
					str(debug_prev_center.round()), str(front.center.round()),
					str(debug_observed_drift.round()), debug_observed_drift.length(),
					str(front.velocity.round()), front.velocity.length(),
				])
			else:
				print("[weather-drift] day=%d c%d type=%d r=%.0f NEW center=%s vel(fallback)=%s |vel|=%.1f" % [
					_day_counter, i, front.type, front.radius,
					str(front.center.round()),
					str(front.velocity.round()), front.velocity.length(),
				])
		# dramatic-fx：椭圆比从 1.10/0.92 改 1.30/0.85，让 front 沿风向拉长，
		# 视觉上更像"风带云团"，不再是圆球。
		front.major_scale = 1.30
		front.minor_scale = 0.85
		# Continuity-fix：用继承代数代替原来硬写的 ttl=2/age=0/life=0.2。
		# 新生 cluster (age=0) → life=0.15，birth=smoothstep(0,0.32,0.15)≈0.30 渐入；
		# 继承 ≥3 tick → life≈0.45，birth=1.0，已成熟、不再每 tick 复位为半透明。
		# ttl 给个足够大的上限以避开 dissolve（smoothstep 起点 0.58）。
		var inherited_age: int = int(c.get("inherited_age", 0))
		front.age_days = inherited_age
		front.ttl_days = maxi(inherited_age * 3 + 12, 12)
		front.decay_per_day = 0.0
		front.edge_seed = float((i + 1) * 37 + int(front.center.x) * 3 + int(front.center.y) * 5)
		front.cloud_amount = clampf(float(c.get("cloud", 0.0)), 0.0, 1.0)
		front.precip_amount = clampf(float(c.get("precip", 0.0)), 0.0, 1.0)
		front.dissolve_amount = 0.0
		front.life_progress = clampf(0.15 + float(inherited_age) * 0.08, 0.15, 0.45)
		fronts.append(front)
		next_seeds.append({
			"type": front.type,
			"center": front.center,
			"age": inherited_age,
			"area": int(c.get("area", 1)),
			# Drift-fix：保存本 tick 实测速度，下 tick EMA 时作为历史项使用。
			"velocity": front.velocity,
		})
	# 持久化下一 tick 的种子列表（仅顶部 limit 个；溢出 limit 的小 cluster 不再继承
	# 给下 tick——避免 16 front 上限造成的"幽灵种子"持续抢 BFS 优先权）。
	_prev_summary_seeds = next_seeds
	return fronts

# Continuity-fix：找到一个适合做"继承种子"的 cell。
#   1. 若 prev_center 所在 cell 仍是同 type 且 ≥ hold 阈值 → 直接用
#   2. 否则 1 环邻居里找一个同 type 且 ≥ hold 阈值的 cell
#   3. 都没有 → 返回 null（这个 prev cluster 本 tick 死掉，让它进 fade-out 路径）
# 注意：picked_seed 必须未被其它 cluster 抢占（visited.has 检查）。
func _pick_inheritance_seed(
		seed_cell: HexCell, prev_type: int, map: MapData,
		visited: Dictionary, enter_thresh: float, hold_thresh: float) -> HexCell:
	# prev_center 所在 cell 仍可用 → 直接用
	if not visited.has(seed_cell):
		var swt: int = seed_cell.weather_type if seed_cell.weather_field_initialized else WeatherType.WT.CLEAR
		var si: float = seed_cell.weather_intensity if seed_cell.weather_field_initialized else 0.0
		var s_thresh: float = hold_thresh if _prev_summary_membership.has(seed_cell) else enter_thresh
		if swt == prev_type and si >= s_thresh:
			return seed_cell
	# Fallback：1 环邻居（即使 seed_cell 本身被其它继承簇抢走，邻居仍可能可用，
	# 这对应"两个 prev cluster 中心相邻、第二个被迫沿外缘扩展"的场景）。
	for nb: HexCell in _cell_neighbors(seed_cell, map):
		if nb == null or visited.has(nb):
			continue
		var nwt: int = nb.weather_type if nb.weather_field_initialized else WeatherType.WT.CLEAR
		var ni: float = nb.weather_intensity if nb.weather_field_initialized else 0.0
		var n_thresh: float = hold_thresh if _prev_summary_membership.has(nb) else enter_thresh
		if nwt == prev_type and ni >= n_thresh:
			return nb
	return null

# Continuity-fix：带 hysteresis 的 flood-fill。
# 从 seed 起 BFS，把所有同 type 且 ≥ 个性化阈值（在上 tick 簇内则用 hold，否则用 enter）的
# cell 收进同一 component。新成员的归属写到 new_membership[cell] = cluster_idx，
# 供下 tick 的 hysteresis 判定使用。
func _flood_fill_field_component(
		seed: HexCell, wt: int, map: MapData,
		visited: Dictionary, new_membership: Dictionary, cluster_idx: int,
		enter_thresh: float, hold_thresh: float) -> Dictionary:
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
		var cwt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var ci: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var thresh_self: float = hold_thresh if _prev_summary_membership.has(cell) else enter_thresh
		if cwt != wt or ci < thresh_self:
			continue
		cells.append(cell)
		new_membership[cell] = cluster_idx
		sum_pos += _cell_world_pos(cell)
		sum_axis += cell.wind_vector
		sum_cloud += cell.weather_cloud
		sum_precip += cell.weather_precip
		max_i = maxf(max_i, ci)
		for nb: HexCell in _cell_neighbors(cell, map):
			if nb == null or visited.has(nb):
				continue
			var nwt: int = nb.weather_type if nb.weather_field_initialized else WeatherType.WT.CLEAR
			var ni: float = nb.weather_intensity if nb.weather_field_initialized else 0.0
			var thresh_nb: float = hold_thresh if _prev_summary_membership.has(nb) else enter_thresh
			if nwt == wt and ni >= thresh_nb:
				visited[nb] = true
				queue.append(nb)
	if cells.is_empty():
		return {}
	var count: float = float(cells.size())
	return {
		"type": wt,
		"center": sum_pos / count,
		"axis": sum_axis / count,
		"cloud": sum_cloud / count,
		"precip": sum_precip / count,
		"intensity": max_i,
		"area": cells.size(),
		"score": max_i * sqrt(count),
	}

# dramatic-fx：把同型 + 圆心距 < (r1+r2) * MERGE_RATIO 的 component 合并。
# 用每 component 的"等效半径"（hex_size * sqrt(area) * 1.05）做距离阈值——
# 与下方 build_front 的 radius 公式同源，避免阈值与最终视觉半径脱节。
# 多轮迭代直到无可合并为止（典型 1-2 轮收敛）。
func _merge_nearby_components(components: Array) -> Array:
	const MERGE_RATIO: float = 0.65
	var changed: bool = true
	var rounds: int = 0
	while changed and rounds < 4:
		changed = false
		rounds += 1
		var n: int = components.size()
		var merged_into: Array[int] = []
		merged_into.resize(n)
		for i in range(n):
			merged_into[i] = -1
		for i in range(n):
			if merged_into[i] >= 0:
				continue
			var ci: Dictionary = components[i]
			var ai: float = float(ci.get("area", 1))
			var ri: float = _hex_size * sqrt(maxf(ai, 1.0)) * 1.05
			var center_i: Vector2 = ci.get("center", Vector2.ZERO)
			var type_i: int = int(ci.get("type", WeatherType.WT.CLEAR))
			for j in range(i + 1, n):
				if merged_into[j] >= 0:
					continue
				var cj: Dictionary = components[j]
				if int(cj.get("type", WeatherType.WT.CLEAR)) != type_i:
					continue
				var aj: float = float(cj.get("area", 1))
				var rj: float = _hex_size * sqrt(maxf(aj, 1.0)) * 1.05
				var center_j: Vector2 = cj.get("center", Vector2.ZERO)
				var dist: float = center_i.distance_to(center_j)
				if dist > (ri + rj) * MERGE_RATIO:
					continue
				# 合并 j → i：area 加和、center 按 area 加权、强度取 max、
				# cloud/precip 按 area 加权、axis 按 area 加权后归一化。
				var total: float = ai + aj
				ci["center"] = (center_i * ai + center_j * aj) / total
				ci["axis"] = (Vector2(ci.get("axis", Vector2.ZERO)) * ai + Vector2(cj.get("axis", Vector2.ZERO)) * aj) / total
				ci["cloud"] = (float(ci.get("cloud", 0.0)) * ai + float(cj.get("cloud", 0.0)) * aj) / total
				ci["precip"] = (float(ci.get("precip", 0.0)) * ai + float(cj.get("precip", 0.0)) * aj) / total
				ci["intensity"] = maxf(float(ci.get("intensity", 0.0)), float(cj.get("intensity", 0.0)))
				ci["area"] = total
				ci["score"] = float(ci.get("intensity", 0.0)) * sqrt(total)
				# Continuity-fix：合并时取较大的继承代数，让"两个老簇合并"的结果
				# 仍被视为成熟簇，而不是被新生分量拖回 birth 阶段。
				ci["inherited_age"] = maxi(
					int(ci.get("inherited_age", 0)),
					int(cj.get("inherited_age", 0))
				)
				ai = total
				ri = _hex_size * sqrt(maxf(ai, 1.0)) * 1.05
				center_i = ci.get("center", Vector2.ZERO)
				components[i] = ci
				merged_into[j] = i
				changed = true
		# 把未被合并的 component 收集为新一轮 components
		var next_components: Array = []
		for i in range(n):
			if merged_into[i] < 0:
				next_components.append(components[i])
		components = next_components
	return components

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
			if cell != null and cell.weather_field_initialized:
				return {
					"type": cell.weather_type,
					"intensity": cell.weather_intensity,
					"cloud": cell.weather_cloud,
					"precip": cell.weather_precip,
					"vapor": cell.weather_vapor,
					"instability": cell.weather_instability,
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
		summary_limit: int,
		convergence_refresh_stride: int = 4) -> void:
	_weather_field_enabled = enabled
	_field_advect_steps = clampi(advect_steps, 0, 1)
	_field_diffusion = clampf(diffusion, 0.0, 0.5)
	_field_condensation_gain = maxf(0.0, condensation_gain)
	_field_precip_decay = clampf(precip_decay, 0.0, 1.0)
	_field_orographic_lift_gain = maxf(0.0, orographic_lift_gain)
	_field_convergence_gain = maxf(0.0, convergence_gain)
	_field_convergence_refresh_stride = clampi(convergence_refresh_stride, 1, 12)
	_field_ocean_evap_gain = maxf(0.0, ocean_evap_gain)
	_field_summary_limit = clampi(summary_limit, 1, 12)
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
	var self_wp: Vector2 = _cell_world_pos(cell)
	var best_nb: HexCell = null
	var best_dot: float = 0.1
	for nb: HexCell in _cell_neighbors(cell, map):
		if nb == null:
			continue
		var nbwp: Vector2 = _cell_world_pos(nb)
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
	for nb: HexCell in _cell_neighbors(cell, map):
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
	if cell == null:
		return 0.0
	# 海面 cell：直接读自身洋流偏差
	if _is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	for nb: HexCell in _cell_neighbors(cell, map):
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
			# 暴风/季风：原 6-11 天 → 4-8 天，避免单地连下一周
			front.ttl_days = _rng.randi_range(4, 8)
			front.decay_per_day = 0.14
		WeatherType.WT.BLIZZARD:
			# 暴雪：原 8-14 天 → 5-10 天
			front.ttl_days = _rng.randi_range(5, 10)
			front.decay_per_day = 0.12
		WeatherType.WT.FOG:
			front.ttl_days = _rng.randi_range(5, 9)
			front.decay_per_day = 0.15
		_:
			# RAIN：原 10-16 天 → 6-11 天
			front.ttl_days = _rng.randi_range(6, 11)
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
