extends "res://tests/runtime/fiscal_return_intent_test.gd"


func _init() -> void:
	_run()
	print("=== military deferred cash conservation: %d failures ===" % failures)
	quit(0 if failures == 0 else 1)


func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.economy_cadence_force_market_days = 1
	profile.economy_cadence_force_plan_days = 10
	profile.economy_cadence_force_investment_days = 10
	var ext: Object = _new_runtime(compiled, catalog, profile, 104172, true)
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	_expect("disable research spending", _disable_research(ext, handle))
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	_expect("fund treasury", _transfer_from_cohort(ext, population.handles[0], 500000, 0, 910001))
	_finish_day(ext, 0)
	var military: Dictionary = MilitaryCatalogCompiler.compile(compiled,
		TechnologyCatalog.compile_native_catalog(), MilitaryCatalogCompiler.CATALOG_PATH)
	_expect("military catalog compiles", bool(military.get("ok", false)))
	_expect("military configures", bool(ext.configure_military(military, 104172).get("ok", false)))
	var terrain := {"cell_count": CELL_COUNT, "width": CELL_COUNT, "height": 1}
	var neighbors := PackedInt32Array()
	neighbors.resize(CELL_COUNT * 6)
	neighbors.fill(-1)
	terrain.neighbors = neighbors
	for key in ["landform", "vegetation", "cover", "is_water", "has_river", "settlement_tier"]:
		var values := PackedByteArray()
		values.resize(CELL_COUNT)
		values.fill(0)
		terrain[key] = values
	_expect("military terrain binds", bool(ext.set_military_terrain(terrain).get("ok", false)))
	# Restore the exact D+1 bridge condition without relying on a particular
	# building catalog to emit upkeep. PKMI v4 stores pending bridge rows.
	var bytes: PackedByteArray = ext.encode_military_state()
	var tail := 12 + int(bytes.decode_u32(8))
	_expect("PKMI v4 empty bridge fixture", bytes.decode_u32(4) == 4
		and bytes.decode_u32(tail + 32) == 0 and bytes.size() == tail + 36)
	bytes.encode_u64(tail, 1) # Sequence cursor includes the restored request.
	bytes.encode_u32(tail + 32, 1)
	var row := PackedByteArray()
	row.resize(92)
	row.fill(0)
	row.encode_u32(0, 9) # MILITARY_INTENT_SPEND_CASH
	row.encode_u32(4, 3) # Deferred cash authority.
	row.encode_u64(24, handle)
	row.encode_u64(40, 1000)
	row.encode_u64(48, 1) # sequence
	row.encode_u64(64, 1) # effective_day
	row.encode_u32(72, 1) # receipt_pending
	bytes.append_array(row)
	_expect("pending upkeep restores", bool(ext.restore_military_state(bytes).get("ok", false)))
	_expect("pending upkeep roundtrip exact", ext.encode_military_state() == bytes)
	var cash := int(ext.get_country_treasury_snapshot(handle).cash)
	var step: Dictionary = ext.run_military_daily({"day_index": 1})
	_expect("deferred upkeep settles once", bool(step.get("ok", false))
		and int(step.get("receipts_folded", 0)) == 1)
	_expect("reserve/collect leaves treasury unchanged",
		int(ext.get_country_treasury_snapshot(handle).cash) == cash)
	_expect("same military day cannot replay upkeep",
		bool(ext.run_military_daily({"day_index": 1}).get("skipped", false)))
	for day in range(1, 10):
		_finish_day(ext, day)
		var report: Dictionary = ext.get_economy_report()
		_expect("no phantom upkeep burn on day %d" % day,
			int(report.get("explicit_money_burn", -1)) == 0)
		if bool(report.get("fatal", false)):
			print("DEFERRED_CASH_FAULT reason=%s money_error=%d burn=%d" % [
				report.get("fatal_reason", ""), report.get("money_error", 0),
				report.get("explicit_money_burn", 0)])
			return
	# Removing the false receipt burn must preserve real explicit cash sinks.
	population = ext.get_population_cell_snapshot(0)
	_expect("real cohort burn queues", bool(ext.submit_economy_commands({
		"opcodes": PackedInt32Array([3]),
		"effective_days": PackedInt64Array([10]),
		"sequences": PackedInt64Array([910002]),
		"target_handles": PackedInt64Array([population.handles[0]]),
		"i32_0": PackedInt32Array([0]), "i32_1": PackedInt32Array([0]),
		"i64_0": PackedInt64Array([1000]), "i64_1": PackedInt64Array([0]),
	}).get("ok", false)))
	_finish_day(ext, 10)
	_expect("real cohort burn remains audited",
		int(ext.get_economy_report().get("explicit_money_burn", 0)) == 1000)
