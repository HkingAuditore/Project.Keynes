class_name StageCMetrics
extends RefCounted

const SCHEMA_VERSION: int = 1
const DEFAULT_MIN_MEDIAN_MS: float = 0.25
const DEFAULT_MIN_MEDIAN_PERCENT: float = 3.0


static func finite_values(values: Array) -> Array:
	var out: Array = []
	for value in values:
		var number := float(value)
		if is_nan(number) or is_inf(number):
			continue
		out.append(number)
	return out


static func mean(values: Array) -> float:
	var clean := finite_values(values)
	if clean.is_empty():
		return 0.0
	var total := 0.0
	for value in clean:
		total += float(value)
	return total / float(clean.size())


static func percentile(values: Array, percentile_value: float) -> float:
	var clean := finite_values(values)
	if clean.is_empty():
		return 0.0
	clean.sort()
	var p := clampf(percentile_value, 0.0, 100.0) / 100.0
	var index := int(ceil(p * float(clean.size())) - 1.0)
	return float(clean[clampi(index, 0, clean.size() - 1)])


static func distribution(values: Array, thresholds: Array = [16.67, 33.33]) -> Dictionary:
	var clean := finite_values(values)
	var out: Dictionary = {
		"count": clean.size(),
		"mean": mean(clean),
		"p50": percentile(clean, 50.0),
		"p95": percentile(clean, 95.0),
		"p99": percentile(clean, 99.0),
		"max": percentile(clean, 100.0),
	}
	for threshold in thresholds:
		var t := float(threshold)
		var count := 0
		for value in clean:
			if float(value) >= t:
				count += 1
		var suffix := _number_suffix(t)
		out["ge_%s_ms_count" % suffix] = count
		out["ge_%s_ms_ratio" % suffix] = float(count) / float(clean.size()) \
			if not clean.is_empty() else 0.0
	return out


static func paired_verdict(pairs: Array,
		min_median_ms: float = DEFAULT_MIN_MEDIAN_MS,
		min_median_percent: float = DEFAULT_MIN_MEDIAN_PERCENT) -> Dictionary:
	var rows: Array = []
	var valid := 0
	var differences: Array = []
	var percentages: Array = []
	for raw in pairs:
		if not (raw is Dictionary):
			continue
		var pair: Dictionary = raw
		var off := float(pair.get("off_p50", pair.get("off", 0.0)))
		var active := float(pair.get("active_p50", pair.get("active", 0.0)))
		if is_nan(off) or is_inf(off) or is_nan(active) or is_inf(active):
			continue
		var difference := active - off
		var percent := difference / off * 100.0 if absf(off) > 0.000001 else INF
		var row := {
			"direction": String(pair.get("direction", "")),
			"off_p50": off,
			"active_p50": active,
			"active_minus_off_ms": difference,
			"active_minus_off_percent": percent,
		}
		rows.append(row)
		valid += 1
		differences.append(difference)
		percentages.append(percent)
	var median_ms := percentile(differences, 50.0)
	var median_percent := percentile(percentages, 50.0)
	var all_improved := valid == 3
	var all_regressed := valid == 3
	for difference in differences:
		all_improved = all_improved and float(difference) < 0.0
		all_regressed = all_regressed and float(difference) > 0.0
	var improvement := all_improved and median_ms <= -absf(min_median_ms) \
		and median_percent <= -absf(min_median_percent)
	var regression := all_regressed and median_ms >= absf(min_median_ms) \
		and median_percent >= absf(min_median_percent)
	var verdict := "stable_improvement" if improvement else \
		"stable_regression" if regression else "mixed_or_no_material_evidence"
	return {
		"verdict": verdict,
		"valid_pairs": valid,
		"pair_results": rows,
		"median_difference_ms": median_ms,
		"median_difference_percent": median_percent,
		"min_median_ms": min_median_ms,
		"min_median_percent": min_median_percent,
	}


static func validate_session_compatibility(left: Dictionary, right: Dictionary) -> Dictionary:
	var mismatches: Array = []
	var keys := [
		"build", "seed", "map_width", "map_height", "num_continents", "continent_size",
		"foreign_count", "speed", "graphics_profile", "window_width", "window_height",
		"vsync", "max_fps", "day_night", "overlay", "warmup_seconds",
		"record_seconds", "tick_stride", "cell_stride", "max_rows", "compact_fields",
	]
	for key in keys:
		var left_value = _session_value(left, key)
		var right_value = _session_value(right, key)
		if left_value == null or right_value == null or not _values_equal(left_value, right_value):
			mismatches.append({"key": key, "left": left_value, "right": right_value})
	var left_fields := _field_array(left)
	var right_fields := _field_array(right)
	if left_fields.is_empty() or right_fields.is_empty() or left_fields != right_fields:
		mismatches.append({"key": "fields", "left": left_fields, "right": right_fields})
	return {"ok": mismatches.is_empty(), "mismatches": mismatches}


static func missing_keys(left_keys: Array, right_keys: Array) -> Dictionary:
	var left := {}
	var right := {}
	for key in left_keys:
		left[String(key)] = true
	for key in right_keys:
		right[String(key)] = true
	var only_left: Array = []
	var only_right: Array = []
	for key in left:
		if not right.has(key):
			only_left.append(key)
	for key in right:
		if not left.has(key):
			only_right.append(key)
	only_left.sort()
	only_right.sort()
	return {"only_left": only_left, "only_right": only_right}


static func best_lag_match(reference_rows: Array, candidate_rows: Array,
		field: String, min_lag: int = -2, max_lag: int = 2) -> Dictionary:
	var candidate_by_key := {}
	for raw in candidate_rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		var key := _row_key(int(row.get("tick_idx", -1)), int(row.get("cell_index", -1)))
		candidate_by_key[key] = row
	var results: Array = []
	for lag in range(min_lag, max_lag + 1):
		var abs_total := 0.0
		var samples := 0
		for raw in reference_rows:
			if not (raw is Dictionary):
				continue
			var reference: Dictionary = raw
			var reference_value := float(reference.get(field, NAN))
			if is_nan(reference_value) or is_inf(reference_value):
				continue
			var key := _row_key(int(reference.get("tick_idx", -1)) + lag,
				int(reference.get("cell_index", -1)))
			if not candidate_by_key.has(key):
				continue
			var candidate_value := float(candidate_by_key[key].get(field, NAN))
			if is_nan(candidate_value) or is_inf(candidate_value):
				continue
			abs_total += absf(candidate_value - reference_value)
			samples += 1
		results.append({
			"lag": lag,
			"samples": samples,
			"mean_abs_diff": abs_total / float(samples) if samples > 0 else INF,
		})
	var best := {}
	for row in results:
		if best.is_empty() or float(row["mean_abs_diff"]) < float(best["mean_abs_diff"]):
			best = row
	return {"field": field, "best": best, "lags": results}


static func harness_adjusted_metrics(run_ms: float, writeback_window_ms: float,
		consume_ms: float, idle_wait_ms: float, effective_days: float) -> Dictionary:
	var raw := maxf(float(run_ms), 0.0)
	var window := maxf(float(writeback_window_ms), 0.0)
	var consume := clampf(float(consume_ms), 0.0, window if window > 0.0 else INF)
	var idle := clampf(float(idle_wait_ms), 0.0, window if window > 0.0 else INF)
	var adjusted := maxf(raw - idle, 0.0)
	var lower_bound := maxf(raw - window, 0.0)
	return {
		"run_ms": raw,
		"harness_writeback_window_ms": window,
		"harness_writeback_consume_ms": consume,
		"harness_idle_wait_ms": idle,
		"harness_adjusted_run_ms": adjusted,
		"harness_lower_bound_run_ms": lower_bound,
		"raw_days_per_second": _days_per_second(effective_days, raw),
		"adjusted_days_per_second": _days_per_second(effective_days, adjusted),
		"lower_bound_days_per_second": _days_per_second(effective_days, lower_bound),
	}


static func _days_per_second(days: float, elapsed_ms: float) -> float:
	return float(days) * 1000.0 / elapsed_ms if elapsed_ms > 0.000001 else 0.0


static func _session_value(payload: Dictionary, key: String):
	if payload.has(key):
		return payload[key]
	var session = payload.get("session", {})
	if session is Dictionary and (session as Dictionary).has(key):
		return (session as Dictionary)[key]
	return null


static func _field_array(payload: Dictionary) -> Array:
	var fields = payload.get("soa_fields", payload.get("fields", []))
	var out: Array = []
	if fields is Array:
		for field in fields:
			out.append(String(field))
	return out


static func _values_equal(left, right) -> bool:
	if typeof(left) == TYPE_FLOAT or typeof(right) == TYPE_FLOAT:
		return is_equal_approx(float(left), float(right))
	return left == right


static func _row_key(tick: int, cell: int) -> String:
	return "%d|%d" % [tick, cell]


static func _number_suffix(value: float) -> String:
	var text := ("%.2f" % value).replace(".", "_")
	return text.rstrip("0").rstrip("_")
