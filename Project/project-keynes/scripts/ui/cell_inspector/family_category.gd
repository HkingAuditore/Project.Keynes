extends RefCounted

## Builds detailed family rows from the selected cell's published snapshot.

const FamilyWorkspaceProjection = preload("res://scripts/ui/family_workspace_projection.gd")


static func _family_category(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	if host._snapshot_pending(snapshot):
		return host._pending_category()
	if snapshot.is_empty() or not bool(snapshot.get("ok", false)):
		return {"insights": [{"id": "families_unavailable", "text":
			"家族情报：无", "accent": UITokens.TEXT_MUTED,
			"icon": "family.house"}]}
	var handles: PackedInt64Array = snapshot.get("family_handles", PackedInt64Array())
	var surnames: PackedStringArray = snapshot.get("surnames", PackedStringArray())
	var family_names: PackedStringArray = snapshot.get(
		"family_names", PackedStringArray())
	var disambiguators: PackedInt32Array = snapshot.get(
		"surname_disambiguators", PackedInt32Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var cash_claims: PackedInt64Array = snapshot.get("cash_claims", PackedInt64Array())
	var owned: PackedInt64Array = snapshot.get("owned_buildings", PackedInt64Array())
	var notable_people: PackedInt32Array = snapshot.get(
		"notable_person_counts", PackedInt32Array())
	var prestige_levels: PackedInt32Array = snapshot.get(
		"prestige_levels", PackedInt32Array())
	var rows: Array = []
	var source_cell = int(snapshot.get("cell_idx", -1))
	var country = host._Overview_delegate._country_summary(host, source_cell) if source_cell >= 0 else {}
	var player_owned = bool(country.get("owned", false)) \
		and int(country.get("country_handle", 0)) == h._player_country_handle()
	for i in range(surnames.size()):
		var suffix = "" if i >= disambiguators.size() or disambiguators[i] == 0 \
			else "（%d）" % (int(disambiguators[i]) + 1)
		var family_handle = int(handles[i]) if i < handles.size() else 0
		var display_name = String(family_names[i]).strip_edges() \
			if i < family_names.size() else ""
		if display_name.is_empty():
			display_name = "%s氏" % String(surnames[i])
		rows.append({
			"id": "family_%d" % family_handle,
			"family_handle": family_handle,
			"source_cell": source_cell,
			"can_dispatch": player_owned and i < populations.size() and populations[i] > 1,
			"name": "%s%s" % [display_name, suffix],
			"population": UITokens.format_compact_number_cn(float(populations[i]), 1) if i < populations.size() else "0",
			"notable_people": int(notable_people[i]) if i < notable_people.size() else 0,
			"owned_buildings": UITokens.format_compact_number_cn(float(owned[i]), 1) if i < owned.size() else "0",
			"cash_claim": h._money_text(int(cash_claims[i])) if i < cash_claims.size() else h._money_text(0),
			"prestige": h._prestige_text(int(prestige_levels[i])) \
				if i < prestige_levels.size() else "0",
			"accent": UITokens.ACCENT,
			"icon": "family.house",
		})
	if rows.is_empty():
		return {"insights": [{"id": "families_empty", "text":
			"显赫家族：无",
			"accent": UITokens.TEXT_MUTED, "icon": "family.house"}]}
	if rows.is_empty():
		return {"insights": [{"id": "families_empty", "text": "显赫家族：无",
			"accent": UITokens.TEXT_MUTED, "icon": "family.house"}], "family_rows": rows}
	return {"family_rows": rows, "list_header": {"lead": "家族 · 族人 · 产业",
		"indent": 41.0, "columns": [{"text": "威望", "width": 64.0}]}}



static func _family_detail_fields(host, snapshot: Dictionary) -> Dictionary:
	var h = host
	return {
		"population": UITokens.format_compact_number_cn(float(snapshot.get("population", 0)), 1),
		"cash_claim": h._money_text(int(snapshot.get("cash_claim", 0))),
		"productive_asset_value": h._money_text(int(snapshot.get("building_asset_value",
			snapshot.get("productive_asset_value", 0)))),
		"net_worth": h._money_text(int(snapshot.get("net_worth", 0))),
		"owned_buildings": UITokens.format_compact_number_cn(float(snapshot.get("owned_buildings", 0)), 1),
		"notable_people": int(snapshot.get("notable_person_count", 0)),
		"founded_day": int(snapshot.get("founded_day", 0)),
		"decline_reviews": int(snapshot.get("decline_reviews", 0)),
		"origin_cell": int(snapshot.get("origin_cell", -1)),
		"origin_settlement_name": String(snapshot.get("origin_settlement_name", "")),
	}



static func _family_trait_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var names: PackedStringArray = snapshot.get("display_names", PackedStringArray())
	var keys: PackedStringArray = snapshot.get("trait_keys", PackedStringArray())
	var core: PackedByteArray = snapshot.get("core", PackedByteArray())
	var descriptions: PackedStringArray = snapshot.get("descriptions", PackedStringArray())
	var effect_names: PackedStringArray = snapshot.get("effect_display_names", PackedStringArray())
	for index in range(keys.size()):
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var is_core = index < core.size() and int(core[index]) != 0
		rows.append({
			"id": String(keys[index]),
			"key": String(keys[index]),
			"name": String(names[index]) if index < names.size() else String(keys[index]),
			"core": is_core,
			"kind": "core" if is_core else "additional",
			"kind_label": "核心特性" if is_core else "附加特性",
			"value": "核心特性" if is_core else "附加特性",
			"detail": detail,
			"badges": FamilyBuffCopy.extract_trait_badges(detail),
			"effect_names": effect_names,
			# 当前 facade 只提供一份说明文本；不要把它伪装成第二份效果摘要。
			"effect_summary": "",
			"tooltip": detail,
		})
	return rows



static func _family_behavior_rows(host, snapshot: Dictionary, cell_idx: int = -1) -> Array:
	var h = host
	var visibility = host._family_behavior_visibility(cell_idx)
	return CellInspectorViewModel._Overview._family_behavior_rows_for_visibility(snapshot, visibility)



static func family_behavior_rows_for_cell(snapshot: Dictionary, facade,
		cell_idx: int) -> Array:
	var visibility = _family_behavior_visibility_for_cell(facade, cell_idx)
	# 派遣快照未就绪时不泄露整张目录；只显示已确认可见的选择器。
	for axis in ["buildings", "goods", "professions", "needs"]:
		visibility["enforce_" + axis] = true
	return _family_behavior_rows_for_visibility(snapshot, visibility)



static func _family_behavior_rows_for_visibility(snapshot: Dictionary,
		visibility: Dictionary) -> Array:
	var rows: Array = []
	var axes: PackedInt32Array = snapshot.get("behavior_axes", PackedInt32Array())
	var stable_ids: PackedStringArray = snapshot.get(
		"behavior_selector_stable_ids", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"behavior_selector_display_names", PackedStringArray())
	var factors: PackedInt32Array = snapshot.get(
		"behavior_factors_q16", PackedInt32Array())
	var axis_names = ["投资", "职业", "需求", "商品消费"]
	for index in range(axes.size()):
		var axis = int(axes[index])
		var stable_id = String(stable_ids[index]) if index < stable_ids.size() else ""
		if not _family_behavior_selector_visible(axis, stable_id, visibility):
			continue
		var factor_q16 = int(factors[index]) if index < factors.size() else 65536
		var factor_percent = float(factor_q16) * 100.0 / 65536.0
		var axis_name: String = axis_names[axis] if axis >= 0 \
			and axis < axis_names.size() else "行为"
		var display_name = String(names[index]) if index < names.size() else "目标 %d" % index
		var signed_delta = factor_percent - 100.0
		rows.append({
			"id": "%d:%s" % [axis, stable_id],
			"stable_id": stable_id,
			"axis": axis,
			"axis_name": axis_name,
			"name": display_name,
			"icon": String(_family_behavior_icon(axis, stable_id, display_name)),
			"factor_q16": factor_q16,
			"factor_percent": factor_percent,
			"factor_text": _q16_percent_text(factor_q16),
			"signed_delta_percent": signed_delta,
			"delta_text": "%s%.0f%%" % [
				"+" if signed_delta >= 0.0 else "−", absf(signed_delta)],
			"bar_ratio": clampf(factor_percent / 200.0, 0.0, 1.0),
			"deviation": absf(factor_percent - 100.0),
			"value": "%s偏好 · %s" % [axis_name, _q16_percent_text(factor_q16)],
		})
	return rows



static func _family_behavior_icon(axis: int, stable_id: String, name_text: String = "") -> StringName:
	return FamilyWorkspaceProjection._family_behavior_icon(axis, stable_id, name_text)



static func _family_behavior_visibility(host, cell_idx: int) -> Dictionary:
	var h = host
	var facade = host._generator.get_economy_facade() if host._generator != null \
		and h._generator.has_method("get_economy_facade") else null
	return CellInspectorViewModel._Overview._family_behavior_visibility_for_cell(facade, cell_idx)



static func _family_behavior_visibility_for_cell(facade, cell_idx: int) -> Dictionary:
	var result = {"buildings": {}, "goods": {}, "professions": {}, "needs": {},
		"enforce_buildings": false, "enforce_goods": false,
		"enforce_professions": false, "enforce_needs": false}
	if cell_idx < 0:
		return result
	if facade == null:
		return result
	var buildings: Dictionary = facade.building_cell_snapshot(cell_idx) \
		if facade.has_method("building_cell_snapshot") else {}
	var building_ids: PackedStringArray = buildings.get(
		"building_type_ids", PackedStringArray())
	var building_available: PackedByteArray = buildings.get(
		"building_technology_available", PackedByteArray())
	if building_available.size() == building_ids.size():
		result.enforce_buildings = true
		for index in range(building_ids.size()):
			if building_available[index] != 0:
				result.buildings[String(building_ids[index])] = true
	var market: Dictionary = facade.market_cell_snapshot(cell_idx) \
		if facade.has_method("market_cell_snapshot") else {}
	var good_ids: PackedStringArray = market.get("good_ids", PackedStringArray())
	var good_available: PackedByteArray = market.get(
		"good_technology_available", PackedByteArray())
	if good_available.size() == good_ids.size():
		result.enforce_goods = true
		for index in range(good_ids.size()):
			if good_available[index] != 0:
				result.goods[String(good_ids[index])] = true
		var catalog: Dictionary = facade.native_catalog() \
			if facade.has_method("native_catalog") else {}
		var need_visibility = _family_behavior_visible_needs(
			catalog, good_ids, good_available)
		if bool(need_visibility.get("ok", false)):
			result.needs = need_visibility.get("needs", {})
			result.enforce_needs = true
	var population: Dictionary = facade.population_cell_snapshot(cell_idx) \
		if facade.has_method("population_cell_snapshot") else {}
	result.professions = _family_behavior_visible_professions(buildings, population)
	result.enforce_professions = not (result.professions as Dictionary).is_empty()
	return result



static func _family_behavior_visible_professions(buildings: Dictionary,
		population: Dictionary) -> Dictionary:
	var catalog: PackedStringArray = population.get(
		"profession_stable_ids", PackedStringArray())
	if catalog.is_empty():
		catalog = buildings.get("profession_stable_ids", PackedStringArray())
	var hired = {}
	var type_ids: PackedStringArray = buildings.get(
		"building_type_ids", PackedStringArray())
	var type_available: PackedByteArray = buildings.get(
		"building_technology_available", PackedByteArray())
	var type_constructible: PackedByteArray = buildings.get(
		"building_construction_available", PackedByteArray())
	var type_counts: PackedInt64Array = buildings.get(
		"building_counts_by_type", PackedInt64Array())
	var owners: PackedInt32Array = buildings.get(
		"building_owner_profession_ids", PackedInt32Array())
	var employee_offsets: PackedInt32Array = buildings.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = buildings.get(
		"building_employee_profession_ids", PackedInt32Array())
	var can_resolve_roles = not catalog.is_empty() \
		and owners.size() == type_ids.size() \
		and employee_offsets.size() == type_ids.size() + 1
	if can_resolve_roles:
		for type_index in range(type_ids.size()):
			var present = type_index < type_counts.size() \
				and int(type_counts[type_index]) > 0
			var unlocked = type_index < type_available.size() \
				and int(type_available[type_index]) != 0
			var constructible = type_index < type_constructible.size() \
				and int(type_constructible[type_index]) != 0
			if not present and not unlocked and not constructible:
				continue
			_add_profession_id(hired, catalog, int(owners[type_index]))
			var begin = int(employee_offsets[type_index])
			var end = int(employee_offsets[type_index + 1])
			for role in range(begin, end):
				if role >= 0 and role < employee_professions.size():
					_add_profession_id(hired, catalog, int(employee_professions[role]))
		hired["unemployed"] = true
		var row_professions: PackedInt32Array = population.get(
			"profession_ids", PackedInt32Array())
		for dense_id in row_professions:
			_add_profession_id(hired, catalog, int(dense_id))
	var available: PackedByteArray = population.get(
		"profession_technology_available", PackedByteArray())
	if available.size() == catalog.size() and not catalog.is_empty():
		if hired.is_empty() and not can_resolve_roles:
			for index in range(catalog.size()):
				if int(available[index]) != 0:
					hired[String(catalog[index])] = true
			return hired
		var filtered = {}
		for profession_id in hired.keys():
			var index = catalog.find(String(profession_id))
			if index >= 0 and int(available[index]) == 0:
				continue
			filtered[String(profession_id)] = true
		return filtered
	return hired



static func _add_profession_id(target: Dictionary, catalog: PackedStringArray,
		dense_id: int) -> void:
	if dense_id < 0 or dense_id >= catalog.size():
		return
	target[String(catalog[dense_id])] = true



static func _family_behavior_visible_needs(catalog: Dictionary,
		market_good_ids: PackedStringArray,
		good_available: PackedByteArray) -> Dictionary:
	var need_ids: PackedStringArray = catalog.get("need_ids", PackedStringArray())
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var need_entries: PackedInt32Array = catalog.get(
		"need_stable_ids", PackedInt32Array())
	var need_variant_offsets: PackedInt32Array = catalog.get(
		"need_variant_offsets", PackedInt32Array())
	var variant_component_offsets: PackedInt32Array = catalog.get(
		"variant_component_offsets", PackedInt32Array())
	var component_good_ids: PackedInt32Array = catalog.get(
		"component_good_ids", PackedInt32Array())
	if need_ids.is_empty() or good_ids.is_empty() \
			or market_good_ids.size() != good_available.size() \
			or need_variant_offsets.size() != need_entries.size() + 1 \
			or variant_component_offsets.is_empty() \
			or variant_component_offsets[-1] != component_good_ids.size():
		return {"ok": false}
	var market_unlocks = {}
	for index in range(market_good_ids.size()):
		market_unlocks[String(market_good_ids[index])] = int(good_available[index]) != 0
	var visible = {}
	for entry in range(need_entries.size()):
		var need_index = int(need_entries[entry])
		if need_index < 0 or need_index >= need_ids.size():
			return {"ok": false}
		var variant_begin = int(need_variant_offsets[entry])
		var variant_end = int(need_variant_offsets[entry + 1])
		if variant_begin < 0 or variant_end <= variant_begin \
				or variant_end > variant_component_offsets.size() - 1:
			return {"ok": false}
		# A need is available when one complete substitute bundle can be bought
		# locally; partially unlocked bundles must not leak the preference row.
		for variant in range(variant_begin, variant_end):
			var component_begin = int(variant_component_offsets[variant])
			var component_end = int(variant_component_offsets[variant + 1])
			if component_begin < 0 or component_end <= component_begin \
					or component_end > component_good_ids.size():
				return {"ok": false}
			var variant_unlocked = true
			for component in range(component_begin, component_end):
				var good_index = int(component_good_ids[component])
				if good_index < 0 or good_index >= good_ids.size() \
						or not bool(market_unlocks.get(String(good_ids[good_index]), false)):
					variant_unlocked = false
					break
			if variant_unlocked:
				visible[String(need_ids[need_index])] = true
				break
	return {"ok": true, "needs": visible}



static func _family_behavior_selector_visible(axis: int, stable_id: String,
		visibility: Dictionary) -> bool:
	if stable_id.is_empty():
		return true
	if axis == 0 and bool(visibility.get("enforce_buildings", false)):
		return (visibility.get("buildings", {}) as Dictionary).has(stable_id)
	if axis == 3 and bool(visibility.get("enforce_goods", false)):
		return (visibility.get("goods", {}) as Dictionary).has(stable_id)
	if axis == 1 and bool(visibility.get("enforce_professions", false)):
		return (visibility.get("professions", {}) as Dictionary).has(stable_id)
	if axis == 2 and bool(visibility.get("enforce_needs", false)):
		return (visibility.get("needs", {}) as Dictionary).has(stable_id)
	return true



static func _family_branch_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cells: PackedInt32Array = snapshot.get("cell_indices", PackedInt32Array())
	var levels: PackedInt32Array = snapshot.get("prestige_levels", PackedInt32Array())
	var population_shares: PackedInt32Array = snapshot.get(
		"population_shares_q16", PackedInt32Array())
	var cash_shares: PackedInt32Array = snapshot.get(
		"cash_shares_q16", PackedInt32Array())
	var building_shares: PackedInt32Array = snapshot.get(
		"building_shares_q16", PackedInt32Array())
	var scores: PackedInt32Array = snapshot.get("prestige_scores_q16", PackedInt32Array())
	var targets: PackedInt32Array = snapshot.get(
		"pending_target_levels", PackedInt32Array())
	var streaks: PackedInt32Array = snapshot.get("review_streaks", PackedInt32Array())
	var populations: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var cash_claims: PackedInt64Array = snapshot.get("cash_claims", PackedInt64Array())
	var building_assets: PackedInt64Array = snapshot.get("building_asset_values", PackedInt64Array())
	var satisfactions: PackedInt32Array = snapshot.get("satisfactions_q16", PackedInt32Array())
	var demo_shares: PackedInt32Array = snapshot.get("demography_shares_q16", PackedInt32Array())
	var target_shares: PackedInt32Array = snapshot.get("target_shares_q16", PackedInt32Array())
	var settlement_names: PackedStringArray = snapshot.get("settlement_names", PackedStringArray())
	for index in range(cells.size()):
		var level = int(levels[index]) if index < levels.size() else 0
		var target = int(targets[index]) if index < targets.size() else level
		var cell = int(cells[index])
		var score_q16 = int(scores[index]) if index < scores.size() else 0
		var population_q16 = int(population_shares[index]) if index < population_shares.size() else 0
		var cash_q16 = int(cash_shares[index]) if index < cash_shares.size() else 0
		var building_q16 = int(building_shares[index]) if index < building_shares.size() else 0
		var pop_count = int(populations[index]) if index < populations.size() else 0
		var cash_val = int(cash_claims[index]) if index < cash_claims.size() else 0
		var asset_val = int(building_assets[index]) if index < building_assets.size() else 0
		var sat_q16 = int(satisfactions[index]) if index < satisfactions.size() else 0
		var demo_q16 = int(demo_shares[index]) if index < demo_shares.size() else 0
		var target_q16 = int(target_shares[index]) if index < target_shares.size() else 0
		var settlement = String(settlement_names[index]).strip_edges() \
			if index < settlement_names.size() else ""
		var loc_label = "%s（地块 %d）" % [settlement, cell] \
			if not settlement.is_empty() else "地块 %d" % cell
		rows.append({
			"id": "branch:%d" % cell,
			"kind": "branch",
			"cell": cell,
			"settlement_name": settlement,
			"location_label": loc_label,
			"prestige_level": level,
			"prestige_label": h._prestige_text(level),
			"prestige_score_q16": score_q16,
			"prestige_percent": float(score_q16) * 100.0 / 65536.0,
			"prestige_text": h._q16_percent_text(score_q16),
			"population_share_q16": population_q16,
			"population_share_text": h._q16_percent_text(population_q16),
			"cash_share_q16": cash_q16,
			"cash_share_text": h._q16_percent_text(cash_q16),
			"building_share_q16": building_q16,
			"building_share_text": h._q16_percent_text(building_q16),
			"population_count": pop_count,
			"population_count_text": "%s 人" % UITokens.format_compact_number_cn(float(pop_count), 1),
			"cash_amount_text": h._money_text(cash_val),
			"building_asset_text": h._money_text(asset_val),
			"satisfaction_q16": sat_q16,
			"satisfaction_percent": float(sat_q16) * 100.0 / 65536.0,
			"satisfaction_text": h._q16_percent_text(sat_q16),
			"demography_share_text": h._q16_percent_text(demo_q16),
			"target_share_text": h._q16_percent_text(target_q16),
			"target_level": target,
			"target_label": h._prestige_text(target),
			"review_streak": int(streaks[index]) if index < streaks.size() else 0,
			"name": "%s · 威望 %s" % [loc_label, h._prestige_text(level)],
			"value": "总分 %s · 人口 %s / 现金 %s / 建筑 %s · 目标 %s（%d/2）" % [
				host._q16_percent_text(score_q16), host._q16_percent_text(population_q16),
				host._q16_percent_text(cash_q16), host._q16_percent_text(building_q16),
				host._prestige_text(target), int(streaks[index]) if index < streaks.size() else 0],
		})
	return rows



static func _family_bound_effect_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cell = int(snapshot.get("cell_idx", -1))
	var prestige_level = int(snapshot.get("prestige_level", 0))
	var settlement_name = String(snapshot.get("settlement_name", "")).strip_edges()
	var keys: PackedStringArray = snapshot.get(
		"effect_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"effect_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"effect_descriptions", PackedStringArray())
	var current_descriptions: PackedStringArray = snapshot.get(
		"effect_current_descriptions", PackedStringArray())
	var prestige_tiers_all: Array = snapshot.get("effect_prestige_descriptions", [])
	var seen = {}
	for index in range(keys.size()):
		var key = String(keys[index]).strip_edges()
		if key.is_empty() or seen.has(key):
			continue
		seen[key] = true
		var display = String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var current = String(current_descriptions[index]).strip_edges() \
			if index < current_descriptions.size() else ""
		if current.is_empty():
			current = detail
		var tier_statements: Array = []
		if index < prestige_tiers_all.size() and prestige_tiers_all[index] is PackedStringArray:
			for st in (prestige_tiers_all[index] as PackedStringArray):
				tier_statements.append(String(st))
		elif index < prestige_tiers_all.size() and prestige_tiers_all[index] is Array:
			for st in (prestige_tiers_all[index] as Array):
				tier_statements.append(String(st))
		if tier_statements.is_empty():
			for st in FamilyBuffCopy.prestige_statements(detail):
				tier_statements.append(String(st))
		rows.append({
			"id": "effect:%d:%s" % [cell, key],
			"kind": "effect",
			"cell": cell,
			"settlement_name": settlement_name,
			"prestige_level": prestige_level,
			"tier_statements": tier_statements,
			"effect_key": key,
			"title": display,
			"name": "地块 %d · %s" % [cell, display],
			"value": current,
			"detail": current,
			"tooltip": current,
		})
	return rows



static func _family_modifier_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cell = int(snapshot.get("cell_idx", -1))
	var keys: PackedStringArray = snapshot.get(
		"modifier_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"modifier_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"modifier_descriptions", PackedStringArray())
	var magnitudes: PackedInt32Array = snapshot.get(
		"modifier_magnitude_q16", PackedInt32Array())
	for index in range(keys.size()):
		var key = String(keys[index])
		var display = String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var magnitude_q16 = int(magnitudes[index]) if index < magnitudes.size() else 0
		rows.append({
			"id": "modifier:%d:%s" % [cell, key],
			"kind": "modifier",
			"cell": cell,
			"modifier_key": key,
			"title": display,
			"magnitude_q16": magnitude_q16,
			"magnitude_percent": float(magnitude_q16) * 100.0 / 65536.0,
			"magnitude_text": h._q16_percent_text(magnitude_q16),
			"name": "地块 %d · %s" % [cell, display],
			"value": "效果幅度 %s" % h._q16_percent_text(magnitude_q16),
			"detail": detail,
			"tooltip": detail,
		})
	return rows



static func _family_trigger_rows(host, snapshot: Dictionary) -> Array:
	var h = host
	var rows: Array = []
	var cell = int(snapshot.get("cell_idx", -1))
	var keys: PackedStringArray = snapshot.get(
		"trigger_definition_keys", PackedStringArray())
	var names: PackedStringArray = snapshot.get(
		"trigger_display_names", PackedStringArray())
	var descriptions: PackedStringArray = snapshot.get(
		"trigger_descriptions", PackedStringArray())
	var progress: PackedInt64Array = snapshot.get("trigger_progress", PackedInt64Array())
	var thresholds: PackedInt64Array = snapshot.get("trigger_thresholds", PackedInt64Array())
	var completed: PackedInt32Array = snapshot.get("trigger_completed", PackedInt32Array())
	var targets: PackedInt32Array = snapshot.get(
		"trigger_reward_targets", PackedInt32Array())
	for index in range(keys.size()):
		var key = String(keys[index])
		var display = String(names[index]).strip_edges() \
			if index < names.size() else ""
		if display.is_empty():
			display = key
		var detail = String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		var progress_value = int(progress[index]) if index < progress.size() else 0
		var threshold_value = int(thresholds[index]) if index < thresholds.size() else 0
		var completed_value = int(completed[index]) if index < completed.size() else 0
		var reward_target = int(targets[index]) if index < targets.size() else 0
		rows.append({
			"id": "trigger:%d:%s" % [cell, key],
			"kind": "trigger",
			"cell": cell,
			"trigger_key": key,
			"title": display,
			"progress": progress_value,
			"threshold": threshold_value,
			"progress_ratio": clampf(float(progress_value) / float(maxi(threshold_value, 1)), 0.0, 1.0),
			"completed": completed_value,
			"reward_target": reward_target,
			"name": "地块 %d · %s" % [cell, display],
			"value": "%d / %d · 已触发 %d 次 · 奖励归属 %s" % [
				progress_value, threshold_value, completed_value,
				"家族分支" if reward_target == 0 \
				else "城市公共"],
			"detail": detail,
			"tooltip": detail,
		})
	return rows



static func _prestige_text(level: int) -> String:
	return FamilyWorkspaceProjection._prestige_text(level)



static func _q16_percent_text(value: int) -> String:
	return FamilyWorkspaceProjection._q16_percent_text(value)



static func _family_notable_person_rows(host, facade, family_handle: int) -> Array:
	var h = host
	var rows: Array = []
	if facade == null or not facade.has_method("family_notable_people") \
			or not facade.has_method("notable_person_snapshot"):
		return rows
	var page: Dictionary = facade.family_notable_people(family_handle, 0, 16)
	if not bool(page.get("ok", false)):
		return rows
	var handles: PackedInt64Array = page.get("person_handles", PackedInt64Array())
	for person_handle in handles:
		var person: Dictionary = facade.notable_person_snapshot(int(person_handle))
		if not bool(person.get("ok", false)):
			continue
		var job_kind = int(person.get("job_kind", 0))
		var job_text = "家族成员"
		if job_kind == 1:
			job_text = "产业所有者"
		elif job_kind == 2:
			job_text = "产业雇员"
		var profession = String(person.get("profession_display_name", ""))
		var profession_id = String(person.get("profession_stable_id", ""))
		var building = String(person.get("building_type_display_name", ""))
		var detail_parts: Array[String] = []
		if not profession.is_empty():
			detail_parts.append(profession)
		detail_parts.append(job_text)
		if not building.is_empty():
			detail_parts.append(building)
		var cash_val = int(person.get("cash_claim", 0))
		var attr_asset_val = int(person.get("attributed_asset_value", 0))
		var net_worth_val = int(person.get("estimated_net_worth", cash_val + attr_asset_val))
		var equity_q32 = int(person.get("family_equity_share_q32", 0))
		var equity_pct = clampf(float(equity_q32) * 100.0 / 4294967296.0, 0.0, 100.0)
		var job_inc = maxi(0, int(person.get("epoch_job_income", 0)))
		var biz_res = int(person.get("epoch_business_result", 0))
		var cons_exp = maxi(0, int(person.get("epoch_consumption_expense", 0)))
		var tax_exp = maxi(0, int(person.get("epoch_tax", 0)))
		var total_inc = job_inc + maxi(0, biz_res)
		var total_exp = cons_exp + tax_exp + maxi(0, -biz_res)
		var net_flow = total_inc - total_exp
		var sat_q16 = int(person.get("needs_satisfaction_q16", 0))
		rows.append({
			"id": "person:%d" % int(person_handle),
			"kind": "person",
			"person_handle": int(person_handle),
			"portrait_key": "family.workspace.person",
			"name": String(person.get("full_name", "未命名人物")),
			"role": job_text,
			"profession": profession,
			"profession_id": profession_id,
			"profession_icon": String(IconCatalog.profession_semantic(profession_id)),
			"building": building,
			"cell_idx": int(person.get("cell_idx", -1)),
			"notable_since_day": int(person.get("notable_since_day", 0)),
			"cash_claim_text": h._money_text(cash_val),
			"attributed_asset_text": h._money_text(attr_asset_val),
			"net_worth_val": net_worth_val,
			"net_worth_text": h._money_text(net_worth_val),
			"equity_share_percent": equity_pct,
			"equity_share_text": "%.1f%%" % equity_pct,
			"income_val": total_inc,
			"expense_val": total_exp,
			"income_text": h._money_text(total_inc),
			"expense_text": h._money_text(total_exp),
			"net_cashflow_val": net_flow,
			"net_cashflow_text": "%s%s" % [
				"+" if net_flow >= 0 else "−", h._money_text(absi(net_flow))],
			"satisfaction_q16": sat_q16,
			"satisfaction_percent": float(sat_q16) * 100.0 / 65536.0,
			"satisfaction_text": h._q16_percent_text(sat_q16),
			"value": " · ".join(detail_parts),
		})
	return rows


## 本地年度产值与人均年度产值。数据全在内存账本里，不发起任何原生查询；
## 未跟踪的格返回空数组，调用方不会多出两格空白指标。
## 金额格式沿用本页邻居（居民存款 / 粮食产出）的 host._money_text 约定，不额外加货币符号。## 金额格式沿用本页邻居（居民存款 / 粮食产出）的 _money_text 约定，不额外加货币符号。
