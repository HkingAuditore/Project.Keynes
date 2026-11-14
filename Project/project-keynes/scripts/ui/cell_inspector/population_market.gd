extends RefCounted


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

func _gdp_metrics(host, cell_idx: int) -> Array:
	var h = host
	var gdp = host._local_gdp(cell_idx)
	if gdp.is_empty():
		return []
	var ytd = float(gdp.get("ytd", 0.0))
	var per_day = float(gdp.get("per_day", 0.0))
	var days = int(gdp.get("days_counted", 0))
	var days_per_year = maxi(1, int(gdp.get("days_per_year", 365)))
	# 卡面只放一个数；「已计走到哪一天」「日均」「与全国人均的差距」都进 tooltip，
	# 否则窄面板里会被截成「已计 10/3…」「全国 11.62…」这类读不完的碎字。
	var metrics = [{
		"id": "population_gdp", "title": "本地年度产值", "money": true,
		"value": h._money_text(int(round(ytd))),
		"subtitle": "",
		"accent": UITokens.ECO, "icon": "metric.treasury",
		"tooltip": "收入法：建筑营收 − 中间投入 − 维护（= 工资 + 营业盈余，不含营业税）。本年度逐经济周期累计，与全国口径一致；已计 %d/%d 天，日均 %s。" % [
			days, days_per_year, host._money_text(int(round(per_day)))],
	}]
	var per_capita = float(gdp.get("per_capita", NAN))
	var national_per_capita = float(gdp.get("national_per_capita", NAN))
	if is_nan(per_capita):
		return metrics
	var comparison = ""
	if not is_nan(national_per_capita) and national_per_capita > 0.0:
		var gap = (per_capita - national_per_capita) / national_per_capita * 100.0
		comparison = "全国人均 %s（本地%s%.0f%%）" % [
			host._money_text(int(round(national_per_capita))),
			"高于" if gap >= 0.0 else "低于", absf(gap)]
	metrics.append({
		"id": "population_gdp_per_capita", "title": "人均年度产值", "money": true,
		"value": h._money_text(int(round(per_capita))),
		"subtitle": "", "accent": UITokens.ACCENT,
		"icon": "family.metric.wealth",
		"tooltip": comparison,
	})
	return metrics



func _population_category(host, snapshot: Dictionary, market_snapshot: Dictionary = {},
		cell_idx: int = -1) -> Dictionary:
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "population_unavailable", "text": "人口情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "growth"}]}
	if not snapshot.has("populations"):
		return {"insights": [{"id": "population_details_unavailable", "text": "无法读取最新人口明细。", "accent": UITokens.RISK, "icon": "growth"}]}
	var list_only = not bool(snapshot.get("demand_preview_included", true))
	var rows = []
	var handles: PackedInt64Array = snapshot.get("handles", PackedInt64Array())
	var profession_indices: PackedInt32Array = snapshot.get("profession_ids", PackedInt32Array())
	var ethnicity_indices: PackedInt32Array = snapshot.get("ethnicity_ids", PackedInt32Array())
	var profession_ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	var ethnicity_ids: PackedStringArray = snapshot.get("ethnicity_stable_ids", PackedStringArray())
	var profession_names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var ethnicity_names: PackedStringArray = snapshot.get("ethnicity_display_names", PackedStringArray())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var funds: PackedInt64Array = snapshot.get("funds_by_cohort", PackedInt64Array())
	var epoch_tax_paid: PackedInt64Array = snapshot.get(
		"epoch_tax_paid_by_cohort", PackedInt64Array())
	var epoch_subsidy_received: PackedInt64Array = snapshot.get(
		"epoch_subsidy_received_by_cohort", PackedInt64Array())
	var satisfaction: PackedInt32Array = snapshot.get(
		"survival_satisfaction_by_cohort_q16",
		snapshot.get("satisfaction_by_cohort_q16", PackedInt32Array()))
	# 综合满意度自 PKEC v30 起是权威列，任何 cohort 都可读，不再依赖 trace。
	var overall_satisfaction: PackedInt32Array = snapshot.get(
		"overall_satisfaction_by_cohort_q16", satisfaction)
	var living_levels: PackedInt32Array = snapshot.get(
		"living_standard_level_by_cohort", PackedInt32Array())
	var dimension_count = int(snapshot.get("satisfaction_dimension_count", 0))
	var satisfaction_dims: PackedInt32Array = snapshot.get(
		"satisfaction_dims_by_cohort_q16", PackedInt32Array())
	var worst_dimensions: PackedInt32Array = snapshot.get(
		"worst_satisfaction_dimension_by_cohort", PackedInt32Array())
	var welfare_available = bool(snapshot.get("welfare_detail_available", false))
	var welfare_need_offsets: PackedInt32Array = snapshot.get("welfare_need_offsets", PackedInt32Array())
	var welfare_need_ids: PackedInt32Array = snapshot.get("welfare_need_ids", PackedInt32Array())
	var welfare_need_satisfaction: PackedInt32Array = snapshot.get(
		"welfare_need_satisfaction_q16", PackedInt32Array())
	var merchant_flags: PackedByteArray = snapshot.get("merchant_flags", PackedByteArray())
	var owner_employed: PackedInt64Array = snapshot.get("owner_employed_by_cohort", PackedInt64Array())
	var employee_employed: PackedInt64Array = snapshot.get("employee_employed_by_cohort", PackedInt64Array())
	var settlement_available = bool(snapshot.get("settlement_detail_available", false))
	var settlement_offsets: PackedInt32Array = snapshot.get("settlement_cashflow_offsets", PackedInt32Array())
	var settlement_source_indices: PackedInt32Array = snapshot.get("settlement_cashflow_source_indices", PackedInt32Array())
	var settlement_source_ids: PackedStringArray = snapshot.get("settlement_cashflow_source_stable_ids", PackedStringArray())
	var settlement_income: PackedInt64Array = snapshot.get("settlement_cashflow_income", PackedInt64Array())
	var settlement_expense: PackedInt64Array = snapshot.get("settlement_cashflow_expense", PackedInt64Array())
	var settlement_income_by_cohort: PackedInt64Array = snapshot.get("settlement_income_by_cohort", PackedInt64Array())
	var settlement_expense_by_cohort: PackedInt64Array = snapshot.get("settlement_expense_by_cohort", PackedInt64Array())
	var settlement_days = maxi(1, int(snapshot.get("settlement_period_days", 1)))
	var demand_offsets: PackedInt32Array = snapshot.get("demand_good_offsets", PackedInt32Array())
	var demand_good_indices: PackedInt32Array = snapshot.get("demand_good_indices", PackedInt32Array())
	var demand_quantities: PackedInt64Array = snapshot.get("demand_per_capita_daily", PackedInt64Array())
	var demand_good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var demand_need_ids: PackedStringArray = snapshot.get("demand_need_stable_ids", PackedStringArray())
	var attribution_good_count = int(snapshot.get("demand_attribution_good_count", 0))
	var wealth_demand_delta: PackedInt64Array = snapshot.get(
		"demand_wealth_delta_per_capita_daily", PackedInt64Array())
	var price_demand_delta: PackedInt64Array = snapshot.get(
		"demand_price_delta_per_capita_daily", PackedInt64Array())
	var local_prices = {}
	var local_technology_available = {}
	var enforce_local_technology = false
	if not list_only and bool(market_snapshot.get("ok", false)):
		var market_good_ids: PackedStringArray = market_snapshot.get("good_ids", PackedStringArray())
		var market_prices: PackedInt32Array = market_snapshot.get("price", PackedInt32Array())
		var market_technology: PackedByteArray = market_snapshot.get(
			"good_technology_available", PackedByteArray())
		enforce_local_technology = market_technology.size() == market_good_ids.size()
		for market_good_idx in range(mini(market_good_ids.size(), market_prices.size())):
			var market_good_id = String(market_good_ids[market_good_idx])
			local_prices[market_good_id] = int(market_prices[market_good_idx])
			if enforce_local_technology:
				local_technology_available[market_good_id] = market_technology[market_good_idx] != 0
	var pop_cell_idx = int(snapshot.get("cell_idx", -1))
	var pop_sample_day = int(snapshot.get("sample_day", h._current_sample_day()))
	if pop_cell_idx >= 0:
		host._ensure_detail_history_cell(pop_cell_idx)
	var should_sample_pop = not list_only and pop_cell_idx >= 0 \
		and pop_sample_day >= 0 and pop_sample_day != host._detail_history_pop_day
	if should_sample_pop:
		host._detail_history_pop_day = pop_sample_day
	var cell_avg_dims = host._compute_cell_avg_satisfaction_dims(
		populations, satisfaction_dims, dimension_count)
	for i in range(populations.size()):
		var profession_id = String(profession_ids[profession_indices[i]]) if profession_indices[i] >= 0 and profession_indices[i] < profession_ids.size() else "unknown"
		var ethnicity_id = String(ethnicity_ids[ethnicity_indices[i]]) if ethnicity_indices[i] >= 0 and ethnicity_indices[i] < ethnicity_ids.size() else "unknown"
		var profession_name = String(profession_names[profession_indices[i]]) if profession_indices[i] >= 0 and profession_indices[i] < profession_names.size() else profession_id
		var ethnicity_name = String(ethnicity_names[ethnicity_indices[i]]) if ethnicity_indices[i] >= 0 and ethnicity_indices[i] < ethnicity_names.size() else ethnicity_id
		var sat = float(overall_satisfaction[i]) / 65536.0 if i < overall_satisfaction.size() else 0.0
		var living_level = int(living_levels[i]) if i < living_levels.size() else -1
		var living_name = host._living_standard_name(living_level)
		var worst_dimension = int(worst_dimensions[i]) \
			if i < worst_dimensions.size() else -1
		var dimension_rows = [] if list_only else host._satisfaction_dimension_rows(
			satisfaction_dims, dimension_count, i, worst_dimension)
		var cohort_dims_float = PackedFloat32Array() if list_only \
			else host._cohort_satisfaction_dims_float(satisfaction_dims, dimension_count, i)
		var need_satisfaction_by_id = {}
		if not list_only and welfare_need_offsets.size() == populations.size() + 1:
			var welfare_begin = clampi(int(welfare_need_offsets[i]), 0, welfare_need_ids.size())
			var welfare_end = clampi(int(welfare_need_offsets[i + 1]), welfare_begin, welfare_need_ids.size())
			for welfare_cursor in range(welfare_begin, welfare_end):
				var need_idx = int(welfare_need_ids[welfare_cursor])
				if need_idx >= 0 and need_idx < demand_need_ids.size() \
						and welfare_cursor < welfare_need_satisfaction.size():
					need_satisfaction_by_id[String(demand_need_ids[need_idx])] = int(
						welfare_need_satisfaction[welfare_cursor])
		var population = int(populations[i])
		var cohort_funds = int(funds[i]) if i < funds.size() else 0
		var wealth_pc = cohort_funds / maxi(population, 1)
		var owners = int(owner_employed[i]) if i < owner_employed.size() else 0
		var employees = int(employee_employed[i]) if i < employee_employed.size() else 0
		var demand_by_good = {}
		if not list_only and demand_offsets.size() == populations.size() + 1:
			var begin = clampi(int(demand_offsets[i]), 0, demand_good_indices.size())
			var end = clampi(int(demand_offsets[i + 1]), begin, demand_good_indices.size())
			for cursor in range(begin, end):
				var good_idx = int(demand_good_indices[cursor])
				if good_idx >= 0 and good_idx < demand_good_ids.size() and cursor < demand_quantities.size():
					demand_by_good[good_idx] = int(demand_quantities[cursor])
		var demand_rows = []
		var demand_groups = []
		var demand_total = 0
		var demand_total_cost = 0
		var demand_cost_available = true
		var demand_names = PackedStringArray()
		var visible_demand_count = 0
		if not list_only:
			var demand_metadata = host._demand_good_metadata(snapshot, i)
			var good_metadata: Dictionary = demand_metadata.get("good_metadata", {}) \
				if bool(demand_metadata.get("ok", false)) else {}
			for good_idx in range(demand_good_ids.size()):
				var stable_id = String(demand_good_ids[good_idx])
				var profile = GoodProfileRegistry.profile_by_id(stable_id)
				var display_name = String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id
				var quantity = int(demand_by_good.get(good_idx, 0))
				var has_price = local_prices.has(stable_id)
				var price = int(local_prices.get(stable_id, 0))
				var daily_cost = quantity * price / 1000 if has_price else 0
				var metadata: Dictionary = good_metadata.get(stable_id, {})
				var good_discovered = not enforce_local_technology \
					or bool(local_technology_available.get(stable_id, false))
				var unlocked_alternative = not metadata.is_empty() and enforce_local_technology \
					and good_discovered
				var visible = good_discovered and (quantity > 0 or unlocked_alternative)
				if visible:
					visible_demand_count += 1
				if visible and quantity > 0:
					demand_total += quantity
					if has_price:
						demand_total_cost += daily_cost
					else:
						demand_cost_available = false
					if demand_names.size() < 3:
						demand_names.append(display_name)
				var need_names: Array = metadata.get("need_names", [])
				var need_satisfaction_total = 0
				var need_satisfaction_count = 0
				for raw_need_id in metadata.get("need_ids", []):
					var need_id = String(raw_need_id)
					if need_satisfaction_by_id.has(need_id):
						need_satisfaction_total += int(need_satisfaction_by_id[need_id])
						need_satisfaction_count += 1
				var attribution_idx = i * attribution_good_count + good_idx
				var attribution_available = welfare_available \
					and attribution_good_count == demand_good_ids.size() \
					and attribution_idx >= 0 and attribution_idx < wealth_demand_delta.size() \
					and attribution_idx < price_demand_delta.size()
				demand_rows.append({
					"id": "demand_%s" % stable_id,
					"stable_id": stable_id,
					"name": display_name,
					"value": "%s 单位/人/日" % UITokens.format_compact_number_cn(float(quantity) / 1000.0, 3),
					"quantity": "%.3f" % (float(quantity) / 1000.0),
					"price": h._money_text(price) if has_price else "—",
					"daily_cost": h._money_text(daily_cost) if has_price else "—",
					"quantity_raw": quantity,
					"price_raw": price if has_price else -1,
					"daily_cost_raw": daily_cost if has_price else -1,
					"need_ids": metadata.get("need_ids", []),
					"need_names": need_names,
					"need_satisfaction_q16": need_satisfaction_total / need_satisfaction_count \
						if need_satisfaction_count > 0 else -1,
					"attribution_available": attribution_available,
					"wealth_delta_raw": int(wealth_demand_delta[attribution_idx]) if attribution_available else 0,
					"price_delta_raw": int(price_demand_delta[attribution_idx]) if attribution_available else 0,
					"has_bundle": bool(metadata.get("has_bundle", false)),
					"has_substitute": bool(metadata.get("has_substitute", false)),
					"is_unallocated_alternative": quantity <= 0 and unlocked_alternative,
					"icon": GoodProfileRegistry.icon_key(stable_id),
					"visible": visible,
				})
			demand_groups = host._group_demand_rows_by_usage(demand_rows)
		var income_rows = []
		var expense_rows = []
		if not list_only and settlement_available and settlement_offsets.size() == populations.size() + 1:
			var flow_begin = clampi(int(settlement_offsets[i]), 0, settlement_source_indices.size())
			var flow_end = clampi(int(settlement_offsets[i + 1]), flow_begin, settlement_source_indices.size())
			for flow in range(flow_begin, flow_end):
				var source_idx = int(settlement_source_indices[flow])
				var source_id = String(settlement_source_ids[source_idx]) if source_idx >= 0 and source_idx < settlement_source_ids.size() else "other"
				var income_value = int(settlement_income[flow]) if flow < settlement_income.size() else 0
				var expense_value = int(settlement_expense[flow]) if flow < settlement_expense.size() else 0
				var income_pc_flow = income_value / maxi(population, 1)
				var expense_pc_flow = expense_value / maxi(population, 1)
				if income_value > 0:
					income_rows.append({"id": "income_%s" % source_id, "source_id": source_id, "name": h._cashflow_source_name(source_id, true), "value": "+%s/人" % h._money_text(income_pc_flow), "raw_per_capita": float(income_pc_flow) / 10000.0, "visible": true})
				if expense_value > 0:
					expense_rows.append({"id": "expense_%s" % source_id, "source_id": source_id, "name": h._cashflow_source_name(source_id, false), "value": "−%s/人" % h._money_text(expense_pc_flow), "raw_per_capita": float(expense_pc_flow) / 10000.0, "visible": true})
		# Fiscal attribution is authoritative even when the detailed cashflow trace
		# has expired or was intentionally omitted from this snapshot.
		var tax_paid_pc = int(epoch_tax_paid[i]) / maxi(population, 1) \
			if i < epoch_tax_paid.size() else 0
		var subsidy_received_pc = int(epoch_subsidy_received[i]) / maxi(population, 1) \
			if i < epoch_subsidy_received.size() else 0
		var has_tax_detail = h._has_cashflow_row(expense_rows, "income_tax") \
			or h._has_cashflow_row(expense_rows, "consumption_tax") \
			or h._has_cashflow_row(expense_rows, "business_tax")
		var has_subsidy_detail = h._has_cashflow_row(income_rows, "income_subsidy") \
			or h._has_cashflow_row(income_rows, "consumption_subsidy") \
			or h._has_cashflow_row(income_rows, "business_subsidy")
		if tax_paid_pc > 0 and not has_tax_detail:
			expense_rows.append({"id": "expense_fiscal_tax", "source_id": "fiscal_tax", "name": "税费（本批）", "value": "−%s/人" % h._money_text(tax_paid_pc), "raw_per_capita": float(tax_paid_pc) / 10000.0, "visible": true})
		if subsidy_received_pc > 0 and not has_subsidy_detail:
			income_rows.append({"id": "income_fiscal_subsidy", "source_id": "fiscal_subsidy", "name": "财政补贴（本批）", "value": "+%s/人" % h._money_text(subsidy_received_pc), "raw_per_capita": float(subsidy_received_pc) / 10000.0, "visible": true})
		var income_pc = int(settlement_income_by_cohort[i]) / maxi(population, 1) \
			if settlement_available and i < settlement_income_by_cohort.size() else 0
		var expense_pc = int(settlement_expense_by_cohort[i]) / maxi(population, 1) \
			if settlement_available and i < settlement_expense_by_cohort.size() else 0
		if not has_subsidy_detail:
			income_pc += subsidy_received_pc
		if not has_tax_detail:
			expense_pc += tax_paid_pc
		var net_pc = income_pc - expense_pc
		var cohort_hist_key = "%s|%s" % [profession_id, ethnicity_id]
		if should_sample_pop:
			host._record_cohort_history(cohort_hist_key, sat,
				float(net_pc) / 10000.0, float(income_pc) / 10000.0,
				float(wealth_pc) / 10000.0)
		var cohort_hist: Dictionary = host._cohort_history.get(cohort_hist_key, {})
		var sat_series: PackedFloat32Array = cohort_hist.get("satisfaction", PackedFloat32Array())
		var net_series: PackedFloat32Array = cohort_hist.get("net", PackedFloat32Array())
		var demand_count = visible_demand_count
		var demand_group_count = demand_groups.size()
		var demand_subtitle = "主要：%s%s" % ["、".join(demand_names), " 等" if demand_count > demand_names.size() else ""] if demand_count > 0 else "当前无消费需求"
		var row_dict = {
			"id": "cohort_%s" % str(handles[i] if i < handles.size() else i),
			"name": profession_name,
			"cohort_identity": ethnicity_name,
			"profession_id": profession_id,
			"cohort_handle": int(handles[i]) if i < handles.size() else -1,
			"population": "%s 人" % UITokens.format_compact_number_cn(float(population), 1),
			"population_raw": population,
			"employed_raw": owners + employees,
			"owners_raw": owners,
			"employees_raw": employees,
			"wealth": h._money_text(wealth_pc),
			"wealth_raw": float(wealth_pc) / 10000.0,
			"income": "+%s" % h._money_text(income_pc) if settlement_available or subsidy_received_pc > 0 else "+—",
			"expense": "−%s" % h._money_text(expense_pc) if settlement_available or tax_paid_pc > 0 else "−—",
			"net": "%s%s" % ["+" if net_pc > 0 else ("−" if net_pc < 0 else ""), h._money_text(absi(net_pc))] if settlement_available or subsidy_received_pc > 0 or tax_paid_pc > 0 else "—",
			"income_pc_float": float(income_pc) / 10000.0,
			"expense_pc_float": float(expense_pc) / 10000.0,
			"net_pc_float": float(net_pc) / 10000.0,
			"net_positive": net_pc >= 0,
			"status": "%s%s · 就业 %s · 结算 %d日" % [
				"商人 · " if i < merchant_flags.size() and merchant_flags[i] != 0 else "",
				ethnicity_name,
				UITokens.format_compact_number_cn(float(owners + employees), 1), settlement_days],
			"accent": UITokens.ACCENT,
			"icon": IconCatalog.profession_semantic(profession_id),
			"living_level": living_level,
			"living_icon": h._living_standard_icon(living_level),
			"living_accent": h._living_standard_accent(living_level),
			"living_standard": living_name,
			"satisfaction": "%.1f%%" % (sat * 100.0),
			"satisfaction_float": sat,
			"satisfaction_rows": dimension_rows,
			"satisfaction_dims_float": cohort_dims_float,
			"cell_reference_dims_float": cell_avg_dims,
			"worst_dimension": h._satisfaction_dimension_name(worst_dimension),
			"worst_dimension_index": worst_dimension,
			"satisfaction_spark": sat_series,
			"satisfaction_delta": h._series_lookback_delta(sat_series),
			"net_spark": net_series,
			"net_delta": h._series_lookback_delta(net_series),
			"demand_rows": demand_rows,
			"demand_groups": demand_groups,
			"income_rows": income_rows,
			"expense_rows": expense_rows,
			"demand_summary": {
				"value": "%d 项用途 · %d 种商品" % [demand_group_count, demand_count],
				"subtitle": demand_subtitle,
				"total_quantity": "%.3f" % (float(demand_total) / 1000.0),
				"total_daily_cost": h._money_text(demand_total_cost) if demand_cost_available else "—",
			},
			"visible": true,
		}
		rows.append(row_dict)
	var insights = []
	var job_capacity = int(snapshot.get("job_capacity", 0))
	var jobs_filled = int(snapshot.get("jobs_filled", 0))
	var job_openings = int(snapshot.get("job_openings", 0))
	var carrying_k_eff = int(snapshot.get("carrying_k_eff", 0))
	var food_access = float(snapshot.get("food_access_q16", 65536)) / 65536.0
	var population_total = int(snapshot.get("population", 0))
	var gauges = []
	if population_total > 0:
		# 百分比和条色已经表达了“够不够”，不再另挂“充足/偏紧/不足”的形容词。
		gauges.append({"id": "population_food_gauge", "label": "口粮保障",
			"value": clampf(food_access, 0.0, 1.0),
			"accent": UITokens.GOOD if food_access >= 0.95 else (
				UITokens.WARN if food_access >= 0.8 else UITokens.RISK),
			"value_text": "%.0f%%" % (food_access * 100.0),
			"tooltip": "居民实际取得的食物当量占最低生存口粮的比例（含购买与自产自用）。低于 95% 偏紧，低于 80% 不足。"})
	if carrying_k_eff > 0:
		var load = float(population_total) / float(carrying_k_eff)
		# 承载力只给一个数：现居人口在页头「人口」格与阶层列表里已经写过了。
		gauges.append({"id": "population_carrying_gauge", "label": "承载力",
			"value": clampf(load, 0.0, 1.0),
			"accent": UITokens.RISK if load > 1.0 else (UITokens.WARN if load > 0.85 else UITokens.ECO),
			"value_text": "%s 人" % UITokens.format_compact_number_cn(float(carrying_k_eff), 1),
			"tooltip": "本地粮食与库存能养活的人口上限；现居 %s 人，占用 %d%%。超过上限后人口不再增长。" % [
				UITokens.format_compact_number_cn(float(population_total), 1),
				roundi(load * 100.0)]})
	if job_capacity > 0:
		# 空缺数在页头「就业率」格已有；这里只留到岗 / 岗位。
		gauges.append({"id": "population_jobs_gauge", "label": "岗位",
			"value": clampf(float(jobs_filled) / float(job_capacity), 0.0, 1.0),
			"accent": UITokens.ACCENT,
			"value_text": "%s / %s" % [
				UITokens.format_compact_number_cn(float(jobs_filled), 1),
				UITokens.format_compact_number_cn(float(job_capacity), 1)],
			"tooltip": "本地建筑提供的岗位与已到岗人数；空缺 %s。" % UITokens.format_compact_number_cn(float(job_openings), 1)})
	var epoch_income = int(snapshot.get("epoch_income", 0))
	var epoch_expense = int(snapshot.get("epoch_expense", 0))
	var epoch_net = epoch_income - epoch_expense
	var identities = {}
	for row in rows:
		identities[String((row as Dictionary).get("cohort_identity", ""))] = true
	var mixed_identity = identities.size() > 1
	if not mixed_identity:
		for row in rows:
			(row as Dictionary)["cohort_identity"] = ""
	var local_metrics = [
		# 存款只给总额；本期结余挪进提示，不再在数值右边挂一串副行文字。
		{"id": "population_funds", "title": "居民存款", "money": true, "value": h._money_text(int(snapshot.get("funds", 0))), "subtitle": "", "accent": UITokens.ACCENT, "icon": "resource",
			"tooltip": "本格各阶层存款合计。本期%s %s。" % ["结余" if epoch_net >= 0 else "亏空", h._money_text(absi(epoch_net))]},
	]
	# 产值两格只在账本已跟踪该格时出现；他国 / 无主 / 无人聚落不加，指标行不会空转。
	local_metrics.append_array(host._gdp_metrics(cell_idx))
	return {
		"insights": insights,
		"gauges": gauges,
		"metrics": local_metrics,
		"cohort_rows": rows,
		"list_header": {"lead": "阶层 · 族群 · 生活水平" if mixed_identity else "阶层 · 生活水平",
			"indent": 41.0, "columns": [
			{"text": "人口", "width": 54.0}, {"text": "存款/净收", "width": 72.0}]},
	}



func _group_demand_rows_by_usage(host, rows: Array) -> Array:
	var h = host
	var groups = []
	var group_indices = {}
	for raw_row in rows:
		var row: Dictionary = raw_row
		if not bool(row.get("visible", false)):
			continue
		var need_names: Array = row.get("need_names", [])
		var group_name = "、".join(need_names) if not need_names.is_empty() else "其他"
		if not group_indices.has(group_name):
			group_indices[group_name] = groups.size()
			groups.append({
				"id": "demand_usage_%d" % groups.size(),
				"name": group_name,
				"rows": [],
			})
		var group_idx = int(group_indices[group_name])
		var group: Dictionary = groups[group_idx]
		var group_rows: Array = group.get("rows", [])
		group_rows.append(row)
		group["rows"] = group_rows
		var satisfaction_total = 0
		var satisfaction_count = 0
		var group_cost_raw = 0
		var group_qty_raw = 0
		for group_row in group_rows:
			var rdict = group_row as Dictionary
			var value = int(rdict.get("need_satisfaction_q16", -1))
			if value >= 0:
				satisfaction_total += value
				satisfaction_count += 1
			var q_raw = int(rdict.get("quantity_raw", 0))
			if q_raw > 0:
				group_qty_raw += q_raw
				var c_raw = int(rdict.get("daily_cost_raw", 0))
				if c_raw > 0:
					group_cost_raw += c_raw
		var sat_ratio = float(satisfaction_total) / 65536.0 / float(satisfaction_count) \
			if satisfaction_count > 0 else -1.0
		group["satisfaction_ratio"] = sat_ratio
		group["daily_cost_raw"] = group_cost_raw
		group["quantity_raw"] = group_qty_raw
		group["satisfaction"] = "满足 %.0f%%" % (sat_ratio * 100.0) \
			if sat_ratio >= 0.0 else ""
		groups[group_idx] = group
	return groups



func _ensure_detail_history_cell(host, cell_idx: int) -> void:
	var h = host
	if cell_idx >= 0 and cell_idx != host._detail_history_cell:
		host._detail_history_cell = cell_idx
		host._detail_history_market_day = -1
		host._detail_history_pop_day = -1
		host._detail_history_building_day = -1
		host._good_history.clear()
		host._cohort_history.clear()
		host._building_history.clear()



func _append_history_sample(host, bucket: Dictionary, key: String, value: float) -> PackedFloat32Array:
	var h = host
	var series: PackedFloat32Array = bucket.get(key, PackedFloat32Array())
	series.append(value)
	if series.size() > host.DETAIL_HISTORY_CAPACITY:
		series = series.slice(series.size() - host.DETAIL_HISTORY_CAPACITY)
	bucket[key] = series
	return series



static func _series_lookback_delta(series: PackedFloat32Array) -> float:
	if series.size() < 2:
		return NAN
	var lookback = mini(DETAIL_HISTORY_LOOKBACK, series.size() - 1)
	var latest = series[series.size() - 1]
	var earlier = series[series.size() - 1 - lookback]
	return latest - earlier if not is_nan(latest) and not is_nan(earlier) else NAN



func _record_cohort_history(host, cohort_key: String, sat: float, net_val: float,
		income_val: float, wealth_val: float) -> void:
	var h = host
	var bucket: Dictionary = host._cohort_history.get(cohort_key, {})
	h._append_history_sample(bucket, "satisfaction", sat)
	h._append_history_sample(bucket, "net", net_val)
	h._append_history_sample(bucket, "income", income_val)
	h._append_history_sample(bucket, "wealth", wealth_val)
	host._cohort_history[cohort_key] = bucket



func _record_good_history(host, good_id: String, price_val: float, price_index: float,
		stock_units: float, shortage_ratio: float) -> void:
	var h = host
	var bucket: Dictionary = host._good_history.get(good_id, {})
	h._append_history_sample(bucket, "price", price_val)
	h._append_history_sample(bucket, "price_index", price_index)
	h._append_history_sample(bucket, "stock", stock_units)
	h._append_history_sample(bucket, "shortage", shortage_ratio)
	host._good_history[good_id] = bucket



func _record_building_history(host, building_key: String, profit_val: float,
		utilization_ratio: float) -> void:
	var h = host
	var bucket: Dictionary = host._building_history.get(building_key, {})
	h._append_history_sample(bucket, "profit", profit_val)
	h._append_history_sample(bucket, "utilization", utilization_ratio)
	host._building_history[building_key] = bucket



func _compute_cell_avg_satisfaction_dims(host, populations: PackedInt64Array,
		dims: PackedInt32Array, dimension_count: int) -> PackedFloat32Array:
	var h = host
	var avg = PackedFloat32Array()
	if dimension_count <= 0 or populations.is_empty():
		return avg
	avg.resize(dimension_count)
	var dim_pop = PackedInt64Array()
	dim_pop.resize(dimension_count)
	for i in range(populations.size()):
		var pop = maxi(0, int(populations[i]))
		var begin = i * dimension_count
		if pop <= 0 or begin < 0 or begin + dimension_count > dims.size():
			continue
		for d in range(dimension_count):
			if dims[begin + d] >= 0:
				avg[d] += (float(dims[begin + d]) / 65536.0) * float(pop)
				dim_pop[d] += pop
	for d in range(dimension_count):
		avg[d] = clampf(avg[d] / float(dim_pop[d]), 0.0, 1.0) if dim_pop[d] > 0 else -1.0
	return avg



func _cohort_satisfaction_dims_float(host, dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int) -> PackedFloat32Array:
	var h = host
	var out = PackedFloat32Array()
	if dimension_count <= 0:
		return out
	var begin = cohort_idx * dimension_count
	if begin < 0 or begin + dimension_count > dims.size():
		return out
	out.resize(dimension_count)
	for d in range(dimension_count):
		out[d] = clampf(float(dims[begin + d]) / 65536.0, 0.0, 1.0) if dims[begin + d] >= 0 else -1.0
	return out



func _living_standard_name(host, level: int) -> String:
	var h = host
	return ["赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"][level] \
		if level >= 0 and level < 7 else "待评估"



func _living_standard_icon(host, level: int) -> String:
	var h = host
	return ["living_destitute", "living_struggling", "living_poor", "living_secure",
		"living_comfortable", "living_affluent", "living_luxury"][level] \
		if level >= 0 and level < 7 else "history"



func _living_standard_accent(host, level: int) -> Color:
	var h = host
	if level <= 0:
		return UITokens.RISK
	if level <= 2:
		return UITokens.WARN
	if level <= 4:
		return UITokens.GOOD
	return UITokens.RESOURCE


## 与原生 SAT_DIM_* 枚举同序。

func _satisfaction_dimension_name(host, dimension: int) -> String:
	var h = host
	return String(host.SATISFACTION_DIMENSION_NAMES[dimension]) \
		if dimension >= 0 and dimension < host.SATISFACTION_DIMENSION_NAMES.size() \
		else "待评估"



func _satisfaction_dimension_rows(host, dims: PackedInt32Array, dimension_count: int,
		cohort_idx: int, worst_dimension: int) -> Array:
	var h = host
	var rows = []
	if dimension_count <= 0:
		return rows
	var begin = cohort_idx * dimension_count
	if begin < 0 or begin + dimension_count > dims.size():
		return rows
	for dimension in range(dimension_count):
		var applicable = dims[begin + dimension] >= 0
		var value = float(dims[begin + dimension]) / 65536.0
		var is_worst = applicable and dimension == worst_dimension
		rows.append({
			"id": "satisfaction_dim_%d" % dimension,
			"name": h._satisfaction_dimension_name(dimension),
			"value": "%.1f%%" % (value * 100.0) if applicable else "不适用",
			"applicable": applicable,
			"tooltip": String(h.SATISFACTION_DIMENSION_EXPLANATIONS[dimension]) if applicable else "当前阶层尚无此档已解锁的生活需求；不参与综合满意度。",
			"accent": UITokens.DOSSIER_INK_MUTED if not applicable else (UITokens.RISK if is_worst else h._satisfaction_accent(value)),
			"worst": is_worst,
			"visible": true,
		})
	return rows



func _satisfaction_accent(host, value: float) -> Color:
	var h = host
	if value < 0.22:
		return UITokens.RISK
	if value < 0.45:
		return UITokens.WARN
	if value < 0.72:
		return UITokens.GOOD
	return UITokens.RESOURCE



func _demand_good_metadata(host, snapshot: Dictionary, cohort_idx: int) -> Dictionary:
	var h = host
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var good_ids: PackedStringArray = snapshot.get("demand_good_stable_ids", PackedStringArray())
	var need_ids: PackedStringArray = snapshot.get("demand_need_stable_ids", PackedStringArray())
	var need_offsets: PackedInt32Array = snapshot.get("demand_need_offsets", PackedInt32Array())
	var need_indices: PackedInt32Array = snapshot.get("demand_need_indices", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = snapshot.get(
		"demand_need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = snapshot.get(
		"demand_variant_component_offsets", PackedInt32Array())
	var component_good_indices: PackedInt32Array = snapshot.get(
		"demand_component_good_indices", PackedInt32Array())
	var component_quantities: PackedInt64Array = snapshot.get(
		"demand_component_per_capita_daily", PackedInt64Array())
	if cohort_idx < 0 or cohort_idx >= populations.size() \
			or need_offsets.size() != populations.size() + 1 \
			or need_variant_offsets.size() != need_indices.size() + 1 \
			or variant_component_offsets.is_empty() \
			or component_good_indices.size() != component_quantities.size() \
			or variant_component_offsets[-1] != component_good_indices.size():
		return {"ok": false}
	var need_begin = int(need_offsets[cohort_idx])
	var need_end = int(need_offsets[cohort_idx + 1])
	if need_begin < 0 or need_end < need_begin or need_end > need_indices.size():
		return {"ok": false}
	var good_metadata = {}
	for need_cursor in range(need_begin, need_end):
		var need_idx = int(need_indices[need_cursor])
		if need_idx < 0 or need_idx >= need_ids.size():
			return {"ok": false}
		var variant_begin = int(need_variant_offsets[need_cursor])
		var variant_end = int(need_variant_offsets[need_cursor + 1])
		if variant_begin < 0 or variant_end < variant_begin \
				or variant_end + 1 > variant_component_offsets.size():
			return {"ok": false}
		var need_id = String(need_ids[need_idx])
		var need_name = host._need_display_name(need_id)
		for variant_cursor in range(variant_begin, variant_end):
			var component_begin = int(variant_component_offsets[variant_cursor])
			var component_end = int(variant_component_offsets[variant_cursor + 1])
			if component_begin < 0 or component_end < component_begin \
					or component_end > component_good_indices.size():
				return {"ok": false}
			var component_count = component_end - component_begin
			for component_cursor in range(component_begin, component_end):
				var good_idx = int(component_good_indices[component_cursor])
				if good_idx < 0 or good_idx >= good_ids.size():
					return {"ok": false}
				var stable_id = String(good_ids[good_idx])
				var metadata: Dictionary = good_metadata.get(stable_id, {
					"need_ids": [],
					"need_names": [],
					"has_bundle": false,
					"has_substitute": false,
				})
				var metadata_need_ids: Array = metadata.get("need_ids", [])
				var metadata_need_names: Array = metadata.get("need_names", [])
				if not metadata_need_ids.has(need_id):
					metadata_need_ids.append(need_id)
					if not metadata_need_names.has(need_name):
						metadata_need_names.append(need_name)
				metadata["need_ids"] = metadata_need_ids
				metadata["need_names"] = metadata_need_names
				metadata["has_bundle"] = bool(metadata.get("has_bundle", false)) \
					or component_count > 1
				metadata["has_substitute"] = bool(metadata.get("has_substitute", false)) \
					or variant_end - variant_begin > 1
				good_metadata[stable_id] = metadata
	return {
		"ok": true,
		"good_metadata": good_metadata,
	}



func _need_display_name(host, stable_id: String) -> String:
	var h = host
	if not host._need_display_names_loaded:
		host._need_display_names = EconomyCatalog.need_display_names()
		host._need_display_names_loaded = true
	return String(host._need_display_names.get(stable_id, stable_id))



func _market_category(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "market_unavailable", "text": "市场情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "resource"}]}
	if not snapshot.has("good_ids"):
		return {"insights": [{"id": "market_details_unavailable", "text": "无法读取最新市场明细。", "accent": UITokens.RISK, "icon": "resource"}]}
	var rows = []
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var prices: PackedInt32Array = snapshot.get("price", PackedInt32Array())
	var demand_ema: PackedInt64Array = snapshot.get("demand_ema", PackedInt64Array())
	var business_demand_ema: PackedInt64Array = snapshot.get("business_demand_ema", PackedInt64Array())
	var offered_supply_ema: PackedInt64Array = snapshot.get("offered_supply_ema", PackedInt64Array())
	var cost_anchor: PackedInt32Array = snapshot.get("cost_anchor_price", PackedInt32Array())
	var reference_ceiling: PackedInt32Array = snapshot.get("price_reference_ceiling", PackedInt32Array())
	var base_ceiling: PackedInt32Array = snapshot.get("price_base_ceiling", PackedInt32Array())
	var effective_ceiling: PackedInt32Array = snapshot.get("price_effective_ceiling", PackedInt32Array())
	var target_ceiling: PackedInt32Array = snapshot.get("price_target_ceiling", PackedInt32Array())
	var confirmation_days: PackedInt32Array = snapshot.get("price_ceiling_confirmation_days", PackedInt32Array())
	var shortage_q16: PackedInt32Array = snapshot.get("shortage_q16", PackedInt32Array())
	var technology_available: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var trade_enabled: PackedByteArray = snapshot.get(
		"good_trade_enabled", PackedByteArray())
	var trade_inbound: PackedInt64Array = snapshot.get(
		"trade_inbound", PackedInt64Array())
	var trade_outbound: PackedInt64Array = snapshot.get(
		"trade_outbound", PackedInt64Array())
	var trade_import_ema: PackedInt64Array = snapshot.get(
		"trade_import_ema", PackedInt64Array())
	var trade_export_ema: PackedInt64Array = snapshot.get(
		"trade_export_ema", PackedInt64Array())
	var enforce_technology = technology_available.size() == good_ids.size()
	var market_id = int(snapshot.get("market_id", snapshot.get("cell_idx", -1)))
	var sample_day = int(snapshot.get("sample_day", h._current_sample_day()))
	if market_id >= 0:
		host._ensure_detail_history_cell(market_id)
	var should_sample_market = market_id >= 0 and sample_day >= 0 \
		and sample_day != host._detail_history_market_day
	if should_sample_market:
		host._detail_history_market_day = sample_day
	var in_transit_kinds = 0
	for i in range(good_ids.size()):
		if enforce_technology and technology_available[i] == 0:
			continue
		var stable_id = String(good_ids[i])
		var profile = GoodProfileRegistry.profile_by_id(stable_id)
		var display_name = String(profile.display_name) if profile != null else stable_id
		var stock_raw = int(stock[i]) if i < stock.size() else 0
		var stock_units = float(stock_raw) / 1000.0
		var price_raw = int(prices[i]) if i < prices.size() else 0
		var price_val = float(price_raw) / 10000.0
		var anchor_raw = int(cost_anchor[i]) if i < cost_anchor.size() else 0
		var anchor_val = float(anchor_raw) / 10000.0
		var price_index = float(price_raw) / float(anchor_raw) if anchor_raw > 0 else 1.0
		var hh_demand_units = float(demand_ema[i]) / 1000.0 if i < demand_ema.size() else 0.0
		var biz_demand_units = float(business_demand_ema[i]) / 1000.0 if i < business_demand_ema.size() else 0.0
		var total_demand_units = hh_demand_units + biz_demand_units
		var supply_units = float(offered_supply_ema[i]) / 1000.0 if i < offered_supply_ema.size() else 0.0
		var stock_daily = host._sample_daily_delta(host._market_prev_stock,
			"%d:%s" % [market_id, stable_id], stock_units, sample_day)
		var shortage = float(shortage_q16[i]) * 100.0 / 65536.0 if i < shortage_q16.size() else 0.0
		var allow_trade = host._market_trade_enabled(trade_enabled, i)
		var inbound = host._packed_i64_at(trade_inbound, i) if allow_trade else 0
		var outbound = host._packed_i64_at(trade_outbound, i) if allow_trade else 0
		var import_flow = host._packed_i64_at(trade_import_ema, i) if allow_trade else 0
		var export_flow = host._packed_i64_at(trade_export_ema, i) if allow_trade else 0
		var inbound_units = float(inbound) / 1000.0
		var outbound_units = float(outbound) / 1000.0
		var import_flow_units = float(import_flow) / 1000.0
		var export_flow_units = float(export_flow) / 1000.0
		var in_transit = inbound > 0 or outbound > 0
		if in_transit:
			in_transit_kinds += 1
		if should_sample_market:
			host._record_good_history(stable_id, price_val, price_index, stock_units, shortage / 100.0)
		var good_hist: Dictionary = host._good_history.get(stable_id, {})
		var price_series: PackedFloat32Array = good_hist.get("price", PackedFloat32Array())
		var stock_series: PackedFloat32Array = good_hist.get("stock", PackedFloat32Array())
		var stock_plain = host._goods_unit_text(stock_raw)
		# 列表副行只给数量：列头已写「库存」，每行再带一次「单位」只是噪音。
		var stock_text = UITokens.format_compact_number_cn(stock_units, 2)
		var anchor_text = h._money_text(anchor_raw) if anchor_raw > 0 else "—"
		var days_of_stock = stock_units / total_demand_units if total_demand_units > 0.001 \
			else (999.0 if stock_units > 0.001 else 0.0)
		var detail_rows = [
			{"id": "household_demand", "name": "居民需求", "value": UITokens.format_compact_number_cn(hh_demand_units, 2)},
			{"id": "business_demand", "name": "产业需求", "value": UITokens.format_compact_number_cn(biz_demand_units, 2)},
			{"id": "supply", "name": "供给", "value": UITokens.format_compact_number_cn(supply_units, 2)},
			{"id": "cost_anchor", "name": "成本锚", "value": anchor_text},
			{"id": "price_index", "name": "价格倍率", "value": "%.2f 倍" % price_index if anchor_raw > 0 else "—"},
			{"id": "shortage", "name": "短缺", "value": "%.1f%%" % shortage},
		]
		if inbound > 0:
			detail_rows.append({"id": "trade_inbound", "name": "运入",
				"value": h._goods_unit_text(inbound)})
		if outbound > 0:
			detail_rows.append({"id": "trade_outbound", "name": "运出",
				"value": h._goods_unit_text(outbound)})
		if import_flow > 0:
			detail_rows.append({"id": "trade_import_flow", "name": "进口均量",
				"value": h._goods_unit_text(import_flow)})
		if export_flow > 0:
			detail_rows.append({"id": "trade_export_flow", "name": "出口均量",
				"value": h._goods_unit_text(export_flow)})
		rows.append({
			"id": "market_%s" % stable_id,
			"name": display_name,
			"good_id": stable_id,
			"stock": "%s · 在途" % stock_text if in_transit else stock_text,
			"stock_plain": stock_plain,
			"stock_units_float": stock_units,
			"days_of_stock_float": days_of_stock,
			"price": h._money_text(price_raw),
			"price_float": price_val,
			"cost_anchor_text": anchor_text,
			"cost_anchor_float": anchor_val,
			"price_index_float": price_index,
			"household_demand_float": hh_demand_units,
			"business_demand_float": biz_demand_units,
			"supply_float": supply_units,
			"shortage_float": shortage / 100.0,
			"inbound_float": inbound_units,
			"outbound_float": outbound_units,
			"import_flow_float": import_flow_units,
			"export_flow_float": export_flow_units,
			"price_spark": price_series,
			"price_delta": h._series_lookback_delta(price_series),
			"stock_spark": stock_series,
			"stock_delta": stock_daily,
			"delta": h._daily_delta_text(stock_daily),
			"risk": "短缺" if shortage >= 25.0 else "",
			"trade_inbound": h._goods_unit_text(inbound) if inbound > 0 else "",
			"trade_outbound": h._goods_unit_text(outbound) if outbound > 0 else "",
			"detail_rows": detail_rows,
			"accent": UITokens.RISK if shortage >= 25.0 else UITokens.RESOURCE,
			"icon": GoodProfileRegistry.icon_key(stable_id),
			"visible": true,
			"_rank": (0 if shortage >= 25.0 else (1 if in_transit else (
				2 if i < stock.size() and stock[i] > 0 else 3))) * 100000 + rows.size(),
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["_rank"]) < int(b["_rank"]))
	for row_value in rows:
		(row_value as Dictionary).erase("_rank")
	var trade_net = int(snapshot.get("merchant_trade_sale_cash", 0)) \
		- int(snapshot.get("merchant_trade_purchase_cash", 0))
	var arrival_days = host._trade_arrival_days(
		int(snapshot.get("trade_next_arrival_day", -1)), sample_day)
	var market_insights = []
	if in_transit_kinds > 0:
		market_insights.append({
			"id": "market_trade_in_transit",
			"text": h._market_trade_insight_text(in_transit_kinds, arrival_days),
			"accent": UITokens.ACCENT,
			"icon": "metric.trade",
		})
	return {
		"insights": market_insights,
		"metrics": [
			{"id": "merchant_cash", "title": "商家现金", "money": true, "value": h._money_text(int(snapshot.get("merchant_cash", 0))), "subtitle": "", "accent": UITokens.ACCENT, "icon": "resource"},
			{"id": "merchant_trade_net", "title": "贸易净额", "money": true, "value": h._money_text(trade_net), "subtitle": "", "accent": UITokens.ACCENT if trade_net == 0 else (UITokens.GOOD if trade_net > 0 else UITokens.RISK), "icon": "resource"},
		],
		"sections": [{
			"id": "merchant_accounts",
			"title": "商家账目",
			"icon": "resource",
			"accent": UITokens.RESOURCE,
			"collapsed": true,
			"metrics": [
				{"id": "merchant_inventory_liquidation", "title": "库存估值", "money": true, "value": h._money_text(int(snapshot.get("merchant_inventory_liquidation_value", 0))), "subtitle": "", "tooltip": "按零售价估算的库存价值。", "accent": UITokens.RESOURCE, "icon": "resource"},
				{"id": "merchant_assets", "title": "商业资产", "money": true, "value": h._money_text(int(snapshot.get("merchant_economic_assets", 0))), "subtitle": "", "tooltip": "现金加库存估值。", "accent": UITokens.GOOD, "icon": "resource"},
				{"id": "merchant_coverage", "title": "周转覆盖", "value": "%s 期" % UITokens.format_compact_number_cn(float(snapshot.get("merchant_liquidity_coverage_q16", 65536)) / 65536.0, 1), "subtitle": "", "tooltip": "现金可支撑的经营期数。", "accent": UITokens.ACCENT, "icon": "resource"},
				{"id": "merchant_margin", "title": "采购毛利", "money": true, "value": h._money_text(int(snapshot.get("merchant_procurement_margin_value", 0))), "subtitle": "", "accent": UITokens.GOOD, "icon": "resource"},
			],
		}],
		"market_rows": rows,
		"list_header": {"lead": "商品 · 库存", "indent": 39.0, "columns": [
			{"text": "价格", "width": 84.0}]},
		# 物资详情逐单商路用：订单页只会在 committed generation 变化后失效。
		"economy_generation": int(snapshot.get("economy_generation", -1)),
		"sample_day": sample_day,
	}


# ─── 物资详情 · 逐单商路 ──────────────────────────────────────────────────
# 对象详情打开后按需查询；页缓存按 committed generation，行缓存再叠加
# sample_day 与视野 revision，因此日 tick / 200ms live patch 不会重复查询原生。
# 对端名称只为 FOG_VISIBLE 的格子读取；不可见对端在本层遮蔽，不查询名称。


func trade_orders_model(host, cell_idx: int, good_id: String, offset: int = 0,
		limit: int = TRADE_ORDER_PAGE_SIZE, generation: int = -1,
		sample_day: int = -1) -> Dictionary:
	var h = host
	if host._map == null or cell_idx < 0:
		return h._trade_orders_failure("", "trade_orders_map_unavailable")
	if VisionSolver.fog_state(host._map, cell_idx) != VisionSolver.FOG_VISIBLE:
		return h._trade_orders_failure("此地不在当前视野内。", "cell_not_visible")
	var facade = host._economy_facade()
	if facade == null or not facade.has_method("trade_orders_for_cell"):
		return h._trade_orders_failure("贸易数据暂不可用。", "trade_order_api_unavailable")
	var good_index = host._trade_order_good_index(facade, good_id)
	if good_index < 0:
		return h._trade_orders_failure("物资不在当前列表中。", "unknown_good")
	var page_limit = clampi(limit, 1, 64)
	var page_offset = maxi(0, offset)
	var resolved_sample_day = sample_day if sample_day >= 0 else host._current_sample_day()
	if generation >= 0 and generation != host._trade_order_generation:
		host._trade_order_generation = generation
		host._trade_order_pages.clear()
		host._trade_order_models.clear()
		host._trade_order_names.clear()
	if generation >= 0:
		var page_key = host._trade_order_page_key(
			cell_idx, good_index, generation, page_offset, page_limit)
		var page: Dictionary = host._trade_order_pages.get(page_key, {})
		if page.is_empty():
			page = host._query_trade_order_page(
				facade, cell_idx, good_index, page_offset, page_limit)
			if bool(page.get("pending", false)):
				return host._trade_orders_pending_model(
					page, page_offset, page_limit, resolved_sample_day, generation)
			if not bool(page.get("ok", false)):
				return h._trade_orders_failure("贸易流水暂不可用。",
					String(page.get("reason", "trade_order_query_failed")))
			host._trade_order_pages[page_key] = page
			host._trim_dictionary(host._trade_order_pages, host.TRADE_ORDER_PAGE_CACHE_LIMIT)
			# 总数缩小导致请求 offset 越界时，把原生钳制后的末页别名回请求 key，
			# 避免之后每次刷新都重新查询一次。
			var effective = int(page.get("page_begin", page_offset))
			if effective != page_offset:
				host._trade_order_pages[host._trade_order_page_key(
					cell_idx, good_index, generation, effective, page_limit)] = page
		var model_key = "%s|%d|%d" % [page_key, resolved_sample_day,
			int(host._map.vision_revision)]
		var cached_model: Dictionary = host._trade_order_models.get(model_key, {})
		if not cached_model.is_empty():
			return cached_model
		var built = host._build_trade_orders_model(page, resolved_sample_day, generation)
		host._trade_order_models[model_key] = built
		host._trim_dictionary(host._trade_order_models, host.TRADE_ORDER_MODEL_CACHE_LIMIT)
		return built
	# generation 缺失只可能出现在旧桥/异常路径：退化为每次有界查询，不保留页缓存。
	var uncached_page = host._query_trade_order_page(
		facade, cell_idx, good_index, page_offset, page_limit)
	if bool(uncached_page.get("pending", false)):
		return host._trade_orders_pending_model(
			uncached_page, page_offset, page_limit, resolved_sample_day, generation)
	if not bool(uncached_page.get("ok", false)):
		return h._trade_orders_failure("贸易流水暂不可用。",
			String(uncached_page.get("reason", "trade_order_query_failed")))
	return host._build_trade_orders_model(
		uncached_page, resolved_sample_day, generation)



func _trade_order_page_key(host, cell_idx: int, good_index: int, generation: int,
		offset: int, limit: int) -> String:
	var h = host
	return "%d|%d|%d|%d|%d" % [cell_idx, good_index, generation, offset, limit]



func _query_trade_order_page(host, facade, cell_idx: int, good_index: int,
		offset: int, limit: int) -> Dictionary:
	var h = host
	var page: Dictionary = facade.trade_orders_for_cell(
		cell_idx, offset, limit, good_index)
	host._trade_order_query_count += 1
	if h._snapshot_pending(page) or String(page.get("reason", "")) == "economy_read_view_pending":
		page["pending"] = true
	return page



func _trade_order_good_index(host, facade, good_id: String) -> int:
	var h = host
	var stable_id = good_id.strip_edges()
	if stable_id.is_empty():
		return -1
	if host._trade_order_good_indices.is_empty():
		var ids: PackedStringArray = facade.good_ids() \
			if facade.has_method("good_ids") else PackedStringArray()
		for index in range(ids.size()):
			host._trade_order_good_indices[String(ids[index])] = index
	return int(host._trade_order_good_indices.get(stable_id, -1))



func _economy_facade(host):
	var h = host
	if h._generator == null or not h._generator.has_method("get_economy_facade"):
		return null
	return host._generator.get_economy_facade()



func _trade_orders_failure(host, text: String, reason: String) -> Dictionary:
	var h = host
	return {"ok": false, "pending": false, "reason": reason,
		"rows": [], "rows_by_id": {}, "total": 0, "offset": 0,
		"limit": h.TRADE_ORDER_PAGE_SIZE, "has_more": false,
		"page_label": "", "hint": text, "empty_text": text,
		"signature": "", "sample_day": -1, "economy_generation": -1}



func _trade_orders_pending_model(host, page: Dictionary, offset: int, limit: int,
		sample_day: int, generation: int) -> Dictionary:
	var h = host
	return {"ok": false, "pending": true,
		"reason": String(page.get("reason", "economy_read_view_pending")),
		"rows": [], "rows_by_id": {}, "total": 0, "offset": offset,
		"limit": limit, "has_more": false, "page_label": "",
		"hint": "经济结算中，沿用上次结果。",
		"empty_text": "经济结算中，暂无可读订单。",
		"signature": "", "sample_day": sample_day,
		"economy_generation": generation}



static func _trim_dictionary(cache: Dictionary, limit: int) -> void:
	while cache.size() > limit:
		cache.erase(cache.keys()[0])



func _build_trade_orders_model(host, page: Dictionary,
		sample_day: int, generation: int) -> Dictionary:
	var h = host
	# 倒计时按 UI 当前世界日计算：订单页的 native sample_day 是上一次 committed
	# 边界，若拿它当“今天”，快进期间剩余天数会一直卡住。generation 只用于缓存。
	var day = sample_day
	if day < 0:
		day = host._current_sample_day()
	var order_ids: PackedInt64Array = page.get("order_ids", PackedInt64Array())
	var directions: PackedInt32Array = page.get("directions", PackedInt32Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var destinations: PackedInt32Array = page.get(
		"destination_cells", PackedInt32Array())
	var departure_days: PackedInt64Array = page.get(
		"departure_days", PackedInt64Array())
	var arrival_days: PackedInt64Array = page.get(
		"arrival_days", PackedInt64Array())
	var cash_escrows: PackedInt64Array = page.get(
		"cash_escrow", PackedInt64Array())
	var capacity_works: PackedInt64Array = page.get(
		"capacity_work", PackedInt64Array())
	var cargo_delivered: PackedByteArray = page.get(
		"cargo_delivered", PackedByteArray())
	var order_flags: PackedByteArray = page.get("order_flags", PackedByteArray())
	var line_offsets: PackedInt32Array = page.get("line_offsets", PackedInt32Array())
	var line_quantities: PackedInt64Array = page.get(
		"line_quantities", PackedInt64Array())
	var line_unit_prices: PackedInt32Array = page.get(
		"line_unit_prices", PackedInt32Array())
	var line_destination_prices: PackedInt32Array = page.get(
		"line_destination_prices", PackedInt32Array())
	var line_base_values: PackedInt64Array = page.get(
		"line_base_values", PackedInt64Array())
	var rows: Array = []
	var rows_by_id: Dictionary = {}
	var page_units = 0
	var waiting_receivers = 0
	var first_arrival = -1
	for i in range(order_ids.size()):
		var order_id = int(order_ids[i])
		var direction = int(directions[i]) if i < directions.size() else 0
		var source_cell = int(sources[i]) if i < sources.size() else -1
		var destination_cell = int(destinations[i]) if i < destinations.size() else -1
		var counterpart = source_cell if direction > 0 else destination_cell
		var departure = int(departure_days[i]) if i < departure_days.size() else day
		var arrival = int(arrival_days[i]) if i < arrival_days.size() else day
		var line_begin = int(line_offsets[i]) if i < line_offsets.size() else 0
		var line_end = int(line_offsets[i + 1]) if i + 1 < line_offsets.size() \
			else line_begin
		var quantity = 0
		var base_value = 0
		var source_price = 0
		var destination_price = 0
		for line in range(line_begin, line_end):
			quantity += int(line_quantities[line]) if line < line_quantities.size() else 0
			base_value += int(line_base_values[line]) if line < line_base_values.size() else 0
			if line < line_unit_prices.size() and source_price <= 0:
				source_price = int(line_unit_prices[line])
			if line < line_destination_prices.size() and destination_price <= 0:
				destination_price = int(line_destination_prices[line])
		var delivered = int(cargo_delivered[i]) if i < cargo_delivered.size() else 0
		var flags = int(order_flags[i]) if i < order_flags.size() else 0
		var counterpart_visible: bool = counterpart >= 0 and VisionSolver.fog_state(
			host._map, counterpart) == VisionSolver.FOG_VISIBLE
		var counterpart_name = "视野外"
		var counterpart_sub = ""
		if counterpart_visible:
			counterpart_name = host._trade_counterpart_name(counterpart)
			var coord = host._trade_counterpart_coord(counterpart)
			if counterpart_name.is_empty():
				counterpart_name = coord
			elif not coord.is_empty():
				counterpart_sub = coord
			if (flags & 1) != 0:
				counterpart_sub = "跨国" if counterpart_sub.is_empty() \
					else "跨国 · %s" % counterpart_sub
		var remaining = maxi(0, arrival - day)
		var span = maxi(1, arrival - departure)
		var progress = clampf(float(day - departure) / float(span), 0.0, 1.0)
		var route_text = "今日到达" if remaining <= 0 else "剩 %d 日" % remaining
		var status_text = "待收款" if delivered != 0 else "在途"
		if delivered != 0:
			waiting_receivers += 1
		var price_text = "—"
		if counterpart_visible and source_price > 0 and destination_price > 0:
			price_text = "%s → %s" % [
				host._money_text(source_price), host._money_text(destination_price)]
		page_units += quantity
		if first_arrival < 0 or arrival < first_arrival:
			first_arrival = arrival
		var escrow = int(cash_escrows[i]) if i < cash_escrows.size() else 0
		var capacity = int(capacity_works[i]) if i < capacity_works.size() else 0
		var row_id = "trade_order_%d" % order_id
		var row = {
			"id": row_id,
			"tooltip": h._trade_order_tooltip(order_id, direction, counterpart_name,
				counterpart_visible, quantity, source_price, destination_price,
				base_value, escrow, capacity, departure, arrival, remaining,
				delivered, flags),
			"muted": delivered != 0,
			"locate_cell": counterpart if counterpart_visible else -1,
			"cells": {
				"dir": {"text": "运入" if direction > 0 else "运出",
					"color": UITokens.DOSSIER_VERDIGRIS if direction > 0
						else UITokens.DOSSIER_OXBLOOD},
				"counterpart": {"text": counterpart_name,
					"sub": counterpart_sub},
				"quantity": {"text": h._goods_unit_text(quantity),
					"value": float(quantity) / 1000.0, "sort": quantity},
				"price": {"text": price_text,
					"sort": destination_price if counterpart_visible else 0},
				"route": {"text": route_text, "value": progress,
					"sort": remaining,
					"bar_color": UITokens.DOSSIER_BRASS if remaining > 0
						else UITokens.DOSSIER_VERDIGRIS},
				"status": {"text": status_text,
					"color": UITokens.DOSSIER_INK_MUTED if delivered != 0
						else UITokens.DOSSIER_BRASS},
			},
		}
		rows.append(row)
		rows_by_id[row_id] = row
	var total = int(page.get("total", rows.size()))
	var page_begin = int(page.get("page_begin", 0))
	var page_label = ""
	if total > rows.size() or page_begin > 0:
		page_label = "%d-%d / %d" % [
			page_begin + 1, page_begin + rows.size(), total]
	var page_text = "%d 笔 · %s 单位" % [rows.size(),
		UITokens.format_compact_number_cn(float(page_units) / 1000.0, 2)]
	if waiting_receivers > 0:
		page_text += " · 待收款 %d 笔" % waiting_receivers
	if first_arrival >= 0 and not rows.is_empty():
		page_text += " · 最近到达 第 %d 天" % (first_arrival + 1)
	var ids = PackedStringArray()
	for value in order_ids:
		ids.append(str(int(value)))
	return {
		"ok": true,
		"pending": false,
		"reason": "",
		"rows": rows,
		"rows_by_id": rows_by_id,
		"total": total,
		"offset": page_begin,
		"limit": int(page.get("limit", rows.size())),
		"has_more": bool(page.get("has_more", false)),
		"page_label": page_label,
		"hint": page_text,
		"empty_text": "",
		"signature": "%d|%d|%d|%d|%d|%s" % [generation, day, page_begin,
			total, int(h._map.vision_revision), ",".join(ids)],
		"sample_day": day,
		"economy_generation": generation,
	}



func _trade_counterpart_name(host, cell_idx: int) -> String:
	var h = host
	if host._trade_order_names.has(cell_idx):
		return String(host._trade_order_names[cell_idx])
	var summary = host._population_summary(cell_idx)
	if not bool(summary.get("ok", false)):
		return ""
	var name = String(summary.get("settlement_name", "")).strip_edges()
	if host._trade_order_names.size() > host.TRADE_ORDER_NAME_CACHE_LIMIT:
		host._trade_order_names.clear()
	host._trade_order_names[cell_idx] = name
	return name



func _trade_counterpart_coord(host, cell_idx: int) -> String:
	var h = host
	var cell: HexCell = host._map.cell_at(cell_idx) if host._map != null else null
	if cell == null:
		return "地块 %d" % (cell_idx + 1)
	var off = HexUtils.cube_to_offset(cell.q, cell.r)
	return "区域 %d, %d" % [off.x + 1, off.y + 1]



func _trade_order_tooltip(host, order_id: int, direction: int, counterpart_name: String,
		counterpart_visible: bool, quantity: int, source_price: int,
		destination_price: int, base_value: int, escrow: int, capacity: int,
		departure: int, arrival: int, remaining: int, delivered: int,
		flags: int) -> String:
	var h = host
	var lines = PackedStringArray()
	lines.append("订单 #%d · %s" % [order_id,
		"运入" if direction > 0 else "运出"])
	if counterpart_visible:
		lines.append("对端：%s" % counterpart_name)
	else:
		lines.append("对端：视野外（仅显示本地订单事实）")
	lines.append("货物：%s · 货值 %s" % [
		host._goods_unit_text(quantity), host._money_text(base_value)])
	if counterpart_visible and source_price > 0 and destination_price > 0:
		lines.append("单价：%s → %s" % [
			host._money_text(source_price), host._money_text(destination_price)])
	lines.append("出发 第 %d 天 → 到达 第 %d 天（%s）" % [
		departure + 1, arrival + 1,
		"今日到达" if remaining <= 0 else "剩余 %d 日" % remaining])
	lines.append("托管现金 %s · 运力 %s" % [
		host._money_text(escrow),
		UITokens.format_compact_number_cn(float(capacity), 1)])
	if delivered != 0:
		lines.append("货物已交付，卖方现金待收款。")
	var notes = PackedStringArray()
	if (flags & 1) != 0:
		notes.append("跨国贸易")
	if (flags & 2) != 0:
		notes.append("救济运输")
	if (flags & 4) != 0:
		notes.append("进口补贴")
	if (flags & 8) != 0:
		notes.append("出口补贴")
	if (flags & 16) != 0:
		notes.append("进口税")
	if (flags & 32) != 0:
		notes.append("出口税")
	if not notes.is_empty():
		lines.append(" · ".join(notes))
	return "\n".join(lines)
