extends SceneTree

# Deterministic schema-v2 normalizer and validator. The network JSON is the
# sole authoring source: this tool never invents prerequisites, branches,
# milestone candidates, application links, or Modifier effects.

const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")

const NETWORK_PATH := "res://data/technology/technology_network.json"
const REPORT_PATH := "res://tools/technology_tree/technology_network_v2_audit.md"
const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
	"steam", "electrical", "atomic", "information", "intelligent",
]
const ALLOWED_REVEAL_CATEGORIES := [
	"general_knowledge", "environment_observation", "practice_diffusion", "composite_science",
]
const ALLOWED_EDGE_KINDS := [
	"hard", "alternative", "application", "milestone_candidate",
]
const MODIFIER_SUBJECT_NAMES := {
	"country.climate.cold_stress_factor": "寒冷损失",
	"country.climate.drought_loss_factor": "旱灾损失",
	"country.climate.flood_loss_factor": "洪灾损失",
	"country.climate.heat_stress_factor": "热害损失",
	"country.construction.cost_factor": "国家建设成本",
	"country.output.agriculture_factor": "农业部门产出",
	"country.output.energy_factor": "能源部门产出",
	"country.output.extractive_factor": "采掘部门产出",
	"country.output.knowledge_factor": "知识部门产出",
	"country.output.manufacturing_factor": "制造部门产出",
	"country.research.engineering_efficiency": "工程领域研究效率",
	"country.research.science_efficiency": "科学领域研究效率",
	"country.research.society_efficiency": "社会领域研究效率",
	"country.trade.speed_factor": "贸易速度",
}


func _init() -> void:
	var payload := _read_payload()
	if payload.is_empty():
		quit(1)
		return
	var check_only := OS.get_cmdline_user_args().has("--check")
	var summaries_changed := _normalize_effect_summaries(payload)
	if check_only and summaries_changed:
		push_error("technology_effect_summaries_not_normalized")
		quit(1)
		return
	var validation := _validate(payload)
	if not bool(validation.get("ok", false)):
		push_error(String(validation.get("reason", "technology_network_v2_invalid")))
		quit(1)
		return
	var rebuilt_edges := _build_visual_edges(payload)
	var authored_edges: Array = payload.get("visual_edges", [])
	if check_only and JSON.stringify(authored_edges) != JSON.stringify(rebuilt_edges):
		push_error("technology_visual_edges_not_normalized")
		quit(1)
		return
	payload["visual_edges"] = rebuilt_edges
	var report := _audit_report(payload, validation)
	if not check_only:
		_write_json(payload)
		_write_text(REPORT_PATH, report)
	print("[PASS] technology schema v2: %d nodes / %d hard / %d alternative / %d milestone candidates" % [
		(payload.nodes as Array).size(), int(validation.hard_edges),
		int(validation.alternative_edges), int(validation.milestone_candidate_edges)])
	quit(0)


func _normalize_effect_summaries(payload: Dictionary) -> bool:
	var changed := false
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		var summary := _effect_summary(node)
		if String(node.get("effect_summary", "")) != summary:
			node["effect_summary"] = summary
			changed = true
	return changed


func _effect_summary(node: Dictionary) -> String:
	var parts := PackedStringArray()
	var seen := {}
	for effect_value in node.get("content_effects", []):
		var effect: Dictionary = effect_value
		if String(effect.get("operation", "")) != "unlock":
			continue
		var display_name := String(effect.get("display_name", effect.get("id", "")))
		var prefix := ""
		match String(effect.get("kind", "")):
			"building": prefix = "解锁建筑"
			"good": prefix = "解锁物资"
			"resource": prefix = "可利用资源"
			_: continue
		var text := "%s：%s" % [prefix, display_name]
		if not seen.has(text):
			seen[text] = true
			parts.append(text)
	for term_value in node.get("modifier_terms", []):
		var term: Dictionary = term_value
		var stat := String(term.get("stat", ""))
		var subject := String(term.get("subject_display_name", ""))
		if subject.is_empty():
			subject = String(MODIFIER_SUBJECT_NAMES.get(stat, stat))
		if stat.begins_with("country.output.building.") \
				or stat.begins_with("country.output.family.") \
				or stat.begins_with("country.output.good.") \
				or stat.begins_with("country.output.terrain.") \
				or stat.begins_with("country.output.landform."):
			subject += "产出"
		var text := "%s %s" % [subject, _modifier_delta(term)]
		if not seen.has(text):
			seen[text] = true
			parts.append(text)
	if parts.is_empty():
		return "完成时代里程碑并开放下一时代" if bool(node.get(
			"is_milestone", false)) else "提供后续科技与内容的知识基础"
	return "；".join(parts)


func _modifier_delta(term: Dictionary) -> String:
	var operation := int(term.get("operation", 0))
	var value := float(term.get("value", 0.0))
	var delta := value
	match operation:
		1: delta = -value
		2: delta = value - 1.0
		3: delta = 1.0 / value - 1.0 if not is_zero_approx(value) else 0.0
	var percent := delta * 100.0
	var amount := ("%.1f" % absf(percent)).rstrip("0").rstrip(".")
	return "%s%s%%" % ["+" if percent >= 0.0 else "-", amount]


func _read_payload() -> Dictionary:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	if file == null:
		push_error("technology_network_missing")
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		push_error("technology_network_json_invalid")
		return {}
	return parsed as Dictionary


func _validate(payload: Dictionary) -> Dictionary:
	if int(payload.get("schema_version", 0)) != 2:
		return _fail("technology_network_schema_version_invalid")
	var eras: Array = payload.get("eras", [])
	var domains: Array = payload.get("domains", [])
	var backbones: Array = payload.get("backbones", [])
	var families: Array = payload.get("branch_families", [])
	var nodes: Array = payload.get("nodes", [])
	if eras.size() != 11 or domains.size() != 4 or backbones.size() != 4 \
			or families.size() != 24 or nodes.size() < 361:
		return _fail("technology_network_shape_invalid")
	if payload.has("specialist_lanes"):
		return _fail("technology_legacy_lane_metadata_present")
	var era_index := {}
	var milestone_by_era := {}
	var candidate_ids := {}
	for index in range(eras.size()):
		var era: Dictionary = eras[index]
		var era_id := String(era.get("id", ""))
		if era_id != ERA_IDS[index]:
			return _fail("technology_era_order_invalid")
		var milestone_id := String(era.get("milestone_id", ""))
		var entry_id := String(era.get("entry_milestone_id", ""))
		var candidates: Array = era.get("milestone_candidate_ids", [])
		if milestone_id.is_empty() or candidates.size() != 8 \
				or int(era.get("candidate_required", 0)) != 4:
			return _fail("technology_era_milestone_contract_invalid:%s" % era_id)
		if (index == 0 and not entry_id.is_empty()) or (index > 0 and entry_id != String(
			(eras[index - 1] as Dictionary).get("milestone_id", ""))):
			return _fail("technology_era_entry_contract_invalid:%s" % era_id)
		era_index[era_id] = index
		milestone_by_era[era_id] = milestone_id
		for candidate in candidates:
			var candidate_id := String(candidate)
			if candidate_ids.has(candidate_id):
				return _fail("technology_milestone_candidate_duplicate:%s" % candidate_id)
			candidate_ids[candidate_id] = era_id
	var family_ids := {}
	var specialist_family_ids := {}
	for row_value in backbones + families:
		var family_id := String((row_value as Dictionary).get("id", ""))
		if family_id.is_empty() or family_ids.has(family_id):
			return _fail("technology_branch_family_invalid")
		family_ids[family_id] = true
	for row_value in families:
		specialist_family_ids[String((row_value as Dictionary).id)] = true
	var route_count_by_family := {}
	var mixed_route_count_by_family := {}
	for family_id in specialist_family_ids:
		route_count_by_family[family_id] = 0
		mixed_route_count_by_family[family_id] = 0
	var node_by_id := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		if not id.begins_with("tech.") or node_by_id.has(id):
			return _fail("technology_id_invalid_or_duplicate:%s" % id)
		node_by_id[id] = node
	for era_id in milestone_by_era:
		if not node_by_id.has(String(milestone_by_era[era_id])):
			return _fail("technology_milestone_missing:%s" % era_id)
	for candidate_id in candidate_ids:
		if not node_by_id.has(candidate_id) or String((node_by_id[candidate_id] as Dictionary).get(
				"era_id", "")) != String(candidate_ids[candidate_id]):
			return _fail("technology_milestone_candidate_invalid:%s" % candidate_id)
	var hard_edges := 0
	var research_condition_nodes := 0
	var empty_modifier_nodes := 0
	var adjacency := {}
	var indegree := {}
	for id in node_by_id:
		adjacency[id] = []
		indegree[id] = 0
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.id)
		var era_id := String(node.get("era_id", ""))
		var family_id := String(node.get("branch_family_id", ""))
		if not era_index.has(era_id) or not family_ids.has(family_id) \
				or node.has("main_lane") or node.has("same_lane_successor_ids") \
				or node.has("is_milestone_candidate"):
			return _fail("technology_node_schema_invalid:%s" % id)
		if not ALLOWED_REVEAL_CATEGORIES.has(String(node.get("reveal_category", ""))) \
				or String(node.get("reveal_summary", "")).is_empty():
			return _fail("technology_reveal_metadata_invalid:%s" % id)
		var hard: Array = node.get("hard_prerequisite_ids", [])
		var rationales: Array = node.get("prerequisite_rationales", [])
		if hard.size() != rationales.size():
			return _fail("technology_prerequisite_rationale_count_invalid:%s" % id)
		for cursor in range(hard.size()):
			var prerequisite := String(hard[cursor])
			var rationale := String(rationales[cursor]).strip_edges()
			if not node_by_id.has(prerequisite) or rationale.is_empty():
				return _fail("technology_prerequisite_invalid:%s" % id)
			if rationale.contains("不可替代的理论、材料、工艺或组织基础"):
				return _fail("technology_prerequisite_rationale_template_forbidden:%s" % id)
			if int(era_index[String((node_by_id[prerequisite] as Dictionary).era_id)]) > int(era_index[era_id]):
				return _fail("technology_prerequisite_future_era:%s" % id)
			var targets: Array = adjacency[prerequisite]
			targets.append(id)
			adjacency[prerequisite] = targets
			indegree[id] = int(indegree[id]) + 1
			hard_edges += 1
		var condition: Dictionary = node.get("research_condition", {})
		if not condition.is_empty():
			var condition_error := _validate_condition(condition, node_by_id)
			if not condition_error.is_empty():
				return _fail("%s:%s" % [condition_error, id])
			if String(node.get("research_condition_summary", "")).is_empty():
				return _fail("technology_research_condition_summary_missing:%s" % id)
			research_condition_nodes += 1
			if specialist_family_ids.has(family_id):
				route_count_by_family[family_id] = int(route_count_by_family[family_id]) + 1
				if _condition_has_signal(condition):
					mixed_route_count_by_family[family_id] = int(
						mixed_route_count_by_family[family_id]) + 1
			var alternatives := PackedStringArray()
			_collect_technology_atoms(condition, alternatives)
			for alternative_id in alternatives:
				if hard.has(String(alternative_id)):
					return _fail("technology_condition_duplicates_hard_prerequisite:%s" % id)
				if int(era_index[String((node_by_id[String(alternative_id)] as Dictionary).era_id)]) \
						> int(era_index[era_id]):
					return _fail("technology_condition_future_era:%s" % id)
		if (node.get("modifier_terms", []) as Array).is_empty() \
				and not bool(node.get("is_starter_eligible", false)):
			empty_modifier_nodes += 1
		var unlocked_content := {}
		for binding_value in node.get("expected_bindings", []):
			var binding: Dictionary = binding_value
			var unlocked_id := String(binding.get("id", ""))
			if not unlocked_id.is_empty():
				unlocked_content["%d:%s" % [int(binding.get("kind", 0)), unlocked_id]] = true
		for term_value in node.get("modifier_terms", []):
			var term: Dictionary = term_value
			if String(term.get("effect_class", "")).is_empty() \
					or String(term.get("effect_rationale", "")).is_empty() \
					or String(term.get("implementation_status", "")) != "runtime_consumed" \
					or String(term.get("runtime_consumer", "")).is_empty():
				return _fail("technology_modifier_semantics_missing:%s" % id)
			var subject_binding_kind := _modifier_subject_binding_kind(String(
				term.get("subject_kind", "")))
			if subject_binding_kind > 0 and unlocked_content.has("%d:%s" % [
				subject_binding_kind, String(term.get("subject_id", ""))]):
				return _fail("technology_unlock_same_target_modifier:%s" % id)
		var branch_successors: Array = node.get("branch_successor_ids", [])
		var branch_rationales: Array = node.get("branch_successor_rationales", [])
		if branch_successors.size() != branch_rationales.size():
			return _fail("technology_branch_successor_rationale_count_invalid:%s" % id)
		for successor_index in range(branch_successors.size()):
			var successor_id := String(branch_successors[successor_index])
			if not node_by_id.has(successor_id):
				return _fail("technology_branch_successor_unknown:%s" % id)
			if String((node_by_id[successor_id] as Dictionary).get("branch_family_id", "")) != family_id:
				return _fail("technology_branch_successor_cross_family:%s" % id)
			if String(branch_rationales[successor_index]).strip_edges().is_empty():
				return _fail("technology_branch_successor_rationale_missing:%s" % id)
		var application_targets: Array = node.get("application_target_ids", [])
		var application_rationales: Array = node.get("application_target_rationales", [])
		if application_targets.size() != application_rationales.size():
			return _fail("technology_application_rationale_count_invalid:%s" % id)
		for target_index in range(application_targets.size()):
			var target_id := String(application_targets[target_index])
			if not node_by_id.has(target_id):
				return _fail("technology_application_target_unknown:%s" % id)
			if String(application_rationales[target_index]).strip_edges().is_empty():
				return _fail("technology_application_rationale_missing:%s" % id)
	var ready: Array[String] = []
	for id in indegree:
		if int(indegree[id]) == 0:
			ready.append(String(id))
	ready.sort()
	var visited := 0
	while not ready.is_empty():
		var id: String = String(ready.pop_front())
		visited += 1
		for target in adjacency[id]:
			indegree[String(target)] = int(indegree[String(target)]) - 1
			if int(indegree[String(target)]) == 0:
				ready.append(String(target))
		ready.sort()
	if visited != nodes.size():
		return _fail("technology_hard_prerequisite_cycle")
	for family_id in specialist_family_ids:
		if int(route_count_by_family[family_id]) < 3:
			return _fail("technology_family_alternative_routes_missing:%s" % family_id)
		if int(mixed_route_count_by_family[family_id]) < 1:
			return _fail("technology_family_mixed_evidence_route_missing:%s" % family_id)
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.id)
		var has_hard_successor := not (adjacency[id] as Array).is_empty()
		var has_authored_successor := not (node.get("branch_successor_ids", []) as Array).is_empty() \
			or not (node.get("application_target_ids", []) as Array).is_empty()
		if not has_hard_successor and not has_authored_successor \
				and String(node.get("terminal_reason", "")).strip_edges().is_empty():
			return _fail("technology_terminal_reason_missing:%s" % id)
	return {
		"ok": true,
		"hard_edges": hard_edges,
		"alternative_edges": _count_condition_technology_atoms(nodes),
		"milestone_candidate_edges": eras.size() * 8,
		"research_condition_nodes": research_condition_nodes,
		"empty_modifier_nodes": empty_modifier_nodes,
	}


func _modifier_subject_binding_kind(subject_kind: String) -> int:
	match subject_kind:
		"good": return 1
		"building": return 2
		"resource": return 3
		_: return 0


func _validate_condition(spec: Dictionary, node_by_id: Dictionary) -> String:
	if spec.has("kind"):
		var kind := int(spec.get("kind", -1))
		var reference_id := String(spec.get("id", ""))
		if kind == ResearchPredicateScript.Kind.TECH_COMPLETED:
			return "" if node_by_id.has(reference_id) else "technology_condition_reference_unknown"
		if kind in [ResearchPredicateScript.Kind.SIGNAL_PRESENT, ResearchPredicateScript.Kind.SIGNAL_COUNT]:
			return "" if not reference_id.is_empty() else "technology_condition_signal_invalid"
		return "technology_condition_predicate_unsupported"
	var operator := int(spec.get("operator", -1))
	var children: Array = spec.get("children", [])
	if operator not in [ResearchConditionScript.Operator.ALL_OF,
			ResearchConditionScript.Operator.ANY_OF, ResearchConditionScript.Operator.AT_LEAST,
			ResearchConditionScript.Operator.NOT] or children.is_empty():
		return "technology_condition_operator_invalid"
	if operator == ResearchConditionScript.Operator.NOT and children.size() != 1:
		return "technology_condition_not_arity_invalid"
	if operator == ResearchConditionScript.Operator.AT_LEAST:
		var required := int(spec.get("required_count", 0))
		if required <= 0 or required > children.size():
			return "technology_condition_at_least_invalid"
	for child_value in children:
		if not child_value is Dictionary:
			return "technology_condition_child_invalid"
		var error := _validate_condition(child_value as Dictionary, node_by_id)
		if not error.is_empty():
			return error
	return ""


func _build_visual_edges(payload: Dictionary) -> Array[Dictionary]:
	var nodes: Array = payload.nodes
	var out: Array[Dictionary] = []
	var seen := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		var target := String(node.id)
		for source in node.get("hard_prerequisite_ids", []):
			_add_edge(out, seen, String(source), target, "hard")
		var alternatives := PackedStringArray()
		_collect_technology_atoms(node.get("research_condition", {}), alternatives)
		for source in alternatives:
			_add_edge(out, seen, String(source), target, "alternative")
		for application in node.get("application_target_ids", []):
			_add_edge(out, seen, target, String(application), "application")
	for era_value in payload.eras:
		var era: Dictionary = era_value
		for candidate in era.milestone_candidate_ids:
			_add_edge(out, seen, String(candidate), String(era.milestone_id), "milestone_candidate")
	var order := {}
	for index in range(nodes.size()):
		order[String((nodes[index] as Dictionary).id)] = index
	out.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := "%08d|%08d|%s" % [int(order.get(String(left.from), 1 << 29)),
			int(order.get(String(left.to), 1 << 29)), String(left.kind)]
		var right_key := "%08d|%08d|%s" % [int(order.get(String(right.from), 1 << 29)),
			int(order.get(String(right.to), 1 << 29)), String(right.kind)]
		return left_key < right_key)
	return out


func _collect_technology_atoms(spec: Dictionary, out: PackedStringArray) -> void:
	if spec.is_empty():
		return
	if spec.has("kind"):
		if int(spec.kind) == ResearchPredicateScript.Kind.TECH_COMPLETED:
			var id := String(spec.get("id", ""))
			if not id.is_empty() and not out.has(id):
				out.append(id)
		return
	for child_value in spec.get("children", []):
		if child_value is Dictionary:
			_collect_technology_atoms(child_value as Dictionary, out)


func _condition_has_signal(spec: Dictionary) -> bool:
	if spec.is_empty():
		return false
	if spec.has("kind"):
		return int(spec.get("kind", -1)) in [
			ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT]
	for child_value in spec.get("children", []):
		if child_value is Dictionary and _condition_has_signal(child_value as Dictionary):
			return true
	return false


func _add_edge(out: Array[Dictionary], seen: Dictionary, source: String,
		target: String, kind: String) -> void:
	if source.is_empty() or target.is_empty() or source == target or not ALLOWED_EDGE_KINDS.has(kind):
		return
	var key := "%s|%s|%s" % [kind, source, target]
	if seen.has(key):
		return
	seen[key] = true
	out.append({"from": source, "to": target, "kind": kind})


func _count_condition_technology_atoms(nodes: Array) -> int:
	var count := 0
	for node_value in nodes:
		var atoms := PackedStringArray()
		_collect_technology_atoms((node_value as Dictionary).get("research_condition", {}), atoms)
		count += atoms.size()
	return count


func _audit_report(payload: Dictionary, validation: Dictionary) -> String:
	var effect_counts := {
		"全社会或部门": 0,
		"精确物资产出": 0,
		"精确物资投入": 0,
		"居民物资消费": 0,
		"自然资源": 0,
		"地理×产业": 0,
	}
	for node_value in payload.nodes:
		for term_value in (node_value as Dictionary).get("modifier_terms", []):
			var stat := String((term_value as Dictionary).get("stat", ""))
			if stat.begins_with("country.output.good."):
				effect_counts["精确物资产出"] += 1
			elif stat.begins_with("country.input.good."):
				effect_counts["精确物资投入"] += 1
			elif stat.begins_with("country.consumption.good."):
				effect_counts["居民物资消费"] += 1
			elif stat.begins_with("country.resource."):
				effect_counts["自然资源"] += 1
			elif stat.begins_with("country.output.terrain.") \
					or stat.begins_with("country.output.landform."):
				effect_counts["地理×产业"] += 1
			else:
				effect_counts["全社会或部门"] += 1
	var lines := PackedStringArray([
		"# Technology Network v2 Audit", "",
		"- Nodes: %d" % (payload.nodes as Array).size(),
		"- Branch families: %d" % (payload.branch_families as Array).size(),
		"- Hard prerequisite edges: %d (no indegree cap)" % int(validation.hard_edges),
		"- Alternative evidence edges: %d" % int(validation.alternative_edges),
		"- Milestone candidate edges: %d (8 per era, require 4)" % int(validation.milestone_candidate_edges),
		"- Nodes with research conditions: %d" % int(validation.research_condition_nodes),
		"- Unlock-only/no-Modifier nodes: %d" % int(validation.empty_modifier_nodes), "",
		"## Explicit effect semantics", "",
		"- Societal/sector terms: %d" % int(effect_counts["全社会或部门"]),
		"- Exact-good output terms: %d" % int(effect_counts["精确物资产出"]),
		"- Exact-good input terms: %d" % int(effect_counts["精确物资投入"]),
		"- Household good-consumption terms: %d" % int(effect_counts["居民物资消费"]),
		"- Natural-resource terms: %d" % int(effect_counts["自然资源"]),
		"- Geography × sector terms: %d" % int(effect_counts["地理×产业"]),
		"- Missing runtime consumers: 0", "",
		"## Branch families", "",
	])
	for family_value in payload.branch_families:
		var family: Dictionary = family_value
		var members := 0
		for node_value in payload.nodes:
			if String((node_value as Dictionary).branch_family_id) == String(family.id):
				members += 1
		lines.append("- %s (`%s`): %d nodes" % [String(family.display_name), String(family.id), members])
	return "\n".join(lines) + "\n"


func _write_json(payload: Dictionary) -> void:
	_write_text(NETWORK_PATH, JSON.stringify(payload, "\t", false, true) + "\n")


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("technology_authoring_write_failed:%s" % path)
		return
	file.store_string(content)
	file.close()


func _fail(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}
