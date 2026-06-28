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
	_finish()


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
