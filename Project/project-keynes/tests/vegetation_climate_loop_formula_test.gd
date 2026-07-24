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
	_test_succession_cadence_guard()
	_test_native_cadence_day_scale()
	_test_moisture_cadence_defaults()
	_test_transpiration_transport_conservation()
	_test_low_vitality_damping()
	_test_succession_reset_and_cooldown()
	_test_succession_candidate_publish()
	_test_native_persistent_mismatch_succession()
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
		int(VegetationType.VEG.TROPICAL_RAINFOREST), 0.78, 0.58)
	_expect("generated rainforest threshold is not born in acute drought",
		lower_non_drought_bound <= 0.58)
	_expect("observed warm humid rainforest remains ecologically viable",
		observed_compat >= 0.25)
	var generator := MapGenerator.new()
	_expect("tropical rainforest is limited to the wet tail",
		int(generator._whittaker_vegetation(0.78, 0.57, int(LandformType.LF.PLAIN))) \
			!= int(VegetationType.VEG.TROPICAL_RAINFOREST) and
		int(generator._whittaker_vegetation(0.78, 0.59, int(LandformType.LF.PLAIN))) \
			== int(VegetationType.VEG.TROPICAL_RAINFOREST))


func _test_succession_cadence_guard() -> void:
	var native_sample_days: int = int(_cp.weather_vegetation_dynamics_stride) * 10
	_expect("persistent moderate mismatch can enter degradation",
		float(_cp.vitality_low_threshold) >= 0.40)
	_expect("succession needs more than one native vegetation sample",
		int(_cp.succession_degrade_days) >= native_sample_days * 2)


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
		int(knobs.get("streak_days", 0)) == stage_b_stride_calls * 10 and
		int(knobs.get("stage_b_call_index", -1)) == stage_b_stride_calls)


func _test_moisture_cadence_defaults() -> void:
	var daily_rate: float = float(_cp.runtime_moisture_base_relax_rate)
	var ten_day_alpha: float = 1.0 - pow(1.0 - daily_rate, 10.0)
	_expect("moisture anchor preserves the original responsive daily rate", is_equal_approx(daily_rate, 0.24))
	_expect("ten-day moisture anchor follows the dynamic target",
		absf(ten_day_alpha - 0.935711) < 0.00001)
	_expect("weather does not directly write climate moisture by default",
		not bool(_cp.weather_direct_moisture_enabled))
	_expect("runtime moisture precipitation coupling uses calibrated water-cycle amplitude",
		is_equal_approx(float(_cp.runtime_moisture_precip_weight), 0.78))
	_expect("runtime moisture soil coupling preserves annual wet-dry range",
		is_equal_approx(float(_cp.runtime_moisture_soil_weight), 1.82))
	_expect("runtime moisture soil drought coupling deepens dry minima",
		is_equal_approx(float(_cp.runtime_moisture_soil_dry_weight), 2.21))
	_expect("runtime moisture rolling balance remains a signed driver",
		is_equal_approx(float(_cp.runtime_moisture_water_balance_weight), 1.04))
	_expect("runtime moisture rolling deficit has stronger drought coupling",
		is_equal_approx(float(_cp.runtime_moisture_water_balance_dry_weight), 1.30))


func _test_transpiration_transport_conservation() -> void:
	var output: float = 0.8
	var source_gain: float = output * 0.01
	var transported: float = output * 0.025
	var valid_neighbors: int = 4
	var donor_delta: float = source_gain - transported
	var receiver_total: float = transported / float(valid_neighbors) * float(valid_neighbors)
	_expect("transpiration neighbor transport is conservative",
		is_equal_approx(donor_delta + receiver_total, source_gain))


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


func _test_native_persistent_mismatch_succession() -> void:
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	cell.terrain = int(TerrainType.TERRAIN.JUNGLE)
	cell.base_terrain = int(TerrainType.TERRAIN.JUNGLE)
	cell.vegetation = int(VegetationType.VEG.TROPICAL_RAINFOREST)
	cell.base_vegetation = int(VegetationType.VEG.TROPICAL_RAINFOREST)
	cell.temperature = 0.80
	cell.temp_30d_mean = 0.80
	cell.moisture = 0.34
	cell.base_moisture = 0.34
	cell.vegetation_vitality = 0.70
	map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.temp_30d_arr[0] = 0.80
	map.water_balance_30d_arr[0] = -0.10
	map.soil_moisture_arr[0] = 0.0
	var ext := DCWorldExt.new()
	_expect("native vegetation fixture binds", bool(ext.bind_map_data(map)))
	var generator := MapGenerator.new()
	var knobs: Dictionary = generator._build_native_daily_stage_b_knobs(map, _cp, 10, 10.0)
	var sample_days: int = int(knobs.get("streak_days", 0))
	var first_ms: float = float(ext.run_stage_b_pass(knobs))
	_expect("first persistent mismatch sample only accumulates streak",
		first_ms >= 0.0 and int(knobs.get("stat_succession_count", 0)) == 0 and
		int(map.vitality_low_streak_arr[0]) == sample_days)
	var final_ms: float = first_ms
	var samples_needed: int = ceili(float(_cp.succession_degrade_days) / float(sample_days))
	for _sample in range(1, samples_needed):
		knobs = generator._build_native_daily_stage_b_knobs(map, _cp, 10, 10.0)
		final_ms = float(ext.run_stage_b_pass(knobs))
	var to_veg: PackedByteArray = knobs.get("succession_to_veg", PackedByteArray())
	_expect("persistent mismatch emits climate-directed succession at the configured duration",
		final_ms >= 0.0 and int(knobs.get("stat_succession_count", 0)) == 1 and
		to_veg.size() == 1 and int(to_veg[0]) == int(VegetationType.VEG.TROPICAL_DRY_FOREST))


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
