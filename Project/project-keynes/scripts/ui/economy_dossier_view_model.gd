extends RefCounted
class_name EconomyDossierViewModel

## 国民经济卷宗的展示模型。只读消费 EconomyFacade.country_economy_overview
## 与国家壳模型（国库、财政、贸易摘要），把原生列式结果整理成各章所需的
## 行与图表数据。卡点归类是纯展示启发式，结果不回写任何模拟状态。

const MONEY_SCALE := 10000.0
const Q16 := 65536.0

const CHAPTERS: Array[Dictionary] = [
	{"id": "overview", "label": "总览", "icon": &"summary.overview",
		"question": "经济是否健康？哪里在出问题？"},
	{"id": "strata", "label": "阶层民生", "icon": &"population.heart",
		"question": "谁过得好、谁过得差，为什么？"},
	{"id": "industry", "label": "产业建筑", "icon": &"economy.building.factory",
		"question": "哪些产业在赚钱、哪些在停工？"},
	{"id": "investment", "label": "投资风向", "icon": &"trend.up",
		"question": "资本正流向哪里，又被什么挡住了？"},
	{"id": "market", "label": "物资市场", "icon": &"metric.goods",
		"question": "什么东西缺、什么东西过剩？"},
	{"id": "trade", "label": "贸易", "icon": &"tax.tariff",
		"question": "靠什么进口、靠什么出口？"},
	{"id": "cities", "label": "城市", "icon": &"metric.territory",
		"question": "各城市之间差距多大？"},
	{"id": "finance", "label": "财政", "icon": &"metric.treasury",
		"question": "国库与税制"},
]

const SECTORS: Array[Dictionary] = [
	{"id": 0, "name": "农业", "icon": &"economy.building.farm", "color": Color(0.34, 0.48, 0.31)},
	{"id": 1, "name": "采掘", "icon": &"economy.building.mine", "color": Color(0.45, 0.36, 0.27)},
	{"id": 2, "name": "制造", "icon": &"economy.building.factory", "color": Color(0.62, 0.36, 0.19)},
	{"id": 3, "name": "能源", "icon": &"economy.building.power", "color": Color(0.69, 0.49, 0.24)},
	{"id": 4, "name": "知识", "icon": &"economy.building.science", "color": Color(0.31, 0.43, 0.53)},
]

const SATISFACTION_DIMENSIONS: Array[String] = [
	"温饱", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展"]
## 前四维是按需求档的满足率，后四维是生活水平。
const CONSUMPTION_TIER_COUNT := 4

const BOTTLENECK_ORDER: Array[String] = [
	"demand", "input", "capital", "labor", "resource", "margin"]
const BOTTLENECK_META := {
	"demand": {"label": "需求不足 / 滞销", "icon": &"trend.down", "chapter": "market",
		"advice": "产出卖不出去或被丢弃，扩产前先打开销路"},
	"input": {"label": "原料断供", "icon": &"status.warning", "chapter": "market",
		"advice": "上游投入或建材短缺，制约生产与新建"},
	"capital": {"label": "资金不足", "icon": &"metric.treasury", "chapter": "industry",
		"advice": "投资方缺钱或企业欠薪"},
	"labor": {"label": "劳动力不足", "icon": &"population.profession.worker", "chapter": "strata",
		"advice": "岗位空缺无人填补"},
	"resource": {"label": "资源 / 气候受限", "icon": &"economy.resource", "chapter": "industry",
		"advice": "资源条件不足或气候损失产出"},
	"margin": {"label": "利润过低", "icon": &"trend.flat", "chapter": "investment",
		"advice": "营收不抵成本，资本不愿进入"},
}
## INVESTMENT_REJECTION_* 下标 → 卡点类别；空串表示不是卡点（在建、产能已足够、随机未中等）。
const REJECTION_CATEGORY: Array[String] = [
	"", "", "margin", "labor", "", "margin", "demand", "demand", "input",
	"margin", "margin", "capital", "input", "resource", "", "demand", "", "", "margin"]
const REJECTION_LABELS: Array[String] = [
	"无", "已有在建", "停业产能待恢复", "现有岗位空缺", "产能已足够",
	"营收不抵成本", "销路不畅", "产出遭丢弃", "上游投入不足", "利润率不达标",
	"回本期过长", "投资方资金不足", "建材短缺", "资源不足", "随机未中",
	"缺少市场信号", "增长上限", "不支持的类型", "缺少成本优势"]
const REJECTION_SUFFICIENT := 4
const MAX_BOTTLENECKS := 4
const SHORTAGE_ALERT := 0.25

## 物资分组按 GoodProfile.technology_tags 中的 industry.* 标签。
const GOOD_GROUPS: Array[Dictionary] = [
	{"id": "primary", "name": "原料", "tags": ["industry.primary"]},
	{"id": "food", "name": "食品", "tags": ["industry.food"]},
	{"id": "textile", "name": "纺织", "tags": ["industry.textile"]},
	{"id": "construction", "name": "建材", "tags": ["industry.construction", "industry.forestry"]},
	{"id": "metals", "name": "金属", "tags": ["industry.metals", "industry.tools"]},
	{"id": "chemicals", "name": "化工能源", "tags": ["industry.chemicals", "industry.energy"]},
	{"id": "machinery", "name": "机械电子", "tags": ["industry.machinery"]},
	{"id": "consumer", "name": "消费与其他", "tags": ["industry.consumer"]},
]

static var _good_group_cache: Dictionary = {}

var scope_cell := -1
var _model: Dictionary = {}
var _facade = null
var _country_handle := 0
var _history: EconomyHistoryBuffer = null
var _strata: SocialStrataTable = null
var _memo: Dictionary = {}
var _last_good: Dictionary = {}
var _pending_seen := false


func _init(strata_table: SocialStrataTable = null) -> void:
	_strata = strata_table if strata_table != null else SocialStrataTable.load_default()


func configure(model: Dictionary, history: EconomyHistoryBuffer = null) -> void:
	_model = model
	var facade = model.get("economy_facade", null)
	var handle := int(model.get("country_handle", 0))
	if facade != _facade or handle != _country_handle:
		_last_good.clear()
	_facade = facade
	_country_handle = handle
	if history != null:
		_history = history
	_memo.clear()


func strata_table() -> SocialStrataTable:
	return _strata


func history() -> EconomyHistoryBuffer:
	return _history


func shell_model() -> Dictionary:
	return _model


func available() -> bool:
	return bool(_model.get("available", false)) and _facade != null \
		and _country_handle > 0 and _facade.has_method("country_economy_overview")


func unavailable_reason() -> String:
	if not bool(_model.get("available", false)):
		return String(_model.get("reason", "国家档案暂不可用"))
	return "国民经济聚合暂不可用"


## 每次实时刷新前清空本轮查询缓存；同一轮里各区块共享同一份原生结果。
func begin_refresh() -> void:
	_memo.clear()
	_pending_seen = false


## 本轮是否有查询撞上经济结算（原生只读视图尚未就绪）；外壳据此短延迟重试。
func had_pending() -> bool:
	return _pending_seen


## 结算进行中时沿用该查询上一次成功的结果，避免整页闪回“结算进行中”。
func query(view: String, filter_id: int = -1, offset: int = 0, limit: int = 0,
		scope_override: int = -2) -> Dictionary:
	if not available():
		return {"ok": false, "reason": unavailable_reason()}
	var scope := scope_cell if scope_override == -2 else scope_override
	var key := "%s|%d|%d|%d|%d" % [view, scope, filter_id, offset, limit]
	if _memo.has(key):
		return _memo[key]
	var result: Dictionary = _facade.country_economy_overview(
		_country_handle, view, scope, filter_id, offset, limit)
	if bool(result.get("ok", false)):
		_last_good[key] = result
	elif is_pending(result):
		_pending_seen = true
		if _last_good.has(key):
			result = _last_good[key]
	_memo[key] = result
	return result


static func is_pending(page: Dictionary) -> bool:
	return bool(page.get("busy", false)) or bool(page.get("read_view_pending", false)) \
		or String(page.get("reason", "")) in ["read_view_pending", "economy_read_view_pending"]


func scope_label() -> String:
	if scope_cell < 0:
		return "全国"
	return _settlement_name(scope_cell)


## 范围下拉：全国 + 按人口排序的已命名城市；未命名村落不进下拉，
## 但仍可从城市章或地图选中格进入单格范围。
func scope_options() -> Array:
	var options: Array = [{"cell": -1, "label": "全国"}]
	var page := query("settlements", -1, 0, 0, -1)
	if not bool(page.get("ok", false)):
		return options
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	var named = page.get("name_active", PackedByteArray())
	for row in range(cells.size()):
		if row < named.size() and int(named[row]) != 0:
			options.append({"cell": int(cells[row]), "label": String(names[row])})
	if scope_cell >= 0 and not options.any(func(o): return int(o.cell) == scope_cell):
		options.append({"cell": scope_cell, "label": _settlement_name(scope_cell)})
	return options


# ── 页头 KPI ────────────────────────────────────────────────────────────

func kpis() -> Array:
	var summary := query("summary")
	if not bool(summary.get("ok", false)):
		return []
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := int(treasury.get("cash", _model.get("cash", 0)))
	var values := EconomyHistoryBuffer.kpi_values(summary, cash)
	var national := scope_cell < 0
	return [
		_kpi("population", "人口", values.population, "count", true,
			"%d 个聚落" % int(summary.get("populated_cell_count", 0)), &"family.metric.population"),
		_kpi("income_per_day", "居民收入 / 日", values.income_per_day / MONEY_SCALE, "money",
			true, "人均 %s" % _money_text(_per_capita(values.income_per_day, values.population)),
			&"family.metric.wealth"),
		_kpi("employment_rate", "就业率", values.employment_rate, "percent", true,
			"空缺岗位 %s" % UITokens.format_compact_number_cn(values.job_openings, 1),
			&"population.profession.worker"),
		_kpi("satisfaction", "综合满意度", values.satisfaction, "percent", true,
			"温饱满足 %s" % _percent_text(float(summary.get("survival_satisfaction_q16", 0)) / Q16),
			&"population.heart"),
		_kpi("treasury", "国库" if national else "产值 / 日",
			values.treasury / MONEY_SCALE if national else values.revenue_per_day / MONEY_SCALE,
			"money", true,
			"税收 %s / 日" % _money_text(values.tax_per_day) if national
				else "利用率 %s" % _percent_text(values.utilization),
			&"metric.treasury" if national else &"family.metric.buildings",
			"treasury" if national else "revenue_per_day"),
	]


func _kpi(id: String, title: String, value: float, kind: String, positive_good: bool,
		caption: String, icon: StringName, history_key: String = "") -> Dictionary:
	var key := id if history_key.is_empty() else history_key
	var spark := PackedFloat32Array()
	var delta := NAN
	# 趋势缓冲只记录全国口径；单城市范围下不画全国曲线以免误读。
	if _history != null and scope_cell < 0:
		spark = _history.series(key)
		delta = _history.delta(key, mini(7, maxi(1, spark.size() - 1)))
		if kind == "money":
			delta /= MONEY_SCALE
	return {"id": id, "title": title, "value": value, "kind": kind,
		"positive_good": positive_good, "caption": caption, "icon": icon,
		"spark": spark, "delta": delta}


# ── 总览 ────────────────────────────────────────────────────────────────

func overview_model() -> Dictionary:
	var summary := query("summary")
	if not bool(summary.get("ok", false)):
		return {"ok": false, "reason": _reason(summary)}
	var professions := query("professions")
	var goods := query("goods")
	var investment := query("investment")
	var income := float(summary.get("income_per_day", 0))
	var wages := minf(float(summary.get("wages_paid_per_day", 0)), income)
	var subsidy := float(summary.get("subsidy_per_day", 0))
	var in_kind := float(summary.get("in_kind_income_per_day", 0))
	var other_income := maxf(0.0, income - wages - subsidy)
	var expense := float(summary.get("expense_per_day", 0))
	var tax := float(summary.get("tax_per_day", 0))
	var strata := aggregate_strata(professions, _strata) \
		if bool(professions.get("ok", false)) else []
	return {
		"ok": true,
		"income_segments": [
			_segment("工资", wages, UITokens.FAMILY_GREEN),
			_segment("经营与其他", other_income, UITokens.FAMILY_BRASS),
			_segment("补贴", subsidy, UITokens.FAMILY_BLUE),
			_segment("实物", in_kind, Color(0.55, 0.47, 0.36)),
		],
		"expense_segments": [
			_segment("消费与其他", maxf(0.0, expense - tax), UITokens.FAMILY_BRASS),
			_segment("税", tax, UITokens.FAMILY_OXBLOOD),
			_segment("结余", maxf(0.0, income - expense), UITokens.FAMILY_GREEN),
		],
		"income_total": income / MONEY_SCALE,
		"expense_total": expense / MONEY_SCALE,
		"strata": strata,
		"bottlenecks": classify_bottlenecks(summary, investment, goods),
		"sectors": sector_rows(summary),
		"shortages": top_shortages(goods, 5),
		"state_day_min": int(summary.get("state_day_min", -1)),
		"state_day_max": int(summary.get("state_day_max", -1)),
	}


func _segment(label: String, value_raw: float, color: Color) -> Dictionary:
	return {"label": label, "value": value_raw / MONEY_SCALE, "color": color,
		"text": _money_text(value_raw)}


static func sector_rows(summary: Dictionary) -> Array:
	var rows: Array = []
	var units = summary.get("sector_units", PackedInt64Array())
	var suspended = summary.get("sector_suspended_units", PackedInt64Array())
	var revenue = summary.get("sector_revenue_per_day", PackedInt64Array())
	var cost = summary.get("sector_cost_per_day", PackedInt64Array())
	var wages = summary.get("sector_wages_per_day", PackedInt64Array())
	var jobs_required = summary.get("sector_jobs_required", PackedInt64Array())
	var jobs_filled = summary.get("sector_jobs_filled", PackedInt64Array())
	var pending = summary.get("sector_pending_units", PackedInt64Array())
	var utilization = summary.get("sector_utilization_q16", PackedInt32Array())
	for sector in SECTORS:
		var index := int(sector.id)
		var required := _at(jobs_required, index)
		rows.append({
			"id": index, "name": sector.name, "icon": sector.icon, "color": sector.color,
			"units": _at(units, index), "suspended": _at(suspended, index),
			"revenue": _at(revenue, index) / MONEY_SCALE,
			"cost": _at(cost, index) / MONEY_SCALE,
			"wages": _at(wages, index) / MONEY_SCALE,
			"profit": (_at(revenue, index) - _at(cost, index)) / MONEY_SCALE,
			"jobs_required": required, "jobs_filled": _at(jobs_filled, index),
			"fill_rate": _at(jobs_filled, index) / required if required > 0.0 else 1.0,
			"pending": _at(pending, index),
			"utilization": _at(utilization, index) / Q16,
		})
	return rows


static func top_shortages(goods: Dictionary, limit: int) -> Array:
	if not bool(goods.get("ok", false)):
		return []
	var rows: Array = []
	var shortages = goods.get("shortage_q16", PackedInt32Array())
	var names = goods.get("good_display_names", goods.get("good_stable_ids", PackedStringArray()))
	var stable_ids = goods.get("good_stable_ids", PackedStringArray())
	var demand = goods.get("demand_ema", PackedInt64Array())
	for row in range(shortages.size()):
		var shortage := _at(shortages, row) / Q16
		if shortage <= 0.02:
			continue
		rows.append({"row": row, "id": String(stable_ids[row]) if row < stable_ids.size() else "",
			"name": String(names[row]) if row < names.size() else "",
			"shortage": shortage, "weight": shortage * maxf(1.0, _at(demand, row))})
	rows.sort_custom(func(a, b): return float(a.weight) > float(b.weight))
	return rows.slice(0, limit)


# ── 卡点归类 ────────────────────────────────────────────────────────────

## 把投资拒绝直方图、欠薪、岗位空缺、丢弃、气候损失、物资短缺归入 6 类，
## 每类给出影响规模与相对严重度，按严重度取前 MAX_BOTTLENECKS 条。
static func classify_bottlenecks(summary: Dictionary, investment: Dictionary,
		goods: Dictionary) -> Array:
	var units := maxf(1.0, float(summary.get("building_units", 0)))
	var scores := {}
	var details := {}
	for category in BOTTLENECK_ORDER:
		scores[category] = 0.0
		details[category] = []
	var rejected_units := {}
	var top_reason := {}
	if bool(investment.get("ok", false)):
		var histogram = investment.get("rejection_units", PackedInt64Array())
		for reason in range(mini(histogram.size(), REJECTION_CATEGORY.size())):
			var category := REJECTION_CATEGORY[reason]
			var count := _at(histogram, reason)
			if category.is_empty() or count <= 0.0:
				continue
			rejected_units[category] = float(rejected_units.get(category, 0.0)) + count
			if count > float((top_reason.get(category, {}) as Dictionary).get("count", 0.0)):
				top_reason[category] = {"reason": reason, "count": count}
	for category in rejected_units:
		var count := float(rejected_units[category])
		scores[category] = maxf(float(scores[category]), count / units)
		var top: Dictionary = top_reason.get(category, {})
		(details[category] as Array).append("%s：%d 组建筑扩产受阻" % [
			REJECTION_LABELS[int(top.get("reason", 0))], int(count)])
	var wages_due := float(summary.get("wages_due_per_day", 0))
	var arrears := maxf(0.0, wages_due - float(summary.get("wages_paid_per_day", 0)))
	if arrears > 0.0 and wages_due > 0.0:
		scores.capital = maxf(float(scores.capital), arrears / wages_due)
		(details.capital as Array).append("欠薪 %s / 日（%s）" % [
			_money_text(arrears), _percent_text(arrears / wages_due)])
	var jobs := float(summary.get("job_capacity", 0))
	var openings := float(summary.get("job_openings", 0))
	if jobs > 0.0 and openings > 0.0:
		scores.labor = maxf(float(scores.labor), openings / jobs)
		(details.labor as Array).append("岗位空缺 %s 人（%s）" % [
			UITokens.format_compact_number_cn(openings, 1), _percent_text(openings / jobs)])
	var output := float(summary.get("output_per_day", 0))
	var discarded := float(summary.get("discarded_per_day", 0))
	if output > 0.0 and discarded > 0.0:
		scores.demand = maxf(float(scores.demand), discarded / output)
		(details.demand as Array).append("产出丢弃 %s" % _percent_text(discarded / output))
	var climate_lost := float(summary.get("climate_lost_per_day", 0))
	if climate_lost > 0.0:
		var basis := maxf(1.0, output + climate_lost)
		scores.resource = maxf(float(scores.resource), climate_lost / basis)
		(details.resource as Array).append("气候损失产出 %s" % _percent_text(climate_lost / basis))
	var suspended := float(summary.get("building_suspended_units", 0))
	if suspended > 0.0:
		scores.margin = maxf(float(scores.margin), suspended / units)
		(details.margin as Array).append("%d 座建筑亏损停业" % int(suspended))
	var short_goods := top_shortages(goods, 3)
	var severe: Array = short_goods.filter(func(g): return float(g.shortage) >= SHORTAGE_ALERT)
	if not severe.is_empty():
		var names := PackedStringArray()
		for good in severe:
			names.append(String(good.name))
		scores.input = maxf(float(scores.input), float(severe[0].shortage))
		(details.input as Array).append("短缺：%s" % "、".join(names))
	var result: Array = []
	for category in BOTTLENECK_ORDER:
		var score := float(scores[category])
		if score <= 0.005:
			continue
		var meta: Dictionary = BOTTLENECK_META[category]
		result.append({"id": category, "label": meta.label, "icon": meta.icon,
			"chapter": meta.chapter, "advice": meta.advice, "severity": clampf(score, 0.0, 1.0),
			"details": details[category]})
	result.sort_custom(func(a, b): return float(a.severity) > float(b.severity))
	return result.slice(0, MAX_BOTTLENECKS)


# ── 阶层民生 ────────────────────────────────────────────────────────────

## 把职业行按展示阶层合并；满意度与 8 维按人口加权，最差需求按人口累加。
static func aggregate_strata(professions: Dictionary, table: SocialStrataTable) -> Array:
	if table == null or not bool(professions.get("ok", false)):
		return []
	var count := table.stratum_count()
	var dim_count := int(professions.get("satisfaction_dimension_count", SATISFACTION_DIMENSIONS.size()))
	var need_count := int(professions.get("need_count", 0))
	var rows: Array = []
	for index in range(count):
		var entry := table.stratum(index)
		var dims := PackedFloat32Array()
		dims.resize(dim_count)
		rows.append({"index": index, "id": String(entry.get("id", "")),
			"name": String(entry.get("name", "")), "icon": StringName(entry.get("icon", "")),
			"color": entry.get("color", UITokens.FAMILY_BRASS), "population": 0.0,
			"cohort_count": 0, "funds": 0.0, "income_per_day": 0.0, "expense_per_day": 0.0,
			"tax_per_day": 0.0, "subsidy_per_day": 0.0, "in_kind_per_day": 0.0,
			"employed": 0.0, "unemployed": 0.0, "satisfaction": 0.0, "survival": 0.0,
			"dims": dims, "professions": [], "need_population": {}})
	var stable_ids = professions.get("profession_stable_ids", PackedStringArray())
	var names = professions.get("profession_display_names", stable_ids)
	var population = professions.get("population", PackedInt64Array())
	var satisfaction = professions.get("satisfaction_q16", PackedInt32Array())
	var survival = professions.get("survival_satisfaction_q16", PackedInt32Array())
	var dims_flat = professions.get("satisfaction_dims_q16", PackedInt32Array())
	var worst = professions.get("worst_need_population", PackedInt64Array())
	var need_names = professions.get("need_display_names", professions.get("need_ids", PackedStringArray()))
	for row in range(stable_ids.size()):
		var stable_id := String(stable_ids[row])
		var index := table.stratum_index_for(stable_id)
		if index < 0 or index >= rows.size():
			continue
		var bucket: Dictionary = rows[index]
		var people := _at(population, row)
		bucket.population += people
		bucket.cohort_count += int(_at(professions.get("cohort_count", []), row))
		bucket.funds += _at(professions.get("funds", []), row)
		bucket.income_per_day += _at(professions.get("income_per_day", []), row)
		bucket.expense_per_day += _at(professions.get("expense_per_day", []), row)
		bucket.tax_per_day += _at(professions.get("tax_per_day", []), row)
		bucket.subsidy_per_day += _at(professions.get("subsidy_per_day", []), row)
		bucket.in_kind_per_day += _at(professions.get("in_kind_income_per_day", []), row)
		bucket.employed += _at(professions.get("owner_employed", []), row) \
			+ _at(professions.get("employee_employed", []), row)
		bucket.unemployed += _at(professions.get("unemployed", []), row)
		bucket.satisfaction += _at(satisfaction, row) * people
		bucket.survival += _at(survival, row) * people
		var dims: PackedFloat32Array = bucket.dims
		for d in range(dim_count):
			dims[d] += _at(dims_flat, row * dim_count + d) * people
		bucket.dims = dims
		var needs: Dictionary = bucket.need_population
		for n in range(need_count):
			var affected := _at(worst, row * need_count + n)
			if affected > 0.0:
				needs[n] = float(needs.get(n, 0.0)) + affected
		var per_capita := _per_capita(_at(professions.get("income_per_day", []), row), people)
		(bucket.professions as Array).append({"id": stable_id,
			"name": String(names[row]) if row < names.size() else stable_id,
			"population": people, "satisfaction": _at(satisfaction, row) / Q16,
			"income_per_capita": per_capita / MONEY_SCALE})
	var total_population := 0.0
	for bucket in rows:
		total_population += float(bucket.population)
	for bucket in rows:
		var people := float(bucket.population)
		bucket.share = people / total_population if total_population > 0.0 else 0.0
		if people > 0.0:
			bucket.satisfaction = float(bucket.satisfaction) / people / Q16
			bucket.survival = float(bucket.survival) / people / Q16
			var dims: PackedFloat32Array = bucket.dims
			for d in range(dims.size()):
				dims[d] = dims[d] / people / Q16
			bucket.dims = dims
		bucket.income_per_capita = _per_capita(float(bucket.income_per_day), people) / MONEY_SCALE
		bucket.expense_per_capita = _per_capita(float(bucket.expense_per_day), people) / MONEY_SCALE
		bucket.funds_per_capita = _per_capita(float(bucket.funds), people) / MONEY_SCALE
		(bucket.professions as Array).sort_custom(
			func(a, b): return float(a.population) > float(b.population))
		var needs: Array = []
		var need_map: Dictionary = bucket.need_population
		for n in need_map:
			needs.append({"index": int(n), "name": String(need_names[int(n)])
				if int(n) < need_names.size() else "需求 %d" % int(n),
				"population": float(need_map[n]),
				"share": float(need_map[n]) / people if people > 0.0 else 0.0})
		needs.sort_custom(func(a, b): return float(a.population) > float(b.population))
		bucket.worst_needs = needs.slice(0, 4)
		bucket.erase("need_population")
	return rows


func strata_model(selected_index: int) -> Dictionary:
	var professions := query("professions")
	if not bool(professions.get("ok", false)):
		return {"ok": false, "reason": _reason(professions)}
	var rows := aggregate_strata(professions, _strata)
	var populated: Array = rows.filter(func(r): return float(r.population) > 0.0)
	var index := selected_index
	if populated.is_empty():
		return {"ok": true, "rows": rows, "selected": {}, "national_dims": PackedFloat32Array()}
	if index < 0 or index >= rows.size() or float(rows[index].population) <= 0.0:
		index = int(populated[0].index)
	var national := PackedFloat32Array()
	national.resize(SATISFACTION_DIMENSIONS.size())
	var total := 0.0
	for row in populated:
		var people := float(row.population)
		total += people
		for d in range(national.size()):
			national[d] += float((row.dims as PackedFloat32Array)[d]) * people
	for d in range(national.size()):
		national[d] = national[d] / total if total > 0.0 else 0.0
	var selected: Dictionary = rows[index]
	selected["cities"] = _stratum_cities(index)
	if _history != null and scope_cell < 0:
		selected["satisfaction_trend"] = _history.stratum_series(index, "satisfaction")
		selected["income_trend"] = _history.stratum_series(index, "income_per_capita")
	return {"ok": true, "rows": rows, "selected": selected, "selected_index": index,
		"national_dims": national}


func _stratum_cities(stratum_index: int) -> Array:
	var page := query("settlements")
	if not bool(page.get("ok", false)):
		return []
	var professions := PackedStringArray()
	if _facade != null and _facade.has_method("profession_ids"):
		professions = _facade.profession_ids()
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	var offsets = page.get("profession_offsets", PackedInt32Array())
	var profession_index = page.get("profession_indices", PackedInt32Array())
	var profession_population = page.get("profession_population", PackedInt64Array())
	var profession_satisfaction = page.get("profession_satisfaction_q16", PackedInt32Array())
	var rows: Array = []
	for row in range(cells.size()):
		if row + 1 >= offsets.size():
			break
		var people := 0.0
		var weighted := 0.0
		for k in range(int(offsets[row]), int(offsets[row + 1])):
			var p := int(profession_index[k])
			if p < 0 or p >= professions.size() \
					or _strata.stratum_index_for(String(professions[p])) != stratum_index:
				continue
			var count := _at(profession_population, k)
			people += count
			weighted += _at(profession_satisfaction, k) * count
		if people > 0.0:
			var name := String(names[row]) if row < names.size() else ""
			rows.append({"cell": int(cells[row]),
				"name": name if not name.is_empty() else "村落 #%d" % int(cells[row]),
				"population": people, "satisfaction": weighted / people / Q16})
	rows.sort_custom(func(a, b): return float(a.population) > float(b.population))
	return rows.slice(0, 6)


# ── 产业建筑 ────────────────────────────────────────────────────────────

func industry_model(sector_filter: int) -> Dictionary:
	var page := query("buildings", sector_filter)
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": _reason(page)}
	var rows: Array = []
	var names = page.get("building_display_names", page.get("building_stable_ids", PackedStringArray()))
	var sectors = page.get("economic_sectors", PackedInt32Array())
	var reason_count := int(page.get("rejection_reason_count", REJECTION_CATEGORY.size()))
	var rejections = page.get("rejection_units", PackedInt64Array())
	for row in range((page.get("type_indices", PackedInt32Array())).size()):
		var revenue := _at(page.get("revenue_per_day", []), row)
		var input_cost := _at(page.get("input_cost_per_day", []), row)
		var wages_paid := _at(page.get("wages_paid_per_day", []), row)
		var wages_due := _at(page.get("wages_due_per_day", []), row)
		var maintenance := _at(page.get("maintenance_per_day", []), row)
		var tax := _at(page.get("business_tax_per_day", []), row)
		var support := _at(page.get("producer_support_per_day", []), row)
		var profit := revenue + support - input_cost - wages_paid - maintenance - tax
		var required := _at(page.get("jobs_required", []), row)
		var filled := _at(page.get("jobs_filled", []), row)
		var output := _at(page.get("output_per_day", []), row)
		var top_reason := -1
		var top_count := 0.0
		for reason in range(mini(reason_count, REJECTION_CATEGORY.size())):
			if REJECTION_CATEGORY[reason].is_empty():
				continue
			var count := _at(rejections, row * reason_count + reason)
			if count > top_count:
				top_count = count
				top_reason = reason
		var sector := int(_at(sectors, row))
		rows.append({
			"id": int(_at(page.get("type_indices", []), row)),
			"name": String(names[row]) if row < names.size() else "",
			"sector": sector,
			"sector_name": String(SECTORS[sector].name) if sector >= 0 and sector < SECTORS.size() else "",
			"color": SECTORS[sector].color if sector >= 0 and sector < SECTORS.size() else UITokens.FAMILY_BRASS,
			"units": _at(page.get("units", []), row),
			"suspended": _at(page.get("suspended_units", []), row),
			"cells": int(_at(page.get("cell_count", []), row)),
			"utilization": _at(page.get("utilization_q16", []), row) / Q16,
			"revenue": revenue / MONEY_SCALE,
			"input_cost": input_cost / MONEY_SCALE,
			"wages": wages_paid / MONEY_SCALE,
			"maintenance": (maintenance + tax) / MONEY_SCALE,
			"support": support / MONEY_SCALE,
			"profit": profit / MONEY_SCALE,
			"margin": clampf(profit / revenue, -1.0, 1.0) if revenue > 0.0 else (-1.0 if profit < 0.0 else 0.0),
			"fill_rate": filled / required if required > 0.0 else 1.0,
			"jobs_required": required,
			"arrears_rate": maxf(0.0, wages_due - wages_paid) / wages_due if wages_due > 0.0 else 0.0,
			"discard_rate": _at(page.get("discarded_per_day", []), row) / output if output > 0.0 else 0.0,
			"pending": _at(page.get("pending_units", []), row),
			"blocker": REJECTION_LABELS[top_reason] if top_reason >= 0 else "",
			"blocker_category": REJECTION_CATEGORY[top_reason] if top_reason >= 0 else "",
		})
	return {"ok": true, "rows": rows, "total": int(page.get("total", rows.size())),
		"sectors": sector_rows(query("summary"))}


# ── 投资风向 ────────────────────────────────────────────────────────────

func investment_model() -> Dictionary:
	var page := query("investment")
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": _reason(page)}
	var reason_count := int(page.get("rejection_reason_count", REJECTION_CATEGORY.size()))
	var histogram = page.get("rejection_units", PackedInt64Array())
	var sector_pending = page.get("sector_pending_units", PackedInt64Array())
	var sector_rejections = page.get("sector_rejection_units", PackedInt64Array())
	var flow_segments: Array = []
	for sector in SECTORS:
		flow_segments.append({"label": sector.name, "value": _at(sector_pending, int(sector.id)),
			"color": sector.color, "text": "%d" % int(_at(sector_pending, int(sector.id)))})
	var categories: Array = []
	for category in BOTTLENECK_ORDER:
		var reasons: Array = []
		var total := 0.0
		var by_sector := PackedFloat32Array()
		by_sector.resize(SECTORS.size())
		for reason in range(mini(reason_count, REJECTION_CATEGORY.size())):
			if REJECTION_CATEGORY[reason] != category:
				continue
			var count := _at(histogram, reason)
			total += count
			for sector in range(SECTORS.size()):
				by_sector[sector] += _at(sector_rejections, sector * reason_count + reason)
			if count > 0.0:
				reasons.append({"reason": reason, "label": REJECTION_LABELS[reason], "count": count})
		reasons.sort_custom(func(a, b): return float(a.count) > float(b.count))
		var meta: Dictionary = BOTTLENECK_META[category]
		categories.append({"id": category, "label": meta.label, "icon": meta.icon,
			"total": total, "reasons": reasons, "by_sector": by_sector, "advice": meta.advice})
	categories.sort_custom(func(a, b): return float(a.total) > float(b.total))
	var pending_rows: Array = []
	var types = page.get("pending_type_indices", PackedInt32Array())
	var day := int(page.get("current_day", 0))
	for row in range(types.size()):
		var type_index := int(types[row])
		pending_rows.append({"id": type_index,
			"name": String(_facade.building_display_name(type_index)) if _facade != null else str(type_index),
			"units": _at(page.get("pending_units", []), row),
			"groups": int(_at(page.get("pending_groups", []), row)),
			"days_left": maxi(0, int(_at(page.get("pending_first_ready_day", []), row)) - day)})
	pending_rows.sort_custom(func(a, b): return float(a.units) > float(b.units))
	return {"ok": true, "flow": flow_segments,
		"pending_total": int(page.get("pending_total_units", 0)),
		"categories": categories, "pending": pending_rows,
		"sufficient_units": _at(histogram, REJECTION_SUFFICIENT),
		"pressure": demand_pressure(query("goods"), 6)}


## 需求压力：短缺 × 需求量 越高，越可能吸引投资。
static func demand_pressure(goods: Dictionary, limit: int) -> Array:
	if not bool(goods.get("ok", false)):
		return []
	var rows: Array = []
	var names = goods.get("good_display_names", goods.get("good_stable_ids", PackedStringArray()))
	var demand = goods.get("demand_ema", PackedInt64Array())
	var supply = goods.get("offered_supply_ema", PackedInt64Array())
	var shortages = goods.get("shortage_q16", PackedInt32Array())
	var price = goods.get("price", PackedInt64Array())
	var anchor = goods.get("cost_anchor_price", PackedInt64Array())
	for row in range(names.size()):
		var wanted := _at(demand, row)
		if wanted <= 0.0:
			continue
		var shortage := _at(shortages, row) / Q16
		var cover := _at(supply, row) / wanted
		var price_index := _at(price, row) / _at(anchor, row) if _at(anchor, row) > 0.0 else 1.0
		var pressure := clampf(shortage * 0.6 + clampf(1.0 - cover, 0.0, 1.0) * 0.4, 0.0, 1.0)
		if pressure <= 0.05:
			continue
		rows.append({"row": row, "name": String(names[row]), "pressure": pressure,
			"cover": cover, "price_index": price_index, "shortage": shortage})
	rows.sort_custom(func(a, b): return float(a.pressure) > float(b.pressure))
	return rows.slice(0, limit)


# ── 物资市场 ────────────────────────────────────────────────────────────

func market_model(group_filter: String) -> Dictionary:
	var page := query("goods")
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": _reason(page)}
	var scale := maxf(1.0, float(page.get("goods_scale", 1)))
	var stable_ids = page.get("good_stable_ids", PackedStringArray())
	var names = page.get("good_display_names", stable_ids)
	var cells: Array = []
	var groups := {}
	for row in range(stable_ids.size()):
		var stable_id := String(stable_ids[row])
		var group := good_group(stable_id)
		if not group_filter.is_empty() and group != group_filter:
			continue
		var demand := _at(page.get("demand_ema", []), row)
		var supply := _at(page.get("offered_supply_ema", []), row)
		var withdrawal := _at(page.get("realized_withdrawal_ema", []), row)
		var stock := _at(page.get("stock", []), row)
		var shortage := _at(page.get("shortage_q16", []), row) / Q16
		var anchor := _at(page.get("cost_anchor_price", []), row)
		var price := _at(page.get("price", []), row)
		var cover := supply / demand if demand > 0.0 else (2.0 if supply > 0.0 else 1.0)
		# 热度：短缺为正（暗红），过剩为负（铜绿）。过剩用库存可用天数衡量。
		var days_of_stock := stock / maxf(withdrawal, demand) if maxf(withdrawal, demand) > 0.0 else 999.0
		var traded := demand > 0.0 or supply > 0.0 or withdrawal > 0.0
		var surplus := clampf((days_of_stock - 30.0) / 120.0, 0.0, 1.0) \
			if shortage < 0.02 and traded else 0.0
		var heat := shortage if shortage >= 0.02 else -surplus
		cells.append({"id": stable_id, "row": row, "name": String(names[row]), "group": group,
			"heat": clampf(heat, -1.0, 1.0), "shortage": shortage,
			"price_index": price / anchor if anchor > 0.0 else 1.0,
			"price": price / MONEY_SCALE, "demand": demand / scale, "supply": supply / scale,
			"stock": stock / scale, "days_of_stock": days_of_stock,
			"import": _at(page.get("trade_import_ema", []), row) / scale,
			"export": _at(page.get("trade_export_ema", []), row) / scale,
			"shortage_cells": int(_at(page.get("shortage_cell_count", []), row)),
			"market_cells": int(_at(page.get("market_cell_count", []), row))})
		groups[group] = int(groups.get(group, 0)) + 1
	var group_rows: Array = []
	for group in GOOD_GROUPS:
		if groups.has(group.id):
			group_rows.append({"id": group.id, "name": group.name, "count": groups[group.id]})
	return {"ok": true, "cells": cells, "groups": group_rows}


static func good_group(stable_id: String) -> String:
	if _good_group_cache.has(stable_id):
		return _good_group_cache[stable_id]
	var group := "consumer"
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	if profile != null:
		for tag in profile.technology_tags:
			var matched := _group_for_tag(String(tag))
			if not matched.is_empty():
				group = matched
				break
	_good_group_cache[stable_id] = group
	return group


static func _group_for_tag(tag: String) -> String:
	for entry in GOOD_GROUPS:
		if (entry.tags as Array).has(tag):
			return String(entry.id)
	return ""


# ── 贸易 ────────────────────────────────────────────────────────────────

func trade_model() -> Dictionary:
	var summary: Dictionary = _model.get("trade_summary", {})
	if _facade == null or not _facade.has_method("country_trade_snapshot"):
		return {"ok": false, "reason": "国家贸易查询暂不可用"}
	var key := "trade|goods"
	var goods: Dictionary = _memo.get(key, {})
	if goods.is_empty():
		goods = _facade.country_trade_snapshot(_country_handle, "goods", 0, 64)
		_memo[key] = goods
	var partners: Dictionary = _memo.get("trade|partners", {})
	if partners.is_empty():
		partners = _facade.country_trade_snapshot(_country_handle, "partners", 0, 16)
		_memo["trade|partners"] = partners
	var rows: Array = []
	if bool(goods.get("ok", false)):
		var indices = goods.get("goods", PackedInt32Array())
		for row in range(indices.size()):
			var good := int(indices[row])
			var import_value := _at(goods.get("import_base", []), row)
			var export_value := _at(goods.get("export_base", []), row)
			rows.append({"id": good, "name": String(_facade.good_display_name(good)),
				"import": import_value / MONEY_SCALE, "export": export_value / MONEY_SCALE,
				"net": (export_value - import_value) / MONEY_SCALE,
				"import_qty": _at(goods.get("import_quantity", []), row),
				"export_qty": _at(goods.get("export_quantity", []), row),
				"tariff": (_at(goods.get("import_tariff", []), row)
					+ _at(goods.get("export_tariff", []), row)) / MONEY_SCALE,
				"cumulative_import": _at(goods.get("cumulative_import_base", []), row) / MONEY_SCALE,
				"cumulative_export": _at(goods.get("cumulative_export_base", []), row) / MONEY_SCALE})
	var partner_rows: Array = []
	if bool(partners.get("ok", false)):
		var slots = partners.get("partners", PackedInt32Array())
		for row in range(slots.size()):
			var handle := int(_at(partners.get("partner_handles", []), row))
			var import_value := _at(partners.get("import_base", []), row)
			var export_value := _at(partners.get("export_base", []), row)
			partner_rows.append({"id": handle, "name": _partner_name(handle, int(slots[row])),
				"import": import_value / MONEY_SCALE, "export": export_value / MONEY_SCALE,
				"orders": int(_at(partners.get("order_count", []), row))})
	return {"ok": bool(summary.get("ok", false)) or bool(goods.get("ok", false)),
		"reason": String(summary.get("reason", goods.get("reason", ""))),
		"imports": float(summary.get("previous_import_base", 0)) / MONEY_SCALE,
		"exports": float(summary.get("previous_export_base", 0)) / MONEY_SCALE,
		"tariff": float(summary.get("previous_tariff_net_income", 0)) / MONEY_SCALE,
		"cumulative_imports": float(summary.get("cumulative_import_base", 0)) / MONEY_SCALE,
		"cumulative_exports": float(summary.get("cumulative_export_base", 0)) / MONEY_SCALE,
		"goods": rows, "partners": partner_rows}


func _partner_name(handle: int, slot: int) -> String:
	var facade = _model.get("country_facade", null)
	if facade != null and handle > 0 and facade.has_method("snapshot"):
		var snapshot: Dictionary = facade.snapshot(handle)
		var name := String(snapshot.get("country_name", snapshot.get("display_name", "")))
		if bool(snapshot.get("ok", false)) and not name.is_empty():
			return name
	return "国家 %d" % slot


# ── 城市 ────────────────────────────────────────────────────────────────

func cities_model() -> Dictionary:
	var page := query("settlements", -1, 0, 0, -1)
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": _reason(page)}
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	var named = page.get("name_active", PackedByteArray())
	var good_names: PackedStringArray = page.get("good_ids", PackedStringArray())
	var tiers: PackedStringArray = page.get("prosperity_names", PackedStringArray())
	var rows: Array = []
	var villages := {"id": -2, "cell": -1, "name": "其余村落", "village": true, "count": 0,
		"population": 0.0, "income": 0.0, "satisfaction_weight": 0.0, "jobs_required": 0.0,
		"jobs_filled": 0.0, "units": 0.0, "suspended": 0.0, "profit": 0.0, "unemployed": 0.0}
	for row in range(cells.size()):
		var people := _at(page.get("population", []), row)
		var satisfaction := _at(page.get("satisfaction_q16", []), row) / Q16
		var required := _at(page.get("jobs_required", []), row)
		var filled := _at(page.get("jobs_filled", []), row)
		var income := _at(page.get("income_per_day", []), row) / MONEY_SCALE
		var profit := _at(page.get("profit_per_day", []), row) / MONEY_SCALE
		if row >= named.size() or int(named[row]) == 0:
			villages.count += 1
			villages.population += people
			villages.income += income
			villages.satisfaction_weight += satisfaction * people
			villages.jobs_required += required
			villages.jobs_filled += filled
			villages.units += _at(page.get("building_units", []), row)
			villages.suspended += _at(page.get("building_suspended_units", []), row)
			villages.profit += profit
			villages.unemployed += _at(page.get("unemployed", []), row)
			continue
		var worst_good := int(_at(page.get("worst_shortage_good", []), row))
		rows.append({"id": int(cells[row]), "cell": int(cells[row]), "name": String(names[row]),
			"village": false, "tier": tiers[row] if row < tiers.size() else "",
			"population": people, "income": income,
			"income_per_capita": income / people if people > 0.0 else 0.0,
			"satisfaction": satisfaction, "survival": _at(page.get("survival_satisfaction_q16", []), row) / Q16,
			"fill_rate": filled / required if required > 0.0 else 1.0,
			"unemployment": _at(page.get("unemployed", []), row) / people if people > 0.0 else 0.0,
			"units": _at(page.get("building_units", []), row),
			"suspended": _at(page.get("building_suspended_units", []), row),
			"profit": profit,
			"shortage": _at(page.get("worst_shortage_q16", []), row) / Q16,
			"shortage_good": _good_name_from(good_names, worst_good),
			"state_day": int(_at(page.get("state_day", []), row))})
	if int(villages.count) > 0:
		var people := float(villages.population)
		villages["income_per_capita"] = float(villages.income) / people if people > 0.0 else 0.0
		villages["satisfaction"] = float(villages.satisfaction_weight) / people if people > 0.0 else 0.0
		villages["survival"] = villages.satisfaction
		villages["fill_rate"] = float(villages.jobs_filled) / float(villages.jobs_required) \
			if float(villages.jobs_required) > 0.0 else 1.0
		villages["unemployment"] = float(villages.unemployed) / people if people > 0.0 else 0.0
		villages["shortage"] = 0.0
		villages["shortage_good"] = ""
		villages["tier"] = "%d 处" % int(villages.count)
		rows.append(villages)
	return {"ok": true, "rows": rows, "total": int(page.get("total", cells.size()))}


func _good_name_from(stable_ids: PackedStringArray, index: int) -> String:
	if _facade != null and index >= 0:
		return String(_facade.good_display_name(index))
	return String(stable_ids[index]) if index >= 0 and index < stable_ids.size() else ""


func _settlement_name(cell: int) -> String:
	var page := query("settlements", -1, 0, 0, -1)
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	for row in range(cells.size()):
		if int(cells[row]) == cell and row < names.size() and not String(names[row]).is_empty():
			return String(names[row])
	return "村落 #%d" % cell


# ── 格式化 ──────────────────────────────────────────────────────────────

static func format_value(value: float, kind: String) -> String:
	if is_nan(value):
		return "—"
	match kind:
		"percent":
			return _percent_text(value)
		"money":
			return UITokens.format_compact_number_cn(value, 2)
		"index":
			return "%.2f" % value
		_:
			return UITokens.format_compact_number_cn(value, 1)


static func _money_text(raw: float) -> String:
	return UITokens.format_compact_number_cn(raw / MONEY_SCALE, 2)


static func _percent_text(ratio: float) -> String:
	return "%.0f%%" % (ratio * 100.0) if absf(ratio) >= 0.1 else "%.1f%%" % (ratio * 100.0)


static func _per_capita(total: float, population: float) -> float:
	return total / population if population > 0.0 else 0.0


static func _at(values, index: int) -> float:
	if values == null or index < 0 or index >= values.size():
		return 0.0
	return float(values[index])


static func _reason(page: Dictionary) -> String:
	if is_pending(page):
		return "正在读取经济数据…"
	match String(page.get("reason", "")):
		"country_handle_invalid":
			return "国家档案已失效"
		"cell_not_in_country":
			return "该区域已不在本国领土内"
		"economy_not_bootstrapped", "economy_not_configured":
			return "经济系统尚未就绪"
	return String(page.get("reason", "数据暂不可用"))
