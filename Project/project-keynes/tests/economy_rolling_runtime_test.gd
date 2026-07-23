extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryTestHelper = preload("res://tests/country_test_helper.gd")

const CELL_COUNT := 10
const PHASE_COUNT := 5
var failures := 0

func _init() -> void:
	_run()
	print("=== economy rolling runtime %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load(
		"res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	var runtime := _new_runtime(compiled, catalog, profile, 92015)
	if runtime == null:
		return
	_expect("rolling inspector trace target registers",
		bool(runtime.set_economy_inspector_trace_cell(1).get("ok", false)))
	var traced_before: Dictionary = runtime.get_population_cell_snapshot(1)
	var traced_handles: PackedInt64Array = traced_before.get("handles", PackedInt64Array())
	_expect("rolling inspector target has a cohort", not traced_handles.is_empty())
	if traced_handles.is_empty():
		return
	_expect("rolling inspector transfer queues", bool(runtime.submit_economy_commands({
		"opcodes": PackedInt32Array([2]),
		"effective_days": PackedInt64Array([1]),
		"sequences": PackedInt64Array([1]),
		"target_handles": PackedInt64Array([traced_handles[0]]),
		"i32_0": PackedInt32Array([0]),
		"i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([123456]),
		"i64_1": PackedInt64Array([0]),
	}).get("ok", false)))
	var traced_epoch := -1
	var traced_sources := PackedInt32Array()
	var traced_income := PackedInt64Array()
	var traced_expense := PackedInt64Array()
	for day in range(8):
		_validate_day(runtime, day)
		var traced: Dictionary = runtime.get_population_cell_snapshot(1)
		if day == 0:
			_expect("non-due trace remains pending before first cell settlement",
				not bool(traced.get("settlement_detail_available", false)) and
				bool(traced.get("settlement_detail_pending", false)))
		elif day == 1:
			traced_epoch = int(traced.get("settlement_epoch_id", -1))
			traced_sources = traced.get(
				"settlement_cashflow_source_indices", PackedInt32Array()).duplicate()
			traced_income = traced.get(
				"settlement_cashflow_income", PackedInt64Array()).duplicate()
			traced_expense = traced.get(
				"settlement_cashflow_expense", PackedInt64Array()).duplicate()
			_expect("due trace exposes the classified transfer",
				bool(traced.get("settlement_detail_available", false)) and
				_cashflow_has_source(traced, "transfer", true) and
				not _cashflow_has_source(traced, "other", true))
		elif day < 6:
			_expect("non-due day %d preserves the last classified trace" % day,
				int(traced.get("settlement_epoch_id", -1)) == traced_epoch and
				traced.get("settlement_cashflow_source_indices", PackedInt32Array()) == traced_sources and
				traced.get("settlement_cashflow_income", PackedInt64Array()) == traced_income and
				traced.get("settlement_cashflow_expense", PackedInt64Array()) == traced_expense and
				not _cashflow_has_source(traced, "other", true) and
				not _cashflow_has_source(traced, "other", false))
	var saved := _save(runtime)
	_expect("PKEC v18 saves at a daily committed boundary",
		bool(saved.get("ok", false)) and int(saved.get("schema", 0)) == 18)
	var restored := _new_ext(compiled)
	_expect("restore country matches", CountryTestHelper.configure_all_technologies(
		restored, catalog, CELL_COUNT, 92015))
	_expect("restore economy configures", bool(restored.configure_economy(
		catalog, profile, CELL_COUNT, 92015).get("ok", false)))
	var restore_result := _restore(restored, saved.get("chunks", []))
	_expect("rolling save restores exact hash", bool(restore_result.get("ok", false)) and
		int(restored.get_economy_state_hash()) == int(runtime.get_economy_state_hash()))
	for day in range(8, 15):
		_validate_day(runtime, day)
		_validate_day(restored, day)
		_expect("day %d restored replay hash" % day,
			int(restored.get_economy_state_hash()) == int(runtime.get_economy_state_hash()))

func _new_runtime(compiled: Dictionary, catalog: Dictionary,
		profile: Dictionary, seed: int) -> Object:
	var ext := _new_ext(compiled)
	_expect("country configures", CountryTestHelper.configure_all_technologies(
		ext, catalog, CELL_COUNT, seed))
	_expect("economy configures", bool(ext.configure_economy(
		catalog, profile, CELL_COUNT, seed).get("ok", false)))
	var merchant := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	var cells := PackedInt32Array()
	var signatures := PackedInt32Array()
	var population := PackedInt64Array()
	var funds := PackedInt64Array()
	cells.resize(CELL_COUNT)
	signatures.resize(CELL_COUNT)
	population.resize(CELL_COUNT)
	funds.resize(CELL_COUNT)
	for cell in range(CELL_COUNT):
		cells[cell] = cell
		signatures[cell] = merchant
		population[cell] = 10
		funds[cell] = 1000000
	var goods: int = (compiled.good_ids as PackedStringArray).size()
	var stock := PackedInt64Array()
	var prices := PackedInt32Array()
	stock.resize(CELL_COUNT * goods)
	stock.fill(0)
	prices.resize(CELL_COUNT * goods)
	for cell in range(CELL_COUNT):
		for good in range(goods):
			prices[cell * goods + good] = int(
				(compiled.good_default_price as PackedInt32Array)[good])
	_expect("ten local markets bootstrap", bool(ext.bootstrap_economy({
		"cell_indices": cells,
		"signature_ids": signatures,
		"population": population,
		"funds": funds,
	}, {"stock": stock, "price": prices}).get("ok", false)))
	return ext

func _validate_day(ext: Object, day: int) -> void:
	var report: Dictionary = {}
	var slices := 0
	var saw_investment_range := false
	while slices < 64:
		report = ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slices,
		})
		if String(report.get("stage", "")) == "building_commit" and \
				int(report.get("building_commit_phase", -1)) >= 1:
			saw_investment_range = true
		slices += 1
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			break
	_expect("day %d uses bounded continuation slices" % day,
		slices > 1 and slices < 64)
	_expect("day %d exposes bounded investment continuation" % day,
		saw_investment_range)
	_expect("day %d commits one rolling phase" % day,
		bool(report.get("done", false)) and not bool(report.get("fatal", false)) and
		int(report.get("settlement_phase", -1)) == day % PHASE_COUNT and
		int(report.get("due_cells", -1)) == CELL_COUNT / PHASE_COUNT and
		int(report.get("processed_due_cells", -1)) == CELL_COUNT / PHASE_COUNT and
		int(report.get("deferred_cells", -1)) == 0)
	_expect("day %d conserves all ledgers" % day,
		int(report.get("population_error", 1)) == 0 and
		int(report.get("money_error", 1)) == 0 and
		int(report.get("goods_error", 1)) == 0 and
		int(report.get("max_state_age_days", 99)) <= 4)
	for cell in range(CELL_COUNT):
		var snapshot: Dictionary = ext.get_market_cell_snapshot(cell)
		var phase := cell % PHASE_COUNT
		var expected_day := phase - PHASE_COUNT
		if day >= phase:
			expected_day = day - ((day - phase) % PHASE_COUNT)
		var expected_generation := 0 if day < phase else (day - phase) / PHASE_COUNT + 1
		_expect("day %d cell %d state date" % [day, cell],
			bool(snapshot.get("ok", false)) and
			int(snapshot.get("state_day", 999)) == expected_day and
			int(snapshot.get("age_days", 99)) <= 4 and
			int(snapshot.get("settlement_generation", -1)) == expected_generation)

func _new_ext(catalog: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(CELL_COUNT)
	var scalar := PackedFloat32Array()
	scalar.resize(CELL_COUNT)
	scalar.fill(0.5)
	for slot_name in [&"cell_temp", &"cell_moisture", &"cell_snow_cover",
			&"cell_weather_intensity", &"cell_elevation"]:
		var sid: int = ext.register_component(slot_name, 0, 1, false)
		ext.write_f32_range(sid, 0, scalar)
	var terrain := PackedByteArray()
	terrain.resize(CELL_COUNT)
	terrain.fill(2)
	var zeros_u8 := PackedByteArray()
	zeros_u8.resize(CELL_COUNT)
	zeros_u8.fill(0)
	for slot_name in [&"cell_terrain", &"cell_landform", &"cell_vegetation",
			&"cell_is_water", &"cell_has_river"]:
		var sid: int = ext.register_component(slot_name, 2, 1, false)
		ext.write_u8_range(sid, 0, terrain if slot_name == &"cell_terrain" else zeros_u8)
	var zeros := PackedFloat32Array()
	zeros.resize(CELL_COUNT)
	zeros.fill(0.0)
	var reserve_slots: PackedStringArray = catalog.building_resource_reserve_slots
	var extra_slots: PackedStringArray = catalog.building_resource_extra_slots
	for i in range(reserve_slots.size()):
		var reserve_sid: int = ext.register_component(StringName(reserve_slots[i]), 0, 1, false)
		var extra_sid: int = ext.register_component(StringName(extra_slots[i]), 0, 1, false)
		ext.write_f32_range(reserve_sid, 0, zeros)
		ext.write_f32_range(extra_sid, 0, zeros)
	return ext


func _cashflow_has_source(snapshot: Dictionary, stable_id: String, income: bool) -> bool:
	var source_ids: PackedStringArray = snapshot.get(
		"settlement_cashflow_source_stable_ids", PackedStringArray())
	var source_idx := source_ids.find(stable_id)
	if source_idx < 0:
		return false
	var sources: PackedInt32Array = snapshot.get(
		"settlement_cashflow_source_indices", PackedInt32Array())
	var values: PackedInt64Array = snapshot.get(
		"settlement_cashflow_income" if income else "settlement_cashflow_expense",
		PackedInt64Array())
	for i in range(mini(sources.size(), values.size())):
		if int(sources[i]) == source_idx and int(values[i]) > 0:
			return true
	return false

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
