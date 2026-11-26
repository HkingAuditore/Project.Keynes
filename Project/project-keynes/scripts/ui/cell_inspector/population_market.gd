extends RefCounted

const MarketProjection = preload("res://scripts/ui/cell_inspector/market_projection.gd")

const PopulationPresentation = preload("res://scripts/ui/cell_inspector/population_presentation.gd")


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
	return PopulationPresentation._gdp_metrics(host, cell_idx)



func _population_category(host, snapshot: Dictionary, market_snapshot: Dictionary = {},
		cell_idx: int = -1) -> Dictionary:
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "population_unavailable", "text": "人口情报暂不可用。", "accent": UITokens.TEXT_MUTED, "icon": "population.crowd"}]}
	if not snapshot.has("populations"):
		return {"insights": [{"id": "population_details_unavailable", "text": "无法读取最新人口明细。", "accent": UITokens.RISK, "icon": "population.crowd"}]}
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
	var pop_sample_day = int(snapshot.get("sample_day", h._Geography_delegate._current_sample_day(h)))
	if pop_cell_idx >= 0:
		host._PopulationMarket_delegate._ensure_detail_history_cell(host, pop_cell_idx)
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
			var demand_metadata = host._PopulationMarket_delegate._demand_good_metadata(host, snapshot, i)
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
			demand_groups = host._PopulationMarket_delegate._group_demand_rows_by_usage(host, demand_rows)
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
					income_rows.append({"id": "income_%s" % source_id, "source_id": source_id, "name": h._Construction_delegate._cashflow_source_name(h, source_id, true), "value": "+%s/人" % h._money_text(income_pc_flow), "raw_per_capita": float(income_pc_flow) / 10000.0, "visible": true})
				if expense_value > 0:
					expense_rows.append({"id": "expense_%s" % source_id, "source_id": source_id, "name": h._Construction_delegate._cashflow_source_name(h, source_id, false), "value": "−%s/人" % h._money_text(expense_pc_flow), "raw_per_capita": float(expense_pc_flow) / 10000.0, "visible": true})
		# Fiscal attribution is authoritative even when the detailed cashflow trace
		# has expired or was intentionally omitted from this snapshot.
		var tax_paid_pc = int(epoch_tax_paid[i]) / maxi(population, 1) \
			if i < epoch_tax_paid.size() else 0
		var subsidy_received_pc = int(epoch_subsidy_received[i]) / maxi(population, 1) \
			if i < epoch_subsidy_received.size() else 0
		var has_tax_detail = h._Construction_delegate._has_cashflow_row(h, expense_rows, "income_tax") \
			or h._Construction_delegate._has_cashflow_row(h, expense_rows, "consumption_tax") \
			or h._Construction_delegate._has_cashflow_row(h, expense_rows, "business_tax")
		var has_subsidy_detail = h._Construction_delegate._has_cashflow_row(h, income_rows, "income_subsidy") \
			or h._Construction_delegate._has_cashflow_row(h, income_rows, "consumption_subsidy") \
			or h._Construction_delegate._has_cashflow_row(h, income_rows, "business_subsidy")
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
			host._PopulationMarket_delegate._record_cohort_history(host, cohort_hist_key, sat,
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
			"worst_dimension": h._PopulationMarket_delegate._satisfaction_dimension_name(h, worst_dimension),
			"worst_dimension_index": worst_dimension,
			"satisfaction_spark": sat_series,
			"satisfaction_delta": CellInspectorViewModel._PopulationMarket._series_lookback_delta(sat_series),
			"net_spark": net_series,
			"net_delta": CellInspectorViewModel._PopulationMarket._series_lookback_delta(net_series),
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
	# 民情并入阶层行：组织状态按职业挂在该职业的第一行上，不再单开页签。
	var unrest_by_profession: Dictionary = MobilizationCategoryModel.by_profession(
		host._economy_facade(), cell_idx if cell_idx >= 0 else pop_cell_idx)
	var unrest_names_by_stage = {}
	for row in rows:
		var row_dict: Dictionary = row
		var pid = String(row_dict.get("profession_id", ""))
		if not unrest_by_profession.has(pid):
			continue
		var unrest: Dictionary = unrest_by_profession[pid]
		unrest_by_profession.erase(pid)
		row_dict["unrest"] = unrest
		row_dict["status"] = "%s\n%s" % [String(row_dict.get("status", "")),
			String(unrest.get("tooltip", ""))]
		var stage = int(unrest.get("stage", 0))
		var names: PackedStringArray = unrest_names_by_stage.get(stage, PackedStringArray())
		names.append(String(row_dict.get("name", "")))
		unrest_names_by_stage[stage] = names
	var escalation = MobilizationCategoryModel.escalation_insight(unrest_names_by_stage)
	if not escalation.is_empty():
		insights.append(escalation)
	var local_metrics = [
		# 存款只给总额；本期结余挪进提示，不再在数值右边挂一串副行文字。
		{"id": "population_funds", "title": "居民存款", "money": true, "value": h._money_text(int(snapshot.get("funds", 0))), "subtitle": "", "accent": UITokens.ACCENT, "icon": "resource",
			"tooltip": "本格各阶层存款合计。本期%s %s。" % ["结余" if epoch_net >= 0 else "亏空", h._money_text(absi(epoch_net))]},
	]
	# 产值两格只在账本已跟踪该格时出现；他国 / 无主 / 无人聚落不加，指标行不会空转。
	local_metrics.append_array(host._PopulationMarket_delegate._gdp_metrics(host, cell_idx))
	return {
		"insights": insights,
		"gauges": gauges,
		"metrics": local_metrics,
		"cohort_rows": rows,
		"class_discontent": snapshot.get("class_discontent", {}),
		"list_header": {"lead": "阶层 · 族群 · 生活水平 · 满意度" if mixed_identity else "阶层 · 生活水平 · 满意度",
			"indent": 41.0, "columns": [
			{"text": "人口", "width": 54.0}, {"text": "存款/净收", "width": 72.0}]},
	}



func _group_demand_rows_by_usage(host, rows: Array) -> Array:
	return PopulationPresentation._group_demand_rows_by_usage(host, rows)



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
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "satisfaction", sat)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "net", net_val)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "income", income_val)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "wealth", wealth_val)
	host._cohort_history[cohort_key] = bucket



func _record_good_history(host, good_id: String, price_val: float, price_index: float,
		stock_units: float, shortage_ratio: float) -> void:
	var h = host
	var bucket: Dictionary = host._good_history.get(good_id, {})
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "price", price_val)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "price_index", price_index)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "stock", stock_units)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "shortage", shortage_ratio)
	host._good_history[good_id] = bucket



func _record_building_history(host, building_key: String, profit_val: float,
		utilization_ratio: float) -> void:
	var h = host
	var bucket: Dictionary = host._building_history.get(building_key, {})
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "profit", profit_val)
	h._PopulationMarket_delegate._append_history_sample(h, bucket, "utilization", utilization_ratio)
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
			"name": h._PopulationMarket_delegate._satisfaction_dimension_name(h, dimension),
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
	return MarketProjection._demand_good_metadata(host, snapshot, cohort_idx)


func _need_display_name(host, stable_id: String) -> String:
	return MarketProjection._need_display_name(host, stable_id)


func _market_category(host, snapshot: Dictionary) -> Dictionary:
	return MarketProjection._market_category(host, snapshot)


func trade_orders_model(host, cell_idx: int, good_id: String, offset: int = 0,
		limit: int = TRADE_ORDER_PAGE_SIZE, generation: int = -1,
		sample_day: int = -1) -> Dictionary:
	return MarketProjection.trade_orders_model(host, cell_idx, good_id, offset, limit, generation, sample_day)


func _trade_order_page_key(host, cell_idx: int, good_index: int, generation: int,
		offset: int, limit: int) -> String:
	return MarketProjection._trade_order_page_key(host, cell_idx, good_index, generation, offset, limit)


func _query_trade_order_page(host, facade, cell_idx: int, good_index: int,
		offset: int, limit: int) -> Dictionary:
	return MarketProjection._query_trade_order_page(host, facade, cell_idx, good_index, offset, limit)


func _trade_order_good_index(host, facade, good_id: String) -> int:
	return MarketProjection._trade_order_good_index(host, facade, good_id)


func _economy_facade(host):
	return MarketProjection._economy_facade(host)


func _trade_orders_failure(host, text: String, reason: String) -> Dictionary:
	return MarketProjection._trade_orders_failure(host, text, reason)


func _trade_orders_pending_model(host, page: Dictionary, offset: int, limit: int,
		sample_day: int, generation: int) -> Dictionary:
	return MarketProjection._trade_orders_pending_model(host, page, offset, limit, sample_day, generation)


static func _trim_dictionary(cache: Dictionary, limit: int) -> void:
	MarketProjection._trim_dictionary(cache, limit)


func _build_trade_orders_model(host, page: Dictionary,
		sample_day: int, generation: int) -> Dictionary:
	return MarketProjection._build_trade_orders_model(host, page, sample_day, generation)


func _trade_counterpart_name(host, cell_idx: int) -> String:
	return MarketProjection._trade_counterpart_name(host, cell_idx)


func _trade_counterpart_coord(host, cell_idx: int) -> String:
	return MarketProjection._trade_counterpart_coord(host, cell_idx)


func _trade_order_tooltip(host, order_id: int, direction: int, counterpart_name: String,
		counterpart_visible: bool, quantity: int, source_price: int,
		destination_price: int, base_value: int, escrow: int, capacity: int,
		departure: int, arrival: int, remaining: int, delivered: int,
		flags: int) -> String:
	return MarketProjection._trade_order_tooltip(host, order_id, direction, counterpart_name, counterpart_visible, quantity, source_price, destination_price, base_value, escrow, capacity, departure, arrival, remaining, delivered, flags)
