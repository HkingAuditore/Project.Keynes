extends "res://tests/economy_rolling_runtime_test.gd"


func _init() -> void:
	_run()
	print("=== income tax settlement %s ===" % ("PASS" if failures == 0 else "FAIL"))
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
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 10
	profile.economy_cadence_force_investment_days = 10
	for mode in [0, 1]:
		var runtime := _new_runtime(compiled, catalog, profile, 92021)
		var handle := int(runtime.get_country_cell_summary(0).country_handle)
		var opening_cash := int(runtime.get_country_treasury_snapshot(handle).cash)
		_expect("income-only policy commits mode=%d" % mode,
			_set_tax_value(runtime, handle, 0, -1, 1000 if mode == 0 else 1, mode, 0, 1))
		for day in range(12):
			_validate_day(runtime, day)
			if bool(runtime.get_economy_report().get("fatal", false)):
				break
		var fiscal: Dictionary = runtime.get_country_fiscal_snapshot(handle)
		var collected: PackedInt64Array = fiscal.get("cumulative_collected", PackedInt64Array())
		_expect("income reaches treasury exactly once mode=%d" % mode,
			collected.size() == 5 and collected[0] > 0 and
			int(runtime.get_country_treasury_snapshot(handle).cash) - opening_cash == collected[0])
		_expect("other tax lanes remain zero mode=%d" % mode,
			collected.size() == 5 and collected[1] == 0 and collected[2] == 0 and
			collected[3] == 0 and collected[4] == 0)
		runtime = null
