extends "res://tests/runtime/fiscal_return_intent_test.gd"

const GROUP_BASELINE := "res://tests/runtime/fiscal_cash_intent_baseline.json"

func _init() -> void:
	_run()
	print("=== fiscal_cash intent %s ===" % ("PASS" if failures == 0 else "FAIL"))
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
	var ext: Object = _new_runtime(compiled, catalog, profile, 104172, false)
	var handle := int(ext.get_country_cell_summary(0).country_handle)
	_expect("disable protected research cash for fiscal fixture", _disable_research(ext, handle))
	var population: Dictionary = ext.get_population_cell_snapshot(0)
	var handles: PackedInt64Array = population.get("handles", PackedInt64Array())
	_expect("fund treasury from existing cohort", _transfer_from_cohort(ext, handles[0], 500000, 0, 1))
	_finish_day(ext, 0)
	# A lower second-day subsidy leaves the previous request's reservation unused.
	_expect("initial income subsidy commits", _set_tax_value(ext, handle, 0, -1, -100, 1, 1, 2))
	_finish_day(ext, 1)
	_expect("lower income subsidy commits", _set_tax_value(ext, handle, 0, -1, -1, 1, 2, 3))
	_finish_day(ext, 2)
	_expect("positive tax commits", _set_tax_value(ext, handle, 0, -1, 1, 1, 3, 4))
	_finish_day(ext, 3)
	var protocol: Dictionary = ext.get_country_report().get("economy_asset_transactions", {})
	var returns: Array = []
	for id in range(1, int(protocol.get("next_transaction_id", 0))):
		var receipt: Dictionary = ext.get_country_economy_asset_transaction(id)
		if int(receipt.get("operation", 0)) in [2, 3, 4]:
			_expect("nonzero group transaction completed", int(receipt.get("committed_quantity", 0)) > 0
				and String(receipt.get("status_name", "")) == "completed"
				and bool(receipt.get("conservation_ok", false)))
			returns.append(receipt)
	_expect("fixture exercises group", not returns.is_empty())
	for operation in [2, 3, 4]:
		_expect("all fiscal operations exercised: %d" % operation, returns.any(func(receipt: Dictionary) -> bool: return int(receipt.operation) == operation))
	var saved_country := _save_country(ext)
	var saved_economy := _save(ext)
	_expect("both pre-intent save streams complete", bool(saved_country.get("ok", false)) and bool(saved_economy.get("ok", false)))
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
	# Compare both outputs with the pre-intent run and check logical equality.
	evidence["restored_economy_sha256"] = _sha(_save_bytes(restored, "economy"))
	evidence["economy_state_hash"] = str(ext.get_economy_state_hash())
	evidence["restored_economy_state_hash"] = str(restored.get_economy_state_hash())
	_expect("restored Economy logical state matches", evidence.economy_state_hash == evidence.restored_economy_state_hash)
	print("FISCAL_CASH_RESULT=" + JSON.stringify(evidence))
	if OS.get_environment("PK_FISCAL_CASH_CAPTURE") != "1":
		var expected: Variant = JSON.parse_string(FileAccess.get_file_as_string(GROUP_BASELINE))
		_expect("receipts and save bytes match pre-intent baseline",
			JSON.parse_string(JSON.stringify(evidence)) == expected)
