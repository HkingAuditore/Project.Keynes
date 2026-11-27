extends RefCounted
class_name EconomyDossierViewModel

const DossierMarkets = preload("res://scripts/ui/economy_dossier_markets.gd")

const DossierStrata = preload("res://scripts/ui/economy_dossier_strata.gd")

const DossierCashflow = preload("res://scripts/ui/economy_dossier_cashflow.gd")

## 国民经济卷宗的展示模型。只读消费 EconomyFacade.country_economy_overview
## 与国家壳模型（国库、财政、贸易摘要），把原生列式结果整理成各章所需的
## 行与图表数据。卡点归类是纯展示启发式，结果不回写任何模拟状态。

const MONEY_SCALE := 10000.0
const Q16 := 65536.0
const DEFAULT_CASHFLOW_WINDOW_DAYS := 30
const CASHFLOW_WINDOW_OPTIONS := [7, 30]
const OTHER_TREASURY_CHANGE_LABEL := "其他国库变动"

const CHAPTERS: Array[Dictionary] = [
	{"id": "overview", "label": "总览", "icon": &"summary.overview", "question": ""},
	{"id": "strata", "label": "阶层民生", "icon": &"population.heart", "question": ""},
	{"id": "industry", "label": "产业", "icon": &"economy.building.factory", "question": ""},
	{"id": "market", "label": "市场", "icon": &"metric.goods", "question": ""},
	{"id": "cities", "label": "城市", "icon": &"metric.territory", "question": ""},
	{"id": "tax", "label": "税收", "icon": &"tax.section", "question": ""},
	{"id": "treasury", "label": "国库", "icon": &"metric.treasury", "question": ""},
]

const SECTORS: Array[Dictionary] = [
	{"id": 0, "name": "农业", "icon": &"economy.building.farm", "color": Color(0.34, 0.48, 0.31)},
	{"id": 1, "name": "采掘", "icon": &"economy.building.mine", "color": Color(0.45, 0.36, 0.27)},
	{"id": 2, "name": "制造", "icon": &"economy.building.factory", "color": Color(0.62, 0.36, 0.19)},
	{"id": 3, "name": "能源", "icon": &"economy.building.power", "color": Color(0.69, 0.49, 0.24)},
	{"id": 4, "name": "知识", "icon": &"economy.building.science", "color": Color(0.31, 0.43, 0.53)},
]

const SATISFACTION_DIMENSIONS: Array[String] = [
	"生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展"]
## 前四维是实际生活消费，后四维是财务与社会感受。-1 表示不适用。
const CONSUMPTION_TIER_COUNT := 4

## 人口视角。阶层是聚合口径（九个展示阶层），职业是原生 professions 视图的原始口径；
## 两者读同一份快照，所以同名职业在两边的数字必然一致，只是分组粗细不同。
const POPULATION_MODES: Array[Dictionary] = [
	{"id": "stratum", "label": "阶层", "tooltip": "按九个社会阶层合并看"},
	{"id": "profession", "label": "职业", "tooltip": "逐职业看，精确到具体职业"},
]

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
	## 利润卡点落在产业章的「资本与在建」一段：合并后它在同页下方，需要滚过去，
	## 否则点卡点只换章、看不到任何对应内容。
	"margin": {"label": "利润过低", "icon": &"trend.flat", "chapter": "industry",
		"section": "investment", "advice": "营收不抵成本，资本不愿进入"},
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

## 五类税种在收支明细里的名字。收入侧是实收税额，支出侧是同一税种的负税率补贴，
## 顺序与 NativeCountryRuntime::TaxKind 一致；快照自带 tax_kinds，按 id 对齐而不是按位置。
const CASHFLOW_KINDS: Array[Dictionary] = [
	{"id": "income", "name": "所得税", "subsidy": "收入补贴"},
	{"id": "consumption", "name": "交易税", "subsidy": "交易补贴"},
	{"id": "business", "name": "营业税", "subsidy": "营业补贴"},
	{"id": "import", "name": "进口关税", "subsidy": "进口补贴"},
	{"id": "export", "name": "出口关税", "subsidy": "出口补贴"},
]
## 非税国库支出：国库按市价付给本地商人、却不是税种的现金流出。顺序与原生
## `NativeEconomyRuntime::NonTaxOutflow` 一致；快照自带 `non_tax_outflow_kinds`，
## 按 id 对齐而不是按位置。每一项各自成段、各自成行，混在一起就没法回答
## 「这笔钱是为科研、开拓还是工程付的」。
const NON_TAX_OUTFLOW_KINDS: Array[Dictionary] = [
	{"id": "research_purchase", "label": "科研采购", "icon": "metric.technology",
		"note": "国库按市价向本地商人购入科技值。"},
	{"id": "expedition_procurement", "label": "开拓采购", "icon": "family.house",
		"note": "开拓商队向本地商人购入随行货物。"},
	{"id": "construction", "label": "工程支出", "icon": "economy.building",
		"note": "工程缺料由国库按市价从本地市场补足。"},
	{"id": "canal", "label": "运河支出", "icon": "metric.territory",
		"note": "运河缺料由国库按市价从本地市场补足。"},
	{"id": "era_procurement", "label": "时代晋升收购", "icon": "technology.milestone",
		"note": "时代晋升期间国库按市价向本地商人收购所需物资。"},
]
## 原生新增项在旧 UI 上的兜底标签：宁可显示「其他支出」，也不要静默吞掉这笔钱。
const NON_TAX_OUTFLOW_FALLBACK_LABEL := "其他支出"

## 物价指数口径。原生按家庭需求（消费端）与供给（生产端）加权，100 = 成本锚。
const PRICE_INDICES: Array[Dictionary] = [
	{"id": "cpi", "label": "CPI", "name": "消费者物价",
		"q16_key": "consumer_price_index_q16", "valid_key": "consumer_price_index_valid",
		"basis": "100 = 消费品成本"},
	{"id": "ppi", "label": "PPI", "name": "生产者物价",
		"q16_key": "producer_price_index_q16", "valid_key": "producer_price_index_valid",
		"basis": "100 = 可售物资成本"},
]

## 与原生 consumption_living_standard_level() 的 0..6 台阶同序。
const LIVING_STANDARD_NAMES: Array[String] = [
	"赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华",
]

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
var _gdp_ledger: EconomyGdpLedger = null
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
	var ledger = model.get("gdp_ledger", null)
	_gdp_ledger = ledger if ledger is EconomyGdpLedger else null
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
		return String(_model.get("reason", "国家数据暂不可用"))
	return "国民经济数据暂不可用"


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

## 页头「年度累计产值」横幅数据。与 kpis() 分开：横幅不是 KPI 卡，
## 增删它不应改变 KPI 条的张数（结构测试锁定 5 张）。
## 读数全部来自内存账本，本方法不发起任何原生查询。
func gdp_headline() -> Dictionary:
	var title := "本年度累计产值" if scope_cell < 0 else "本城年度累计产值"
	if _gdp_ledger == null:
		return {"ok": false, "title": title, "reason": "经济数据尚未接入"}
	if not _gdp_ledger.ready():
		return {"ok": false, "title": title, "reason": "经济数据尚未就绪"}
	var national := scope_cell < 0
	if not national and not _gdp_ledger.tracks_cell(scope_cell):
		return {"ok": false, "title": title, "reason": "此地暂无可统计的产值"}
	var ytd := _gdp_ledger.national_ytd() if national \
		else _gdp_ledger.cell_ytd(scope_cell)
	var per_day := _gdp_ledger.national_per_day() if national \
		else _gdp_ledger.cell_per_day(scope_cell)
	var per_capita := _gdp_ledger.national_per_capita() if national \
		else _gdp_ledger.cell_per_capita(scope_cell)
	return {
		"ok": true,
		"title": title,
		"value": ytd / MONEY_SCALE,
		"per_day": per_day / MONEY_SCALE,
		"per_capita": per_capita / MONEY_SCALE if not is_nan(per_capita) else NAN,
		"population": _gdp_ledger.national_population() if national \
			else _gdp_ledger.cell_population(scope_cell),
		"days_counted": _gdp_ledger.days_counted(),
		"days_per_year": _gdp_ledger.days_per_year(),
		"year_index": _gdp_ledger.year_index(),
		"backfilled": _gdp_ledger.backfilled(),
		"partial": national and _gdp_ledger.partial(),
	}


func kpis() -> Array:
	var summary := query("summary")
	if not bool(summary.get("ok", false)):
		return []
	var treasury: Dictionary = _model.get("treasury", {})
	var cash := int(treasury.get("cash", _model.get("cash", 0)))
	var values := EconomyHistoryBuffer.kpi_values(summary, cash)
	var national := scope_cell < 0
	# 满意度与国库两张卡不留副行：主数字已经说完了，剩下的口径信息放进悬停提示。
	var survival := _percent_text(float(summary.get("survival_satisfaction_q16", 0)) / Q16)
	var tax_per_day := _money_text(values.tax_per_day)
	return [
		_kpi("population", "人口", values.population, "count", true,
			"%d 个聚落" % int(summary.get("populated_cell_count", 0)), &"family.metric.population"),
		_kpi("income_per_day", "居民收入 / 日", values.income_per_day / MONEY_SCALE, "money",
			true, "人均 %s" % _money_text(_per_capita(values.income_per_day, values.population)),
			&"family.metric.wealth"),
		_kpi("employment_rate", "就业率", values.employment_rate, "percent", true,
			"空缺岗位 %s" % UITokens.format_compact_number_cn(values.job_openings, 1),
			&"population.profession.worker"),
		_kpi("satisfaction", "综合满意度", values.satisfaction, "percent", true, "",
			&"population.heart", "", "生存满足 %s" % survival),
		_kpi("treasury", "国库" if national else "产值 / 日",
			values.treasury / MONEY_SCALE if national else values.revenue_per_day / MONEY_SCALE,
			"money", true,
			"" if national else "利用率 %s" % _percent_text(values.utilization),
			&"metric.treasury" if national else &"family.metric.buildings",
			"treasury" if national else "revenue_per_day",
			"税收 %s / 日" % tax_per_day if national else ""),
	]


func _kpi(id: String, title: String, value: float, kind: String, positive_good: bool,
		caption: String, icon: StringName, history_key: String = "",
		tooltip_detail: String = "") -> Dictionary:
	var key := id if history_key.is_empty() else history_key
	var spark := PackedFloat32Array()
	var delta := NAN
	# 趋势缓冲只记录全国口径；单城市范围下不画全国曲线以免误读。
	if _history != null and scope_cell < 0:
		spark = _history.series(key)
		delta = _history.delta(key, mini(7, maxi(1, spark.size() - 1)))
		if kind == "money":
			delta /= MONEY_SCALE
	var out := {"id": id, "title": title, "value": value, "kind": kind,
		"positive_good": positive_good, "caption": caption, "icon": icon,
		"spark": spark, "delta": delta}
	# 没有额外口径时交给卡片自己拼默认提示，避免把 tooltip 覆盖成空串。
	if not tooltip_detail.is_empty():
		out["tooltip"] = tooltip_detail
	return out


# ── 总览 ────────────────────────────────────────────────────────────────

func overview_model(window_days: int = DEFAULT_CASHFLOW_WINDOW_DAYS) -> Dictionary:
	var summary := query("summary")
	if not bool(summary.get("ok", false)):
		return {"ok": false, "reason": _reason(summary)}
	var goods := query("goods")
	return {
		"ok": true,
		"cashflow": cashflow_model(window_days),
		"price": price_model(summary),
		"living": living_standard_model(summary),
		"per_capita": per_capita_model(),
		"sectors": sector_rows(summary),
		"shortages": top_shortages(goods, 5),
		"state_day_min": int(summary.get("state_day_min", -1)),
		"state_day_max": int(summary.get("state_day_max", -1)),
	}


## 物价指数：原生 summary 已按需求 / 供给加权算好，成本锚 = 100。
## 消费者指数按家庭需求加权，生产者指数按供给加权，两者都是流量权重而不是简单平均。
static func price_model(summary: Dictionary) -> Dictionary:
	if not bool(summary.get("ok", false)):
		return {"ok": false, "rows": []}
	var rows: Array = []
	var values: Array = []
	for entry in PRICE_INDICES:
		var valid := bool(summary.get(entry.valid_key, false))
		var value := float(summary.get(entry.q16_key, 0)) / Q16 if valid else NAN
		if valid:
			values.append(value)
		rows.append({"id": entry.id, "label": entry.label,
			"index": value * 100.0 if valid else NAN, "valid": valid,
			"text": "%.1f" % (value * 100.0) if valid else "—",
			"tooltip": "%s\n%s" % [String(entry.name), String(entry.basis)]})
	# CPI − PPI 就是两端的价格裂口：正值说明消费端比出厂端更贵。
	# 任一端缺读数就不报裂口，缺一半的减法没有意义。
	var spread := NAN
	if values.size() == PRICE_INDICES.size():
		spread = (float(values[0]) - float(values[1])) * 100.0
	return {"ok": true, "rows": rows, "spread": spread}


## 人均生活水平：原生按人口加权后给出 0..6 的连续读数（Q16）。
## 这是有序台阶而不是连续量，所以展示成阶梯而不是刻度条。
static func living_standard_model(summary: Dictionary) -> Dictionary:
	if not bool(summary.get("ok", false)):
		return {"ok": false, "level": NAN, "max": LIVING_STANDARD_NAMES.size() - 1}
	var valid := bool(summary.get("living_standard_level_valid", false))
	var level := float(summary.get("living_standard_level_q16", 0)) / Q16 if valid else NAN
	return {
		"ok": valid,
		"level": level,
		"max": LIVING_STANDARD_NAMES.size() - 1,
		"name": LIVING_STANDARD_NAMES[clampi(int(floor(level)), 0,
			LIVING_STANDARD_NAMES.size() - 1)] if valid else "",
		"text": "%.1f" % level if valid else "—",
	}


## 人均日产值：GDP 账本的当日人均流量与最近的趋势。
## 与页头横幅的「年度人均累计」是两个口径——这里跟着每天的产出波动，
## 所以把年度累计写在 caption 里，避免读者把两个「人均」当成同一个数。
func per_capita_model() -> Dictionary:
	if _gdp_ledger == null or not _gdp_ledger.ready():
		return {"ok": false, "value": 0.0, "trend": PackedFloat32Array(), "delta": NAN,
			"caption": ""}
	var value := _gdp_ledger.national_per_capita_per_day() / MONEY_SCALE
	var trend := _gdp_ledger.per_capita_trend()
	var spark := PackedFloat32Array()
	for point in trend:
		spark.append(point / MONEY_SCALE)
	var delta := NAN
	if spark.size() >= 2 and not is_nan(spark[-1]) and not is_nan(spark[-2]):
		delta = spark[-1] - spark[-2]
	var year_per_capita := _gdp_ledger.national_per_capita() / MONEY_SCALE
	return {"ok": not is_nan(value), "value": value, "trend": spark, "delta": delta,
		"ytd_per_capita": year_per_capita,
		"caption": "年度人均 %s" % UITokens.format_compact_number_cn(year_per_capita, 2)
			if not is_nan(year_per_capita) else "",
		"population": _gdp_ledger.national_population()}


## 国库收支：堆叠条看结构（谁交的、补给谁），折线看方向（总量怎么变）。
## 有逐日国库历史时优先展示滑动窗口日均；历史还不足以形成一段现金区间时，
## 回退到当天/最近一次结算，避免用单点伪造整月均值。
## 数据只来自 shell 模型里的财政快照与国库日序列，不额外发起原生查询。
func cashflow_model(window_days: int = DEFAULT_CASHFLOW_WINDOW_DAYS) -> Dictionary:
	return DossierCashflow.cashflow_model(self, window_days)


static func cashflow_from_history(history: EconomyFiscalHistory, fiscal: Dictionary,
		window_days: int = DEFAULT_CASHFLOW_WINDOW_DAYS) -> Dictionary:
	return DossierCashflow.cashflow_from_history(history, fiscal, window_days)


static func build_rolling_cashflow(rolling: Dictionary) -> Dictionary:
	return DossierCashflow.build_rolling_cashflow(rolling)


static func _series_money(values: PackedFloat32Array) -> PackedFloat32Array:
	return DossierCashflow._series_money(values)


static func _average_values(values, days: int) -> PackedFloat64Array:
	return DossierCashflow._average_values(values, days)


static func _other_treasury_change_row(amount: float, positive: bool) -> Dictionary:
	return DossierCashflow._other_treasury_change_row(amount, positive)


static func build_cashflow(fiscal: Dictionary) -> Dictionary:
	return DossierCashflow.build_cashflow(fiscal)


static func _flow_segments(raw: Array, base: Color) -> Array:
	return DossierCashflow._flow_segments(raw, base)


static func _cashflow_cell(raw: float, color: Color = UITokens.DOSSIER_INK) -> Dictionary:
	return DossierCashflow._cashflow_cell(raw, color)


static func _cashflow_meta(kind_ids, index: int) -> Dictionary:
	return DossierCashflow._cashflow_meta(kind_ids, index)


static func _non_tax_outflow_id(kind_ids, index: int) -> String:
	return DossierCashflow._non_tax_outflow_id(kind_ids, index)


static func _non_tax_outflow_label(kind_ids, index: int) -> String:
	return DossierCashflow._non_tax_outflow_label(kind_ids, index)


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
			"chapter": meta.chapter, "section": String(meta.get("section", "")),
			"advice": meta.advice, "severity": clampf(score, 0.0, 1.0),
			"details": details[category]})
	result.sort_custom(func(a, b): return float(a.severity) > float(b.severity))
	return result.slice(0, MAX_BOTTLENECKS)


# ── 阶层民生 ────────────────────────────────────────────────────────────

## 把职业行按展示阶层合并；满意度与 8 维按人口加权，最差需求按人口累加。
static func aggregate_strata(professions: Dictionary, table: SocialStrataTable) -> Array:
	return DossierStrata.aggregate_strata(professions, table)


static func living_name(level: float) -> String:
	return DossierStrata.living_name(level)


static func profession_rows(professions: Dictionary, table: SocialStrataTable) -> Array:
	return DossierStrata.profession_rows(professions, table)


static func national_dims(rows: Array) -> PackedFloat32Array:
	return DossierStrata.national_dims(rows)


func strata_model(selected_index: int = -1, mode: String = "stratum",
		selected_profession: String = "") -> Dictionary:
	return DossierStrata.strata_model(self, selected_index, mode, selected_profession)


static func _pick_profession(rows: Array, wanted: String) -> Dictionary:
	return DossierStrata._pick_profession(rows, wanted)


func _cities_for(stratum_index: int, profession_id: String) -> Array:
	return DossierStrata._cities_for(self, stratum_index, profession_id)


# ── 产业建筑 ────────────────────────────────────────────────────────────

func industry_model(sector_filter: int) -> Dictionary:
	return DossierMarkets.industry_model(self, sector_filter)


func investment_model() -> Dictionary:
	return DossierMarkets.investment_model(self)


static func demand_pressure(goods: Dictionary, limit: int) -> Array:
	return DossierMarkets.demand_pressure(goods, limit)


func market_model(group_filter: String) -> Dictionary:
	return DossierMarkets.market_model(self, group_filter)


static func good_group(stable_id: String) -> String:
	return DossierMarkets.good_group(stable_id)


static func _group_for_tag(tag: String) -> String:
	return DossierMarkets._group_for_tag(tag)


func trade_model() -> Dictionary:
	return DossierMarkets.trade_model(self)


func _partner_name(handle: int, slot: int) -> String:
	return DossierMarkets._partner_name(self, handle, slot)


func cities_model() -> Dictionary:
	return DossierMarkets.cities_model(self)


func _good_name_from(stable_ids: PackedStringArray, index: int) -> String:
	return DossierMarkets._good_name_from(self, stable_ids, index)


func _settlement_name(cell: int) -> String:
	return DossierMarkets._settlement_name(self, cell)


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


## 金额只出数字（含正负号与「万/亿」缩写），单位由渲染层的金币图标负责：
## 图表走 DossierChart._money_text()，容器行走 MoneyDisplay.make_icon()。
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
			return "国家数据已失效"
		"cell_not_in_country":
			return "该区域已不在本国领土内"
		"economy_not_bootstrapped", "economy_not_configured":
			return "经济系统尚未就绪"
	return String(page.get("reason", "数据暂不可用"))
