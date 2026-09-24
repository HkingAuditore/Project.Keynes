extends "res://tests/economy_rolling_runtime_test.gd"

func _init() -> void:
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		print("PROBE catalog failed: %s" % compiled)
		quit(2)
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile: Dictionary = load("res://data/economy/default_economy.tres").to_native_profile()
	profile.market_runtime_mode = "ACTIVE"
	profile.trade_runtime_mode = "OFF"
	profile.economy_cadence_force_market_days = 5
	profile.economy_cadence_force_plan_days = 10
	profile.economy_cadence_force_investment_days = 10
	var runtime := _new_runtime(compiled, catalog, profile, 92016, false)
	if runtime == null:
		print("PROBE runtime null")
		quit(2)
		return
	var handle := int(runtime.get_country_cell_summary(0).country_handle)
	runtime.set_economy_inspector_trace_cell(0)
	var before: Dictionary = runtime.get_population_cell_snapshot(0)
	var handles: PackedInt64Array = before.get("handles", PackedInt64Array())
	var funds_before: PackedInt64Array = before.get("funds_by_cohort", PackedInt64Array())
	print("PROBE before handles=%s funds=%s" % [handles, funds_before])
	if handles.is_empty() or not _transfer_from_cohort(runtime, int(handles[0]), 500000, 0, 1):
		print("PROBE donor transfer failed")
		quit(2)
		return
	_validate_day(runtime, 0)
	if not _set_income_tax(runtime, handle, -20, 1, 2):
		print("PROBE tax command failed")
		quit(2)
		return
	_validate_day(runtime, 1)
	for cell in range(10):
			var cp: Dictionary = runtime.get_population_cell_snapshot(cell)
			print("PROBE cell=%d state=%d funds=%s subsidy=%s tax=%s income=%s expense=%s detail=%s" % [cell, int(cp.get("state_day", -99)), cp.get("funds_by_cohort", PackedInt64Array()), cp.get("epoch_subsidy_received_by_cohort", PackedInt64Array()), cp.get("epoch_tax_paid_by_cohort", PackedInt64Array()), cp.get("settlement_income_by_cohort", PackedInt64Array()), cp.get("settlement_expense_by_cohort", PackedInt64Array()), cp.get("settlement_detail_available", false)])
	var after: Dictionary = runtime.get_population_cell_snapshot(0)
	var fiscal: Dictionary = runtime.get_country_fiscal_snapshot(handle)
	var epoch_subsidy_total := 0
	for cell in range(CELL_COUNT):
		var cell_snapshot: Dictionary = runtime.get_population_cell_snapshot(cell)
		var epoch_subsidies: PackedInt64Array = cell_snapshot.get(
			"epoch_subsidy_received_by_cohort", PackedInt64Array())
		for amount in epoch_subsidies:
			epoch_subsidy_total += int(amount)
	var ids: PackedStringArray = after.get("settlement_cashflow_source_stable_ids", PackedStringArray())
	var src_idx := ids.find("income_subsidy")
	var src_total := 0
	var src_rows := 0
	var src_indices: PackedInt32Array = after.get("settlement_cashflow_source_indices", PackedInt32Array())
	var src_income: PackedInt64Array = after.get("settlement_cashflow_income", PackedInt64Array())
	for i in range(mini(src_indices.size(), src_income.size())):
		if int(src_indices[i]) == src_idx and int(src_income[i]) > 0:
			src_total += int(src_income[i])
			src_rows += 1
	print("PROBE cohort income=%s expense=%s epoch=%s/%s" % [after.get("incomes"), after.get("expenses"), after.get("epoch_income_by_cohort", PackedInt64Array()), after.get("epoch_expense_by_cohort", PackedInt64Array())])
	print("PROBE detail=%s offsets=%s" % [after.get("settlement_detail_available", false), after.get("settlement_cashflow_offsets", PackedInt32Array())])
	print("PROBE after funds=%s settlement_income=%s source_ids=%s src_idx=%d src_rows=%d src_total=%d" % [after.get("funds_by_cohort", PackedInt64Array()), after.get("settlement_income_by_cohort", PackedInt64Array()), ids, src_idx, src_rows, src_total])
	print("PROBE fiscal=%s" % fiscal)
	var paid: PackedInt64Array = fiscal.get("subsidy_paid", PackedInt64Array())
	var cumulative: PackedInt64Array = fiscal.get("cumulative_subsidy_paid", PackedInt64Array())
	var report: Dictionary = runtime.get_economy_report()
	# The detailed settlement trace is a bounded, expiring diagnostic.  The
	# cohort epoch field and funds delta are the authoritative account credit.
	var ok := paid.size() == 5 and cumulative.size() == 5 and int(paid[0]) > 0 \
		and int(cumulative[0]) > 0 and epoch_subsidy_total > 0 \
		and int(report.get("money_error", 1)) == 0 and int(report.get("goods_error", 1)) == 0 \
		and int(report.get("population_error", 1)) == 0
	print("PROBE_RESULT ok=%s paid0=%d cumulative0=%d epoch_subsidy=%d src_total=%d money=%d goods=%d population=%d" % [ok, paid[0] if paid.size() > 0 else -1, cumulative[0] if cumulative.size() > 0 else -1, epoch_subsidy_total, src_total, int(report.get("money_error", 1)), int(report.get("goods_error", 1)), int(report.get("population_error", 1))])
	quit(0 if ok else 1)






