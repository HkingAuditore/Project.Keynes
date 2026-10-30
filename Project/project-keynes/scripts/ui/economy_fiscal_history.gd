extends RefCounted
class_name EconomyFiscalHistory

## 国库收支的会话内趋势。只在已提交日采样一次，不写存档，
## 与 EconomyGdpLedger 共用同一套「每个已提交日一个点」的契约。
##
## 只读财政快照里的两个合计（五类税种实收 / 五类税种实付补贴），
## 不做逐格聚合：这是给折线看方向的，明细由当批快照负责。

const CAPACITY := 60

var _country_handle := 0
var _days := PackedInt32Array()
var _income := PackedFloat32Array()
var _expense := PackedFloat32Array()


func reset(country_handle: int = 0) -> void:
	_country_handle = country_handle
	_days = PackedInt32Array()
	_income = PackedFloat32Array()
	_expense = PackedFloat32Array()


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
	_days.append(day)
	_income.append(_total(fiscal.get("collected", PackedInt64Array())))
	# 支出一侧 = 五类税种补贴实付 + 全部非税国库支出（科研采购、开拓采购、
	# 工程与运河的缺料付款）。同口径才能让折线与堆叠条、与国库现金的实际变化对齐。
	_expense.append(_total(fiscal.get("subsidy_paid", PackedInt64Array()))
		+ _total(fiscal.get("non_tax_outflow", PackedInt64Array())))
	while _days.size() > CAPACITY:
		_days.remove_at(0)
		_income.remove_at(0)
		_expense.remove_at(0)
	return true


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
