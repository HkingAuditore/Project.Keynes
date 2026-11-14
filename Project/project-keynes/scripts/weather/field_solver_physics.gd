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


static func wind_convergence_for_cell(host, cell: HexCell, map: MapData) -> float:
	if host._weather_system == null or cell == null:
		return 0.0
	var self_wp: Vector2 = host._weather_system._cell_world_pos(cell)
	var wrap_width_x: float = host._world_wrap_width_x(map)
	var incoming: float = 0.0
	var checked: int = 0
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
		incoming += maxf(0.0, dir_to_self.normalized().dot(wind.normalized()))
		checked += 1
	if checked == 0:
		return 0.0
	return clampf(incoming / float(checked), 0.0, 1.0)


static func wind_convergence_idx(host, idx: int, cells: Array, cell_pos: PackedVector2Array, neighbor_indices: PackedInt32Array) -> float:
	var self_wp: Vector2 = cell_pos[idx]
	var incoming: float = 0.0
	var checked: int = 0
	var base: int = idx * 6
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
		incoming += maxf(0.0, dir_to_self.normalized().dot(wind.normalized()))
		checked += 1
	if checked == 0:
		return 0.0
	return clampf(incoming / float(checked), 0.0, 1.0)

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
