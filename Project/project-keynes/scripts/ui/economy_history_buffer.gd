extends RefCounted
class_name EconomyHistoryBuffer

## 国民经济卷宗的会话内趋势缓冲。每个已提交经济日最多采样一次，
## 只保留最近 CAPACITY 个点；不写入存档，换国家或重开会话即清空。

const CAPACITY := 120
const KPI_KEYS: Array[String] = [
	"population", "income_per_day", "expense_per_day", "employment_rate",
	"satisfaction", "treasury", "revenue_per_day", "utilization",
	"tax_per_day", "job_openings", "suspended_units", "pending_units",
	"wage_arrears_per_day",
]
## 阶层与职业共用同一组序列键：展示层要的是「满意度怎么变」「人均收入怎么变」。
const STRATUM_KEYS: Array[String] = ["satisfaction", "income_per_capita", "population"]

var _country_handle := 0
var _days := PackedInt32Array()
var _series: Dictionary = {}
## 分组序列：`s:<阶层下标>` 与 `p:<职业稳定 id>` 都落在这里，值都是 {key: PackedFloat32Array}。
var _group_series: Dictionary = {}


func reset(country_handle: int = 0) -> void:
	_country_handle = country_handle
	_days = PackedInt32Array()
	_series.clear()
	_group_series.clear()


func country_handle() -> int:
	return _country_handle


func size() -> int:
	return _days.size()


func latest_day() -> int:
	return _days[_days.size() - 1] if not _days.is_empty() else -1


## 查询原生聚合并记录一个点。同一已提交日重复调用会被忽略；
## 经济线程忙（只读视图未发布）时返回 false，下一次提交再采样。
func sample(economy_facade, country_handle_value: int, treasury_cash: int,
		strata_table: SocialStrataTable) -> bool:
	if economy_facade == null or country_handle_value <= 0 \
			or not economy_facade.has_method("country_economy_overview"):
		return false
	if country_handle_value != _country_handle:
		reset(country_handle_value)
	var summary: Dictionary = economy_facade.country_economy_overview(
		country_handle_value, "summary")
	if not bool(summary.get("ok", false)):
		return false
	var day := int(summary.get("sample_day", -1))
	if day < 0 or day == latest_day():
		return false
	var professions: Dictionary = economy_facade.country_economy_overview(
		country_handle_value, "professions")
	var strata: Array = EconomyDossierViewModel.aggregate_strata(professions, strata_table) \
		if bool(professions.get("ok", false)) and strata_table != null else []
	var profession_rows: Array = EconomyDossierViewModel.profession_rows(
		professions, strata_table) if bool(professions.get("ok", false)) \
		and strata_table != null else []
	record(day, kpi_values(summary, treasury_cash), strata, profession_rows)
	return true


static func kpi_values(summary: Dictionary, treasury_cash: int) -> Dictionary:
	var population := float(summary.get("population", 0))
	var employed := float(summary.get("owner_employed", 0)) \
		+ float(summary.get("employee_employed", 0))
	return {
		"population": population,
		"income_per_day": float(summary.get("income_per_day", 0)),
		"expense_per_day": float(summary.get("expense_per_day", 0)),
		"employment_rate": employed / population if population > 0.0 else 0.0,
		"satisfaction": float(summary.get("satisfaction_q16", 0)) / 65536.0,
		"treasury": float(treasury_cash),
		"revenue_per_day": float(summary.get("revenue_per_day", 0)),
		"utilization": float(summary.get("utilization_q16", 0)) / 65536.0,
		"tax_per_day": float(summary.get("tax_per_day", 0)),
		"job_openings": float(summary.get("job_openings", 0)),
		"suspended_units": float(summary.get("building_suspended_units", 0)),
		"pending_units": float(summary.get("pending_construction_units", 0)),
		"wage_arrears_per_day": maxf(0.0, float(summary.get("wages_due_per_day", 0))
			- float(summary.get("wages_paid_per_day", 0))),
	}


## strata：aggregate_strata() 的结果数组，按阶层下标对齐。
## professions：profession_rows() 的结果数组，按职业稳定 id 对齐（可缺省）。
func record(day: int, kpis: Dictionary, strata: Array = [],
		professions: Array = []) -> void:
	if not _days.is_empty() and day <= latest_day():
		return
	_days.append(day)
	for key in KPI_KEYS:
		var values: PackedFloat32Array = _series.get(key, PackedFloat32Array())
		values.append(float(kpis.get(key, 0.0)))
		_series[key] = values
	for index in range(strata.size()):
		_record_group("s:%d" % index, strata[index])
	for row in professions:
		_record_group("p:%s" % String((row as Dictionary).get("id", "")), row)
	_trim()


## 一组序列按「已提交日」对齐：中途才出现的职业用 NAN 补齐前缀，
## 这样画出来的趋势线不会把「刚出现的职业」冒充成「一直很高」。
func _record_group(group_key: String, row: Dictionary) -> void:
	var bucket: Dictionary = _group_series.get(group_key, {})
	for key in STRATUM_KEYS:
		var values: PackedFloat32Array = bucket.get(key, PackedFloat32Array())
		while values.size() < _days.size() - 1:
			values.append(NAN)
		values.append(float(row.get(key, 0.0)))
		bucket[key] = values
	_group_series[group_key] = bucket


func days() -> PackedInt32Array:
	return _days


func series(key: String) -> PackedFloat32Array:
	return _series.get(key, PackedFloat32Array())


func stratum_series(stratum_index: int, key: String) -> PackedFloat32Array:
	return group_series("s:%d" % stratum_index, key)


func profession_series(profession_id: String, key: String) -> PackedFloat32Array:
	return group_series("p:" + profession_id, key)


func group_series(group_key: String, key: String) -> PackedFloat32Array:
	return (_group_series.get(group_key, {}) as Dictionary).get(key, PackedFloat32Array())


## 与最近一次之前的样本相比的变化量；样本不足返回 NAN。
func delta(key: String, lookback: int = 1) -> float:
	var values := series(key)
	if values.size() <= lookback:
		return NAN
	return values[values.size() - 1] - values[values.size() - 1 - lookback]


func _trim() -> void:
	var overflow := _days.size() - CAPACITY
	if overflow <= 0:
		return
	_days = _days.slice(overflow)
	for key in _series.keys():
		_series[key] = (_series[key] as PackedFloat32Array).slice(overflow)
	for group_key in _group_series.keys():
		var bucket: Dictionary = _group_series[group_key]
		for key in bucket.keys():
			var values: PackedFloat32Array = bucket[key]
			bucket[key] = values.slice(maxi(0, values.size() - _days.size()))
