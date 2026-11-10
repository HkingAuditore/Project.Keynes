extends "res://tests/runtime/fiscal_return_intent_test.gd"

const GROUP_BASELINE := "res://tests/runtime/asset_transfer_intent_baseline.json"

func _init() -> void:
	_run()
	print("=== asset_transfer intent %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)

func _run() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
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
	_expect("disable protected research cash for fiscal fixture", _disable_research(ext, handle))
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var handles: PackedInt64Array = population.get("handles", PackedInt64Array())
	_expect("fund treasury from existing cohort", _transfer_from_cohort(ext, handles[0], 500000, 0, 1))
	var goods: PackedStringArray = compiled.good_ids
	var good := goods.find("gathered_plants")
	_expect("fixture has stocked good", good >= 0)
	_finish_day(ext, 0)
	_expect("cash returned to cohort queues", _asset_command(ext, 1, handles[0], 0, 0, 12345, 1, 2))
	_expect("goods enter treasury queues", _asset_command(ext, 13, handle, 0, good, 10000, 1, 3))
	_finish_day(ext, 1)
	_expect("goods return to market queues", _asset_command(ext, 12, handle, 0, good, 4321, 2, 4))
	_finish_day(ext, 2)
	var protocol: Dictionary = ext.get_country_report().get("economy_asset_transactions", {})
	var returns: Array = []
	for id in range(1, int(protocol.get("next_transaction_id", 0))):
		var receipt: Dictionary = ext.get_country_economy_asset_transaction(id)
		if int(receipt.get("operation", 0)) in [5, 6, 7, 8]:
			_expect("nonzero group transaction completed", int(receipt.get("committed_quantity", 0)) > 0
				and String(receipt.get("status_name", "")) == "completed"
				and bool(receipt.get("conservation_ok", false)))
			returns.append(receipt)
	_expect("fixture exercises group", not returns.is_empty())
	for operation in [5, 6, 7, 8]:
		_expect("both directions exercised: %d" % operation, returns.any(func(receipt: Dictionary) -> bool: return int(receipt.operation) == operation))
	var saved_country := _save_country(ext)
	var saved_economy := _save(ext)
	_expect("both current save streams complete", bool(saved_country.get("ok", false)) and bool(saved_economy.get("ok", false)))
	var country_bytes := _joined(saved_country.chunks)
	var economy_bytes := _joined(saved_economy.chunks)
	var evidence := {"returns": returns, "country_sha256": _sha(country_bytes),
		"economy_sha256": _sha(economy_bytes)}
	var restored: Object = _new_ext(compiled)
	_expect("restore Country configured", CountryTestHelper.configure_all_technologies(restored, catalog, CELL_COUNT, 104172))
	_expect("Country restore", _restore_country(restored, saved_country.chunks))
	_expect("restore Economy configured", bool(restored.configure_economy(catalog, profile, CELL_COUNT, 104172).get("ok", false)))
	var loaded: Dictionary = _restore(restored, saved_economy.chunks)
	_expect("Economy restore", bool(loaded.get("ok", false)))
	_expect("Country roundtrip preserves bytes", _save_bytes(restored, "country") == country_bytes)
	# PKEC re-encoding already differs from its input before this prototype.
	# Compare both outputs with the reviewed content baseline and check logical equality.
	evidence["restored_economy_sha256"] = _sha(_save_bytes(restored, "economy"))
	evidence["economy_state_hash"] = str(ext.get_economy_state_hash())
	evidence["restored_economy_state_hash"] = str(restored.get_economy_state_hash())
	_expect("restored Economy logical state matches", evidence.economy_state_hash == evidence.restored_economy_state_hash)
	print("ASSET_TRANSFER_RESULT=" + JSON.stringify(evidence))
	if OS.get_environment("PK_ASSET_TRANSFER_CAPTURE") != "1":
		var expected: Variant = JSON.parse_string(FileAccess.get_file_as_string(GROUP_BASELINE))
		_expect("receipts and save bytes match reviewed content baseline",
			JSON.parse_string(JSON.stringify(evidence)) == expected)

func _asset_command(ext: Object, opcode: int, handle: int, cell: int, good: int,
		amount: int, day: int, sequence: int) -> bool:
	return bool(ext.submit_economy_commands({
		"opcodes": PackedInt32Array([opcode]), "effective_days": PackedInt64Array([day]),
		"sequences": PackedInt64Array([sequence]), "target_handles": PackedInt64Array([handle]),
		"i32_0": PackedInt32Array([cell]), "i32_1": PackedInt32Array([good]),
		"i64_0": PackedInt64Array([amount]), "i64_1": PackedInt64Array([0]),
	}).get("ok", false))
