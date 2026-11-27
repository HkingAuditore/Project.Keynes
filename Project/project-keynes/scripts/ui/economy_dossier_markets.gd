extends RefCounted

## Builds industry, trade, city, and goods-market reports.


static func industry_model(owner: EconomyDossierViewModel, sector_filter: int) -> Dictionary:
	var page := owner.query("buildings", sector_filter)
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": EconomyDossierViewModel._reason(page)}
	var rows: Array = []
	var names = page.get("building_display_names", page.get("building_stable_ids", PackedStringArray()))
	var sectors = page.get("economic_sectors", PackedInt32Array())
	var reason_count := int(page.get("rejection_reason_count", EconomyDossierViewModel.REJECTION_CATEGORY.size()))
	var rejections = page.get("rejection_units", PackedInt64Array())
	for row in range((page.get("type_indices", PackedInt32Array())).size()):
		var revenue := EconomyDossierViewModel._at(page.get("revenue_per_day", []), row)
		var input_cost := EconomyDossierViewModel._at(page.get("input_cost_per_day", []), row)
		var wages_paid := EconomyDossierViewModel._at(page.get("wages_paid_per_day", []), row)
		var wages_due := EconomyDossierViewModel._at(page.get("wages_due_per_day", []), row)
		var maintenance := EconomyDossierViewModel._at(page.get("maintenance_per_day", []), row)
		var tax := EconomyDossierViewModel._at(page.get("business_tax_per_day", []), row)
		var support := EconomyDossierViewModel._at(page.get("producer_support_per_day", []), row)
		var profit := revenue + support - input_cost - wages_paid - maintenance - tax
		var required := EconomyDossierViewModel._at(page.get("jobs_required", []), row)
		var filled := EconomyDossierViewModel._at(page.get("jobs_filled", []), row)
		var output := EconomyDossierViewModel._at(page.get("output_per_day", []), row)
		var top_reason := -1
		var top_count := 0.0
		for reason in range(mini(reason_count, EconomyDossierViewModel.REJECTION_CATEGORY.size())):
			if EconomyDossierViewModel.REJECTION_CATEGORY[reason].is_empty():
				continue
			var count := EconomyDossierViewModel._at(rejections, row * reason_count + reason)
			if count > top_count:
				top_count = count
				top_reason = reason
		var sector := int(EconomyDossierViewModel._at(sectors, row))
		rows.append({
			"id": int(EconomyDossierViewModel._at(page.get("type_indices", []), row)),
			"name": String(names[row]) if row < names.size() else "",
			"sector": sector,
			"sector_name": String(EconomyDossierViewModel.SECTORS[sector].name) if sector >= 0 and sector < EconomyDossierViewModel.SECTORS.size() else "",
			"color": EconomyDossierViewModel.SECTORS[sector].color if sector >= 0 and sector < EconomyDossierViewModel.SECTORS.size() else UITokens.FAMILY_BRASS,
			"units": EconomyDossierViewModel._at(page.get("units", []), row),
			"suspended": EconomyDossierViewModel._at(page.get("suspended_units", []), row),
			"cells": int(EconomyDossierViewModel._at(page.get("cell_count", []), row)),
			"utilization": EconomyDossierViewModel._at(page.get("utilization_q16", []), row) / EconomyDossierViewModel.Q16,
			"revenue": revenue / EconomyDossierViewModel.MONEY_SCALE,
			"input_cost": input_cost / EconomyDossierViewModel.MONEY_SCALE,
			"wages": wages_paid / EconomyDossierViewModel.MONEY_SCALE,
			"maintenance": (maintenance + tax) / EconomyDossierViewModel.MONEY_SCALE,
			"support": support / EconomyDossierViewModel.MONEY_SCALE,
			"profit": profit / EconomyDossierViewModel.MONEY_SCALE,
			"margin": clampf(profit / revenue, -1.0, 1.0) if revenue > 0.0 else (-1.0 if profit < 0.0 else 0.0),
			"fill_rate": filled / required if required > 0.0 else 1.0,
			"jobs_required": required,
			"arrears_rate": maxf(0.0, wages_due - wages_paid) / wages_due if wages_due > 0.0 else 0.0,
			"discard_rate": EconomyDossierViewModel._at(page.get("discarded_per_day", []), row) / output if output > 0.0 else 0.0,
			"pending": EconomyDossierViewModel._at(page.get("pending_units", []), row),
			"blocker": EconomyDossierViewModel.REJECTION_LABELS[top_reason] if top_reason >= 0 else "",
			"blocker_category": EconomyDossierViewModel.REJECTION_CATEGORY[top_reason] if top_reason >= 0 else "",
		})
	return {"ok": true, "rows": rows, "total": int(page.get("total", rows.size())),
		"sectors": EconomyDossierViewModel.sector_rows(owner.query("summary"))}


# ── 投资风向 ────────────────────────────────────────────────────────────
static func investment_model(owner: EconomyDossierViewModel) -> Dictionary:
	var page := owner.query("investment")
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": EconomyDossierViewModel._reason(page)}
	var reason_count := int(page.get("rejection_reason_count", EconomyDossierViewModel.REJECTION_CATEGORY.size()))
	var histogram = page.get("rejection_units", PackedInt64Array())
	var sector_pending = page.get("sector_pending_units", PackedInt64Array())
	var sector_rejections = page.get("sector_rejection_units", PackedInt64Array())
	var flow_segments: Array = []
	for sector in EconomyDossierViewModel.SECTORS:
		flow_segments.append({"label": sector.name, "value": EconomyDossierViewModel._at(sector_pending, int(sector.id)),
			"color": sector.color, "text": "%d" % int(EconomyDossierViewModel._at(sector_pending, int(sector.id)))})
	var categories: Array = []
	for category in EconomyDossierViewModel.BOTTLENECK_ORDER:
		var reasons: Array = []
		var total := 0.0
		var by_sector := PackedFloat32Array()
		by_sector.resize(EconomyDossierViewModel.SECTORS.size())
		for reason in range(mini(reason_count, EconomyDossierViewModel.REJECTION_CATEGORY.size())):
			if EconomyDossierViewModel.REJECTION_CATEGORY[reason] != category:
				continue
			var count := EconomyDossierViewModel._at(histogram, reason)
			total += count
			for sector in range(EconomyDossierViewModel.SECTORS.size()):
				by_sector[sector] += EconomyDossierViewModel._at(sector_rejections, sector * reason_count + reason)
			if count > 0.0:
				reasons.append({"reason": reason, "label": EconomyDossierViewModel.REJECTION_LABELS[reason], "count": count})
		reasons.sort_custom(func(a, b): return float(a.count) > float(b.count))
		var meta: Dictionary = EconomyDossierViewModel.BOTTLENECK_META[category]
		categories.append({"id": category, "label": meta.label, "icon": meta.icon,
			"total": total, "reasons": reasons, "by_sector": by_sector, "advice": meta.advice})
	categories.sort_custom(func(a, b): return float(a.total) > float(b.total))
	var pending_rows: Array = []
	var types = page.get("pending_type_indices", PackedInt32Array())
	var day := int(page.get("current_day", 0))
	for row in range(types.size()):
		var type_index := int(types[row])
		pending_rows.append({"id": type_index,
			"name": String(owner._facade.building_display_name(type_index)) if owner._facade != null else str(type_index),
			"units": EconomyDossierViewModel._at(page.get("pending_units", []), row),
			"groups": int(EconomyDossierViewModel._at(page.get("pending_groups", []), row)),
			"days_left": maxi(0, int(EconomyDossierViewModel._at(page.get("pending_first_ready_day", []), row)) - day)})
	pending_rows.sort_custom(func(a, b): return float(a.units) > float(b.units))
	return {"ok": true, "flow": flow_segments,
		"pending_total": int(page.get("pending_total_units", 0)),
		"categories": categories, "pending": pending_rows,
		"sufficient_units": EconomyDossierViewModel._at(histogram, EconomyDossierViewModel.REJECTION_SUFFICIENT),
		"pressure": EconomyDossierViewModel.demand_pressure(owner.query("goods"), 6)}


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
		var wanted := EconomyDossierViewModel._at(demand, row)
		if wanted <= 0.0:
			continue
		var shortage := EconomyDossierViewModel._at(shortages, row) / EconomyDossierViewModel.Q16
		var cover := EconomyDossierViewModel._at(supply, row) / wanted
		var price_index := EconomyDossierViewModel._at(price, row) / EconomyDossierViewModel._at(anchor, row) if EconomyDossierViewModel._at(anchor, row) > 0.0 else 1.0
		var pressure := clampf(shortage * 0.6 + clampf(1.0 - cover, 0.0, 1.0) * 0.4, 0.0, 1.0)
		if pressure <= 0.05:
			continue
		rows.append({"row": row, "name": String(names[row]), "pressure": pressure,
			"cover": cover, "price_index": price_index, "shortage": shortage})
	rows.sort_custom(func(a, b): return float(a.pressure) > float(b.pressure))
	return rows.slice(0, limit)


# ── 物资市场 ────────────────────────────────────────────────────────────
static func market_model(owner: EconomyDossierViewModel, group_filter: String) -> Dictionary:
	var page := owner.query("goods")
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": EconomyDossierViewModel._reason(page)}
	var scale := maxf(1.0, float(page.get("goods_scale", 1)))
	var stable_ids = page.get("good_stable_ids", PackedStringArray())
	var names = page.get("good_display_names", stable_ids)
	var cells: Array = []
	var groups := {}
	for row in range(stable_ids.size()):
		var stable_id := String(stable_ids[row])
		var group := EconomyDossierViewModel.good_group(stable_id)
		if not group_filter.is_empty() and group != group_filter:
			continue
		var demand := EconomyDossierViewModel._at(page.get("demand_ema", []), row)
		var supply := EconomyDossierViewModel._at(page.get("offered_supply_ema", []), row)
		var withdrawal := EconomyDossierViewModel._at(page.get("realized_withdrawal_ema", []), row)
		var stock := EconomyDossierViewModel._at(page.get("stock", []), row)
		var shortage := EconomyDossierViewModel._at(page.get("shortage_q16", []), row) / EconomyDossierViewModel.Q16
		var anchor := EconomyDossierViewModel._at(page.get("cost_anchor_price", []), row)
		var price := EconomyDossierViewModel._at(page.get("price", []), row)
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
			"price": price / EconomyDossierViewModel.MONEY_SCALE, "demand": demand / scale, "supply": supply / scale,
			"stock": stock / scale, "days_of_stock": days_of_stock,
			"import": EconomyDossierViewModel._at(page.get("trade_import_ema", []), row) / scale,
			"export": EconomyDossierViewModel._at(page.get("trade_export_ema", []), row) / scale,
			"shortage_cells": int(EconomyDossierViewModel._at(page.get("shortage_cell_count", []), row)),
			"market_cells": int(EconomyDossierViewModel._at(page.get("market_cell_count", []), row))})
		groups[group] = int(groups.get(group, 0)) + 1
	var group_rows: Array = []
	for group in EconomyDossierViewModel.GOOD_GROUPS:
		if groups.has(group.id):
			group_rows.append({"id": group.id, "name": group.name, "count": groups[group.id]})
	return {"ok": true, "cells": cells, "groups": group_rows}



static func good_group(stable_id: String) -> String:
	if EconomyDossierViewModel._good_group_cache.has(stable_id):
		return EconomyDossierViewModel._good_group_cache[stable_id]
	var group := "consumer"
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	if profile != null:
		for tag in profile.technology_tags:
			var matched := EconomyDossierViewModel._group_for_tag(String(tag))
			if not matched.is_empty():
				group = matched
				break
	EconomyDossierViewModel._good_group_cache[stable_id] = group
	return group



static func _group_for_tag(tag: String) -> String:
	for entry in EconomyDossierViewModel.GOOD_GROUPS:
		if (entry.tags as Array).has(tag):
			return String(entry.id)
	return ""


# ── 贸易 ────────────────────────────────────────────────────────────────
static func trade_model(owner: EconomyDossierViewModel) -> Dictionary:
	var summary: Dictionary = owner._model.get("trade_summary", {})
	if owner._facade == null or not owner._facade.has_method("country_trade_snapshot"):
		return {"ok": false, "reason": "国家贸易查询暂不可用"}
	var key := "trade|goods"
	var goods: Dictionary = owner._memo.get(key, {})
	if goods.is_empty():
		goods = owner._facade.country_trade_snapshot(owner._country_handle, "goods", 0, 64)
		owner._memo[key] = goods
	var partners: Dictionary = owner._memo.get("trade|partners", {})
	if partners.is_empty():
		partners = owner._facade.country_trade_snapshot(owner._country_handle, "partners", 0, 16)
		owner._memo["trade|partners"] = partners
	var rows: Array = []
	if bool(goods.get("ok", false)):
		var indices = goods.get("goods", PackedInt32Array())
		for row in range(indices.size()):
			var good := int(indices[row])
			var import_value := EconomyDossierViewModel._at(goods.get("import_base", []), row)
			var export_value := EconomyDossierViewModel._at(goods.get("export_base", []), row)
			rows.append({"id": good, "name": String(owner._facade.good_display_name(good)),
				"import": import_value / EconomyDossierViewModel.MONEY_SCALE, "export": export_value / EconomyDossierViewModel.MONEY_SCALE,
				"net": (export_value - import_value) / EconomyDossierViewModel.MONEY_SCALE,
				"import_qty": EconomyDossierViewModel._at(goods.get("import_quantity", []), row),
				"export_qty": EconomyDossierViewModel._at(goods.get("export_quantity", []), row),
				"tariff": (EconomyDossierViewModel._at(goods.get("import_tariff", []), row)
					+ EconomyDossierViewModel._at(goods.get("export_tariff", []), row)) / EconomyDossierViewModel.MONEY_SCALE,
				"cumulative_import": EconomyDossierViewModel._at(goods.get("cumulative_import_base", []), row) / EconomyDossierViewModel.MONEY_SCALE,
				"cumulative_export": EconomyDossierViewModel._at(goods.get("cumulative_export_base", []), row) / EconomyDossierViewModel.MONEY_SCALE})
	var partner_rows: Array = []
	if bool(partners.get("ok", false)):
		var slots = partners.get("partners", PackedInt32Array())
		for row in range(slots.size()):
			var handle := int(EconomyDossierViewModel._at(partners.get("partner_handles", []), row))
			var import_value := EconomyDossierViewModel._at(partners.get("import_base", []), row)
			var export_value := EconomyDossierViewModel._at(partners.get("export_base", []), row)
			partner_rows.append({"id": handle, "name": owner._partner_name(handle, int(slots[row])),
				"import": import_value / EconomyDossierViewModel.MONEY_SCALE, "export": export_value / EconomyDossierViewModel.MONEY_SCALE,
				"orders": int(EconomyDossierViewModel._at(partners.get("order_count", []), row))})
	return {"ok": bool(summary.get("ok", false)) or bool(goods.get("ok", false)),
		"reason": String(summary.get("reason", goods.get("reason", ""))),
		"imports": float(summary.get("previous_import_base", 0)) / EconomyDossierViewModel.MONEY_SCALE,
		"exports": float(summary.get("previous_export_base", 0)) / EconomyDossierViewModel.MONEY_SCALE,
		"tariff": float(summary.get("previous_tariff_net_income", 0)) / EconomyDossierViewModel.MONEY_SCALE,
		"cumulative_imports": float(summary.get("cumulative_import_base", 0)) / EconomyDossierViewModel.MONEY_SCALE,
		"cumulative_exports": float(summary.get("cumulative_export_base", 0)) / EconomyDossierViewModel.MONEY_SCALE,
		"goods": rows, "partners": partner_rows}



static func _partner_name(owner: EconomyDossierViewModel, handle: int, slot: int) -> String:
	var facade = owner._model.get("country_facade", null)
	if facade != null and handle > 0 and facade.has_method("snapshot"):
		var snapshot: Dictionary = facade.snapshot(handle)
		var name := String(snapshot.get("country_name", snapshot.get("display_name", "")))
		if bool(snapshot.get("ok", false)) and not name.is_empty():
			return name
	return "国家 %d" % slot


# ── 城市 ────────────────────────────────────────────────────────────────
static func cities_model(owner: EconomyDossierViewModel) -> Dictionary:
	var page := owner.query("settlements", -1, 0, 0, -1)
	if not bool(page.get("ok", false)):
		return {"ok": false, "reason": EconomyDossierViewModel._reason(page)}
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	var named = page.get("name_active", PackedByteArray())
	var good_names: PackedStringArray = page.get("good_ids", PackedStringArray())
	var tiers: PackedStringArray = page.get("prosperity_names", PackedStringArray())
	var rows: Array = []
	var villages := {"id": -2, "cell": -1, "name": "其余村落", "village": true, "count": 0,
		"population": 0.0, "income": 0.0, "satisfaction_weight": 0.0,
		"survival_weight": 0.0, "jobs_required": 0.0,
		"jobs_filled": 0.0, "units": 0.0, "suspended": 0.0, "profit": 0.0, "unemployed": 0.0}
	for row in range(cells.size()):
		var people := EconomyDossierViewModel._at(page.get("population", []), row)
		var satisfaction := EconomyDossierViewModel._at(page.get("satisfaction_q16", []), row) / EconomyDossierViewModel.Q16
		var required := EconomyDossierViewModel._at(page.get("jobs_required", []), row)
		var filled := EconomyDossierViewModel._at(page.get("jobs_filled", []), row)
		var income := EconomyDossierViewModel._at(page.get("income_per_day", []), row) / EconomyDossierViewModel.MONEY_SCALE
		var profit := EconomyDossierViewModel._at(page.get("profit_per_day", []), row) / EconomyDossierViewModel.MONEY_SCALE
		if row >= named.size() or int(named[row]) == 0:
			villages.count += 1
			villages.population += people
			villages.income += income
			villages.satisfaction_weight += satisfaction * people
			villages.survival_weight += EconomyDossierViewModel._at(
				page.get("survival_satisfaction_q16", []), row) / EconomyDossierViewModel.Q16 * people
			villages.jobs_required += required
			villages.jobs_filled += filled
			villages.units += EconomyDossierViewModel._at(page.get("building_units", []), row)
			villages.suspended += EconomyDossierViewModel._at(page.get("building_suspended_units", []), row)
			villages.profit += profit
			villages.unemployed += EconomyDossierViewModel._at(page.get("unemployed", []), row)
			continue
		var worst_good := int(EconomyDossierViewModel._at(page.get("worst_shortage_good", []), row))
		rows.append({"id": int(cells[row]), "cell": int(cells[row]), "name": String(names[row]),
			"village": false, "tier": tiers[row] if row < tiers.size() else "",
			"population": people, "income": income,
			"income_per_capita": income / people if people > 0.0 else 0.0,
			"satisfaction": satisfaction, "survival": EconomyDossierViewModel._at(page.get("survival_satisfaction_q16", []), row) / EconomyDossierViewModel.Q16,
			"fill_rate": filled / required if required > 0.0 else 1.0,
			"unemployment": EconomyDossierViewModel._at(page.get("unemployed", []), row) / people if people > 0.0 else 0.0,
			"units": EconomyDossierViewModel._at(page.get("building_units", []), row),
			"suspended": EconomyDossierViewModel._at(page.get("building_suspended_units", []), row),
			"profit": profit,
			"shortage": EconomyDossierViewModel._at(page.get("worst_shortage_q16", []), row) / EconomyDossierViewModel.Q16,
			"shortage_good": owner._good_name_from(good_names, worst_good),
			"state_day": int(EconomyDossierViewModel._at(page.get("state_day", []), row))})
	if int(villages.count) > 0:
		var people := float(villages.population)
		villages["income_per_capita"] = float(villages.income) / people if people > 0.0 else 0.0
		villages["satisfaction"] = float(villages.satisfaction_weight) / people if people > 0.0 else 0.0
		villages["survival"] = float(villages.survival_weight) / people if people > 0.0 else 0.0
		villages["fill_rate"] = float(villages.jobs_filled) / float(villages.jobs_required) \
			if float(villages.jobs_required) > 0.0 else 1.0
		villages["unemployment"] = float(villages.unemployed) / people if people > 0.0 else 0.0
		villages["shortage"] = 0.0
		villages["shortage_good"] = ""
		villages["tier"] = "%d 处" % int(villages.count)
		rows.append(villages)
	return {"ok": true, "rows": rows, "total": int(page.get("total", cells.size()))}



static func _good_name_from(owner: EconomyDossierViewModel, stable_ids: PackedStringArray, index: int) -> String:
	if owner._facade != null and index >= 0:
		return String(owner._facade.good_display_name(index))
	return String(stable_ids[index]) if index >= 0 and index < stable_ids.size() else ""



static func _settlement_name(owner: EconomyDossierViewModel, cell: int) -> String:
	var page := owner.query("settlements", -1, 0, 0, -1)
	var cells = page.get("cell_indices", PackedInt32Array())
	var names = page.get("settlement_names", PackedStringArray())
	for row in range(cells.size()):
		if int(cells[row]) == cell and row < names.size() and not String(names[row]).is_empty():
			return String(names[row])
	return "村落 #%d" % cell
