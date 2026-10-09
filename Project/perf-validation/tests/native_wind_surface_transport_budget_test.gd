extends SceneTree

# Headless:
#   godot --headless --script tests/native_wind_surface_transport_budget_test.gd --quit
#
# Regression coverage for anomaly composition: ocean and air anomalies are both
# lateral heat transport and must share one transport budget before local
# feedback is added.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native wind surface transport budget ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var ext := DCWorldExt.new()
	if not ext.has_method("run_wind_surface_pass"):
		_skip("run_wind_surface_pass not exported")
		return

	var map := MapData.new(2, 1)
	_seed_two_cell_map(map, 0.20)
	_expect("bind_map_data succeeds", bool(ext.bind_map_data(map)))
	if _failures > 0:
		_finish()
		return

	var ms: float = float(ext.run_wind_surface_pass(_knobs(0.20)))
	_expect("wind_surface native path executed", ms >= 0.0)
	_expect("warm water receives shared transport cap",
			absf(float(map.temp_arr[0]) - 0.28) < 0.0001)
	_expect("old additive cap would have been warmer",
			float(map.temp_arr[0]) < 0.30)

	_seed_two_cell_map(map, 0.0)
	_expect("bind_map_data succeeds for cold water", bool(ext.bind_map_data(map)))
	ms = float(ext.run_wind_surface_pass(_knobs(0.0)))
	_expect("wind_surface native path executed for cold water", ms >= 0.0)
	_expect("cold water positive transport is latent-heat gated",
			float(map.temp_arr[0]) < 0.01)
	_finish()


func _knobs(baseline: float) -> Dictionary:
	return {
		"n_cells": 2,
		"air_leak": 1.0,
		"neighbor_indices": PackedInt32Array([1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]),
		"fallback_baseline_arr": PackedFloat32Array([baseline, baseline]),
		"cold_transport_form_threshold": 0.06,
		"cold_transport_melt_threshold": 0.11,
	}


func _seed_two_cell_map(map: MapData, baseline: float) -> void:
	var n := 2
	map.temp_arr = _pf(n, baseline)
	map.temp_baseline_arr = _pf(n, baseline)
	map.temp_30d_arr = _pf(n, 0.0)
	map.temp_365d_arr = _pf(n, 0.0)
	map.temp_anomaly_arr = _pf(n, 0.0)
	map.moisture_arr = _pf(n, 0.0)
	map.snow_cover_arr = _pf(n, 0.0)
	map.sea_ice_frac_arr = _pf(n, 0.0)
	map.weather_intensity_arr = _pf(n, 0.0)
	map.weather_cloud_arr = _pf(n, 0.0)
	map.weather_cloud_water_arr = _pf(n, 0.0)
	map.weather_precip_arr = _pf(n, 0.0)
	map.weather_transition_alpha_arr = _pf(n, 0.0)
	map.elevation_arr = _pf(n, 0.0)
	map.base_moisture_arr = _pf(n, 0.0)
	map.ocean_current_x_arr = _pf(n, 0.0)
	map.ocean_current_y_arr = _pf(n, 0.0)
	map.wind_x_arr = PackedFloat32Array([0.0, 1.0])
	map.wind_y_arr = _pf(n, 0.0)
	map.slp_arr = _pf(n, 0.0)
	map.wind_speed_arr = PackedFloat32Array([0.0, 1.2])
	map.upwelling_strength_arr = _pf(n, 0.0)
	map.wind_stress_curl_arr = _pf(n, 0.0)
	map.ocean_psi_arr = _pf(n, 0.0)
	map.cell_pos_x_arr = PackedFloat32Array([0.0, -1.0])
	map.cell_pos_y_arr = _pf(n, 0.0)
	map.cell_lat_norm_arr = _pf(n, 0.0)
	map.temp_baseline_year_arr = _pf(n, baseline)
	map.weather_vapor_arr = _pf(n, 0.0)
	map.weather_convergence_arr = _pf(n, 0.0)
	map.weather_instability_arr = _pf(n, 0.0)
	map.air_mass_temp_anomaly_arr = PackedFloat32Array([0.0, 0.08])
	map.ocean_thermal_anomaly_arr = PackedFloat32Array([0.08, 0.0])
	map.local_thermal_anomaly_arr = _pf(n, 0.0)
	map.river_flow_arr = _pf(n, 0.0)
	map.temp_season_offset_arr = _pf(n, 0.0)
	map.insolation_now_arr = _pf(n, 0.0)
	map.insolation_dev_arr = _pf(n, 0.0)
	map.day_length_arr = _pf(n, 0.0)
	map.heat_input_arr = _pf(n, 0.0)
	map.thermal_energy_arr = _pf(n, 0.0)
	map.snowpack_arr = _pf(n, 0.0)
	map.water_balance_30d_arr = _pf(n, 0.0)
	map.vegetation_vitality_arr = _pf(n, 0.0)
	map.soil_moisture_arr = _pf(n, 0.0)
	map.vegetation_growth_pressure_arr = _pf(n, 0.0)
	map.temperature_transport_anomaly_arr = _pf(n, 0.0)
	map.vegetation_heat_stress_arr = _pf(n, 0.0)
	map.vegetation_drought_stress_arr = _pf(n, 0.0)
	map.vegetation_cold_stress_arr = _pf(n, 0.0)
	map.vegetation_regen_score_arr = _pf(n, 0.0)
	map.river_discharge_arr = _pf(n, 0.0)
	map.river_discharge_30d_arr = _pf(n, 0.0)
	map.river_storage_arr = _pf(n, 0.0)
	map.groundwater_storage_arr = _pf(n, 0.0)
	map.surface_runoff_arr = _pf(n, 0.0)
	map.terrain_arr = _pb(n, 0)
	map.landform_arr = _pb(n, 0)
	map.vegetation_arr = _pb(n, 0)
	map.base_terrain_arr = _pb(n, 0)
	map.base_landform_arr = _pb(n, 0)
	map.base_vegetation_arr = _pb(n, 0)
	map.cover_arr = _pb(n, 0)
	map.weather_type_arr = _pb(n, 0)
	map.weather_prev_type_arr = _pb(n, 0)
	map.weather_target_type_arr = _pb(n, 0)
	map.is_water_arr = _pb(n, 1)
	map.climate_dirty_mask = _pb(n, 0)
	map.weather_dirty_mask = _pb(n, 0)
	map.weather_field_init_arr = _pb(n, 0)
	map.has_river_arr = _pb(n, 0)
	map.ema_initialized_arr = _pb(n, 0)
	map.vitality_low_streak_arr = _pi(n, 0)
	map.vitality_high_streak_arr = _pi(n, 0)
	map.hydro_parent_arr = _pi(n, -1)


func _pf(n: int, value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		out[i] = value
	return out


func _pb(n: int, value: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(n)
	for i in range(n):
		out[i] = value & 0xFF
	return out


func _pi(n: int, value: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	for i in range(n):
		out[i] = value
	return out


func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
