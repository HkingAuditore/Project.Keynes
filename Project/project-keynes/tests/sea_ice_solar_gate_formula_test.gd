extends SceneTree

# Headless:
#   godot --headless --script tests/sea_ice_solar_gate_formula_test.gd --quit
#
# Sea-ice solar gate formula smoke test. The native and GDScript passes both
# mirror this formula through ClimateProfile defaults.

const ClimateProfileScript := preload("res://scripts/data/climate_profile.gd")

var _checks: int = 0
var _failures: int = 0
var _cp: ClimateProfile


func _init() -> void:
	_cp = ClimateProfileScript.new()
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== sea ice solar gate formula ===")
	_expect("solar gate enabled by default", bool(_cp.sea_ice_solar_gate_enabled))
	_expect("high sun blocks cold freeze", _delta_frac(0.0, 1.0, false) < 0.0)
	_expect("high sun blocks neighbor contagion", _delta_frac(0.0, 1.0, true) < 0.0)
	_expect("low sun allows cold freeze", _delta_frac(0.0, 0.1, false) > 0.0)
	_expect("shoulder sun partially gates freeze", _freeze_gate(0.45) > 0.0 and _freeze_gate(0.45) < 1.0)
	_expect("daily delta cap limits rapid growth", absf(_delta_frac_capped(0.0, 0.0, true, 30.0)) <= float(_cp.sea_ice_daily_delta_cap) + 0.0001)
	_expect("high latitude summer solar melt is capped", absf(_delta_frac_capped(0.75, 1.0, false, 30.0)) <= float(_cp.sea_ice_daily_delta_cap) + 0.0001)
	_finish()


func _delta_frac(temp_now: float, insolation_now: float, has_cold_neighbor: bool) -> float:
	var k_freeze: float = float(_cp.sea_ice_freeze_rate)
	if has_cold_neighbor:
		k_freeze *= 1.0 + float(_cp.sea_ice_neighbor_contagion)
	var delta_freeze: float = k_freeze \
		* maxf(0.0, float(_cp.sea_ice_form_threshold) - temp_now) \
		* _freeze_gate(insolation_now)
	var delta_melt: float = float(_cp.sea_ice_melt_rate) \
		* maxf(0.0, temp_now - float(_cp.sea_ice_melt_threshold)) \
		+ _solar_melt(insolation_now)
	return delta_freeze - delta_melt


func _delta_frac_capped(temp_now: float, insolation_now: float, has_cold_neighbor: bool, dt_days: float) -> float:
	var raw: float = _delta_frac(temp_now, insolation_now, has_cold_neighbor) * dt_days
	return clampf(raw, -float(_cp.sea_ice_daily_delta_cap), float(_cp.sea_ice_daily_delta_cap))


func _freeze_gate(insolation_now: float) -> float:
	var low: float = float(_cp.sea_ice_freeze_insol_low)
	var high: float = maxf(float(_cp.sea_ice_freeze_insol_high), low + 0.001)
	return clampf(1.0 - smoothstep(low, high, insolation_now), 0.0, 1.0)


func _solar_melt(insolation_now: float) -> float:
	return maxf(0.0, float(_cp.sea_ice_solar_melt_gain)) \
		* maxf(0.0, insolation_now - float(_cp.sea_ice_solar_melt_start))


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
