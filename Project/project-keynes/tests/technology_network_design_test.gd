extends SceneTree

const NETWORK_PATH := "res://data/technology/technology_network.json"
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")
const EXPECTED_LEGACY_IDS := 361
const EXPECTED_FAMILIES := 24
const EXPECTED_CANDIDATES_PER_ERA := 8
const EXPECTED_CANDIDATE_REQUIRED := 4


func _init() -> void:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	assert(file != null)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary)
	var data: Dictionary = parsed
	assert(int(data.get("schema_version", 0)) == 2)
	var eras: Array = data.get("eras", [])
	var domains: Array = data.get("domains", [])
	var backbones: Array = data.get("backbones", [])
	var families: Array = data.get("branch_families", [])
	var nodes: Array = data.get("nodes", [])
	assert(eras.size() == 11)
	assert(domains.size() == 4)
	assert(backbones.size() == 4)
	assert(families.size() == EXPECTED_FAMILIES)
	assert(nodes.size() >= EXPECTED_LEGACY_IDS)
	assert(not data.has("specialist_lanes"))

	var node_by_id := {}
	var era_order := {}
	var milestone_ids := {}
	var family_ids := {}
	var backbone_ids := {}
	for backbone_value in backbones:
		backbone_ids[String((backbone_value as Dictionary).get("id", ""))] = true
	for family_value in families:
		var family: Dictionary = family_value
		var family_id := String(family.get("id", ""))
		assert(not family_id.is_empty() and not family_ids.has(family_id))
		family_ids[family_id] = true
	for era_index in range(eras.size()):
		var era: Dictionary = eras[era_index]
		var era_id := String(era.get("id", ""))
		var milestone_id := String(era.get("milestone_id", ""))
		var entry_id := String(era.get("entry_milestone_id", ""))
		var candidates: Array = era.get("milestone_candidate_ids", [])
		assert(not era_order.has(era_id))
		era_order[era_id] = era_index
		milestone_ids[milestone_id] = true
		assert(candidates.size() == EXPECTED_CANDIDATES_PER_ERA)
		assert(int(era.get("candidate_required", 0)) == EXPECTED_CANDIDATE_REQUIRED)
		assert(entry_id.is_empty() if era_index == 0 else entry_id == String((eras[era_index - 1] as Dictionary).milestone_id))
		var unique_candidates := {}
		for candidate_value in candidates:
			var candidate_id := String(candidate_value)
			assert(not unique_candidates.has(candidate_id))
			unique_candidates[candidate_id] = true

	for node_value in nodes:
		var node: Dictionary = node_value
		var technology_id := String(node.get("id", ""))
		assert(technology_id.begins_with("tech.") and not node_by_id.has(technology_id))
		node_by_id[technology_id] = node
		assert(not node.has("main_lane"))
		assert(not node.has("same_lane_successor_ids"))
		assert(not node.has("is_milestone_candidate"))
		var branch_family_id := String(node.get("branch_family_id", ""))
		assert(family_ids.has(branch_family_id) or backbone_ids.has(branch_family_id))
		assert(not String(node.get("reveal_category", "")).is_empty())
		assert(not String(node.get("reveal_summary", "")).is_empty())
		assert(not String(node.get("network_role", "")).is_empty())
		assert(not String(node.get("node_role", "")).is_empty())
		assert(node.get("hard_prerequisite_ids", []) is Array)
		assert(node.get("prerequisite_rationales", []) is Array)
		assert((node.hard_prerequisite_ids as Array).size() == (node.prerequisite_rationales as Array).size())
		assert(node.get("branch_successor_rationales", []) is Array)
		assert((node.branch_successor_ids as Array).size() == (node.branch_successor_rationales as Array).size())
		assert(node.get("application_target_rationales", []) is Array)
		assert((node.application_target_ids as Array).size() == (node.application_target_rationales as Array).size())
		_validate_condition(node.get("reveal_condition", {}))
		_validate_condition(node.get("research_condition", {}))
		if not bool(node.get("is_milestone", false)) and not bool(node.get("is_starting", false)) \
				and not bool(node.get("is_starter_eligible", false)):
			var required_terms: Array = node.get("modifier_terms", [])
			assert(required_terms.size() >= 1 and required_terms.size() <= 6,
				"formal technology must have 1-6 Modifier terms: %s" % technology_id)
			assert(String(node.get("effect_summary", "")) != "提供后续科技与内容的知识基础")
		for term_value in node.get("modifier_terms", []):
			var term: Dictionary = term_value
			assert(not String(term.get("effect_class", "")).is_empty())
			assert(not String(term.get("effect_rationale", "")).is_empty())
			assert(String(term.get("implementation_status", "")) == "runtime_consumed")
			assert(not String(term.get("runtime_consumer", "")).is_empty())
			for binding_value in node.get("expected_bindings", []):
				var binding: Dictionary = binding_value
				var subject_kind := String(term.get("subject_kind", ""))
				var matching_binding_kind: int = int({"good": 1, "building": 2, "resource": 3}.get(
					subject_kind, -1))
				assert(matching_binding_kind < 0 \
					or int(binding.get("kind", 0)) != matching_binding_kind \
					or String(term.get("subject_id", "")) != String(binding.get("id", "")),
					"%s unlocks and modifies %s in the same technology" % [
						String(node.id), String(term.get("subject_id", ""))])
		_assert_effect_summary_matches_structured_effects(node)

	var maximum_hard_indegree := 0
	var hard_successor_counts := {}
	for technology_id in node_by_id:
		hard_successor_counts[technology_id] = 0
	for node_value in nodes:
		var node: Dictionary = node_value
		var technology_id := String(node.id)
		var technology_era := int(era_order[String(node.era_id)])
		var hard: Array = node.hard_prerequisite_ids
		maximum_hard_indegree = maxi(maximum_hard_indegree, hard.size())
		for prerequisite_index in range(hard.size()):
			var prerequisite_id := String(hard[prerequisite_index])
			assert(node_by_id.has(prerequisite_id), "%s missing prerequisite %s" % [technology_id, prerequisite_id])
			assert(not milestone_ids.has(prerequisite_id), "%s retains node-level milestone edge" % technology_id)
			assert(int(era_order[String((node_by_id[prerequisite_id] as Dictionary).era_id)]) <= technology_era)
			assert(not String((node.prerequisite_rationales as Array)[prerequisite_index]).is_empty())
			assert(not String((node.prerequisite_rationales as Array)[prerequisite_index]).contains(
				"不可替代的理论、材料、工艺或组织基础"))
			hard_successor_counts[prerequisite_id] = int(hard_successor_counts[prerequisite_id]) + 1
		var alternative_ids := PackedStringArray()
		_collect_technology_atoms(node.research_condition as Dictionary, alternative_ids)
		for alternative_id in alternative_ids:
			assert(not (node.hard_prerequisite_ids as Array).has(String(alternative_id)))
		for successor_value in node.branch_successor_ids:
			var successor_id := String(successor_value)
			assert(node_by_id.has(successor_id))
			assert(String((node_by_id[successor_id] as Dictionary).branch_family_id) == String(node.branch_family_id))
		for application_value in node.application_target_ids:
			var application_id := String(application_value)
			assert(node_by_id.has(application_id))
	_assert_acyclic(node_by_id)
	for node_value in nodes:
		var node: Dictionary = node_value
		if int(hard_successor_counts[String(node.id)]) == 0 \
				and (node.branch_successor_ids as Array).is_empty() \
				and (node.application_target_ids as Array).is_empty():
			assert(not String(node.get("terminal_reason", "")).is_empty())
	var public_backbone_ids := {}
	for era_value in eras:
		for public_candidate_value in ((era_value as Dictionary).milestone_candidate_ids as Array).slice(0, 4):
			public_backbone_ids[String(public_candidate_value)] = true
	for era_value in eras:
		var public_candidates: Array = (era_value as Dictionary).milestone_candidate_ids
		for public_candidate_value in public_candidates.slice(0, 4):
			var public_node: Dictionary = node_by_id[String(public_candidate_value)]
			assert((public_node.reveal_condition as Dictionary).is_empty())
			assert((public_node.research_condition as Dictionary).is_empty())
			for prerequisite_value in public_node.hard_prerequisite_ids:
				assert(public_backbone_ids.has(String(prerequisite_value)))
	assert(maximum_hard_indegree >= 5)

	var candidate_edges := 0
	var alternative_edges := 0
	var application_edges := 0
	for edge_value in data.get("visual_edges", []):
		var edge: Dictionary = edge_value
		match String(edge.get("kind", "")):
			"milestone_candidate": candidate_edges += 1
			"alternative": alternative_edges += 1
			"application": application_edges += 1
			"hard": pass
			_: assert(false, "unknown visual edge kind")
	assert(candidate_edges == 88)
	assert(alternative_edges > 0)
	assert(application_edges > 0)
	var route_count_by_family := {}
	var mixed_count_by_family := {}
	for family_id in family_ids:
		route_count_by_family[String(family_id)] = 0
		mixed_count_by_family[String(family_id)] = 0
	for node_value in nodes:
		var node: Dictionary = node_value
		var condition: Dictionary = node.get("research_condition", {})
		var family_id := String(node.get("branch_family_id", ""))
		if condition.is_empty() or not family_ids.has(family_id):
			continue
		route_count_by_family[family_id] = int(route_count_by_family[family_id]) + 1
		if _condition_has_signal(condition):
			mixed_count_by_family[family_id] = int(mixed_count_by_family[family_id]) + 1
	for family_id in family_ids:
		assert(int(route_count_by_family[String(family_id)]) >= 3,
			"%s lacks three alternative route nodes" % family_id)
		assert(int(mixed_count_by_family[String(family_id)]) >= 1,
			"%s lacks a mixed evidence route" % family_id)

	_assert_prerequisites(node_by_id, "tech.property_cadastre", [
		"tech.cartography", "tech.long_term_leases"])
	_assert_no_token(node_by_id["tech.property_cadastre"], "maize")
	_assert_prerequisites(node_by_id, "tech.atmospheric_engine", [
		"tech.mine_drainage", "tech.mechanical_workshops"])
	assert(not ((node_by_id["tech.atmospheric_engine"] as Dictionary).modifier_terms as Array).is_empty())
	_assert_binding(node_by_id, "tech.atmospheric_engine", "building", "atmospheric_engine_workshop")
	_assert_prerequisites(node_by_id, "tech.geographic_information_systems", [
		"tech.cartography", "tech.digital_computing"])
	_assert_no_prerequisite(node_by_id, "tech.geographic_information_systems", "tech.plastics_engineering")
	assert(int(((node_by_id["tech.geographic_information_systems"] as Dictionary).research_condition as Dictionary).operator) == ResearchConditionScript.Operator.ANY_OF)
	assert(not ((node_by_id["tech.geographic_information_systems"] as Dictionary).modifier_terms as Array).is_empty())
	_assert_prerequisites(node_by_id, "tech.scientific_classification", ["tech.natural_philosophy"])
	assert(int(((node_by_id["tech.scientific_classification"] as Dictionary).research_condition as Dictionary).operator) == ResearchConditionScript.Operator.AT_LEAST)
	_assert_no_token(node_by_id["tech.scientific_classification"], "detergent")
	_assert_binding(node_by_id, "tech.petrochemical_industry", "good", "detergent")
	_assert_binding(node_by_id, "tech.petrochemical_industry", "building", "detergent_plant")
	_assert_exact_prerequisites(node_by_id, "tech.software_engineering", [
		"tech.digital_computing", "tech.information_theory"])
	_assert_exact_prerequisites(node_by_id, "tech.synthetic_fiber_engineering", [
		"tech.industrial_chemistry", "tech.petrochemical_industry", "tech.textile_machinery"])
	_assert_exact_prerequisites(node_by_id, "tech.steam_sawmilling", [
		"tech.timber_sawing", "tech.steam_power", "tech.machine_tools"])
	_assert_exact_prerequisites(node_by_id, "tech.steam_pumping", [
		"tech.mine_drainage", "tech.steam_power", "tech.machine_tools"])
	_assert_exact_prerequisites(node_by_id, "tech.corporate_management", [
		"tech.managerial_hierarchy", "tech.double_entry_bookkeeping", "tech.industrial_statistics"])
	_assert_no_prerequisite(node_by_id, "tech.software_engineering", "tech.petrochemical_cracking")
	_assert_no_prerequisite(node_by_id, "tech.synthetic_fiber_engineering", "tech.corporate_management")
	_assert_no_prerequisite(node_by_id, "tech.steam_sawmilling", "tech.learned_societies")
	assert(String((node_by_id["tech.learned_societies"] as Dictionary).branch_family_id) == "branch.natural_history")
	assert(String((node_by_id["tech.electrochemistry"] as Dictionary).branch_family_id) == "branch.industrial_chemistry")
	_assert_binding(node_by_id, "tech.steam_sawmilling", "building", "method_lumber_plant_r6")
	_assert_binding(node_by_id, "tech.estate_cereal_management", "building", "landed_estate")
	_assert_binding(node_by_id, "tech.estate_cereal_management", "building", "method_wheat_farm_r3")
	_assert_binding(node_by_id, "tech.estate_cereal_management", "building", "method_wheat_farm_r5")
	_assert_binding(node_by_id, "tech.tenant_paddy_management", "building", "method_rice_collector_r3")
	_assert_binding(node_by_id, "tech.estate_paddy_management", "building", "method_rice_collector_r5")
	_assert_binding(node_by_id, "tech.estate_plantation_management", "building", "method_flax_collector_r3")
	_assert_binding(node_by_id, "tech.estate_plantation_management", "building", "method_flax_collector_r5")
	var cereal_stats := {
		"country.output.good.grain_factor": true,
		"country.output.good.wheat_grain_factor": true,
		"country.output.good.rice_grain_factor": true,
		"country.output.good.corn_grain_factor": true,
	}
	var threshing_terms: Array = (node_by_id["tech.grain_threshing"] as Dictionary).modifier_terms
	assert(threshing_terms.size() == cereal_stats.size())
	for term_value in threshing_terms:
		var term: Dictionary = term_value
		assert(cereal_stats.has(String(term.stat)))
		assert(is_equal_approx(float(term.value), 0.18))
		assert(String(term.subject_display_name) == "全部谷物")
	for node_value in nodes:
		for term_value in (node_value as Dictionary).modifier_terms:
			assert(String((term_value as Dictionary).stat) !=
				"country.output.family.field_crop_farming_factor")
	for institutional_id in ["tech.estate_accounting", "tech.serf_obligations",
			"tech.estate_cereal_management", "tech.estate_paddy_management",
			"tech.estate_plantation_management", "tech.long_term_leases"]:
		for term_value in (node_by_id[institutional_id] as Dictionary).modifier_terms:
			assert(not String((term_value as Dictionary).get("stat", "")).contains(
				"landed_estate"), "%s retains a corn-only estate modifier" % institutional_id)
	for oceanic_id in ["tech.magnetic_navigation", "tech.oceanic_navigation",
			"tech.oceanic_ship_design", "tech.coastal_shipyards",
			"tech.oceanic_provisioning"]:
		var reveal_json := JSON.stringify((node_by_id[oceanic_id] as Dictionary).reveal_condition)
		assert(reveal_json.contains("landform.coast"))
		assert(reveal_json.contains("contact.maritime_vessel"))
		assert(not reveal_json.contains("contact.maize")
			and not reveal_json.contains("contact.tin"))

	var unlock_only_count := 0
	for node_value in nodes:
		var node: Dictionary = node_value
		if (node.modifier_terms as Array).is_empty() and int(node.get("cost_points", 0)) > 0 \
				and not bool(node.get("is_milestone", false)) \
				and not bool(node.get("is_starting", false)) \
				and not bool(node.get("is_starter_eligible", false)):
			unlock_only_count += 1
		_assert_no_unlock_and_same_target_modifier(node)
	assert(unlock_only_count == 0)
	var maize_terms: Array = (node_by_id["tech.maize_propagation"] as Dictionary).modifier_terms
	assert(maize_terms.size() >= 1 and maize_terms.size() <= 6)
	assert(String((maize_terms[0] as Dictionary).stat) == "country.output.good.corn_grain_factor")
	assert(is_equal_approx(float((maize_terms[0] as Dictionary).value), 0.25))
	assert(((node_by_id["tech.maize_propagation"] as Dictionary).expected_bindings as Array).is_empty())
	print("[PASS] technology network schema v2: %d nodes / %d families / max indegree %d" % [
		nodes.size(), families.size(), maximum_hard_indegree])
	quit(0)


func _validate_condition(condition_value: Variant) -> void:
	assert(condition_value is Dictionary)
	var condition: Dictionary = condition_value
	if condition.is_empty():
		return
	if condition.has("kind"):
		var kind := int(condition.get("kind", -1))
		assert(kind in [ResearchPredicateScript.Kind.TECH_COMPLETED,
			ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT])
		assert(not String(condition.get("id", "")).is_empty())
		return
	var operator := int(condition.get("operator", -1))
	assert(operator in [ResearchConditionScript.Operator.ALL_OF,
		ResearchConditionScript.Operator.ANY_OF,
		ResearchConditionScript.Operator.AT_LEAST,
		ResearchConditionScript.Operator.NOT])
	var children: Array = condition.get("children", [])
	assert(not children.is_empty())
	if operator == ResearchConditionScript.Operator.NOT:
		assert(children.size() == 1)
	if operator == ResearchConditionScript.Operator.AT_LEAST:
		assert(int(condition.get("required_count", 0)) >= 1
			and int(condition.required_count) <= children.size())
	for child in children:
		_validate_condition(child)


func _collect_technology_atoms(condition: Dictionary, out: PackedStringArray) -> void:
	if condition.is_empty():
		return
	if condition.has("kind"):
		if int(condition.get("kind", -1)) == ResearchPredicateScript.Kind.TECH_COMPLETED:
			out.append(String(condition.get("id", "")))
		return
	for child_value in condition.get("children", []):
		if child_value is Dictionary:
			_collect_technology_atoms(child_value as Dictionary, out)


func _condition_has_signal(condition: Dictionary) -> bool:
	if condition.is_empty():
		return false
	if condition.has("kind"):
		return int(condition.get("kind", -1)) in [
			ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT]
	for child_value in condition.get("children", []):
		if child_value is Dictionary and _condition_has_signal(child_value as Dictionary):
			return true
	return false


func _assert_acyclic(node_by_id: Dictionary) -> void:
	var state := {}
	for technology_id_value in node_by_id.keys():
		_assert_acyclic_visit(String(technology_id_value), node_by_id, state)


func _assert_acyclic_visit(technology_id: String, node_by_id: Dictionary,
		state: Dictionary) -> void:
	var current := int(state.get(technology_id, 0))
	assert(current != 1, "hard prerequisite cycle at %s" % technology_id)
	if current == 2:
		return
	state[technology_id] = 1
	for prerequisite_value in (node_by_id[technology_id] as Dictionary).hard_prerequisite_ids:
		_assert_acyclic_visit(String(prerequisite_value), node_by_id, state)
	state[technology_id] = 2


func _assert_prerequisites(node_by_id: Dictionary, technology_id: String,
		expected_ids: Array) -> void:
	var hard: Array = (node_by_id[technology_id] as Dictionary).hard_prerequisite_ids
	for expected_id in expected_ids:
		assert(hard.has(expected_id), "%s missing %s" % [technology_id, expected_id])


func _assert_exact_prerequisites(node_by_id: Dictionary, technology_id: String,
		expected_ids: Array) -> void:
	var hard: Array = (node_by_id[technology_id] as Dictionary).hard_prerequisite_ids
	assert(hard == expected_ids, "%s prerequisites differ: %s" % [technology_id, hard])


func _assert_no_prerequisite(node_by_id: Dictionary, technology_id: String,
		forbidden_id: String) -> void:
	assert(not ((node_by_id[technology_id] as Dictionary).hard_prerequisite_ids as Array).has(forbidden_id))


func _assert_binding(node_by_id: Dictionary, technology_id: String,
		binding_type: String, binding_id: String) -> void:
	var expected_kind: int = int({"good": 1, "building": 2, "profession": 3}.get(binding_type, -1))
	for binding_value in (node_by_id[technology_id] as Dictionary).expected_bindings:
		var binding: Dictionary = binding_value
		if int(binding.get("kind", -1)) == expected_kind and String(binding.get("id", "")) == binding_id:
			return
	assert(false, "%s missing %s:%s" % [technology_id, binding_type, binding_id])


func _assert_no_token(node_value: Variant, forbidden: String) -> void:
	var node: Dictionary = node_value
	assert(not JSON.stringify(node.get("expected_bindings", [])).contains(forbidden))
	assert(not JSON.stringify(node.get("modifier_terms", [])).contains(forbidden))


func _assert_no_unlock_and_same_target_modifier(node: Dictionary) -> void:
	var unlocked_buildings := {}
	for binding_value in node.expected_bindings:
		var binding: Dictionary = binding_value
		if int(binding.get("kind", 0)) == 2:
			unlocked_buildings[String(binding.get("id", ""))] = true
	for term_value in node.modifier_terms:
		var subject_id := String((term_value as Dictionary).get("subject_id", ""))
		assert(not unlocked_buildings.has(subject_id), "%s unlocks and buffs %s" % [node.id, subject_id])


func _assert_effect_summary_matches_structured_effects(node: Dictionary) -> void:
	var summary := String(node.get("effect_summary", ""))
	assert(not summary.is_empty(), "missing effect summary: %s" % node.id)
	for forbidden in ["开放通用职业阶层岗位", "开放科技职业阶层岗位",
			"开放农民阶层岗位", "适应温度条件", "需要河流地块条件"]:
		assert(not summary.contains(forbidden), "%s retains generated summary filler" % node.id)
	var content_effects: Array = node.get("content_effects", [])
	var modifier_terms: Array = node.get("modifier_terms", [])
	for effect_value in content_effects:
		var effect: Dictionary = effect_value
		if String(effect.get("operation", "")) == "unlock":
			assert(summary.contains(String(effect.get("display_name", effect.get("id", "")))),
				"%s summary omits direct unlock" % node.id)
	for term_value in modifier_terms:
		var term: Dictionary = term_value
		var subject := String(term.get("subject_display_name", ""))
		if not subject.is_empty():
			assert(summary.contains(subject), "%s summary omits modifier target" % node.id)
	if content_effects.is_empty() and modifier_terms.is_empty():
		assert(summary == "完成时代里程碑并开放下一时代" if bool(node.get(
			"is_milestone", false)) else "",
			"%s summary claims an unauthored effect" % node.id)
