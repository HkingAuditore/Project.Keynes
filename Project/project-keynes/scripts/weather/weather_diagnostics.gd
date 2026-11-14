extends RefCounted

## Stateless weather diagnostics; WeatherSystem remains the state owner.

static func cell_world_pos(host, cell: HexCell) -> Vector2:
	if host._tick_cell_pos.has(cell):
		return host._tick_cell_pos[cell]
	return HexUtils.cube_to_world(cell.q, cell.r, host._hex_size)

static func front_diagnostic_kind(host, temp_advection: float) -> int:
	const FRONT_TEMP_ADVECTION_THRESHOLD: float = 0.015
	if temp_advection > FRONT_TEMP_ADVECTION_THRESHOLD:
		return WeatherFront.FRONT_DIAG_COLD
	if temp_advection < -FRONT_TEMP_ADVECTION_THRESHOLD:
		return WeatherFront.FRONT_DIAG_WARM
	return WeatherFront.FRONT_DIAG_NONE


static func front_diagnostic_counts(host, fronts: Array) -> Dictionary:
	var cold_count: int = 0
	var warm_count: int = 0
	for front in fronts:
		if front == null:
			continue
		match int(front.front_diagnostic_kind):
			WeatherFront.FRONT_DIAG_COLD:
				cold_count += 1
			WeatherFront.FRONT_DIAG_WARM:
				warm_count += 1
	return {
		"weather_cold_front_count": cold_count,
		"weather_warm_front_count": warm_count,
	}


static func prev_vapor_cached(host, cell: HexCell, map: MapData, prev_vapor: PackedFloat32Array) -> float:
	var idx: int = map.index_of(cell)
	if idx >= 0 and idx < prev_vapor.size():
		return prev_vapor[idx]
	return cell.weather_vapor if cell.weather_field_initialized else cell.moisture

