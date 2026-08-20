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
	_expect("carrying catalog compiles twenty-one families",
		(compiled.carrying_family_ids as PackedStringArray).size() == 21 and
		String((compiled.carrying_family_ids as PackedStringArray)[0]) == "staple" and
		String((compiled.carrying_family_ids as PackedStringArray)[6]) == "hygiene" and
		String((compiled.carrying_family_ids as PackedStringArray)[17]) == "construction")
	_test_worker_scalar_birth_equivalence(compiled)
	_test_birth_waits_for_next_employment(compiled)
	_test_small_population_birth_residual_save_restore(compiled)
	_test_two_and_ten_year_attractor(compiled)
	_test_overcrowded_replacement(compiled)
	_test_unlocked_families_are_neutral(compiled)
	_test_list_snapshot_omits_demand_preview(compiled)
	_test_resources_raise_k_geo(compiled)
	_test_class_weights_compile(compiled)
	_test_household_survives_merchant_death(compiled)

func _test_worker_scalar_birth_equivalence(compiled: Dictionary) -> void:
	const CELL_COUNT := 96
	var scalar := _configured_population_world(compiled, false, CELL_COUNT, 1000, 2301)
	var worker := _configured_population_world(compiled, true, CELL_COUNT, 1000, 2301)
	_run_cycle(scalar, 0)
	_run_cycle(worker, 0)
	var scalar_report := _run_cycle(scalar, 1)
	var worker_report := _run_cycle(worker, 1)
	print("  birth worker_tasks=%d last_completed_max=%d market_max=%d scalar_births=%d worker_births=%d scalar_deaths=%d worker_deaths=%d" % [
		int(worker_report.get("worker_tasks", -1)),
		int(worker_report.get("last_completed_market_worker_tasks_max", -1)),
		int(worker_report.get("market_worker_tasks_max", -1)),
		int(scalar_report.get("births", -1)),
		int(worker_report.get("births", -1)),
		int(scalar_report.get("deaths", -1)),
		int(worker_report.get("deaths", -1))])
	_expect("birth worker path dispatches multiple tasks",
		int(worker_report.get("worker_tasks", 1)) > 1
		or int(worker_report.get("last_completed_market_worker_tasks_max", 1)) > 1
		or int(worker_report.get("market_worker_tasks_max", 1)) > 1)
	var scalar_population := _world_population(scalar, CELL_COUNT)
	var worker_population := _world_population(worker, CELL_COUNT)
	_expect("birth worker and scalar counts match",
		scalar_population == worker_population and scalar_population > 0)
	_expect("birth worker and scalar state hashes match",
		scalar.get_economy_state_hash() == worker.get_economy_state_hash())
	_expect("birth worker and scalar conserve population",
		int(scalar_report.get("population_error", 1)) == 0 and
		int(worker_report.get("population_error", 1)) == 0)

func _test_two_and_ten_year_attractor(compiled: Dictionary) -> void:
	const OPENING_POPULATION := 15
	const TWO_YEAR_CYCLES := 146
	const TEN_YEAR_CYCLES := 730
	var runtime := _configured_population_world(
		compiled, false, 1, OPENING_POPULATION, 2302)
	var opening := int(runtime.get_population_cell_summary(0).population)
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
	var two_year_growth := float(two_year_population - opening) / float(opening)
	var summary: Dictionary = runtime.get_population_cell_summary(0)
	var k_geo := int(summary.get("carrying_k_geo", 0))
	var k_eff := int(summary.get("carrying_k_eff", 0))
	_expect("two-year small-population growth stays near forty-two percent",
		two_year_population >= 21 and two_year_population <= 22)
	_expect("ten-year attractor stays near geographic carrying",
		ten_year_population >= 32 and ten_year_population <= 45 and
		k_geo >= 32 and k_geo <= 48 and k_eff >= 32 and k_eff <= 48)
	cycle_times_ms.sort()
	var average_cycle_ms := float(Time.get_ticks_usec() - started) / 1000.0 / TEN_YEAR_CYCLES
	var p95_cycle_ms := cycle_times_ms[int(floor(0.95 * (cycle_times_ms.size() - 1)))]
	print("  birth-attractor opening=%d two_year=%d growth=%.4f ten_year=%d k_geo=%d k_eff=%d avg_ms=%.3f p95_ms=%.3f max_ms=%.3f" % [
		opening, two_year_population, two_year_growth, ten_year_population,
		k_geo, k_eff, average_cycle_ms, p95_cycle_ms, max_cycle_ms])

func _test_overcrowded_replacement(compiled: Dictionary) -> void:
	const OPENING_POPULATION := 200
	const CYCLES := 40
	var runtime := _configured_population_world(
		compiled, false, 1, OPENING_POPULATION, 2306)
	var opening := int(runtime.get_population_cell_summary(0).population)
	for cycle in range(CYCLES):
		var report := _run_cycle(runtime, cycle)
		if int(report.get("population_error", 1)) != 0:
			_expect("overcrowded birth cycle conserves population", false)
			return
	var later := int(runtime.get_population_cell_summary(0).population)
	var k_eff := int(runtime.get_population_cell_summary(0).get("carrying_k_eff", 0))
	_expect("overcrowded population stays near replacement instead of doubling",
		later >= opening - 12 and later <= opening + 12 and
		later > k_eff and k_eff >= 32 and k_eff <= 48)
	print("  overcrowded opening=%d later=%d k_eff=%d" % [opening, later, k_eff])

func _test_unlocked_families_are_neutral(compiled: Dictionary) -> void:
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var worker_signature := (catalog.signature_keys as PackedStringArray).find(
		"worker|default")
	var profile := _logistic_profile(false)
	var ext := _new_ext(1, catalog)
	_expect("unlocked-family country configures without technologies",
		_configure_starting_technologies(ext, catalog, 1, 2307, PackedStringArray()))
	_expect("unlocked-family economy configures",
		bool(ext.configure_economy(catalog, profile, 1, 2307).get("ok", false)))
	_expect("unlocked-family population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_signature]),
		"population": PackedInt64Array([15]),
		"funds": PackedInt64Array([0]),
	}, {}).get("ok", false)))
	var report := _run_cycle(ext, 0)
	var snapshot: Dictionary = ext.get_population_cell_snapshot(0)
	var family_ids: PackedStringArray = snapshot.get("carrying_family_ids", PackedStringArray())
	var bindable: PackedByteArray = snapshot.get("carrying_family_bindable", PackedByteArray())
	var hygiene_idx := family_ids.find("hygiene")
	var housing_idx := family_ids.find("housing")
	_expect("uninvented hygiene stays out of the surplus denominator",
		int(report.get("population_error", 1)) == 0 and
		hygiene_idx >= 0 and housing_idx >= 0 and
		int(bindable[hygiene_idx]) == 0 and int(bindable[housing_idx]) == 0 and
		int(snapshot.get("carrying_surplus_q16", 0)) > 0)
	print("  unlocked-family surplus=%d hygiene_bindable=%d housing_bindable=%d" % [
		int(snapshot.get("carrying_surplus_q16", 0)),
		int(bindable[hygiene_idx]) if hygiene_idx >= 0 else -1,
		int(bindable[housing_idx]) if housing_idx >= 0 else -1])

func _test_list_snapshot_omits_demand_preview(compiled: Dictionary) -> void:
	var ext := _configured_population_world(compiled, false, 1, 15, 2311)
	_run_cycle(ext, 0)
	var full: Dictionary = ext.get_population_cell_snapshot(0, true)
	var listed: Dictionary = ext.get_population_cell_snapshot(0, false)
	var full_pops: PackedInt64Array = full.get("populations", PackedInt64Array())
	var list_pops: PackedInt64Array = listed.get("populations", PackedInt64Array())
	_expect("list snapshot keeps cohort populations",
		bool(listed.get("ok", false)) and
		bool(listed.get("demand_preview_included", true)) == false and
		bool(full.get("demand_preview_included", false)) == true and
		list_pops == full_pops and
		int(listed.get("population", -1)) == int(full.get("population", -2)))
	_expect("list snapshot omits demand preview CSR",
		not listed.has("demand_good_offsets") and
		not listed.has("demand_need_offsets") and
		(full.get("demand_good_offsets", PackedInt32Array()) as PackedInt32Array).size()
			== full_pops.size() + 1)
	print("  list-snapshot cohorts=%d demand_offsets=%d" % [
		full_pops.size(),
		(full.get("demand_good_offsets", PackedInt32Array()) as PackedInt32Array).size()])

func _test_resources_raise_k_geo(compiled: Dictionary) -> void:
	var habitat := _configured_resource_world(compiled, 0.0, 2308)
	var farmed := _configured_resource_world(compiled, 100.0, 2308)
	_run_cycle(habitat, 0)
	_run_cycle(farmed, 0)
	var habitat_k := int(habitat.get_population_cell_summary(0).get("carrying_k_geo", 0))
	var farmed_k := int(farmed.get_population_cell_summary(0).get("carrying_k_geo", 0))
	_expect("plain habitat K_geo stays near the reference forty",
		habitat_k >= 32 and habitat_k <= 48)
	_expect("unlocked food buildings raise K_geo above habitat",
		farmed_k > habitat_k)
	print("  k_geo habitat=%d farmed=%d" % [habitat_k, farmed_k])

func _test_class_weights_compile(compiled: Dictionary) -> void:
	var profile = load("res://data/economy/default_economy.tres")
	var farmer_idx: int = profile.carrying_class_ids.find("farmer")
	var technology_idx: int = profile.carrying_class_ids.find("technology")
	_expect("farmer class weight exceeds technology class weight",
		farmer_idx >= 0 and technology_idx >= 0 and
		int(profile.carrying_class_weight_q16[farmer_idx]) >
			int(profile.carrying_class_weight_q16[technology_idx]))
	var runtime := _configured_population_world(compiled, false, 1, 15, 2309)
	_run_cycle(runtime, 0)
	var sat_q16 := int(runtime.get_population_cell_summary(0).get("carrying_sat_q16", 0))
	_expect("class-weighted cell satisfaction stays inside authored floors",
		sat_q16 >= 8192 and sat_q16 <= 65536)

func _test_household_survives_merchant_death(compiled: Dictionary) -> void:
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var signatures: PackedStringArray = catalog.signature_keys
	var worker_signature := signatures.find("worker|default")
	var merchant_signature := signatures.find("merchant|default")
	var death_rates: PackedInt64Array = catalog.signature_death_rate_q32.duplicate()
	death_rates.fill(0)
	death_rates[merchant_signature] = 4294967296
	catalog.signature_death_rate_q32 = death_rates
	var profile := _logistic_profile(false)
	var ext := _new_ext(1, catalog)
	_expect("dead-merchant household country configures",
		CountryTestHelper.configure_all_technologies(ext, catalog, 1, 2310))
	_expect("dead-merchant household economy configures",
		bool(ext.configure_economy(catalog, profile, 1, 2310).get("ok", false)))
	var stock := PackedInt64Array()
	stock.resize((catalog.good_ids as PackedStringArray).size())
	stock.fill(1000000000)
	_expect("dead-merchant household population bootstraps", bool(ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([worker_signature, merchant_signature]),
		"population": PackedInt64Array([20, 1]),
		"funds": PackedInt64Array([1000000000000, 1000000000000]),
	}, {
		"stock": stock,
	}).get("ok", false)))
	for cycle in range(3):
		var report := _run_cycle(ext, cycle)
		var population: Dictionary = ext.get_population_cell_snapshot(0)
		_expect("household survives merchant death on cycle %d" % cycle,
			bool(report.get("done", false)) and
			not bool(report.get("fatal", false)) and
			String(report.get("fatal_reason", "")) == "" and
			int(report.get("money_error", 1)) == 0 and
			int(report.get("goods_error", 1)) == 0 and
			_sum_u8(population.get("merchant_flags", PackedByteArray()) as PackedByteArray) >= 1)
		print("  dead-merchant cycle=%d repairs=%d money_error=%d goods_error=%d living_merchants=%d" % [
			cycle,
			int(report.get("merchant_repairs", 0)),
			int(report.get("money_error", 0)),
			int(report.get("goods_error", 0)),
			_sum_u8(population.get("merchant_flags", PackedByteArray()) as PackedByteArray)])

func _sum_u8(values: PackedByteArray) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total

func _test_birth_waits_for_next_employment(compiled: Dictionary) -> void:
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var ext := _new_ext(1, catalog)
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
	var profile := _logistic_profile(false)
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

func _test_small_population_birth_residual_save_restore(compiled: Dictionary) -> void:
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var worker_signature := (catalog.signature_keys as PackedStringArray).find(
		"worker|default")
	var births: PackedInt64Array = catalog.signature_birth_rate_q32
	var deaths: PackedInt64Array = catalog.signature_death_rate_q32
	var weights: PackedInt64Array = catalog.signature_satisfaction_birth_weight_q16
	births.fill(429496730)
	deaths.fill(0)
	weights.fill(0)
	# One person accumulates just over half a Q32 birth per five-day cycle.
	catalog.signature_birth_rate_q32 = births
	catalog.signature_death_rate_q32 = deaths
	catalog.signature_satisfaction_birth_weight_q16 = weights
	var profile := _logistic_profile(false)
	var source := _new_ext(1, catalog)
	_expect("small-population source country configures",
		CountryTestHelper.configure_all_technologies(source, catalog, 1, 2304))
	_expect("small-population source economy configures",
		bool(source.configure_economy(catalog, profile, 1, 2304).get("ok", false)))
	_expect("small-population source bootstraps", bool(source.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_signature]),
		"population": PackedInt64Array([1]),
		"funds": PackedInt64Array([0]),
	}, {}).get("ok", false)))
	var first_report := _run_cycle(source, 0)
	_expect("fractional birth remains pending after first cycle",
		int(first_report.get("births", -1)) == 0 and
		int(source.get_population_cell_summary(0).population) == 1)
	var saved := _save(source)
	_expect("PKEC v41 saves accumulated birth residual and support EMA",
		bool(saved.get("ok", false)) and int(saved.get("schema", 0)) == 39)
	var restored := _new_ext(1, catalog)
	_expect("small-population restored country configures",
		CountryTestHelper.configure_all_technologies(restored, catalog, 1, 2304))
	_expect("small-population restored economy configures",
		bool(restored.configure_economy(catalog, profile, 1, 2304).get("ok", false)))
	var restore_result := _restore(restored, saved.get("chunks", []))
	_expect("PKEC v41 restores accumulated birth residual",
		bool(restore_result.get("ok", false)) and
		source.get_economy_state_hash() == restored.get_economy_state_hash())
	var source_second := _run_cycle(source, 1)
	var restored_second := _run_cycle(restored, 1)
	print("  small-pop residual source_births=%d restored_births=%d source_pop=%d restored_pop=%d source_hash=%d restored_hash=%d" % [
		int(source_second.get("births", 0)), int(restored_second.get("births", 0)),
		int(source.get_population_cell_summary(0).population),
		int(restored.get_population_cell_summary(0).population),
		int(source.get_economy_state_hash()), int(restored.get_economy_state_hash())])
	_expect("small population deterministically births on the next cycle",
		int(source_second.get("births", 0)) == 1 and
		int(restored_second.get("births", 0)) == 1 and
		int(source.get_population_cell_summary(0).population) == 2 and
		source.get_economy_state_hash() == restored.get_economy_state_hash())

func _configured_population_world(compiled: Dictionary, workers: bool,
		cells: int, population_per_cell: int, seed: int) -> Object:
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var ext := _new_ext(cells, catalog)
	# Weight zero isolates the calibrated full-satisfaction attractor from goods supply.
	var weights: PackedInt64Array = catalog.signature_satisfaction_birth_weight_q16
	weights.fill(0)
	catalog.signature_satisfaction_birth_weight_q16 = weights
	var profile := _logistic_profile(workers)
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

func _configured_resource_world(compiled: Dictionary, arable: float, seed: int) -> Object:
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var ext := _new_ext(1, catalog)
	_set_resource(ext, catalog, "arable_land", arable)
	_set_resource(ext, catalog, "fertile_soil", arable)
	var profile := _logistic_profile(false)
	CountryTestHelper.configure_all_technologies(ext, catalog, 1, seed)
	ext.configure_economy(catalog, profile, 1, seed)
	var worker_signature := (catalog.signature_keys as PackedStringArray).find("worker|default")
	ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0]),
		"signature_ids": PackedInt32Array([worker_signature]),
		"population": PackedInt64Array([15]),
		"funds": PackedInt64Array([0]),
	}, {})
	return ext

func _logistic_profile(workers: bool) -> Dictionary:
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.market_cycle_days = 5
	profile.starvation_death_rate_q32 = 0
	profile.worker_enabled = workers
	profile.worker_market_threshold = 1
	profile.worker_tasks_hint = 4 if workers else 0
	profile.carrying_surplus_elasticity_q16 = 0
	profile.carrying_sat_elasticity_q16 = 0
	return profile

func _configure_starting_technologies(ext: Object, catalog: Dictionary,
		cell_count: int, seed: int, technology_ids: PackedStringArray) -> bool:
	var water := PackedByteArray()
	water.resize(cell_count)
	water.fill(0)
	var country_profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": technology_ids,
	}
	var configured: Dictionary = ext.configure_country(
		catalog, country_profile, cell_count, seed)
	if not bool(configured.get("ok", false)):
		return false
	return bool(ext.bootstrap_country({}, water).get("ok", false))

func _new_ext(cells: int, catalog: Dictionary = {}) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cells)
	var climate := PackedFloat32Array()
	climate.resize(cells)
	climate.fill(0.5)
	var zero_f := PackedFloat32Array()
	zero_f.resize(cells)
	zero_f.fill(0.0)
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_weather_precip"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, climate)
	for slot_name in [&"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var slot: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(slot, 0, zero_f)
	var terrain := PackedByteArray()
	terrain.resize(cells)
	terrain.fill(2)
	var landform := PackedByteArray()
	landform.resize(cells)
	landform.fill(LandformType.LF.PLAIN)
	var vegetation := PackedByteArray()
	vegetation.resize(cells)
	vegetation.fill(VegetationType.VEG.TEMPERATE_GRASSLAND)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(cells)
	zeros_u8.fill(0)
	var terrain_sid: int = ext.register_component(&"cell_terrain", 2, 1, false)
	ext.write_u8_range(terrain_sid, 0, terrain)
	var landform_sid: int = ext.register_component(&"cell_landform", 2, 1, false)
	ext.write_u8_range(landform_sid, 0, landform)
	var vegetation_sid: int = ext.register_component(&"cell_vegetation", 2, 1, false)
	ext.write_u8_range(vegetation_sid, 0, vegetation)
	var water_sid: int = ext.register_component(&"cell_is_water", 2, 1, false)
	ext.write_u8_range(water_sid, 0, zeros_u8)
	var river_sid: int = ext.register_component(&"cell_has_river", 2, 1, false)
	ext.write_u8_range(river_sid, 0, zeros_u8)
	if not catalog.is_empty():
		var reserve_slots: PackedStringArray = catalog.get(
			"building_resource_reserve_slots", PackedStringArray())
		var extra_slots: PackedStringArray = catalog.get(
			"building_resource_extra_slots", PackedStringArray())
		for i in range(reserve_slots.size()):
			var reserve_sid: int = ext.register_component(
				StringName(reserve_slots[i]), 0, 1, false)
			var extra_sid: int = ext.register_component(
				StringName(extra_slots[i]), 0, 1, false)
			ext.write_f32_range(reserve_sid, 0, zero_f)
			ext.write_f32_range(extra_sid, 0, zero_f)
	return ext

func _set_resource(ext: Object, catalog: Dictionary, resource_id: String, reserve: float) -> void:
	var idx := (catalog.building_resource_ids as PackedStringArray).find(resource_id)
	if idx < 0:
		return
	var reserve_sid: int = ext.component_id(
		StringName(catalog.building_resource_reserve_slots[idx]))
	var extra_sid: int = ext.component_id(
		StringName(catalog.building_resource_extra_slots[idx]))
	var reserves: PackedFloat32Array = ext.snapshot_f32(reserve_sid)
	var changes: PackedFloat32Array = ext.snapshot_f32(extra_sid)
	reserves[0] = reserve
	changes[0] = 0.0
	ext.write_f32_range(reserve_sid, 0, reserves)
	ext.write_f32_range(extra_sid, 0, changes)

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

func _save(ext: Object) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_save(65536)
	if not bool(begin.get("ok", false)):
		return begin
	var chunks: Array[PackedByteArray] = []
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty():
			break
		chunks.append(chunk)
	var ended: Dictionary = ext.end_economy_save()
	return {"ok": bool(ended.get("ok", false)),
		"schema": int(begin.get("schema_version", 0)), "chunks": chunks}

func _restore(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(value as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()

func _world_population(ext: Object, cells: int) -> int:
	var total := 0
	for cell in range(cells):
		total += int(ext.get_population_cell_summary(cell).get("population", 0))
	return total

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
