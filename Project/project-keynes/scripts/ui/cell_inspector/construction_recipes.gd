extends RefCounted

static func _construction_recipe_side(host, rows: Array) -> String:
	var h = host
	if rows.is_empty():
		return ""
	var parts = PackedStringArray()
	for raw in rows:
		var row: Dictionary = raw
		parts.append("%s %s" % [String(row.get("name", "")),
			String(row.get("quantity", ""))])
	return "、".join(parts)


static func _goods_scaled(host, value: int) -> String:
	var h = host
	return UITokens.format_compact_number_cn(float(value) / 1000.0, 3)


static func _construction_recipe_rows(host, placement: Dictionary, ids_key: String,
		quantities_key: String, label: String) -> Array:
	var h = host
	var rows: Array = []
	var ids: PackedStringArray = placement.get(ids_key, PackedStringArray())
	var quantities: PackedInt64Array = placement.get(quantities_key, PackedInt64Array())
	for index in range(ids.size()):
		var good_id = String(ids[index])
		rows.append({"name": h._good_display_name(good_id),
			"quantity": "%s/日" % h._goods_scaled(quantities[index]) \
				if index < quantities.size() else "—",
			"label": label})
	return rows


static func _construction_input_recipe_rows(host, placement: Dictionary,
		unlocked_goods: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var quantities: PackedInt64Array = placement.get("input_quantities", PackedInt64Array())
	var required: PackedInt32Array = placement.get("input_required_q16", PackedInt32Array())
	for index in range(ids.size()):
		rows.append({
			"name": h._construction_input_candidate_label(placement, index, unlocked_goods),
			"quantity": "%s/日" % h._goods_scaled(quantities[index]) \
				if index < quantities.size() else "—",
			"label": "原材料",
			"optional": index < required.size() and required[index] > 0 and required[index] < 65536,
		})
	return rows


static func _construction_input_candidate_label(host, placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> String:
	var h = host
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var fallback_id = String(ids[input_idx]) if input_idx >= 0 and input_idx < ids.size() else ""
	var visible := construction_input_candidates(placement, input_idx, unlocked_goods)
	if visible.is_empty():
		return host._format_input_candidate_label(fallback_id, 65536)
	var labels = PackedStringArray()
	for entry in visible.slice(0, 3):
		labels.append(host._format_input_candidate_label(
			String(entry.id), int(entry.efficiency)))
	var text = " / ".join(labels)
	if visible.size() > labels.size():
		text += " 等 %d 种" % visible.size()
	return text


static func construction_input_candidates(placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> Array[Dictionary]:
	var offsets: PackedInt32Array = placement.get(
		"input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = placement.get(
		"input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = placement.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return []
	var entries: Array[Dictionary] = []
	for candidate_idx in range(int(offsets[input_idx]), int(offsets[input_idx + 1])):
		if candidate_idx < 0 or candidate_idx >= candidates.size():
			continue
		entries.append({
			"id": String(candidates[candidate_idx]),
			"efficiency": int(efficiencies[candidate_idx]) \
				if candidate_idx < efficiencies.size() else 65536,
		})
	var enforce = not unlocked_goods.is_empty()
	var visible: Array[Dictionary] = []
	for entry in entries:
		if not enforce or bool(unlocked_goods.get(String(entry.id), false)):
			visible.append(entry)
	if visible.is_empty():
		visible = entries
	visible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left_efficiency = int(a.efficiency)
		var right_efficiency = int(b.efficiency)
		if left_efficiency != right_efficiency:
			return left_efficiency < right_efficiency
		return String(a.id) < String(b.id))
	return visible


static func _unlocked_good_ids(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var available: PackedByteArray = snapshot.get(
		"good_technology_available", PackedByteArray())
	var unlocked = {}
	if ids.is_empty() or available.size() != ids.size():
		return unlocked
	for index in range(ids.size()):
		if available[index] != 0:
			unlocked[String(ids[index])] = true
	return unlocked


static func _construction_profession_name(host, profession_id: String) -> String:
	var h = host
	if h._generator != null and h._generator.has_method("get_economy_facade"):
		var facade = host._generator.get_economy_facade()
		if facade != null and facade.has_method("profession_display_name"):
			return String(facade.profession_display_name(StringName(profession_id)))
	return profession_id


static func construction_requirements(host, snapshot: Dictionary, type_idx: int) -> Array:
	var offsets: PackedInt32Array = snapshot.get("building_construction_offsets", PackedInt32Array())
	var indices: PackedInt32Array = snapshot.get("building_construction_good_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_construction_quantities", PackedInt64Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var rows: Array = []
	if type_idx < 0 or type_idx + 1 >= offsets.size():
		return rows
	var totals := {}
	for edge in range(offsets[type_idx], mini(offsets[type_idx + 1],
			mini(indices.size(), quantities.size()))):
		var good_idx := indices[edge]
		if good_idx >= 0 and good_idx < good_ids.size() and quantities[edge] > 0:
			totals[good_idx] = int(totals.get(good_idx, 0)) + quantities[edge]
	for good_idx in totals:
		var good_id := good_ids[good_idx]
		rows.append({
			"name": host._good_display_name(good_id),
			"icon": IconCatalog.good_semantic(good_id),
			"text": "%s 单位" % host._goods_scaled(totals[good_idx]),
		})
	return rows


static func _append_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int, kind: String,
		actual_total: int, building_count: int, period_days: int, group_idx: int = -1) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_%s_offsets" % kind, PackedInt32Array())
	var good_indices: PackedInt32Array = snapshot.get("building_%s_good_ids" % kind, PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_%s_quantities" % kind, PackedInt64Array())
	var required: PackedInt32Array = snapshot.get("building_input_required_q16", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size():
		return
	var begin = int(offsets[type_idx])
	var end = int(offsets[type_idx + 1])
	var recipe_total = 0
	for cursor in range(begin, end):
		recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	var divisor = maxi(1, building_count) * maxi(1, period_days)
	for cursor in range(begin, end):
		var good_idx = int(good_indices[cursor]) if cursor < good_indices.size() else -1
		var stable_id = String(good_ids[good_idx]) if good_idx >= 0 and good_idx < good_ids.size() else "unknown"
		var quantity = int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual = int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var good_label = host._Construction_delegate._input_candidate_label(host,
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else h._good_display_name(stable_id)
		var short_good = host._Construction_delegate._selected_input_short_label(host,
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else h._good_display_name(stable_id)
		rows.append({
			"id": "%s_%d" % [kind, cursor],
			"name": "%s · %s" % ["原材料" if kind == "input" else "产出", good_label],
			"short_name": "%s · %s" % ["投入" if kind == "input" else "产出", short_good],
			"candidates_detail": good_label if kind == "input" else "",
			"optional_input": kind == "input" and cursor < required.size()
				and required[cursor] > 0 and required[cursor] < 65536,
			"daily_per_building_float": float(actual) / 1000.0 / float(divisor),
			"value": h._Construction_delegate._actual_daily_rate(h, actual, building_count, period_days),
			"detail": "基础产量 %s 单位/栋/日" % h._goods_scaled(quantity) if kind == "output" and quantity > 0 else "",
			"icon": IconCatalog.good_semantic(stable_id),
			"accent": UITokens.RESOURCE,
		})


static func _selected_input_short_label(host, snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	var h = host
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var selected_offsets: PackedInt32Array = snapshot.get(
		"group_input_selected_offsets", PackedInt32Array())
	var selected_goods: PackedInt32Array = snapshot.get(
		"group_input_selected_good_ids", PackedInt32Array())
	if group_idx >= 0 and group_idx + 1 < selected_offsets.size():
		var selected_idx = int(selected_offsets[group_idx]) + local_input_idx
		if selected_idx >= int(selected_offsets[group_idx]) \
				and selected_idx < int(selected_offsets[group_idx + 1]) \
				and selected_idx < selected_goods.size():
			var selected_good = int(selected_goods[selected_idx])
			if selected_good >= 0 and selected_good < good_ids.size():
				return host._good_display_name(String(good_ids[selected_good]))
	var offsets: PackedInt32Array = snapshot.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidates: PackedInt32Array = snapshot.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	if input_idx >= 0 and input_idx + 1 < offsets.size():
		var first_idx = int(offsets[input_idx])
		var count_cand = int(offsets[input_idx + 1]) - first_idx
		if count_cand > 0 and first_idx >= 0 and first_idx < candidates.size():
			var good_idx = int(candidates[first_idx])
			if good_idx >= 0 and good_idx < good_ids.size():
				var base_name = host._good_display_name(String(good_ids[good_idx]))
				return "%s等" % base_name if count_cand > 1 else base_name
	return host._good_display_name(fallback_id)


static func _input_candidate_label(host, snapshot: Dictionary, input_idx: int, local_input_idx: int,
		group_idx: int, fallback_id: String) -> String:
	var h = host
	var offsets: PackedInt32Array = snapshot.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidates: PackedInt32Array = snapshot.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var efficiencies: PackedInt32Array = snapshot.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return host._good_display_name(fallback_id)
	var labels = PackedStringArray()
	for candidate_idx in range(offsets[input_idx], offsets[input_idx + 1]):
		var good_idx = int(candidates[candidate_idx]) if candidate_idx < candidates.size() else -1
		if good_idx < 0 or good_idx >= good_ids.size():
			continue
		var efficiency = int(efficiencies[candidate_idx]) if candidate_idx < efficiencies.size() else 65536
		labels.append(host._Construction_delegate._format_input_candidate_label(host, String(good_ids[good_idx]), efficiency))
	var candidate_label = " / ".join(labels) \
		if not labels.is_empty() else host._good_display_name(fallback_id)
	var selected_offsets: PackedInt32Array = snapshot.get(
		"group_input_selected_offsets", PackedInt32Array())
	var selected_goods: PackedInt32Array = snapshot.get(
		"group_input_selected_good_ids", PackedInt32Array())
	if group_idx >= 0 and group_idx + 1 < selected_offsets.size():
		var selected_idx = int(selected_offsets[group_idx]) + local_input_idx
		if selected_idx >= int(selected_offsets[group_idx]) \
				and selected_idx < int(selected_offsets[group_idx + 1]) \
				and selected_idx < selected_goods.size():
			var selected_good = int(selected_goods[selected_idx])
			if selected_good >= 0 and selected_good < good_ids.size():
				candidate_label += "（当前：%s）" % h._good_display_name(String(good_ids[selected_good]))
	return candidate_label


static func _append_resource_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_resource_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_production_resource_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = snapshot.get("building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = snapshot.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var local_reserve: PackedInt64Array = snapshot.get(
		"building_resource_effective_reserve", PackedInt64Array())
	var nearby_reserve: PackedInt64Array = snapshot.get(
		"building_resource_accessible_effective_reserve", PackedInt64Array())
	var resource_ids: PackedStringArray = snapshot.get("building_resource_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size(): return
	var begin = int(offsets[type_idx])
	var end = int(offsets[type_idx + 1])
	var recipe_total = 0
	for cursor in range(begin, end): recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var resource_idx = int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var stable_id = String(resource_ids[resource_idx]) if resource_idx >= 0 and resource_idx < resource_ids.size() else "unknown"
		var quantity = int(quantities[cursor]) if cursor < quantities.size() else 0
		var mode = int(modes[cursor]) if cursor < modes.size() else 0
		var access_mode = int(access_modes[cursor]) if cursor < access_modes.size() else 0
		var actual = int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		var access_label = "邻域 · " if access_mode == 1 else ""
		var row_name = "自然资源 · %s%s" % [access_label, h._resource_display_name(stable_id)]
		var row_value = "需 %s 单位/栋" % h._goods_scaled(quantity) if mode == 1 \
			else h._Construction_delegate._actual_daily_rate(h, actual, building_count, period_days)
		var resource_name: String = h._resource_display_name(stable_id)
		var short_name := "%s%s %s" % [access_label, "承载" if mode == 1 else "开采", resource_name]
		var reserve := nearby_reserve if access_mode == 1 else local_reserve
		var detail := ""
		if mode == 0 and resource_idx >= 0 and resource_idx < reserve.size():
			detail = "当前可采 %s 单位" % h._goods_scaled(reserve[resource_idx])
		rows.append({"id": "natural_input_%d" % cursor,
			"name": row_name,
			"short_name": short_name,
			"value": row_value,
			"detail": detail,
			"icon": IconCatalog.resource_semantic(stable_id),
			"accent": UITokens.ECO})


static func _append_resource_generation_rows(host, rows: Array, snapshot: Dictionary, type_idx: int,
		actual_total: int, building_count: int, period_days: int) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_resource_generation_offsets", PackedInt32Array())
	var resource_indices: PackedInt32Array = snapshot.get("building_resource_generation_ids", PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_resource_generation_quantities", PackedInt64Array())
	var resource_ids: PackedStringArray = snapshot.get("building_resource_ids", PackedStringArray())
	if type_idx < 0 or type_idx + 1 >= offsets.size(): return
	var begin = int(offsets[type_idx])
	var end = int(offsets[type_idx + 1])
	var recipe_total = 0
	for cursor in range(begin, end): recipe_total += int(quantities[cursor]) if cursor < quantities.size() else 0
	for cursor in range(begin, end):
		var resource_idx = int(resource_indices[cursor]) if cursor < resource_indices.size() else -1
		var stable_id = String(resource_ids[resource_idx]) if resource_idx >= 0 and resource_idx < resource_ids.size() else "unknown"
		var quantity = int(quantities[cursor]) if cursor < quantities.size() else 0
		var actual = int(float(actual_total) * float(quantity) / float(recipe_total)) if recipe_total > 0 else 0
		rows.append({"id": "natural_generation_%d" % cursor,
			"name": "培育 · %s" % h._resource_display_name(stable_id),
			"value": "%s · 待资源到位" % h._Construction_delegate._actual_daily_rate(h, actual, building_count, period_days),
			"icon": IconCatalog.resource_semantic(stable_id),
			"accent": UITokens.GOOD})


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
	var signature_professions: PackedInt32Array = snapshot.get("signature_profession_ids", PackedInt32Array())
	var profession_ids: PackedStringArray = snapshot.get("profession_stable_ids", PackedStringArray())
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
	var last_maintenance_cost: PackedInt64Array = snapshot.get("last_maintenance_cost", PackedInt64Array())
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
	var bld_sample_day = int(snapshot.get("sample_day", h._Geography_delegate._current_sample_day(h)))
	if cell_idx >= 0:
		host._PopulationMarket_delegate._ensure_detail_history_cell(host, cell_idx)
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
		var maintenance = int(last_maintenance_cost[i]) if i < last_maintenance_cost.size() else 0
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
		var signature := owner_signatures[i] if i < owner_signatures.size() else -1
		var owner_profession := signature_professions[signature] \
			if signature >= 0 and signature < signature_professions.size() else -1
		var owner_icon := IconCatalog.profession_semantic(profession_ids[owner_profession]) \
			if owner_profession >= 0 and owner_profession < profession_ids.size() else &"family.metric.wealth"
		var job_rows = [
			{"id": "owner_job", "name": "业主 · %s" % h._Construction_delegate._owner_profession_name(h, snapshot, signature), "icon": owner_icon,
				"value": owner_job_value, "ratio": float(owner_actual) / float(owner_required) if owner_required > 0 else 0.0},
		]
		if role_offsets.size() == group_types.size() + 1:
			for role in range(role_offsets[i], role_offsets[i + 1]):
				var required = int(role_required[role]) if role < role_required.size() else 0
				var filled = int(role_filled[role]) if role < role_filled.size() else 0
				var role_value = "%d / %d" % [filled, required]
				if required == 0 and (is_loss_suspended or not is_available):
					role_value += "（岗位已释放）"
				var profession := role_professions[role] if role < role_professions.size() else -1
				job_rows.append({
					"id": "job_%d" % role,
					"name": "雇员 · %s" % h._Construction_delegate._profession_name(h, snapshot, profession),
					"icon": IconCatalog.profession_semantic(profession_ids[profession]) \
						if profession >= 0 and profession < profession_ids.size() else &"population.profession.worker",
					"value": role_value,
					"ratio": float(filled) / float(required) if required > 0 else 0.0,
				})
		var production_rows = []
		h._Construction_delegate._append_recipe_rows(h, production_rows, snapshot, type_idx, "input",
			int(last_input[i]) if i < last_input.size() else 0, count, period_days, i)
		host._Construction_delegate._append_resource_generation_rows(host, production_rows, snapshot, type_idx,
			int(last_resource_generated[i]) if i < last_resource_generated.size() else 0,
			count, period_days)
		host._Construction_delegate._append_resource_recipe_rows(host, production_rows, snapshot, type_idx,
			int(last_resource[i]) if i < last_resource.size() else 0, count, period_days)
		var resource_net = (int(last_resource_generated[i]) if i < last_resource_generated.size() else 0) \
			- (int(last_resource[i]) if i < last_resource.size() else 0)
		if resource_net != 0:
			production_rows.append({"id": "resource_net", "name": "自然资源净额",
				"value": h._Construction_delegate._actual_daily_rate(h, resource_net, count, period_days),
				"icon": "eco", "accent": UITokens.GOOD if resource_net > 0 else UITokens.WARN})
		var output_row_begin = production_rows.size()
		h._Construction_delegate._append_recipe_rows(h, production_rows, snapshot, type_idx, "output",
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
				climate_lost_daily_text = host._Construction_delegate._actual_daily_rate(host, lost_output, count, period_days)
				production_rows.append({"id": "climate_lost_output", "name": "气候减产",
					"value": climate_lost_daily_text,
					"icon": "warning", "accent": UITokens.WARN})
		var finance_breakdown = "现金 %s · 自用折算 %s · 原料 %s · 工资成本 %s · 维护 %s · 营业税 %s" % [
			host._money_text(revenue), host._money_text(in_kind_income), host._money_text(input_cost),
			host._money_text(wages_due), host._money_text(maintenance), host._money_text(business_tax)]
		if business_subsidy > 0:
			finance_breakdown += " · 经营补贴 %s" % h._money_text(business_subsidy)
		var finance = {
			"revenue": h._money_text(revenue + in_kind_income),
			"revenue_float": float(revenue + in_kind_income) / 10000.0,
			"gross_revenue_text": h._money_text(revenue + in_kind_income + maxi(0, business_tax)),
			"gross_revenue_float": float(revenue + in_kind_income + maxi(0, business_tax)) / 10000.0,
			"cash_revenue_float": float(revenue) / 10000.0,
			"cash_revenue_text": h._money_text(revenue),
			"gross_cash_revenue_text": h._money_text(revenue + maxi(0, business_tax)),
			"in_kind_float": float(in_kind_income) / 10000.0,
			"in_kind_text": h._money_text(in_kind_income),
			"subsidy_float": float(business_subsidy) / 10000.0,
			"subsidy_text": h._money_text(business_subsidy),
			"cost": h._money_text(operating_cost),
			"cost_float": float(operating_cost) / 10000.0,
			"total_cost_with_tax_text": h._money_text(operating_cost + maxi(0, business_tax)),
			"total_cost_with_tax_float": float(operating_cost + maxi(0, business_tax)) / 10000.0,
			"input_cost_float": float(input_cost) / 10000.0,
			"input_cost_text": h._money_text(input_cost),
			"wages_paid_float": float(wages) / 10000.0,
			"wages_paid_text": h._money_text(wages),
			"wages_cost_float": float(wages_due) / 10000.0,
			"wages_cost_text": h._money_text(wages_due),
			"maintenance_float": float(maintenance) / 10000.0,
			"maintenance_text": h._money_text(maintenance),
			"business_tax_float": float(business_tax) / 10000.0,
			"business_tax_text": h._money_text(business_tax),
			"profit": "%s%s" % ["+" if profit > 0 else "", h._money_text(profit)],
			"profit_float": float(profit) / 10000.0,
			"profit_loss_text": h._money_text(absi(profit)),
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
				and host._Construction_delegate._building_resource_depleted(host, snapshot, type_idx):
			state_label = "资源短缺"
			state_detail = "本地资源不足，无法生产。"
			state_accent = UITokens.WARN
			show_state_summary = true
		else:
			var status_parts: Array[String] = ["到岗 %d/%d" % [staffing_actual, staffing_required]]
			if owner_open > 0:
				status_parts.append("缺业主 %d" % owner_open)
			status_parts.append("开工 %.0f%%" % actual_percent)
			if has_outputs and planned_percent < 99.5:
				status_parts.append("计划 %.0f%%" % planned_percent)
			state_label = " · ".join(status_parts)
		var pending_state = int(pending_operating_states[i]) \
			if i < pending_operating_states.size() else 255
		if pending_state == 0 and operating_state != 0:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期恢复正常经营"
		elif pending_state == 1 and operating_state != 1:
			state_meta += (" · " if not state_meta.is_empty() else "") + "下期转入亏损停产"
		# 方向由数值符号与颜色表达，标签只说明这是什么数。
		var headline_profit_label = "净额"
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
			host._PopulationMarket_delegate._record_building_history(host, bld_hist_key, float(profit) / 10000.0,
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
			"owner": "业主 · %s" % h._Construction_delegate._owner_profession_name(h, snapshot, int(owner_signatures[i]) if i < owner_signatures.size() else -1),
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
			"profit_delta": CellInspectorViewModel._PopulationMarket._series_lookback_delta(profit_series),
			"utilization_spark": util_series,
			"utilization_delta": CellInspectorViewModel._PopulationMarket._series_lookback_delta(util_series),
			"accent": state_accent if show_state_summary else (UITokens.GOOD if profit > 0 else (UITokens.RISK if profit < 0 else UITokens.TEXT_MUTED)),
			"icon": h._building_icon(building_id, snapshot, type_idx), "job_rows": job_rows,
			"production_rows": production_rows, "finance": finance, "visible": true,
			"construction_requirements": construction_requirements(host, snapshot, type_idx),
		})
		total_profit += profit
		if show_state_summary:
			halted_groups += 1
	host._Construction_delegate._append_construction_rows(host, rows, snapshot, type_ids, type_names)
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
