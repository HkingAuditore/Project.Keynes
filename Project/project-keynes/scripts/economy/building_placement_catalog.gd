extends RefCounted

const Q16_ONE := 65536

# Pure catalog projection shared by opening planners; no runtime state.
static func query(catalog: Dictionary, building_id: StringName) -> Dictionary:
	var type_ids: PackedStringArray = catalog.get("building_type_ids", PackedStringArray())
	var type_id := type_ids.find(String(building_id))
	if type_id < 0:
		return {"ok": false, "reason": "unknown building type: %s" % String(building_id)}
	var good_ids: PackedStringArray = catalog.get("good_ids", PackedStringArray())
	var resource_ids: PackedStringArray = catalog.get(
		"building_resource_ids", PackedStringArray())
	var input_goods := _stable_ids_from_catalog_range(catalog, type_id, good_ids,
		"building_input_offsets", "building_input_good_ids")
	var output_goods := _stable_ids_from_catalog_range(catalog, type_id, good_ids,
		"building_output_offsets", "building_output_good_ids")
	var input_quantities_all: PackedInt64Array = catalog.get(
		"building_input_quantities", PackedInt64Array())
	var input_required_all: PackedInt32Array = catalog.get(
		"building_input_required_q16", PackedInt32Array())
	var output_quantities_all: PackedInt64Array = catalog.get(
		"building_output_quantities", PackedInt64Array())
	var production_resources := _stable_ids_from_catalog_range(catalog, type_id, resource_ids,
		"building_resource_offsets", "building_production_resource_ids")
	var technology_offsets: PackedInt32Array = catalog.get(
		"building_technology_tag_offsets", PackedInt32Array())
	var technology_tags: PackedStringArray = catalog.get(
		"building_technology_tags", PackedStringArray())
	var required_offsets: PackedInt32Array = catalog.get("building_required_technology_tag_offsets", PackedInt32Array())
	var required_tags: PackedStringArray = catalog.get("building_required_technology_tags", PackedStringArray())
	var input_categories_all: PackedStringArray = catalog.get(
		"building_input_category_ids", PackedStringArray())
	var input_min_levels_all: PackedInt32Array = catalog.get(
		"building_input_min_quality_levels", PackedInt32Array())
	var candidate_offsets_all: PackedInt32Array = catalog.get(
		"building_input_candidate_offsets", PackedInt32Array())
	var candidate_goods_all: PackedInt32Array = catalog.get(
		"building_input_candidate_good_ids", PackedInt32Array())
	var candidate_efficiencies_all: PackedInt32Array = catalog.get(
		"building_input_candidate_efficiency_q16", PackedInt32Array())
	var good_categories: PackedStringArray = catalog.get(
		"good_category_ids", PackedStringArray())
	var good_substitution_offsets: PackedInt32Array = catalog.get(
		"good_substitution_category_offsets", PackedInt32Array())
	var good_substitution_ids: PackedStringArray = catalog.get(
		"good_substitution_category_ids", PackedStringArray())
	if not bool(input_goods.get("ok", false)) or not bool(output_goods.get("ok", false)) \
			or not bool(production_resources.get("ok", false)):
		return {"ok": false, "reason": "building placement catalog shape invalid"}
	var kinds: PackedInt32Array = catalog.get("building_kinds", PackedInt32Array())
	var quantities: PackedInt64Array = catalog.get(
		"building_production_resource_quantities", PackedInt64Array())
	var modes: PackedInt32Array = catalog.get(
		"building_production_resource_modes", PackedInt32Array())
	var access_modes: PackedInt32Array = catalog.get(
		"building_production_resource_access_modes", PackedInt32Array())
	var family_ids: PackedStringArray = catalog.get(
		"building_upgrade_family_ids", PackedStringArray())
	var family_indices: PackedInt32Array = catalog.get(
		"building_upgrade_family_indices", PackedInt32Array())
	var upgrade_tiers: PackedInt32Array = catalog.get(
		"building_upgrade_tiers", PackedInt32Array())
	var resource_begin := int(production_resources.begin)
	var resource_end := int(production_resources.end)
	if type_id >= kinds.size() or type_id >= family_indices.size() \
			or type_id >= upgrade_tiers.size() \
			or resource_end > quantities.size() or resource_end > modes.size() \
			or resource_end > access_modes.size() or type_id + 1 >= technology_offsets.size() \
			or type_id + 1 >= required_offsets.size():
		return {"ok": false, "reason": "building placement resource columns invalid"}
	var technology_begin := int(technology_offsets[type_id])
	var technology_end := int(technology_offsets[type_id + 1])
	var required_begin := int(required_offsets[type_id])
	var required_end := int(required_offsets[type_id + 1])
	var input_begin := int(input_goods.begin)
	var input_end := int(input_goods.end)
	if required_begin < 0 or required_end < required_begin or required_end > required_tags.size() \
			or technology_begin < 0 or technology_end < technology_begin \
			or technology_end > technology_tags.size() or input_end > input_categories_all.size() \
			or input_end > input_min_levels_all.size() or input_end >= candidate_offsets_all.size() \
			or input_end > input_quantities_all.size() \
			or input_end > input_required_all.size() \
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
		"input_required_q16": input_required_all.slice(input_begin, input_end),
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
		"required_technology_tags": required_tags.slice(required_begin, required_end),
	}

static func _stable_ids_from_catalog_range(catalog: Dictionary, type_id: int, stable_ids: PackedStringArray,
		offset_key: String, index_key: String) -> Dictionary:
	var offsets: PackedInt32Array = catalog.get(offset_key, PackedInt32Array())
	var indices: PackedInt32Array = catalog.get(index_key, PackedInt32Array())
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

static func validate_building_progression_profiles(profiles: Array) -> Dictionary:
	var ids := PackedStringArray()
	var index_by_id := {}
	for profile in profiles:
		var building_id := String(profile.id).strip_edges()
		if building_id.is_empty() or index_by_id.has(building_id):
			return {"ok": false, "reason": "building_progression_id_invalid", "id": building_id}
		index_by_id[building_id] = ids.size()
		ids.append(building_id)
	var chain_ids := PackedStringArray()
	var steps := PackedInt32Array()
	var ranks := PackedInt32Array()
	var display_names := PackedStringArray()
	var roles := PackedStringArray()
	var terminal_reasons := PackedStringArray()
	var predecessor_offsets := PackedInt32Array([0])
	var predecessor_indices := PackedInt32Array()
	var cjk := RegEx.new()
	cjk.compile("[\\x{4e00}-\\x{9fff}]")
	for profile in profiles:
		var building_id := String(profile.id).strip_edges()
		var chain_id := String(profile.industry_chain_id).strip_edges()
		var step := int(profile.progression_step)
		var rank := int(profile.maturity_rank)
		var display_name := String(profile.maturity_display_name).strip_edges()
		var role := String(profile.progression_role).strip_edges()
		var predecessors: PackedStringArray = profile.predecessor_building_ids
		var terminal_reason := String(profile.terminal_reason).strip_edges()
		var active := not chain_id.is_empty() or step != 0 or rank != 0 \
			or not display_name.is_empty() or not role.is_empty() \
			or not predecessors.is_empty() or not terminal_reason.is_empty()
		if not active:
			chain_ids.append("")
			steps.append(0)
			ranks.append(0)
			display_names.append("")
			roles.append("")
			terminal_reasons.append("")
			predecessor_offsets.append(predecessor_indices.size())
			continue
		if chain_id.is_empty() or step <= 0 or rank < 1 or rank > 7 \
				or display_name.is_empty() or cjk.search(display_name) == null \
				or role not in ["entry", "mainline", "specialization", "support", "terminal"]:
			return {"ok": false, "reason": "building_progression_metadata_invalid", "id": building_id}
		if role == "entry" and not predecessors.is_empty():
			return {"ok": false, "reason": "building_progression_entry_has_predecessor", "id": building_id}
		if role != "entry" and predecessors.is_empty():
			return {"ok": false, "reason": "building_progression_predecessor_missing", "id": building_id}
		if role == "terminal" and terminal_reason.is_empty():
			return {"ok": false, "reason": "building_progression_terminal_reason_missing", "id": building_id}
		if role != "terminal" and not terminal_reason.is_empty():
			return {"ok": false, "reason": "building_progression_terminal_reason_unexpected", "id": building_id}
		var predecessor_seen := {}
		for predecessor_value in predecessors:
			var predecessor_id := String(predecessor_value).strip_edges()
			if predecessor_id == building_id or predecessor_seen.has(predecessor_id) \
					or not index_by_id.has(predecessor_id):
				return {"ok": false, "reason": "building_progression_predecessor_invalid", "id": building_id, "predecessor_id": predecessor_id}
			predecessor_seen[predecessor_id] = true
			var predecessor = profiles[int(index_by_id[predecessor_id])]
			if String(predecessor.industry_chain_id).strip_edges() != chain_id \
					or int(predecessor.progression_step) >= step \
					or int(predecessor.maturity_rank) > rank:
				return {"ok": false, "reason": "building_progression_predecessor_order_invalid", "id": building_id, "predecessor_id": predecessor_id,
					"chain": chain_id, "predecessor_chain": String(predecessor.industry_chain_id),
					"step": step, "predecessor_step": int(predecessor.progression_step),
					"rank": rank, "predecessor_rank": int(predecessor.maturity_rank)}
			predecessor_indices.append(int(index_by_id[predecessor_id]))
		chain_ids.append(chain_id)
		steps.append(step)
		ranks.append(rank)
		display_names.append(display_name)
		roles.append(role)
		terminal_reasons.append(terminal_reason)
		predecessor_offsets.append(predecessor_indices.size())
	return {
		"ok": true,
		"building_industry_chain_ids": chain_ids,
		"building_progression_steps": steps,
		"building_maturity_ranks": ranks,
		"building_maturity_display_names": display_names,
		"building_progression_roles": roles,
		"building_progression_predecessor_offsets": predecessor_offsets,
		"building_progression_predecessor_indices": predecessor_indices,
		"building_progression_terminal_reasons": terminal_reasons,
	}

static func _validate_explicit_input_candidates(profile: Resource,
		good_index: Dictionary) -> String:
	var offsets: PackedInt32Array = profile.input_candidate_offsets
	var candidate_ids: PackedStringArray = profile.input_candidate_good_ids
	var efficiencies: PackedInt32Array = profile.input_candidate_efficiency_q16
	var has_explicit_candidates := offsets.size() > 1 \
		or not candidate_ids.is_empty() or not efficiencies.is_empty()
	if not has_explicit_candidates:
		return ""
	if offsets.size() != profile.input_good_ids.size() + 1 or offsets[0] != 0 \
			or candidate_ids.size() != efficiencies.size() \
			or offsets[-1] != candidate_ids.size():
		return "building explicit input candidate columns mismatch"
	for offset_idx in range(1, offsets.size()):
		if offsets[offset_idx] < offsets[offset_idx - 1]:
			return "building explicit input candidate offsets invalid"
	var configured_categories: PackedStringArray = profile.input_category_ids
	for input_idx in range(profile.input_good_ids.size()):
		var begin := int(offsets[input_idx])
		var end := int(offsets[input_idx + 1])
		if end <= begin:
			continue
		var category_id := String(configured_categories[input_idx]) \
			if not configured_categories.is_empty() else ""
		if category_id != "":
			return "building input cannot combine category and explicit candidates"
		var preferred_id := String(profile.input_good_ids[input_idx])
		var seen_candidates := {}
		for candidate_idx in range(begin, end):
			var candidate_id := String(candidate_ids[candidate_idx])
			var efficiency := int(efficiencies[candidate_idx])
			if not good_index.has(candidate_id) or seen_candidates.has(candidate_id) \
					or efficiency <= 0 or efficiency > 262144:
				return "invalid building explicit input candidate"
			seen_candidates[candidate_id] = true
		if not seen_candidates.has(preferred_id):
			return "preferred building input missing from explicit candidates"
	return ""


## Compiles the material/resource prerequisites for every direct building
## technology branch.  A branch is usable only when its own technology and
## required tags are completed, and every dependency group has at least one
## completed discovery/production tag.  Input candidate alternatives share one
## group, so a building is not incorrectly forced to unlock every substitute.

static func _append_building_goods(ids: PackedStringArray, quantities: PackedInt64Array,
		good_index: Dictionary, out_ids: PackedInt32Array,
		out_quantities: PackedInt64Array) -> String:
	if ids.size() != quantities.size():
		return "building good columns mismatch"
	for i in range(ids.size()):
		var stable_id := String(ids[i])
		if not good_index.has(stable_id) or int(quantities[i]) <= 0:
			return "invalid building good"
		out_ids.append(int(good_index[stable_id]))
		out_quantities.append(int(quantities[i]))
	return ""


## Construction BOM rows are authoring weights, not independent hard slots.
## Compile every building to one effective-quantity group whose candidates are
## the stable union of every authored row. Any mixture can therefore satisfy
## the total bill, matching household food-basket substitution semantics.

static func _append_pooled_construction(authored_goods: PackedInt32Array,
		authored_quantities: PackedInt64Array,
		authored_candidate_offsets: PackedInt32Array,
		authored_candidate_goods: PackedInt32Array,
		authored_candidate_efficiencies: PackedInt32Array,
		out_goods: PackedInt32Array, out_quantities: PackedInt64Array,
		out_candidate_offsets: PackedInt32Array,
		out_candidate_goods: PackedInt32Array,
		out_candidate_efficiencies: PackedInt32Array) -> String:
	if authored_goods.is_empty() \
			or authored_goods.size() != authored_quantities.size() \
			or authored_candidate_offsets.size() != authored_goods.size() + 1 \
			or authored_candidate_goods.size() != authored_candidate_efficiencies.size():
		return "invalid pooled construction columns"
	var total_quantity := 0
	for quantity in authored_quantities:
		if int(quantity) <= 0 or total_quantity > 9223372036854775807 - int(quantity):
			return "pooled construction quantity overflow"
		total_quantity += int(quantity)
	var candidate_position := {}
	for candidate_index in range(authored_candidate_goods.size()):
		var good_id := int(authored_candidate_goods[candidate_index])
		var efficiency := int(authored_candidate_efficiencies[candidate_index])
		if candidate_position.has(good_id):
			var position := int(candidate_position[good_id])
			# A material admitted through several authored roles keeps its most
			# efficient valid conversion into generic construction quantity.
			out_candidate_efficiencies[position] = maxi(
				int(out_candidate_efficiencies[position]), efficiency)
			continue
		candidate_position[good_id] = out_candidate_goods.size()
		out_candidate_goods.append(good_id)
		out_candidate_efficiencies.append(efficiency)
	out_goods.append(int(authored_goods[0]))
	out_quantities.append(total_quantity)
	out_candidate_offsets.append(out_candidate_goods.size())
	return ""


## Zero-bill lots: merchant-style services, or stone-age construction
## collectors tagged `starter.construction` whose daily inputs are empty or
## all-soft complements. Industrial buildings and later collectors still need
## an explicit bill.

static func allows_zero_cost_construction(profile: Resource) -> bool:
	if profile == null or int(profile.construction_days) != 0 \
			or not profile.construction_good_ids.is_empty():
		return false
	var kind := String(profile.building_kind)
	if kind == "service" or kind == "state":
		return true
	if kind != "collector" or not _daily_inputs_are_all_soft(profile):
		return false
	for tag in profile.semantic_tags:
		if String(tag).strip_edges() == "starter.construction":
			return true
	return false

static func _daily_inputs_are_all_soft(profile: Resource) -> bool:
	if profile.input_good_ids.is_empty():
		return true
	var required: PackedInt32Array = profile.input_required_q16
	if required.size() != profile.input_good_ids.size():
		return false
	for required_q16 in required:
		if int(required_q16) >= Q16_ONE:
			return false
	return true

static func _append_construction_candidates(profile: Resource,
		good_index: Dictionary, category_good_indices: Dictionary,
		good_quality_levels: PackedInt32Array,
		good_efficiencies_q16: PackedInt32Array, out_offsets: PackedInt32Array,
		out_goods: PackedInt32Array, out_efficiencies: PackedInt32Array) -> String:
	var groups: PackedStringArray = profile.construction_good_ids
	var explicit_offsets: PackedInt32Array = profile.construction_candidate_offsets
	var explicit_goods: PackedStringArray = profile.construction_candidate_good_ids
	var explicit_efficiencies: PackedInt32Array = profile.construction_candidate_efficiency_q16
	var categories: PackedStringArray = profile.construction_category_ids
	var min_levels: PackedInt32Array = profile.construction_min_quality_levels
	var has_explicit := explicit_offsets.size() > 1 \
		or not explicit_goods.is_empty() or not explicit_efficiencies.is_empty()
	if not categories.is_empty() and categories.size() != groups.size():
		return "building construction category columns mismatch"
	if not min_levels.is_empty() and min_levels.size() != groups.size():
		return "building construction quality columns mismatch"
	if has_explicit:
		if explicit_offsets.size() != groups.size() + 1 \
			or explicit_offsets.is_empty() or explicit_offsets[0] != 0 \
			or explicit_goods.size() != explicit_efficiencies.size() \
			or explicit_offsets[-1] != explicit_goods.size():
			return "building construction candidate columns mismatch"
		for offset_index in range(1, explicit_offsets.size()):
			if explicit_offsets[offset_index] < explicit_offsets[offset_index - 1]:
				return "building construction candidate offsets invalid"
	for group_index in range(groups.size()):
		var preferred := String(groups[group_index])
		if not good_index.has(preferred):
			return "invalid construction good"
		var category_id := String(categories[group_index]) if not categories.is_empty() else ""
		var min_level := int(min_levels[group_index]) if not min_levels.is_empty() else 0
		if min_level < 0:
			return "negative construction quality"
		var begin := int(explicit_offsets[group_index]) if has_explicit else 0
		var end := int(explicit_offsets[group_index + 1]) if has_explicit else 0
		if end > begin:
			if category_id != "":
				return "building construction cannot combine category and explicit candidates"
			var seen := {}
			var preferred_seen := false
			for candidate_index in range(begin, end):
				var candidate_id := String(explicit_goods[candidate_index])
				var efficiency := int(explicit_efficiencies[candidate_index])
				if not good_index.has(candidate_id) or seen.has(candidate_id) \
						or efficiency <= 0 or efficiency > 4 * Q16_ONE:
					return "invalid construction candidate"
				seen[candidate_id] = true
				preferred_seen = preferred_seen or candidate_id == preferred
				out_goods.append(int(good_index[candidate_id]))
				out_efficiencies.append(efficiency)
			if not preferred_seen:
				return "construction candidate group must include preferred good"
		elif category_id == "":
			out_goods.append(int(good_index[preferred]))
			out_efficiencies.append(Q16_ONE)
		else:
			# A category group expands to every member whose production quality
			# clears the gate. The preferred good stays in the group so the
			# runtime keeps its cost tie-break and the content-binding summary
			# still sees the authored material.
			var preferred_index := int(good_index[preferred])
			var members: PackedInt32Array = category_good_indices.get(
				category_id, PackedInt32Array())
			var preferred_expanded := false
			for good_idx in members:
				if int(good_quality_levels[good_idx]) < min_level:
					continue
				preferred_expanded = preferred_expanded or int(good_idx) == preferred_index
				out_goods.append(int(good_idx))
				out_efficiencies.append(int(good_efficiencies_q16[good_idx]))
			if not preferred_expanded:
				return "construction category must include preferred good"
		if out_offsets[-1] == out_goods.size():
			return "building construction category has no candidates"
		out_offsets.append(out_goods.size())
	return ""
