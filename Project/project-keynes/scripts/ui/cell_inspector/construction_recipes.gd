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
	for index in range(ids.size()):
		rows.append({
			"name": h._construction_input_candidate_label(placement, index, unlocked_goods),
			"quantity": "%s/日" % h._goods_scaled(quantities[index]) \
				if index < quantities.size() else "—",
			"label": "原材料",
		})
	return rows


static func _construction_input_candidate_label(host, placement: Dictionary, input_idx: int,
		unlocked_goods: Dictionary) -> String:
	var h = host
	var ids: PackedStringArray = placement.get("input_good_ids", PackedStringArray())
	var fallback_id = String(ids[input_idx]) if input_idx >= 0 and input_idx < ids.size() else ""
	var offsets: PackedInt32Array = placement.get(
		"input_candidate_offsets", PackedInt32Array())
	var candidates: PackedStringArray = placement.get(
		"input_candidate_good_ids", PackedStringArray())
	var efficiencies: PackedInt32Array = placement.get(
		"input_candidate_efficiency_q16", PackedInt32Array())
	if input_idx < 0 or input_idx + 1 >= offsets.size():
		return host._format_input_candidate_label(fallback_id, 65536)
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
	if visible.is_empty():
		return host._format_input_candidate_label(fallback_id, 65536)
	visible.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var left_efficiency = int(a.efficiency)
		var right_efficiency = int(b.efficiency)
		if left_efficiency != right_efficiency:
			return left_efficiency < right_efficiency
		return String(a.id) < String(b.id))
	var labels = PackedStringArray()
	for entry in visible:
		if labels.size() >= 3:
			break
		labels.append(host._format_input_candidate_label(
			String(entry.id), int(entry.efficiency)))
	var text = " / ".join(labels)
	if visible.size() > labels.size():
		text += " 等 %d 种" % visible.size()
	return text


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


static func _append_recipe_rows(host, rows: Array, snapshot: Dictionary, type_idx: int, kind: String,
		actual_total: int, building_count: int, period_days: int, group_idx: int = -1) -> void:
	var h = host
	var offsets: PackedInt32Array = snapshot.get("building_%s_offsets" % kind, PackedInt32Array())
	var good_indices: PackedInt32Array = snapshot.get("building_%s_good_ids" % kind, PackedInt32Array())
	var quantities: PackedInt64Array = snapshot.get("building_%s_quantities" % kind, PackedInt64Array())
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
		var good_label = host._input_candidate_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else h._good_display_name(stable_id)
		var short_good = host._selected_input_short_label(
			snapshot, cursor, cursor - begin, group_idx, stable_id) \
			if kind == "input" else h._good_display_name(stable_id)
		rows.append({
			"id": "%s_%d" % [kind, cursor],
			"name": "%s · %s" % ["原材料" if kind == "input" else "产出", good_label],
			"short_name": "%s · %s" % ["投入" if kind == "input" else "产出", short_good],
			"candidates_detail": good_label if kind == "input" else "",
			"daily_per_building_float": float(actual) / 1000.0 / float(divisor),
			"value": h._actual_daily_rate(actual, building_count, period_days),
			"icon": "resource",
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
		labels.append(host._format_input_candidate_label(String(good_ids[good_idx]), efficiency))
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
		var availability = "不足" if h._building_resource_depleted(snapshot, type_idx) else "充足"
		var row_value = "每栋 %.3f · %s" % [float(quantity) / 1000.0, availability] if mode == 1 \
			else "%s · %s" % [h._actual_daily_rate(actual, building_count, period_days), availability]
		rows.append({"id": "natural_input_%d" % cursor,
			"name": row_name,
			"value": row_value,
			"icon": "eco", "accent": UITokens.ECO})


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
			"value": "%s · 待资源周期生效" % h._actual_daily_rate(actual, building_count, period_days),
			"icon": "growth", "accent": UITokens.GOOD})
