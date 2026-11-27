extends RefCounted

## Formats goods and population cohort dossiers from published rows.

const DOSSIER_EXPENSE_COLORS: Array[Color] = [UITokens.DOSSIER_OXBLOOD, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_UMBER, UITokens.DOSSIER_SLATE]
const DOSSIER_INCOME_COLORS: Array[Color] = [UITokens.DOSSIER_VERDIGRIS, UITokens.DOSSIER_BRASS, UITokens.DOSSIER_SLATE, UITokens.DOSSIER_UMBER]
const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")
const SATISFACTION_DIMENSION_NAMES = ["生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展"]


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
			price_index_caption = "成本锚 +%.0f%%" % minf(999.0, (price_index - 1.0) * 100.0)
		elif price_index < 0.95:
			price_index_caption = "成本锚 -%.0f%%" % ((1.0 - price_index) * 100.0)
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
		balance_caption = "-%s/日" % UITokens.format_compact_number_cn(absf(net_supply), 2)
	elif net_supply > 0.01:
		balance_caption = "+%s/日" % UITokens.format_compact_number_cn(net_supply, 2)
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
