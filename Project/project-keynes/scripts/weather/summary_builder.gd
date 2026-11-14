extends "res://scripts/weather/weather_context.gd"
class_name DCWeatherSummaryBuilder


func _init(weather_system) -> void:
	_weather_system = weather_system


func _build_field_summary_fronts_legacy(host, map: MapData, world: WorldData) -> Array[WeatherFront]:
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
	#   Step 1（C）以 host._prev_summary_seeds 为优先种子做 BFS，让 cluster 跨 tick 保身份。#   Step 1（C）以 _prev_summary_seeds 为优先种子做 BFS，让 cluster 跨 tick 保身份。
	#   Step 2（D）阈值滞回：上 tick 在某簇内的 cell 用 _HOLD=0.06 留簇里；新加入需 ≥ _ENTER=0.10。
	#   Step 3（A）给每个 front 设 velocity = axis × radius × 0.4（与 host._spawn_random_front 同源），#   Step 3（A）给每个 front 设 velocity = axis × radius × 0.4（与 _spawn_random_front 同源），
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
	var prev_seed_list: Array = host._prev_summary_seeds.duplicate()
	prev_seed_list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("area", 1)) > int(b.get("area", 1))
	)
	for prev in prev_seed_list:
		var prev_type: int = int(prev.get("type", WeatherType.WT.CLEAR))
		var prev_center: Vector2 = prev.get("center", Vector2.ZERO)
		var cube = HexUtils.world_to_cube(prev_center, host._hex_size)
		var seed_cell: HexCell = map.get_cell_by_cube(cube)
		if seed_cell == null:
			continue
		# 找到合格种子：优先 prev_center 所在 cell；若 type 改变或强度跌穿 hold，
		# 再在 1 环邻居里寻找同型且 ≥ hold 阈值的 cell 作为继承种子。
		var picked_seed: HexCell = host._pick_inheritance_seed(
			seed_cell, prev_type, map, visited,
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if picked_seed == null:
			continue
		var component = host._flood_fill_field_component(
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
		var thresh: float = _SUMMARY_INTENSITY_HOLD if host._prev_summary_membership.has(seed_cell) else _SUMMARY_INTENSITY_ENTER
		if intensity < thresh or wt == WeatherType.WT.CLEAR:
			visited[seed_cell] = true
			continue
		var component = host._flood_fill_field_component(
			seed_cell, wt, map, visited, new_membership, components.size(),
			_SUMMARY_INTENSITY_ENTER, _SUMMARY_INTENSITY_HOLD
		)
		if not component.is_empty():
			component["inherited_age"] = 0
			components.append(component)

	# 跨 tick 状态更新（在 host._merge_nearby_components 重排前记录 cell 归属）。# 跨 tick 状态更新（在 _merge_nearby_components 重排前记录 cell 归属）。
	host._prev_summary_membership = new_membership

	# dramatic-fx：同型相邻合并 pass。flood-fill 后仍可能存在"被一两格 CLEAR 隔开"
	# 的同型团块（云之间的过渡空隙），这些在视觉上是连续的一片云，但作为两个 front
	# 下发会被 shader 各自做包络衰减 → 边界处出现"双圆叠加 + 中间空"的诡异形态。
	# 这里 O(n²) 扫一遍，把同型且圆心距 < (r1+r2)*0.65 的两个 component 合并，
	# 中心按 area 加权平均、area 累加、intensity 取 max。
	components = host._merge_nearby_components(components)

	components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("score", 0.0)) > float(b.get("score", 0.0))
	)

	var fronts: Array[WeatherFront] = [] as Array[WeatherFront]
	var next_seeds: Array = []
	var limit: int = mini(host._field_summary_limit, components.size())
	for i in range(limit):
		var c: Dictionary = components[i]
		var front = WeatherFront.new()
		front.type = int(c.get("type", WeatherType.WT.CLEAR))
		front.center = c.get("center", Vector2.ZERO)
		front.intensity = clampf(float(c.get("intensity", 0.0)), 0.0, 1.0)
		# dramatic-fx：sqrt(area) 系数 0.78 → 1.05；基底 1.35 → 1.6。
		# 单 front 半径整体 +35%，配合下方拉长的 major_scale，覆盖面积约 ×2.
		front.radius = host._hex_size * (1.6 + sqrt(float(c.get("area", 1))) * 1.05)
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
		if host.DRIFT_DEBUG_LOG and i < 3:
			if debug_inherited:
				print("[weather-drift] day=%d c%d type=%d r=%.0f prev=%s new=%s drift=%s |drift|=%.1f vel=%s |vel|=%.1f" % [
					host._day_counter, i, front.type, front.radius,
					str(debug_prev_center.round()), str(front.center.round()),
					str(debug_observed_drift.round()), debug_observed_drift.length(),
					str(front.velocity.round()), front.velocity.length(),
				])
			else:
				print("[weather-drift] day=%d c%d type=%d r=%.0f NEW center=%s vel(fallback)=%s |vel|=%.1f" % [
					host._day_counter, i, front.type, front.radius,
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
		front.front_temperature_advection = float(c.get("temp_advection", 0.0))
		front.front_diagnostic_kind = int(c.get("front_diag_kind", WeatherFront.FRONT_DIAG_NONE))
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
	host._prev_summary_seeds = next_seeds
	return fronts

# Continuity-fix：找到一个适合做"继承种子"的 cell。
#   1. 若 prev_center 所在 cell 仍是同 type 且 ≥ hold 阈值 → 直接用
#   2. 否则 1 环邻居里找一个同 type 且 ≥ hold 阈值的 cell
#   3. 都没有 → 返回 null（这个 prev cluster 本 tick 死掉，让它进 fade-out 路径）
# 注意：picked_seed 必须未被其它 cluster 抢占（visited.has 检查）。

func _pick_inheritance_seed(host,
		seed_cell: HexCell, prev_type: int, map: MapData,
		visited: Dictionary, enter_thresh: float, hold_thresh: float) -> HexCell:
	# prev_center 所在 cell 仍可用 → 直接用
	if not visited.has(seed_cell):
		var swt: int = seed_cell.weather_type if seed_cell.weather_field_initialized else WeatherType.WT.CLEAR
		var si: float = seed_cell.weather_intensity if seed_cell.weather_field_initialized else 0.0
		var s_thresh: float = hold_thresh if host._prev_summary_membership.has(seed_cell) else enter_thresh
		if swt == prev_type and si >= s_thresh:
			return seed_cell
	# Fallback：1 环邻居（即使 seed_cell 本身被其它继承簇抢走，邻居仍可能可用，
	# 这对应"两个 prev cluster 中心相邻、第二个被迫沿外缘扩展"的场景）。
	for nb: HexCell in host._cell_neighbors(seed_cell, map):
		if nb == null or visited.has(nb):
			continue
		var nwt: int = nb.weather_type if nb.weather_field_initialized else WeatherType.WT.CLEAR
		var ni: float = nb.weather_intensity if nb.weather_field_initialized else 0.0
		var n_thresh: float = hold_thresh if host._prev_summary_membership.has(nb) else enter_thresh
		if nwt == prev_type and ni >= n_thresh:
			return nb
	return null

# Continuity-fix：带 hysteresis 的 flood-fill。
# 从 seed 起 BFS，把所有同 type 且 ≥ 个性化阈值（在上 tick 簇内则用 hold，否则用 enter）的
# cell 收进同一 component。新成员的归属写到 new_membership[cell] = cluster_idx，
# 供下 tick 的 hysteresis 判定使用。

func _flood_fill_field_component(host,
		seed: HexCell, wt: int, map: MapData,
		visited: Dictionary, new_membership: Dictionary, cluster_idx: int,
		enter_thresh: float, hold_thresh: float) -> Dictionary:
	var queue: Array = [seed]
	visited[seed] = true
	var cells: Array = []
	var sum_pos = Vector2.ZERO
	var sum_axis = Vector2.ZERO
	var sum_cloud: float = 0.0
	var sum_precip: float = 0.0
	var sum_temp_adv: float = 0.0
	var temp_adv_weight: float = 0.0
	var max_i: float = 0.0
	while not queue.is_empty():
		var cell: HexCell = queue.pop_front()
		var cwt: int = cell.weather_type if cell.weather_field_initialized else WeatherType.WT.CLEAR
		var ci: float = cell.weather_intensity if cell.weather_field_initialized else 0.0
		var thresh_self: float = hold_thresh if host._prev_summary_membership.has(cell) else enter_thresh
		if cwt != wt or ci < thresh_self:
			continue
		cells.append(cell)
		new_membership[cell] = cluster_idx
		sum_pos += host._cell_world_pos(cell)
		sum_axis += cell.wind_vector
		sum_cloud += cell.weather_cloud
		sum_precip += cell.weather_precip
		var wind: Vector2 = cell.wind_vector
		if wind.length_squared() > 0.0001:
			var upstream: HexCell = host._neighbor_aligned(cell, map, -wind)
			var downstream: HexCell = host._neighbor_aligned(cell, map, wind)
			if downstream != null:
				var upstream_temp: float = upstream.temperature if upstream != null else cell.temperature
				var local_adv: float = upstream_temp - downstream.temperature
				sum_temp_adv += local_adv * ci
				temp_adv_weight += ci
		max_i = maxf(max_i, ci)
		for nb: HexCell in host._cell_neighbors(cell, map):
			if nb == null or visited.has(nb):
				continue
			var nwt: int = nb.weather_type if nb.weather_field_initialized else WeatherType.WT.CLEAR
			var ni: float = nb.weather_intensity if nb.weather_field_initialized else 0.0
			var thresh_nb: float = hold_thresh if host._prev_summary_membership.has(nb) else enter_thresh
			if nwt == wt and ni >= thresh_nb:
				visited[nb] = true
				queue.append(nb)
	if cells.is_empty():
		return {}
	var count: float = float(cells.size())
	var temp_advection: float = sum_temp_adv / maxf(temp_adv_weight, 0.001)
	return {
		"type": wt,
		"center": sum_pos / count,
		"axis": sum_axis / count,
		"cloud": sum_cloud / count,
		"precip": sum_precip / count,
		"temp_advection": temp_advection,
		"front_diag_kind": host._front_diagnostic_kind(temp_advection),
		"intensity": max_i,
		"area": cells.size(),
		"score": max_i * sqrt(count),
	}

# dramatic-fx：把同型 + 圆心距 < (r1+r2) * MERGE_RATIO 的 component 合并。
# 用每 component 的"等效半径"（hex_size * sqrt(area) * 1.05）做距离阈值——
# 与下方 build_front 的 radius 公式同源，避免阈值与最终视觉半径脱节。
# 多轮迭代直到无可合并为止（典型 1-2 轮收敛）。

func _merge_nearby_components(host, components: Array) -> Array:
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
			var ri: float = host._hex_size * sqrt(maxf(ai, 1.0)) * 1.05
			var center_i: Vector2 = ci.get("center", Vector2.ZERO)
			var type_i: int = int(ci.get("type", WeatherType.WT.CLEAR))
			for j in range(i + 1, n):
				if merged_into[j] >= 0:
					continue
				var cj: Dictionary = components[j]
				if int(cj.get("type", WeatherType.WT.CLEAR)) != type_i:
					continue
				var aj: float = float(cj.get("area", 1))
				var rj: float = host._hex_size * sqrt(maxf(aj, 1.0)) * 1.05
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
				var temp_adv: float = (float(ci.get("temp_advection", 0.0)) * ai + float(cj.get("temp_advection", 0.0)) * aj) / total
				ci["temp_advection"] = temp_adv
				ci["front_diag_kind"] = host._front_diagnostic_kind(temp_adv)
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
				ri = host._hex_size * sqrt(maxf(ai, 1.0)) * 1.05
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


func build(map: MapData, world: WorldData) -> Array[WeatherFront]:
	if _weather_system == null or map == null or world == null:
		return [] as Array[WeatherFront]
	return _build_field_summary_fronts_legacy(_weather_system, map, world)

func reset() -> void:
	if _weather_system != null:
		_weather_system._prev_summary_membership.clear()
		_weather_system._prev_summary_seeds.clear()

func describe() -> String:
	return "DCWeatherSummaryBuilder(owner=%s seeds=%d)" % [
		"ws" if _weather_system != null else "(null)",
		_weather_system._prev_summary_seeds.size() if _weather_system != null else 0,
	]
