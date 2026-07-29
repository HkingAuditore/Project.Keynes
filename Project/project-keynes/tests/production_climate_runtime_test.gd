extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")
const Q16_ONE := 65536

var failures := 0


func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		printerr("[FAIL] DCWorldExt unavailable")
		quit(1)
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("climate runtime catalog compiles", bool(compiled.get("ok", false)))
	if bool(compiled.get("ok", false)):
		var catalog := compiled.duplicate(true)
		catalog.erase("ok")
		_test_production_scaling(catalog)
		_test_rolling_freeze(catalog)
		_test_worker_scalar_and_save(catalog)
	print("=== production climate runtime %s ===" % (
		"PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _test_production_scaling(source_catalog: Dictionary) -> void:
	var catalog := _catalog_with_consumed_test_resources(source_catalog)
	var profile := _profile(false)
	var ideal := _configured_runtime(catalog, 1, 4401, false)
	var harsh := _configured_runtime(catalog, 1, 4401, false)
	_expect("ideal and harsh climate runtimes configure",
		bool(ideal.get("ok", false)) and bool(harsh.get("ok", false)))
	if not bool(ideal.get("ok", false)) or not bool(harsh.get("ok", false)):
		return
	var climate := _climate_values(catalog, "intensive_farm")
	_set_climate(ideal, climate.temperature, climate.water)
	_set_climate(harsh, 0.0, 0.0)
	_expect("ideal production runtime configures economy",
		bool(ideal.ext.configure_economy(catalog, profile, 1, 4401).get("ok", false)))
	_expect("harsh production runtime configures economy",
		bool(harsh.ext.configure_economy(catalog, profile, 1, 4401).get("ok", false)))
	_expect("ideal production fixture bootstraps",
		_bootstrap_intensive_farms(ideal.ext, catalog, 1))
	_expect("harsh production fixture bootstraps",
		_bootstrap_intensive_farms(harsh.ext, catalog, 1))
	var ideal_report := _run_simulation_day(ideal.ext, 0)
	var harsh_report := _run_simulation_day(harsh.ext, 0)
	var type_id := (catalog.building_type_ids as PackedStringArray).find(
		"intensive_farm")
	var ideal_group := _building_group(ideal.ext, 0, type_id)
	var harsh_group := _building_group(harsh.ext, 0, type_id)
	var ideal_snapshot: Dictionary = ideal_group.snapshot
	var harsh_snapshot: Dictionary = harsh_group.snapshot
	var ig := int(ideal_group.index)
	var hg := int(harsh_group.index)
	var ideal_capacity := _i64(ideal_snapshot, "last_climate_capacity_q16", ig)
	var harsh_capacity := _i64(harsh_snapshot, "last_climate_capacity_q16", hg)
	_expect("real profile reaches full capacity at its optimum",
		ig >= 0 and ideal_capacity == Q16_ONE)
	_expect("dryland floor caps a zero-signal cell at one quarter",
		hg >= 0 and harsh_capacity == int(climate.floor_q16))
	_expect("climate cap lowers output, input, and test resource consumption",
		_i64(ideal_snapshot, "last_output", ig) > _i64(
			harsh_snapshot, "last_output", hg) and
		_i64(ideal_snapshot, "last_input", ig) > _i64(
			harsh_snapshot, "last_input", hg) and
		_i64(ideal_snapshot, "last_resource", ig) > _i64(
			harsh_snapshot, "last_resource", hg))
	if not (_i64(harsh_snapshot, "last_climate_lost_output", hg) > 0 and
			_i64(harsh_snapshot, "capacity_q16", hg) <= harsh_capacity and
			_i64(harsh_snapshot, "last_temperature_fit_q16", hg) == 0 and
			_i64(harsh_snapshot, "last_water_fit_q16", hg) == 0):
		print("  harsh climate diagnostics=", {
			"lost": _i64(harsh_snapshot, "last_climate_lost_output", hg),
			"capacity": _i64(harsh_snapshot, "capacity_q16", hg),
			"climate": harsh_capacity,
			"temperature_fit": _i64(harsh_snapshot,
				"last_temperature_fit_q16", hg),
			"water_fit": _i64(harsh_snapshot, "last_water_fit_q16", hg),
		})
	_expect("climate loss is explicit and total capacity remains decomposed",
		_i64(harsh_snapshot, "last_climate_lost_output", hg) > 0 and
		_i64(harsh_snapshot, "capacity_q16", hg) <= harsh_capacity and
		_i64(harsh_snapshot, "last_temperature_fit_q16", hg) == 0 and
		_i64(harsh_snapshot, "last_water_fit_q16", hg) == 0)
	_expect("committed contract wage obligation is independent of climate output",
		_i64(ideal_snapshot, "last_base_wages_due", ig) > 0 and
		_i64(ideal_snapshot, "last_base_wages_due", ig) == _i64(
			harsh_snapshot, "last_base_wages_due", hg) and
		ideal_snapshot.get("employee_filled", PackedInt64Array()) ==
			harsh_snapshot.get("employee_filled", PackedInt64Array()))
	_expect("climate production keeps exact conservation",
		_conserved(ideal_report) and _conserved(harsh_report))
	_expect("climate report exposes limited groups and average capacity",
		int(harsh_report.get("climate_profiled_building_groups", 0)) == 1 and
		int(harsh_report.get("climate_limited_building_groups", 0)) == 1 and
		int(harsh_report.get("average_climate_capacity_q16", -1)) == harsh_capacity)


func _test_rolling_freeze(catalog: Dictionary) -> void:
	var runtime := _configured_runtime(catalog, 2, 4402, false)
	_expect("rolling climate runtime configures", bool(runtime.get("ok", false)))
	if not bool(runtime.get("ok", false)):
		return
	var climate := _climate_values(catalog, "intensive_farm")
	_set_climate(runtime, climate.temperature, climate.water)
	var profile := _profile(false)
	_expect("rolling climate economy configures", bool(runtime.ext.configure_economy(
		catalog, profile, 2, 4402).get("ok", false)))
	_expect("rolling climate fixture bootstraps",
		_bootstrap_intensive_farms(runtime.ext, catalog, 2))
	var type_id := (catalog.building_type_ids as PackedStringArray).find(
		"intensive_farm")
	var day0 := _run_simulation_day(runtime.ext, 0)
	var cell0_day0 := _building_group(runtime.ext, 0, type_id)
	var cell1_day0 := _building_group(runtime.ext, 1, type_id)
	_expect("day zero settles only phase-zero climate diagnostics",
		_conserved(day0) and _i64(cell0_day0.snapshot,
			"last_climate_capacity_q16", cell0_day0.index) == Q16_ONE and
		_i64(cell1_day0.snapshot,
			"last_climate_capacity_q16", cell1_day0.index) == Q16_ONE and
		_i64(cell1_day0.snapshot, "last_output", cell1_day0.index) == 0)
	_set_climate(runtime, 0.0, 0.0)
	var day1 := _run_simulation_day(runtime.ext, 1)
	var cell0_day1 := _building_group(runtime.ext, 0, type_id)
	var cell1_day1 := _building_group(runtime.ext, 1, type_id)
	_expect("day one freezes harsh climate only for the due phase-one cell",
		_conserved(day1) and _i64(cell0_day1.snapshot,
			"last_climate_capacity_q16", cell0_day1.index) == Q16_ONE and
		_i64(cell1_day1.snapshot,
			"last_climate_capacity_q16", cell1_day1.index) == int(climate.floor_q16))
	_set_climate(runtime, climate.temperature, climate.water)
	for day in range(2, 5):
		_run_simulation_day(runtime.ext, day)
	var cell1_before_due := _building_group(runtime.ext, 1, type_id)
	_expect("mid-cycle climate changes do not rewrite a non-due cell",
		_i64(cell1_before_due.snapshot,
			"last_climate_capacity_q16", cell1_before_due.index) == int(climate.floor_q16))
	var day5 := _run_simulation_day(runtime.ext, 5)
	var cell0_day5 := _building_group(runtime.ext, 0, type_id)
	var cell1_day5 := _building_group(runtime.ext, 1, type_id)
	_expect("next phase-zero settlement reads its new frozen climate",
		_conserved(day5) and _i64(cell0_day5.snapshot,
			"last_climate_capacity_q16", cell0_day5.index) == Q16_ONE and
		_i64(cell1_day5.snapshot,
			"last_climate_capacity_q16", cell1_day5.index) == int(climate.floor_q16))


func _test_worker_scalar_and_save(catalog: Dictionary) -> void:
	const CELL_COUNT := 48
	var scalar := _configured_runtime(catalog, CELL_COUNT, 4403, false)
	var worker := _configured_runtime(catalog, CELL_COUNT, 4403, true)
	_expect("scalar and worker climate runtimes configure",
		bool(scalar.get("ok", false)) and bool(worker.get("ok", false)))
	if not bool(scalar.get("ok", false)) or not bool(worker.get("ok", false)):
		return
	var climate := _climate_values(catalog, "intensive_farm")
	_set_climate(scalar, 0.0, 0.0)
	_set_climate(worker, 0.0, 0.0)
	var scalar_profile := _profile(false)
	scalar_profile.auto_slice_by_scale = false
	scalar_profile.cells_per_slice = CELL_COUNT
	scalar_profile.building_cells_per_slice = CELL_COUNT
	scalar_profile.worker_enabled = false
	scalar_profile.economy_investment_sparse_mode = "OFF"
	scalar_profile.economy_closing_audit_mode = "FULL"
	var worker_profile := scalar_profile.duplicate(true)
	worker_profile.worker_enabled = true
	worker_profile.worker_tasks_hint = 4
	worker_profile.economy_investment_sparse_mode = "ACTIVE"
	worker_profile.economy_closing_audit_mode = "INCREMENTAL"
	_expect("scalar climate economy configures", bool(scalar.ext.configure_economy(
		catalog, scalar_profile, CELL_COUNT, 4403).get("ok", false)))
	_expect("worker climate economy configures", bool(worker.ext.configure_economy(
		catalog, worker_profile, CELL_COUNT, 4403).get("ok", false)))
	_expect("scalar climate fixture bootstraps",
		_bootstrap_intensive_farms(scalar.ext, catalog, CELL_COUNT))
	_expect("worker climate fixture bootstraps",
		_bootstrap_intensive_farms(worker.ext, catalog, CELL_COUNT))
	var scalar_report := _run_simulation_day(scalar.ext, 0)
	var worker_report := _run_simulation_day(worker.ext, 0)
	_expect("climate worker path dispatches production work",
		int(worker_report.get("building_production_worker_tasks_max", 1)) > 1)
	_expect("climate worker and scalar hashes are exact",
		_conserved(scalar_report) and _conserved(worker_report) and
		int(scalar.ext.get_economy_state_hash()) == int(
			worker.ext.get_economy_state_hash()))
	var saved := _save_economy(worker.ext)
	_expect("PKEC v24 climate save streams at a committed boundary",
		bool(saved.get("ok", false)) and int(saved.get("schema", 0)) == 24)
	if not bool(saved.get("ok", false)):
		return
	var restored := _configured_runtime(catalog, CELL_COUNT, 4403, false)
	var restored_profile := _profile(false)
	_expect("PKEC v22 restore target configures", bool(restored.get("ok", false)) and
		bool(restored.ext.configure_economy(
			catalog, restored_profile, CELL_COUNT, 4403).get("ok", false)))
	var restore_result := _restore_economy(restored.ext, saved.chunks)
	_expect("PKEC v22 round-trip preserves climate state hash",
		bool(restore_result.get("ok", false)) and
		int(restored.ext.get_economy_state_hash()) == int(
			worker.ext.get_economy_state_hash()))
	var invalid := _configured_runtime(catalog, CELL_COUNT, 4403, false)
	invalid.ext.configure_economy(catalog, _profile(false), CELL_COUNT, 4403)
	var invalid_result := _restore_corrupted_building(invalid.ext, saved.chunks)
	if bool(invalid_result.get("ok", true)) or String(invalid_result.get(
			"reason", "")) != "save_building_record_invalid":
		print("  invalid climate restore result=", invalid_result)
	_expect("PKEC v22 rejects an illegal climate diagnostic without bootstrapping",
		not bool(invalid_result.get("ok", true)) and
		String(invalid_result.get("reason", "")) == "save_building_record_invalid" and
		String(invalid.ext.begin_economy_save(65536).get("reason", "")) ==
			"economy_not_bootstrapped")
	var truncated := _configured_runtime(catalog, CELL_COUNT, 4403, false)
	truncated.ext.configure_economy(catalog, _profile(false), CELL_COUNT, 4403)
	var truncated_result := _restore_truncated_building(truncated.ext, saved.chunks)
	_expect("PKEC v22 rejects a truncated climate building record without bootstrapping",
		not bool(truncated_result.get("ok", true)) and
		String(truncated_result.get("reason", "")) == "save_chunk_header_invalid" and
		String(truncated.ext.begin_economy_save(65536).get("reason", "")) ==
			"economy_not_bootstrapped")
	_expect("harsh worker fixture uses the compiled dryland floor",
		int(climate.floor_q16) == 16384)


func _catalog_with_consumed_test_resources(source: Dictionary) -> Dictionary:
	var catalog := source.duplicate(true)
	var type_id := (catalog.building_type_ids as PackedStringArray).find(
		"intensive_farm")
	var offsets: PackedInt32Array = catalog.building_resource_offsets
	var modes: PackedInt32Array = catalog.building_production_resource_modes.duplicate()
	for edge in range(int(offsets[type_id]), int(offsets[type_id + 1])):
		modes[edge] = 0
	catalog.building_production_resource_modes = modes
	return catalog


func _configured_runtime(catalog: Dictionary, cell_count: int,
		seed: int, worker_enabled: bool) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(cell_count)
	var half := _filled_f32(cell_count, 0.5)
	var slots := {}
	for slot_name in [&"cell_temp", &"cell_temp_30d", &"cell_moisture",
			&"cell_plant_available_water", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, half)
		slots[String(slot_name)] = sid
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(cell_count)
	zeros_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zeros_u8)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for i in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(
			StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(
			StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, _filled_f32(cell_count, 1000000000.0))
		ext.write_f32_range(extra_sid, 0, _filled_f32(cell_count, 0.0))
	var country_ok := CountryTestHelper.configure_all_technologies(
		ext, catalog, cell_count, seed)
	return {"ok": country_ok, "ext": ext, "slots": slots,
		"worker_enabled": worker_enabled}


func _bootstrap_intensive_farms(ext: Object, catalog: Dictionary,
		cell_count: int) -> bool:
	var signatures: PackedStringArray = catalog.signature_keys
	var fixture_signatures := PackedInt32Array([
		signatures.find("landlord|default"),
		signatures.find("agricultural_worker|default"),
		signatures.find("manager|default"),
		signatures.find("merchant|default"),
		signatures.find("unemployed|default"),
	])
	if fixture_signatures.has(-1):
		return false
	var cells := PackedInt32Array()
	var cohort_signatures := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	var building_cells := PackedInt32Array()
	var building_types := PackedInt32Array()
	var building_owners := PackedInt32Array()
	var building_counts := PackedInt64Array()
	var type_id := (catalog.building_type_ids as PackedStringArray).find(
		"intensive_farm")
	for cell in range(cell_count):
		for i in range(fixture_signatures.size()):
			cells.push_back(cell)
			cohort_signatures.push_back(fixture_signatures[i])
			populations.push_back([1, 28, 2, 2, 1000][i])
			funds.push_back([1000000000, 10000000, 10000000,
				1000000000, 10000000][i])
		building_cells.push_back(cell)
		building_types.push_back(type_id)
		building_owners.push_back(fixture_signatures[0])
		building_counts.push_back(1)
	var goods: PackedStringArray = catalog.good_ids
	var stock := PackedInt64Array()
	stock.resize(cell_count * goods.size())
	stock.fill(1000000000)
	var grain := goods.find("grain")
	var vegetables := goods.find("vegetables")
	for cell in range(cell_count):
		stock[cell * goods.size() + grain] = 0
		stock[cell * goods.size() + vegetables] = 0
	var prices := PackedInt32Array()
	prices.resize(cell_count * goods.size())
	var defaults: PackedInt32Array = catalog.good_default_price
	for cell in range(cell_count):
		for good in range(goods.size()):
			prices[cell * goods.size() + good] = defaults[good]
	return bool(ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": cohort_signatures,
		"population": populations,
		"funds": funds,
	}, {
		"stock": stock,
		"price": prices,
		"building_cells": building_cells,
		"building_type_ids": building_types,
		"building_owner_signature_ids": building_owners,
		"building_counts": building_counts,
	}).get("ok", false))


func _profile(worker_enabled: bool) -> Dictionary:
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 5
	profile.trade_runtime_mode = "OFF"
	profile.starvation_death_rate_q32 = 0
	profile.resource_safe_harvest_q16 = 0
	profile.worker_enabled = worker_enabled
	return profile


func _climate_values(catalog: Dictionary, building_id: String) -> Dictionary:
	var type_id := (catalog.building_type_ids as PackedStringArray).find(building_id)
	var indices: PackedInt32Array = catalog.building_production_climate_profile_indices
	var climate_id := int(indices[type_id])
	return {
		"temperature": float((catalog.production_climate_temperature_opt_q16 as
			PackedInt32Array)[climate_id]) / Q16_ONE,
		"water": float((catalog.production_climate_water_opt_q16 as
			PackedInt32Array)[climate_id]) / Q16_ONE,
		"floor_q16": int((catalog.production_climate_floor_q16 as
			PackedInt32Array)[climate_id]),
	}


func _set_climate(runtime: Dictionary, temperature: float, water: float) -> void:
	var ext: Object = runtime.ext
	var slots: Dictionary = runtime.slots
	var count := int(ext.entity_count())
	ext.write_f32_range(int(slots.cell_temp_30d), 0, _filled_f32(count, temperature))
	ext.write_f32_range(int(slots.cell_plant_available_water), 0,
		_filled_f32(count, water))


func _run_simulation_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(512):
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice,
		})
		if bool(report.get("done", false)):
			return report
	return report


func _building_group(ext: Object, cell: int, type_id: int) -> Dictionary:
	var snapshot: Dictionary = ext.get_building_cell_snapshot(cell)
	return {"snapshot": snapshot,
		"index": (snapshot.get("group_type_ids", PackedInt32Array()) as
			PackedInt32Array).find(type_id)}


func _save_economy(ext: Object) -> Dictionary:
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


func _restore_economy(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var fed: Dictionary = ext.feed_economy_restore_chunk(value as PackedByteArray)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()


func _restore_corrupted_building(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var chunk := (value as PackedByteArray).duplicate()
		if chunk.size() >= 60 and chunk.decode_u16(6) == 5:
			# Building payload offset 36 is last_temperature_fit_q16 in PKEC v22.
			chunk.encode_s64(16 + 36, Q16_ONE + 1)
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()


func _restore_truncated_building(ext: Object, chunks: Array) -> Dictionary:
	var begin: Dictionary = ext.begin_economy_restore()
	if not bool(begin.get("ok", false)):
		return begin
	for value in chunks:
		var chunk := (value as PackedByteArray).duplicate()
		if chunk.size() > 16 and chunk.decode_u16(6) == 5:
			chunk.resize(chunk.size() - 1)
		var fed: Dictionary = ext.feed_economy_restore_chunk(chunk)
		if not bool(fed.get("ok", false)):
			return fed
	return ext.end_economy_restore()


func _filled_f32(count: int, value: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	out.fill(value)
	return out


func _i64(snapshot: Dictionary, column: String, index: int) -> int:
	if index < 0:
		return -1
	var values: PackedInt64Array = snapshot.get(column, PackedInt64Array())
	return int(values[index]) if index < values.size() else -1


func _conserved(report: Dictionary) -> bool:
	return (bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
