extends SceneTree

## EconomyGdpLedger 的纯逻辑回归：不加载原生运行时，用假 façade 驱动。
## 覆盖——同日去重、墙钟合流、跨日积分、跨年截断、逐格加总等于全国、
## 聚落消失后的日产值归零与年度累计保留。

const LedgerScript = preload("res://scripts/ui/economy_gdp_ledger.gd")

var failures := 0


class FakeMap:
	extends RefCounted
	var count := 8

	func cell_count() -> int:
		return count


class FakeClock:
	extends RefCounted
	var dpy := 10

	func days_per_year() -> int:
		return dpy

	func year_index_for_day(day: int) -> int:
		return int(floor(float(day) / float(dpy)))


class FakeCountryFacade:
	extends RefCounted
	var owned := true

	func cell_summary(_cell: int) -> Dictionary:
		if not owned:
			return {"ok": true, "owned": false}
		return {"ok": true, "owned": true, "country_handle": 7}


class FakeEconomyFacade:
	extends RefCounted
	## cell → {profit, wages, population}
	var rows := {}
	var whole_country := 0
	var busy := false
	var calls := 0
	var page_limit_override := 0

	func country_economy_overview(_handle: int, view: String = "summary",
			_scope: int = -1, _filter: int = -1, offset: int = 0,
			limit: int = 0) -> Dictionary:
		calls += 1
		if busy:
			return {"ok": false, "busy": true, "reason": "read_view_pending"}
		if view == "summary":
			var revenue := 0
			var input := 0
			var maintenance := 0
			var population := 0
			for key in rows:
				var row: Dictionary = rows[key]
				revenue += int(row.get("profit", 0)) + int(row.get("wages", 0))
				population += int(row.get("population", 0))
			return {"ok": true, "view": "summary", "revenue_per_day": revenue,
				"input_cost_per_day": input, "maintenance_per_day": maintenance,
				"population": population}
		if view != "settlements":
			return {"ok": false, "reason": "unknown_view"}
		var page_size := limit if limit > 0 else 512
		if page_limit_override > 0:
			page_size = page_limit_override
		var cells := PackedInt32Array()
		var profit := PackedInt64Array()
		var wages := PackedInt64Array()
		var populations := PackedInt64Array()
		var keys := rows.keys()
		keys.sort()
		for index in range(offset, mini(keys.size(), offset + page_size)):
			var cell := int(keys[index])
			var row: Dictionary = rows[cell]
			cells.append(cell)
			profit.append(int(row.get("profit", 0)))
			wages.append(int(row.get("wages", 0)))
			populations.append(int(row.get("population", 0)))
		return {"ok": true, "view": "settlements", "total": keys.size(),
			"offset": offset, "limit": page_size,
			"has_more": offset + cells.size() < keys.size(),
			"cell_indices": cells, "profit_per_day": profit,
			"wages_paid_per_day": wages, "population": populations}


class FakeGenerator:
	extends RefCounted
	var economy := FakeEconomyFacade.new()
	var country := FakeCountryFacade.new()
	var start_ok := true

	func gameplay_start_report() -> Dictionary:
		return {"ok": start_ok, "cell": 0}

	func get_economy_facade():
		return economy

	func get_country_facade():
		return country


func _init() -> void:
	_run()
	print("=== economy gdp ledger %s ===" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _near(a: float, b: float, tolerance: float = 0.001) -> bool:
	return absf(a - b) <= tolerance


func _make() -> Dictionary:
	var generator := FakeGenerator.new()
	var clock := FakeClock.new()
	var map := FakeMap.new()
	var ledger = LedgerScript.new()
	ledger.min_sample_msec = 0
	ledger.configure(generator, clock, map)
	return {"ledger": ledger, "generator": generator, "clock": clock, "map": map}


func _run() -> void:
	_check_backfill_and_integration()
	_check_year_rollover()
	_check_cell_sum_equals_national()
	_check_vanished_settlement()
	_check_busy_and_missing_country()
	_check_paging_fallback()


func _check_backfill_and_integration() -> void:
	var env := _make()
	var ledger = env.ledger
	var generator: FakeGenerator = env.generator
	generator.economy.rows = {0: {"profit": 100, "wages": 50, "population": 10}}

	_expect("not ready before first sample", not ledger.ready())
	_expect("first sample backfills from year start", ledger.sample(5))
	_expect("ytd integrates 5 days at 150/day", _near(ledger.cell_ytd(0), 750.0))
	_expect("national ytd matches cell", _near(ledger.national_ytd(), 750.0))
	_expect("days counted is 5", ledger.days_counted() == 5)
	_expect("backfilled flag set", ledger.backfilled())
	_expect("per capita = ytd / population", _near(ledger.cell_per_capita(0), 75.0))

	_expect("same committed day is ignored", not ledger.sample(5))
	_expect("ytd unchanged after duplicate", _near(ledger.cell_ytd(0), 750.0))

	_expect("next day integrates one more day", ledger.sample(6))
	_expect("ytd after day 6", _near(ledger.cell_ytd(0), 900.0))

	# 墙钟合流：阈值拉高后采样被丢弃，恢复阈值后一次补齐跨过的天数。
	ledger.min_sample_msec = 10000000
	_expect("throttled sample is dropped", not ledger.sample(7))
	_expect("throttle does not lose money", _near(ledger.cell_ytd(0), 900.0))
	ledger.min_sample_msec = 0
	_expect("catch-up sample succeeds", ledger.sample(9))
	_expect("catch-up integrates 3 days", _near(ledger.cell_ytd(0), 1350.0))


func _check_year_rollover() -> void:
	var env := _make()
	var ledger = env.ledger
	var generator: FakeGenerator = env.generator
	generator.economy.rows = {0: {"profit": 100, "wages": 0, "population": 10}}
	ledger.sample(8)
	_expect("ytd near year end", _near(ledger.cell_ytd(0), 800.0))
	_expect("year index 0", ledger.year_index() == 0)

	_expect("first sample of new year accepted", ledger.sample(12))
	_expect("year index advanced", ledger.year_index() == 1)
	_expect("new year only counts days inside the year",
		_near(ledger.cell_ytd(0), 200.0))
	_expect("new year days counted", ledger.days_counted() == 2)
	_expect("year start day", ledger.year_start_day() == 10)


func _check_cell_sum_equals_national() -> void:
	var env := _make()
	var ledger = env.ledger
	var generator: FakeGenerator = env.generator
	generator.economy.rows = {
		0: {"profit": 30, "wages": 70, "population": 4},
		3: {"profit": 200, "wages": 25, "population": 8},
	}
	ledger.sample(4)
	var cell_sum: float = ledger.cell_ytd(0) + ledger.cell_ytd(3)
	_expect("per-cell ytd sums to national", _near(cell_sum, ledger.national_ytd()))
	_expect("national per day is 325", _near(ledger.national_per_day(), 325.0))
	_expect("national population aggregated", ledger.national_population() == 12)
	_expect("national per capita", _near(ledger.national_per_capita(), 1300.0 / 12.0))
	_expect("untracked cell reads as zero", _near(ledger.cell_ytd(5), 0.0))
	_expect("out-of-range cell reads as minus one", _near(ledger.cell_ytd(99), -1.0))
	_expect("untracked cell not reported", not ledger.tracks_cell(5))


func _check_vanished_settlement() -> void:
	var env := _make()
	var ledger = env.ledger
	var generator: FakeGenerator = env.generator
	generator.economy.rows = {
		0: {"profit": 10, "wages": 10, "population": 5},
		1: {"profit": 10, "wages": 10, "population": 5},
	}
	ledger.sample(2)
	_expect("both settlements tracked", ledger.tracks_cell(0) and ledger.tracks_cell(1))
	generator.economy.rows = {1: {"profit": 10, "wages": 10, "population": 5}}
	ledger.sample(3)
	_expect("vanished settlement keeps ytd", _near(ledger.cell_ytd(0), 40.0))
	_expect("vanished settlement drops daily output",
		_near(ledger.cell_per_day(0), 0.0))
	_expect("vanished settlement drops population", ledger.cell_population(0) == 0)
	_expect("vanished settlement still tracked for the year", ledger.tracks_cell(0))
	_expect("per capita is NAN without population", is_nan(ledger.cell_per_capita(0)))


func _check_busy_and_missing_country() -> void:
	var env := _make()
	var ledger = env.ledger
	var generator: FakeGenerator = env.generator
	generator.economy.rows = {0: {"profit": 10, "wages": 0, "population": 5}}
	generator.economy.busy = true
	_expect("busy commit does not advance", not ledger.sample(4))
	_expect("busy commit keeps ledger unready", not ledger.ready())
	generator.economy.busy = false
	_expect("retry after busy advances", ledger.sample(4))
	_expect("busy retry backfills the missed span",
		_near(ledger.cell_ytd(0), 40.0))

	var orphan := _make()
	orphan.generator.country.owned = false
	for _attempt in range(40):
		orphan.ledger.sample(4)
	_expect("unowned start cell yields no ledger", not orphan.ledger.ready())


func _check_paging_fallback() -> void:
	var env := _make()
	var ledger = env.ledger
	var generator: FakeGenerator = env.generator
	var rows := {}
	for cell in range(6):
		rows[cell] = {"profit": 10, "wages": 0, "population": 5}
	generator.economy.rows = rows
	# 每页只给 1 行：4 页只能覆盖 6 个聚落中的 4 个，触发 summary 回退。
	generator.economy.page_limit_override = 1
	_expect("paging still samples", ledger.sample(2))
	_expect("paging covers the first pages before the cap", ledger.tracks_cell(0))
	_expect("paging reports partial coverage", ledger.partial())
	# 全国值回退到 summary 口径：六个聚落 60/日 × 2 天。
	_expect("national falls back to summary totals",
		_near(ledger.national_ytd(), 120.0))
