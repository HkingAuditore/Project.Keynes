extends RefCounted

## Builds and validates the starter construction requirements.

const StarterInputs = preload("res://scripts/economy/starter_economy_inputs.gd")
const Q16_ONE := 65536


static func _compile_starter_construction_contract(plan_result: Dictionary,
		starter_route: Dictionary, completed: Dictionary, map: MapData,
		cell_idx: int, profile_by_id: Dictionary,
		attempted_seed_ids: Dictionary = {}) -> Dictionary:
	var seed_building_id := String(plan_result.get("primary_food_building_id", ""))
	if seed_building_id.is_empty() or not profile_by_id.has(seed_building_id):
		return StarterInputs._error("starter_construction_seed_missing",
			"开局食物种子建筑缺少可编译的建材配方。")
	attempted_seed_ids[seed_building_id] = true
	var seed_profile = profile_by_id[seed_building_id]
	var seed_groups := _construction_groups(seed_profile)
	if seed_groups.is_empty():
		return StarterInputs._error("starter_construction_groups_missing",
			"开局食物种子建筑没有建材组：%s" % seed_building_id)

	# Opening construction is granted as bootstrap stock, so every authored
	# seed-group candidate is locally reachable without extra producer buildings.
	var locally_reachable := StarterInputs._starter_initial_goods(starter_route)
	for group in seed_groups:
		for candidate in group.candidates:
			locally_reachable[String(candidate.good_id)] = true
	for profile in StarterInputs._building_profiles:
		if not StarterInputs._technology_available(profile, completed) \
				or not StarterInputs._conditions_met(profile, map, cell_idx) \
				or StarterInputs._resource_building_count_cap(profile, map, cell_idx) == 0:
			continue
		for good_id in profile.output_good_ids:
			locally_reachable[String(good_id)] = true

	var preferred_good := String(starter_route.get(
		"starter_construction_good_id", ""))
	var group_offsets := PackedInt32Array([0])
	var candidate_good_ids := PackedStringArray()
	var candidate_efficiencies := PackedInt32Array()
	var legacy_candidates := PackedStringArray()
	var viable_groups: Array = []
	for group_index in range(seed_groups.size()):
		var group: Dictionary = seed_groups[group_index]
		var viable: Array[Dictionary] = []
		for candidate in group.candidates:
			var good_id := String(candidate.good_id)
			candidate_good_ids.append(good_id)
			candidate_efficiencies.append(int(candidate.efficiency_q16))
			if not legacy_candidates.has(good_id):
				legacy_candidates.append(good_id)
			if locally_reachable.has(good_id):
				var physical := _construction_physical_quantity(
					int(group.quantity), int(candidate.efficiency_q16))
				viable.append({"good_id": good_id, "physical": physical})
		group_offsets.append(candidate_good_ids.size())
		if viable.is_empty():
			return {
				"ok": false,
				"code": "starter_construction_group_unreachable",
				"message": "出生地缺少种子建筑第 %d 个建材组的本地可达材料。" % group_index,
				"failed_group": group_index,
				"seed_building_id": seed_building_id,
			}
		viable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_preferred := String(a.good_id) == preferred_good
			var b_preferred := String(b.good_id) == preferred_good
			if a_preferred != b_preferred:
				return a_preferred
			if int(a.physical) != int(b.physical):
				return int(a.physical) < int(b.physical)
			return String(a.good_id) < String(b.good_id))
		viable_groups.append(viable)

	# A seed recipe may expose one OR group while the rest of the starter bundle
	# uses its candidates in different material roles. Pick the first stable
	# one-candidate-per-group combination that closes the complete bundle instead
	# of committing to the preferred good before checking downstream buildings.
	var selections: Array = [[]]
	for viable_group in viable_groups:
		var expanded: Array = []
		for prefix in selections:
			for option in viable_group:
				var next: Array = (prefix as Array).duplicate()
				next.append(option)
				expanded.append(next)
				if expanded.size() > 1024:
					return StarterInputs._error("starter_construction_selection_overflow",
						"开局建材候选组合超过确定性搜索上限。")
		selections = expanded
	var selected_good_ids := PackedStringArray()
	var selected_quantities := PackedInt64Array()
	var dependency_check := {}
	for selection in selections:
		var selected_by_good := {}
		for option in selection:
			var good_id := String(option.good_id)
			selected_by_good[good_id] = int(selected_by_good.get(good_id, 0)) \
				+ int(option.physical)
		var trial_good_ids := PackedStringArray(selected_by_good.keys())
		trial_good_ids.sort()
		var trial_check := _validate_starter_construction_closure(
			plan_result, starter_route, completed, map, cell_idx, profile_by_id,
			trial_good_ids)
		if dependency_check.is_empty():
			dependency_check = trial_check
		if not bool(trial_check.get("ok", false)):
			continue
		selected_good_ids = trial_good_ids
		for good_id in selected_good_ids:
			selected_quantities.append(int(selected_by_good[String(good_id)]))
		dependency_check = trial_check
		break
	if not bool(dependency_check.get("ok", false)):
		# The largest food contributor is not always a viable construction
		# seed. Cold starts, for example, may rely on several hunting camps,
		# while the gathering route carries the bootstrap fiber group needed
		# to rebuild the complete starter bundle.
		var food_goods: PackedStringArray = starter_route.get(
			"starter_food_good_ids", PackedStringArray())
		var starter_ids: PackedStringArray = plan_result.get(
			"starter_building_ids", PackedStringArray())
		for alternative_id in starter_ids:
			var alternative := String(alternative_id)
			if attempted_seed_ids.has(alternative) \
					or not profile_by_id.has(alternative):
				continue
			var alternative_profile = profile_by_id[alternative]
			var produces_food := false
			for output_good in alternative_profile.output_good_ids:
				if food_goods.has(String(output_good)):
					produces_food = true
					break
			if not produces_food:
				continue
			var ordered := StarterInputs._primary_building_first(
				starter_ids,
				plan_result.get("starter_building_counts", PackedInt64Array()),
				alternative)
			plan_result["primary_food_building_id"] = alternative
			plan_result["starter_building_ids"] = ordered.ids
			plan_result["starter_building_counts"] = ordered.counts
			var alternative_contract := _compile_starter_construction_contract(
				plan_result, starter_route, completed, map, cell_idx,
				profile_by_id, attempted_seed_ids)
			if bool(alternative_contract.get("ok", false)):
				return alternative_contract
		return dependency_check
	return {
		"ok": true,
		"starter_construction_seed_building_id": seed_building_id,
		"starter_construction_group_offsets": group_offsets,
		"starter_construction_candidate_good_ids": candidate_good_ids,
		"starter_construction_candidate_efficiency_q16": candidate_efficiencies,
		"starter_construction_selected_good_ids": selected_good_ids,
		"starter_construction_selected_quantities": selected_quantities,
		# Read-only compatibility metadata. Bootstrap never consumes these fields.
		"starter_construction_good_id": preferred_good,
		"starter_construction_good_ids": legacy_candidates,
	}

static func _compile_pending_knowledge_construction(starter_route: Dictionary,
		profile_by_id: Dictionary) -> Dictionary:
	var building_id := String(starter_route.get("pending_knowledge_building_id", ""))
	if building_id.is_empty():
		return {
			"ok": true,
			"pending_knowledge_construction_good_ids": PackedStringArray(),
			"pending_knowledge_construction_quantities": PackedInt64Array(),
		}
	if not profile_by_id.has(building_id):
		return StarterInputs._error("starter_knowledge_building_missing",
			"开局待建知识棚不在规划目录：%s" % building_id)
	var groups := _construction_groups(profile_by_id[building_id])
	if groups.is_empty():
		return StarterInputs._error("starter_knowledge_construction_missing",
			"待建知识棚缺少建材配方：%s" % building_id)
	# Bootstrap stocks one copy of the chosen recipe, so every authored
	# candidate is reachable without leftover gathering techs.
	var preferred_good := String(starter_route.get("starter_construction_good_id", ""))
	var selected_by_good := {}
	for group in groups:
		var viable: Array[Dictionary] = []
		for candidate in group.candidates:
			var good_id := String(candidate.good_id)
			viable.append({
				"good_id": good_id,
				"physical": _construction_physical_quantity(
					int(group.quantity), int(candidate.efficiency_q16)),
			})
		if viable.is_empty():
			return StarterInputs._error("starter_knowledge_construction_unreachable",
				"待建知识棚没有可用建材候选：%s" % building_id)
		viable.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_preferred := String(a.good_id) == preferred_good
			var b_preferred := String(b.good_id) == preferred_good
			if a_preferred != b_preferred:
				return a_preferred
			if int(a.physical) != int(b.physical):
				return int(a.physical) < int(b.physical)
			return String(a.good_id) < String(b.good_id))
		var selected: Dictionary = viable[0]
		selected_by_good[String(selected.good_id)] = int(selected_by_good.get(
			String(selected.good_id), 0)) + int(selected.physical)
	var selected_good_ids := PackedStringArray(selected_by_good.keys())
	selected_good_ids.sort()
	var selected_quantities := PackedInt64Array()
	for good_id in selected_good_ids:
		selected_quantities.append(int(selected_by_good[String(good_id)]))
	return {
		"ok": true,
		"pending_knowledge_construction_good_ids": selected_good_ids,
		"pending_knowledge_construction_quantities": selected_quantities,
	}

static func _validate_starter_construction_closure(plan_result: Dictionary,
		starter_route: Dictionary, completed: Dictionary, map: MapData,
		cell_idx: int, profile_by_id: Dictionary,
		selected_materials: PackedStringArray) -> Dictionary:
	var reachable := StarterInputs._starter_initial_goods(starter_route)
	for good_id in selected_materials:
		reachable[String(good_id)] = true
	var local_profiles: Array = []
	for profile in StarterInputs._building_profiles:
		if StarterInputs._technology_available(profile, completed) \
				and StarterInputs._conditions_met(profile, map, cell_idx) \
				and StarterInputs._resource_building_count_cap(profile, map, cell_idx) != 0:
			local_profiles.append(profile)
	for profile in local_profiles:
		var outputs := {}
		for output_good in profile.output_good_ids:
			outputs[String(output_good)] = true
		for group in _construction_groups(profile):
			# Category expansion (e.g. primitive_construction) may list a
			# building's own output as one optional substitute. That is not a
			# closed loop while any external candidate remains.
			var has_external_candidate := false
			for candidate in group.candidates:
				if not outputs.has(String(candidate.good_id)):
					has_external_candidate = true
					break
			if not group.candidates.is_empty() and not has_external_candidate:
				return StarterInputs._error("starter_construction_self_dependency",
					"开局可达建筑不得使用自身产物建造：%s -> %s" % [
						String(profile.id), String(group.candidates[0].good_id)])
	var changed := true
	while changed:
		changed = false
		for profile in local_profiles:
			if not _construction_groups_reachable(profile, reachable):
				continue
			for output_good in profile.output_good_ids:
				var good_id := String(output_good)
				if not reachable.has(good_id):
					reachable[good_id] = true
					changed = true
	var starter_ids: PackedStringArray = plan_result.get(
		"starter_building_ids", PackedStringArray())
	for building_id in starter_ids:
		var stable_id := String(building_id)
		if not profile_by_id.has(stable_id) \
				or not _construction_groups_reachable(profile_by_id[stable_id], reachable):
			return StarterInputs._error("starter_construction_dependency_cycle",
				"开局建筑没有外部入口可完成重建：%s" % stable_id)
	return {"ok": true}

static func _construction_groups(profile) -> Array[Dictionary]:
	var authored_groups: Array[Dictionary] = []
	var good_ids: PackedStringArray = profile.construction_good_ids
	var quantities: PackedInt64Array = profile.construction_quantities
	var offsets: PackedInt32Array = profile.construction_candidate_offsets
	var candidate_ids: PackedStringArray = profile.construction_candidate_good_ids
	var efficiencies: PackedInt32Array = profile.construction_candidate_efficiency_q16
	var categories: PackedStringArray = profile.construction_category_ids
	var min_levels: PackedInt32Array = profile.construction_min_quality_levels
	for group_index in range(mini(good_ids.size(), quantities.size())):
		var candidates: Array[Dictionary] = []
		if offsets.size() == good_ids.size() + 1:
			for candidate_index in range(int(offsets[group_index]),
					int(offsets[group_index + 1])):
				if candidate_index >= 0 and candidate_index < candidate_ids.size():
					candidates.append({
						"good_id": String(candidate_ids[candidate_index]),
						"efficiency_q16": int(efficiencies[candidate_index]) \
							if candidate_index < efficiencies.size() else Q16_ONE,
					})
		# EconomyCatalog expands a category group the same way; the starter
		# contract is compared against the compiled CSR, so both readers must
		# agree on the candidate set.
		if candidates.is_empty() and categories.size() == good_ids.size():
			var category_id := String(categories[group_index])
			var min_level := int(min_levels[group_index]) \
				if min_levels.size() == good_ids.size() else 0
			candidates = _construction_category_candidates(category_id, min_level)
		if candidates.is_empty():
			candidates.append({"good_id": String(good_ids[group_index]),
				"efficiency_q16": Q16_ONE})
		authored_groups.append({"preferred_good_id": String(good_ids[group_index]),
			"quantity": int(quantities[group_index]), "candidates": candidates})
	return authored_groups

static func _construction_category_candidates(category_id: String,
		min_quality_level: int) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	if category_id.is_empty():
		return candidates
	for good_profile in GoodProfileRegistry.ordered():
		if int(good_profile.production_quality_level) < min_quality_level:
			continue
		var roles: PackedStringArray = good_profile.substitution_category_ids
		var member := roles.has(category_id) \
			or (roles.is_empty() and String(good_profile.category_id) == category_id)
		if not member:
			continue
		candidates.append({
			"good_id": String(good_profile.id),
			"efficiency_q16": int(good_profile.production_efficiency_q16),
		})
	return candidates

static func _construction_groups_reachable(profile, reachable: Dictionary) -> bool:
	for group in _construction_groups(profile):
		var group_ready := false
		for candidate in group.candidates:
			if reachable.has(String(candidate.good_id)):
				group_ready = true
				break
		if not group_ready:
			return false
	return true

static func _construction_physical_quantity(quantity: int, efficiency_q16: int) -> int:
	var efficiency := maxi(1, efficiency_q16)
	return maxi(1, (quantity * Q16_ONE + efficiency - 1) / efficiency)
