extends RefCounted

## Physical and weather diagnostics sampled by the tile recorder.

const TileCsv = preload("res://scripts/ui/tile_data_recorder_csv.gd")


static func _physical_field_stats(map_data) -> Dictionary:
	var out: Dictionary = {}
	var slp_arr = map_data.get("slp_arr")
	if typeof(slp_arr) == TYPE_PACKED_FLOAT32_ARRAY and not slp_arr.is_empty():
		out["slp_abs_p95"] = _packed_float_abs_p95(slp_arr)
	var wind_speed_arr = map_data.get("wind_speed_arr")
	if typeof(wind_speed_arr) == TYPE_PACKED_FLOAT32_ARRAY and not wind_speed_arr.is_empty():
		out["wind_mag_p95"] = _packed_float_abs_p95(wind_speed_arr)
	var transport_arr = map_data.get("temperature_transport_anomaly_arr")
	if typeof(transport_arr) == TYPE_PACKED_FLOAT32_ARRAY and not transport_arr.is_empty():
		out["transport_abs_p95"] = _packed_float_abs_p95(transport_arr)
		out["transport_nonzero_ratio"] = _packed_float_nonzero_ratio(transport_arr, 0.0001)
	var ocean_stats: Dictionary = _packed_vector_mag_stats(map_data.get("ocean_current_x_arr"), map_data.get("ocean_current_y_arr"))
	if not ocean_stats.is_empty():
		out["ocean_mag_p95"] = ocean_stats["p95"]
	var upwelling_arr = map_data.get("upwelling_strength_arr")
	if typeof(upwelling_arr) == TYPE_PACKED_FLOAT32_ARRAY and not upwelling_arr.is_empty():
		out["upwelling_abs_p95"] = _packed_float_abs_p95(upwelling_arr)
	return out


static func _weather_transition_stats(map_data) -> Dictionary:
	var type_arr = map_data.get("weather_type_arr")
	var target_arr = map_data.get("weather_target_type_arr")
	var alpha_arr = map_data.get("weather_transition_alpha_arr")
	if TileCsv._array_size(type_arr) <= 0 or TileCsv._array_size(target_arr) != TileCsv._array_size(type_arr) or TileCsv._array_size(alpha_arr) != TileCsv._array_size(type_arr):
		return {}
	var n: int = TileCsv._array_size(type_arr)
	var mismatch_count: int = 0
	var transitioning_count: int = 0
	var alpha_sum: float = 0.0
	var alpha_values: Array = []
	for i in range(n):
		if int(type_arr[i]) != int(target_arr[i]):
			mismatch_count += 1
		var alpha: float = float(alpha_arr[i])
		if is_nan(alpha) or is_inf(alpha):
			alpha = 0.0
		alpha = clampf(alpha, 0.0, 1.0)
		if alpha > 0.0 and alpha < 0.999:
			transitioning_count += 1
			alpha_sum += alpha
			alpha_values.append(alpha)
	alpha_values.sort()
	return {
		"target_mismatch_count": mismatch_count,
		"transitioning_count": transitioning_count,
		"transition_alpha_mean": alpha_sum / float(maxi(transitioning_count, 1)),
		"transition_alpha_p95": _sorted_p95(alpha_values),
	}


static func _packed_vector_mag_stats(x_arr, y_arr) -> Dictionary:
	if typeof(x_arr) != TYPE_PACKED_FLOAT32_ARRAY or typeof(y_arr) != TYPE_PACKED_FLOAT32_ARRAY:
		return {}
	var n: int = mini(x_arr.size(), y_arr.size())
	if n <= 0:
		return {}
	var values: Array = []
	for i in range(n):
		var x: float = float(x_arr[i])
		var y: float = float(y_arr[i])
		if is_nan(x) or is_inf(x) or is_nan(y) or is_inf(y):
			continue
		values.append(sqrt(x * x + y * y))
	values.sort()
	if values.is_empty():
		return {}
	return { "p95": _sorted_p95(values) }


static func _packed_float_abs_p95(arr) -> float:
	var values: Array = []
	for i in range(arr.size()):
		var v: float = float(arr[i])
		if is_nan(v) or is_inf(v):
			continue
		values.append(absf(v))
	values.sort()
	return _sorted_p95(values)


static func _packed_float_nonzero_ratio(arr, eps: float = 0.0001) -> float:
	var total: int = 0
	var nonzero: int = 0
	for i in range(arr.size()):
		var v: float = float(arr[i])
		if is_nan(v) or is_inf(v):
			continue
		total += 1
		if absf(v) > eps:
			nonzero += 1
	return float(nonzero) / float(maxi(total, 1))


static func _packed_float_p95(arr) -> float:
	var values: Array = []
	values.resize(arr.size())
	for i in range(arr.size()):
		values[i] = float(arr[i])
	values.sort()
	return _sorted_p95(values)


static func _sorted_p95(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var pos: int = clampi(int(floor(float(values.size() - 1) * 0.95)), 0, values.size() - 1)
	return float(values[pos])
