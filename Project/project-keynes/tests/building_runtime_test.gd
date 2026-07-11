extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")

var failures := 0

func _init() -> void:
	_run()
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	print("=== native building runtime test ===")
	var compiled := EconomyCatalogScript.compile_native_catalog()
	_expect("building catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		print(compiled)
		return
	var building_ids: PackedStringArray = compiled.building_type_ids
	_expect("coal mine type exists", building_ids.has("coal_mine"))
	var ext := _new_ext(compiled)
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_cycle_days = 1
	profile.market_runtime_mode = "ACTIVE"
	_expect("building runtime configures", bool(ext.configure_economy(catalog, profile, 1, 77).get("ok", false)))
	var landlord_sig: int = (compiled.signature_keys as PackedStringArray).find("landlord|default")
	var worker_sig: int = (compiled.signature_keys as PackedStringArray).find("worker|default")
	var goods: PackedStringArray = compiled.good_ids
	var stock := PackedInt64Array()
	stock.resize(goods.size())
	stock[goods.find("cloth")] = 100000
	var boot: Dictionary = ext.bootstrap_economy({
		"cell_indices": PackedInt32Array([0, 0]),
		"signature_ids": PackedInt32Array([landlord_sig, worker_sig]),
		"population": PackedInt64Array([5, 100]),
		"funds": PackedInt64Array([10000000, 1000000]),
	}, {"stock": stock})
	_expect("building population bootstraps", bool(boot.get("ok", false)))
	var pop: Dictionary = ext.get_population_cell_snapshot(0)
	var owner_handle := _handle_for_profession(pop, landlord_sig)
	_expect("landlord owner handle exists", owner_handle != 0)
	var mine_id := building_ids.find("coal_mine")
	var submit: Dictionary = ext.submit_economy_commands({
		"opcodes": PackedInt32Array([10]),
		"effective_days": PackedInt64Array([0]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([owner_handle]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([mine_id]),
		"i64_0": PackedInt64Array([1]),
		"i64_1": PackedInt64Array([0]),
	})
	_expect("build command accepted", bool(submit.get("ok", false)))
	var day0 := _run_day(ext, 0)
	_expect("construction cycle commits", bool(day0.get("done", false)) and not bool(day0.get("fatal", false)))
	var buildings: Dictionary = ext.get_building_cell_snapshot(0)
	_expect("mine completes at cycle boundary", int((buildings.building_counts_by_type as PackedInt64Array)[mine_id]) == 1)
	var day1 := _run_day(ext, 1)
	_expect("production cycle conserves population", int(day1.get("population_error", 1)) == 0)
	_expect("production cycle conserves money", int(day1.get("money_error", 1)) == 0)
	_expect("production cycle conserves market goods", int(day1.get("goods_error", 1)) == 0)
	buildings = ext.get_building_cell_snapshot(0)
	_expect("owner job filled", int((buildings.filled_owner as PackedInt64Array)[0]) == 1)
	_expect("employee jobs filled", int((buildings.employee_filled as PackedInt64Array)[0]) == 20)
	_expect("mine produces output", int((buildings.last_output as PackedInt64Array)[0]) > 0)
	_expect("merchant buys at least part of output", int((buildings.last_sold as PackedInt64Array)[0]) > 0)
	pop = ext.get_population_cell_snapshot(0)
	var worker_row := _row_for_signature(pop, worker_sig)
	var landlord_row := _row_for_signature(pop, landlord_sig)
	_expect("worker cohort has real employee count", worker_row >= 0 and
		int((pop.employee_employed_by_cohort as PackedInt64Array)[worker_row]) > 0)
	var expected_wages := 20 * 5000
	_expect("fixed wages reach the worker cohort", worker_row >= 0 and
		int((pop.epoch_income_by_cohort as PackedInt64Array)[worker_row]) == expected_wages)
	_expect("owner pays the same fixed payroll", landlord_row >= 0 and
		int((pop.epoch_expense_by_cohort as PackedInt64Array)[landlord_row]) == expected_wages)
	_expect("wage report is exact and fully funded",
		int(day1.get("building_wages_paid", -1)) == expected_wages and
		int(day1.get("building_wages_unpaid", -1)) == 0)
	var market: Dictionary = ext.get_market_cell_snapshot(0)
	_expect("sold coal enters local stock", _good_value(market, "stock", "coal") > 0)
	var resource_extra_slots: PackedStringArray = compiled.building_resource_extra_slots
	var coal_resource: int = (compiled.building_resource_ids as PackedStringArray).find("coal")
	var extra_sid: int = ext.component_id(StringName(resource_extra_slots[coal_resource]))
	var extra_values: PackedFloat32Array = ext.snapshot_f32(extra_sid)
	_expect("resource extraction publishes negative extra delta", extra_values.size() == 1 and extra_values[0] < 0.0)
	_expect("building snapshot stays committed", bool(buildings.get("committed", false)))
	var chunks: Array[PackedByteArray] = []
	_expect("building save begins", bool(ext.begin_economy_save(65536).get("ok", false)))
	while true:
		var chunk: PackedByteArray = ext.read_economy_save_chunk(65536)
		if chunk.is_empty(): break
		chunks.append(chunk)
	_expect("building save completes", bool(ext.end_economy_save().get("ok", false)))
	var restored := _new_ext(compiled)
	_expect("building restore target configures", bool(restored.configure_economy(
		catalog, profile, 1, 77).get("ok", false)))
	_expect("building restore begins", bool(restored.begin_economy_restore().get("ok", false)))
	for chunk in chunks:
		_expect("building restore chunk accepted", bool(restored.feed_economy_restore_chunk(chunk).get("ok", false)))
	_expect("building restore completes", bool(restored.end_economy_restore().get("ok", false)))
	_expect("building save hash round-trips", restored.get_economy_state_hash() == ext.get_economy_state_hash())
	var restored_buildings: Dictionary = restored.get_building_cell_snapshot(0)
	_expect("restored mine and jobs remain committed",
		int((restored_buildings.building_counts_by_type as PackedInt64Array)[mine_id]) == 1 and
		int((restored_buildings.employee_filled as PackedInt64Array)[0]) == 20)
	print("=== native building runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var scalar := PackedFloat32Array([0.5])
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover", &"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var zero_u8 := PackedByteArray([0])
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation", &"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, zero_u8)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	var resource_ids: PackedStringArray = catalog.building_resource_ids
	for i in range(resource_ids.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		var reserve := PackedFloat32Array([1000.0 if resource_ids[i] == "coal" else 0.0])
		ext.write_f32_range(reserve_sid, 0, reserve)
		ext.write_f32_range(extra_sid, 0, PackedFloat32Array([0.0]))
	return ext

func _run_day(ext: Object, day: int) -> Dictionary:
	var report := {}
	for slice in range(256):
		report = ext.run_economy_slice({"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)):
			return report
	return report

func _row_for_signature(snapshot: Dictionary, signature: int) -> int:
	return (snapshot.signature_ids as PackedInt32Array).find(signature)

func _handle_for_profession(snapshot: Dictionary, signature: int) -> int:
	var row := _row_for_signature(snapshot, signature)
	return int((snapshot.handles as PackedInt64Array)[row]) if row >= 0 else 0

func _good_value(snapshot: Dictionary, column: String, good_id: String) -> int:
	var index := (snapshot.good_ids as PackedStringArray).find(good_id)
	return int((snapshot[column] as PackedInt64Array)[index]) if index >= 0 else 0
