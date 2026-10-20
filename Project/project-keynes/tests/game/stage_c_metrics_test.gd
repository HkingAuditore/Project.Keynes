extends SceneTree

const MetricsScript = preload("res://scripts/tools/stage_c_metrics.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_test_distribution()
	_test_paired_verdict()
	_test_session_compatibility()
	_test_missing_keys_and_lag()
	_test_harness_formula()
	print("=== stage_c_metrics test summary: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1


func _test_distribution() -> void:
	var out: Dictionary = MetricsScript.distribution([1.0, 2.0, 3.0, 20.0, 40.0])
	_expect(out.count == 5 and is_equal_approx(out.p50, 3.0), "nearest-rank distribution")
	_expect(is_equal_approx(out.ge_16_67_ms_ratio, 0.4), "16.67ms ratio")
	_expect(is_equal_approx(out.ge_33_33_ms_ratio, 0.2), "33.33ms ratio")


func _test_paired_verdict() -> void:
	var improvement: Dictionary = MetricsScript.paired_verdict([
		{"off": 10.0, "active": 9.0}, {"off": 11.0, "active": 10.0},
		{"off": 12.0, "active": 11.0},
	])
	_expect(improvement.verdict == "stable_improvement", "three-direction stable improvement")
	var median_threshold: Dictionary = MetricsScript.paired_verdict([
		{"off": 10.0, "active": 9.9}, {"off": 10.0, "active": 9.0},
		{"off": 10.0, "active": 9.0},
	])
	_expect(median_threshold.verdict == "stable_improvement",
		"consistent directions use the median threshold")
	var incomplete: Dictionary = MetricsScript.paired_verdict([{"off": 10.0, "active": 9.0}])
	_expect(incomplete.verdict == "mixed_or_no_material_evidence", "fewer than three pairs rejected")
	var mixed: Dictionary = MetricsScript.paired_verdict([
		{"off": 10.0, "active": 9.0}, {"off": 10.0, "active": 10.1},
		{"off": 10.0, "active": 9.0},
	])
	_expect(mixed.verdict == "mixed_or_no_material_evidence", "mixed direction rejected")


func _session(mode: String = "ACTIVE") -> Dictionary:
	return {
		"session": {
			"build": "Debug", "seed": 20260718, "map_width": 60, "map_height": 40,
			"num_continents": 2, "continent_size": 0.5, "foreign_count": 3,
			"speed": 50.0, "graphics_profile": "high", "window_width": 1600,
			"window_height": 960, "vsync": false, "max_fps": 0,
			"day_night": true, "overlay": false, "warmup_seconds": 5.0,
			"record_seconds": 30.0, "tick_stride": 1, "cell_stride": 1,
			"max_rows": 50000000,
			"compact_fields": false, "authority_mode": mode,
		},
		"soa_fields": ["temp_arr", "moisture_arr"],
	}


func _test_session_compatibility() -> void:
	var left := _session("ACTIVE")
	var right := _session("OFF")
	_expect(MetricsScript.validate_session_compatibility(left, right).ok,
		"authority mode may differ while measurement metadata matches")
	right.session.seed = 7
	_expect(not MetricsScript.validate_session_compatibility(left, right).ok, "seed mismatch rejected")
	right = _session("OFF")
	right.soa_fields = ["temp_arr"]
	_expect(not MetricsScript.validate_session_compatibility(left, right).ok, "field schema mismatch rejected")
	right = _session("OFF")
	right.session.erase("graphics_profile")
	_expect(not MetricsScript.validate_session_compatibility(left, right).ok, "missing session key rejected")


func _test_missing_keys_and_lag() -> void:
	var missing: Dictionary = MetricsScript.missing_keys(["1|0", "2|0"], ["2|0", "3|0"])
	_expect(missing.only_left == ["1|0"] and missing.only_right == ["3|0"], "missing tick/cell keys")
	var reference := [
		{"tick_idx": 1, "cell_index": 0, "v": 4.0},
		{"tick_idx": 2, "cell_index": 0, "v": 5.0},
	]
	var candidate := [
		{"tick_idx": 2, "cell_index": 0, "v": 4.0},
		{"tick_idx": 3, "cell_index": 0, "v": 5.0},
	]
	_expect(MetricsScript.best_lag_match(reference, candidate, "v").best.lag == 1,
		"best lag detects +1 tick")


func _test_harness_formula() -> void:
	var out: Dictionary = MetricsScript.harness_adjusted_metrics(1000.0, 400.0, 50.0, 350.0, 100.0)
	_expect(is_equal_approx(out.harness_adjusted_run_ms, 650.0), "adjusted subtracts idle only")
	_expect(is_equal_approx(out.harness_lower_bound_run_ms, 600.0), "lower bound subtracts whole window")
	_expect(is_equal_approx(out.raw_days_per_second, 100.0), "raw days per second")
