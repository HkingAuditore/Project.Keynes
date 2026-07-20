class_name EconomyFacade
extends RefCounted

signal economy_event_batch_available(meta: Dictionary)
signal economy_event_batch(batch: Dictionary)

const DEFAULT_PROFILE_PATH := "res://data/economy/default_economy.tres"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EconomyProfileScript = preload("res://scripts/data/economy_profile.gd")

enum Opcode {
	TRANSFER_TO_COHORT = 1,
	MINT_TO_COHORT = 2,
	BURN_FROM_COHORT = 3,
	ADD_STOCK = 4,
	REMOVE_STOCK = 5,
	ADD_POPULATION = 6,
	MOVE_POPULATION = 7,
	CHANGE_SIGNATURE = 8,
	TRANSFER_FROM_COHORT = 9,
	BUILD = 10,
	DEMOLISH = 11,
	COUNTRY_GOOD_TO_MARKET = 12,
	MARKET_GOOD_TO_COUNTRY = 13,
}

var _world_ext: Object = null
var _profile = null
var _catalog: Dictionary = {}
var _configured: bool = false
var _profession_display_names: Dictionary = {}
var _ethnicity_display_names: Dictionary = {}
var _building_display_names: Dictionary = {}

func configure(world_ext: Object, cell_count: int, seed: int, profile = null) -> Dictionary:
	_world_ext = world_ext
	_profile = profile
	if _profile == null:
		_profile = ResourceLoader.load(DEFAULT_PROFILE_PATH, "Resource")
	if _world_ext == null or not _world_ext.has_method("configure_economy"):
		return {"ok": false, "reason": "DCWorldExt economy API unavailable"}
	if _profile == null:
		return {"ok": false, "reason": "EconomyProfile unavailable"}
	_catalog = EconomyCatalogScript.compile_native_catalog()
	if not bool(_catalog.get("ok", false)):
		return _catalog
	var native_catalog := _catalog.duplicate()
	native_catalog.erase("ok")
	_profession_display_names = _load_display_names(EconomyCatalogScript.PROFESSION_DIR)
	_ethnicity_display_names = _load_display_names(EconomyCatalogScript.ETHNICITY_DIR)
	_building_display_names = _load_display_names(EconomyCatalogScript.BUILDING_DIR)
	var result: Dictionary = _world_ext.configure_economy(
		native_catalog, _profile.to_native_profile(), cell_count, seed)
	_configured = bool(result.get("ok", false))
	return result

func bootstrap(population_packet: Dictionary = {}, market_packet: Dictionary = {},
		building_packet: Dictionary = {}) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var packet := population_packet
	if packet.is_empty():
		packet = {
			"cell_indices": PackedInt32Array(),
			"signature_ids": PackedInt32Array(),
			"population": PackedInt64Array(),
			"funds": PackedInt64Array(),
		}
	var markets := market_packet.duplicate(true)
	for key in building_packet:
		markets[key] = building_packet[key]
	return _world_ext.bootstrap_economy(packet, markets)

func submit(commands: Array[Dictionary]) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "economy facade is not configured"}
	var batch := {
		"opcodes": PackedInt32Array(),
		"effective_days": PackedInt64Array(),
		"sequences": PackedInt64Array(),
		"target_handles": PackedInt64Array(),
		"i32_0": PackedInt32Array(),
		"i32_1": PackedInt32Array(),
		"i64_0": PackedInt64Array(),
		"i64_1": PackedInt64Array(),
	}
	for command in commands:
		batch.opcodes.append(int(command.get("opcode", 0)))
		batch.effective_days.append(int(command.get("effective_day", 0)))
		batch.sequences.append(int(command.get("sequence", 0)))
		batch.target_handles.append(int(command.get("target_handle", 0)))
		batch.i32_0.append(int(command.get("i32_0", 0)))
		batch.i32_1.append(int(command.get("i32_1", 0)))
		batch.i64_0.append(int(command.get("i64_0", 0)))
		batch.i64_1.append(int(command.get("i64_1", 0)))
	return _world_ext.submit_economy_commands(batch)

func add_stock(cell_idx: int, good_id: StringName, quantity: int,
		effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var good_idx: int = goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	return submit([{
		"opcode": Opcode.ADD_STOCK,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": 0,
		"i32_0": cell_idx,
		"i32_1": good_idx,
		"i64_0": quantity,
		"i64_1": 0,
	}])

func transfer_country_cash_to_cohort(country_handle: int, cohort_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_TO_COHORT,
		"target_handle": cohort_handle, "i64_0": amount, "i64_1": country_handle,
		"effective_day": effective_day, "sequence": sequence}])

func transfer_cohort_cash_to_country(cohort_handle: int, country_handle: int,
		amount: int, effective_day: int, sequence: int) -> Dictionary:
	return submit([{"opcode": Opcode.TRANSFER_FROM_COHORT,
		"target_handle": cohort_handle, "i64_0": amount, "i64_1": country_handle,
		"effective_day": effective_day, "sequence": sequence}])

func transfer_country_good_to_market(country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return _submit_country_good_transfer(Opcode.COUNTRY_GOOD_TO_MARKET, country_handle,
		cell_idx, good_id, quantity, effective_day, sequence)

func transfer_market_good_to_country(country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	return _submit_country_good_transfer(Opcode.MARKET_GOOD_TO_COUNTRY, country_handle,
		cell_idx, good_id, quantity, effective_day, sequence)

func _submit_country_good_transfer(opcode: int, country_handle: int, cell_idx: int,
		good_id: StringName, quantity: int, effective_day: int, sequence: int) -> Dictionary:
	var goods: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var good_idx := goods.find(String(good_id))
	if good_idx < 0:
		return {"ok": false, "reason": "unknown good id: %s" % String(good_id)}
	return submit([{"opcode": opcode, "target_handle": country_handle,
		"i32_0": cell_idx, "i32_1": good_idx, "i64_0": quantity,
		"effective_day": effective_day, "sequence": sequence}])

func population_cell_summary(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	if _world_ext.has_method("get_population_cell_summary"):
		return _world_ext.get_population_cell_summary(cell_idx)
	return _world_ext.get_population_cell_snapshot(cell_idx)


func population_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_population_cell_snapshot(cell_idx)
	if snapshot.has("populations"):
		_attach_population_display_metadata(snapshot)
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
	else:
		snapshot["details_available"] = false
		snapshot["details_pending"] = bool(snapshot.get("busy", false))
	return snapshot

func market_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_market_cell_snapshot(cell_idx)
	var has_details := snapshot.has("good_ids")
	if has_details:
		snapshot["details_available"] = true
		snapshot["details_pending"] = false
	else:
		snapshot["details_available"] = false
		snapshot["details_pending"] = bool(snapshot.get("busy", false))
	return snapshot

func trade_orders_for_cell(cell_idx: int, offset: int = 0, limit: int = 64) -> Dictionary:
	if not _configured or not _world_ext.has_method("get_trade_orders_for_cell"):
		return {"ok": false, "reason": "trade order API unavailable", "total": 0}
	var page: Dictionary = _world_ext.get_trade_orders_for_cell(cell_idx, offset, limit)
	page["good_ids"] = _catalog.get("good_ids", PackedStringArray())
	return page

func building_cell_snapshot(cell_idx: int) -> Dictionary:
	if not _configured:
		return {}
	var snapshot: Dictionary = _world_ext.get_building_cell_snapshot(cell_idx)
	if snapshot.has("building_type_ids"):
		_attach_building_display_metadata(snapshot)
	return snapshot

func _attach_building_display_metadata(snapshot: Dictionary) -> void:
	var type_ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var type_names := PackedStringArray()
	for stable_id in type_ids:
		type_names.append(String(_building_display_names.get(String(stable_id), String(stable_id))))
	var profession_ids: PackedStringArray = _catalog.get("profession_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(_profession_display_names.get(String(stable_id), String(stable_id))))
	snapshot["building_type_display_names"] = type_names
	snapshot["profession_stable_ids"] = profession_ids
	snapshot["profession_display_names"] = profession_names
	for key in [
		"signature_profession_ids", "building_owner_profession_ids", "building_owner_slots",
		"building_employee_offsets", "building_employee_profession_ids", "building_employee_slots",
		"building_input_offsets", "building_input_good_ids", "building_input_quantities",
		"building_input_category_ids", "building_input_min_quality_levels",
		"building_input_candidate_offsets", "building_input_candidate_good_ids",
		"building_input_candidate_efficiency_q16", "building_upgrade_family_ids",
		"building_upgrade_family_indices", "building_upgrade_tiers",
		"building_behavior_ids",
		"building_output_offsets", "building_output_good_ids", "building_output_quantities",
		"building_resource_ids", "building_resource_offsets", "building_production_resource_ids",
		"building_production_resource_quantities", "building_production_resource_modes",
		"building_production_resource_access_modes",
		"building_resource_generation_offsets",
		"building_resource_generation_ids", "building_resource_generation_quantities",
		"building_resource_generation_floor_q16", "building_kinds",
		"building_technology_tag_offsets", "building_technology_tags", "good_ids",
		"good_category_ids", "good_substitution_category_offsets",
		"good_substitution_category_ids", "good_storage_modes", "good_monetary_issue_values",
		"good_production_quality_levels", "good_production_efficiency_q16",
		"good_technology_tag_offsets", "good_technology_tags",
	]:
		snapshot[key] = _catalog.get(key)

func building_type_id(building_id: StringName) -> int:
	var ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	return ids.find(String(building_id))

func building_job_spec(building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var profession_ids: PackedStringArray = _catalog.get("profession_ids", PackedStringArray())
	var owner_professions: PackedInt32Array = _catalog.get(
		"building_owner_profession_ids", PackedInt32Array())
	var owner_slots: PackedInt64Array = _catalog.get("building_owner_slots", PackedInt64Array())
	var employee_offsets: PackedInt32Array = _catalog.get(
		"building_employee_offsets", PackedInt32Array())
	var employee_professions: PackedInt32Array = _catalog.get(
		"building_employee_profession_ids", PackedInt32Array())
	var employee_slots: PackedInt64Array = _catalog.get(
		"building_employee_slots", PackedInt64Array())
	if type_id >= owner_professions.size() or type_id >= owner_slots.size() or \
			type_id + 1 >= employee_offsets.size():
		return {"ok": false, "reason": "building job catalog shape invalid"}
	var owner_profession_idx := int(owner_professions[type_id])
	if owner_profession_idx < 0 or owner_profession_idx >= profession_ids.size():
		return {"ok": false, "reason": "building owner profession invalid"}
	var role_professions := PackedStringArray()
	var role_slots := PackedInt64Array()
	for role in range(employee_offsets[type_id], employee_offsets[type_id + 1]):
		var profession_idx := int(employee_professions[role])
		if profession_idx < 0 or profession_idx >= profession_ids.size():
			return {"ok": false, "reason": "building employee profession invalid"}
		role_professions.append(profession_ids[profession_idx])
		role_slots.append(employee_slots[role])
	return {
		"ok": true,
		"type_id": type_id,
		"stable_id": String(building_id),
		"owner_profession": profession_ids[owner_profession_idx],
		"owner_slots": owner_slots[type_id],
		"employee_professions": role_professions,
		"employee_slots": role_slots,
	}

func building_placement_spec(building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = _catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var good_ids: PackedStringArray = _catalog.get("good_ids", PackedStringArray())
	var resource_ids: PackedStringArray = _catalog.get(
		"building_resource_ids", PackedStringArray())
	var input_goods := _stable_ids_from_catalog_range(type_id, good_ids,
		"building_input_offsets", "building_input_good_ids")
	var output_goods := _stable_ids_from_catalog_range(type_id, good_ids,
		"building_output_offsets", "building_output_good_ids")
	var input_quantities_all: PackedInt64Array = _catalog.get(
		"building_input_quantities", PackedInt64Array())
	var output_quantities_all: PackedInt64Array = _catalog.get(
		"building_output_quantities", PackedInt64Array())
	var production_resources := _stable_ids_from_catalog_range(type_id, resource_ids,
		"building_resource_offsets", "building_production_resource_ids")
	var technology_offsets: PackedInt32Array = _catalog.get(
		"building_technology_tag_offsets", PackedInt32Array())
	var technology_tags: PackedStringArray = _catalog.get(
		"building_technology_tags", PackedStringArray())
	var input_categories_all: PackedStringArray = _catalog.get(
		"building_input_category_ids", PackedStringArray())
	var input_min_levels_all: PackedInt32Array = _catalog.get(
		"building_input_min_quality_levels", PackedInt32Array())
	var candidate_offsets_all: PackedInt32Array = _catalog.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidate_goods_all: PackedInt32Array = _catalog.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var candidate_efficiencies_all: PackedInt32Array = _catalog.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_categories: PackedStringArray = _catalog.get(
		"good_category_ids", PackedStringArray())
	var good_substitution_offsets: PackedInt32Array = _catalog.get(
		"good_substitution_category_offsets", PackedInt32Array())
	var good_substitution_ids: PackedStringArray = _catalog.get(
		"good_substitution_category_ids", PackedStringArray())
	if not bool(input_goods.get("ok", false)) or not bool(output_goods.get("ok", false)) \
			or not bool(production_resources.get("ok", false)):
		return {"ok": false, "reason": "building placement catalog shape invalid"}
	var kinds: PackedInt32Array = _catalog.get("building_kinds", PackedInt32Array())
	var quantities: PackedInt64Array = _catalog.get(
		"building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = _catalog.get(
		"building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = _catalog.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var family_ids: PackedStringArray = _catalog.get(
		"building_upgrade_family_ids", PackedStringArray())
	var family_indices: PackedInt32Array = _catalog.get(
		"building_upgrade_family_indices", PackedInt32Array())
	var upgrade_tiers: PackedInt32Array = _catalog.get(
		"building_upgrade_tiers", PackedInt32Array())
	var resource_begin := int(production_resources.begin)
	var resource_end := int(production_resources.end)
	if type_id >= kinds.size() or type_id >= family_indices.size() \
			or type_id >= upgrade_tiers.size() \
			or resource_end > quantities.size() or resource_end > modes.size() \
			or resource_end > access_modes.size() or type_id + 1 >= technology_offsets.size():
		return {"ok": false, "reason": "building placement resource columns invalid"}
	var technology_begin := int(technology_offsets[type_id])
	var technology_end := int(technology_offsets[type_id + 1])
	var input_begin := int(input_goods.begin)
	var input_end := int(input_goods.end)
	if technology_begin < 0 or technology_end < technology_begin \
			or technology_end > technology_tags.size() or input_end > input_categories_all.size() \
			or input_end > input_min_levels_all.size() or input_end >= candidate_offsets_all.size() \
			or input_end > input_quantities_all.size() \
			or int(output_goods.end) > output_quantities_all.size():
		return {"ok": false, "reason": "building placement technology columns invalid"}
	var local_candidate_offsets := PackedInt32Array([0])
	var local_candidate_good_ids := PackedStringArray()
	var local_candidate_efficiencies := PackedInt32Array()
	for input_idx in range(input_begin, input_end):
		var candidate_begin := int(candidate_offsets_all[input_idx])
		var candidate_end := int(candidate_offsets_all[input_idx + 1])
		if candidate_begin < 0 or candidate_end < candidate_begin \
				or candidate_end > candidate_goods_all.size() \
				or candidate_end > candidate_efficiencies_all.size():
			return {"ok": false, "reason": "building placement candidate columns invalid"}
		for candidate_idx in range(candidate_begin, candidate_end):
			var good_idx := int(candidate_goods_all[candidate_idx])
			if good_idx < 0 or good_idx >= good_ids.size():
				return {"ok": false, "reason": "building placement candidate good invalid"}
			local_candidate_good_ids.append(good_ids[good_idx])
			local_candidate_efficiencies.append(candidate_efficiencies_all[candidate_idx])
		local_candidate_offsets.append(local_candidate_good_ids.size())
	var output_categories := PackedStringArray()
	var output_substitution_offsets := PackedInt32Array([0])
	var output_substitution_ids := PackedStringArray()
	for good_id in output_goods.ids:
		var good_idx := good_ids.find(String(good_id))
		output_categories.append(String(good_categories[good_idx]) \
			if good_idx >= 0 and good_idx < good_categories.size() else "")
		if good_idx < 0 or good_idx + 1 >= good_substitution_offsets.size():
			return {"ok": false, "reason": "building output substitution categories invalid"}
		var category_begin := int(good_substitution_offsets[good_idx])
		var category_end := int(good_substitution_offsets[good_idx + 1])
		if category_begin < 0 or category_end <= category_begin \
				or category_end > good_substitution_ids.size():
			return {"ok": false, "reason": "building output substitution category range invalid"}
		output_substitution_ids.append_array(
			good_substitution_ids.slice(category_begin, category_end))
		output_substitution_offsets.append(output_substitution_ids.size())
	var family_idx := int(family_indices[type_id])
	var higher_tier_ids := PackedStringArray()
	if family_idx >= 0:
		for candidate in range(type_ids.size()):
			if candidate < family_indices.size() and candidate < upgrade_tiers.size() \
					and int(family_indices[candidate]) == family_idx \
					and int(upgrade_tiers[candidate]) > int(upgrade_tiers[type_id]):
				higher_tier_ids.append(type_ids[candidate])
	return {
		"ok": true,
		"type_id": type_id,
		"stable_id": String(building_id),
		"kind": int(kinds[type_id]),
		"upgrade_family_id": family_ids[family_idx] \
			if family_idx >= 0 and family_idx < family_ids.size() else "",
		"upgrade_tier": int(upgrade_tiers[type_id]),
		"higher_tier_building_ids": higher_tier_ids,
		"input_good_ids": input_goods.ids,
		"input_quantities": input_quantities_all.slice(input_begin, input_end),
		"input_category_ids": input_categories_all.slice(input_begin, input_end),
		"input_min_quality_levels": input_min_levels_all.slice(input_begin, input_end),
		"input_candidate_offsets": local_candidate_offsets,
		"input_candidate_good_ids": local_candidate_good_ids,
		"input_candidate_efficiency_q16": local_candidate_efficiencies,
		"output_good_ids": output_goods.ids,
		"output_quantities": output_quantities_all.slice(
			int(output_goods.begin), int(output_goods.end)),
		"output_category_ids": output_categories,
		"output_substitution_category_offsets": output_substitution_offsets,
		"output_substitution_category_ids": output_substitution_ids,
		"resource_ids": production_resources.ids,
		"resource_quantities": quantities.slice(resource_begin, resource_end),
		"resource_modes": modes.slice(resource_begin, resource_end),
		"resource_access_modes": access_modes.slice(resource_begin, resource_end),
		"technology_tags": technology_tags.slice(technology_begin, technology_end),
	}

func _stable_ids_from_catalog_range(type_id: int, stable_ids: PackedStringArray,
		offset_key: String, index_key: String) -> Dictionary:
	var offsets: PackedInt32Array = _catalog.get(offset_key, PackedInt32Array())
	var indices: PackedInt32Array = _catalog.get(index_key, PackedInt32Array())
	if type_id + 1 >= offsets.size():
		return {"ok": false}
	var begin := int(offsets[type_id])
	var end := int(offsets[type_id + 1])
	if begin < 0 or end < begin or end > indices.size():
		return {"ok": false}
	var ids := PackedStringArray()
	for edge in range(begin, end):
		var stable_idx := int(indices[edge])
		if stable_idx < 0 or stable_idx >= stable_ids.size():
			return {"ok": false}
		ids.append(stable_ids[stable_idx])
	return {"ok": true, "ids": ids, "begin": begin, "end": end}

func build(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id := building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	return submit([{
		"opcode": Opcode.BUILD,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}])

func demolish(cell_idx: int, building_id: StringName, count: int, owner_handle: int,
		effective_day: int, sequence: int) -> Dictionary:
	var type_id := building_type_id(building_id)
	if type_id < 0 or count <= 0:
		return {"ok": false, "reason": "invalid building type or count"}
	return submit([{
		"opcode": Opcode.DEMOLISH,
		"effective_day": effective_day,
		"sequence": sequence,
		"target_handle": owner_handle,
		"i32_0": cell_idx,
		"i32_1": type_id,
		"i64_0": count,
		"i64_1": 0,
	}])

func report() -> Dictionary:
	return _world_ext.get_economy_report() if _configured else {"configured": false}

func signature_id(profession_id: StringName, ethnicity_id: StringName) -> int:
	var key := "%s|%s" % [String(profession_id), String(ethnicity_id)]
	var keys: PackedStringArray = _catalog.get("signature_keys", PackedStringArray())
	return keys.find(key)

func good_ids() -> PackedStringArray:
	return (_catalog.get("good_ids", PackedStringArray()) as PackedStringArray).duplicate()

func profession_ids() -> PackedStringArray:
	return (_catalog.get("profession_ids", PackedStringArray()) as PackedStringArray).duplicate()

func building_type_ids() -> PackedStringArray:
	return (_catalog.get("building_type_ids", PackedStringArray()) as PackedStringArray).duplicate()

## Cold-path bootstrap view of the same compiled columns consumed by the native runtime.
## This deliberately exposes only finance inputs; runtime authority remains in C++.
func bootstrap_finance_columns() -> Dictionary:
	var result := {}
	for key in [
		"good_ids", "good_default_price", "good_inventory_target_ratios_q16",
		"good_merchant_buy_factor_q16", "good_monetary_issue_values",
		"plan_ids", "plan_need_offsets", "need_ids", "need_living_cost_weights_q16",
		"need_stable_ids", "need_base_qty_per_person", "need_quantity_env_curve_ids",
		"need_variant_offsets", "variant_preference_q16",
		"variant_preference_env_curve_ids", "variant_component_offsets",
		"component_good_ids", "component_qty_per_need", "environment_curve_signal_ids",
		"environment_curve_values_q16", "ethnicity_need_factor_q16",
		"signature_ethnicity_ids",
	]:
		result[key] = _catalog.get(key)
	var ratios: PackedInt32Array = result.get(
		"good_inventory_target_ratios_q16", PackedInt32Array())
	var target_days := PackedInt32Array()
	target_days.resize(ratios.size())
	for good_idx in range(ratios.size()):
		target_days[good_idx] = int(_profile.merchant_market_making_days_q16) * \
			int(ratios[good_idx]) / 65536
	result["good_target_inventory_days_q16"] = target_days
	result["living_cost_base_plan_id"] = String(_profile.living_cost_base_plan_id)
	return result

func bootstrap_cycle_days(cohort_count: int, market_count: int = 0,
		active_building_cell_count: int = 0, building_group_count: int = 0) -> int:
	if _profile == null:
		return 1
	var maximum := maxi(1, int(_profile.market_max_cycle_days))
	var configured := int(_profile.market_cycle_days)
	if configured > 0:
		return mini(configured, maximum)
	var target := int(_profile.market_target_cohorts_per_slice)
	if target <= 0:
		target = 4000 if cohort_count <= 500000 else (12000 if cohort_count <= 2000000 else 30000)
	var market_budget := maxi(1, int(_profile.cells_per_slice))
	if bool(_profile.auto_slice_by_scale):
		market_budget = clampi(market_count, 1, 128)
	var market_slices := maxi(1, (market_count + market_budget - 1) / market_budget)
	var cohort_slices := (cohort_count + target - 1) / target if cohort_count > 0 else 0
	market_slices = maxi(market_slices, cohort_slices)
	var building_budget := int(_profile.building_cells_per_slice)
	if building_budget <= 0:
		building_budget = 256
	var building_ranges := (active_building_cell_count + building_budget - 1) / \
		building_budget if active_building_cell_count > 0 else 0
	var group_budget := maxi(1, int(_profile.building_groups_per_slice))
	var group_ranges := (building_group_count + group_budget - 1) / group_budget \
		if building_group_count > 0 else 0
	building_ranges = maxi(building_ranges, group_ranges)
	var minimum := maxi(1, int(_profile.market_min_cycle_days))
	var raw_total := maxi(minimum, market_slices + building_ranges * 4 + 4)
	var scheduler_slack := maxi(0, (raw_total - minimum + 1) / 2)
	return clampi(raw_total + scheduler_slack, 1, maximum)

func _attach_population_display_metadata(snapshot: Dictionary) -> void:
	var profession_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var ethnicity_ids: PackedStringArray = snapshot.get(
		"ethnicity_stable_ids", PackedStringArray())
	var profession_names := PackedStringArray()
	var ethnicity_names := PackedStringArray()
	for stable_id in profession_ids:
		profession_names.append(String(_profession_display_names.get(
			String(stable_id), String(stable_id))))
	for stable_id in ethnicity_ids:
		ethnicity_names.append(String(_ethnicity_display_names.get(
			String(stable_id), String(stable_id))))
	snapshot["profession_display_names"] = profession_names
	snapshot["ethnicity_display_names"] = ethnicity_names

static func _load_display_names(directory: String) -> Dictionary:
	var result := {}
	var paths := PackedStringArray()
	for file_name in DirAccess.get_files_at(directory):
		if file_name.get_extension().to_lower() == "tres":
			paths.append("%s/%s" % [directory, file_name])
	paths.sort()
	for path in paths:
		var profile = ResourceLoader.load(path, "Resource")
		if profile == null:
			continue
		var stable_id := String(profile.get("id"))
		if stable_id == "":
			continue
		var display_name := String(profile.get("display_name"))
		result[stable_id] = display_name if display_name != "" else stable_id
	return result

func begin_save() -> Dictionary:
	return _world_ext.begin_economy_save(_profile.save_chunk_bytes) if _configured else {"ok": false, "reason": "not configured"}

func read_save_chunk() -> PackedByteArray:
	return _world_ext.read_economy_save_chunk(_profile.save_chunk_bytes) if _configured else PackedByteArray()

func end_save() -> Dictionary:
	return _world_ext.end_economy_save() if _configured else {"ok": false, "reason": "not configured"}

func event_schema() -> Dictionary:
	if not _configured or not _world_ext.has_method("get_economy_event_schema"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.get_economy_event_schema()

func set_trace_cells(cells: PackedInt32Array) -> Dictionary:
	if not _configured or not _world_ext.has_method("set_economy_trace_filter"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.set_economy_trace_filter({"cells": cells})

func set_inspector_trace_cell(cell_idx: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("set_economy_inspector_trace_cell"):
		return {"ok": false, "reason": "economy inspector trace API unavailable"}
	return _world_ext.set_economy_inspector_trace_cell(cell_idx)

func poll_events(consumer_id: StringName, max_events: int = -1,
		kind: int = 0, cell: int = -1, after_event_id: int = -1) -> Dictionary:
	if not _configured or not _world_ext.has_method("poll_economy_events"):
		return {"ok": false, "reason": "economy event API unavailable", "count": 0}
	var opts := {
		"consumer_id": consumer_id,
		"max_events": _profile.economy_trace_poll_max_events if max_events < 0 else max_events,
		"kind": kind,
		"cell": cell,
	}
	if after_event_id >= 0:
		opts["after_event_id"] = after_event_id
	return _world_ext.poll_economy_events(opts)

func ack_events(consumer_id: StringName, up_to_event_id: int) -> Dictionary:
	if not _configured or not _world_ext.has_method("ack_economy_events"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.ack_economy_events(consumer_id, up_to_event_id)

func trace_report() -> Dictionary:
	if not _configured or not _world_ext.has_method("get_economy_trace_report"):
		return {"ok": false, "reason": "economy event API unavailable"}
	return _world_ext.get_economy_trace_report()

func dispatch_committed_events(meta: Dictionary) -> void:
	if not bool(meta.get("economy_event_batch_published", false)):
		return
	economy_event_batch_available.emit(meta)
	var batch := poll_events(&"economy_facade_handlers")
	if int(batch.get("count", 0)) <= 0:
		return
	economy_event_batch.emit(batch)
	ack_events(&"economy_facade_handlers", int(batch.get("last_event_id", 0)))

func begin_event_archive(chunk_bytes: int = -1) -> Dictionary:
	if not _configured or not _world_ext.has_method("begin_economy_event_archive"):
		return {"ok": false, "reason": "economy event archive API unavailable"}
	return _world_ext.begin_economy_event_archive(
		_profile.save_chunk_bytes if chunk_bytes < 0 else chunk_bytes)

func read_event_archive_chunk(max_bytes: int = -1) -> PackedByteArray:
	if not _configured or not _world_ext.has_method("read_economy_event_archive_chunk"):
		return PackedByteArray()
	return _world_ext.read_economy_event_archive_chunk(
		_profile.save_chunk_bytes if max_bytes < 0 else max_bytes)

func end_event_archive() -> Dictionary:
	if not _configured or not _world_ext.has_method("end_economy_event_archive"):
		return {"ok": false, "reason": "economy event archive API unavailable"}
	return _world_ext.end_economy_event_archive()

func write_event_archive(path: String, chunk_bytes: int = -1) -> Dictionary:
	if not _configured:
		return {"ok": false, "reason": "not configured"}
	var file := FileAccess.open_compressed(
		path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if file == null:
		return {"ok": false, "reason": "event archive file open failed",
			"error": FileAccess.get_open_error()}
	var begin := begin_event_archive(chunk_bytes)
	if not bool(begin.get("ok", false)):
		file.close()
		return begin
	var chunks := 0
	var bytes_written := 0
	while true:
		var chunk := read_event_archive_chunk(chunk_bytes)
		if chunk.is_empty():
			break
		file.store_buffer(chunk)
		chunks += 1
		bytes_written += chunk.size()
	file.close()
	var ended := end_event_archive()
	ended["path"] = path
	ended["chunks"] = chunks
	ended["uncompressed_bytes"] = bytes_written
	return ended

func world_ext() -> Object:
	return _world_ext

func profile():
	return _profile

func is_configured() -> bool:
	return _configured
