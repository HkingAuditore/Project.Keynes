extends RefCounted

const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")
const SATISFACTION_DIMENSION_NAMES = ["生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展"]
const SATISFACTION_DIMENSION_EXPLANATIONS = ["热量与御寒的生理满足率；不足会限制综合满意度。", "基本生活实际消费相对生活目标的完整度；综合各项满足率与最短缺的一项，目标不随预算和物价缩减。", "实际享受到的舒适消费相对生活目标的满足率；存款不直接加分。", "实际享受到的奢侈与身份消费相对生活目标的满足率；存款不直接加分。", "近期收入相对长期收入基线的变化。", "剩余存款可支撑的基础生活月数。", "本期净税负相对毛收入的压力。", "本地聚落等级、国家技术进度和建成产业种类。"]
const DOSSIER_INCOME_COLORS: Array[Color] = [UITokens.DOSSIER_VERDIGRIS, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_SLATE, UITokens.DOSSIER_UMBER]
const DOSSIER_EXPENSE_COLORS: Array[Color] = [UITokens.DOSSIER_OXBLOOD, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_UMBER, UITokens.DOSSIER_SLATE]

const TEMPERATURE_HISTORY_CAPACITY = 32
const TEMPERATURE_HISTORY_CACHE_LIMIT = 64
const DETAIL_HISTORY_CAPACITY = 48
const DETAIL_HISTORY_LOOKBACK = 7
## 原生金额单位是 1/10000 货币；只有视图层才把它换算成金币读数。
const MONEY_SCALE = 10000.0

# 对象详情弹窗：行类型 → 页签 / 行列表键 / 中文类型名。
const OBJECT_DETAIL_TAB = {
	"cohort": "population",
	"building": "buildings",
	"good": "market",
	"resource": "geography",
	"family": "families",
}
const OBJECT_DETAIL_ROWS = {
	"cohort": "cohort_rows",
	"building": "building_rows",
	"good": "market_rows",
	"resource": "resource_rows",
	"family": "family_rows",
}
const OBJECT_TYPE_LABELS = {
	"cohort": "阶层",
	"building": "建筑",
	"good": "物资",
	"resource": "自然资源",
	"family": "家族",
}
# 对象类型 → 关联税种（税收契约：所得税按职业、营业税按建筑类型、
# 交易税与进出口关税按物资；自然资源没有适用税种）。
const OBJECT_TAX_KINDS = {
	"cohort": ["income"],
	"building": ["business"],
	"good": ["consumption", "import", "export"],
}
const TAX_KIND_IDS = {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const TAX_KIND_LABELS = {"income": "所得税", "consumption": "交易税",
	"business": "营业税", "import": "进口关税", "export": "出口关税"}
const TAX_DEFAULT_LABELS = {"income": "此地所得税", "consumption": "此地交易税",
	"business": "此地营业税", "import": "此地进口税", "export": "此地出口税"}
const TAX_KIND_ACCENTS = {"income": UITokens.ACCENT, "consumption": UITokens.GOOD,
	"business": UITokens.CLIMATE, "import": UITokens.WATER, "export": UITokens.WATER}
const TRADE_ORDER_PAGE_SIZE = 12
const TRADE_ORDER_PAGE_CACHE_LIMIT = 8
const TRADE_ORDER_MODEL_CACHE_LIMIT = 16
const TRADE_ORDER_NAME_CACHE_LIMIT = 256

## 营造窗口一页的建筑条目数。一页 = 16 条同时报价：够填满视口，又让
## 「打开 / 切部门 / 翻页 / 每日刷新」的原生报价调用保持在毫秒级。
const CONSTRUCTION_PAGE_SIZE = 16
## Building kinds are compiled to dense ints; 3 == state-owned (barracks /
## fortification / war college). The dedicated military department lists them
## from MilitaryCatalog's `state_buildings` and quotes their economy type IDs.
const STATE_BUILDING_KIND = 3
## 军事部门不是经济目录里的部门：条目来自 MilitaryCatalog 的 `state_buildings`，
## 命令走军事运行时的 `state.build`，与经济侧的 `construction.build` 是两条通道
## （见 docs/ui/military-cell-tab.md §2.1）。这个 id 故意不并入 economy 的
## sector 表，避免被 `construction_candidates` 当成经济部门下标。
const CONSTRUCTION_MILITARY_SECTOR = "military"
## 军事页的三行官营建筑，顺序即行序；`role` 对齐 MilitaryStateRole (military_core.h)。
const STATE_BUILDING_ROLES: Array[Dictionary] = [
	{"id": "barracks", "label": "兵营", "role": 0},
	{"id": "fortification", "label": "城防", "role": 1},
	{"id": "war_college", "label": "军校", "role": 2},
]
## Same order as MilitaryUnitClass (military_core.h), used for unit icon keys.
const MILITARY_UNIT_CLASS_IDS: Array[String] = ["line", "mobile", "artillery"]
## 维护快照的 `kind`：0 = 建筑组，1 = 装备组（D7 契约）。地块档案只读建筑组。
## `object_id` 是目录 `state_buildings` 的稠密下标，与 `state_building_materials()`
## 用的是同一套下标。
const MAINTENANCE_KIND_BUILDING = 0
const MAINTENANCE_REASON_TEXT: Array[String] = ["—", "缺货", "预算不足", "运输未到"]
const CONSTRUCTION_SECTOR_LABELS = {
	"agriculture": "农业",
	"extractive": "采掘",
	"manufacturing": "制造",
	"energy": "能源",
	"knowledge": "知识",
	"military": "军事",
}
const CONSTRUCTION_SECTOR_ICONS = {
	"agriculture": &"economy.building.farm",
	"extractive": &"economy.building.mine",
	"manufacturing": &"economy.building.factory",
	"energy": &"economy.building.power",
	"knowledge": &"economy.building.science",
	"military": &"military.building.barracks",
}
## 营造目录的排序档。三档都遵守「可建优先」，档位只决定可建项之间的次序。
const CONSTRUCTION_SORT_IDS = ["recommended", "cost", "newest"]
## 原生报价的拒绝码 → 玩家可读的短因由（行内标签用，长解释在 hover 里）。
const CONSTRUCTION_REASON_TEXT = {
	"construction_cell_not_owned": "非本国领土",
	"construction_technology_locked": "科技未解锁",
	"construction_obsolete": "已被高阶取代",
	"construction_conditions_failed": "地块不符",
	"construction_resource_unavailable": "自然资源不足",
	"construction_materials_insufficient": "建材不足",
	"construction_market_short": "市场缺货",
	"construction_treasury_cash_insufficient": "资金不足",
	"construction_market_unavailable": "市场不可结算",
	"construction_owner_signature_unavailable": "无合适业主",
	"construction_target_invalid": "目标无效",
}
## one-tick memo for the (large) cell building snapshot: the buildings tab and
## the construction window share one read per cell per committed day.

static func family_workspace_model(detail: Dictionary) -> Dictionary:
	return FamilyWorkspaceProjection.family_workspace_model(detail)


## Facade snapshots may contain the same presentation row through multiple legacy
## lanes.  The workspace is a player-facing projection, so collapse only rows that
## are semantically identical; effects retain their cell in the key to preserve
## same-name effects bound to different branches.

static func _family_unique_traits(rows: Array) -> Array:
	return FamilyWorkspaceProjection._family_unique_traits(rows)



static func _family_unique_preferences(rows: Array) -> Array:
	return FamilyWorkspaceProjection._family_unique_preferences(rows)



static func _family_unique_rows(rows: Array, key_fields: Array) -> Array:
	return FamilyWorkspaceProjection._family_unique_rows(rows, key_fields)



static func _family_text_key(value: Variant) -> String:
	return FamilyWorkspaceProjection._family_text_key(value)



static func _parse_leading_float(text: Variant, fallback: float = 0.0) -> float:
	return FamilyWorkspaceProjection._parse_leading_float(text, fallback)



static func _detail_row_value_map(detail_rows: Array) -> Dictionary:
	var out = {}
	for raw in detail_rows:
		if not (raw is Dictionary):
			continue
		var item: Dictionary = raw
		var id_key = String(item.get("id", ""))
		var name_key = String(item.get("name", ""))
		var val = String(item.get("value", ""))
		if not id_key.is_empty():
			out[id_key] = val
		if not name_key.is_empty():
			out[name_key] = val
	return out


## 物资详情卷宗视图模型：提炼 4 格 KPI、诊断批注、供需对冲条、价格锚点刻度条与贸易对冲条。

static func good_dossier_model(row: Dictionary) -> Dictionary:
	var detail_map = _detail_row_value_map(row.get("detail_rows", []))
	var stock_plain = String(row.get("stock_plain", row.get("stock", "0 单位")))
	var stock_units = float(row.get("stock_units_float", _parse_leading_float(stock_plain, 0.0)))
	var price_text = String(row.get("price", "—"))
	var price_val = float(row.get("price_float", _parse_leading_float(price_text, 0.0)))
	var anchor_text = String(row.get("cost_anchor_text", detail_map.get("cost_anchor", detail_map.get("成本锚", "—"))))
	var anchor_val = float(row.get("cost_anchor_float", _parse_leading_float(anchor_text, 0.0)))
	var has_anchor = anchor_val > 0.00001 and anchor_text != "—" and not anchor_text.is_empty()
	var price_index = float(row.get("price_index_float",
		(price_val / anchor_val) if has_anchor else 1.0))
	var hh_demand = float(row.get("household_demand_float",
		_parse_leading_float(detail_map.get("household_demand", detail_map.get("居民需求", "0")), 0.0)))
	var biz_demand = float(row.get("business_demand_float",
		_parse_leading_float(detail_map.get("business_demand", detail_map.get("产业需求", "0")), 0.0)))
	var total_demand = hh_demand + biz_demand
	var supply_units = float(row.get("supply_float",
		_parse_leading_float(detail_map.get("supply", detail_map.get("供给", "0")), 0.0)))
	var shortage_ratio = float(row.get("shortage_float",
		_parse_leading_float(detail_map.get("shortage", detail_map.get("短缺", "0")), 0.0) / 100.0))
	if shortage_ratio <= 0.0 and String(row.get("risk", "")) == "短缺":
		shortage_ratio = 0.25
	var days_of_stock = float(row.get("days_of_stock_float",
		stock_units / total_demand if total_demand > 0.001 else (999.0 if stock_units > 0.001 else 0.0)))
	var delta_text = String(row.get("delta", "—"))
	var inbound_text = String(row.get("trade_inbound", detail_map.get("trade_inbound", detail_map.get("运入", ""))))
	var outbound_text = String(row.get("trade_outbound", detail_map.get("trade_outbound", detail_map.get("运出", ""))))
	var inbound_units = float(row.get("inbound_float", _parse_leading_float(inbound_text, 0.0)))
	var outbound_units = float(row.get("outbound_float", _parse_leading_float(outbound_text, 0.0)))
	var import_flow_units = float(row.get("import_flow_float",
		_parse_leading_float(detail_map.get("trade_import_flow", detail_map.get("进口均量", "0")), 0.0)))
	var export_flow_units = float(row.get("export_flow_float",
		_parse_leading_float(detail_map.get("trade_export_flow", detail_map.get("出口均量", "0")), 0.0)))

	var price_tone = "risk" if price_index >= 1.35 else ("warn" if price_index >= 1.15 else "")
	var price_index_caption = "贴近成本锚"
	if has_anchor:
		if price_index > 1.05:
			price_index_caption = "高于成本锚 %.0f%%" % minf(999.0, (price_index - 1.0) * 100.0)
		elif price_index < 0.95:
			price_index_caption = "低于成本锚 %.0f%%" % ((1.0 - price_index) * 100.0)
	else:
		price_index_caption = ""

	var stock_caption = "日变 %s" % delta_text if delta_text != "—" else "无日常消耗"
	if total_demand > 0.001:
		stock_caption = "库存充裕" if days_of_stock >= 180.0 else ("可支 %d 日" % int(days_of_stock))

	var balance_text = "静态库存"
	if shortage_ratio >= 0.02 or String(row.get("risk", "")) != "":
		balance_text = "短缺 %.0f%%" % (shortage_ratio * 100.0) if shortage_ratio >= 0.02 else String(row.get("risk", "短缺"))
	elif supply_units > total_demand * 1.15 and supply_units > 0.01:
		balance_text = "供过于求"
	elif total_demand > 0.001 or supply_units > 0.001:
		balance_text = "供需平衡"
	var net_supply = supply_units - total_demand
	var balance_caption = "日均供需持平"
	if net_supply < -0.01:
		balance_caption = "日缺口 %s" % UITokens.format_compact_number_cn(absf(net_supply), 2)
	elif net_supply > 0.01:
		balance_caption = "日盈余 +%s" % UITokens.format_compact_number_cn(net_supply, 2)
	elif delta_text != "—":
		balance_caption = "日变 %s" % delta_text

	var price_index_text = "%.2f 倍" % price_index
	var kpis = [
		{
			"id": "good_price",
			"title": "本地时价",
			"value": price_val,
			"kind": "text",
			"text": price_text,
			"caption": "锚价 %s" % anchor_text if has_anchor else "本地零售单价",
			"tone": price_tone,
			"positive_good": false,
			"spark": row.get("price_spark", PackedFloat32Array()),
			"delta": float(row.get("price_delta", NAN)),
			"icon": &"metric.goods",
		},
		{
			"id": "good_anchor_ratio",
			"title": "价格锚比",
			"value": price_index,
			"kind": "text",
			"text": price_index_text if has_anchor else "",
			"caption": price_index_caption,
			"tone": price_tone,
			"positive_good": false,
			"icon": &"trend.up" if price_index > 1.05 else (&"trend.down" if price_index < 0.95 else &"trend.flat"),
		},
		{
			"id": "good_stock",
			"title": "本地库存",
			"value": stock_units,
			"kind": "text",
			"text": UITokens.format_compact_number_cn(stock_units, 1),
			"caption": stock_caption,
			"tone": "risk" if (total_demand > 0.01 and days_of_stock < 3.0) else "",
			"positive_good": true,
			"spark": row.get("stock_spark", PackedFloat32Array()),
			"delta": float(row.get("stock_delta", NAN)),
			"icon": &"economy.resource",
			"tooltip": "本地库存：%s\n%s" % [stock_plain, stock_caption],
		},
		{
			"id": "good_balance",
			"title": "供需状态",
			"value": shortage_ratio,
			"kind": "text",
			"text": balance_text,
			"caption": balance_caption,
			"tone": "risk" if shortage_ratio >= 0.25 else ("warn" if shortage_ratio >= 0.05 or net_supply < -0.05 else ""),
			"positive_good": false,
			"icon": &"status.warning" if shortage_ratio >= 0.25 else &"summary.overview",
		},
	]

	# 物资卷宗不再附修饰性批注；短缺/盈余由 KPI 与条形图直接表达。
	var insights = []

	var flow_peak = maxf(maxf(total_demand, supply_units), 0.001)
	var demand_supply_bars = [
		{
			"id": "hh_demand",
			"label": "居民需求",
			"icon": &"population.heart",
			"value": clampf(hh_demand / flow_peak, 0.0, 1.0) if (total_demand > 0.0 or supply_units > 0.0) else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(hh_demand, 2),
			"color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "本地各阶层居民日常消费需求",
		},
		{
			"id": "biz_demand",
			"label": "产业需求",
			"icon": &"economy.building.factory",
			"value": clampf(biz_demand / flow_peak, 0.0, 1.0) if (total_demand > 0.0 or supply_units > 0.0) else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(biz_demand, 2),
			"color": UITokens.DOSSIER_BRASS,
			"tooltip": "本地生产建筑与在建工程的原料需求",
		},
		{
			"id": "local_supply",
			"label": "本地供给",
			"icon": &"economy.building.farm",
			"value": clampf(supply_units / flow_peak, 0.0, 1.0) if (total_demand > 0.0 or supply_units > 0.0) else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(supply_units, 2),
			"color": UITokens.DOSSIER_VERDIGRIS,
			"tooltip": "本地建筑向市场提供的日常供给",
		},
	]

	var price_stock_bars = [
		{
			"id": "price_anchor_bar",
			"label": "价格指数",
			"icon": &"metric.goods",
			"value": clampf(price_index / 2.0, 0.0, 1.0) if has_anchor else 0.5,
			"marker": 0.5,
			"text": price_index_text if has_anchor else price_text,
			"color": UITokens.DOSSIER_OXBLOOD if price_index > 1.05 else (UITokens.DOSSIER_VERDIGRIS if price_index < 0.95 else UITokens.DOSSIER_BRASS),
			"tooltip": "竖线刻度为成本锚基准（1.00 倍 = %s），当前时价 %s" % [anchor_text, price_text],
		},
		{
			"id": "shortage_bar",
			"label": "短缺率",
			"icon": &"status.warning",
			"value": clampf(shortage_ratio, 0.0, 1.0),
			"text": "%.1f%%" % (shortage_ratio * 100.0),
			"color": UITokens.DOSSIER_OXBLOOD if shortage_ratio >= 0.25 else (UITokens.DOSSIER_BRASS if shortage_ratio >= 0.05 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "买方未能买到所需物资的比例",
		},
		{
			"id": "stock_days_bar",
			"label": "库存保障",
			"icon": &"economy.resource",
			"value": clampf(days_of_stock / 60.0, 0.0, 1.0) if stock_units > 0.0 else 0.0,
			"text": "充裕" if (days_of_stock >= 180.0 and stock_units > 0.0) else ("%d 日" % int(days_of_stock) if total_demand > 0.001 else stock_plain),
			"color": UITokens.DOSSIER_VERDIGRIS if days_of_stock >= 15.0 else (UITokens.DOSSIER_BRASS if days_of_stock >= 5.0 else UITokens.DOSSIER_OXBLOOD),
			"tooltip": "按当前日需求估算，现有库存（%s）可支撑的天数" % stock_plain,
		},
	]

	var trade_peak = maxf(maxf(inbound_units, outbound_units), maxf(maxf(import_flow_units, export_flow_units), 0.001))
	var has_any_trade = inbound_units > 0.0 or outbound_units > 0.0 or import_flow_units > 0.0 or export_flow_units > 0.0
	var trade_bars = [
		{
			"id": "trade_import_flow",
			"label": "日均进口",
			"icon": &"trend.up",
			"value": clampf(import_flow_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(import_flow_units, 2),
			"color": UITokens.DOSSIER_VERDIGRIS,
			"tooltip": "外地向本地市场输入的日均流量",
		},
		{
			"id": "trade_export_flow",
			"label": "日均出口",
			"icon": &"trend.down",
			"value": clampf(export_flow_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s/日" % UITokens.format_compact_number_cn(export_flow_units, 2),
			"color": UITokens.DOSSIER_OXBLOOD,
			"tooltip": "本地市场向外地输出的日均流量",
		},
		{
			"id": "trade_inbound",
			"label": "在途运入",
			"icon": &"tax.tariff",
			"value": clampf(inbound_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s 单位" % UITokens.format_compact_number_cn(inbound_units, 2),
			"color": UITokens.DOSSIER_SLATE,
			"tooltip": "商队正在运往本地的在途货物总量",
		},
		{
			"id": "trade_outbound",
			"label": "在途运出",
			"icon": &"tax.tariff",
			"value": clampf(outbound_units / trade_peak, 0.0, 1.0) if has_any_trade else 0.0,
			"text": "%s 单位" % UITokens.format_compact_number_cn(outbound_units, 2),
			"color": UITokens.DOSSIER_BRASS,
			"tooltip": "商队正从本地运往外地的在途货物总量",
		},
	]

	return {
		"kpis": kpis,
		"insights": insights,
		"supply_demand_bar": {
			"left_label": "本地需求",
			"left_value": total_demand,
			"left_text": "%s/日" % UITokens.format_compact_number_cn(total_demand, 2),
			"right_label": "本地供给",
			"right_value": supply_units,
			"right_text": "%s/日" % UITokens.format_compact_number_cn(supply_units, 2),
		},
		"demand_supply_bars": demand_supply_bars,
		"price_stock_bars": price_stock_bars,
		"trade_flow_bar": {
			"left_label": "外销流出",
			"left_value": export_flow_units + outbound_units,
			"left_text": "%s/日" % UITokens.format_compact_number_cn(export_flow_units, 2),
			"right_label": "采购流入",
			"right_value": import_flow_units + inbound_units,
			"right_text": "%s/日" % UITokens.format_compact_number_cn(import_flow_units, 2),
		},
		"trade_bars": trade_bars,
	}


## 阶层详情卷宗视图模型：提炼 4 格 KPI、7 档生活水平刻度、8 维满意度雷达/短板条、
## 收支对冲与堆叠条、按用途分组的消费结构条，以及零消费替代品折叠摘要。

static func cohort_dossier_model(row: Dictionary) -> Dictionary:
	var pop_text = String(row.get("population", "—"))
	var pop_raw = int(row.get("population_raw", int(_parse_leading_float(pop_text, 0.0))))
	var employed_raw = int(row.get("employed_raw", -1))
	var identity_text = String(row.get("cohort_identity", "本地人口"))
	if identity_text.is_empty():
		identity_text = "本地常住"
	var wealth_text = String(row.get("wealth", "—")).trim_prefix("人均 ").strip_edges()
	var living_name = String(row.get("living_standard", "待评估"))
	var living_level = int(row.get("living_level", -1))
	if living_level < 0:
		living_level = ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"].find(living_name)
	var sat_text = String(row.get("satisfaction", "—"))
	var sat_float = float(row.get("satisfaction_float", _parse_leading_float(sat_text, 0.0) / 100.0))
	var worst_dim_name = String(row.get("worst_dimension", "—"))
	var income_text = String(row.get("income", "—"))
	var expense_text = String(row.get("expense", "—"))
	var net_text = String(row.get("net", "—"))
	var income_float = float(row.get("income_pc_float", absf(_parse_leading_float(income_text, 0.0))))
	var expense_float = float(row.get("expense_pc_float", absf(_parse_leading_float(expense_text, 0.0))))
	var net_float = float(row.get("net_pc_float", _parse_leading_float(net_text, income_float - expense_float)))
	var net_positive = bool(row.get("net_positive", net_float >= -1e-6))

	var pop_caption = identity_text
	if employed_raw >= 0:
		pop_caption = "就业 %s 人 · %s" % [
			UITokens.format_compact_number_cn(float(employed_raw), 1), identity_text]

	var kpis = [
		{
			"id": "cohort_population",
			"title": "阶层人口",
			"value": float(pop_raw),
			"kind": "text",
			"text": pop_text,
			"caption": pop_caption,
			"positive_good": true,
			"icon": StringName(row.get("icon", "population.profession.worker")),
		},
		{
			"id": "cohort_living",
			"title": "生活水平",
			"value": float(maxi(0, living_level)),
			"kind": "text",
			"text": living_name,
			"caption": "人均存款 %s" % wealth_text,
			"tone": "risk" if (living_level >= 0 and living_level <= 1) else ("warn" if living_level == 2 else ""),
			"positive_good": true,
			"icon": &"family.metric.wealth",
		},
		{
			"id": "cohort_satisfaction",
			"title": "综合满意度",
			"value": sat_float,
			"kind": "text",
			"text": sat_text,
			"caption": ("短板：%s" % worst_dim_name) if (not worst_dim_name.is_empty() and worst_dim_name != "—") else "各维均衡",
			"tone": "risk" if sat_float < 0.40 else ("warn" if sat_float < 0.65 else ""),
			"positive_good": true,
			"spark": row.get("satisfaction_spark", PackedFloat32Array()),
			"delta": float(row.get("satisfaction_delta", NAN)),
			"icon": &"population.heart",
		},
		{
			"id": "cohort_net",
			"title": "人均日净收",
			"value": net_float,
			"kind": "text",
			"text": net_text,
			"caption": "收 %s · 支 %s" % [income_text, expense_text],
			"tone": "" if net_positive else "risk",
			"positive_good": true,
			"spark": row.get("net_spark", PackedFloat32Array()),
			"delta": float(row.get("net_delta", NAN)),
			"icon": &"trend.up" if net_positive else &"trend.down",
		},
	]

	var sat_rows: Array = row.get("satisfaction_rows", [])
	var dims_float: PackedFloat32Array = row.get("satisfaction_dims_float", PackedFloat32Array())
	var ref_dims_float: PackedFloat32Array = row.get("cell_reference_dims_float", PackedFloat32Array())
	var radar_axes = PackedStringArray(SATISFACTION_DIMENSION_NAMES)
	var radar_values = dims_float.duplicate()
	if radar_values.size() != SATISFACTION_DIMENSION_NAMES.size():
		radar_values.resize(SATISFACTION_DIMENSION_NAMES.size())
		for d in range(SATISFACTION_DIMENSION_NAMES.size()):
			radar_values[d] = sat_float
		for raw_s in sat_rows:
			if not (raw_s is Dictionary):
				continue
			var sdict: Dictionary = raw_s
			var sname = String(sdict.get("name", ""))
			var sidx = SATISFACTION_DIMENSION_NAMES.find(sname)
			if sidx >= 0:
				radar_values[sidx] = clampf(_parse_leading_float(sdict.get("value", "0"), 0.0) / 100.0, 0.0, 1.0)

	var dimension_bars = []
	if not sat_rows.is_empty():
		for idx in range(sat_rows.size()):
			var sdict: Dictionary = sat_rows[idx]
			if not bool(sdict.get("visible", true)):
				continue
			var sname = String(sdict.get("name", ""))
			var sval_text = String(sdict.get("value", "0%"))
			var sval = clampf(_parse_leading_float(sval_text, 0.0) / 100.0, 0.0, 1.0)
			var is_worst = bool(sdict.get("worst", sname == worst_dim_name))
			var marker = ref_dims_float[idx] if idx < ref_dims_float.size() and bool(sdict.get("applicable", true)) else -1.0
			var color = UITokens.DOSSIER_OXBLOOD if (is_worst or sval < 0.45) \
				else (UITokens.DOSSIER_BRASS if sval < 0.72 else UITokens.DOSSIER_VERDIGRIS)
			dimension_bars.append({
				"id": String(sdict.get("id", "dim_%d" % idx)),
				"label": sname,
				"value": sval,
				"marker": marker,
				"text": sval_text,
				"color": color if bool(sdict.get("applicable", true)) else UITokens.DOSSIER_RULE,
				"text_color": UITokens.DOSSIER_INK_MUTED if not bool(sdict.get("applicable", true)) else (UITokens.DOSSIER_OXBLOOD if is_worst else UITokens.DOSSIER_INK),
				"tooltip": String(sdict.get("tooltip", "")) + "\n" + "%s满意度 %s%s%s" % [
					sname, sval_text,
					"（当前最短板）" if is_worst else "",
					("（本地均值 %.0f%%）" % (marker * 100.0)) if marker >= 0.0 else ""],
			})

	# 阶层卷宗不再附修饰性批注；短板与收支由条形图/KPI 表达。
	var insights = []

	var income_segments = []
	var income_rows: Array = row.get("income_rows", [])
	for idx in range(income_rows.size()):
		var ir: Dictionary = income_rows[idx]
		if not bool(ir.get("visible", true)):
			continue
		var vtext = String(ir.get("value", ""))
		var vnum = maxf(0.0001, float(ir.get("raw_per_capita", absf(_parse_leading_float(vtext, 0.0)))))
		income_segments.append({
			"label": String(ir.get("name", "收入")),
			"value": vnum,
			"text": vtext,
			"color": DOSSIER_INCOME_COLORS[idx % DOSSIER_INCOME_COLORS.size()],
		})

	var expense_segments = []
	var expense_rows: Array = row.get("expense_rows", [])
	for idx in range(expense_rows.size()):
		var er: Dictionary = expense_rows[idx]
		if not bool(er.get("visible", true)):
			continue
		var vtext = String(er.get("value", ""))
		var vnum = maxf(0.0001, float(er.get("raw_per_capita", absf(_parse_leading_float(vtext, 0.0)))))
		expense_segments.append({
			"label": String(er.get("name", "支出")),
			"value": vnum,
			"text": vtext,
			"color": DOSSIER_EXPENSE_COLORS[idx % DOSSIER_EXPENSE_COLORS.size()],
		})

	var demand_groups: Array = row.get("demand_groups", [])
	var demand_tier_bars = []
	for idx in range(demand_groups.size()):
		var grp: Dictionary = demand_groups[idx]
		var gname = String(grp.get("name", "消费"))
		var sat_str = String(grp.get("satisfaction", ""))
		var sat_ratio = float(grp.get("satisfaction_ratio",
			_parse_leading_float(sat_str, 100.0) / 100.0 if not sat_str.is_empty() else 1.0))
		var clamped_sat = clampf(sat_ratio, 0.0, 1.0)
		var grp_cost_raw = int(grp.get("daily_cost_raw", 0))
		var right_text = sat_str.trim_prefix("满足 ") if not sat_str.is_empty() else "%.0f%%" % (clamped_sat * 100.0)
		if grp_cost_raw > 0:
			right_text = "%s · 支 %s" % [
				right_text,
				UITokens.format_compact_number_cn(float(grp_cost_raw) / 10000.0, 2)]
		demand_tier_bars.append({
			"id": String(grp.get("id", "tier_%d" % idx)),
			"label": gname,
			"icon": &"population.heart",
			"value": clamped_sat,
			"text": right_text,
			"color": UITokens.DOSSIER_OXBLOOD if clamped_sat < 0.45 else (UITokens.DOSSIER_BRASS if clamped_sat < 0.75 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "用途【%s】%s" % [gname, sat_str if not sat_str.is_empty() else right_text],
		})

	var demand_rows: Array = row.get("demand_rows", [])
	var active_candidates = []
	var inactive_names = PackedStringArray()
	var peak_metric = 0.0001
	for raw_d in demand_rows:
		if not (raw_d is Dictionary):
			continue
		var drow: Dictionary = raw_d
		if not bool(drow.get("visible", true)):
			continue
		var dname = String(drow.get("name", ""))
		var qty_float = float(drow.get("quantity_raw", -1)) / 1000.0 \
			if drow.has("quantity_raw") \
			else _parse_leading_float(drow.get("quantity", drow.get("value", "0")), 0.0)
		var cost_float = float(drow.get("daily_cost_raw", -1)) / 10000.0 \
			if int(drow.get("daily_cost_raw", -1)) >= 0 \
			else _parse_leading_float(drow.get("daily_cost", "0"), 0.0)
		if qty_float <= 0.00001:
			if not dname.is_empty():
				inactive_names.append(dname)
			continue
		var metric = cost_float if cost_float > 0.00001 else qty_float
		peak_metric = maxf(peak_metric, metric)
		active_candidates.append({
			"row": drow,
			"qty": qty_float,
			"cost": cost_float,
			"metric": metric,
		})
	active_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.metric) > float(b.metric))

	var active_demand_bars = []
	for item in active_candidates:
		var drow: Dictionary = item.row
		var dname = String(drow.get("name", ""))
		var qty_text = String(drow.get("quantity", ""))
		if qty_text.is_empty():
			qty_text = String(drow.get("value", "")).replace(" 单位/人/日", "")
		var cost_text = String(drow.get("daily_cost", ""))
		var right_text = "%s/日" % qty_text
		if not cost_text.is_empty() and cost_text != "—":
			right_text = "支 %s · %s" % [cost_text, qty_text]
		var wealth_delta = int(drow.get("wealth_delta_raw", 0))
		var price_delta = int(drow.get("price_delta_raw", 0))
		var drivers = PackedStringArray()
		if wealth_delta > 0:
			drivers.append("财富拉动 +%s" % UITokens.format_compact_number_cn(float(wealth_delta) / 1000.0, 3))
		elif wealth_delta < 0:
			drivers.append("贫困抑制 %s" % UITokens.format_compact_number_cn(float(wealth_delta) / 1000.0, 3))
		if price_delta < 0:
			drivers.append("高价抑制 %s" % UITokens.format_compact_number_cn(float(price_delta) / 1000.0, 3))
		elif price_delta > 0:
			drivers.append("低价促进 +%s" % UITokens.format_compact_number_cn(float(price_delta) / 1000.0, 3))
		var need_names: Array = drow.get("need_names", [])
		var tip_lines = PackedStringArray([
			"%s：%s 单位/人/日" % [dname, qty_text],
		])
		if not cost_text.is_empty() and cost_text != "—":
			tip_lines.append("单价 %s · 日均开销 %s/人" % [String(drow.get("price", "—")), cost_text])
		if not need_names.is_empty():
			tip_lines.append("满足用途：%s" % "、".join(need_names))
		if not drivers.is_empty():
			tip_lines.append("弹性归因：%s" % "，".join(drivers))
		var bar_color = UITokens.DOSSIER_BRASS
		if price_delta < -10:
			bar_color = UITokens.DOSSIER_OXBLOOD
		elif wealth_delta > 10:
			bar_color = UITokens.DOSSIER_VERDIGRIS
		active_demand_bars.append({
			"id": String(drow.get("id", "demand_" + dname)),
			"label": dname,
			"icon": StringName(drow.get("icon", &"metric.goods")),
			"value": clampf(float(item.metric) / peak_metric, 0.0, 1.0),
			"text": right_text,
			"color": bar_color,
			"tooltip": "\n".join(tip_lines),
		})

	var inactive_summary = ""
	if not inactive_names.is_empty():
		var preview = PackedStringArray()
		for idx in range(mini(4, inactive_names.size())):
			preview.append(inactive_names[idx])
		inactive_summary = "未采购替代品：另有 %s%s（共 %d 种）已解锁商品因本地无货或性价比偏低暂未消费。" % [
			"、".join(preview),
			" 等" if inactive_names.size() > preview.size() else "",
			inactive_names.size(),
		]

	return {
		"kpis": kpis,
		"insights": insights,
		"living_level": living_level,
		"living_name": living_name,
		"wealth_text": wealth_text,
		"radar_axes": radar_axes,
		"radar_values": radar_values,
		"radar_reference": ref_dims_float,
		"dimension_bars": dimension_bars,
		"cashflow_bar": {
			"left_label": "人均日支",
			"left_value": expense_float,
			"left_text": expense_text,
			"right_label": "人均日收",
			"right_value": income_float,
			"right_text": income_text,
		},
		"income_segments": income_segments,
		"expense_segments": expense_segments,
		"demand_tier_bars": demand_tier_bars,
		"active_demand_bars": active_demand_bars,
		"inactive_alternatives_summary": inactive_summary,
	}


## 建筑详情卷宗视图模型：提炼 4 格 KPI、经营诊断批注、产能与气候适宜横条、
## 岗位配置横条、投入产出结构横条（折叠未使用的可选替代原料），以及营收与成本堆叠对冲。

static func building_dossier_model(row: Dictionary) -> Dictionary:
	var count_text = String(row.get("count", "1 栋"))
	var count_raw = maxi(1, int(row.get("count_raw", int(_parse_leading_float(count_text, 1.0)))))
	var owner_raw = String(row.get("owner", "业主 · 本地产业"))
	var owner_short = owner_raw.trim_prefix("业主 · ").strip_edges()
	var status_text = String(row.get("status", "正常运转"))
	var profit_label = String(row.get("profit_label", "利润"))
	var profit_text = String(row.get("profit", "—"))
	var profit_val = float(row.get("profit_float", _parse_leading_float(profit_text, 0.0)))

	var job_rows: Array = row.get("job_rows", [])
	var staff_actual = int(row.get("staffing_actual_raw", -1))
	var staff_req = int(row.get("staffing_required_raw", -1))
	if staff_actual < 0 or staff_req < 0:
		staff_actual = 0
		staff_req = 0
		for raw_j in job_rows:
			if not (raw_j is Dictionary):
				continue
			var jval = String((raw_j as Dictionary).get("value", ""))
			var slash = jval.find("/")
			if slash >= 0:
				staff_actual += int(_parse_leading_float(jval.substr(0, slash), 0.0))
				staff_req += int(_parse_leading_float(jval.substr(slash + 1), 0.0))
	var staff_ratio = float(staff_actual) / float(staff_req) if staff_req > 0 else 1.0
	var staff_text = "%d / %d" % [staff_actual, staff_req] if staff_req > 0 else "—"

	var actual_util = float(row.get("actual_utilization_float", -1.0))
	var planned_util = float(row.get("planned_utilization_float", 1.0))
	if actual_util < 0.0:
		var cap_pos = status_text.find("产能")
		if cap_pos >= 0:
			actual_util = clampf(_parse_leading_float(status_text.substr(cap_pos + 2), 100.0) / 100.0, 0.0, 1.0)
		elif status_text.find("停") >= 0 or profit_text.find("停") >= 0:
			actual_util = 0.0
		else:
			actual_util = 1.0

	var state_summary: Dictionary = row.get("state_summary", {})
	var is_halted = not state_summary.is_empty() or status_text.find("停") >= 0
	var util_text = String(state_summary.get("label", "停产")) if is_halted \
		else ("%.0f%%" % (actual_util * 100.0))
	var util_caption = "正常运转"
	if is_halted:
		util_caption = String(state_summary.get("detail", "本期暂停生产"))
	elif planned_util < 0.995:
		util_caption = "计划限产 %.0f%%" % (planned_util * 100.0)
	elif actual_util < 0.995:
		util_caption = "受人力或环境制约"
	else:
		util_caption = "满负荷运转"

	var finance: Dictionary = row.get("finance", {})
	var rev_text = String(finance.get("revenue", "—"))
	var cost_text = String(finance.get("cost", "—"))
	var profit_positive = bool(finance.get("profit_positive", not profit_text.begins_with("-") and not profit_text.begins_with("−") and not is_halted))
	var profit_caption = status_text
	if not finance.is_empty():
		profit_caption = "收 %s · 支 %s" % [rev_text, cost_text]

	var kpis = [
		{
			"id": "building_scale",
			"title": "建筑规模",
			"value": float(count_raw),
			"kind": "text",
			"text": count_text,
			"caption": "业主：%s" % owner_short if not owner_short.is_empty() else status_text,
			"positive_good": true,
			"icon": StringName(row.get("icon", &"economy.building")),
		},
		{
			"id": "building_utilization",
			"title": "产能出力",
			"value": actual_util,
			"kind": "text",
			"text": util_text,
			"caption": util_caption,
			"tone": "risk" if (is_halted or actual_util < 0.25) else ("warn" if actual_util < 0.75 else ""),
			"positive_good": true,
			"spark": row.get("utilization_spark", PackedFloat32Array()),
			"delta": float(row.get("utilization_delta", NAN)),
			"icon": &"economy.building.factory",
		},
		{
			"id": "building_staffing",
			"title": "岗位到岗",
			"value": staff_ratio,
			"kind": "text",
			"text": staff_text,
			"caption": ("到岗 %.0f%%" % (staff_ratio * 100.0)) if staff_req > 0 else "",
			"tone": "risk" if (staff_req > 0 and staff_ratio < 0.5) else ("warn" if (staff_req > 0 and staff_ratio < 0.99) else ""),
			"positive_good": true,
			"icon": &"population.profession.worker",
		},
		{
			"id": "building_profit",
			"title": "本期%s" % profit_label if profit_label in ["利润", "亏损"] else profit_label,
			"value": profit_val,
			"kind": "text",
			"text": profit_text,
			"caption": profit_caption,
			"tone": "risk" if (is_halted or not profit_positive) else "",
			"positive_good": true,
			"spark": row.get("profit_spark", PackedFloat32Array()),
			"delta": float(row.get("profit_delta", NAN)),
			"icon": &"trend.up" if (profit_positive and not is_halted) else &"trend.down",
		},
	]

	# 仅保留真实经营异常；气候减产与「正常运转」叙述性批注去掉。
	var insights = []
	if not state_summary.is_empty():
		var slabel = String(state_summary.get("label", "经营异常"))
		var sdetail = String(state_summary.get("detail", ""))
		var smeta = String(state_summary.get("meta", ""))
		var line = "%s：%s" % [slabel, sdetail] if not sdetail.is_empty() else slabel
		if not smeta.is_empty():
			line += "（%s）" % smeta
		insights.append({
			"id": "building_state_alert",
			"text": line,
			"accent": UITokens.DOSSIER_OXBLOOD,
			"icon": "status.warning",
		})

	var capacity_bars = [
		{
			"id": "cap_actual",
			"label": "实际产能",
			"icon": &"economy.building.factory",
			"value": clampf(actual_util, 0.0, 1.0),
			"marker": clampf(planned_util, 0.0, 1.0) if planned_util < 0.995 else -1.0,
			"text": util_text,
			"color": UITokens.DOSSIER_OXBLOOD if actual_util < 0.25 else (UITokens.DOSSIER_BRASS if actual_util < 0.75 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "计划上限 %.1f%%" % (planned_util * 100.0),
		},
	]
	if bool(row.get("has_climate_profile", false)):
		var climate_cap = clampf(float(row.get("climate_capacity_float", 1.0)), 0.0, 1.0)
		var temp_fit = clampf(float(row.get("temperature_fit_float", 1.0)), 0.0, 1.0)
		var water_fit = clampf(float(row.get("water_fit_float", 1.0)), 0.0, 1.0)
		capacity_bars.append({
			"id": "cap_climate",
			"label": "气候出力",
			"icon": &"climate",
			"value": climate_cap,
			"text": "%.0f%%" % (climate_cap * 100.0),
			"color": UITokens.DOSSIER_VERDIGRIS if climate_cap >= 0.90 else (UITokens.DOSSIER_BRASS if climate_cap >= 0.60 else UITokens.DOSSIER_OXBLOOD),
			"tooltip": "温度适宜度 %.1f%% · 水分适宜度 %.1f%% · 综合气候出力 %.1f%%" % [
				temp_fit * 100.0, water_fit * 100.0, climate_cap * 100.0],
		})
		if temp_fit < 0.995 or water_fit < 0.995:
			capacity_bars.append({
				"id": "cap_temp",
				"label": "温度适宜",
				"value": temp_fit,
				"text": "%.0f%%" % (temp_fit * 100.0),
				"color": UITokens.DOSSIER_VERDIGRIS if temp_fit >= 0.85 else UITokens.DOSSIER_BRASS,
			})
			capacity_bars.append({
				"id": "cap_water",
				"label": "水分适宜",
				"value": water_fit,
				"text": "%.0f%%" % (water_fit * 100.0),
				"color": UITokens.DOSSIER_SLATE if water_fit >= 0.85 else UITokens.DOSSIER_BRASS,
			})

	var job_bars = []
	for idx in range(job_rows.size()):
		var raw_j = job_rows[idx]
		if not (raw_j is Dictionary):
			continue
		var jdict: Dictionary = raw_j
		if not bool(jdict.get("visible", true)):
			continue
		var jname = String(jdict.get("name", "岗位"))
		var jval = String(jdict.get("value", "0 / 0"))
		var jratio = float(jdict.get("ratio", -1.0))
		if jratio < 0.0:
			var slash = jval.find("/")
			if slash >= 0:
				var f = _parse_leading_float(jval.substr(0, slash), 0.0)
				var r = _parse_leading_float(jval.substr(slash + 1), 0.0)
				jratio = f / r if r > 0.0 else 1.0
			else:
				jratio = 1.0
		var clamped_j = clampf(jratio, 0.0, 1.0)
		var is_owner_row = jname.begins_with("业主")
		job_bars.append({
			"id": String(jdict.get("id", "job_%d" % idx)),
			"label": jname,
			"icon": &"family.metric.wealth" if is_owner_row else &"population.profession.worker",
			"value": clamped_j,
			"text": jval.split("（")[0].strip_edges(),
			"color": UITokens.DOSSIER_OXBLOOD if clamped_j < 0.50 else (UITokens.DOSSIER_BRASS if clamped_j < 0.99 else UITokens.DOSSIER_VERDIGRIS),
			"tooltip": "%s：%s" % [jname, jval],
		})

	var prod_rows: Array = row.get("production_rows", [])
	var production_candidates = []
	var unused_input_notes = PackedStringArray()
	var prod_peak = 0.001
	var has_natural_input = false
	var has_natural_gen = false
	for raw_p in prod_rows:
		if not (raw_p is Dictionary):
			continue
		var pdict: Dictionary = raw_p
		var pid = String(pdict.get("id", ""))
		if pid.begins_with("natural_input"):
			has_natural_input = true
		elif pid.begins_with("natural_generation"):
			has_natural_gen = true

	for idx in range(prod_rows.size()):
		var raw_p = prod_rows[idx]
		if not (raw_p is Dictionary):
			continue
		var pdict: Dictionary = raw_p
		var pid = String(pdict.get("id", "prod_%d" % idx))
		if pid in ["climate_fit", "climate_lost_output", "input_none", "output_none"]:
			continue
		# 仅在同时有培育与消耗时才显示“自然资源净额”，避免与单向消耗行重复。
		if pid == "resource_net" and not (has_natural_input and has_natural_gen):
			continue
		var full_name = String(pdict.get("name", ""))
		var short_name = String(pdict.get("short_name", full_name))
		var val_str = String(pdict.get("value", ""))
		var rate_num = float(pdict.get("daily_per_building_float", absf(_parse_leading_float(val_str, 0.0))))
		var is_input = pid.begins_with("input_") or full_name.begins_with("原材料")
		if is_input and rate_num <= 0.00001:
			var cand_desc = String(pdict.get("candidates_detail", full_name.trim_prefix("原材料 · ")))
			if not cand_desc.is_empty() and cand_desc != "无":
				unused_input_notes.append(cand_desc)
			continue
		if short_name.length() > 14 and short_name.find("/") >= 0:
			var first_part = short_name.split("/")[0].strip_edges()
			short_name = "%s等" % first_part
		var compact_val = val_str.replace(" 单位/栋/日", "/栋/日")
		prod_peak = maxf(prod_peak, rate_num)
		var bar_color = UITokens.DOSSIER_VERDIGRIS
		var icon_key = &"metric.goods"
		if pid.begins_with("output_") or full_name.begins_with("产出"):
			bar_color = UITokens.DOSSIER_VERDIGRIS
			icon_key = &"metric.goods"
		elif pid.begins_with("natural_") or pid == "resource_net":
			bar_color = UITokens.DOSSIER_SLATE if val_str.find("不足") < 0 else UITokens.DOSSIER_OXBLOOD
			icon_key = &"economy.resource"
		else:
			bar_color = UITokens.DOSSIER_BRASS
			icon_key = &"economy.building.factory"
		production_candidates.append({
			"id": pid,
			"label": short_name,
			"icon": icon_key,
			"rate": rate_num,
			"text": compact_val,
			"color": bar_color,
			"tooltip": "%s：%s" % [full_name, val_str],
		})

	var production_bars = []
	for item in production_candidates:
		var rate = float(item.rate)
		production_bars.append({
			"id": item.id,
			"label": item.label,
			"icon": item.icon,
			"value": clampf(rate / prod_peak, 0.08 if rate > 0.0 else 0.0, 1.0),
			"text": item.text,
			"color": item.color,
			"tooltip": item.tooltip,
		})

	var unused_inputs_summary = ""
	if not unused_input_notes.is_empty():
		unused_inputs_summary = "可选增产投入（当前未消耗）：%s。" % "；".join(unused_input_notes)

	var cash_rev = float(finance.get("cash_revenue_float", 0.0))
	var in_kind_rev = float(finance.get("in_kind_float", 0.0))
	var subsidy_rev = float(finance.get("subsidy_float", 0.0))
	var total_rev = float(finance.get("revenue_float", _parse_leading_float(rev_text, cash_rev + in_kind_rev)))
	var input_cost_val = float(finance.get("input_cost_float", 0.0))
	var wages_val = float(finance.get("wages_paid_float", 0.0))
	var tax_val = float(finance.get("business_tax_float", 0.0))
	var total_cost = float(finance.get("cost_float", _parse_leading_float(cost_text, input_cost_val + wages_val + tax_val)))

	# 兼容未携带细分浮点字段的旧字典（按 breakdown 解析）
	if cash_rev <= 0.0 and in_kind_rev <= 0.0 and total_rev > 0.0:
		cash_rev = total_rev
	var revenue_segments = []
	if cash_rev > 0.0001:
		revenue_segments.append({
			"label": "市场销售",
			"value": cash_rev,
			"text": String(finance.get("cash_revenue_text", UITokens.format_compact_number_cn(cash_rev, 2))),
			"color": UITokens.DOSSIER_VERDIGRIS,
		})
	if in_kind_rev > 0.0001:
		revenue_segments.append({
			"label": "自用留存折算",
			"value": in_kind_rev,
			"text": String(finance.get("in_kind_text", UITokens.format_compact_number_cn(in_kind_rev, 2))),
			"color": UITokens.DOSSIER_BRASS,
		})
	if subsidy_rev > 0.0001:
		revenue_segments.append({
			"label": "经营补贴",
			"value": subsidy_rev,
			"text": String(finance.get("subsidy_text", UITokens.format_compact_number_cn(subsidy_rev, 2))),
			"color": UITokens.DOSSIER_SLATE,
		})

	var cost_segments = []
	if input_cost_val > 0.0001:
		cost_segments.append({
			"label": "原料采购",
			"value": input_cost_val,
			"text": String(finance.get("input_cost_text", UITokens.format_compact_number_cn(input_cost_val, 2))),
			"color": UITokens.DOSSIER_OXBLOOD,
		})
	if wages_val > 0.0001:
		cost_segments.append({
			"label": "雇员工资",
			"value": wages_val,
			"text": String(finance.get("wages_paid_text", UITokens.format_compact_number_cn(wages_val, 2))),
			"color": UITokens.DOSSIER_BRASS,
		})
	if tax_val > 0.0001:
		cost_segments.append({
			"label": "营业税费",
			"value": tax_val,
			"text": String(finance.get("business_tax_text", UITokens.format_compact_number_cn(tax_val, 2))),
			"color": UITokens.DOSSIER_UMBER,
		})

	var finance_note = ""
	if cost_segments.is_empty() and not finance.is_empty():
		finance_note = "本期无外购原料、雇员薪资与营业税支出（业主自营收益已计入总收入）。"

	return {
		"kpis": kpis,
		"insights": insights,
		"capacity_bars": capacity_bars,
		"job_bars": job_bars,
		"production_bars": production_bars,
		"unused_inputs_summary": unused_inputs_summary,
		"finance_diverging_bar": {
			"left_label": "本期总成本",
			"left_value": total_cost,
			"left_text": cost_text if cost_text != "—" else "0",
			"right_label": "税后总收入",
			"right_value": total_rev,
			"right_text": rev_text if rev_text != "—" else "0",
		},
		"revenue_segments": revenue_segments,
		"cost_segments": cost_segments,
		"finance_note": finance_note,
		"finance_warning": String(finance.get("warning", "")),
	}


static func build_object_detail(host, cell: HexCell, request: Dictionary) -> Dictionary:
	if cell == null or host._map == null:
		return {}
	var kind = String(request.get("kind", ""))
	var row_id = String(request.get("row_id", ""))
	if not host.OBJECT_DETAIL_TAB.has(kind) or row_id.is_empty():
		return {}
	var idx = int(cell.index)
	if VisionSolver.fog_state(host._map, idx) != VisionSolver.FOG_VISIBLE:
		return {}
	var category = host.build_tab_category(cell, String(host.OBJECT_DETAIL_TAB[kind]))
	var row = {}
	var category_rows = host._rows_from_category(category, String(host.OBJECT_DETAIL_ROWS[kind]))
	for raw in category_rows:
		var candidate: Dictionary = raw
		if String(candidate.get("id", "")) == row_id:
			row = candidate
			break
	# 阶层行的 id 携带原生 (generation<<32|slot) handle，跨仿真日会随
	# slot 回收/迁移而失效；点击到重建之间若落了一次提交，按职业名
	# 回退匹配继任 cohort，保证点击总是打开同一职业的详情。
	if row.is_empty() and kind == "cohort":
		var fallback_profession = String(request.get("profession_id", ""))
		if not fallback_profession.is_empty():
			for raw in category_rows:
				var candidate: Dictionary = raw
				if String(candidate.get("profession_id", "")) == fallback_profession:
					row = candidate
					break
	if row.is_empty():
		if bool(category.get("data_pending", false)):
			return {"data_pending": true}
		return {}
	if kind == "family":
		var facade = host._generator.get_economy_facade() if host._generator != null \
			and host._generator.has_method("get_economy_facade") else null
		var family_handle = int(row.get("family_handle", 0))
		if facade != null and facade.has_method("family_snapshot"):
			var family_snapshot: Dictionary = facade.family_snapshot(family_handle)
			if bool(family_snapshot.get("ok", false)):
				row.merge(host._family_detail_fields(family_snapshot), true)
				var family_name = String(family_snapshot.get("family_name", "")).strip_edges()
				if not family_name.is_empty():
					row["name"] = family_name
			row["notable_person_rows"] = host._family_notable_person_rows(
				facade, family_handle)
			if facade.has_method("get_family_traits"):
				var traits: Dictionary = facade.get_family_traits(family_handle)
				if bool(traits.get("ok", false)):
					row["trait_rows"] = host._family_trait_rows(traits)
					row["behavior_rows"] = host._family_behavior_rows(traits, idx)
			if facade.has_method("family_branches"):
				var branches: Dictionary = facade.family_branches(
					family_handle, 0, 64)
				if bool(branches.get("ok", false)):
					row["branch_rows"] = host._family_branch_rows(branches)
					var modifier_rows: Array = []
					var trigger_rows: Array = []
					var effect_rows: Array = []
					var branch_cells: PackedInt32Array = branches.get(
						"cell_indices", PackedInt32Array())
					for branch_cell in branch_cells:
						if not facade.has_method("get_family_branch_effects"):
							break
						var effects: Dictionary = facade.get_family_branch_effects(
							family_handle, int(branch_cell))
						if not bool(effects.get("ok", false)):
							continue
						modifier_rows.append_array(
							host._family_modifier_rows(effects))
						trigger_rows.append_array(
							host._family_trigger_rows(effects))
						effect_rows.append_array(
							host._family_bound_effect_rows(effects))
						if int(branch_cell) == idx:
							row["prestige_level"] = int(
								effects.get("prestige_level", 0))
							row["prestige_score_q16"] = int(
								effects.get("prestige_score_q16", 0))
							row["prestige_score"] = host._q16_percent_text(int(
								effects.get("prestige_score_q16", 0)))
					row["modifier_rows"] = modifier_rows
					row["trigger_rows"] = trigger_rows
					row["effect_rows"] = effect_rows
	var item_id = host._object_tax_item_id(kind, row)
	var country = host._country_summary(idx)
	var off = HexUtils.cube_to_offset(cell.q, cell.r)
	var payload = {
		"kind": kind,
		"row_id": String(row.get("id", row_id)),
		"item_id": item_id,
		"name": host._object_display_name(kind, row, idx),
		"icon": String(row.get("icon", "resource")),
		"accent": row.get("accent", UITokens.ACCENT),
		"subtitle": "%s · 区域 %d, %d · %s" % [
			String(host.OBJECT_TYPE_LABELS[kind]), off.x + 1, off.y + 1,
			String(country.get("country_name", "无主之地"))],
		"tax_context": category.get("tax_context", {}),
		"row": row,
	}
	if kind == "good":
		# 逐单商路页：只在物资详情打开时按需构建；ViewModel 按 generation 缓存，
		# 日 tick 与 200ms live patch 只会命中模型缓存。
		payload["trade_orders"] = host.trade_orders_model(
			idx,
			String(row.get("good_id", "")),
			int(request.get("orders_offset", 0)),
			host.TRADE_ORDER_PAGE_SIZE,
			int(category.get("economy_generation", -1)),
			int(category.get("sample_day", host._current_sample_day())))
	return payload


static func build_family_detail(host, cell: HexCell, request: Dictionary) -> Dictionary:
	if String(request.get("kind", "")) != "family":
		return {}
	var detail = host.build_object_detail(cell, request)
	if bool(detail.get("data_pending", false)):
		return detail
	if detail.is_empty() or String(detail.get("kind", "")) != "family":
		return {}
	return host.family_workspace_model(detail)


static func _tax_lanes_from_policy(host,
		policy: Dictionary,
		object_kind: String,
		item_id: String,
		editable: bool
) -> Array:
	var lanes: Array = []
	if item_id.is_empty():
		return lanes
	var country_defaults = host._tax_basis_points_array(policy,
		"country_default_rates_basis_points", "country_default_rates")
	var local_defaults = host._tax_basis_points_array(policy,
		"local_default_rates_basis_points", "local_default_rates")
	var local_flags: PackedByteArray = policy.get(
		"has_local_default", PackedByteArray())
	var local_modes: PackedInt32Array = policy.get(
		"local_default_assessment_modes", PackedInt32Array())
	var country_modes: PackedInt32Array = policy.get(
		"country_default_assessment_modes", PackedInt32Array())
	for kind_value in host.OBJECT_TAX_KINDS.get(object_kind, []):
		var kind = String(kind_value)
		var group: Dictionary = policy.get(kind, {})
		var ids: PackedStringArray = group.get("item_ids", PackedStringArray())
		var item_index = ids.find(item_id)
		var rates = host._tax_group_basis_points(group, "final_base_rates")
		if item_index < 0 or item_index >= rates.size():
			continue
		var effective = host._tax_group_basis_points(group, "effective_rates", rates)
		var modes: PackedInt32Array = group.get(
			"assessment_modes", PackedInt32Array())
		var item_flags: PackedByteArray = group.get(
			"has_local_item", PackedByteArray())
		var country_bases = host._tax_group_basis_points(group, "country_base_rates")
		var kind_id = int(host.TAX_KIND_IDS.get(kind, -1))
		var inherited = int(local_defaults[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_defaults.size() \
			else (int(country_bases[item_index]) \
				if item_index < country_bases.size() else (int(country_defaults[kind_id]) \
					if kind_id >= 0 and kind_id < country_defaults.size() else 0))
		var inherited_mode = int(local_modes[kind_id]) \
			if kind_id >= 0 and kind_id < local_flags.size() \
			and local_flags[kind_id] != 0 and kind_id < local_modes.size() \
			else (int(country_modes[kind_id]) \
				if kind_id >= 0 and kind_id < country_modes.size() else 0)
		var mode = int(modes[item_index]) if item_index < modes.size() else inherited_mode
		lanes.append({
			"scope": "item", "kind": kind,
			"kind_label": String(host.TAX_KIND_LABELS.get(kind, kind)),
			"accent": host.TAX_KIND_ACCENTS.get(kind, UITokens.ACCENT),
			"item_id": item_id, "base": int(rates[item_index]),
			"effective": int(effective[item_index]) \
				if item_index < effective.size() else int(rates[item_index]),
			"mode": mode, "effective_mode": mode,
			"has_override": item_index < item_flags.size() \
				and item_flags[item_index] != 0,
			"default_rate": inherited, "default_mode": inherited_mode,
			"editable": editable,
		})
	return lanes


static func _building_category(host, snapshot: Dictionary, cell_idx: int = -1) -> Dictionary:
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "buildings_unavailable", "text": "建筑情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "building"}]}
	if not snapshot.has("group_type_ids"):
		return {"insights": [{"id": "building_details_unavailable", "text": "无法读取最新建筑明细。", "accent": UITokens.RISK, "icon": "building"}]}
	var rows = []
	var type_ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var type_names: PackedStringArray = snapshot.get("building_type_display_names", PackedStringArray())
	var group_types: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
	var owner_signatures: PackedInt32Array = snapshot.get("owner_signature_ids", PackedInt32Array())
	var group_counts: PackedInt64Array = snapshot.get("group_counts", PackedInt64Array())
	var owner_capacity: PackedInt64Array = snapshot.get("owner_capacity", PackedInt64Array())
	var owner_required_by_group: PackedInt64Array = snapshot.get("owner_required", PackedInt64Array())
	var filled_owner: PackedInt64Array = snapshot.get("filled_owner", PackedInt64Array())
	var owner_openings: PackedInt64Array = snapshot.get("owner_openings", PackedInt64Array())
	var planned_utilization: PackedInt32Array = snapshot.get("planned_utilization_q16", PackedInt32Array())
	var capacity_q16: PackedInt64Array = snapshot.get("capacity_q16", PackedInt64Array())
	var temperature_fit_q16: PackedInt64Array = snapshot.get(
		"last_temperature_fit_q16", PackedInt64Array())
	var water_fit_q16: PackedInt64Array = snapshot.get(
		"last_water_fit_q16", PackedInt64Array())
	var climate_capacity_q16: PackedInt64Array = snapshot.get(
		"last_climate_capacity_q16", PackedInt64Array())
	var climate_lost_output: PackedInt64Array = snapshot.get(
		"last_climate_lost_output", PackedInt64Array())
	var building_climate_profiles: PackedInt32Array = snapshot.get(
		"building_production_climate_profile_indices", PackedInt32Array())
	var last_input: PackedInt64Array = snapshot.get("last_input", PackedInt64Array())
	var last_output: PackedInt64Array = snapshot.get("last_output", PackedInt64Array())
	var last_resource: PackedInt64Array = snapshot.get("last_resource", PackedInt64Array())
	var last_resource_generated: PackedInt64Array = snapshot.get("last_resource_generated", PackedInt64Array())
	var last_revenue: PackedInt64Array = snapshot.get("last_revenue", PackedInt64Array())
	var last_business_tax: PackedInt64Array = snapshot.get(
		"last_business_tax_paid", PackedInt64Array())
	var last_business_subsidy: PackedInt64Array = snapshot.get(
		"last_business_subsidy_received", PackedInt64Array())
	var last_input_cost: PackedInt64Array = snapshot.get("last_input_cost", PackedInt64Array())
	var last_wages: PackedInt64Array = snapshot.get("last_wages_paid", PackedInt64Array())
	var last_wages_due: PackedInt64Array = snapshot.get("last_wages_due", PackedInt64Array())
	var last_operating_cost: PackedInt64Array = snapshot.get("last_operating_cost", PackedInt64Array())
	var last_in_kind: PackedInt64Array = snapshot.get(
		"last_in_kind_livelihood_value", PackedInt64Array())
	var opportunity_owner_income: PackedInt64Array = snapshot.get(
		"opportunity_owner_income_per_day", PackedInt64Array())
	var opportunity_capacity: PackedInt64Array = snapshot.get(
		"opportunity_executable_capacity_q16", PackedInt64Array())
	var role_offsets: PackedInt32Array = snapshot.get("employee_fill_offsets", PackedInt32Array())
	var role_professions: PackedInt32Array = snapshot.get("employee_profession_ids", PackedInt32Array())
	var role_required: PackedInt64Array = snapshot.get("employee_required", PackedInt64Array())
	var role_filled: PackedInt64Array = snapshot.get("employee_filled", PackedInt64Array())
	var wage_suspended: PackedByteArray = snapshot.get("wage_suspended", PackedByteArray())
	var operating_states: PackedByteArray = snapshot.get("operating_state", PackedByteArray())
	var pending_operating_states: PackedByteArray = snapshot.get(
		"pending_operating_state", PackedByteArray())
	var severe_loss_cycles: PackedInt32Array = snapshot.get(
		"severe_loss_cycles", PackedInt32Array())
	var realized_profit_margins: PackedInt32Array = snapshot.get(
		"realized_profit_margin_q16", PackedInt32Array())
	var technology_available: PackedByteArray = snapshot.get(
		"building_technology_available", PackedByteArray())
	var owner_slots: PackedInt64Array = snapshot.get("building_owner_slots", PackedInt64Array())
	var period_days = maxi(1, int(snapshot.get("period_days", 1)))
	var bld_sample_day = int(snapshot.get("sample_day", h._current_sample_day()))
	if cell_idx >= 0:
		host._ensure_detail_history_cell(cell_idx)
	var should_sample_bld = cell_idx >= 0 and bld_sample_day >= 0 \
		and bld_sample_day != host._detail_history_building_day
	if should_sample_bld:
		host._detail_history_building_day = bld_sample_day
	var total_profit = 0
	var halted_groups = 0
	for i in range(group_types.size()):
		var type_idx = int(group_types[i])
		var building_id = String(type_ids[type_idx]) \
			if type_idx >= 0 and type_idx < type_ids.size() else ""
		var count = int(group_counts[i]) if i < group_counts.size() else 0
		var revenue = int(last_revenue[i]) if i < last_revenue.size() else 0
		var input_cost = int(last_input_cost[i]) if i < last_input_cost.size() else 0
		var wages = int(last_wages[i]) if i < last_wages.size() else 0
		var wages_due = int(last_wages_due[i]) if i < last_wages_due.size() else wages
		var operating_cost = int(last_operating_cost[i]) if i < last_operating_cost.size() else input_cost + wages_due
		# In-kind owner retention is part of the same economic income as cash
		# receipts. A host-consuming producer must not be shown as loss-making# receipts. A self-consuming producer must not be shown as loss-making
		# merely because it has no merchant sale.
		var in_kind_income = int(last_in_kind[i]) if i < last_in_kind.size() else 0
		var profit = revenue + in_kind_income - operating_cost
		var business_tax = int(last_business_tax[i]) \
			if i < last_business_tax.size() else 0
		var business_subsidy = int(last_business_subsidy[i]) \
			if i < last_business_subsidy.size() else 0
		var owner_physical_capacity = int(owner_capacity[i]) if i < owner_capacity.size() else \
			(count * int(owner_slots[type_idx]) if type_idx >= 0 and type_idx < owner_slots.size() else count)
		var owner_required = int(owner_required_by_group[i]) if i < owner_required_by_group.size() else 0
		if i >= owner_required_by_group.size():
			owner_required = owner_physical_capacity
		var owner_actual = int(filled_owner[i]) if i < filled_owner.size() else 0
		var owner_open = int(owner_openings[i]) if i < owner_openings.size() else maxi(0, owner_required - owner_actual)
		var operating_state = int(operating_states[i]) if i < operating_states.size() else 0
		var opportunity_income = int(opportunity_owner_income[i]) \
			if i < opportunity_owner_income.size() else 0
		var opportunity_capacity_value = int(opportunity_capacity[i]) \
			if i < opportunity_capacity.size() else 0
		var is_available = type_idx < 0 or type_idx >= technology_available.size() \
			or int(technology_available[type_idx]) != 0
		var is_loss_suspended = operating_state == 1
		var owner_job_value = "%d / %d" % [owner_actual, owner_required]
		if owner_required == 0 and owner_physical_capacity > 0:
			owner_job_value += "（物理容量 %d）" % owner_physical_capacity
		var job_rows = [
			{"id": "owner_job", "name": "业主 · %s" % h._owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1), "value": owner_job_value, "ratio": float(owner_actual) / float(owner_required) if owner_required > 0 else 0.0},
		]
		if role_offsets.size() == group_types.size() + 1:
			for role in range(role_offsets[i], role_offsets[i + 1]):
				var required = int(role_required[role]) if role < role_required.size() else 0
				var filled = int(role_filled[role]) if role < role_filled.size() else 0
				var role_value = "%d / %d" % [filled, required]
				if required == 0 and (is_loss_suspended or not is_available):
					role_value += "（岗位已释放）"
				job_rows.append({
					"id": "job_%d" % role,
					"name": "雇员 · %s" % h._profession_name(snapshot, int(role_professions[role]) if role < role_professions.size() else -1),
					"value": role_value,
					"ratio": float(filled) / float(required) if required > 0 else 0.0,
				})
		var production_rows = []
		h._append_recipe_rows(production_rows, snapshot, type_idx, "input",
			int(last_input[i]) if i < last_input.size() else 0, count, period_days, i)
		host._append_resource_generation_rows(production_rows, snapshot, type_idx,
			int(last_resource_generated[i]) if i < last_resource_generated.size() else 0,
			count, period_days)
		host._append_resource_recipe_rows(production_rows, snapshot, type_idx,
			int(last_resource[i]) if i < last_resource.size() else 0, count, period_days)
		var resource_net = (int(last_resource_generated[i]) if i < last_resource_generated.size() else 0) \
			- (int(last_resource[i]) if i < last_resource.size() else 0)
		if resource_net != 0:
			production_rows.append({"id": "resource_net", "name": "自然资源净额",
				"value": h._actual_daily_rate(resource_net, count, period_days),
				"icon": "eco", "accent": UITokens.GOOD if resource_net > 0 else UITokens.WARN})
		var output_row_begin = production_rows.size()
		h._append_recipe_rows(production_rows, snapshot, type_idx, "output",
			int(last_output[i]) if i < last_output.size() else 0, count, period_days)
		var has_outputs = production_rows.size() != output_row_begin
		var has_climate_profile = type_idx >= 0 \
			and type_idx < building_climate_profiles.size() \
			and int(building_climate_profiles[type_idx]) >= 0
		var temp_fit = 100.0
		var water_fit = 100.0
		var climate_capacity = 100.0
		var climate_lost_daily_text = ""
		if has_climate_profile:
			temp_fit = float(temperature_fit_q16[i]) * 100.0 / 65536.0 \
				if i < temperature_fit_q16.size() else 100.0
			water_fit = float(water_fit_q16[i]) * 100.0 / 65536.0 \
				if i < water_fit_q16.size() else 100.0
			climate_capacity = float(climate_capacity_q16[i]) * 100.0 / 65536.0 \
				if i < climate_capacity_q16.size() else 100.0
			production_rows.append({"id": "climate_fit", "name": "气候适宜度",
				"value": "温度 %.1f%% · 水分 %.1f%% · 能力 %.1f%%" % [
					temp_fit, water_fit, climate_capacity], "icon": "climate",
				"accent": UITokens.GOOD if climate_capacity >= 99.9 else UITokens.WARN})
			var lost_output = int(climate_lost_output[i]) \
				if i < climate_lost_output.size() else 0
			if lost_output > 0:
				climate_lost_daily_text = host._actual_daily_rate(lost_output, count, period_days)
				production_rows.append({"id": "climate_lost_output", "name": "气候减产",
					"value": climate_lost_daily_text,
					"icon": "warning", "accent": UITokens.WARN})
		var finance_breakdown = "现金 %s · 自用折算 %s · 原料 %s · 工资 %s · 营业税 %s" % [
			host._money_text(revenue), host._money_text(in_kind_income), host._money_text(input_cost),
			host._money_text(wages), host._money_text(business_tax)]
		if business_subsidy > 0:
			finance_breakdown += " · 经营补贴 %s" % h._money_text(business_subsidy)
		var finance = {
			"revenue": h._money_text(revenue + in_kind_income),
			"revenue_float": float(revenue + in_kind_income) / 10000.0,
			"cash_revenue_float": float(revenue) / 10000.0,
			"cash_revenue_text": h._money_text(revenue),
			"in_kind_float": float(in_kind_income) / 10000.0,
			"in_kind_text": h._money_text(in_kind_income),
			"subsidy_float": float(business_subsidy) / 10000.0,
			"subsidy_text": h._money_text(business_subsidy),
			"cost": h._money_text(operating_cost),
			"cost_float": float(operating_cost) / 10000.0,
			"input_cost_float": float(input_cost) / 10000.0,
			"input_cost_text": h._money_text(input_cost),
			"wages_paid_float": float(wages) / 10000.0,
			"wages_paid_text": h._money_text(wages),
			"business_tax_float": float(business_tax) / 10000.0,
			"business_tax_text": h._money_text(business_tax),
			"profit": "%s%s" % ["+" if profit > 0 else "", h._money_text(profit)],
			"profit_float": float(profit) / 10000.0,
			"profit_positive": profit >= 0,
			"breakdown": finance_breakdown,
			"revenue_label": "税后总收入（含自用）",
			"warning": "工资未足额支付，生产受限" if wages < wages_due else "",
		}
		var staffing_required = owner_required
		var staffing_actual = owner_actual
		if role_offsets.size() == group_types.size() + 1:
			for role in range(role_offsets[i], role_offsets[i + 1]):
				staffing_required += int(role_required[role]) if role < role_required.size() else 0
				staffing_actual += int(role_filled[role]) if role < role_filled.size() else 0
		var planned_percent = float(planned_utilization[i]) * 100.0 / 65536.0 \
			if i < planned_utilization.size() else 100.0
		var actual_percent = float(capacity_q16[i]) * 100.0 / 65536.0 \
			if i < capacity_q16.size() else 0.0
		var state_label = "正常经营"
		var state_detail = ""
		var state_meta = ""
		var state_accent = UITokens.GOOD
		var show_state_summary = false
		if not is_available:
			state_label = "技术停用"
			state_detail = "技术条件不足，本期停产。"
			state_accent = UITokens.WARN
			show_state_summary = true
		elif is_loss_suspended:
			state_label = "亏损停产"
			state_detail = "连续亏损停产，岗位已释放。"
			var loss_count = int(severe_loss_cycles[i]) if i < severe_loss_cycles.size() else 0
			var realized_margin = float(realized_profit_margins[i]) * 100.0 / 65536.0 \
				if i < realized_profit_margins.size() else 0.0
			state_meta = "上一经营期利润率 %.1f%%" % realized_margin
			if loss_count > 0:
				state_meta += " · 连续亏损 %d 期" % loss_count
			state_accent = UITokens.RISK
			show_state_summary = true
		elif i < wage_suspended.size() and int(wage_suspended[i]) != 0:
			state_label = "资金停产"
			state_detail = "工资未付清，本期停产。"
			state_accent = UITokens.RISK
			show_state_summary = true
		elif i < capacity_q16.size() and int(capacity_q16[i]) == 0 \
				and host._building_resource_depleted(snapshot, type_idx):
			state_label = "资源短缺"
			state_detail = "本地资源不足，无法生产。"
			state_accent = UITokens.WARN
			show_state_summary = true
		else:
			var status_parts: Array[String] = ["到岗 %d/%d" % [staffing_actual, staffing_required]]
			if owner_open > 0:
				status_parts.append("缺业主 %d" % owner_open)
			status_parts.append("产能 %.0f%%" % actual_percent)
			if has_outputs and planned_percent < 99.5:
				status_parts.append("限产 %.0f%%" % planned_percent)
			state_label = " · ".join(status_parts)
		var pending_state = int(pending_operating_states[i]) \
			if i < pending_operating_states.size() else 255
		if pending_state == 0 and operating_state != 0:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期恢复正常经营"
		elif pending_state == 1 and operating_state != 1:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期转入亏损停产"
		var headline_profit_label = "利润" if profit >= 0 else "亏损"
		var headline_profit = "%s%s" % ["+" if profit > 0 else "", h._money_text(profit)]
		# A vacant but executable owner-operated group has no realized cash flow
		# yet. Do not present that zero settlement as an already-realized loss;
		# expose the read-only opportunity quote until an owner is attached.
		if owner_actual == 0 and opportunity_capacity_value > 0:
			headline_profit_label = "机会收益"
			headline_profit = "%s%s" % ["+" if opportunity_income > 0 else "",
				host._money_text(opportunity_income)]
		if is_loss_suspended:
			headline_profit_label = "状态"
			headline_profit = "停产"
		elif not is_available:
			headline_profit_label = "状态"
			headline_profit = "停用"
		if is_loss_suspended:
			finance.warning = "停产中 · 利润率取自上一经营期"
		var bld_hist_key = "%d|%d" % [type_idx, int(owner_signatures[i]) if i < owner_signatures.size() else i]
		if should_sample_bld:
			host._record_building_history(bld_hist_key, float(profit) / 10000.0,
				clampf(actual_percent / 100.0, 0.0, 1.0))
		var bld_hist: Dictionary = host._building_history.get(bld_hist_key, {})
		var profit_series: PackedFloat32Array = bld_hist.get("profit", PackedFloat32Array())
		var util_series: PackedFloat32Array = bld_hist.get("utilization", PackedFloat32Array())
		rows.append({
			"id": "building_%d_%d" % [type_idx, i],
			"name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (String(type_ids[type_idx]) if type_idx >= 0 and type_idx < type_ids.size() else "建筑"),
			"building_type_id": building_id,
			"count": "%d" % count,
			"count_raw": count,
			"owner": "业主 · %s" % h._owner_profession_name(snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1),
			"status": state_label,
			"staffing_actual_raw": staffing_actual,
			"staffing_required_raw": staffing_required,
			"actual_utilization_float": clampf(actual_percent / 100.0, 0.0, 1.0),
			"planned_utilization_float": clampf(planned_percent / 100.0, 0.0, 1.0),
			"has_climate_profile": has_climate_profile,
			"temperature_fit_float": clampf(temp_fit / 100.0, 0.0, 1.0),
			"water_fit_float": clampf(water_fit / 100.0, 0.0, 1.0),
			"climate_capacity_float": clampf(climate_capacity / 100.0, 0.0, 1.0),
			"climate_lost_daily_text": climate_lost_daily_text,
			"state_summary": {"label": state_label, "detail": state_detail,
				"meta": state_meta, "accent": state_accent,
				"icon": "warning"} \
				if show_state_summary else {},
			"profit": headline_profit,
			"profit_float": float(profit) / 10000.0,
			"profit_label": headline_profit_label,
			"profit_spark": profit_series,
			"profit_delta": h._series_lookback_delta(profit_series),
			"utilization_spark": util_series,
			"utilization_delta": h._series_lookback_delta(util_series),
			"accent": state_accent if show_state_summary else (UITokens.GOOD if profit > 0 else (UITokens.RISK if profit < 0 else UITokens.TEXT_MUTED)),
			"icon": h._building_icon(building_id, snapshot, type_idx), "job_rows": job_rows,
			"production_rows": production_rows, "finance": finance, "visible": true,
		})
		total_profit += profit
		if show_state_summary:
			halted_groups += 1
	host._append_construction_rows(rows, snapshot, type_ids, type_names)
	var total_count = h._sum_i64(snapshot.get("building_counts_by_type", PackedInt64Array()))
	var metrics = [{"id": "building_total", "title": "建筑总数", "value": "%s 栋" % UITokens.format_compact_number_cn(float(total_count), 1), "subtitle": "%d 处停产" % halted_groups if halted_groups > 0 else "", "accent": UITokens.RISK if halted_groups > 0 else UITokens.ACCENT, "icon": "building"}]
	if group_types.size() > 0:
		metrics.append({"id": "building_profit_total", "title": "本期利润", "money": true, "value": "%s%s" % ["+" if total_profit > 0 else "", h._money_text(total_profit)], "subtitle": "", "tooltip": "本期各建筑利润合计，自用产出按市价折算。", "accent": UITokens.GOOD if total_profit >= 0 else UITokens.RISK, "icon": "resource"})
	var category = {
		"insights": [],
		"metrics": metrics,
		"construction_entry": h.build_construction_entry(cell_idx),
		"building_rows": rows,
	}
	if not rows.is_empty():
		category["list_header"] = {"lead": "建筑 · 业主 · 状况", "indent": 41.0, "columns": [
			{"text": "数量", "width": 44.0}, {"text": "利润", "width": 78.0}]}
	return category
