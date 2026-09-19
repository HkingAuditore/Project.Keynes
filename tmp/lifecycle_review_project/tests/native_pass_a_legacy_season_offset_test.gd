extends SceneTree

# Headless:
#   godot --headless --script tests/native_pass_a_legacy_season_offset_test.gd --quit
#
# Regression coverage for the native/SoA pass-A migration: the original AoS
# formula did not multiply land seasonal forcing by temp_land_continentality.
# Keeping that field as compatibility data must not re-warm subpolar summer land.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native pass-A legacy season offset ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var low: Dictionary = _run_case(1.0)
	var high: Dictionary = _run_case(2.5)
	if _failures > 0:
		_finish()
		return

	_expect("season offset ignores compatibility continentality",
			absf(float(low["season_offset"]) - float(high["season_offset"])) < 0.000001)
	_expect("runtime baseline ignores compatibility continentality",
			absf(float(low["baseline"]) - float(high["baseline"])) < 0.000001)
	_expect("subpolar summer still has positive seasonal signal",
			float(low["season_offset"]) > 0.10)
	_test_runtime_moisture_units()
	_finish()


func _test_runtime_moisture_units() -> void:
	var base_target: float = _run_moisture_case(0.0, 0.0, 0.0, 0.0)
	var opposite_season_target: float = _run_moisture_case(0.0, 0.0, 0.0, 0.0, false, 0.0)
	var equilibrium_vapor: float = _run_moisture_case(base_target * 0.15, 0.0, 0.12, 0.15)
	var equilibrium_vapor_threaded: float = _run_moisture_case(base_target * 0.15, 0.0, 0.12, 0.15, true)
	var equilibrium_vapor_async: float = _run_async_moisture_case(base_target * 0.15)
	var wet_soil: float = _run_moisture_case(base_target * 0.15, 0.20, 0.12, 0.15)
	var dry_soil: float = _run_moisture_case(base_target * 0.15, -0.20, 0.12, 0.15)
	var calibrated_wet_soil: float = _run_moisture_case(base_target * 0.15, 0.20, 0.12, 1.20)
	var calibrated_wet_soil_threaded: float = _run_moisture_case(
		base_target * 0.15, 0.20, 0.12, 1.20, true)
	var calibrated_wet_soil_async: float = _run_async_moisture_case(
		base_target * 0.15, 0.20, 1.20)
	var asymmetric_wet_hydrology: float = _run_moisture_case(
		base_target * 0.15, 0.10, 0.12, 1.82, false, 2.0, 2.21, 0.05, 1.04, 1.30)
	var asymmetric_dry_hydrology: float = _run_moisture_case(
		base_target * 0.15, -0.10, 0.12, 1.82, false, 2.0, 2.21, -0.05, 1.04, 1.30)
	var asymmetric_dry_hydrology_threaded: float = _run_moisture_case(
		base_target * 0.15, -0.10, 0.12, 1.82, true, 2.0, 2.21, -0.05, 1.04, 1.30)
	var asymmetric_dry_hydrology_async: float = _run_async_moisture_case(
		base_target * 0.15, -0.10, 1.82, 2.21, -0.05, 1.04, 1.30)
	_expect("equilibrium atmospheric vapor does not dry terrain moisture",
			absf(equilibrium_vapor - base_target) < 0.000001)
	_expect("insolation season does not directly force terrain moisture",
			absf(opposite_season_target - base_target) < 0.000001)
	_expect("threaded pass-A uses the same vapor/soil units",
			absf(equilibrium_vapor_threaded - equilibrium_vapor) < 0.000001)
	_expect("async pass-A uses the same vapor/soil units",
			absf(equilibrium_vapor_async - equilibrium_vapor) < 0.000001)
	_expect("positive signed soil anomaly is additive",
			absf(wet_soil - (base_target + 0.03)) < 0.000001)
	_expect("negative signed soil anomaly remains a drought signal",
			absf(dry_soil - (base_target - 0.03)) < 0.000001)
	_expect("calibrated soil weight above one is not internally clipped",
			absf(calibrated_wet_soil - (base_target + 0.24)) < 0.000001)
	_expect("threaded pass-A preserves calibrated soil amplitude",
			absf(calibrated_wet_soil_threaded - calibrated_wet_soil) < 0.000001)
	_expect("async pass-A preserves calibrated soil amplitude",
			absf(calibrated_wet_soil_async - calibrated_wet_soil) < 0.000001)
	_expect("positive hydrology keeps the existing wet-side weights",
			absf(asymmetric_wet_hydrology - (base_target + 0.234)) < 0.000001)
	_expect("negative hydrology uses stronger dry-side weights",
			absf(asymmetric_dry_hydrology - (base_target - 0.286)) < 0.000001)
	_expect("threaded pass-A preserves asymmetric drought response",
			absf(asymmetric_dry_hydrology_threaded - asymmetric_dry_hydrology) < 0.000001)
	_expect("async pass-A preserves asymmetric drought response",
			absf(asymmetric_dry_hydrology_async - asymmetric_dry_hydrology) < 0.000001)


func _run_moisture_case(vapor: float, soil: float, vapor_weight: float,
		soil_weight: float, threaded: bool = false, season_phase: float = 2.0,
		soil_dry_weight: float = -1.0, water_balance: float = 0.0,
		water_balance_weight: float = 0.0, water_balance_dry_weight: float = -1.0) -> float:
	var ext := DCWorldExt.new()
	var map := MapData.new(1, 1)
	_seed_subpolar_land_map(map)
	map.base_moisture_arr[0] = 0.60
	map.moisture_arr[0] = 0.60
	map.weather_vapor_arr[0] = vapor
	map.soil_moisture_arr[0] = soil
	map.water_balance_30d_arr[0] = water_balance
	_expect("bind_map_data succeeds for moisture-unit case", bool(ext.bind_map_data(map)))
	var cp_struct := {
		"use_sparse": false,
		"moist_scale_now": 1.0,
		"season_phase": season_phase,
		"days_per_year": 365,
		"axial_tilt_deg": 23.5,
		"day_length_gain": 0.35,
		"solar_gain": 1.0,
		"insol_dev_min": -1.0,
		"insol_dev_max": 1.0,
		"runtime_moisture_base_relax_rate": 1.0,
		"runtime_moisture_weather_vapor_weight": vapor_weight,
		"runtime_moisture_precip_weight": 0.0,
		"runtime_moisture_soil_weight": soil_weight,
		"runtime_moisture_soil_dry_weight": soil_weight if soil_dry_weight < 0.0 else soil_dry_weight,
		"runtime_moisture_water_balance_weight": water_balance_weight,
		"runtime_moisture_water_balance_dry_weight": water_balance_weight if water_balance_dry_weight < 0.0 else water_balance_dry_weight,
		"thermal_dt_days": 1.0,
		"thermal_daily_delta_cap": 1.0,
	}
	var rc: float = float(ext.run_climate_pass_a_thread(cp_struct, season_phase, season_phase, 2)) \
			if threaded else float(ext.run_climate_pass_a(cp_struct, season_phase, season_phase))
	_expect("pass-A moisture-unit case executed", rc >= 0.0)
	return float(map.moisture_arr[0])


func _run_async_moisture_case(vapor: float, soil: float = 0.0,
		soil_weight: float = 0.15, soil_dry_weight: float = -1.0,
		water_balance: float = 0.0, water_balance_weight: float = 0.0,
		water_balance_dry_weight: float = -1.0) -> float:
	var ext := DCWorldExt.new()
	var map := MapData.new(1, 1)
	_seed_subpolar_land_map(map)
	map.base_moisture_arr[0] = 0.60
	map.moisture_arr[0] = 0.60
	map.weather_vapor_arr[0] = vapor
	map.soil_moisture_arr[0] = soil
	map.water_balance_30d_arr[0] = water_balance
	_expect("bind_map_data succeeds for async moisture-unit case", bool(ext.bind_map_data(map)))
	ext.async_climate_round_register()
	var input := {
		"n_cells": 1,
		"passes_mask": 0x01,
		"is_water": map.is_water_arr,
		"terrain": map.terrain_arr,
		"cover": map.cover_arr,
		"ema_initialized": map.ema_initialized_arr,
		"elevation": map.elevation_arr,
		"base_moisture": map.base_moisture_arr,
		"weather_vapor": map.weather_vapor_arr,
		"weather_precip": map.weather_precip_arr,
		"soil_moisture": map.soil_moisture_arr,
		"water_balance_30d": map.water_balance_30d_arr,
		"lat_norm": map.cell_lat_norm_arr,
		"temp_baseline_year": map.temp_baseline_year_arr,
		"temp": map.temp_arr,
		"temp_30d": map.temp_30d_arr,
		"temp_365d": map.temp_365d_arr,
		"thermal_energy": map.thermal_energy_arr,
		"snowpack": map.snowpack_arr,
		"moisture": map.moisture_arr,
		"season_phase": 2.0,
		"axial_tilt_deg": 23.5,
		"day_length_gain": 0.35,
		"solar_gain": 1.0,
		"insol_amp": 0.20,
		"insol_gain": 1.0,
		"moist_scale_now": 1.0,
		"insol_dev_min": -1.0,
		"insol_dev_max": 1.0,
		"runtime_moisture_base_relax_rate": 1.0,
		"runtime_moisture_weather_vapor_weight": 0.12,
		"runtime_moisture_precip_weight": 0.0,
		"runtime_moisture_soil_weight": soil_weight,
		"runtime_moisture_soil_dry_weight": soil_weight if soil_dry_weight < 0.0 else soil_dry_weight,
		"runtime_moisture_water_balance_weight": water_balance_weight,
		"runtime_moisture_water_balance_dry_weight": water_balance_weight if water_balance_dry_weight < 0.0 else water_balance_dry_weight,
		"thermal_dt_days": 1.0,
		"thermal_daily_delta_cap": 1.0,
	}
	_expect("async moisture-unit case kicked", bool(ext.async_climate_round_kick(input)))
	var poll_result: Dictionary = {}
	for _attempt in range(1000):
		poll_result = ext.async_climate_round_poll()
		if not poll_result.is_empty():
			break
		OS.delay_msec(1)
	_expect("async moisture-unit case completed", not poll_result.is_empty())
	ext.async_climate_round_shutdown()
	return float(map.moisture_arr[0])


func _run_case(land_continentality: float) -> Dictionary:
	var ext := DCWorldExt.new()
	if not ext.has_method("run_climate_pass_a"):
		_skip("run_climate_pass_a not exported")
		return {}

	var map := MapData.new(1, 1)
	_seed_subpolar_land_map(map)
	_expect("bind_map_data succeeds", bool(ext.bind_map_data(map)))
	if _failures > 0:
		return {}

	var cp_struct := {
		"use_insol": true,
		"use_sparse": false,
		"insol_amp": 0.32,
		"insol_gain": 1.8,
		"moist_scale_now": 1.0,
		"season_phase": 2.0,
		"days_per_year": 365,
		"axial_tilt_deg": 23.5,
		"day_length_gain": 0.35,
		"solar_gain": 1.0,
		"insol_dev_min": -1.0,
		"insol_dev_max": 1.0,
		"thermal_inertia_land": 1.0,
		"thermal_inertia_water": 0.008,
		"thermal_inertia_snow": 0.09,
		"thermal_inertia_high_mountain": 0.16,
		"thermal_daily_delta_cap": 1.0,
		"temp_land_continentality": land_continentality,
		"thermal_dt_days": 1.0,
		"snowpack_cover_low": 0.05,
		"snowpack_cover_full": 0.32,
		"sea_level": 0.50,
	}
	var rc: float = float(ext.run_climate_pass_a(cp_struct, 2.0, 2.0))
	_expect("pass-A native path executed", rc >= 0.0)
	return {
		"season_offset": float(map.temp_season_offset_arr[0]),
		"baseline": float(map.temp_baseline_arr[0]),
		"insolation": float(map.insolation_now_arr[0]),
	}


func _seed_subpolar_land_map(map: MapData) -> void:
	var n := 1
	map.temp_arr = _pf(n, 0.4429)
	map.temp_baseline_arr = _pf(n, 0.4429)
	map.temp_30d_arr = _pf(n, 0.4429)
	map.temp_365d_arr = _pf(n, 0.4429)
	map.temp_anomaly_arr = _pf(n, 0.0)
	map.moisture_arr = _pf(n, 0.45)
	map.snow_cover_arr = _pf(n, 0.0)
	map.sea_ice_frac_arr = _pf(n, 0.0)
	map.weather_intensity_arr = _pf(n, 0.0)
	map.weather_cloud_arr = _pf(n, 0.0)
	map.weather_cloud_water_arr = _pf(n, 0.0)
	map.weather_precip_arr = _pf(n, 0.0)
	map.weather_transition_alpha_arr = _pf(n, 0.0)
	map.elevation_arr = _pf(n, 0.0)
	map.base_moisture_arr = _pf(n, 0.45)
	map.ocean_current_x_arr = _pf(n, 0.0)
	map.ocean_current_y_arr = _pf(n, 0.0)
	map.wind_x_arr = _pf(n, 0.0)
	map.wind_y_arr = _pf(n, 0.0)
	map.slp_arr = _pf(n, 0.0)
	map.wind_speed_arr = _pf(n, 0.0)
	map.upwelling_strength_arr = _pf(n, 0.0)
	map.wind_stress_curl_arr = _pf(n, 0.0)
	map.ocean_psi_arr = _pf(n, 0.0)
	map.cell_pos_x_arr = _pf(n, 0.0)
	map.cell_pos_y_arr = _pf(n, 0.0)
	map.cell_lat_norm_arr = _pf(n, 0.18)
	map.temp_baseline_year_arr = _pf(n, 0.4429)
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
	map.thermal_energy_arr = _pf(n, 0.4429)
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
	map.terrain_arr = PackedByteArray([13])
	map.landform_arr = PackedByteArray([0])
	map.vegetation_arr = PackedByteArray([0])
	map.base_terrain_arr = PackedByteArray([13])
	map.base_landform_arr = PackedByteArray([0])
	map.base_vegetation_arr = PackedByteArray([0])
	map.cover_arr = PackedByteArray([0])
	map.weather_type_arr = PackedByteArray([0])
	map.weather_prev_type_arr = PackedByteArray([0])
	map.weather_target_type_arr = PackedByteArray([0])
	map.is_water_arr = PackedByteArray([0])
	map.climate_dirty_mask = PackedByteArray([0])
	map.weather_dirty_mask = PackedByteArray([0])
	map.weather_field_init_arr = PackedByteArray([0])
	map.has_river_arr = PackedByteArray([0])
	map.ema_initialized_arr = PackedByteArray([1])
	map.vitality_low_streak_arr = PackedInt32Array([0])
	map.vitality_high_streak_arr = PackedInt32Array([0])
	map.hydro_parent_arr = PackedInt32Array([-1])


func _pf(n: int, value: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(n)
	for i in range(n):
		a[i] = value
	return a


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
