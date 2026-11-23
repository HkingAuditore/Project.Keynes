extends RefCounted

## Stateless physics helpers for DCWeatherFieldSolver; all state stays on host.

static func orographic_lift_for_cell(host, cell: HexCell, map: MapData, wind_dir: Vector2) -> float:
	var upstream: HexCell = host._neighbor_aligned(cell, map, -wind_dir)
	if upstream == null:
		return 0.0
	var diff: float = cell.elevation - upstream.elevation
	if diff > 0.02:
		return clampf(diff * 2.2, 0.0, 1.0)
	if diff < -0.02:
		return clampf(diff * 1.6, -1.0, 0.0)
	return 0.0


static func orographic_lift_from_upstream_idx(host, idx: int, upstream_idx: int, cells: Array) -> float:
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


## 风场辐合：有符号净流入（W9 之后生产只剩这一种口径，legacy 分支与开关已退役）。
##
## 旧实现是半波整流均值 `mean_d max(0, cos(self→nb, wind_nb))`：六角格 6 个等间隔方向上
## 它恒在 0.29–1.25，均匀流（零辐散）也读 1/3 —— 与辐合无关。回归见
## tests/world/weather_convergence_metric_test.gd。
##
## 与 C++ `wf_wind_convergence_idx_xy` / `wf_wind_convergence_idx_cached` 逐位对应：
##   w_d     = clamp(|v_nb| / 1.2, 0, 1.25)
##   inflow  = Σ_d max(0,  cos_in_d) · w_d
##   outflow = Σ_d max(0, -cos_in_d) · w_d
##   conv    = clamp((inflow - outflow) / (inflow + outflow), 0, 1)
static func wind_convergence_for_cell(host, cell: HexCell, map: MapData) -> float:
	if host._weather_system == null or cell == null:
		return 0.0
	var self_wp: Vector2 = host._weather_system._cell_world_pos(cell)
	var wrap_width_x: float = host._world_wrap_width_x(map)
	var net_in := 0.0
	var net_out := 0.0
	for nb: HexCell in host._weather_system._cell_neighbors(cell, map):
		if nb == null:
			continue
		var nb_wp: Vector2 = host._weather_system._cell_world_pos(nb)
		var dir_to_self: Vector2 = host._wrapped_delta(nb_wp, self_wp, wrap_width_x)
		if dir_to_self.length_squared() <= 0.0001:
			continue
		var wind: Vector2 = nb.wind_vector
		if wind.length_squared() <= 0.0001:
			continue
		var cos_in: float = dir_to_self.normalized().dot(wind.normalized())
		var speed_w: float = _convergence_speed_weight(nb, wind)
		if cos_in > 0.0:
			net_in += cos_in * speed_w
		else:
			net_out += -cos_in * speed_w
	return _convergence_net_value(net_in, net_out)


static func wind_convergence_idx(host, idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> float:
	var self_wp: Vector2 = cell_pos[idx]
	var base: int = idx * 6
	var net_in := 0.0
	var net_out := 0.0
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var dir_to_self: Vector2 = host._wrapped_delta(cell_pos[nb_idx], self_wp, host._field_slice_wrap_width_x)
		if dir_to_self.length_squared() <= 0.0001:
			continue
		var nb: HexCell = cells[nb_idx]
		var wind: Vector2 = nb.wind_vector
		if wind.length_squared() <= 0.0001:
			continue
		var cos_in: float = dir_to_self.normalized().dot(wind.normalized())
		var speed_w: float = _convergence_speed_weight(nb, wind)
		if cos_in > 0.0:
			net_in += cos_in * speed_w
		else:
			net_out += -cos_in * speed_w
	return _convergence_net_value(net_in, net_out)


## 与 C++ `wf_wind_speed_norm` + 净流入口径的权重逐字对应：
##   wsp = wind_speed > 0 ? wind_speed : |wind|；speed_w = clamp(wsp / 1.2, 0, 1.25)
static func _convergence_speed_weight(nb: HexCell, wind: Vector2) -> float:
	var wsp: float = float(nb.wind_speed)
	if wsp <= 0.0001:
		wsp = sqrt(wind.length_squared())
	var speed_w: float = wsp / 1.2
	if speed_w < 0.0:
		speed_w = 0.0
	elif speed_w > 1.25:
		speed_w = 1.25
	return speed_w


## 与 C++ 尾部一致：denom 过小返回 0，net<0（辐散）钳 0。
static func _convergence_net_value(net_in: float, net_out: float) -> float:
	var denom: float = net_in + net_out
	if denom <= 0.0001:
		return 0.0
	var net: float = (net_in - net_out) / denom
	if net <= 0.0:
		return 0.0
	return minf(net, 1.0)


static func avg_ocean_anomaly_at_idx(host, idx: int, cells: Array, neighbor_indices: PackedInt32Array) -> float:
	if host._weather_system == null:
		return 0.0
	var cell: HexCell = cells[idx]
	if host._weather_system._is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	var base: int = idx * 6
	for d in range(6):
		var nb_idx: int = neighbor_indices[base + d]
		if nb_idx < 0:
			continue
		var nb: HexCell = cells[nb_idx]
		if host._weather_system._is_water_terrain(int(nb.terrain)):
			sum_an += nb.temperature_transport_anomaly
			n_water += 1
	if n_water == 0:
		return 0.0
	return sum_an / float(n_water)


static func avg_ocean_anomaly_at(host, cell: HexCell, map: MapData) -> float:
	if cell == null or host._weather_system == null:
		return 0.0
	# 海面 cell：直接读自身洋流偏差
	if host._weather_system._is_water_terrain(int(cell.terrain)):
		return cell.temperature_transport_anomaly
	var sum_an: float = 0.0
	var n_water: int = 0
	for nb: HexCell in host._weather_system._cell_neighbors(cell, map):
		if nb != null and host._weather_system._is_water_terrain(int(nb.terrain)):
			sum_an += nb.temperature_transport_anomaly
			n_water += 1
	if n_water == 0:
		return 0.0
	return sum_an / float(n_water)
