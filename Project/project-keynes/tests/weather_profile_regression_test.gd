# weather_profile_regression_test.gd
# Runtime regression test for the WeatherProfile refactor.
#
# Verifies that the data loaded from .tres matches the exact values that
# were hardcoded in weather_type.gd and weather_layer.gd prior to the refactor.
# If any assertion fails the test prints a clear failure line with context.
#
# Headless execution (recommended):
#     godot --headless --script tests/weather_profile_regression_test.gd --quit
#
# Or invoke manually from a running scene via `load(...).new()._run()`.

extends SceneTree

# ─── Baseline from the pre-refactor hardcoded dictionaries ──────────────
# Keep these in sync with the original weather_type.gd dictionaries.

const BASELINE_MOISTURE := {
	0: 0.00,   # CLEAR
	1: 0.18,   # RAIN
	2: 0.30,   # STORM
	3: 0.20,   # BLIZZARD
	4: -0.30,  # DROUGHT
	5: 0.04,   # FOG
	6: -0.18,  # HEATWAVE
	7: 0.40,   # MONSOON
}

const BASELINE_TEMP := {
	0: 0.00,
	1: -0.04,
	2: -0.06,
	3: -0.18,
	4: 0.06,
	5: -0.02,
	6: 0.18,
	7: -0.04,
}

const BASELINE_CAN_SNOW := {
	0: false, 1: false, 2: false, 3: true,
	4: false, 5: false, 6: false, 7: false,
}

const BASELINE_CAN_FLOOD := {
	0: false, 1: true, 2: true, 3: false,
	4: false, 5: false, 6: false, 7: true,
}

const BASELINE_NAME := {
	0: "晴朗", 1: "降雨", 2: "雷暴", 3: "暴风雪",
	4: "旱灾", 5: "浓雾", 6: "热浪", 7: "季风暴雨",
}

var _failures: int = 0
var _checks: int = 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== WeatherProfile regression test ===")
	_test_profiles_exist()
	_test_numeric_deltas_match_baseline()
	_test_flags_match_baseline()
	_test_display_names_match_baseline()
	_test_weather_type_facade()
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])

# 1. Every WT slot must produce a non-null profile whose weather_type field agrees.
func _test_profiles_exist() -> void:
	for wt in range(8):
		var p := WeatherProfileRegistry.get_profile(wt)
		_expect(p != null, "profile for WT=%d is null" % wt)
		if p == null:
			continue
		_expect(
			p.weather_type == wt,
			"profile for WT=%d has mismatched weather_type=%d" % [wt, p.weather_type]
		)

# 2. moisture_delta / temp_delta must equal the original dictionary values.
func _test_numeric_deltas_match_baseline() -> void:
	for wt in range(8):
		var p := WeatherProfileRegistry.get_profile(wt)
		if p == null:
			continue
		var expected_m: float = BASELINE_MOISTURE[wt]
		var expected_t: float = BASELINE_TEMP[wt]
		_expect(
			is_equal_approx(p.moisture_delta, expected_m),
			"WT=%d moisture_delta=%f expected %f" % [wt, p.moisture_delta, expected_m]
		)
		_expect(
			is_equal_approx(p.temp_delta, expected_t),
			"WT=%d temp_delta=%f expected %f" % [wt, p.temp_delta, expected_t]
		)

# 3. can_form_snow / can_form_flood flags must match.
func _test_flags_match_baseline() -> void:
	for wt in range(8):
		var p := WeatherProfileRegistry.get_profile(wt)
		if p == null:
			continue
		var expected_s: bool = BASELINE_CAN_SNOW[wt]
		var expected_f: bool = BASELINE_CAN_FLOOD[wt]
		_expect(
			p.can_form_snow == expected_s,
			"WT=%d can_form_snow=%s expected %s" % [wt, p.can_form_snow, expected_s]
		)
		_expect(
			p.can_form_flood == expected_f,
			"WT=%d can_form_flood=%s expected %s" % [wt, p.can_form_flood, expected_f]
		)

# 4. display_name must still produce the original Chinese label.
func _test_display_names_match_baseline() -> void:
	for wt in range(8):
		var p := WeatherProfileRegistry.get_profile(wt)
		if p == null:
			continue
		var expected: String = BASELINE_NAME[wt]
		_expect(
			p.display_name == expected,
			"WT=%d display_name=%s expected %s" % [wt, p.display_name, expected]
		)

# 5. WeatherType facade must return identical values to the profile directly.
#    This is the contract that keeps WeatherSystem / UI panels unchanged.
func _test_weather_type_facade() -> void:
	for wt in range(8):
		_expect(
			is_equal_approx(WeatherType.moisture_delta(wt), BASELINE_MOISTURE[wt]),
			"Facade moisture_delta(%d)=%f mismatch"
				% [wt, WeatherType.moisture_delta(wt)]
		)
		_expect(
			is_equal_approx(WeatherType.temp_delta(wt), BASELINE_TEMP[wt]),
			"Facade temp_delta(%d)=%f mismatch" % [wt, WeatherType.temp_delta(wt)]
		)
		_expect(
			WeatherType.can_form_snow(wt) == BASELINE_CAN_SNOW[wt],
			"Facade can_form_snow(%d) mismatch" % wt
		)
		_expect(
			WeatherType.can_form_flood(wt) == BASELINE_CAN_FLOOD[wt],
			"Facade can_form_flood(%d) mismatch" % wt
		)
		_expect(
			WeatherType.name_cn(wt) == BASELINE_NAME[wt],
			"Facade name_cn(%d)=%s mismatch" % [wt, WeatherType.name_cn(wt)]
		)

func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("[FAIL] " + msg)
		print("[FAIL] " + msg)
