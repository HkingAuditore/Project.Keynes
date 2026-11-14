extends SceneTree

## 国库收支滚动窗口：真实结算去重、逐日现金采样、7/30 日窗口和
## “其他国库变动”校准。这里不启动原生经济，只验证展示层的数据契约。

const HANDLE := 7
const Q16 := 65536.0

var failures := 0


class FakeCountryFacade:
	extends RefCounted
	var cash := 0
	var fiscal: Dictionary = {}

	func cell_summary(_cell: int) -> Dictionary:
		return {
			"ok": true, "owned": true, "country_handle": HANDLE, "cash": cash,
		}

	func fiscal_snapshot(_handle: int) -> Dictionary:
		return fiscal


class FakeGenerator:
	extends RefCounted
	var facade := FakeCountryFacade.new()

	func gameplay_start_report() -> Dictionary:
		return {"ok": true, "cell": 0}

	func get_country_facade():
		return facade


func _init() -> void:
	_run()
	print("=== economy fiscal history rolling %s ===" % (
		"PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _run() -> void:
	_check_sample_dedup()
	_check_windows_and_calibration()
	_check_positive_other_change()
	_check_insufficient_history_falls_back()
	_check_country_sampler()


func _check_sample_dedup() -> void:
	var history := EconomyFiscalHistory.new()
	_expect("first committed day samples",
		history.sample(HANDLE, _snapshot(2, 10000), 1000000, 2))
	_expect("duplicate committed day is ignored",
		not history.sample(HANDLE, _snapshot(2, 10000), 1000000, 2))
	_expect("same settlement day is stored once",
		history.settlement_size() == 1 and history.size() == 1)
	_expect("same settlement day keeps one cash sample",
		history.latest_cash_day() == 2)
	var carried := history.display_snapshot({
		"ok": true, "sample_day": 2, "has_settlement": false,
	})
	_expect("settlement can be carried forward for the daily series",
		bool(carried.get("carried_forward", false)))


func _check_windows_and_calibration() -> void:
	var history := EconomyFiscalHistory.new()
	var snapshots := [
		_snapshot(0, 10000, 0, 0, true),
		_snapshot(0, 0, 0, 0, false),
		_snapshot(2, 100000),
		_snapshot(2, 0, 0, 0, false),
		_snapshot(4, 100000, 0, 30000),
		_snapshot(4, 0, 0, 0, false),
		_snapshot(6, 100000),
		_snapshot(6, 0, 0, 0, false),
		_snapshot(8, 100000),
		_snapshot(8, 0, 0, 0, false),
	]
	var cash := [
		1000000, 1000000, 1100000, 1080000, 1180000,
		1170000, 1270000, 1260000, 1360000, 1350000,
	]
	for day in range(snapshots.size()):
		history.sample(HANDLE, snapshots[day], cash[day], day)
	_expect("display series keeps every committed day", history.size() == 10)
	_expect("no-settlement days do not duplicate the event ledger",
		history.settlement_size() == 5)
	var seven := history.rolling_snapshot(7)
	_expect("seven-day window is native", bool(seven.get("ok", false)))
	_expect("seven-day window covers seven cash days",
		int(seven.get("covered_days", 0)) == 7 and not bool(seven.get("is_partial", true)))
	_expect("seven-day window only sums real settlement events",
		int(seven.get("event_days", 0)) == 3
			and int(seven.get("classified_net", 0)) == 270000)
	_expect("seven-day window cash delta is authoritative",
		int(seven.get("cash_change", 0)) == 250000
			and int(seven.get("unclassified_change", 0)) == -20000)
	var month := history.rolling_snapshot(30)
	_expect("monthly window reports actual partial coverage",
		bool(month.get("is_partial", false))
			and int(month.get("covered_days", 0)) == 9
			and int(month.get("event_days", 0)) == 4)
	_expect("monthly window includes the older settlement",
		int(month.get("classified_net", 0)) == 370000
			and int(month.get("cash_change", 0)) == 350000)
	var flow := EconomyDossierViewModel.build_rolling_cashflow(seven)
	_expect("rolling flow is stamped as a daily average",
		bool(flow.get("rolling", false))
			and String(flow.get("window_text", "")).contains("近 7 日 · 日均")
			and not String(flow.get("window_text", "")).contains("实际"))
	var expected_net := 250000.0 / 7.0 / 10000.0
	_expect("rolling net equals treasury cash change per day",
		absf(float(flow.get("net", 0.0)) - expected_net) < 0.00001)
	_expect("rolling flow keeps the non-tax detail",
		(flow.get("detail_rows", []) as Array).size() == 7
			and (flow.get("expense_segments", []) as Array).any(
				func(row: Dictionary) -> bool:
					return String(row.get("label", "")) == "其他国库变动"))
	_expect("classified and unclassified parts remain visible",
		float(flow.get("classified_net", 0.0)) > 0.0
			and float(flow.get("other_change", 0.0)) < 0.0)
	var partial := EconomyDossierViewModel.build_rolling_cashflow(month)
	_expect("partial month states how many days it actually covers",
		String(partial.get("window_text", "")).contains("实际 9 日"))
	_expect("history helper attaches the settlement trend",
		(EconomyDossierViewModel.cashflow_from_history(
			history, _snapshot(8, 0, 0, 0, false), 7).get(
				"income_series", PackedFloat32Array()) as PackedFloat32Array).size() == 10)


func _check_positive_other_change() -> void:
	var history := EconomyFiscalHistory.new()
	history.sample(HANDLE, _snapshot(-1, 0, 0, 0, false), 1000000, 0)
	history.sample(HANDLE, _snapshot(-1, 0, 0, 0, false), 1200000, 1)
	var rolling := history.rolling_snapshot(7)
	_expect("cash-only changes still form a rolling window",
		bool(rolling.get("ok", false))
			and int(rolling.get("classified_net", 0)) == 0
			and int(rolling.get("unclassified_change", 0)) == 200000)
	var flow := EconomyDossierViewModel.build_rolling_cashflow(rolling)
	_expect("positive unclassified cash becomes an income segment",
		(flow.get("income_segments", []) as Array).any(
			func(row: Dictionary) -> bool:
				return String(row.get("label", "")) == "其他国库变动")
			and float(flow.get("net", 0.0)) > 0.0)


func _check_insufficient_history_falls_back() -> void:
	var history := EconomyFiscalHistory.new()
	history.sample(HANDLE, _snapshot(0, 5000), 1000000, 0)
	var rolling := history.rolling_snapshot(30)
	_expect("one cash sample cannot fake a rolling window",
		not bool(rolling.get("ok", true)))
	var flow := EconomyDossierViewModel.cashflow_from_history(
		history, _snapshot(0, 5000), 30)
	_expect("fallback remains the current settlement",
		not bool(flow.get("rolling", false))
			and bool(flow.get("history_available", false))
			and not bool(flow.get("can_roll", true))
			and String(flow.get("day_text", "")) == "第 1 日")


func _check_country_sampler() -> void:
	var generator := FakeGenerator.new()
	generator.facade.cash = 1000000
	generator.facade.fiscal = _snapshot(0, 0, 0, 0, false)
	var vm := CountryViewModel.new()
	vm.set_context(generator)
	_expect("country sampler records the committed day and summary cash",
		vm.sample_fiscal_history(0)
			and vm.fiscal_history().latest_cash_day() == 0)
	generator.facade.cash = 1470000
	generator.facade.fiscal = _snapshot(1, 470000)
	_expect("country sampler accepts a settlement on the next day",
		vm.sample_fiscal_history(1)
			and vm.fiscal_history().cash_size() == 2)
	var rolling := vm.fiscal_history().rolling_snapshot(7)
	_expect("sampled treasury delta drives the rolling result",
		bool(rolling.get("ok", false))
			and int(rolling.get("cash_change", 0)) == 470000
			and int(rolling.get("classified_net", 0)) == 470000)


func _snapshot(day: int, collected: int, paid: int = 0, non_tax: int = 0,
		has_settlement: bool = true) -> Dictionary:
	var snapshot := {
		"ok": true,
		"sample_day": day,
		"has_settlement": has_settlement,
		"tax_kinds": PackedStringArray(
			["income", "consumption", "business", "import", "export"]),
		"tax_base": PackedInt64Array([collected, 0, 0, 0, 0]),
		"collected": PackedInt64Array([collected, 0, 0, 0, 0]),
		"subsidy_requested": PackedInt64Array([0, 0, 0, 0, 0]),
		"subsidy_paid": PackedInt64Array([paid, 0, 0, 0, 0]),
		"non_tax_outflow_kinds": PackedStringArray(),
		"non_tax_outflow": PackedInt64Array(),
	}
	if non_tax > 0:
		snapshot["non_tax_outflow_kinds"] = PackedStringArray(["research_purchase"])
		snapshot["non_tax_outflow"] = PackedInt64Array([non_tax])
	return snapshot


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
