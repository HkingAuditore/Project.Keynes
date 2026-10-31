extends "res://tests/economy/economy_rolling_runtime_test.gd"

## get_country_economy_overview 只读聚合：全国汇总必须严格等于领土内逐格查询之和。


func _init() -> void:
	_run()
	print("=== country economy overview %s ===" % ("PASS" if failures == 0 else "FAIL"))
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
	var runtime := _new_runtime(compiled, catalog, profile, 92077)
	_expect("overview API is bound", runtime.has_method("get_country_economy_overview"))
	if not runtime.has_method("get_country_economy_overview"):
		return
	var handle := int(runtime.get_country_cell_summary(0).get("country_handle", 0))
	_expect("country handle resolves", handle != 0)
	for day in range(7):
		_run_day(runtime, day)
	var territory := _territory_cells(runtime, handle)
	_expect("territory is non-empty", not territory.is_empty())
	_check_summary(runtime, handle, territory)
	_check_market_metrics(runtime, handle, territory)
	_check_professions(runtime, handle)
	_check_buildings(runtime, handle)
	_check_settlements(runtime, handle, territory)
	_check_goods(runtime, handle, territory)
	_check_investment(runtime, handle)
	_check_scope_and_errors(runtime, handle, territory)


func _run_day(ext: Object, day: int) -> void:
	for slice in range(64):
		var report: Dictionary = ext.run_economy_slice({
			"day_index": day, "tick_index": day * 1000 + slice})
		if bool(report.get("done", false)) or bool(report.get("fatal", false)):
			_expect("day %d commits" % day, bool(report.get("done", false)))
			return
	_expect("day %d finishes within slice budget" % day, false)


func _territory_cells(ext: Object, handle: int) -> PackedInt32Array:
	var cells := PackedInt32Array()
	for cell in range(CELL_COUNT):
		if int(ext.get_country_cell_summary(cell).get("country_handle", 0)) == handle:
			cells.append(cell)
	return cells


func _check_summary(ext: Object, handle: int, territory: PackedInt32Array) -> void:
	var summary: Dictionary = ext.get_country_economy_overview(handle, "summary")
	_expect("summary ok", bool(summary.get("ok", false)))
	var population := 0
	var funds := 0
	var income := 0
	var expense := 0
	for cell in territory:
		var cell_summary: Dictionary = ext.get_population_cell_summary(cell)
		population += int(cell_summary.get("population", 0))
		funds += int(cell_summary.get("funds", 0))
		income += int(cell_summary.get("epoch_income", 0))
		expense += int(cell_summary.get("epoch_expense", 0))
	_expect("summary population equals territory cell sum",
		int(summary.get("population", -1)) == population and population > 0)
	_expect("summary funds equals territory cell sum", int(summary.get("funds", -1)) == funds)
	_expect("summary period income/expense equal cell sums",
		int(summary.get("epoch_income", -1)) == income and
		int(summary.get("epoch_expense", -1)) == expense)
	_expect("summary employment partitions population",
		int(summary.get("owner_employed", 0)) + int(summary.get("employee_employed", 0)) +
		int(summary.get("unemployed", 0)) >= population)
	var dims: PackedInt32Array = summary.get("satisfaction_dims_q16", PackedInt32Array())
	_expect("summary exposes eight satisfaction dimensions", dims.size() == 8)
	_expect("summary satisfaction is a q16 ratio",
		int(summary.get("satisfaction_q16", -1)) >= 0 and
		int(summary.get("satisfaction_q16", 65537)) <= 65536)
	_expect("summary exposes population-weighted living standard",
		bool(summary.get("living_standard_level_valid", false)) and
		int(summary.get("living_standard_level_q16", -1)) >= 0 and
		int(summary.get("living_standard_level_q16", 0)) <= 6 * 65536)
	_expect("summary exposes five sectors",
		(summary.get("sector_units", PackedInt64Array()) as PackedInt64Array).size() == 5)
	_expect("summary state day range is ordered",
		int(summary.get("state_day_min", 0)) <= int(summary.get("state_day_max", -1)))
	_expect("summary does not saturate", int(summary.get("saturation_count", 1)) == 0)


func _check_market_metrics(ext: Object, handle: int, territory: PackedInt32Array) -> void:
	var summary: Dictionary = ext.get_country_economy_overview(handle, "summary")
	var expected := _expected_market_metrics(ext, territory)
	for metric in ["consumer_price_index", "producer_price_index",
			"consumer_shortage", "industrial_shortage"]:
		_expect("%s matches committed market weighting" % metric,
			int(summary.get("%s_q16" % metric, -1)) == int(expected["%s_q16" % metric]))
		_expect("%s validity follows positive weighted data" % metric,
			bool(summary.get("%s_valid" % metric, not bool(expected["%s_valid" % metric]))) ==
			bool(expected["%s_valid" % metric]))
	_expect("consumer and producer indices are nonnegative Q16 values",
		int(summary.get("consumer_price_index_q16", -1)) >= 0 and
		int(summary.get("producer_price_index_q16", -1)) >= 0)
	_expect("shortage aggregates stay within Q16 ratio bounds",
		int(summary.get("consumer_shortage_q16", -1)) >= 0 and
		int(summary.get("consumer_shortage_q16", 65537)) <= 65536 and
		int(summary.get("industrial_shortage_q16", -1)) >= 0 and
		int(summary.get("industrial_shortage_q16", 65537)) <= 65536)

	var invalid_scope_checked := false
	for cell in territory:
		var scope := PackedInt32Array([cell])
		var scoped_expected := _expected_market_metrics(ext, scope)
		var has_invalid_metric := false
		for metric in ["consumer_price_index", "producer_price_index",
				"consumer_shortage", "industrial_shortage"]:
			has_invalid_metric = has_invalid_metric or not bool(
				scoped_expected["%s_valid" % metric])
		if not has_invalid_metric:
			continue
		var scoped: Dictionary = ext.get_country_economy_overview(
			handle, "summary", cell)
		var invalid_matches := true
		for metric in ["consumer_price_index", "producer_price_index",
				"consumer_shortage", "industrial_shortage"]:
			invalid_matches = invalid_matches and (
				int(scoped.get("%s_q16" % metric, -1)) ==
				int(scoped_expected["%s_q16" % metric]) and
				bool(scoped.get("%s_valid" % metric, true)) ==
				bool(scoped_expected["%s_valid" % metric]))
		_expect("single-cell invalid macro denominators are explicit",
			invalid_matches)
		invalid_scope_checked = true
		break
	_expect("fixture includes a no-weight macro metric scope", invalid_scope_checked)


func _expected_market_metrics(ext: Object, cells: PackedInt32Array) -> Dictionary:
	var weighted := {
		"consumer_price_index_q16": 0, "producer_price_index_q16": 0,
		"consumer_shortage_q16": 0, "industrial_shortage_q16": 0,
	}
	var weights := {
		"consumer_price_index": 0, "producer_price_index": 0,
		"consumer_shortage": 0, "industrial_shortage": 0,
	}
	for cell in cells:
		var market: Dictionary = ext.get_market_cell_snapshot(cell)
		if not bool(market.get("ok", false)):
			continue
		var good_ids: PackedStringArray = market.get("good_ids", PackedStringArray())
		var tags: PackedStringArray = market.get(
			"good_technology_tags", PackedStringArray())
		var offsets: PackedInt32Array = market.get(
			"good_technology_tag_offsets", PackedInt32Array())
		var demand: PackedInt64Array = market.get("demand_ema", PackedInt64Array())
		var business: PackedInt64Array = market.get(
			"business_demand_ema", PackedInt64Array())
		var supply: PackedInt64Array = market.get(
			"offered_supply_ema", PackedInt64Array())
		var prices: PackedInt32Array = market.get("price", PackedInt32Array())
		var anchors: PackedInt32Array = market.get(
			"cost_anchor_price", PackedInt32Array())
		var shortages: PackedInt32Array = market.get(
			"shortage_q16", PackedInt32Array())
		for good in range(good_ids.size()):
			var food := _has_industry_tag(offsets, tags, good, "industry.food")
			var textile := _has_industry_tag(offsets, tags, good, "industry.textile")
			var consumer := _has_industry_tag(offsets, tags, good, "industry.consumer")
			var is_industrial := _has_industry_tag(offsets, tags, good, "industry.primary") or \
				_has_industry_tag(offsets, tags, good, "industry.construction") or \
				_has_industry_tag(offsets, tags, good, "industry.metals") or \
				_has_industry_tag(offsets, tags, good, "industry.chemicals") or \
				_has_industry_tag(offsets, tags, good, "industry.energy") or \
				_has_industry_tag(offsets, tags, good, "industry.machinery")
			if good >= demand.size() or good >= business.size() or good >= supply.size() or \
				good >= prices.size() or good >= anchors.size() or good >= shortages.size():
				continue
			var household_demand := maxi(0, demand[good])
			var business_demand := maxi(0, business[good])
			var offered_supply := maxi(0, supply[good])
			var anchor := anchors[good]
			var ratio_q16 := int(maxi(0, prices[good]) * 65536 / anchor) if anchor > 0 else 0
			if food or textile or consumer:
				if household_demand > 0 and anchor > 0:
					weighted["consumer_price_index_q16"] += ratio_q16 * household_demand
					weights["consumer_price_index"] += household_demand
			if offered_supply > 0 and anchor > 0:
				weighted["producer_price_index_q16"] += ratio_q16 * offered_supply
				weights["producer_price_index"] += offered_supply
			if (textile or consumer) and household_demand > 0:
				weighted["consumer_shortage_q16"] += clampi(shortages[good], 0, 65536) * household_demand
				weights["consumer_shortage"] += household_demand
			if is_industrial and business_demand > 0:
				weighted["industrial_shortage_q16"] += clampi(shortages[good], 0, 65536) * business_demand
				weights["industrial_shortage"] += business_demand
	for metric in ["consumer_price_index", "producer_price_index",
			"consumer_shortage", "industrial_shortage"]:
		var weight := int(weights[metric])
		var valid := weight > 0
		weighted["%s_valid" % metric] = valid
		weighted["%s_q16" % metric] = int(
			int(weighted["%s_q16" % metric]) / weight) if valid else 0
	return weighted


func _has_industry_tag(offsets: PackedInt32Array, tags: PackedStringArray,
		good: int, wanted: String) -> bool:
	if offsets.size() <= good + 1:
		return false
	for index in range(offsets[good], offsets[good + 1]):
		if String(tags[index]) == wanted:
			return true
	return false


func _check_professions(ext: Object, handle: int) -> void:
	var summary: Dictionary = ext.get_country_economy_overview(handle, "summary")
	var page: Dictionary = ext.get_country_economy_overview(handle, "professions")
	_expect("professions ok", bool(page.get("ok", false)))
	_expect("professions partition population",
		_sum_i64(page.get("population", PackedInt64Array())) ==
		int(summary.get("population", -1)))
	_expect("professions partition funds",
		_sum_i64(page.get("funds", PackedInt64Array())) == int(summary.get("funds", -1)))
	var rows := (page.get("profession_indices", PackedInt32Array()) as PackedInt32Array).size()
	_expect("profession dimension matrix is row-major",
		(page.get("satisfaction_dims_q16", PackedInt32Array()) as PackedInt32Array).size() ==
		rows * 8)
	_expect("profession worst-need matrix is row-major",
		(page.get("worst_need_population", PackedInt64Array()) as PackedInt64Array).size() ==
		rows * int(page.get("need_count", 0)))


func _check_buildings(ext: Object, handle: int) -> void:
	var summary: Dictionary = ext.get_country_economy_overview(handle, "summary")
	var page: Dictionary = ext.get_country_economy_overview(handle, "buildings")
	_expect("buildings ok", bool(page.get("ok", false)))
	_expect("building units equal summary",
		_sum_i64(page.get("units", PackedInt64Array())) ==
		int(summary.get("building_units", -1)))
	_expect("building revenue equals summary",
		_sum_i64(page.get("revenue_per_day", PackedInt64Array())) ==
		int(summary.get("revenue_per_day", -1)))
	_expect("building jobs equal summary",
		_sum_i64(page.get("jobs_required", PackedInt64Array())) ==
		int(summary.get("job_capacity", -1)))
	var sector_units: PackedInt64Array = summary.get("sector_units", PackedInt64Array())
	for sector in range(sector_units.size()):
		var filtered: Dictionary = ext.get_country_economy_overview(
			handle, "buildings", -1, sector)
		_expect("sector %d filter matches summary" % sector,
			_sum_i64(filtered.get("units", PackedInt64Array())) == sector_units[sector])


func _check_settlements(ext: Object, handle: int, territory: PackedInt32Array) -> void:
	var page: Dictionary = ext.get_country_economy_overview(handle, "settlements")
	_expect("settlements ok", bool(page.get("ok", false)))
	var cells: PackedInt32Array = page.get("cell_indices", PackedInt32Array())
	var populations: PackedInt64Array = page.get("population", PackedInt64Array())
	var populated := 0
	for cell in territory:
		if int(ext.get_population_cell_summary(cell).get("population", 0)) > 0:
			populated += 1
	_expect("settlements list each populated territory cell",
		int(page.get("total", -1)) == populated and cells.size() == populated)
	var rows_match := true
	for row in range(cells.size()):
		rows_match = rows_match and populations[row] == int(
			ext.get_population_cell_summary(cells[row]).get("population", -1))
		if row > 0:
			rows_match = rows_match and populations[row - 1] >= populations[row]
	_expect("settlement rows match cell population and sort descending", rows_match)
	var offsets: PackedInt32Array = page.get("profession_offsets", PackedInt32Array())
	var profession_population: PackedInt64Array = page.get(
		"profession_population", PackedInt64Array())
	var csr_ok := offsets.size() == cells.size() + 1
	for row in range(cells.size()):
		if not csr_ok:
			break
		var subtotal := 0
		for k in range(offsets[row], offsets[row + 1]):
			subtotal += profession_population[k]
		csr_ok = subtotal == populations[row]
	_expect("settlement profession CSR partitions each row", csr_ok)
	var paged: Dictionary = ext.get_country_economy_overview(
		handle, "settlements", -1, -1, 1, 1)
	_expect("settlement paging honours offset/limit",
		(paged.get("cell_indices", PackedInt32Array()) as PackedInt32Array).size() ==
		mini(1, maxi(0, populated - 1)))


func _check_goods(ext: Object, handle: int, territory: PackedInt32Array) -> void:
	var page: Dictionary = ext.get_country_economy_overview(handle, "goods")
	_expect("goods ok", bool(page.get("ok", false)))
	var goods: PackedInt32Array = page.get("good_indices", PackedInt32Array())
	var stock: PackedInt64Array = page.get("stock", PackedInt64Array())
	var stock_ok := true
	for row in range(goods.size()):
		var expected := 0
		for cell in territory:
			if int(ext.get_population_cell_summary(cell).get("population", 0)) <= 0:
				continue
			var market: Dictionary = ext.get_market_cell_snapshot(cell)
			var cell_stock: PackedInt64Array = market.get("stock", PackedInt64Array())
			if goods[row] < cell_stock.size():
				expected += maxi(0, cell_stock[goods[row]])
		stock_ok = stock_ok and expected == stock[row]
	_expect("goods stock equals territory market sum", stock_ok and not goods.is_empty())
	var shortages: PackedInt32Array = page.get("shortage_q16", PackedInt32Array())
	var ratio_ok := true
	for value in shortages:
		ratio_ok = ratio_ok and value >= 0 and value <= 65536
	_expect("goods shortage is a q16 ratio", ratio_ok)


func _check_investment(ext: Object, handle: int) -> void:
	var page: Dictionary = ext.get_country_economy_overview(handle, "investment")
	_expect("investment ok", bool(page.get("ok", false)))
	_expect("investment covers every rejection reason",
		(page.get("rejection_units", PackedInt64Array()) as PackedInt64Array).size() ==
		int(page.get("rejection_reason_count", -1)) and
		int(page.get("rejection_reason_count", -1)) == 19)
	_expect("investment pending totals agree",
		_sum_i64(page.get("pending_units", PackedInt64Array())) ==
		int(page.get("pending_total_units", -1)))


func _check_scope_and_errors(ext: Object, handle: int, territory: PackedInt32Array) -> void:
	var cell := territory[0]
	var scoped: Dictionary = ext.get_country_economy_overview(handle, "summary", cell)
	var cell_summary: Dictionary = ext.get_population_cell_summary(cell)
	_expect("single-city scope equals that cell",
		bool(scoped.get("ok", false)) and
		int(scoped.get("population", -1)) == int(cell_summary.get("population", -2)) and
		int(scoped.get("funds", -1)) == int(cell_summary.get("funds", -2)) and
		int(scoped.get("territory_cell_count", -1)) == 1)
	var invalid: Dictionary = ext.get_country_economy_overview(987654321, "summary")
	_expect("foreign/invalid handle is rejected",
		not bool(invalid.get("ok", true)) and
		String(invalid.get("reason", "")) == "country_handle_invalid")
	var unknown: Dictionary = ext.get_country_economy_overview(handle, "nope")
	_expect("unknown view is rejected",
		String(unknown.get("reason", "")) == "country_economy_view_unknown")
	for other in range(CELL_COUNT):
		if territory.has(other):
			continue
		var outside: Dictionary = ext.get_country_economy_overview(handle, "summary", other)
		_expect("cell outside territory is rejected",
			String(outside.get("reason", "")) == "cell_not_in_country")
		break
