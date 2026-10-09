extends SceneTree

# native_dt_compensation_probe_test.gd
# Headless:
#   godot --headless --script tests/native_dt_compensation_probe_test.gd --quit
#
# dt>1 直测探针（weather-seaice-selfconsistency-fix 2026-06-28）。
# 不用 FakeClock / WorldClock，直接以显式 dt_days 驱动 dt-aware 公式与 sea_ice C++ pass，
# 坐实三条修复在加速档（dt≈9）下的行为：
#   1) temp_anomaly 的 EMA 在 dt=9 下不坍缩（dt-aware ≈ 逐日参考，且远胜旧固定 alpha）。
#   2) 天气过渡机在 dt≥3 时即时切换（dt=1 仍保留 ~3 次求解平滑）。
#   3) 海冰冻融在 dt=9 下极地稳定饱和(>0.9)、单 pass |Δ| 受 cap·dt 约束、暖水不结冰。
# 三段公式镜像 world_ext_climate.cpp / world_ext_weather.cpp / field_solver.gd 的真源逻辑。

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native dt-compensation probe (dt>1) ===")
	_test_ema_anomaly_does_not_collapse()
	_test_weather_transition_switches_promptly()
	_test_sea_ice_dt9_polar_saturation_and_cap()
	_finish()


# ── 修复 2 探针：dt-aware EMA 在加速档下保留季节距平信号 ───────────────────────
# 镜像 world_ext_climate.cpp 的 m30/m365 递推：m = m + (temp-m)*alpha。
# dt-aware alpha = 1-(1-base)^dt；旧实现固定用 base（每次求解一次），在 dt=9 下令 30d 窗口
# 膨胀到 ~270 天 → m30 与 m365 都趋年均 → 距平坍缩。
func _ema_anomaly_amplitude(dt_days: float, dt_aware: bool) -> float:
	var base30: float = 1.0 / 30.0
	var base365: float = 1.0 / 365.0
	var a30: float = base30
	var a365: float = base365
	if dt_aware and dt_days > 1.0:
		a30 = 1.0 - pow(1.0 - base30, dt_days)
		a365 = 1.0 - pow(1.0 - base365, dt_days)
	var m30: float = 0.4
	var m365: float = 0.4
	var max_anom: float = 0.0
	var day: float = 0.0
	var total_days: float = 365.0 * 4.0
	var warmup: float = 365.0 * 2.0
	while day < total_days:
		var temp: float = 0.4 + 0.15 * sin(TAU * day / 365.0)
		m30 = m30 + (temp - m30) * a30
		m365 = m365 + (temp - m365) * a365
		if day > warmup:
			max_anom = maxf(max_anom, absf(m30 - m365))
		day += dt_days
	return max_anom


func _test_ema_anomaly_does_not_collapse() -> void:
	var amp_dt1: float = _ema_anomaly_amplitude(1.0, true)
	var amp_dt9_aware: float = _ema_anomaly_amplitude(9.0, true)
	var amp_dt9_old: float = _ema_anomaly_amplitude(9.0, false)
	print("  [ema] amp dt=1=%.4f  dt=9(aware)=%.4f  dt=9(old)=%.4f" % [amp_dt1, amp_dt9_aware, amp_dt9_old])
	_expect("dt=1 seasonal anomaly amplitude is meaningful", amp_dt1 > 0.03)
	_expect("dt=9 dt-aware preserves >=70%% of dt=1 anomaly amplitude",
			amp_dt9_aware > 0.70 * amp_dt1)
	_expect("dt=9 old fixed-alpha collapses vs dt-aware (aware >= 1.3x old)",
			amp_dt9_aware >= 1.3 * amp_dt9_old)


# ── 修复 1 探针：天气过渡机按游戏天数推进 ────────────────────────────────────
# 镜像 field_solver.gd / world_ext_weather.cpp：分类器每次求解输出 STORM(wt=2)，
# 从静止 CLEAR(0) 起，统计需多少次求解 display 才切到 STORM。
func _transition_solves_to_switch(dt_days: float) -> int:
	var rate: float = 0.35
	var display: int = 0
	var prev: int = 0
	var target: int = 0
	var alpha: float = 1.0
	var wt: int = 2
	for solve in range(1, 60):
		var current_display: int = display
		if target != wt:
			prev = current_display
			target = wt
			alpha = clampf(rate * dt_days, 0.0, 1.0)
		elif prev == target or current_display == target:
			prev = target
			alpha = 0.0
		else:
			alpha = clampf(alpha + rate * dt_days, 0.0, 1.0)
		display = target if alpha >= 1.0 else prev
		if alpha >= 1.0:
			prev = target
			alpha = 0.0
		if display == wt:
			return solve
	return 999


func _test_weather_transition_switches_promptly() -> void:
	var s_dt1: int = _transition_solves_to_switch(1.0)
	var s_dt3: int = _transition_solves_to_switch(3.0)
	var s_dt9: int = _transition_solves_to_switch(9.0)
	print("  [transition] solves-to-switch dt=1=%d dt=3=%d dt=9=%d (rate=0.35)" % [s_dt1, s_dt3, s_dt9])
	_expect("dt=9 transient weather displays in a single solve", s_dt9 == 1)
	_expect("dt=3 transient weather displays in a single solve", s_dt3 == 1)
	_expect("dt=1 keeps multi-solve smoothing (>=3 solves)", s_dt1 >= 3)


# ── 修复 3 探针：海冰 dt=9 极地饱和 + |Δ| 受 cap + 暖水不结冰 ──────────────────
func _test_sea_ice_dt9_polar_saturation_and_cap() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found — sea ice dt>1 section skipped")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null or not ext.has_method("run_sea_ice_daily_pass"):
		_skip("DCWorldExt.run_sea_ice_daily_pass unavailable — sea ice dt>1 section skipped")
		return
	var cp := ClimateProfile.new()
	var dt_days: float = 9.0
	var cap: float = float(cp.sea_ice_daily_delta_cap)
	var per_pass_cap: float = cap * dt_days

	# (a) 冷暗极地水：温度远低于 form 阈、极夜无日照 → 应在数次 dt=9 pass 内饱和到 >0.9，
	#     且每次 pass |Δ| 不超过 cap·dt。
	var map_cold := MapData.new(1, 1)
	_seed_one_ocean_cell(map_cold, 0.04, 0.0)
	map_cold.sea_ice_frac_arr = PackedFloat32Array([0.0])
	_expect("bind_map_data succeeds (cold polar)", bool(ext.call("bind_map_data", map_cold)))
	var cap_respected: bool = true
	var prev_frac: float = 0.0
	for _pass in range(6):
		var ms: float = float(ext.call("run_sea_ice_daily_pass",
				_sea_ice_knobs(cp, 0.04, 0.0, dt_days), 0.0))
		if ms < 0.0:
			_expect("sea ice native pass executed (cold polar)", false)
			return
		var now_frac: float = float(map_cold.sea_ice_frac_arr[0])
		if absf(now_frac - prev_frac) > per_pass_cap + 1e-4:
			cap_respected = false
		prev_frac = now_frac
	print("  [sea_ice] cold polar after 6x dt=9 passes: frac=%.4f (cap/pass=%.3f)" % [prev_frac, per_pass_cap])
	_expect("cold polar sea ice saturates (>0.9) under dt=9", prev_frac > 0.9)
	_expect("each dt=9 pass respects |Δ| <= daily_delta_cap*dt", cap_respected)

	# (b) 暖水（temp 远高于 melt 阈）携已存厚冰 → dt=9 一步应显著融化，绝不"暖水结冰"。
	var map_warm := MapData.new(1, 1)
	_seed_one_ocean_cell(map_warm, 0.50, 0.0)
	map_warm.sea_ice_frac_arr = PackedFloat32Array([0.80])
	_expect("bind_map_data succeeds (warm water)", bool(ext.call("bind_map_data", map_warm)))
	var ms_warm: float = float(ext.call("run_sea_ice_daily_pass",
			_sea_ice_knobs(cp, 0.50, 0.0, dt_days), 0.0))
	_expect("sea ice native pass executed (warm water)", ms_warm >= 0.0)
	var warm_frac: float = float(map_warm.sea_ice_frac_arr[0])
	print("  [sea_ice] warm water (temp=0.50) ice 0.80 -> %.4f after dt=9" % warm_frac)
	_expect("warm water melts ice (no ice-on-warm)", warm_frac < 0.80)
	_expect("warm water melt is substantial under dt=9", warm_frac < 0.30)


func _sea_ice_knobs(cp: ClimateProfile, temp: float, insol: float, dt_days: float) -> Dictionary:
	return {
		"n_cells": 1,
		"k_freeze": float(cp.sea_ice_freeze_rate),
		"k_melt": float(cp.sea_ice_melt_rate),
		"t_form": float(cp.sea_ice_form_threshold),
		"t_melt": float(cp.sea_ice_melt_threshold),
		"contagion": float(cp.sea_ice_neighbor_contagion),
		"threshold": float(cp.sea_ice_terrain_threshold),
		"hysteresis": float(cp.sea_ice_terrain_hysteresis),
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
		"temp_transport_anomaly": PackedFloat32Array([0.0]),
		"upwelling_strength": PackedFloat32Array([0.0]),
		"insolation_now_arr": PackedFloat32Array([insol]),
		"solar_gate_enabled": bool(cp.sea_ice_solar_gate_enabled),
		"freeze_insol_low": float(cp.sea_ice_freeze_insol_low),
		"freeze_insol_high": float(cp.sea_ice_freeze_insol_high),
		"solar_melt_start": float(cp.sea_ice_solar_melt_start),
		"solar_melt_gain": float(cp.sea_ice_solar_melt_gain),
		"min_thick_ice_solar_exposure": float(cp.sea_ice_min_thick_ice_solar_exposure),
		"edge_mix_rate": float(cp.sea_ice_edge_mix_rate),
		"cell_temperature_arr": PackedFloat32Array([temp]),
		"daily_delta_cap": float(cp.sea_ice_daily_delta_cap),
		"dt_days": dt_days,
		"apply_terrain_flips": false,
	}


func _seed_one_ocean_cell(map: MapData, temp: float, oanom: float) -> void:
	var n := 1
	map.temp_arr = PackedFloat32Array([temp])
	map.temp_baseline_arr = PackedFloat32Array([temp])
	map.temp_30d_arr = PackedFloat32Array([temp])
	map.temp_365d_arr = PackedFloat32Array([temp])
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
	map.temp_baseline_year_arr = PackedFloat32Array([temp])
	map.weather_vapor_arr = _pf(n, 0.0)
	map.weather_convergence_arr = _pf(n, 0.0)
	map.weather_instability_arr = _pf(n, 0.0)
	map.air_mass_temp_anomaly_arr = _pf(n, 0.0)
	map.ocean_thermal_anomaly_arr = PackedFloat32Array([oanom])
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


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
