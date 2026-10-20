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
	_expect("summary exposes five sectors",
		(summary.get("sector_units", PackedInt64Array()) as PackedInt64Array).size() == 5)
	_expect("summary state day range is ordered",
		int(summary.get("state_day_min", 0)) <= int(summary.get("state_day_max", -1)))
	_expect("summary does not saturate", int(summary.get("saturation_count", 1)) == 0)


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
