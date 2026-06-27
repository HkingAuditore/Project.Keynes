extends SceneTree

# Headless:
#   godot --headless --script tests/native_ocean_water_sea_ice_suppression_test.gd --quit
#
# Regression coverage for frozen ocean cells: positive ocean heat transport
# should be suppressed by sea_ice_frac, while open water still receives the
# normal warm-current anomaly.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native ocean water sea ice suppression ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var ext := DCWorldExt.new()
	if not ext.has_method("run_ocean_water_pass"):
		_skip("run_ocean_water_pass not exported")
		return

	var map := MapData.new(2, 1)
	_seed_two_cell_map(map, 1.0, 0.0, 0.4)
	_expect("bind_map_data succeeds for ice-covered case", bool(ext.bind_map_data(map)))
	if _failures > 0:
		_finish()
		return
	_run_water_pass(ext, 0.0, 0.4)
	_expect("warm ocean anomaly suppressed under full sea ice",
			absf(float(map.ocean_thermal_anomaly_arr[0])) < 0.0001)

	_seed_two_cell_map(map, 0.0, 0.0, 0.4)
	_expect("bind_map_data succeeds for cold open-water case", bool(ext.bind_map_data(map)))
	_run_water_pass(ext, 0.0, 0.4)
	_expect("cold open water absorbs warm anomaly as latent heat",
			absf(float(map.ocean_thermal_anomaly_arr[0])) < 0.0001)

	_seed_two_cell_map(map, 0.0, 0.2, 0.4)
	_expect("bind_map_data succeeds for warm open-water case", bool(ext.bind_map_data(map)))
	_run_water_pass(ext, 0.2, 0.4)
	_expect("warm open water still receives capped warm anomaly",
			absf(float(map.ocean_thermal_anomaly_arr[0]) - 0.08) < 0.0001)
	_run_default_tta_variant_parity(ext)
	_finish()


func _run_water_pass(ext, baseline: float, upstream_temp: float) -> void:
	var knobs := {
		"n_cells": 2,
		"advect_steps": 1,
		"heat_mix": 1.0,
		"neighbor_indices": PackedInt32Array([1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]),
		"baseline_arr": PackedFloat32Array([baseline, baseline]),
		"temp_before_arr": PackedFloat32Array([baseline, upstream_temp]),
		"anomaly_out": PackedFloat32Array([0.0, 0.0]),
		"ocean_current_x_arr": PackedFloat32Array([1.0, 0.0]),
		"ocean_current_y_arr": PackedFloat32Array([0.0, 0.0]),
		"cold_transport_form_threshold": 0.06,
		"cold_transport_melt_threshold": 0.11,
	}
	var ms: float = float(ext.run_ocean_water_pass(knobs))
	_expect("ocean_water native path executed", ms >= 0.0)


func _run_default_tta_variant_parity(ext) -> void:
	var expected: float = _run_water_pass_without_tta_knobs(ext, "run_ocean_water_pass")
	if ext.has_method("run_ocean_water_pass_simd"):
		var simd_value: float = _run_water_pass_without_tta_knobs(ext, "run_ocean_water_pass_simd")
		_expect("ocean_water SIMD default TTA knobs match scalar",
				absf(simd_value - expected) < 0.0001)
	if ext.has_method("run_ocean_water_pass_thread"):
		var thread_value: float = _run_water_pass_without_tta_knobs(ext, "run_ocean_water_pass_thread")
		_expect("ocean_water thread default TTA knobs match scalar",
				absf(thread_value - expected) < 0.0001)


func _run_water_pass_without_tta_knobs(ext, method_name: String) -> float:
	var map := MapData.new(2, 1)
	_seed_two_cell_map(map, 0.0, 0.2, 0.4)
	_expect("bind_map_data succeeds for %s default parity" % method_name, bool(ext.bind_map_data(map)))
	var knobs := {
		"n_cells": 2,
		"advect_steps": 1,
		"heat_mix": 1.0,
		"neighbor_indices": PackedInt32Array([1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]),
		"baseline_arr": PackedFloat32Array([0.2, 0.2]),
		"temp_before_arr": PackedFloat32Array([0.2, 0.4]),
		"anomaly_out": PackedFloat32Array([0.0, 0.0]),
		"ocean_current_x_arr": PackedFloat32Array([1.0, 0.0]),
		"ocean_current_y_arr": PackedFloat32Array([0.0, 0.0]),
		"cold_transport_form_threshold": 0.06,
		"cold_transport_melt_threshold": 0.11,
	}
	var ms: float = 0.0
	if method_name == "run_ocean_water_pass_thread":
		ms = float(ext.call(method_name, knobs, 2))
	else:
		ms = float(ext.call(method_name, knobs))
	_expect("%s default TTA path executed" % method_name, ms >= 0.0)
	var anomaly_out: PackedFloat32Array = knobs.get("anomaly_out", PackedFloat32Array())
	_expect("%s default TTA returned anomaly_out" % method_name, anomaly_out.size() == 2)
	return float(anomaly_out[0]) if anomaly_out.size() > 0 else NAN


func _seed_two_cell_map(map: MapData, target_ice: float, baseline: float, upstream_temp: float) -> void:
	var n := 2
	map.temp_arr = PackedFloat32Array([baseline, upstream_temp])
	map.temp_baseline_arr = _pf(n, baseline)
	map.temp_30d_arr = _pf(n, baseline)
	map.temp_365d_arr = _pf(n, baseline)
	map.temp_anomaly_arr = _pf(n, 0.0)
	map.moisture_arr = _pf(n, 0.0)
	map.snow_cover_arr = _pf(n, 0.0)
	map.sea_ice_frac_arr = PackedFloat32Array([target_ice, 0.0])
	map.weather_intensity_arr = _pf(n, 0.0)
	map.weather_cloud_arr = _pf(n, 0.0)
	map.weather_cloud_water_arr = _pf(n, 0.0)
	map.weather_precip_arr = _pf(n, 0.0)
	map.weather_transition_alpha_arr = _pf(n, 0.0)
	map.elevation_arr = _pf(n, 0.0)
	map.base_moisture_arr = _pf(n, 0.0)
	map.ocean_current_x_arr = PackedFloat32Array([1.0, 0.0])
	map.ocean_current_y_arr = _pf(n, 0.0)
	map.wind_x_arr = _pf(n, 0.0)
	map.wind_y_arr = _pf(n, 0.0)
	map.slp_arr = _pf(n, 0.0)
	map.wind_speed_arr = _pf(n, 0.0)
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
	map.air_mass_temp_anomaly_arr = _pf(n, 0.0)
	map.ocean_thermal_anomaly_arr = _pf(n, 0.0)
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
