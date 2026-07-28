extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	print("=== economy birth runtime %s: checks=%d failures=%d ===" % [
		"PASS" if _failures == 0 else "FAIL", _checks, _failures])
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("birth catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)) or not ClassDB.class_exists("DCWorldExt"):
		return
	_test_worker_scalar_birth_equivalence(compiled)
	_test_birth_waits_for_next_employment(compiled)
	_test_two_and_ten_year_attractor(compiled)

func _test_worker_scalar_birth_equivalence(compiled: Dictionary) -> void:
	const CELL_COUNT := 96
	var scalar := _configured_population_world(compiled, false, CELL_COUNT, 1000, 2301)
	var worker := _configured_population_world(compiled, true, CELL_COUNT, 1000, 2301)
	var scalar_report := _run_cycle(scalar, 0)
	var worker_report := _run_cycle(worker, 0)
	_expect("birth worker path dispatches multiple tasks",
		int(worker_report.get("worker_tasks", 1)) > 1)
	_expect("birth worker and scalar counts match",
		int(scalar_report.get("births", -1)) > 0 and
		int(scalar_report.get("births", -1)) == int(worker_report.get("births", -2)) and
		int(scalar_report.get("deaths", -1)) == int(worker_report.get("deaths", -2)))
	_expect("birth worker and scalar state hashes match",
		scalar.get_economy_state_hash() == worker.get_economy_state_hash())
	_expect("birth worker and scalar conserve population",
		int(scalar_report.get("population_error", 1)) == 0 and
		int(worker_report.get("population_error", 1)) == 0)

func _test_two_and_ten_year_attractor(compiled: Dictionary) -> void:
	const OPENING_POPULATION := 1000000
	const TWO_YEAR_CYCLES := 146
	const TEN_YEAR_CYCLES := 730
	var runtime := _configured_population_world(
		compiled, false, 1, OPENING_POPULATION, 2302)
	var two_year_population := 0
	var max_cycle_ms := 0.0
	var cycle_times_ms: Array[float] = []
	var started := Time.get_ticks_usec()
	for cycle in range(TEN_YEAR_CYCLES):
		var cycle_started := Time.get_ticks_usec()
		var report := _run_cycle(runtime, cycle)
		var cycle_ms := float(Time.get_ticks_usec() - cycle_started) / 1000.0
		cycle_times_ms.append(cycle_ms)
		max_cycle_ms = maxf(max_cycle_ms, cycle_ms)
		if int(report.get("population_error", 1)) != 0:
			_expect("long-run birth cycle conserves population", false)
			return
		if cycle + 1 == TWO_YEAR_CYCLES:
			two_year_population = int(runtime.get_population_cell_summary(0).population)
	var ten_year_population := int(runtime.get_population_cell_summary(0).population)
	var two_year_growth := float(two_year_population - OPENING_POPULATION) / OPENING_POPULATION
	var ten_year_growth := float(ten_year_population - OPENING_POPULATION) / OPENING_POPULATION
	_expect("two-year healthy-rate attractor stays near one percent growth",
		two_year_growth >= 0.008 and two_year_growth <= 0.013)
	_expect("ten-year healthy-rate attractor stays near five percent growth",
		ten_year_growth >= 0.045 and ten_year_growth <= 0.058)
	cycle_times_ms.sort()
	var average_cycle_ms := float(Time.get_ticks_usec() - started) / 1000.0 / TEN_YEAR_CYCLES
	var p95_cycle_ms := cycle_times_ms[int(floor(0.95 * (cycle_times_ms.size() - 1)))]
	print("  birth-attractor two_year=%.4f ten_year=%.4f avg_ms=%.3f p95_ms=%.3f max_ms=%.3f" % [
		two_year_growth, ten_year_growth,
		average_cycle_ms, p95_cycle_ms, max_cycle_ms])

func _test_birth_waits_for_next_employment(compiled: Dictionary) -> void:
	var ext := _new_ext(1)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var signatures: PackedStringArray = catalog.signature_keys
	var artisan_signature := signatures.find("artisan|default")
	var merchant_signature := signatures.find("merchant|default")
	var unemployed_signature := signatures.find("unemployed|default")
	var births: PackedInt64Array = catalog.signature_birth_rate_q32
	var deaths: PackedInt64Array = catalog.signature_death_rate_q32
	births.fill(0)
	deaths.fill(0)
	births[artisan_signature] = 858993460
	catalog.signature_birth_rate_q32 = births
	catalog.signature_death_rate_q32 = deaths
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.starvation_death_rate_q32 = 0
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	_expect("birth employment country configures",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 2303))
	_expect("birth employment economy configures",
		bool(ext.configure_economy(catalog, profile, 1, 2303).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000000)
	var knapping_type := (catalog.building_type_ids as PackedStringArray).find(
		"knapping_workshop")
	_expect("birth employment population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([artisan_signature, merchant_signature]),
		"population": PackedInt64Array([1, 1]),
		"funds": PackedInt64Array([1000000000000, 1000000000000]),
	}, {
		"stock": stock,
		"building_cells": PackedInt32Array([0]),
		"building_type_ids": PackedInt32Array([knapping_type]),
		"building_owner_signature_ids": PackedInt32Array([artisan_signature]),
		"building_counts": PackedInt64Array([2]),
	}).get("ok", false)))
	var report := _run_cycle(ext, 0)
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	var unemployed_row := (population.signature_ids as PackedInt32Array).find(
		unemployed_signature)
	_expect("birth enters zero-fund unemployed cohort",
		int(report.get("births", 0)) == 1 and unemployed_row >= 0 and
		int((population.populations as PackedInt64Array)[unemployed_row]) == 1 and
		int((population.funds_by_cohort as PackedInt64Array)[unemployed_row]) == 0)
	_expect("birth does not recruit into an owner vacancy in the same cycle",
		_sum_i64(buildings.filled_owner as PackedInt64Array) == 1 and
		_sum_i64(buildings.owner_openings as PackedInt64Array) == 1 and
		int((population.owner_employed_by_cohort as PackedInt64Array)[unemployed_row]) == 0 and
		int(report.get("population_error", 1)) == 0)

func _configured_population_world(compiled: Dictionary, workers: bool,
		cells: int, population_per_cell: int, seed: int) -> Object:
	var ext := _new_ext(cells)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	# Weight zero isolates the calibrated full-satisfaction attractor from goods supply.
	var weights: PackedInt64Array = catalog.signature_satisfaction_birth_weight_q16
	weights.fill(0)
	catalog.signature_satisfaction_birth_weight_q16 = weights
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.starvation_death_rate_q32 = 0
	profile.worker_enabled = workers
	profile.worker_market_threshold = 1
	profile.worker_tasks_hint = 4 if workers else 0
	_expect("birth test country configures",
		CountryTestHelper.configure_all_technologies(ext, catalog, cells, seed))
	_expect("birth test economy configures",
		bool(ext.configure_economy(catalog, profile, cells, seed).get("ok", false)))
	var worker_signature := (catalog.signature_keys as PackedStringArray).find("worker|default")
	var cell_indices := PackedInt32Array()
	var signature_ids := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	for cell in range(cells):
		cell_indices.append(cell)
		signature_ids.append(worker_signature)
		populations.append(population_per_cell)
		funds.append(0)
	_expect("birth test population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": cell_indices,
		"signature_ids": signature_ids,
		"population": populations,
		"funds": funds,
	}, {}).get("ok", false)))
	return ext

func _new_ext(cells: int) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover", &"cell_weather_intensity"]:
		var values := PackedFloat32Array()
		values.resize(cells)
		values.fill(1.0 if slot_name == &"cell_temp" else 0.0)
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, values)
	return ext

func _run_cycle(ext: Object, cycle: int) -> Dictionary:
	var report: Dictionary = {}
	for slice in range(256):
		report = ext.run_economy_slice({
			"day_index": cycle * 5,
			"tick_index": slice,
		})
		if bool(report.get("done", false)):
			return report
	return report

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1

func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total
