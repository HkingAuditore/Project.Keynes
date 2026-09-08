class_name TechnologyNetworkValidator
extends RefCounted

## Single authority for technology-network schema-v4 normalization and validation.
## The headless gate (tools/build_technology_network_authoring.gd) and the
## in-editor authoring workbench both run this class, so diagnostic codes can
## never diverge between the two.
##
## Unlike a gate, an authoring workbench needs every problem at once. `validate`
## therefore collects findings in the same evaluation order the gate used to
## return them, which keeps `findings[0].code` byte-identical to the legacy
## single-reason output.

const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

const SEVERITY_ERROR := "error"
const SEVERITY_WARNING := "warning"

const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
	"steam", "electrical", "atomic", "information", "intelligent",
]
const ALLOWED_REVEAL_CATEGORIES := [
	"general_knowledge", "environment_observation", "practice_diffusion", "composite_science",
	"application_intersection", "method_progression",
]
const ALLOWED_EDGE_KINDS := [
	"hard", "alternative", "application", "branch", "milestone_candidate",
]
const TOPOLOGY_REVIEW_ROLES := [
	"origin", "continuation", "convergence", "branch", "terminal",
]
const BUILDING_UNLOCK_POLICIES := ["single", "paired", "support_only"]
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
	"country.research.agriculture_efficiency": "农业领域研究效率",
	"country.research.engineering_efficiency": "工程领域研究效率",
	"country.research.science_efficiency": "科学领域研究效率",
	"country.research.society_efficiency": "社会领域研究效率",
	"country.research.institution_output_factor": "科研机构产出",
	"country.trade.capacity_factor": "国内贸易容量",
	"country.trade.speed_factor": "贸易速度",
}

const MODIFIER_OPERATION_NAMES := ["加", "减", "乘", "除"]


## The one on-disk serialization for the network. The gate and the workbench
## both call it so an editor save and a gate rewrite cannot churn the file
## against each other.
static func serialize_network(payload: Dictionary) -> String:
	return JSON.stringify(payload, "\t", false, true) + "\n"


# --------------------------------------------------------------------------
# Findings
# --------------------------------------------------------------------------

static func finding(code: String, message: String, node_id := "",
		field := "", severity := SEVERITY_ERROR) -> Dictionary:
	return {
		"severity": severity,
		"code": code,
		"node_id": node_id,
		"field": field,
		"message": message,
	}


static func first_error_code(findings: Array) -> String:
	for value in findings:
		var row: Dictionary = value
		if String(row.get("severity", SEVERITY_ERROR)) == SEVERITY_ERROR:
			return String(row.get("code", ""))
	return ""


static func error_count(findings: Array) -> int:
	var count := 0
	for value in findings:
		if String((value as Dictionary).get("severity", SEVERITY_ERROR)) == SEVERITY_ERROR:
			count += 1
	return count


# --------------------------------------------------------------------------
# Normalization
# --------------------------------------------------------------------------

## Rewrites every `effect_summary` from the authored effects. Returns true when
## anything changed, which the gate treats as "not normalized" under --check.
static func normalize_effect_summaries(payload: Dictionary) -> bool:
	var changed := false
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		var summary := effect_summary(node)
		if String(node.get("effect_summary", "")) != summary:
			node["effect_summary"] = summary
			changed = true
	return changed


static func effect_summary(node: Dictionary) -> String:
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
		var text := "%s %s" % [subject, modifier_delta(term)]
		if not seen.has(text):
			seen[text] = true
			parts.append(text)
	var support_names := PackedStringArray()
	for support_value in node.get("support_buildings", []):
		var support: Dictionary = support_value
		var support_name := String(support.get("name", support.get("id", "")))
		if not support_name.is_empty() and not support_names.has(support_name):
			support_names.append(support_name)
	if not support_names.is_empty():
		parts.append("作为必要支撑：" + "、".join(support_names))
	if parts.is_empty():
		return "完成时代里程碑并开放下一时代" if bool(node.get(
			"is_milestone", false)) else ""
	return "；".join(parts)


static func modifier_delta(term: Dictionary) -> String:
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


## Rebuilds the deterministic visual-edge projection from authored relations.
static func build_visual_edges(payload: Dictionary) -> Array[Dictionary]:
	var nodes: Array = payload.get("nodes", [])
	var out: Array[Dictionary] = []
	var seen := {}
	for node_value in nodes:
		var node: Dictionary = node_value
		var target := String(node.get("id", ""))
		for source in node.get("hard_prerequisite_ids", []):
			_add_edge(out, seen, String(source), target, "hard")
		for route_value in node.get("research_routes", []):
			var route: Dictionary = route_value
			var alternatives := PackedStringArray()
			collect_technology_atoms(route.get("condition", {}), alternatives)
			for source in alternatives:
				_add_edge(out, seen, String(source), target, "alternative",
					String(route.get("id", "")))
		for branch_successor in node.get("branch_successor_ids", []):
			_add_edge(out, seen, target, String(branch_successor), "branch")
		for application in node.get("application_target_ids", []):
			_add_edge(out, seen, target, String(application), "application")
	for era_value in payload.get("eras", []):
		var era: Dictionary = era_value
		for candidate in era.get("milestone_candidate_ids", []):
			_add_edge(out, seen, String(candidate), String(era.get("milestone_id", "")),
				"milestone_candidate")
	var order := {}
	for index in range(nodes.size()):
		order[String((nodes[index] as Dictionary).get("id", ""))] = index
	out.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := "%08d|%08d|%s" % [int(order.get(String(left.from), 1 << 29)),
			int(order.get(String(left.to), 1 << 29)), String(left.kind)]
		var right_key := "%08d|%08d|%s" % [int(order.get(String(right.from), 1 << 29)),
			int(order.get(String(right.to), 1 << 29)), String(right.kind)]
		return left_key < right_key)
	return out


static func _add_edge(out: Array[Dictionary], seen: Dictionary, source: String,
		target: String, kind: String, route_id: String = "") -> void:
	if source.is_empty() or target.is_empty() or source == target or not ALLOWED_EDGE_KINDS.has(kind):
		return
	var key := "%s|%s|%s|%s" % [kind, source, target, route_id]
	if seen.has(key):
		return
	seen[key] = true
	var edge := {"from": source, "to": target, "kind": kind}
	if not route_id.is_empty():
		edge["route_id"] = route_id
	out.append(edge)


static func collect_technology_atoms(spec: Dictionary, out: PackedStringArray) -> void:
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
			collect_technology_atoms(child_value as Dictionary, out)


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

## Returns {ok, findings, stats}. `findings` preserves the legacy gate order so
## the first error matches the historical single-reason output exactly.
static func validate(payload: Dictionary) -> Dictionary:
	var findings: Array[Dictionary] = []
	var stats := {
		"hard_edges": 0,
		"alternative_edges": 0,
		"milestone_candidate_edges": 0,
		"research_route_nodes": 0,
		"research_route_count": 0,
		"empty_modifier_nodes": 0,
		"branch_successor_edges": 0,
	}
	if int(payload.get("schema_version", 0)) != 4:
		findings.append(finding("technology_network_schema_version_invalid",
			"schema_version 必须为 4。"))
		return _result(findings, stats)
	var eras: Array = payload.get("eras", [])
	var domains: Array = payload.get("domains", [])
	var backbones: Array = payload.get("backbones", [])
	var families: Array = payload.get("branch_families", [])
	var nodes: Array = payload.get("nodes", [])
	if eras.size() != 11 or domains.size() != 4 or backbones.size() != 4 \
			or families.size() != 24 or nodes.is_empty():
		findings.append(finding("technology_network_shape_invalid",
			"网络形状非法：需要 11 时代 / 4 领域 / 4 骨干 / 24 分支族 且节点非空。"))
		return _result(findings, stats)
	var application_validation := TechnologyCatalogScript.validate_application_intersections(
		payload, nodes)
	if not bool(application_validation.get("ok", false)):
		var application_code := String(application_validation.get("reason",
			"technology_application_intersections_invalid"))
		findings.append(finding(application_code, "应用交汇记录非法：%s" % application_code,
			String(application_validation.get("id", ""))))
		return _result(findings, stats)
	if payload.has("specialist_lanes"):
		findings.append(finding("technology_legacy_lane_metadata_present",
			"存在已废弃的 specialist_lanes 元数据。"))
		return _result(findings, stats)

	var era_index := {}
	var milestone_by_era := {}
	var candidate_ids := {}
	for index in range(eras.size()):
		var era: Dictionary = eras[index]
		var era_id := String(era.get("id", ""))
		if era_id != ERA_IDS[index]:
			findings.append(finding("technology_era_order_invalid",
				"时代顺序非法：第 %d 位应为 %s，实为 %s。" % [index, ERA_IDS[index], era_id],
				era_id, "eras"))
			return _result(findings, stats)
		var milestone_id := String(era.get("milestone_id", ""))
		var entry_id := String(era.get("entry_milestone_id", ""))
		var candidates: Array = era.get("milestone_candidate_ids", [])
		var candidate_required := int(era.get("candidate_required", 0))
		if milestone_id.is_empty() or candidates.size() < 8 or candidates.size() > 18 \
				or candidate_required < 4 or candidate_required > 7 \
				or candidate_required > candidates.size():
			findings.append(finding("technology_era_milestone_contract_invalid:%s" % era_id,
				"时代 %s 里程碑契约非法：候选需 8–18 个、candidate_required 需 4–7 且不超过候选数。" % era_id,
				era_id, "milestone_candidate_ids"))
		stats.milestone_candidate_edges = int(stats.milestone_candidate_edges) + candidates.size()
		if (index == 0 and not entry_id.is_empty()) or (index > 0 and entry_id != String(
				(eras[index - 1] as Dictionary).get("milestone_id", ""))):
			findings.append(finding("technology_era_entry_contract_invalid:%s" % era_id,
				"时代 %s 的 entry_milestone_id 必须等于上一时代的 milestone_id（首时代须为空）。" % era_id,
				era_id, "entry_milestone_id"))
		era_index[era_id] = index
		milestone_by_era[era_id] = milestone_id
		for candidate in candidates:
			var candidate_id := String(candidate)
			if candidate_ids.has(candidate_id):
				findings.append(finding("technology_milestone_candidate_duplicate:%s" % candidate_id,
					"里程碑候选 %s 在多个时代重复出现。" % candidate_id,
					candidate_id, "milestone_candidate_ids"))
				continue
			candidate_ids[candidate_id] = era_id

	var family_ids := {}
	for row_value in backbones + families:
		var family_id := String((row_value as Dictionary).get("id", ""))
		if family_id.is_empty() or family_ids.has(family_id):
			findings.append(finding("technology_branch_family_invalid",
				"分支族 ID 为空或重复：%s" % family_id, family_id, "branch_families"))
			return _result(findings, stats)
		family_ids[family_id] = true

	var node_by_id := {}
	var node_order := {}
	for cursor in range(nodes.size()):
		var node: Dictionary = nodes[cursor]
		var id := String(node.get("id", ""))
		if not id.begins_with("tech.") or node_by_id.has(id):
			findings.append(finding("technology_id_invalid_or_duplicate:%s" % id,
				"科技 ID 非法或重复：%s（必须以 tech. 开头且唯一）。" % id, id, "id"))
			continue
		node_by_id[id] = node
		node_order[id] = cursor
	if node_by_id.is_empty():
		return _result(findings, stats)

	for era_id in milestone_by_era:
		if not node_by_id.has(String(milestone_by_era[era_id])):
			findings.append(finding("technology_milestone_missing:%s" % era_id,
				"时代 %s 的里程碑节点 %s 不存在。" % [era_id, String(milestone_by_era[era_id])],
				String(era_id), "milestone_id"))
	for candidate_id in candidate_ids:
		if not node_by_id.has(candidate_id) or String((node_by_id[candidate_id] as Dictionary).get(
				"era_id", "")) != String(candidate_ids[candidate_id]):
			findings.append(finding("technology_milestone_candidate_invalid:%s" % candidate_id,
				"里程碑候选 %s 不存在或不属于时代 %s。" % [candidate_id, String(candidate_ids[candidate_id])],
				String(candidate_id), "milestone_candidate_ids"))

	var formal_nodes_without_direct_consumer := PackedStringArray()
	var adjacency := {}
	var indegree := {}
	for id in node_by_id:
		adjacency[id] = []
		indegree[id] = 0

	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		if not node_by_id.has(id) or node_by_id[id] != node:
			continue
		var era_id := String(node.get("era_id", ""))
		var family_id := String(node.get("branch_family_id", ""))
		if not era_index.has(era_id) or not family_ids.has(family_id) \
				or node.has("main_lane") or node.has("same_lane_successor_ids") \
				or node.has("is_milestone_candidate"):
			findings.append(finding("technology_node_schema_invalid:%s" % id,
				"节点 %s 的时代/分支族未知，或残留了已废弃字段。" % id, id, "era_id"))
			continue
		if not ALLOWED_REVEAL_CATEGORIES.has(String(node.get("reveal_category", ""))) \
				or String(node.get("reveal_summary", "")).is_empty():
			findings.append(finding("technology_reveal_metadata_invalid:%s" % id,
				"节点 %s 的 reveal_category 非法或 reveal_summary 为空。" % id,
				id, "reveal_category"))
		var topology_review: Dictionary = node.get("topology_review", {})
		if not topology_review.is_empty():
			var topology_role := String(topology_review.get("role", ""))
			var topology_rationale := String(topology_review.get("rationale", "")).strip_edges()
			if not TOPOLOGY_REVIEW_ROLES.has(topology_role) or topology_rationale.is_empty():
				findings.append(finding("technology_topology_review_invalid:%s" % id,
					"节点 %s 的拓扑审核 role 非法或 rationale 为空。" % id, id, "topology_review"))
			var expected_families: Array = topology_review.get("expected_hard_family_ids", [])
			if not expected_families is Array:
				findings.append(finding("technology_topology_review_family_list_invalid:%s" % id,
					"节点 %s 的 expected_hard_family_ids 不是数组。" % id, id, "topology_review"))
			else:
				for expected_family in expected_families:
					if not family_ids.has(String(expected_family)):
						findings.append(finding("technology_topology_review_family_unknown:%s" % id,
							"节点 %s 的拓扑审核引用了未知分支族 %s。" % [id, String(expected_family)],
							id, "topology_review"))
				if topology_role == "convergence" and expected_families.is_empty():
					findings.append(finding("technology_topology_review_convergence_empty:%s" % id,
						"节点 %s 标记为汇聚，但未列出预期硬前置分支族。" % id, id, "topology_review"))
		var building_review: Dictionary = node.get("building_unlock_review", {})
		if not building_review.is_empty():
			var building_policy := String(building_review.get("policy", ""))
			var building_rationale := String(building_review.get("rationale", "")).strip_edges()
			if not BUILDING_UNLOCK_POLICIES.has(building_policy) \
					or building_rationale.is_empty():
				findings.append(finding("technology_building_unlock_review_invalid:%s" % id,
					"节点 %s 的建筑解锁审核 policy 非法或 rationale 为空。" % id,
					id, "building_unlock_review"))
		var hard: Array = node.get("hard_prerequisite_ids", [])
		var rationales: Array = node.get("prerequisite_rationales", [])
		if hard.size() != rationales.size():
			findings.append(finding("technology_prerequisite_rationale_count_invalid:%s" % id,
				"节点 %s 的硬前置 %d 条与理由 %d 条不等长。" % [id, hard.size(), rationales.size()],
				id, "hard_prerequisite_ids"))
		for cursor in range(hard.size()):
			var prerequisite := String(hard[cursor])
			var rationale := String(rationales[cursor]).strip_edges() if cursor < rationales.size() else ""
			if not node_by_id.has(prerequisite) or rationale.is_empty():
				findings.append(finding("technology_prerequisite_invalid:%s" % id,
					"节点 %s 的硬前置 %s 未知或缺少理由。" % [id, prerequisite],
					id, "hard_prerequisite_ids"))
			if rationale.contains("不可替代的理论、材料、工艺或组织基础"):
				findings.append(finding("technology_prerequisite_rationale_template_forbidden:%s" % id,
					"节点 %s 的前置理由使用了被禁止的模板文案。" % id, id, "prerequisite_rationales"))
			if not node_by_id.has(prerequisite):
				continue
			var prerequisite_era := String((node_by_id[prerequisite] as Dictionary).get("era_id", ""))
			if era_index.has(prerequisite_era) \
					and int(era_index[prerequisite_era]) > int(era_index[era_id]):
				findings.append(finding("technology_prerequisite_future_era:%s" % id,
					"节点 %s 的硬前置 %s 位于更晚的时代。" % [id, prerequisite], id, "hard_prerequisite_ids"))
			var targets: Array = adjacency[prerequisite]
			targets.append(id)
			adjacency[prerequisite] = targets
			indegree[id] = int(indegree[id]) + 1
			stats.hard_edges = int(stats.hard_edges) + 1
		var legacy_condition: Dictionary = node.get("research_condition", {})
		if not legacy_condition.is_empty():
			findings.append(finding("technology_legacy_research_condition_forbidden:%s" % id,
				"节点 %s 残留了已废弃的 research_condition。" % id, id, "research_condition"))
		var routes: Array = node.get("research_routes", [])
		if int(era_index[era_id]) >= 2 and routes.is_empty() \
				and String(node.get("route_exemption_reason", "")).strip_edges().is_empty():
			findings.append(finding("technology_route_exemption_reason_missing:%s" % id,
				"节点 %s 位于王国时代及以后但没有研究路线，需要填写 route_exemption_reason。" % id,
				id, "route_exemption_reason"))
		var route_ids := {}
		var route_types := {}
		for route_value in routes:
			if not route_value is Dictionary:
				findings.append(finding("technology_research_route_invalid:%s" % id,
					"节点 %s 的研究路线条目不是字典。" % id, id, "research_routes"))
				continue
			var route: Dictionary = route_value
			var route_id := String(route.get("id", "")).strip_edges()
			var route_type := String(route.get("route_type", "")).strip_edges()
			var route_condition: Dictionary = route.get("condition", {})
			if not route_id.begins_with("research_route.") or route_ids.has(route_id) \
					or String(route.get("display_name", "")).strip_edges().is_empty() \
					or route_type.is_empty() \
					or String(route.get("description", "")).strip_edges().is_empty() \
					or route_condition.is_empty():
				findings.append(finding("technology_research_route_invalid:%s" % id,
					"节点 %s 的研究路线 %s 非法：ID 需以 research_route. 开头且唯一，名称/类型/描述/条件均不可为空。" % [id, route_id],
					id, "research_routes"))
				continue
			route_ids[route_id] = true
			route_types[route_type] = true
			var condition_error := _validate_condition(route_condition, node_by_id)
			if not condition_error.is_empty():
				findings.append(finding("%s:%s:%s" % [condition_error, id, route_id],
					"节点 %s 的路线 %s 条件非法：%s" % [id, route_id, condition_error],
					id, "research_routes"))
				continue
			var alternatives := PackedStringArray()
			collect_technology_atoms(route_condition, alternatives)
			for alternative_id in alternatives:
				if hard.has(String(alternative_id)):
					findings.append(finding("technology_route_duplicates_core_prerequisite:%s" % id,
						"节点 %s 的路线证据 %s 与硬前置重复。" % [id, String(alternative_id)],
						id, "research_routes"))
					continue
				var source_index := int(node_order.get(String(alternative_id), -1))
				var target_index := int(node_order.get(id, -1))
				if source_index < 0 or source_index >= target_index:
					findings.append(finding("technology_research_route_reference_not_earlier:%s" % id,
						"节点 %s 的路线证据 %s 必须在本节点之前定义。" % [id, String(alternative_id)],
						id, "research_routes"))
		if routes.size() > 1 and route_types.size() < 2:
			findings.append(finding("technology_research_route_types_not_distinct:%s" % id,
				"节点 %s 有多条研究路线但 route_type 不互异。" % id, id, "research_routes"))
		if not routes.is_empty():
			stats.research_route_nodes = int(stats.research_route_nodes) + 1
			stats.research_route_count = int(stats.research_route_count) + routes.size()
		var modifier_terms: Array = node.get("modifier_terms", [])
		var is_formal := not bool(node.get("is_milestone", false)) \
			and not bool(node.get("is_starting", false)) \
			and not bool(node.get("is_starter_eligible", false))
		var has_direct_consumer := not (node.get("expected_bindings", []) as Array).is_empty() \
			or not (node.get("content_effects", []) as Array).is_empty() \
			or not (node.get("support_buildings", []) as Array).is_empty() \
			or not (node.get("branch_successor_ids", []) as Array).is_empty() \
			or not (node.get("application_target_ids", []) as Array).is_empty()
		if is_formal and modifier_terms.size() > 6:
			findings.append(finding("technology_modifier_term_count_invalid:%s" % id,
				"节点 %s 的 modifier_terms 有 %d 条，上限为 6。" % [id, modifier_terms.size()],
				id, "modifier_terms"))
		if is_formal and modifier_terms.is_empty() and not has_direct_consumer:
			formal_nodes_without_direct_consumer.append(id)
		if modifier_terms.is_empty() and not bool(node.get("is_starter_eligible", false)):
			stats.empty_modifier_nodes = int(stats.empty_modifier_nodes) + 1
		for term_value in modifier_terms:
			var term: Dictionary = term_value
			if String(term.get("effect_class", "")).is_empty() \
					or String(term.get("effect_rationale", "")).is_empty() \
					or String(term.get("implementation_status", "")) != "runtime_consumed" \
					or String(term.get("runtime_consumer", "")).is_empty():
				findings.append(finding("technology_modifier_semantics_missing:%s" % id,
					"节点 %s 的效果项 %s 缺少 effect_class / effect_rationale / runtime_consumer，或 implementation_status 不是 runtime_consumed。" % [
						id, String(term.get("stat", ""))],
					id, "modifier_terms"))
			if same_target_conflict(node, term):
				findings.append(finding("technology_unlock_same_target_modifier:%s" % id,
					"节点 %s 同时解锁并加成同一目标 %s。" % [id, String(term.get("subject_id", ""))],
					id, "modifier_terms"))
		var branch_successors: Array = node.get("branch_successor_ids", [])
		var branch_rationales: Array = node.get("branch_successor_rationales", [])
		if branch_successors.size() != branch_rationales.size():
			findings.append(finding("technology_branch_successor_rationale_count_invalid:%s" % id,
				"节点 %s 的分支后继 %d 条与理由 %d 条不等长。" % [
					id, branch_successors.size(), branch_rationales.size()],
				id, "branch_successor_ids"))
		for successor_index in range(branch_successors.size()):
			var successor_id := String(branch_successors[successor_index])
			if not node_by_id.has(successor_id):
				findings.append(finding("technology_branch_successor_unknown:%s" % id,
					"节点 %s 的分支后继 %s 不存在。" % [id, successor_id], id, "branch_successor_ids"))
				continue
			if String((node_by_id[successor_id] as Dictionary).get("branch_family_id", "")) != family_id:
				findings.append(finding("technology_branch_successor_cross_family:%s" % id,
					"节点 %s 的分支后继 %s 属于其他分支族。" % [id, successor_id], id, "branch_successor_ids"))
			if successor_index >= branch_rationales.size() \
					or String(branch_rationales[successor_index]).strip_edges().is_empty():
				findings.append(finding("technology_branch_successor_rationale_missing:%s" % id,
					"节点 %s 的分支后继 %s 缺少理由。" % [id, successor_id], id, "branch_successor_rationales"))
		stats.branch_successor_edges = int(stats.branch_successor_edges) + branch_successors.size()
		var application_targets: Array = node.get("application_target_ids", [])
		var application_rationales: Array = node.get("application_target_rationales", [])
		if application_targets.size() != application_rationales.size():
			findings.append(finding("technology_application_rationale_count_invalid:%s" % id,
				"节点 %s 的应用交汇 %d 条与理由 %d 条不等长。" % [
					id, application_targets.size(), application_rationales.size()],
				id, "application_target_ids"))
		for target_index in range(application_targets.size()):
			var target_id := String(application_targets[target_index])
			if not node_by_id.has(target_id):
				findings.append(finding("technology_application_target_unknown:%s" % id,
					"节点 %s 的应用目标 %s 不存在。" % [id, target_id], id, "application_target_ids"))
				continue
			if target_index >= application_rationales.size() \
					or String(application_rationales[target_index]).strip_edges().is_empty():
				findings.append(finding("technology_application_rationale_missing:%s" % id,
					"节点 %s 的应用目标 %s 缺少理由。" % [id, target_id], id, "application_target_rationales"))

	for id in formal_nodes_without_direct_consumer:
		if (adjacency[String(id)] as Array).is_empty():
			findings.append(finding("technology_real_consumer_missing:%s" % id,
				"节点 %s 既无效果、无解锁、无后继，也没有任何硬后继消费它。" % id, String(id), "modifier_terms"))

	var pending := {}
	for id in indegree:
		pending[id] = int(indegree[id])
	var ready: Array[String] = []
	for id in pending:
		if int(pending[id]) == 0:
			ready.append(String(id))
	ready.sort()
	var visited := 0
	while not ready.is_empty():
		var id: String = String(ready.pop_front())
		visited += 1
		for target in adjacency[id]:
			pending[String(target)] = int(pending[String(target)]) - 1
			if int(pending[String(target)]) == 0:
				ready.append(String(target))
		ready.sort()
	if visited != node_by_id.size():
		var cycle_members := PackedStringArray()
		for id in pending:
			if int(pending[id]) > 0:
				cycle_members.append(String(id))
		findings.append(finding("technology_hard_prerequisite_cycle",
			"硬前置存在环，涉及 %d 个节点。" % cycle_members.size(), "", "hard_prerequisite_ids"))
		for id in cycle_members:
			findings.append(finding("technology_hard_prerequisite_cycle_member:%s" % id,
				"节点 %s 处于硬前置环中。" % id, String(id), "hard_prerequisite_ids"))

	var post_kingdom_total := 0
	var post_kingdom_with_routes := 0
	for node_value in nodes:
		var node: Dictionary = node_value
		var node_era := String(node.get("era_id", ""))
		if not era_index.has(node_era) or int(era_index[node_era]) < 2:
			continue
		if String(node.get("reveal_category", "")) in [
				"application_intersection", "method_progression"]:
			continue
		post_kingdom_total += 1
		if not (node.get("research_routes", []) as Array).is_empty():
			post_kingdom_with_routes += 1
	if post_kingdom_total <= 0 or post_kingdom_with_routes * 100 < post_kingdom_total * 80:
		findings.append(finding("technology_research_route_coverage_below_80_percent",
			"王国时代及以后的研究路线覆盖率为 %d/%d，低于 80%%。" % [
				post_kingdom_with_routes, post_kingdom_total], "", "research_routes"))

	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		if not adjacency.has(id):
			continue
		var has_hard_successor := not (adjacency[id] as Array).is_empty()
		var has_authored_successor := not (node.get("branch_successor_ids", []) as Array).is_empty() \
			or not (node.get("application_target_ids", []) as Array).is_empty()
		var has_runtime_endpoint := not (node.get("expected_bindings", []) as Array).is_empty() \
			or not (node.get("content_effects", []) as Array).is_empty() \
			or not (node.get("support_buildings", []) as Array).is_empty() \
			or not (node.get("modifier_terms", []) as Array).is_empty()
		if not has_hard_successor and not has_authored_successor \
				and not has_runtime_endpoint \
				and String(node.get("terminal_reason", "")).strip_edges().is_empty():
			findings.append(finding("technology_terminal_reason_missing:%s" % id,
				"节点 %s 是终点但未填写 terminal_reason。" % id, id, "terminal_reason"))

	stats.alternative_edges = _count_route_technology_atoms(nodes)
	return _result(findings, stats)


## Editor-only pass. The headless gate never runs this, so gate output stays
## byte-identical while the workbench can still reject unknown Modifier stats
## before EconomyCatalog compilation fails.
static func validate_modifier_stats(payload: Dictionary,
		allowed_stats: Dictionary) -> Array[Dictionary]:
	var findings: Array[Dictionary] = []
	if allowed_stats.is_empty():
		return findings
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		for term_value in node.get("modifier_terms", []):
			var term: Dictionary = term_value
			var stat := String(term.get("stat", ""))
			if stat.is_empty() or not allowed_stats.has(stat):
				findings.append(finding("technology_modifier_stat_unknown:%s" % id,
					"节点 %s 的效果 stat「%s」不在 Modifier 目录中，编译经济目录时会失败。" % [id, stat],
					id, "modifier_terms"))
			var operation := int(term.get("operation", 0))
			if operation < 0 or operation > 3:
				findings.append(finding("technology_modifier_operation_invalid:%s" % id,
					"节点 %s 的效果 operation 必须在 0–3 之间。" % id, id, "modifier_terms"))
			var value := float(term.get("value", 0.0))
			if not is_finite(value):
				findings.append(finding("technology_modifier_value_invalid:%s" % id,
					"节点 %s 的效果 value 不是有限数。" % id, id, "modifier_terms"))
	return findings


static func _result(findings: Array[Dictionary], stats: Dictionary) -> Dictionary:
	return {
		"ok": error_count(findings) == 0,
		"findings": findings,
		"stats": stats,
	}


## True when a node both unlocks a target through `expected_bindings` and buffs
## the same target through a Modifier term. Exposed so the authoring inspector
## can warn while typing using the exact rule the gate enforces.
static func same_target_conflict(node: Dictionary, term: Dictionary) -> bool:
	var binding_kind := _modifier_subject_binding_kind(String(
		term.get("subject_kind", "")))
	if binding_kind <= 0:
		return false
	var subject_id := String(term.get("subject_id", ""))
	if subject_id.is_empty():
		return false
	for binding_value in node.get("expected_bindings", []):
		var binding: Dictionary = binding_value
		if int(binding.get("kind", 0)) == binding_kind \
				and String(binding.get("id", "")) == subject_id:
			return true
	return false


static func _modifier_subject_binding_kind(subject_kind: String) -> int:
	match subject_kind:
		"good": return 1
		"building": return 2
		"resource": return 3
		_: return 0


static func _validate_condition(spec: Dictionary, node_by_id: Dictionary) -> String:
	if spec.has("kind"):
		var kind := int(spec.get("kind", -1))
		var reference_id := String(spec.get("id", ""))
		if kind == ResearchPredicateScript.Kind.TECH_COMPLETED:
			return "" if node_by_id.has(reference_id) else "technology_condition_reference_unknown"
		if kind in [ResearchPredicateScript.Kind.SIGNAL_PRESENT,
				ResearchPredicateScript.Kind.SIGNAL_COUNT]:
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


static func _count_route_technology_atoms(nodes: Array) -> int:
	var count := 0
	for node_value in nodes:
		for route_value in (node_value as Dictionary).get("research_routes", []):
			var atoms := PackedStringArray()
			collect_technology_atoms((route_value as Dictionary).get("condition", {}), atoms)
			count += atoms.size()
	return count


# --------------------------------------------------------------------------
# Audit report
# --------------------------------------------------------------------------

static func audit_report(payload: Dictionary, stats: Dictionary) -> String:
	var effect_counts := {
		"全社会或部门": 0,
		"精确物资产出": 0,
		"精确物资投入": 0,
		"居民物资消费": 0,
		"自然资源": 0,
		"地理×产业": 0,
		"国家气候适应": 0,
		"生产类型气候适应": 0,
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
			elif stat.begins_with("country.climate.profile."):
				effect_counts["生产类型气候适应"] += 1
			elif stat.begins_with("country.climate."):
				effect_counts["国家气候适应"] += 1
			else:
				effect_counts["全社会或部门"] += 1
	var lines := PackedStringArray([
		"# Technology Network v4 Audit", "",
		"- Research nodes: %d" % (payload.nodes as Array).size(),
		"- Application intersections: %d (static, zero-cost)" % (payload.get("application_intersections", []) as Array).size(),
		"- Nodes: %d" % (payload.nodes as Array).size(),
		"- Branch families: %d" % (payload.branch_families as Array).size(),
		"- Hard prerequisite edges: %d (no indegree cap)" % int(stats.hard_edges),
		"- Alternative evidence edges: %d" % int(stats.alternative_edges),
		"- Milestone candidate edges: %d (8–18 per era, require 4–7)" % int(stats.milestone_candidate_edges),
		"- Nodes with research routes: %d" % int(stats.research_route_nodes),
		"- Research routes: %d" % int(stats.research_route_count),
		"- Authored branch successor edges: %d" % int(stats.branch_successor_edges),
		"- Unlock-only/no-Modifier nodes: %d" % int(stats.empty_modifier_nodes), "",
		"## Explicit effect semantics", "",
		"- Societal/sector terms: %d" % int(effect_counts["全社会或部门"]),
		"- Exact-good output terms: %d" % int(effect_counts["精确物资产出"]),
		"- Exact-good input terms: %d" % int(effect_counts["精确物资投入"]),
		"- Household good-consumption terms: %d" % int(effect_counts["居民物资消费"]),
		"- Natural-resource terms: %d" % int(effect_counts["自然资源"]),
		"- Geography × sector terms: %d" % int(effect_counts["地理×产业"]),
		"- Country climate-adaptation terms: %d" % int(effect_counts["国家气候适应"]),
		"- Production-profile climate-adaptation terms: %d" % int(
			effect_counts["生产类型气候适应"]),
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
