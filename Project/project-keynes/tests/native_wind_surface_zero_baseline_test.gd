extends SceneTree

# Headless:
#   godot --headless --script tests/native_wind_surface_zero_baseline_test.gd --quit
#
# Regression coverage for polar-night/frozen cells: temp_baseline_arr == 0.0 is
# a valid runtime baseline and must not fall back to warmer temp_baseline_year.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native wind surface zero baseline ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return

	var ext := DCWorldExt.new()
	if not ext.has_method("run_wind_surface_pass"):
		_skip("run_wind_surface_pass not exported")
		return

	var map := MapData.new(1, 1)
	_seed_one_cell_map(map)
	_expect("bind_map_data succeeds", bool(ext.bind_map_data(map)))
	if _failures > 0:
		_finish()
		return

	var knobs := {
		"n_cells": 1,
		"air_leak": 1.0,
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1]),
		"fallback_baseline_arr": PackedFloat32Array([0.45]),
	}
	var ms: float = float(ext.run_wind_surface_pass(knobs))
	_expect("wind_surface native path executed", ms >= 0.0)

	var expected := 0.03
	var actual := float(map.temp_arr[0])
	_expect("runtime baseline zero is preserved", absf(actual - expected) < 0.0001)
	_expect("warm fallback baseline was not used", actual < 0.10)
	_finish()


func _seed_one_cell_map(map: MapData) -> void:
	map.temp_arr = PackedFloat32Array([0.0])
	map.temp_baseline_arr = PackedFloat32Array([0.0])
	map.temp_30d_arr = PackedFloat32Array([0.0])
	map.temp_365d_arr = PackedFloat32Array([0.0])
	map.temp_anomaly_arr = PackedFloat32Array([0.0])
	map.moisture_arr = PackedFloat32Array([0.0])
	map.snow_cover_arr = PackedFloat32Array([0.0])
	map.sea_ice_frac_arr = PackedFloat32Array([0.0])
	map.weather_intensity_arr = PackedFloat32Array([0.0])
	map.weather_cloud_arr = PackedFloat32Array([0.0])
	map.weather_cloud_water_arr = PackedFloat32Array([0.0])
	map.weather_precip_arr = PackedFloat32Array([0.0])
	map.weather_transition_alpha_arr = PackedFloat32Array([0.0])
	map.elevation_arr = PackedFloat32Array([0.0])
	map.base_moisture_arr = PackedFloat32Array([0.0])
	map.ocean_current_x_arr = PackedFloat32Array([0.0])
	map.ocean_current_y_arr = PackedFloat32Array([0.0])
	map.wind_x_arr = PackedFloat32Array([0.0])
	map.wind_y_arr = PackedFloat32Array([0.0])
	map.slp_arr = PackedFloat32Array([0.0])
	map.wind_speed_arr = PackedFloat32Array([0.0])
	map.upwelling_strength_arr = PackedFloat32Array([0.0])
	map.wind_stress_curl_arr = PackedFloat32Array([0.0])
	map.ocean_psi_arr = PackedFloat32Array([0.0])
	map.cell_pos_x_arr = PackedFloat32Array([0.0])
	map.cell_pos_y_arr = PackedFloat32Array([0.0])
	map.cell_lat_norm_arr = PackedFloat32Array([0.0])
	map.temp_baseline_year_arr = PackedFloat32Array([0.45])
	map.weather_vapor_arr = PackedFloat32Array([0.0])
	map.weather_convergence_arr = PackedFloat32Array([0.0])
	map.weather_instability_arr = PackedFloat32Array([0.0])
	map.air_mass_temp_anomaly_arr = PackedFloat32Array([0.0])
	map.ocean_thermal_anomaly_arr = PackedFloat32Array([0.02])
	map.local_thermal_anomaly_arr = PackedFloat32Array([0.03])
	map.river_flow_arr = PackedFloat32Array([0.0])
	map.temp_season_offset_arr = PackedFloat32Array([0.0])
	map.insolation_now_arr = PackedFloat32Array([0.0])
	map.insolation_dev_arr = PackedFloat32Array([0.0])
	map.day_length_arr = PackedFloat32Array([0.0])
	map.heat_input_arr = PackedFloat32Array([0.0])
	map.thermal_energy_arr = PackedFloat32Array([0.0])
	map.snowpack_arr = PackedFloat32Array([0.0])
	map.water_balance_30d_arr = PackedFloat32Array([0.0])
	map.vegetation_vitality_arr = PackedFloat32Array([0.0])
	map.soil_moisture_arr = PackedFloat32Array([0.0])
	map.vegetation_growth_pressure_arr = PackedFloat32Array([0.0])
	map.temperature_transport_anomaly_arr = PackedFloat32Array([0.0])
	map.vegetation_heat_stress_arr = PackedFloat32Array([0.0])
	map.vegetation_drought_stress_arr = PackedFloat32Array([0.0])
	map.vegetation_cold_stress_arr = PackedFloat32Array([0.0])
	map.vegetation_regen_score_arr = PackedFloat32Array([0.0])
	map.river_discharge_arr = PackedFloat32Array([0.0])
	map.river_discharge_30d_arr = PackedFloat32Array([0.0])
	map.river_storage_arr = PackedFloat32Array([0.0])
	map.groundwater_storage_arr = PackedFloat32Array([0.0])
	map.surface_runoff_arr = PackedFloat32Array([0.0])
	map.terrain_arr = PackedByteArray([0])
	map.landform_arr = PackedByteArray([0])
	map.vegetation_arr = PackedByteArray([0])
	map.base_terrain_arr = PackedByteArray([0])
	map.base_landform_arr = PackedByteArray([0])
	map.base_vegetation_arr = PackedByteArray([0])
	map.cover_arr = PackedByteArray([0])
	map.weather_type_arr = PackedByteArray([0])
	map.weather_prev_type_arr = PackedByteArray([0])
	map.weather_target_type_arr = PackedByteArray([0])
	map.is_water_arr = PackedByteArray([1])
	map.climate_dirty_mask = PackedByteArray([0])
	map.weather_dirty_mask = PackedByteArray([0])
	map.weather_field_init_arr = PackedByteArray([0])
	map.has_river_arr = PackedByteArray([0])
	map.ema_initialized_arr = PackedByteArray([0])
	map.vitality_low_streak_arr = PackedInt32Array([0])
	map.vitality_high_streak_arr = PackedInt32Array([0])
	map.hydro_parent_arr = PackedInt32Array([-1])


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
