extends SceneTree

# Headless:
#   godot --headless --script tests/native_sea_ice_state_machine_test.gd --quit
#
# P0 sea-ice native handoff smoke test. Detailed deterministic terrain-flip
# equivalence should be added once a compact MapData fixture is available.

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native sea ice state-machine smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return

	_expect("run_sea_ice_daily_pass exported", ext.has_method("run_sea_ice_daily_pass"))
	_expect("run_native_sim_tick exported", ext.has_method("run_native_sim_tick"))
	_expect("get_native_dirty_report exported", ext.has_method("get_native_dirty_report"))
	var dirty_report: Dictionary = ext.call("get_native_dirty_report") if ext.has_method("get_native_dirty_report") else {}
	_expect("dirty report is dictionary", typeof(dirty_report) == TYPE_DICTIONARY)
	var res: Dictionary = ext.call("run_native_sim_tick", {
		"probe": true,
		"native_daily_bundle": {
			"use_system_schedule": true,
			"sea_ice_knobs": {
				"apply_terrain_flips": true,
			},
		},
		"required_pass_keys": ["sea_ice_knobs"],
	}) if ext.has_method("run_native_sim_tick") else {}
	_expect("unconfigured sea ice native tick does not mutate", int(res.get("rc", 0)) == -1)
	_test_tta_residual_avoids_double_count(ext)
	_test_thick_ice_solar_melt_is_shielded(ext)
	_finish()


func _test_tta_residual_avoids_double_count(ext: Object) -> void:
	var map := MapData.new(1, 1)
	_seed_one_cold_ocean_cell(map)
	_expect("bind_map_data succeeds for sea ice residual case", bool(ext.call("bind_map_data", map)))
	var knobs := {
		"n_cells": 1,
		"k_freeze": 0.40,
		"k_melt": 1.45,
		"t_form": 0.06,
		"t_melt": 0.11,
		"contagion": 0.0,
		"threshold": 0.68,
		"hysteresis": 0.12,
		"ice_delay": 1.0,
		"enable_ocean_heat_transport": true,
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": PackedByteArray([
			int(TerrainType.TERRAIN.OCEAN),
			int(TerrainType.TERRAIN.COAST),
			int(TerrainType.TERRAIN.LAKE),
			int(TerrainType.TERRAIN.REEF),
			int(TerrainType.TERRAIN.KELP),
			int(TerrainType.TERRAIN.SEA_ICE),
		]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1]),
		"base_terrain_arr": PackedByteArray([int(TerrainType.TERRAIN.OCEAN)]),
		"temp_transport_anomaly": PackedFloat32Array([0.07]),
		"upwelling_strength": PackedFloat32Array([0.0]),
		"insolation_now_arr": PackedFloat32Array([0.0]),
		"solar_gate_enabled": true,
		"freeze_insol_low": 0.30,
		"freeze_insol_high": 0.55,
		"solar_melt_start": 0.40,
		"solar_melt_gain": 0.80,
		"cell_temperature_arr": PackedFloat32Array([0.055]),
		"daily_delta_cap": 0.05,
		"dt_days": 1.0,
		"apply_terrain_flips": false,
	}
	var ms: float = float(ext.call("run_sea_ice_daily_pass", knobs, 0.0))
	_expect("sea ice native path executed", ms >= 0.0)
	_expect("sea ice grows when TTA is already represented by ocean anomaly",
			float(map.sea_ice_frac_arr[0]) > 0.001)


func _test_thick_ice_solar_melt_is_shielded(ext: Object) -> void:
	var map := MapData.new(1, 1)
	_seed_one_cold_ocean_cell(map)
	map.temp_arr = PackedFloat32Array([0.02])
	map.temp_baseline_arr = PackedFloat32Array([0.02])
	map.temp_baseline_year_arr = PackedFloat32Array([0.02])
	map.sea_ice_frac_arr = PackedFloat32Array([0.8])
	map.ocean_thermal_anomaly_arr = PackedFloat32Array([0.0])
	map.temperature_transport_anomaly_arr = PackedFloat32Array([0.0])
	_expect("bind_map_data succeeds for thick ice solar case", bool(ext.call("bind_map_data", map)))
	var knobs := _one_cell_sea_ice_knobs(
			PackedFloat32Array([0.0]),
			PackedFloat32Array([1.0]),
			PackedFloat32Array([0.02]))
	var ms: float = float(ext.call("run_sea_ice_daily_pass", knobs, 0.0))
	_expect("sea ice native path executed for thick ice solar case", ms >= 0.0)
	_expect("thick ice does not melt at the full daily cap under sun",
			float(map.sea_ice_frac_arr[0]) > 0.75)
	_expect("thick ice still has meaningful summer melt pressure",
			float(map.sea_ice_frac_arr[0]) < 0.77)


func _one_cell_sea_ice_knobs(
		tta: PackedFloat32Array,
		insolation: PackedFloat32Array,
		temp: PackedFloat32Array) -> Dictionary:
	return {
		"n_cells": 1,
		"k_freeze": 0.40,
		"k_melt": 1.45,
		"t_form": 0.06,
		"t_melt": 0.11,
		"contagion": 0.0,
		"threshold": 0.68,
		"hysteresis": 0.12,
		"ice_delay": 1.0,
		"enable_ocean_heat_transport": true,
		"terrain_lake_id": int(TerrainType.TERRAIN.LAKE),
		"terrain_sea_ice_id": int(TerrainType.TERRAIN.SEA_ICE),
		"terrain_ocean_id": int(TerrainType.TERRAIN.OCEAN),
		"water_terrain_ids": PackedByteArray([
			int(TerrainType.TERRAIN.OCEAN),
			int(TerrainType.TERRAIN.COAST),
			int(TerrainType.TERRAIN.LAKE),
			int(TerrainType.TERRAIN.REEF),
			int(TerrainType.TERRAIN.KELP),
			int(TerrainType.TERRAIN.SEA_ICE),
		]),
		"neighbor_indices": PackedInt32Array([-1, -1, -1, -1, -1, -1]),
		"base_terrain_arr": PackedByteArray([int(TerrainType.TERRAIN.OCEAN)]),
		"temp_transport_anomaly": tta,
		"upwelling_strength": PackedFloat32Array([0.0]),
		"insolation_now_arr": insolation,
		"solar_gate_enabled": true,
		"freeze_insol_low": 0.30,
		"freeze_insol_high": 0.55,
		"solar_melt_start": 0.40,
		"solar_melt_gain": 0.80,
		"cell_temperature_arr": temp,
		"daily_delta_cap": 0.05,
		"dt_days": 1.0,
		"apply_terrain_flips": false,
	}


func _seed_one_cold_ocean_cell(map: MapData) -> void:
	var n := 1
	map.temp_arr = PackedFloat32Array([0.055])
	map.temp_baseline_arr = PackedFloat32Array([0.055])
	map.temp_30d_arr = PackedFloat32Array([0.055])
	map.temp_365d_arr = PackedFloat32Array([0.055])
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
	map.wind_x_arr = _pf(n, 0.0)
	map.wind_y_arr = _pf(n, 0.0)
	map.slp_arr = _pf(n, 0.0)
	map.wind_speed_arr = _pf(n, 0.0)
	map.upwelling_strength_arr = _pf(n, 0.0)
	map.wind_stress_curl_arr = _pf(n, 0.0)
	map.ocean_psi_arr = _pf(n, 0.0)
	map.cell_pos_x_arr = _pf(n, 0.0)
	map.cell_pos_y_arr = _pf(n, 0.0)
	map.cell_lat_norm_arr = _pf(n, 0.02)
	map.temp_baseline_year_arr = PackedFloat32Array([0.055])
	map.weather_vapor_arr = _pf(n, 0.0)
	map.weather_convergence_arr = _pf(n, 0.0)
	map.weather_instability_arr = _pf(n, 0.0)
	map.air_mass_temp_anomaly_arr = _pf(n, 0.0)
	map.ocean_thermal_anomaly_arr = PackedFloat32Array([0.07])
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
	map.temperature_transport_anomaly_arr = PackedFloat32Array([0.07])
	map.vegetation_heat_stress_arr = _pf(n, 0.0)
	map.vegetation_drought_stress_arr = _pf(n, 0.0)
	map.vegetation_cold_stress_arr = _pf(n, 0.0)
	map.vegetation_regen_score_arr = _pf(n, 0.0)
	map.river_discharge_arr = _pf(n, 0.0)
	map.river_discharge_30d_arr = _pf(n, 0.0)
	map.river_storage_arr = _pf(n, 0.0)
	map.groundwater_storage_arr = _pf(n, 0.0)
	map.surface_runoff_arr = _pf(n, 0.0)
	map.terrain_arr = PackedByteArray([int(TerrainType.TERRAIN.OCEAN)])
	map.landform_arr = PackedByteArray([int(LandformType.LF.OCEAN)])
	map.vegetation_arr = _pb(n, 0)
	map.base_terrain_arr = PackedByteArray([int(TerrainType.TERRAIN.OCEAN)])
	map.base_landform_arr = PackedByteArray([int(LandformType.LF.OCEAN)])
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
