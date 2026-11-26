extends RefCounted

## Builds construction display rows from the snapshots and quotes already loaded by the inspector.

const ConstructionTooltip = preload("res://scripts/ui/cell_inspector/construction_tooltip.gd")


static func _construction_page_rows(host, entries: Array, quotes: Dictionary,
		snapshot: Dictionary, economy, market: Dictionary,
		maturity_names: PackedStringArray) -> Array:
	var h = host
	var rows = []
	var items: Array = quotes.get("items", [])
	var local_stock = host._construction_local_stock(market)
	var unlocked_goods = host._unlocked_good_ids(market)
	for raw in entries:
		var entry: Dictionary = raw
		var index = int(entry.get("index", -1))
		var item: Dictionary = items[index] \
			if index >= 0 and index < items.size() else {}
		var materials: Array = item.get("materials", [])
		var type_id = int(entry.get("type_id", -1))
		var building_id = String(entry.get("building_id", ""))
		var eligible = bool(entry.get("eligible", false))
		var reason_text = host._construction_reason_text(
			String(entry.get("reason_code", "")), materials, local_stock)
		var maturity = String(maturity_names[type_id]) \
			if type_id >= 0 and type_id < maturity_names.size() else ""
		var placement: Dictionary = economy.building_placement_spec(
			StringName(building_id)) if economy.has_method("building_placement_spec") else {}
		var job_spec: Dictionary = economy.building_job_spec(
			StringName(building_id)) if economy.has_method("building_job_spec") else {}
		var cash = int(entry.get("cash_required", 0))
		var material_status = host._construction_material_status_rows(materials, local_stock)
		var preview := _construction_preview_rows(host, placement, job_spec, unlocked_goods)
		rows.append({
			"building_id": building_id,
			"type_id": type_id,
			"name": String(entry.get("name", building_id)),
			"icon": entry.get("icon", &"economy.building"),
			"eligible": eligible,
			"blocked": not eligible,
			"reason_code": String(entry.get("reason_code", "")),
			"reason_text": "" if eligible else reason_text,
			"materials_text": h._construction_materials_text(materials),
			"cash_required": cash,
			"cash_text": h._money_text(cash),
			"days": int(entry.get("days", 0)),
			"score": int(entry.get("score", 0)),
			"maturity": maturity,
			"market_used": int(entry.get("market_used", 0)),
			"material_status": material_status,
			"preview": preview,
		"material_free": eligible and item.has("materials") and materials.is_empty(),
		"fold": entry.get("fold", {}),
		"fold_action": entry.get("fold_action", {}),
			"cash_blocked": String(entry.get("reason_code", ""))
				== "construction_treasury_cash_insufficient",
			"tooltip": h._construction_tooltip(entry, item, materials, local_stock,
				placement, job_spec, unlocked_goods, int(entry.get("days", 0)),
				maturity, reason_text),
		})
	return rows



static func _construction_materials_text(host, materials: Array) -> String:
	var h = host
	var parts = PackedStringArray()
	for raw in materials:
		if parts.size() >= 3:
			break
		var material: Dictionary = raw
		parts.append("%s %s" % [String(material.get("name", "建材")),
			h._goods_scaled(int(material.get("required", 0)))])
	var text = " · ".join(parts)
	if materials.size() > parts.size():
		text += " 等 %d 项" % materials.size()
	return text


static func _construction_material_status_rows(host, materials: Array,
		local_stock: Dictionary) -> Array:
	return ConstructionTooltip._construction_material_status_rows(host, materials, local_stock)


static func _construction_reason_text(host, code: String, materials: Array,
		local_stock: Dictionary) -> String:
	var h = host
	if code.is_empty() or code == "ok":
		return ""
	if code == "construction_materials_insufficient":
		# 同一个拒绝码覆盖两种缺料：国库+市场总量不够，或市场现货不够缺口。
		for raw in materials:
			var material: Dictionary = raw
			var shortfall = int(material.get("market", 0))
			if shortfall <= 0:
				continue
			var good_id = String(material.get("good_id", ""))
			if int(local_stock.get(good_id, 0)) < shortfall:
				return String(host.CONSTRUCTION_REASON_TEXT.get(
					"construction_market_short", "市场缺货"))
	return String(h.CONSTRUCTION_REASON_TEXT.get(code, "暂不可营造"))


static func _construction_tooltip(host, entry: Dictionary, item: Dictionary, materials: Array,
		local_stock: Dictionary, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary, days: int, maturity: String,
		reason_text: String) -> String:
	return ConstructionTooltip._construction_tooltip(host, entry, item, materials, local_stock, placement, job_spec, unlocked_goods, days, maturity, reason_text)



static func _construction_job_text(host, job_spec: Dictionary) -> String:
	var h = host
	if not bool(job_spec.get("ok", false)):
		return ""
	var parts = PackedStringArray()
	var owner_slots = int(job_spec.get("owner_slots", 0))
	if owner_slots > 0:
		parts.append("业主 %s ×%d" % [h._construction_profession_name(
			String(job_spec.get("owner_profession", ""))), owner_slots])
	var professions: PackedStringArray = job_spec.get(
		"employee_professions", PackedStringArray())
	var slots: PackedInt64Array = job_spec.get("employee_slots", PackedInt64Array())
	for index in range(professions.size()):
		var role_slots = int(slots[index]) if index < slots.size() else 0
		if role_slots <= 0:
			continue
		parts.append("雇员 %s ×%d" % [h._construction_profession_name(
			String(professions[index])), role_slots])
	return " · ".join(parts)



## 悬停卡 Body/Flow + Body/Employment 的结构化数据源。
##
## 704de6648 之后卡片只认 payload.preview（building_hover_card.gd:139-145），
## 而这里原来只把「投入/自然资源/产出/岗位」压成 tooltip 的纯文本，卡片拿到空字典，
## 于是营造目录的悬停卡永远不显示这几段。取数与 _construction_tooltip 完全同源：
## 同一份 placement（:1034）与 job_spec（:1036），复用 Recipes 的行构造，不另写一套。
static func _construction_preview_rows(host, placement: Dictionary, job_spec: Dictionary,
		unlocked_goods: Dictionary) -> Dictionary:
	var h = host
	# 数量行的字段是 name / detail / text（building_quantity_list.gd:19-28），
	# 而 Recipes 的行用的是 "quantity"，所以在这一层做一次映射。
	var outputs: Array = []
	for raw in h._construction_recipe_rows(placement, "output_good_ids",
			"output_quantities", "产出"):
		var row: Dictionary = raw
		outputs.append({"name": String(row.get("name", "")), "icon": &"metric.goods",
			"text": String(row.get("quantity", ""))})
	var inputs: Array = []
	for raw in h._construction_input_recipe_rows(placement, unlocked_goods):
		var row: Dictionary = raw
		inputs.append({"name": String(row.get("name", "")), "icon": &"metric.goods",
			"text": String(row.get("quantity", ""))})
	var resource_ids: PackedStringArray = placement.get("resource_ids", PackedStringArray())
	var resource_quantities: PackedInt64Array = placement.get(
		"resource_quantities", PackedInt64Array())
	var resource_modes: PackedInt32Array = placement.get("resource_modes", PackedInt32Array())
	for index in range(mini(resource_ids.size(),
			mini(resource_quantities.size(), resource_modes.size()))):
		# 与 tooltip 同一口径：承载需求是每栋储量门槛，开采量才是每日消耗。
		var resource_text := "需有 %s" % h._goods_scaled(resource_quantities[index]) \
			if resource_modes[index] == 1 \
			else "%s/日" % h._goods_scaled(resource_quantities[index])
		inputs.append({"name": h._resource_display_name(resource_ids[index]),
			"icon": &"metric.goods", "detail": "自然资源", "text": resource_text})
	var jobs: Array = []
	if bool(job_spec.get("ok", false)):
		var owner_slots = int(job_spec.get("owner_slots", 0))
		if owner_slots > 0:
			jobs.append({"name": h._construction_profession_name(
				String(job_spec.get("owner_profession", ""))), "icon": &"metric.population",
				"detail": "业主", "text": "×%d" % owner_slots})
		var professions: PackedStringArray = job_spec.get(
			"employee_professions", PackedStringArray())
		var slots: PackedInt64Array = job_spec.get("employee_slots", PackedInt64Array())
		for index in range(professions.size()):
			var role_slots = int(slots[index]) if index < slots.size() else 0
			if role_slots <= 0:
				continue
			jobs.append({"name": h._construction_profession_name(String(professions[index])),
				"icon": &"metric.population", "detail": "雇员", "text": "×%d" % role_slots})
	return {"outputs": outputs, "inputs": inputs, "jobs": jobs}


static func _append_construction_rows(host, rows: Array, snapshot: Dictionary, type_ids: PackedStringArray, type_names: PackedStringArray) -> void:
	var h = host
	var types: PackedInt32Array = snapshot.get("construction_type_ids", PackedInt32Array())
	var owners: PackedInt32Array = snapshot.get("construction_owner_signature_ids", PackedInt32Array())
	var counts: PackedInt64Array = snapshot.get("construction_counts", PackedInt64Array())
	var ready_days: PackedInt64Array = snapshot.get("construction_ready_days", PackedInt64Array())
	for i in range(types.size()):
		var type_idx = int(types[i])
		var building_id = String(type_ids[type_idx]) \
			if type_idx >= 0 and type_idx < type_ids.size() else ""
		rows.append({"id": "construction_%d_%d" % [type_idx, i], "name": String(type_names[type_idx]) if type_idx >= 0 and type_idx < type_names.size() else (building_id if not building_id.is_empty() else "建筑"), "building_type_id": building_id, "count": "%d" % (int(counts[i]) if i < counts.size() else 0), "owner": "业主 · %s" % h._Construction_delegate._owner_profession_name(h, snapshot, int(owners[i]) if i < owners.size() else -1), "status": "建造中 · 第 %d 日完工" % (int(ready_days[i]) if i < ready_days.size() else 0), "profit": "—", "profit_label": "未投产", "accent": UITokens.WARN, "icon": h._building_icon(building_id, snapshot, type_idx), "job_rows": [], "production_rows": [], "finance": {}, "visible": true})



static func _building_icon(host, type_id: String, snapshot: Dictionary = {}, type_idx: int = -1) -> StringName:
	var h = host
	if type_id.is_empty():
		return &"economy.building"
	var output_offsets: PackedInt32Array = snapshot.get(
		"building_output_offsets", PackedInt32Array())
	var output_good_indices: PackedInt32Array = snapshot.get(
		"building_output_good_ids", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var kinds: PackedInt32Array = snapshot.get("building_kinds", PackedInt32Array())
	if type_idx >= 0 and type_idx + 1 < output_offsets.size():
		var output_pos = int(output_offsets[type_idx])
		if output_pos < int(output_offsets[type_idx + 1]) \
				and output_pos >= 0 and output_pos < output_good_indices.size():
			var good_idx = int(output_good_indices[output_pos])
			if good_idx >= 0 and good_idx < good_ids.size():
				var kind = int(kinds[type_idx]) if type_idx < kinds.size() else 1
				return IconCatalog.building_semantic(type_id, good_ids[good_idx], kind)
	if type_id.contains("hearth"):
		return &"economy.building.hearth"
	if type_id.contains("gathering"):
		return &"economy.building.gathering"
	if type_id.contains("merchant") or type_id.contains("market") \
			or type_id.contains("trade"):
		return &"economy.building.market"
	if type_id.contains("fish"):
		return &"economy.building.fishing"
	if type_id.contains("hunting"):
		return &"economy.building.hunting"
	if type_id.contains("kitchen") or type_id.contains("food") \
			or type_id.contains("slaughterhouse"):
		return &"economy.building.food"
	if type_id.contains("farm") or type_id.contains("estate") \
			or type_id.contains("pasture") or type_id.contains("rice") \
			or type_id.contains("potato") or type_id.contains("wheat") \
			or type_id.contains("cotton") or type_id.contains("flax") \
			or type_id.contains("rubber_tree") or type_id.contains("spice") \
			or type_id.contains("herbs"):
		return &"economy.building.farm"
	if type_id.contains("timber") or type_id.contains("lumber"):
		return &"economy.building.forestry"
	if type_id.contains("mine") or type_id.contains("ore_") \
			or type_id.contains("quarry") or type_id.contains("stone_collector") \
			or type_id.contains("coal") or type_id.contains("oil_collector") \
			or type_id.contains("natural_gas") or type_id.contains("bauxite") \
			or type_id.contains("limestone") or type_id.contains("silica") \
			or type_id.contains("phosphate") or type_id.contains("salt") \
			or type_id.contains("sulfur") or type_id.contains("rare_earth") \
			or type_id.contains("flint"):
		return &"economy.building.mine"
	if type_id.contains("power"):
		return &"economy.building.power"
	if type_id.contains("shipyard"):
		return &"economy.building.shipyard"
	if type_id.contains("rail"):
		return &"economy.building.transport"
	if type_id.contains("scientific") or type_id.contains("medicine") \
			or type_id.contains("pharmaceutical"):
		return &"economy.building.science"
	if type_id.contains("workshop") or type_id.contains("kiln") \
			or type_id.contains("smith") or type_id.contains("tailor") \
			or type_id.contains("tannery") or type_id.contains("scriptorium"):
		return &"economy.building.workshop"
	if type_id.contains("plant") or type_id.contains("works") \
			or type_id.contains("mill") or type_id.contains("factory"):
		return &"economy.building.factory"
	if type_id.contains("school") or type_id.contains("hospital") \
			or type_id.contains("office"):
		return &"economy.building.service"
	return &"economy.building"



static func _owner_profession_name(host, snapshot: Dictionary, signature_idx: int) -> String:
	var h = host
	var signature_professions: PackedInt32Array = snapshot.get("signature_profession_ids", PackedInt32Array())
	return host._Construction_delegate._profession_name(host, snapshot, int(signature_professions[signature_idx]) if signature_idx >= 0 and signature_idx < signature_professions.size() else -1)



static func _profession_name(host, snapshot: Dictionary, profession_idx: int) -> String:
	var h = host
	var names: PackedStringArray = snapshot.get("profession_display_names", PackedStringArray())
	var ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
	if profession_idx >= 0 and profession_idx < names.size(): return String(names[profession_idx])
	return String(ids[profession_idx]) if profession_idx >= 0 and profession_idx < ids.size() else "未知阶层"



static func _format_input_candidate_label(host, good_id: String, efficiency_q16: int) -> String:
	var h = host
	var label = host._good_display_name(good_id)
	if efficiency_q16 != 65536:
		label += " %.0f%%" % (float(efficiency_q16) * 100.0 / 65536.0)
	return label



static func _good_display_name(host, stable_id: String) -> String:
	var h = host
	var profile = GoodProfileRegistry.profile_by_id(stable_id)
	return String(profile.display_name) if profile != null and String(profile.display_name) != "" else stable_id



static func _resource_display_name(host, stable_id: String) -> String:
	var h = host
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) == stable_id:
			return String(profile.display_name) if String(profile.display_name) != "" else stable_id
	return stable_id



static func _fill_percent(host, filled: int, required: int) -> float:
	var h = host
	return float(filled) * 100.0 / float(required) if required > 0 else 100.0



static func _actual_daily_rate(host, actual_total: int, building_count: int, period_days: int) -> String:
	var h = host
	var divisor = maxi(1, building_count) * maxi(1, period_days)
	return "%s 单位/栋/日" % UITokens.format_compact_number_cn(float(actual_total) / 1000.0 / float(divisor), 3)



static func _sum_i64(host, values: PackedInt64Array) -> int:
	var h = host
	var total = 0
	for value in values:
		total += int(value)
	return total



static func _money_text(host, subunits: int) -> String:
	var h = host
	if subunits != 0 and absi(subunits) < 100:
		return "%.4f" % (float(subunits) / h.MONEY_SCALE)
	return UITokens.format_compact_number_cn(float(subunits) / host.MONEY_SCALE, 2)



static func _goods_unit_text(host, subunits: int) -> String:
	var h = host
	return "%s 单位" % UITokens.format_compact_number_cn(float(maxi(0, subunits)) / 1000.0, 2)



static func _packed_i64_at(host, values: PackedInt64Array, index: int) -> int:
	var h = host
	return int(values[index]) if index >= 0 and index < values.size() else 0



static func _market_trade_enabled(host, enabled: PackedByteArray, index: int) -> bool:
	var h = host
	if enabled.is_empty() or index < 0 or index >= enabled.size():
		return true
	return enabled[index] != 0



static func _trade_arrival_days(host, next_arrival_day: int, sample_day: int) -> int:
	var h = host
	if next_arrival_day < 0:
		return -1
	return maxi(0, next_arrival_day - sample_day)



static func _market_trade_insight_text(host, in_transit_kinds: int, arrival_days: int) -> String:
	var h = host
	if arrival_days < 0:
		return "%d 种物资在途。" % in_transit_kinds
	if arrival_days == 0:
		return "%d 种物资在途，下一批今日到货。" % in_transit_kinds
	return "%d 种物资在途，下一批还有 %d 日到货。" % [in_transit_kinds, arrival_days]



static func _cashflow_source_name(host, source_id: String, income: bool) -> String:
	var h = host
	match source_id:
		"wages": return "工资"
		"owner_operations": return "业主经营"
		"merchant_household_sales": return "居民销售"
		"merchant_business_sales": return "产业供货"
		"transfer": return "转移支付"
		"household_consumption": return "生活消费"
		"production_inputs": return "生产原料"
		"owner_wages": return "雇员工资"
		"construction": return "建设"
		"merchant_procurement": return "商品收购"
		"producer_support_issuance": return "托底收购"
		"income_tax": return "所得税"
		"consumption_tax": return "交易税"
		"business_tax": return "营业税"
		"income_subsidy": return "收入补贴"
		"consumption_subsidy": return "消费补贴"
		"business_subsidy": return "经营补贴"
		"fiscal_escrow": return "财政托管"
		_: return "其他收入" if income else "其他支出"



static func _has_cashflow_row(host, rows: Array, source_id: String) -> bool:
	var h = host
	for row_value in rows:
		if row_value is Dictionary and String((row_value as Dictionary).get("id", "")) == \
			("income_" + source_id if String((row_value as Dictionary).get("id", "")).begins_with("income_") else "expense_" + source_id):
			return true
	return false
