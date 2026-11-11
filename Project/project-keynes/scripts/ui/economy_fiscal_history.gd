extends RefCounted
class_name EconomyFiscalHistory

## 国库收支的会话内趋势。只在已提交日采样一次，不写存档，
## 与 EconomyGdpLedger 共用同一套「每个已提交日一个点」的契约。
##
## 这里同时保留两份数据：
## - 逐已提交日国库现金：用来取得窗口内真实的现金净变化；
## - 按财政 sample_day 去重的结算事件：用来拆分税种与非税支出。
##
## 不能把逐日展示序列直接求和：未结算日会沿用上一次结算值，把它当作当天
## 流水累加会重复计账。滚动窗口只汇总窗口内真实发生过的结算事件，再用国库
## 现金首尾差校准；差额由展示层单列为「其他国库变动」。

const CAPACITY := 60
const DEFAULT_WINDOW_DAYS := 30
const TAX_KINDS := ["income", "consumption", "business", "import", "export"]
const OTHER_TREASURY_CHANGE_ID := "other_treasury_change"
const OTHER_TREASURY_CHANGE_LABEL := "其他国库变动"

var _country_handle := 0
var _days := PackedInt32Array()
var _income := PackedFloat32Array()
var _expense := PackedFloat32Array()
var _cash_days := PackedInt32Array()
var _cash_values := PackedInt64Array()
var _settlement_days := PackedInt32Array()
var _settlements: Array = []
var _last_settlement: Dictionary = {}


func reset(country_handle: int = 0) -> void:
	_country_handle = country_handle
	_days = PackedInt32Array()
	_income = PackedFloat32Array()
	_expense = PackedFloat32Array()
	_cash_days = PackedInt32Array()
	_cash_values = PackedInt64Array()
	_settlement_days = PackedInt32Array()
	_settlements.clear()
	_last_settlement = {}


func country_handle() -> int:
	return _country_handle


func size() -> int:
	return _days.size()


func latest_day() -> int:
	return _days[_days.size() - 1] if not _days.is_empty() else -1


func latest_cash_day() -> int:
	return _cash_days[_cash_days.size() - 1] if not _cash_days.is_empty() else -1


func cash_size() -> int:
	return _cash_days.size()


func settlement_size() -> int:
	return _settlement_days.size()


## 金额单位与原生一致（1/10000 货币）。
##
## `committed_day` 让没有财政结算的日子也能留下国库现金样本；它与
## `fiscal.sample_day` 分开，避免把「最近一次结算日」误当成「今天」。
## 旧调用只传两个参数时仍按财政 sample_day 采样，保持兼容。
func sample(country_handle_value: int, fiscal: Dictionary, treasury_cash: int = -1,
		committed_day: int = -1) -> bool:
	if country_handle_value <= 0:
		return false
	if country_handle_value != _country_handle:
		reset(country_handle_value)
	var fiscal_owner := int(fiscal.get("country_handle", country_handle_value))
	var fiscal_ok := bool(fiscal.get("ok", false)) and not fiscal.is_empty() \
		and fiscal_owner == country_handle_value
	var event_day := int(fiscal.get("sample_day", -1)) if fiscal_ok else -1
	var sample_day := committed_day if committed_day >= 0 else event_day
	if sample_day < 0:
		return false
	var changed := false
	if fiscal_ok:
		if _record_settlement(event_day, fiscal):
			changed = true
		if _record_display_sample(sample_day, fiscal):
			changed = true
	if treasury_cash >= 0 and _record_cash_sample(sample_day, treasury_cash):
		changed = true
	return changed


## 保留原结算日期，让玩家知道当前展示的是哪次结算。
func display_snapshot(fiscal: Dictionary) -> Dictionary:
	if int(fiscal.get("country_handle", _country_handle)) != _country_handle:
		return fiscal
	if not _last_settlement.is_empty() and (
			not bool(fiscal.get("ok", false)) or (
			not bool(fiscal.get("has_settlement", true)) and not _has_cashflow(fiscal))):
		var held := _last_settlement.duplicate(true)
		held["carried_forward"] = true
		return held
	return fiscal


## 返回滚动窗口的原始聚合值，不做货币单位换算或文字格式化。
## 只有拿到至少两个不同日期的现金样本时才成功；历史不足时由展示层回退到
## 当前财政快照，不能用一条样本伪造整段窗口。
func rolling_snapshot(window_days: int) -> Dictionary:
	var window := clampi(window_days, 1, CAPACITY)
	var cash_latest := latest_cash_day()
	var display_latest := latest_day()
	if cash_latest < 0:
		return _rolling_failure(window, display_latest, "cash_history_unavailable")
	if display_latest >= 0 and cash_latest < display_latest:
		return _rolling_failure(window, display_latest, "cash_history_incomplete")
	var end_index := _cash_days.size() - 1
	var end_day := cash_latest
	var window_start := end_day - window + 1
	var first_cash_day := int(_cash_days[0])
	var wanted_baseline_day := maxi(first_cash_day, window_start - 1)
	var baseline_index := _cash_index_at_or_before(wanted_baseline_day)
	if baseline_index < 0:
		baseline_index = 0
	# 中间缺样本时不要跨过缺口去要一个更长的窗口；改用窗口内第一份样本，
	# 宁可显示较短的「实际 N 日」，也不把 35 天的变化冒充近 30 日。
	if int(_cash_days[baseline_index]) < wanted_baseline_day:
		var next_index := _cash_index_at_or_after(wanted_baseline_day)
		if next_index >= 0 and next_index < end_index:
			baseline_index = next_index
	if baseline_index >= end_index:
		return _rolling_failure(window, end_day, "cash_history_span_insufficient")
	var baseline_day := int(_cash_days[baseline_index])
	var covered_days := end_day - baseline_day
	if covered_days <= 0:
		return _rolling_failure(window, end_day, "cash_history_span_insufficient")
	var collected := _zero_tax_values()
	var paid := _zero_tax_values()
	var requested := _zero_tax_values()
	var bases := _zero_tax_values()
	var non_tax_ids := PackedStringArray()
	var non_tax_totals: Dictionary = {}
	var event_days := 0
	for event_index in range(_settlement_days.size()):
		var event_day := int(_settlement_days[event_index])
		if event_day <= baseline_day or event_day > end_day:
			continue
		event_days += 1
		var event: Dictionary = _settlements[event_index]
		var event_kinds = event.get("tax_kinds", PackedStringArray())
		for slot in range(TAX_KINDS.size()):
			var source := _kind_index(event_kinds, String(TAX_KINDS[slot]))
			if source < 0:
				continue
			collected[slot] += int(_at(event.get("collected", PackedInt64Array()), source))
			paid[slot] += int(_at(event.get("subsidy_paid", PackedInt64Array()), source))
			requested[slot] += int(_at(
				event.get("subsidy_requested", PackedInt64Array()), source))
			bases[slot] += int(_at(event.get("tax_base", PackedInt64Array()), source))
		var outflow_kinds = event.get("non_tax_outflow_kinds", PackedStringArray())
		var outflows = event.get("non_tax_outflow", PackedInt64Array())
		for index in range(maxi(outflow_kinds.size(), outflows.size())):
			var kind_id := String(outflow_kinds[index]) if index < outflow_kinds.size() \
				else "non_tax_%d" % index
			if kind_id.is_empty():
				kind_id = "non_tax_%d" % index
			if not non_tax_totals.has(kind_id):
				non_tax_ids.append(kind_id)
				non_tax_totals[kind_id] = 0
			non_tax_totals[kind_id] = int(non_tax_totals[kind_id]) + int(_at(outflows, index))
	var non_tax_values := PackedInt64Array()
	for kind_id in non_tax_ids:
		non_tax_values.append(int(non_tax_totals.get(kind_id, 0)))
	var cash_change := int(_cash_values[end_index]) - int(_cash_values[baseline_index])
	var classified_net := _sum_values(collected) - _sum_values(paid) \
		- _sum_values(non_tax_values)
	return {
		"ok": true,
		"country_handle": _country_handle,
		"window_days": window,
		"covered_days": covered_days,
		"event_days": event_days,
		"is_partial": covered_days < window,
		"sample_day": end_day,
		"start_day": baseline_day + 1,
		"end_day": end_day,
		"baseline_day": baseline_day,
		"cash_change": cash_change,
		"classified_net": classified_net,
		"unclassified_change": cash_change - classified_net,
		"tax_kinds": PackedStringArray(TAX_KINDS),
		"tax_base": bases,
		"collected": collected,
		"subsidy_requested": requested,
		"subsidy_paid": paid,
		"non_tax_outflow_kinds": non_tax_ids,
		"non_tax_outflow": non_tax_values,
	}


func days() -> PackedInt32Array:
	return _days


func income_series() -> PackedFloat32Array:
	return _income


func expense_series() -> PackedFloat32Array:
	return _expense


func _rolling_failure(window_days: int, latest: int, reason: String) -> Dictionary:
	return {
		"ok": false,
		"reason": reason,
		"window_days": window_days,
		"covered_days": 0,
		"event_days": 0,
		"is_partial": true,
		"sample_day": latest,
	}


func _record_settlement(event_day: int, fiscal: Dictionary) -> bool:
	if event_day < 0:
		return false
	if not bool(fiscal.get("has_settlement", true)) and not _has_cashflow(fiscal):
		return false
	var event := {
		"tax_kinds": fiscal.get("tax_kinds", PackedStringArray(TAX_KINDS)),
		"tax_base": fiscal.get("tax_base", PackedInt64Array()),
		"collected": fiscal.get("collected", PackedInt64Array()),
		"subsidy_requested": fiscal.get("subsidy_requested", PackedInt64Array()),
		"subsidy_paid": fiscal.get("subsidy_paid", PackedInt64Array()),
		"non_tax_outflow_kinds": fiscal.get(
			"non_tax_outflow_kinds", PackedStringArray()),
		"non_tax_outflow": fiscal.get("non_tax_outflow", PackedInt64Array()),
	}
	var last_day := -1
	if not _settlement_days.is_empty():
		last_day = int(_settlement_days[_settlement_days.size() - 1])
	if event_day < last_day:
		# 结算日由权威快照给出，正常只会单调前进；迟到旧事件不能插进序列中间。
		return false
	if event_day == last_day:
		var last_index := _settlement_days.size() - 1
		_settlements[last_index] = event
		_last_settlement = fiscal.duplicate(true)
		return false
	_settlement_days.append(event_day)
	_settlements.append(event)
	_last_settlement = fiscal.duplicate(true)
	while _settlement_days.size() > CAPACITY:
		_settlement_days.remove_at(0)
		_settlements.remove_at(0)
	return true


func _record_display_sample(day: int, fiscal: Dictionary) -> bool:
	if day < 0 or day <= latest_day():
		return false
	var display := display_snapshot(fiscal)
	_days.append(day)
	_income.append(_total(display.get("collected", PackedInt64Array())))
	# 支出一侧 = 五类税种补贴实付 + 全部非税国库支出（科研采购、开拓采购、
	# 工程与运河的缺料付款）。趋势与堆叠条同用最近结算口径。
	_expense.append(_total(display.get("subsidy_paid", PackedInt64Array()))
		+ _total(display.get("non_tax_outflow", PackedInt64Array())))
	while _days.size() > CAPACITY:
		_days.remove_at(0)
		_income.remove_at(0)
		_expense.remove_at(0)
	return true


func _record_cash_sample(day: int, treasury_cash: int) -> bool:
	if day < 0:
		return false
	var latest := latest_cash_day()
	if day < latest:
		return false
	if day == latest:
		_cash_values[_cash_values.size() - 1] = treasury_cash
		return false
	_cash_days.append(day)
	_cash_values.append(treasury_cash)
	while _cash_days.size() > CAPACITY:
		_cash_days.remove_at(0)
		_cash_values.remove_at(0)
	var cutoff := day - CAPACITY
	while not _settlement_days.is_empty() and int(_settlement_days[0]) < cutoff:
		_settlement_days.remove_at(0)
		_settlements.remove_at(0)
	return true


func _cash_index_at_or_before(day: int) -> int:
	var low := 0
	var high := _cash_days.size() - 1
	var found := -1
	while low <= high:
		var middle := (low + high) >> 1
		if int(_cash_days[middle]) <= day:
			found = middle
			low = middle + 1
		else:
			high = middle - 1
	return found


func _cash_index_at_or_after(day: int) -> int:
	var low := 0
	var high := _cash_days.size() - 1
	var found := -1
	while low <= high:
		var middle := (low + high) >> 1
		if int(_cash_days[middle]) >= day:
			found = middle
			high = middle - 1
		else:
			low = middle + 1
	return found


static func _kind_index(kinds, kind_id: String) -> int:
	for index in range(kinds.size()):
		if String(kinds[index]) == kind_id:
			return index
	return -1


static func _zero_tax_values() -> PackedInt64Array:
	return PackedInt64Array([0, 0, 0, 0, 0])


static func _has_cashflow(fiscal: Dictionary) -> bool:
	return _total(fiscal.get("collected", PackedInt64Array())) != 0.0 \
		or _total(fiscal.get("subsidy_paid", PackedInt64Array())) != 0.0 \
		or _total(fiscal.get("non_tax_outflow", PackedInt64Array())) != 0.0


static func _sum_values(values) -> int:
	var sum := 0
	for value in values:
		sum += int(value)
	return sum


static func _at(values, index: int) -> float:
	if values == null or index < 0 or index >= values.size():
		return 0.0
	return float(values[index])


static func _total(values) -> float:
	var sum := 0.0
	for value in values:
		sum += float(value)
	return sum
