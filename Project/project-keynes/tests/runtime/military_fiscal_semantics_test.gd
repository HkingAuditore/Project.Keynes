extends "res://tests/runtime/fiscal_return_intent_test.gd"

# Opt-in diagnosis of the synchronous military pay route, not a golden fixture.
# Conservation is asserted normally: a real defect must produce a failing exit.
const ARMY := 7001001
var trace: Array = []

func _init() -> void:
	_run()
	print("MILITARY_FISCAL_TRACE=" + JSON.stringify(trace))
	print("military fiscal semantics: %d failures" % failures)
	quit(0 if failures == 0 else 1)

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
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
	_expect("fund treasury from cohort", _transfer_from_cohort(ext, population.handles[0], 500000, 0, 910001))
	_finish_day(ext, 0)
	var cash := int(ext.get_country_treasury_snapshot(handle).cash)
	_record(ext, handle, "opening")
	var reserved := _transaction(ext, handle, "reserve", 12345, 910002, true)
	_expect("reserve debits treasury", int(ext.get_country_treasury_snapshot(handle).cash) == cash - reserved)
	var collected := _transaction(ext, handle, "collect", reserved, 910003, true)
	_expect("collect credits treasury back", collected == reserved and int(ext.get_country_treasury_snapshot(handle).cash) == cash)
	_transaction(ext, handle, "reserve", 777, 910004, false)
	_expect("peer cancellation leaves cash unchanged", int(ext.get_country_treasury_snapshot(handle).cash) == cash)
	_transaction(ext, 0, "reserve", 777, 910005, true)
	_expect("invalid handle leaves cash unchanged", int(ext.get_country_treasury_snapshot(handle).cash) == cash)
	var all_cash := _transaction(ext, handle, "reserve", cash, 910006, true)
	_expect("empty treasury rejects reserve", _transaction(ext, handle, "reserve", 1, 910007, true) == 0)
	_transaction(ext, handle, "return", all_cash, 910008, true)
	_expect("return restores failed-reserve fixture", int(ext.get_country_treasury_snapshot(handle).cash) == cash)
	# Legacy ingress rejects army opcodes before they reach the native branch.
	# Record that boundary; the opt-in native probe below calls production C++.
	var signature := (compiled.signature_keys as PackedStringArray).find("merchant|default")
	_expect("legacy ingress rejects army opcode 30", not _army_command(ext, 30, signature, 1, 0, 1, 910010))
	_expect("legacy ingress rejects army opcode 34", not _army_command(ext, 34, 0, 12345, handle, 2, 910011))
	var probe_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--native-probe="):
			probe_path = arg.trim_prefix("--native-probe=")
	if probe_path.is_empty():
		print("[SKIP] optional native military probe was not supplied")
		return
	_expect("native probe path supplied", true)
	var loaded := GDExtensionManager.load_extension(probe_path)
	_expect("test-only native probe loads", loaded == GDExtensionManager.LOAD_STATUS_OK)
	if loaded != GDExtensionManager.LOAD_STATUS_OK:
		return
	var probe: Object = ClassDB.instantiate("MilitaryFiscalProbe")
	var packet := {
		"country_ids": PackedStringArray(["country.military_probe"]),
		"country_names": PackedStringArray(["Military Probe"]),
		"country_cash": PackedInt64Array([500000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
	}
	var pop := {"cell_indices": PackedInt32Array([0]), "signature_ids": PackedInt32Array([signature]),
		"population": PackedInt64Array([10]), "funds": PackedInt64Array([1000000])}
	var stock := PackedInt64Array()
	stock.resize(compiled.good_ids.size())
	stock.fill(0)
	var native: Dictionary = probe.run(catalog, profile, packet, pop,
		{"stock": stock, "price": compiled.good_default_price}, signature,
		OS.get_environment("PK_MILITARY_CHECKPOINT") == "1")
	trace.append({"stage": "native_production_methods", "result": native})
	_expect("native nonzero army pay executes", bool(native.get("ok", false)))
	_expect("native army pay conserves cash", native.has("money_delta") and int(native.money_delta) == 0)
	var continued: Array = native.get("continuation", [])
	_expect("eight nonzero post-save payments recorded", continued.size() == 8)
	for row in continued:
		_expect("post-save military payment conserved " + str(row.day), bool(row.conserved))
	var checks: Dictionary = native.get("checks", {})
	_expect("native edge cases recorded", checks.size() == 8)
	for label in checks:
		_expect("native " + str(label), bool(checks[label]))
	var deferred: Dictionary = native.get("deferred_checks", {})
	_expect("six deferred helper boundaries recorded", deferred.size() == 6)
	for label in deferred:
		_expect("deferred helper observed neutral cash: " + str(label), bool(deferred[label]))
	_expect("native Country transactions conserved", int(native.get("country_report", {}).get("economy_asset_ledger_failures", -1)) == 0)

	_deferred_bridge(ext, compiled, handle)

func _deferred_bridge(ext: Object, compiled: Dictionary, handle: int) -> void:
	var military: Dictionary = MilitaryCatalogCompiler.compile(compiled,
		TechnologyCatalog.compile_native_catalog(), MilitaryCatalogCompiler.CATALOG_PATH)
	_expect("deferred catalog compiles", bool(military.get("ok", false)))
	if not bool(military.get("ok", false)): return
	# Test-only authored building: deterministic nonzero material and upkeep.
	military.state_buildings = [{"id": "probe_fort", "economy_building_id": -1,
		"role": 1, "tier": 0, "unlock_bit": -1, "capacity": 0,
		"fort_bonus": 0.0, "training_speed": 1.0, "upkeep": 1.0,
		"build_days": 1, "material_goods": PackedInt32Array([0]),
		"material_qty": PackedInt64Array([1000])}]
	_expect("deferred military configures", bool(ext.configure_military(military, 104172).get("ok", false)))
	var terrain := {"cell_count": 1, "width": 1, "height": 1,
		"neighbors": PackedInt32Array([-1, -1, -1, -1, -1, -1])}
	for key in ["landform", "vegetation", "cover", "is_water", "has_river", "settlement_tier"]:
		terrain[key] = PackedByteArray([0])
	_expect("deferred terrain binds", bool(ext.set_military_terrain(terrain).get("ok", false)))
	_expect("deferred state build accepted", bool(ext.submit_military_commands([
		{"op": "state.build", "country": handle, "cell": 0, "unit_to": 0}]).get("ok", false)))
	var opening := int(ext.get_country_treasury_snapshot(handle).cash)
	var cohort_open := _cohort_total(ext)
	var emitted_material := false
	var emitted_upkeep := false
	for day in range(0, 14):
		var report: Dictionary = ext.run_military_daily({"day_index": day})
		var fiscal: Dictionary = ext.get_country_report()
		var snapshot: Dictionary = ext.get_military_country_snapshot(handle)
		trace.append({"stage": "actual_deferred_bridge", "day": day, "report": report,
			"country_cash": ext.get_country_treasury_snapshot(handle).cash,
			"cohort_cash": _cohort_total(ext), "escrow": fiscal.get("economy_asset_transactions", {}).get("reserved_cash", -1),
			"country_transactions": fiscal.get("economy_asset_transactions", {}),
			"military": snapshot})
		_expect("deferred day executes " + str(day), bool(report.get("ok", false)))
		_expect("deferred bridge cash remains neutral " + str(day), int(ext.get_country_treasury_snapshot(handle).cash) == opening)
		_expect("deferred cohort/escrow unchanged " + str(day), _cohort_total(ext) == cohort_open and int(fiscal.get("economy_asset_transactions", {}).get("reserved_cash", -1)) == 0)
		if day == 0: emitted_material = int(report.get("intents_submitted", 0)) > 0
		if day == 5: emitted_upkeep = int(snapshot.get("spend_upkeep_30", 0)) > 0
		if day == 5 and OS.get_environment("PK_MILITARY_CHECKPOINT") == "1":
			var bytes: PackedByteArray = ext.encode_military_state()
			_expect("D+1 pending upkeep checkpoint restores", bool(ext.restore_military_state(bytes).get("ok", false)))
			_expect("PKMI roundtrip exact", bytes == ext.encode_military_state())
	_expect("nonzero material notification emitted", emitted_material)
	_expect("nonzero upkeep emitted", emitted_upkeep)

func _army_command(ext: Object, opcode: int, signature: int, amount: int,
		country: int, day: int, sequence: int) -> bool:
	return bool(ext.submit_economy_commands({
		"opcodes": PackedInt32Array([opcode]), "effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]), "target_handles": PackedInt64Array([ARMY]),
		"i32_0": PackedInt32Array([0]), "i32_1": PackedInt32Array([signature]),
		"i64_0": PackedInt64Array([amount]), "i64_1": PackedInt64Array([country]),
	}).get("ok", false))

func _transaction(ext: Object, handle: int, kind: String, amount: int,
		request_id: int, prepared: bool) -> int:
	var tx: Dictionary = ext.call("begin_country_economy_fiscal_" + kind,
		handle, amount, 0, 1, request_id)
	_record(ext, handle, kind + ":begin", tx)
	if not prepared:
		_expect("cancel case reserves nonzero cash", bool(tx.get("ok", false)) and int(tx.get("prepared_quantity", 0)) == amount)
	if not bool(tx.get("ok", false)):
		return 0
	var id := int(tx.transaction_id)
	var session := int(tx.session_epoch)
	var generation := int(tx.country_generation)
	var ack: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		id, session, generation, 1, prepared, "" if prepared else "test_cancel")
	_record(ext, handle, kind + ":prepared" if prepared else kind + ":cancelled", ack)
	if not prepared:
		_expect("cancel releases reservation without commit", bool(ack.get("ok", false)) and ack.get("status_name", "") == "rejected" and int(ack.get("reserved_cash", -1)) == 0 and int(ack.get("committed_cash", -1)) == 0 and bool(ack.get("conservation_ok", false)))
		return 0
	var commit: Dictionary = ext.commit_country_economy_asset_transaction(id)
	_record(ext, handle, kind + ":commit", commit)
	var applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		id, session, generation, 1, true, "")
	_record(ext, handle, kind + ":applied", applied)
	return int(commit.get("committed_quantity", 0))

func _record(ext: Object, handle: int, label: String, receipt: Dictionary = {}) -> void:
	var report: Dictionary = ext.get_economy_report()
	var ledger := {}
	for key in ["money_open", "money_close", "money_expected", "money_error", "explicit_money_mint",
			"explicit_money_burn", "opening_cohort_funds", "closing_cohort_funds", "opening_country_cash",
			"closing_country_cash", "opening_escrow_cash", "closing_escrow_cash", "closing_expedition_funds",
			"closing_transit_population", "fatal", "fatal_reason", "audit_incomplete"]:
		ledger[key] = report.get(key)
	trace.append({"stage": label, "country_cash": ext.get_country_treasury_snapshot(handle).get("cash", -1),
		"country_transactions": ext.get_country_report().get("economy_asset_transactions", {}),
		"economy_last_audit": ledger, "receipt": receipt})

func _cohort_total(ext: Object) -> int:
	var total := 0
	for cell in CELL_COUNT:
		for amount in ext.get_population_cell_snapshot(cell).get("funds_by_cohort", PackedInt64Array()):
			total += int(amount)
	return total
