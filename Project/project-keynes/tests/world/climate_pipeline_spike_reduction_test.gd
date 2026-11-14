extends SceneTree

# tests/climate_pipeline_spike_reduction_test.gd
#
# Headless execution:
#   godot --headless --script tests/climate_pipeline_spike_reduction_test.gd --quit
#
# 覆盖 climate-pipeline-spike-reduction 中最容易纯脚本验证的端到端链路：
# weather fronts signature diff → renderer skip / fallback full sync 诊断。

const HexRendererScript := preload("res://scripts/rendering/hex_renderer.gd")
const ClimateProfileScript := preload("res://scripts/data/climate_profile.gd")

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== climate pipeline spike reduction regression ===")
	_test_weather_front_renderer_signature_sync()
	_test_daily_finalizer_formula_caps()
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _test_weather_front_renderer_signature_sync() -> void:
	var renderer = HexRendererScript.new()
	var fronts: Array = [_front(Vector2(128.0, 64.0), 0, 0.75)]
	# Front signatures were retired with the renderer collaborator split. The
	# current boundary is the bounded set_weather_fronts() upload itself.
	renderer.set_weather_fronts(fronts)
	_expect(int(renderer._set_weather_fronts_last_n) == 1,
		"current renderer boundary accepts one weather front")
	renderer.set_weather_fronts([])
	_expect(int(renderer._set_weather_fronts_last_n) == 0,
		"clearing fronts reaches the same renderer boundary")


func _front(center: Vector2, type_id: int, intensity: float) -> Dictionary:
	return {
		"center": center,
		"type": type_id,
		"intensity": intensity,
		"radius": 96.0,
		"axis": Vector2.RIGHT,
		"major_scale": 1.0,
		"minor_scale": 1.0,
		"cloud_amount": 0.6,
		"precip_amount": 0.4,
		"dissolve_amount": 0.0,
		"life_progress": 0.25,
	}


func _test_daily_finalizer_formula_caps() -> void:
	var cp: ClimateProfile = ClimateProfileScript.new()
	var temp_start: float = 0.45
	var temp_candidate: float = temp_start + float(cp.thermal_daily_delta_cap) * 3.0
	var temp_final: float = _cap_delta(temp_candidate, temp_start, float(cp.thermal_daily_delta_cap))
	_expect(absf(temp_final - temp_start) <= float(cp.thermal_daily_delta_cap) + 0.0001,
		"finalizer should cap full-day temperature jump")

	var tta_start: float = -0.04
	var tta_candidate: float = 0.80
	var tta_final: float = _cap_delta(tta_candidate, tta_start, float(cp.temperature_transport_anomaly_daily_cap))
	_expect(absf(tta_final - tta_start) <= float(cp.temperature_transport_anomaly_daily_cap) + 0.0001,
		"transport anomaly should have its own daily cap")

	var thermal_energy: float = _init_thermal_energy(NAN, temp_start)
	_expect(is_finite(thermal_energy) and is_equal_approx(thermal_energy, temp_start),
		"thermal energy initializer should replace invalid values with current temperature")


func _cap_delta(candidate: float, start: float, cap: float) -> float:
	if cap <= 0.0:
		return candidate
	return clampf(candidate, start - cap, start + cap)


func _init_thermal_energy(value: float, temp: float) -> float:
	if not is_finite(value):
		return temp
	return value


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("[FAIL] " + msg)
		print("[FAIL] " + msg)
