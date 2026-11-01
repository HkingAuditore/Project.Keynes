extends RefCounted
class_name EconomyFiscalHistory

## 国库收支的会话内趋势。只在已提交日采样一次，不写存档，
## 与 EconomyGdpLedger 共用同一套「每个已提交日一个点」的契约。
##
## 展示最近一次结算：未结算日沿用前值，真实零结算照常更新。
## 此序列仅用于展示，不能作为累计财政流水求和。

const CAPACITY := 60

var _country_handle := 0
var _days := PackedInt32Array()
var _income := PackedFloat32Array()
var _expense := PackedFloat32Array()
var _last_settlement: Dictionary = {}


func reset(country_handle: int = 0) -> void:
	_country_handle = country_handle
	_days = PackedInt32Array()
	_income = PackedFloat32Array()
	_expense = PackedFloat32Array()
	_last_settlement = {}


func country_handle() -> int:
	return _country_handle


func size() -> int:
	return _days.size()


func latest_day() -> int:
	return _days[_days.size() - 1] if not _days.is_empty() else -1


## 金额单位与原生一致（1/10000 货币）。同一已提交日重复调用会被忽略，
## 财政快照尚未发布（ok=false）时也不记点，避免把「读不到」画成零收支。
func sample(country_handle_value: int, fiscal: Dictionary) -> bool:
	if country_handle_value <= 0 or not bool(fiscal.get("ok", false)):
		return false
	if country_handle_value != _country_handle:
		reset(country_handle_value)
	var day := int(fiscal.get("sample_day", -1))
	if day < 0 or day <= latest_day():
		return false
	# 非税采购和跨格税款也可能发生在本国地块未结算的日子。
	# 有真实现金事件时必须展示，不能被沿用值盖掉。
	if bool(fiscal.get("has_settlement", true)) or _has_cashflow(fiscal):
		_last_settlement = fiscal.duplicate(true)
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


static func _has_cashflow(fiscal: Dictionary) -> bool:
	return _total(fiscal.get("collected", PackedInt64Array())) != 0.0 \
		or _total(fiscal.get("subsidy_paid", PackedInt64Array())) != 0.0 \
		or _total(fiscal.get("non_tax_outflow", PackedInt64Array())) != 0.0


func days() -> PackedInt32Array:
	return _days


func income_series() -> PackedFloat32Array:
	return _income


func expense_series() -> PackedFloat32Array:
	return _expense


static func _total(values) -> float:
	var sum := 0.0
	for value in values:
		sum += float(value)
	return sum
