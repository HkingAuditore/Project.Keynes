extends RefCounted
class_name EconomyGdpLedger

## 年度累计产值（GDP）账本。只读消费 EconomyFacade.country_economy_overview 的
## settlements 视图，把逐聚落的「日产值」按已提交经济周期积分成年初至今的累计值。
##
## 口径（收入法）：GDP / 日 = 建筑营收 − 中间投入 − 维护 = 工资 + 营业盈余。
## settlements 行里的 profit_per_day 已经是「营收 − 投入 − 工资 − 维护」，所以
## profit_per_day + wages_paid_per_day 恒等于上式；逐格相加即全国值，不用另设口径。
## 生产税（营业税）不在其中——原生 last_revenue 已是税后实收。
##
## 性能契约：
## - 每个已提交周期最多一次批量查询（sample_day 去重 + MIN_SAMPLE_MSEC 墙钟合流）；
## - 合流丢掉的是采样点而不是金额：累加按 delta_days 积分，跨过的天数下次一并补上；
## - 之后所有读数都是 PackedFloat64Array 的 O(1) 下标访问，不再碰原生；
## - 无 _process、无 Timer，只在 UI 管理器的「已提交日」回调里被动采样。

const MIN_SAMPLE_MSEC := 120
## 与原生 OVERVIEW_MAX_ROWS 对齐：settlements 单页最多 512 行。
const PAGE_LIMIT := 512
## 分页上限，防止极端局面下无限翻页；超出则全国值回退到 summary 口径。
const MAX_PAGES := 4
const COUNTRY_RESOLVE_MISS_LIMIT := 32

## 墙钟合流阈值。测试可置 0 关掉节流，生产环境保持 MIN_SAMPLE_MSEC。
var min_sample_msec := MIN_SAMPLE_MSEC

var _generator = null
var _world_clock = null
var _map = null

var _country_handle := -1
var _country_resolve_misses := 0
var _country_resolved := false

var _cell_count := 0
## 按 cell 索引，单位与原生一致（1/10000 货币）。未跟踪格恒为 0。
var _cell_ytd := PackedFloat64Array()
var _cell_per_day := PackedFloat64Array()
var _cell_population := PackedInt64Array()
## 本年度是否出现在 settlements 列表里（出现过就保留累计值，即使后来人口归零）。
var _cell_tracked := PackedByteArray()
## 本轮采样命中标记，只用于判定「上一轮有、这一轮没了」的聚落。
var _cell_seen_round := PackedByteArray()
var _tracked_cells := PackedInt32Array()

var _national_ytd := 0.0
var _national_per_day := 0.0
var _national_population := 0
var _partial := false

var _year := -1
var _days_per_year := 365
## 上次累计到的已提交日；换年时重置为当年第 0 天。
var _last_day := -1
var _last_sample_msec := 0
## 本年度第一个样本跨了多少天（>1 说明年初那段是按当前速率回溯折算的）。
var _first_sample_span := 0
var _days_counted := 0
## 至少成功累加过一笔；用于区分「还没结算」与「当年确实是 0」。
var _has_sample := false


func configure(generator, world_clock, map) -> void:
	_generator = generator
	_world_clock = world_clock
	_map = map
	_country_handle = -1
	_country_resolve_misses = 0
	_country_resolved = false
	_cell_count = 0
	_cell_ytd = PackedFloat64Array()
	_cell_per_day = PackedFloat64Array()
	_cell_population = PackedInt64Array()
	_cell_tracked = PackedByteArray()
	_cell_seen_round = PackedByteArray()
	_tracked_cells = PackedInt32Array()
	_national_ytd = 0.0
	_national_per_day = 0.0
	_national_population = 0
	_partial = false
	_year = -1
	_days_per_year = _resolve_days_per_year()
	_last_day = -1
	_last_sample_msec = 0
	_first_sample_span = 0
	_days_counted = 0
	_has_sample = false


# ── 采样 ────────────────────────────────────────────────────────────────

## 由 UI 管理器在每个已提交经济日调用。返回 true 表示本次真的累加了一笔。
func sample(day_idx: int) -> bool:
	if _generator == null or day_idx < 0:
		return false
	if not _ensure_country():
		return false
	if _year >= 0 and day_idx < _last_day:
		return false
	var now := Time.get_ticks_msec()
	# 墙钟合流：高速模拟下不因每次提交都做整国聚合；跨过的天数由 delta 补偿。
	if _last_sample_msec > 0 and now - _last_sample_msec < min_sample_msec:
		return false

	var year := _year_index_for_day(day_idx)
	var days_per_year := _resolve_days_per_year()
	if year != _year or days_per_year != _days_per_year:
		_days_per_year = days_per_year
		_year = year
		_reset_year_values()

	var year_start := _year * _days_per_year
	var delta := day_idx - _last_day
	if delta <= 0:
		# 同一已提交日、或恰好落在年首：没有可积分的流量，等下一次提交。
		return false

	if _fetch_and_accumulate(delta).is_empty():
		# 结算进行中或读数未就绪：不推进 _last_day，下次提交会把这段天数补回来。
		return false

	if _first_sample_span <= 0:
		_first_sample_span = delta
	_last_day = day_idx
	_last_sample_msec = now
	_days_counted = day_idx - year_start
	_has_sample = true
	return true


## 拉一次 settlements 并把逐格日产值积分到 delta 天上。
## 返回空字典表示本次没有可用读数（此时调用方不得推进日期）。
func _fetch_and_accumulate(delta: int) -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {}
	var facade = _generator.get_economy_facade()
	if facade == null or not facade.has_method("country_economy_overview"):
		return {}
	if not _ensure_capacity():
		return {}

	var previous_cells := _tracked_cells
	for cell in previous_cells:
		if cell >= 0 and cell < _cell_count:
			_cell_seen_round[cell] = 0

	var next_tracked := PackedInt32Array()
	var offset := 0
	var pages := 0
	var total := 0
	var rows_seen := 0
	var sum_per_day := 0.0
	var sum_population := 0
	var first_page_ok := false

	while pages < MAX_PAGES:
		var page: Dictionary = facade.country_economy_overview(
			_country_handle, "settlements", -1, -1, offset, PAGE_LIMIT)
		pages += 1
		if not bool(page.get("ok", false)):
			if not first_page_ok:
				return {}
			break
		first_page_ok = true
		total = int(page.get("total", 0))
		var cells: PackedInt32Array = page.get("cell_indices", PackedInt32Array())
		var profit: PackedInt64Array = page.get("profit_per_day", PackedInt64Array())
		var wages: PackedInt64Array = page.get("wages_paid_per_day", PackedInt64Array())
		var populations: PackedInt64Array = page.get("population", PackedInt64Array())
		var rows := cells.size()
		for index in range(rows):
			var cell := int(cells[index])
			if cell < 0 or cell >= _cell_count:
				continue
			var per_day := float(profit[index]) + float(wages[index])
			_cell_ytd[cell] += per_day * float(delta)
			_cell_per_day[cell] = per_day
			_cell_population[cell] = int(populations[index])
			_cell_tracked[cell] = 1
			_cell_seen_round[cell] = 1
			sum_per_day += per_day
			sum_population += int(populations[index])
			next_tracked.append(cell)
		rows_seen += rows
		if rows <= 0 or not bool(page.get("has_more", false)):
			break
		offset += rows

	# 本轮消失的聚落（人口清零 / 被吞并）：日产值归零，但年度累计保留历史产出。
	for cell in previous_cells:
		if cell < 0 or cell >= _cell_count:
			continue
		if _cell_seen_round[cell] == 0:
			_cell_per_day[cell] = 0.0
			_cell_population[cell] = 0
	_tracked_cells = next_tracked

	if rows_seen >= total:
		_partial = false
		_national_per_day = sum_per_day
		_national_population = sum_population
		_national_ytd += sum_per_day * float(delta)
		return {"ok": true}

	# 分页没覆盖全部聚落：逐格值仍然准确，全国值改用 summary 的单次精确聚合。
	_partial = true
	var summary: Dictionary = facade.country_economy_overview(_country_handle, "summary")
	if not bool(summary.get("ok", false)):
		return {}
	_national_per_day = float(summary.get("revenue_per_day", 0)) \
		- float(summary.get("input_cost_per_day", 0)) \
		- float(summary.get("maintenance_per_day", 0))
	_national_population = int(summary.get("population", 0))
	_national_ytd += _national_per_day * float(delta)
	return {"ok": true}


# ── 读数 ────────────────────────────────────────────────────────────────

## 是否已经有可用读数（至少成功采样过一次）。
func ready() -> bool:
	return _has_sample


func year_index() -> int:
	return _year


func days_per_year() -> int:
	return _days_per_year


## 本年度已计入的累计天数（年初至今，含跨年截断）。
func days_counted() -> int:
	return maxi(0, _days_counted)


## 本年度起始日（第 0 天）。用于 tooltip 说明数据起算点。
func year_start_day() -> int:
	return _year * _days_per_year if _year >= 0 else -1


## 年初那段是否按当前速率回溯折算（读档、或面板中途打开）。
func backfilled() -> bool:
	return _first_sample_span > 1


## 分页未覆盖全部聚落，全国值来自 summary 而非逐格求和。
func partial() -> bool:
	return _partial


func national_ytd() -> float:
	return _national_ytd


func national_per_day() -> float:
	return _national_per_day


func national_population() -> int:
	return _national_population


func national_per_capita() -> float:
	if _national_population <= 0:
		return NAN
	return _national_ytd / float(_national_population)


func tracks_cell(cell: int) -> bool:
	if cell < 0 or cell >= _cell_count:
		return false
	return _cell_tracked[cell] != 0


func cell_ytd(cell: int) -> float:
	if cell < 0 or cell >= _cell_count:
		return -1.0
	return _cell_ytd[cell]


func cell_per_day(cell: int) -> float:
	if cell < 0 or cell >= _cell_count:
		return -1.0
	return _cell_per_day[cell]


func cell_population(cell: int) -> int:
	if cell < 0 or cell >= _cell_count:
		return 0
	return _cell_population[cell]


func cell_per_capita(cell: int) -> float:
	var population := cell_population(cell)
	if population <= 0:
		return NAN
	return _cell_ytd[cell] / float(population)


# ── 内部 ────────────────────────────────────────────────────────────────

func _reset_year_values() -> void:
	_cell_ytd.fill(0.0)
	_cell_per_day.fill(0.0)
	_cell_population.fill(0)
	_cell_tracked.fill(0)
	_cell_seen_round.fill(0)
	_tracked_cells = PackedInt32Array()
	_national_ytd = 0.0
	_national_per_day = 0.0
	_national_population = 0
	_partial = false
	_days_counted = 0
	_first_sample_span = 0
	_last_day = _year * _days_per_year if _year >= 0 else -1


func _resolve_days_per_year() -> int:
	if _world_clock != null and _world_clock.has_method("days_per_year"):
		return clampi(int(_world_clock.days_per_year()), 1, 3660)
	return 365


func _year_index_for_day(day_idx: int) -> int:
	if _world_clock != null and _world_clock.has_method("year_index_for_day"):
		return int(_world_clock.year_index_for_day(day_idx))
	return int(floor(float(day_idx) / float(_days_per_year)))


func _ensure_country() -> bool:
	if _country_resolved:
		return _country_handle > 0
	if _country_resolve_misses >= COUNTRY_RESOLVE_MISS_LIMIT:
		return false
	_country_resolve_misses += 1
	if _generator == null or not _generator.has_method("gameplay_start_report") \
			or not _generator.has_method("get_country_facade"):
		return false
	var report: Dictionary = _generator.gameplay_start_report()
	if not bool(report.get("ok", false)):
		return false
	var start_cell := int(report.get("cell", -1))
	if start_cell < 0:
		return false
	var facade = _generator.get_country_facade()
	if facade == null or not facade.has_method("cell_summary"):
		return false
	var summary: Dictionary = facade.cell_summary(start_cell)
	if not bool(summary.get("ok", false)) or not bool(summary.get("owned", false)):
		return false
	_country_handle = int(summary.get("country_handle", -1))
	_country_resolved = _country_handle > 0
	return _country_resolved


func _ensure_capacity() -> bool:
	var count := 0
	if _map != null and _map.has_method("cell_count"):
		count = int(_map.cell_count())
	if count <= 0:
		return false
	if _cell_ytd.size() == count:
		return true
	_cell_count = count
	_cell_ytd = PackedFloat64Array()
	_cell_ytd.resize(count)
	_cell_ytd.fill(0.0)
	_cell_per_day = PackedFloat64Array()
	_cell_per_day.resize(count)
	_cell_per_day.fill(0.0)
	_cell_population = PackedInt64Array()
	_cell_population.resize(count)
	_cell_population.fill(0)
	_cell_tracked = PackedByteArray()
	_cell_tracked.resize(count)
	_cell_tracked.fill(0)
	_cell_seen_round = PackedByteArray()
	_cell_seen_round.resize(count)
	_cell_seen_round.fill(0)
	return true
