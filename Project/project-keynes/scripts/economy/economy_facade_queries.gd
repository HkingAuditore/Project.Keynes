extends RefCounted

## Reads published economy views and handles family requests.

const FamilyBuffCopyScript = preload("res://scripts/family/family_buff_copy.gd")
const EconomyFacadeDisplayScript = preload(
	"res://scripts/economy/economy_facade_display.gd")
const SATISFACTION_DIMENSION_NAMES := [
	"生存", "基本生活", "舒适", "奢侈", "收入增长", "储蓄", "税负", "社会发展",
]
const Opcode = preload("res://scripts/economy/economy_facade_commands.gd").Opcode


static func population_cell_summary(host, cell_idx: int) -> Dictionary:
	if not host._configured:
		return {}
	if host._world_ext.has_method("get_population_cell_summary"):
		return host._world_ext.get_population_cell_summary(cell_idx)
	return host._world_ext.get_population_cell_snapshot(cell_idx)


static func named_settlement_snapshot(host) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "native settlement runtime unavailable"}
	return host._world_ext.get_named_settlement_snapshot()


static func settlement_delta(host, since_revision: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "native settlement runtime unavailable"}
	return host._world_ext.get_settlement_delta(since_revision)


static func population_cell_snapshot(host, cell_idx: int, include_details: bool = true) -> Dictionary:
	if not host._configured:
		return {}
	var snapshot: Dictionary = host._world_ext.get_population_cell_snapshot(
		cell_idx, include_details)
	if snapshot.has("populations"):
		EconomyFacadeDisplayScript.attach_population_display_metadata(host, snapshot)
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
	else:
		snapshot["details_available"] = false
		snapshot["details_pending"] = bool(snapshot.get("busy", false))
	return snapshot


static func market_cell_snapshot(host, cell_idx: int) -> Dictionary:
	if not host._configured:
		return {}
	var snapshot: Dictionary = host._world_ext.get_market_cell_snapshot(cell_idx)
	var has_details := snapshot.has("good_ids")
	if has_details:
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
	else:
		snapshot["details_available"] = false
		snapshot["details_pending"] = bool(snapshot.get("busy", false))
	return snapshot


## 有界地图状况视图。NativeEconomyRuntime 只返回请求地块的定点严重度，
## 不把市场/人口/建筑矩阵复制进 MapData。


static func cell_situation_snapshot(host, requested_cells: PackedInt32Array) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy_situation_visual_api_unavailable"}
	return host._world_ext.get_cell_situation_snapshot(
		requested_cells)

## 冷路径满意度溯源。只读且只在原生 slice 之间安全，Inspector 打开时才调用。


static func explain_cohort_satisfaction(host, cohort_handle: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "satisfaction explain API unavailable"}
	var explained: Dictionary = host._world_ext.explain_cohort_satisfaction(cohort_handle)
	if bool(explained.get("ok", false)):
		explained["dimension_names"] = SATISFACTION_DIMENSION_NAMES
	return explained


static func cell_satisfaction_attractiveness(host, cell_idx: int) -> Dictionary:
	if not host._configured :
		return {"ok": false, "reason": "satisfaction attractiveness API unavailable"}
	var attractiveness: Dictionary = \
		host._world_ext.get_cell_satisfaction_attractiveness(cell_idx)
	if bool(attractiveness.get("ok", false)):
		attractiveness["dimension_names"] = SATISFACTION_DIMENSION_NAMES
	return attractiveness


static func cell_mobilization_snapshot(host, cell_idx: int) -> Dictionary:
	if not host._configured \
			or not host._world_ext.has_method("get_cell_mobilization_snapshot"):
		return {"ok": false, "reason": "mobilization API unavailable"}
	return host._world_ext.get_cell_mobilization_snapshot(cell_idx)


static func country_mobilization_summary(host, country_slot: int) -> Dictionary:
	if not host._configured \
			or not host._world_ext.has_method("get_country_mobilization_summary"):
		return {"ok": false, "reason": "mobilization API unavailable"}
	return host._world_ext.get_country_mobilization_summary(country_slot)


static func mobilization_odds(host, cell_idx: int, profession: int, action: int,
		spend_bp: int = 0) -> Dictionary:
	if not host._configured or not host._world_ext.has_method("get_mobilization_odds"):
		return {"ok": false, "reason": "mobilization API unavailable"}
	return host._world_ext.get_mobilization_odds(cell_idx, profession, action,
		spend_bp)


static func resolve_player_mobilization(host, choice: Dictionary) -> Dictionary:
	if not host._configured or not host._world_ext.has_method("resolve_player_mobilization"):
		return {"ok": false, "code": "mobilization_unavailable"}
	return host._world_ext.resolve_player_mobilization(choice)


static func apply_mobilization_result(host, cell_idx: int, profession: int, action: int,
		success: bool) -> bool:
	if not host._configured \
			or not host._world_ext.has_method("apply_mobilization_result"):
		return false
	return bool(host._world_ext.apply_mobilization_result(cell_idx, profession,
		action, success))


static func trade_orders_for_cell(host, cell_idx: int, offset: int = 0, limit: int = 64,
		good_index: int = -1) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "trade order API unavailable", "total": 0}
	var page: Dictionary = host._world_ext.get_trade_orders_for_cell(
		cell_idx, offset, limit, good_index)
	page["good_ids"] = host._catalog.get("good_ids", PackedStringArray())
	return page


## Optional, bounded visual observer. The native bridge never waits for a worker.


static func trade_visual_snapshot(host, cells: PackedInt32Array, visible: PackedByteArray,
        vision_revision: int, selected_cell: int = -1, enabled: bool = true) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "trade_visual_unavailable"}
	return host._world_ext.get_trade_visual_snapshot(cells, visible,
		vision_revision, selected_cell, enabled)


static func bake_trade_visual_paths(host, snapshot: Dictionary, map_width: int, hex_size: float) -> Dictionary:
	if not host._configured:
		return {"ok": false}
	return host._world_ext.bake_trade_visual_paths(snapshot, map_width, hex_size)


static func country_trade_snapshot(host, country_handle: int, view: String = "summary",
		offset: int = 0, limit: int = 32) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "country trade API unavailable",
			"view": view, "total": 0}
	var page: Dictionary = host._world_ext.get_country_trade_snapshot(
		country_handle, view, offset, clampi(limit, 1, 64))
	page["good_ids"] = host._catalog.get("good_ids", PackedStringArray())
	return page


## 国家经济卷宗只读聚合。scope_cell < 0 为全国；filter_id 仅对 buildings 视图生效（产业部门）。


static func country_economy_overview(host, country_handle: int, view: String = "summary",
		scope_cell: int = -1, filter_id: int = -1, offset: int = 0,
		limit: int = 0) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "country economy overview API unavailable",
			"view": view}
	var page: Dictionary = host._world_ext.get_country_economy_overview(
		country_handle, view, scope_cell, filter_id, offset, limit)
	if not bool(page.get("ok", false)):
		return page
	if page.has("profession_stable_ids"):
		page["profession_display_names"] = EconomyFacadeDisplayScript.mapped_names(
			page["profession_stable_ids"], host._profession_display_names)
	if page.has("building_stable_ids"):
		page["building_display_names"] = EconomyFacadeDisplayScript.mapped_names(
			page["building_stable_ids"], host._building_display_names)
	if page.has("good_stable_ids"):
		page["good_display_names"] = EconomyFacadeDisplayScript.mapped_names(
			page["good_stable_ids"], host._good_display_names)
	if page.has("need_ids"):
		page["need_display_names"] = EconomyFacadeDisplayScript.mapped_names(page["need_ids"], host._need_display_names)
	return page


static func building_cell_snapshot(host, cell_idx: int) -> Dictionary:
	if not host._configured:
		return {}
	var snapshot: Dictionary = host._world_ext.get_building_cell_snapshot(cell_idx)
	if snapshot.has("building_type_ids"):
		EconomyFacadeDisplayScript.attach_building_display_metadata(host, snapshot)
	return snapshot


## Dense catalog columns the construction workspace needs beyond the cell
## snapshot: sector, base build time, and production maturity (the authored
## "how advanced is this process" rank used by the 「最新」 ordering).
## All are catalog-wide columns, so they are read once instead of per cell.


static func family_cell_snapshot(host, cell_idx: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_family_cell_snapshot(
		cell_idx, offset, limit)
	if bool(snapshot.get("ok", false)):
		EconomyFacadeDisplayScript.attach_family_display_names(host, snapshot)
	return snapshot


static func family_snapshot(host, family_handle: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_family_snapshot(family_handle)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var profession_ids: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	var profession_names := PackedStringArray()
	var catalog_professions: PackedStringArray = host._catalog.get(
		"profession_ids", PackedStringArray())
	for profession_id in profession_ids:
		profession_names.append(catalog_professions[profession_id]
			if profession_id >= 0 and profession_id < catalog_professions.size()
			else "")
	snapshot["profession_stable_ids"] = profession_names
	var origin_cell := int(snapshot.get("origin_cell", -1))
	var settlement_name := String(EconomyFacadeDisplayScript.settlement_name_lookup(host).get(origin_cell, ""))
	snapshot["origin_settlement_name"] = settlement_name
	var surname := String(snapshot.get("surname", ""))
	var format := String(snapshot.get("culture_group_naming_format", "CITY_SURNAME_SUFFIX"))
	var separator := String(snapshot.get("culture_group_separator", "-"))
	var suffix := String(snapshot.get("culture_group_suffix", "氏"))
	var family_name: String = host.compose_family_display_name(
		settlement_name, surname, format, separator, suffix)
	var collision_index := 1
	var origin_families: Dictionary = host.family_cell_snapshot(origin_cell, 0, 256)
	var origin_cells: PackedInt32Array = origin_families.get("origin_cells", PackedInt32Array())
	var surnames: PackedStringArray = origin_families.get("surnames", PackedStringArray())
	var stable_ids: PackedInt64Array = origin_families.get("stable_ids", PackedInt64Array())
	var collisions: Array[int] = []
	for i in range(mini(origin_cells.size(), mini(surnames.size(), stable_ids.size()))):
		if int(origin_cells[i]) == origin_cell and String(surnames[i]) == surname:
			collisions.append(int(stable_ids[i]))
	collisions.sort()
	if collisions.size() > 1:
		collision_index = collisions.find(int(snapshot.get("stable_id", 0))) + 1
		family_name += "（%d）" % collision_index
	snapshot["family_name_collision_index"] = collision_index
	snapshot["family_name"] = family_name
	return snapshot


static func get_family_traits(host, family_handle: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_trait_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_family_traits(family_handle)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var axes: PackedInt32Array = snapshot.get(
		"behavior_axes", PackedInt32Array())
	var selector_ids: PackedInt32Array = snapshot.get(
		"behavior_selector_ids", PackedInt32Array())
	var stable_ids := PackedStringArray()
	var display_names := PackedStringArray()
	for index in range(mini(axes.size(), selector_ids.size())):
		var source_ids := PackedStringArray()
		var names: Dictionary = {}
		match int(axes[index]):
			0:
				source_ids = host._catalog.get("building_type_ids", PackedStringArray())
				names = host._building_display_names
			1:
				source_ids = host._catalog.get("profession_ids", PackedStringArray())
				names = host._profession_display_names
			2:
				source_ids = host._catalog.get("need_ids", PackedStringArray())
				names = host._need_display_names
			3:
				source_ids = host._catalog.get("good_ids", PackedStringArray())
				names = host._good_display_names
		var selector_id := int(selector_ids[index])
		var stable_id := String(source_ids[selector_id]) \
			if selector_id >= 0 and selector_id < source_ids.size() else ""
		stable_ids.append(stable_id)
		display_names.append(String(names.get(stable_id, stable_id)))
	snapshot["behavior_selector_stable_ids"] = stable_ids
	snapshot["behavior_selector_display_names"] = display_names
	var trait_keys: PackedStringArray = snapshot.get("trait_keys", PackedStringArray())
	snapshot["descriptions"] = EconomyFacadeDisplayScript.family_trait_description_column(host,
		trait_keys, snapshot.get("strength_q16", PackedInt32Array()))
	var effect_names := EconomyFacadeDisplayScript.family_trait_effect_display_names(host, trait_keys)
	var bound_keys: PackedStringArray = snapshot.get(
		"effect_definition_keys", PackedStringArray())
	snapshot["bound_effect_display_names"] = EconomyFacadeDisplayScript.mapped_effect_names(
		bound_keys, host._family_effect_displays)
	snapshot["bound_effect_descriptions"] = EconomyFacadeDisplayScript.mapped_effect_current_descriptions(host,
		bound_keys, EconomyFacadeDisplayScript.family_max_prestige_level(host, family_handle))
	var seen := {}
	for name in effect_names:
		seen[String(name)] = true
	for name in snapshot["bound_effect_display_names"]:
		var label := String(name).strip_edges()
		if label.is_empty() or seen.has(label):
			continue
		seen[label] = true
		effect_names.append(label)
	snapshot["effect_display_names"] = effect_names
	return snapshot


static func family_branches(host, family_handle: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_family_branches(family_handle, offset, limit)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var settlements := EconomyFacadeDisplayScript.settlement_name_lookup(host)
	var cells: PackedInt32Array = snapshot.get("cell_indices", PackedInt32Array())
	var settlement_names := PackedStringArray()
	for cell_idx in cells:
		settlement_names.append(String(settlements.get(int(cell_idx), "")))
	snapshot["settlement_names"] = settlement_names
	return snapshot


static func get_family_branch_effects(host, family_handle: int, cell_idx: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_trait_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_family_branch_effects(
		family_handle, cell_idx)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var modifier_keys: PackedStringArray = snapshot.get(
		"modifier_definition_keys", PackedStringArray())
	snapshot["modifier_display_names"] = EconomyFacadeDisplayScript.mapped_effect_names(
		modifier_keys, host._family_modifier_displays)
	snapshot["modifier_descriptions"] = EconomyFacadeDisplayScript.mapped_effect_descriptions(
		modifier_keys, host._family_modifier_displays)
	var trigger_keys: PackedStringArray = snapshot.get(
		"trigger_definition_keys", PackedStringArray())
	snapshot["trigger_display_names"] = EconomyFacadeDisplayScript.mapped_effect_names(
		trigger_keys, host._family_trigger_displays)
	snapshot["trigger_descriptions"] = EconomyFacadeDisplayScript.mapped_effect_descriptions(
		trigger_keys, host._family_trigger_displays)
	var effect_keys: PackedStringArray = snapshot.get(
		"effect_definition_keys", PackedStringArray())
	snapshot["effect_display_names"] = EconomyFacadeDisplayScript.mapped_effect_names(
		effect_keys, host._family_effect_displays)
	var prestige_level := int(snapshot.get("prestige_level", 0))
	snapshot["effect_current_descriptions"] = EconomyFacadeDisplayScript.mapped_effect_current_descriptions(host,
		effect_keys, prestige_level)
	snapshot["effect_descriptions"] = snapshot["effect_current_descriptions"]
	snapshot["effect_prestige_descriptions"] = EconomyFacadeDisplayScript.mapped_effect_prestige_descriptions(host,
		effect_keys)
	snapshot["settlement_name"] = String(EconomyFacadeDisplayScript.settlement_name_lookup(host).get(cell_idx, ""))
	return snapshot


static func queue_family_trait_mutation(host, family_handle: int, operation: Variant,
		trait_key: StringName, strength_q16: int = 65536,
		effective_day: int = 0, priority: int = 100,
		sequence: int = -1) -> int:
	if not host._configured:
		return 0
	var opcode: int = int(operation) if typeof(operation) == TYPE_INT else {
		"grant": 1, "remove": 2, "set_strength": 3,
	}.get(String(operation), 0)
	if sequence < 0:
		host._family_trait_sequence += 1
		sequence = host._family_trait_sequence
	var result: Dictionary = host._world_ext.submit_family_trait_commands({
		"protocol_version": 1,
		"operations": PackedInt32Array([opcode]),
		"family_handles": PackedInt64Array([family_handle]),
		"trait_keys": PackedStringArray([String(trait_key)]),
		"strength_q16": PackedInt32Array([strength_q16]),
		"effective_days": PackedInt64Array([effective_day]),
		"priorities": PackedInt32Array([priority]),
		"sequences": PackedInt64Array([sequence]),
	})
	var orders: PackedInt64Array = result.get("request_orders", PackedInt64Array())
	return int(orders[0]) if bool(result.get("ok", false)) and not orders.is_empty() else 0


## Pending 1-of-3 family founding offers with player-facing card copy.


static func family_founding_offers(host, offset: int = 0, limit: int = 16) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_founding_runtime_unavailable"}
	var result: Dictionary = host._world_ext.get_family_founding_offers(offset, limit)
	if not bool(result.get("ok", false)) or (result.get("offers", []) as Array).is_empty():
		return result
	for offer in result.get("offers", []):
		host.decorate_family_founding_offer(offer)
	return result


static func decorate_family_founding_offer(host, offer: Dictionary) -> void:
	var settlements := EconomyFacadeDisplayScript.settlement_name_lookup(host)
	var settlement_name := String(settlements.get(int(offer.get("cell", -1)), ""))
	offer["settlement_name"] = settlement_name
	var split := String(offer.get("kind", "FOUNDING")) == "SPLIT"
	if split:
		var parent: Dictionary = host.family_snapshot(int(offer.get("source_family_handle", 0)))
		offer["source_family_name"] = String(parent.get("family_name", "原家族"))
	var plan_index := 0
	for card in offer.get("candidates", []):
		host._decorate_family_founding_card(card, settlement_name)
		if split:
			plan_index += 1
			card["family_name"] = "%s · 方案%s" % [card["family_name"], ["一", "二", "三"][plan_index - 1]]
			card["people_label"] = "分支族人"
			card["choice_label"] = "确立此家风"
			card["choice_tooltip"] = "按此方案独立成族；本地整支族人、产业与名人统一转入新家族。"


static func submit_family_founding_choice(host, offer_id: int, generation: int,
		choice_index: int, effective_day: int, sequence: int = 0) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_founding_runtime_unavailable"}
	if sequence == 0:
		host._family_founding_sequence += 1
		sequence = host._family_founding_sequence
	return host._world_ext.submit_family_founding_choice(offer_id, generation,
		choice_index, maxi(0, effective_day), sequence)


static func _decorate_family_founding_card(host, card: Dictionary, settlement_name: String) -> void:
	card["family_name"] = host.compose_family_display_name(settlement_name,
		String(card.get("surname", "")),
		String(card.get("culture_group_naming_format", "CITY_SURNAME_SUFFIX")),
		String(card.get("culture_group_separator", "-")),
		String(card.get("culture_group_suffix", "氏")))
	var building_id := String(card.get("building_type_id", ""))
	card["building_display_name"] = String(
		host._building_display_names.get(building_id, building_id))
	card["building_icon_key"] = String(host._building_icon_for_type(building_id))
	var profession_id := String(card.get("owner_profession_id", ""))
	card["owner_profession_display_name"] = String(
		host._profession_display_names.get(profession_id, profession_id))
	card["profession_icon_key"] = String(
		IconCatalog.profession_semantic(profession_id) \
		if not profession_id.is_empty() else &"population.profession.owner")
	var trait_keys: PackedStringArray = card.get("trait_keys", PackedStringArray())
	var strengths: PackedInt32Array = card.get("trait_strength_q16", PackedInt32Array())
	var trait_names := PackedStringArray()
	for trait_key in trait_keys:
		var copy: Dictionary = host._family_trait_copy.get(String(trait_key), {})
		var display := String(copy.get("display_name", ""))
		trait_names.append(display if not display.is_empty() else String(trait_key))
	card["trait_display_names"] = trait_names
	var trait_descriptions := EconomyFacadeDisplayScript.family_trait_description_column(host, trait_keys, strengths)
	card["trait_descriptions"] = trait_descriptions
	var trait_items: Array[Dictionary] = []
	for index in range(trait_keys.size()):
		var trait_key := String(trait_keys[index])
		var copy: Dictionary = host._family_trait_copy.get(trait_key, {})
		var display_name := String(trait_names[index]) if index < trait_names.size() else trait_key
		var description := String(trait_descriptions[index]) \
			if index < trait_descriptions.size() else ""
		var min_q16 := int(copy.get("strength_min_q16", 0))
		var max_q16 := int(copy.get("strength_max_q16", 65536))
		var strength := int(strengths[index]) if index < strengths.size() else min_q16
		var span := max_q16 - min_q16
		var ratio := 0.65 if span <= 0 else clampf(
			float(strength - min_q16) / float(span), 0.0, 1.0)
		var axis := int(copy.get("primary_axis", -1))
		trait_items.append({
			"key": trait_key,
			"name": display_name,
			"description": description,
			"axis": axis,
			"axis_label": FamilyBuffCopyScript.axis_short_label(axis),
			"badges": FamilyBuffCopyScript.extract_trait_badges(description),
			"strength_ratio": ratio,
			"factor_percent": FamilyBuffCopyScript.trait_factor_percent(description, ratio),
		})
	card["trait_items"] = trait_items
	var effect_key := String(card.get("effect_key", ""))
	if effect_key.is_empty():
		card["effect_display_name"] = ""
		card["effect_description"] = ""
		card["effect_prestige_descriptions"] = PackedStringArray()
		card["effect_full_description"] = ""
		return
	var keys := PackedStringArray([effect_key])
	card["effect_display_name"] = String(EconomyFacadeDisplayScript.mapped_effect_names(
		keys, host._family_effect_displays)[0])
	var effect_entry: Dictionary = host._family_effect_displays.get(effect_key, {})
	var prestige_statements: PackedStringArray = effect_entry.get(
		"prestige_descriptions", PackedStringArray())
	card["effect_prestige_descriptions"] = prestige_statements
	var preview := FamilyBuffCopyScript.founding_effect_preview(
		prestige_statements, String(effect_entry.get("description", "")))
	if preview.is_empty():
		preview = String(EconomyFacadeDisplayScript.mapped_effect_current_descriptions(host, keys, 1)[0]).strip_edges()
	card["effect_description"] = preview
	card["effect_full_description"] = FamilyBuffCopyScript.join_prestige(
		prestige_statements, preview)


static func _building_icon_for_type(host, type_id: String) -> StringName:
	if type_id.is_empty():
		return &"economy.building"
	var type_ids: PackedStringArray = host._catalog.get(
		"building_type_ids", PackedStringArray())
	var type_idx := type_ids.find(type_id)
	var output_offsets: PackedInt32Array = host._catalog.get(
		"building_output_offsets", PackedInt32Array())
	var output_good_indices: PackedInt32Array = host._catalog.get(
		"building_output_good_ids", PackedInt32Array())
	var good_ids: PackedStringArray = host._catalog.get("good_ids", PackedStringArray())
	var kinds: PackedInt32Array = host._catalog.get("building_kinds", PackedInt32Array())
	if type_idx >= 0 and type_idx + 1 < output_offsets.size():
		var output_pos := int(output_offsets[type_idx])
		if output_pos < int(output_offsets[type_idx + 1]) \
				and output_pos >= 0 and output_pos < output_good_indices.size():
			var good_idx := int(output_good_indices[output_pos])
			if good_idx >= 0 and good_idx < good_ids.size():
				var kind := int(kinds[type_idx]) if type_idx < kinds.size() else 1
				return IconCatalog.building_semantic(type_id, good_ids[good_idx], kind)
	if type_id.contains("gathering"):
		return &"economy.building.gathering"
	if type_id.contains("hunting"):
		return &"economy.building.hunting"
	if type_id.contains("fish"):
		return &"economy.building.fishing"
	if type_id.contains("timber") or type_id.contains("lumber"):
		return &"economy.building.forestry"
	if type_id.contains("farm") or type_id.contains("pasture"):
		return &"economy.building.farm"
	if type_id.contains("mine") or type_id.contains("quarry"):
		return &"economy.building.mine"
	return &"economy.building"


static func queue_family_trigger_reward(host, effect: Dictionary) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var command_key := String(effect.get("command_key", ""))
	var opcode := 0
	var building_type := -1
	if command_key == "family.free_building":
		opcode = Opcode.FAMILY_FREE_BUILDING
		var authored := String(effect.get("definition_key", "")).strip_edges()
		if authored.is_empty():
			building_type = -1
		else:
			var building_ids: PackedStringArray = host._catalog.get(
				"building_type_ids", PackedStringArray())
			building_type = building_ids.find(authored)
			if building_type < 0:
				return {"ok": false, "reason": "family_reward_building_unknown"}
	elif command_key == "family.population_reward":
		opcode = Opcode.FAMILY_POPULATION_REWARD
	elif command_key == "family.absorb_anonymous":
		opcode = Opcode.FAMILY_ABSORB_ANONYMOUS
	elif command_key == "family.purchase_discount":
		opcode = Opcode.FAMILY_PURCHASE_DISCOUNT
	else:
		return {"ok": false, "reason": "family_reward_command_unknown"}
	var command_batch: Array[Dictionary] = [{
		"opcode": opcode,
		"effective_day": int(effect.get("effective_day", 0)),
		"sequence": maxi(0, int(effect.get("effect_id", 0))),
		"target_handle": int(effect.get("target_handle", 0)),
		"i32_0": int(effect.get("payload_i0", 0)),
		"i32_1": building_type,
		"i64_0": maxi(1, int(effect.get("resolved_value", 1))) \
			if opcode != Opcode.FAMILY_PURCHASE_DISCOUNT \
			else int(effect.get("resolved_value", 32768)),
		"i64_1": int(effect.get("payload_i1", effect.get("effect_id", 0))),
	}]
	return host.submit(command_batch)


static func family_industries(host, family_handle: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "family_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_family_industries(
		family_handle, offset, limit)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	var ids: PackedInt32Array = snapshot.get("building_type_ids", PackedInt32Array())
	var names := PackedStringArray()
	var catalog_ids: PackedStringArray = host._catalog.get(
		"building_type_ids", PackedStringArray())
	for type_id in ids:
		names.append(catalog_ids[type_id]
			if type_id >= 0 and type_id < catalog_ids.size() else "")
	snapshot["building_type_stable_ids"] = names
	return snapshot


static func family_notable_people(host, family_handle: int, offset: int = 0,
		limit: int = 64) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "notable_person_runtime_unavailable"}
	var page: Dictionary = host._world_ext.get_family_notable_people(
		family_handle, offset, limit)
	if not bool(page.get("ok", false)):
		return page
	var family: Dictionary = host.family_snapshot(family_handle)
	EconomyFacadeDisplayScript.attach_notable_person_page_names(host, page, String(family.get("surname", "")))
	return page


static func notable_person_snapshot(host, person_handle: int) -> Dictionary:
	if not host._configured:
		return {"ok": false, "reason": "notable_person_runtime_unavailable"}
	var snapshot: Dictionary = host._world_ext.get_notable_person_snapshot(person_handle)
	if not bool(snapshot.get("ok", false)):
		return snapshot
	snapshot["full_name"] = EconomyFacadeDisplayScript.format_person_name(
		String(snapshot.get("surname", "")),
		String(snapshot.get("given_name", "")),
		int(snapshot.get("name_disambiguator", 0)))
	var profession_idx := int(snapshot.get("profession_id", -1))
	var professions: PackedStringArray = host._catalog.get(
		"profession_ids", PackedStringArray())
	var profession_id := professions[profession_idx] \
		if profession_idx >= 0 and profession_idx < professions.size() else ""
	snapshot["profession_stable_id"] = profession_id
	snapshot["profession_display_name"] = String(
		host._profession_display_names.get(String(profession_id), String(profession_id)))
	var building_idx := int(snapshot.get("building_type_id", -1))
	var building_ids: PackedStringArray = host._catalog.get(
		"building_type_ids", PackedStringArray())
	var building_id := building_ids[building_idx] \
		if building_idx >= 0 and building_idx < building_ids.size() else ""
	snapshot["building_type_stable_id"] = building_id
	snapshot["building_type_display_name"] = String(
		host._building_display_names.get(String(building_id), String(building_id)))
	return snapshot
