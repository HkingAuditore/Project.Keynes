extends SceneTree

# Headless:
#   godot --headless --script tests/vegetation_climate_loop_formula_test.gd --quit
#
# Formula-level guard for the climate -> water -> vegetation vitality loop.

const ClimateProfileScript := preload("res://scripts/data/climate_profile.gd")

var _checks: int = 0
var _failures: int = 0
var _cp: ClimateProfile


func _init() -> void:
	_cp = ClimateProfileScript.new()
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== vegetation climate loop formula ===")
	_test_plant_water_monotonic()
	_test_vitality_tracks_target()
	_test_weather_resistance_reduces_stress()
	_test_weather_pressure_write_gate()
	_test_succession_min_gain()
	_test_rainforest_threshold_alignment()
	_test_native_cadence_day_scale()
	_test_low_vitality_damping()
	_test_succession_reset_and_cooldown()
	_test_succession_candidate_publish()
	_finish()


func _test_plant_water_monotonic() -> void:
	var dry: float = _plant_water(0.20, -0.40, 0.0)
	var base: float = _plant_water(0.20, 0.0, 0.0)
	var wet_balance: float = _plant_water(0.20, 0.40, 0.0)
	var wet_soil: float = _plant_water(0.20, 0.40, 0.30)
	_expect("drought lowers plant water", dry < base)
	_expect("positive water balance raises plant water", wet_balance > base)
	_expect("soil buffer raises plant water", wet_soil > wet_balance)
	_expect("plant water clamps to [0,1]", _plant_water(0.90, 1.0, 1.0) <= 1.0 and _plant_water(0.0, -2.0, 0.0) >= 0.0)


func _test_vitality_tracks_target() -> void:
	var up: float = _vitality_step(0.20, 0.80, 1.0)
	var down: float = _vitality_step(0.80, 0.20, 1.0)
	_expect("target above vitality raises vitality", up > 0.20)
	_expect("target below vitality lowers vitality", down < 0.80)
	_expect("negative drift uses harshness", is_equal_approx(down, 0.80 + (0.20 - 0.80) * float(_cp.vitality_change_rate) * float(_cp.compat_harshness)))


func _test_weather_resistance_reduces_stress() -> void:
	var drought: int = int(WeatherType.WT.DROUGHT)
	var wi: float = 0.85
	var scrub_stress: float = _weather_stress(int(VegetationType.VEG.DESERT_SCRUB), drought, wi)
	var rainforest_stress: float = _weather_stress(int(VegetationType.VEG.TROPICAL_RAINFOREST), drought, wi)
	_expect("weather resistance reduces drought stress", scrub_stress < rainforest_stress)
	_expect("clear weather has no stress", is_equal_approx(_weather_stress(int(VegetationType.VEG.TEMPERATE_GRASSLAND), int(WeatherType.WT.CLEAR), 1.0), 0.0))


func _test_weather_pressure_write_gate() -> void:
	var target_pressure: float = 0.32
	var rain: int = int(WeatherType.WT.RAIN)
	var preserved: float = _weather_feedback_pressure(target_pressure, rain, 1.0, false)
	var accumulated: float = _weather_feedback_pressure(target_pressure, rain, 1.0, true)
	_expect("weather feedback preserves target pressure when gated", is_equal_approx(preserved, target_pressure))
	_expect("weather feedback can still accumulate on non-veg-dyn ticks", accumulated > target_pressure)


func _test_succession_min_gain() -> void:
	var veg: int = int(VegetationType.VEG.TEMPERATE_GRASSLAND)
	var temp: float = 0.50
	var plant_water: float = 0.45
	var current: float = VegetationType.climate_compat_score(veg, temp, plant_water)
	var next_r: int = int(VegetationType.next_in_succession(veg, 1))
	var next_score: float = VegetationType.climate_compat_score(next_r, temp, plant_water)
	var eligible: bool = next_r != veg and next_score >= current + float(_cp.succession_min_compat_gain)
	_expect("current biome is near-optimal test fixture", current > 0.95)
	_expect("small/no compat gain blocks succession", not eligible)


func _test_rainforest_threshold_alignment() -> void:
	var profile = VegetationProfileRegistry.get_profile(
		int(VegetationType.VEG.TROPICAL_RAINFOREST))
	var lower_non_drought_bound: float = float(profile.ideal_moist) - float(profile.moist_tolerance)
	var observed_compat: float = VegetationType.climate_compat_score(
		int(VegetationType.VEG.TROPICAL_RAINFOREST), 0.78, 0.52)
	_expect("generated rainforest threshold is not born in acute drought",
		lower_non_drought_bound <= 0.50)
	_expect("observed warm humid rainforest remains ecologically viable",
		observed_compat >= 0.25)


func _test_native_cadence_day_scale() -> void:
	var map := MapData.new(1, 1)
	map.set_cell(HexCell.new(0, 0))
	map._build_indices()
	map.init_soa_from_bake()
	var generator := MapGenerator.new()
	var stage_b_stride_calls: int = int(_cp.weather_vegetation_dynamics_stride)
	var knobs: Dictionary = generator._build_native_daily_stage_b_knobs(
		map, _cp, stage_b_stride_calls, 10.0)
	_expect("native vegetation cadence accumulates real game days",
		is_equal_approx(float(knobs.get("day_scale", 0.0)),
			float(stage_b_stride_calls) * 10.0) and
		int(knobs.get("streak_days", 0)) == stage_b_stride_calls * 10)


func _test_low_vitality_damping() -> void:
	var normal_drop: float = 0.30 - _vitality_step(0.30, 0.0, 1.0)
	var low_drop: float = 0.10 - _vitality_step(0.10, 0.0, 1.0)
	_expect("low vitality damping slows further decline", low_drop < normal_drop)


func _test_succession_reset_and_cooldown() -> void:
	var degraded_vitality: float = _succession_reset_vitality(true)
	var upgraded_vitality: float = _succession_reset_vitality(false)
	_expect("degrade reset target defaults to 0.75", is_equal_approx(degraded_vitality, float(_cp.vegetation_degrade_reset_target)))
	_expect("upgrade reset target remains conservative", is_equal_approx(upgraded_vitality, 0.7))
	_expect("succession cooldown stores negative streak days", _cooldown_streak_after_change() == -int(_cp.vegetation_succession_cooldown_days))
	_expect("cooldown advances toward zero", _advance_cooldown(-30, 10) == -20)


func _test_succession_candidate_publish() -> void:
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	cell.vegetation = int(VegetationType.VEG.TROPICAL_RAINFOREST)
	cell.base_vegetation = int(VegetationType.VEG.TROPICAL_RAINFOREST)
	cell.vegetation_vitality = 0.20
	map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	var generator := MapGenerator.new()
	var applied: int = generator._apply_vegetation_succession_candidates(
		map,
		PackedInt32Array([0]),
		PackedByteArray([int(VegetationType.VEG.TROPICAL_DRY_FOREST)]),
		_cp)
	_expect("native succession candidate is applied", applied == 1)
	_expect("succession publishes vegetation to cell and map SoA",
		int(cell.vegetation) == int(VegetationType.VEG.TROPICAL_DRY_FOREST) and
		int(map.vegetation_arr[0]) == int(VegetationType.VEG.TROPICAL_DRY_FOREST))
	_expect("succession publishes base vegetation and visible state",
		int(cell.base_vegetation) == int(VegetationType.VEG.TROPICAL_DRY_FOREST) and
		int(map.base_vegetation_arr[0]) == int(VegetationType.VEG.TROPICAL_DRY_FOREST) and
		int(cell.current_state.get("vegetation", -1)) == int(VegetationType.VEG.TROPICAL_DRY_FOREST))
	_expect("succession resets vitality softly and starts cooldown",
		cell.vegetation_vitality > 0.20 and cell._vitality_low_streak < 0 and
		cell._vitality_high_streak < 0)


func _plant_water(base_moisture: float, water_balance_30d: float, soil_moisture: float) -> float:
	return clampf(
		base_moisture
		+ maxf(water_balance_30d, 0.0) * float(_cp.plant_water_balance_weight)
		+ maxf(soil_moisture, 0.0) * float(_cp.plant_soil_buffer_weight)
		+ minf(water_balance_30d, 0.0) * float(_cp.plant_drought_penalty),
		0.0,
		1.0
	)


func _vitality_step(vitality: float, target: float, day_scale: float) -> float:
	var dv: float = (target - vitality) * float(_cp.vitality_change_rate)
	if dv < 0.0:
		dv *= float(_cp.compat_harshness)
		var threshold: float = float(_cp.vegetation_low_vitality_damping_threshold)
		if threshold > 0.0 and vitality < threshold:
			dv *= clampf(vitality / threshold, 0.25, 1.0)
	return clampf(vitality + dv * maxf(day_scale, 1.0), 0.0, 1.0)


func _weather_stress(veg: int, wt: int, wi: float) -> float:
	var base_penalty: float = _weather_penalty(wt)
	var resistance: float = VegetationType.weather_resistance(veg, wt)
	return base_penalty * maxf(wi, 0.0) * (1.0 - resistance) * float(_cp.vegetation_weather_penalty_scale)


func _weather_penalty(wt: int) -> float:
	match wt:
		WeatherType.WT.DROUGHT:
			return 0.004
		WeatherType.WT.HEATWAVE:
			return 0.003
		WeatherType.WT.STORM:
			return 0.001
		WeatherType.WT.MONSOON:
			return 0.001
		_:
			return 0.0


func _weather_feedback_pressure(prev_pressure: float, wt: int, wi: float, write_weather_veg_pressure: bool) -> float:
	if not write_weather_veg_pressure:
		return prev_pressure
	var precip_contrib: float = 0.0
	match wt:
		WeatherType.WT.RAIN:
			precip_contrib = wi
		WeatherType.WT.STORM:
			precip_contrib = wi * 0.8
		WeatherType.WT.MONSOON:
			precip_contrib = wi * 1.2
		WeatherType.WT.BLIZZARD:
			precip_contrib = wi * 0.3
		WeatherType.WT.DROUGHT:
			precip_contrib = -wi * 0.6
		WeatherType.WT.HEATWAVE:
			precip_contrib = -wi * 0.4
	var d_veg: float = clampf(
		float(_cp.weather_to_vegetation_gain) * precip_contrib,
		-float(_cp.feedback_per_day_clamp),
		float(_cp.feedback_per_day_clamp)
	)
	return clampf(prev_pressure + d_veg, -0.5, 0.5)


func _succession_reset_vitality(is_degrade: bool) -> float:
	return float(_cp.vegetation_degrade_reset_target) if is_degrade else 0.7


func _cooldown_streak_after_change() -> int:
	var cooldown: int = int(_cp.vegetation_succession_cooldown_days)
	return -cooldown if cooldown > 0 else 0


func _advance_cooldown(streak: int, streak_days: int) -> int:
	return mini(streak + streak_days, 0)


func _finish() -> void:
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
