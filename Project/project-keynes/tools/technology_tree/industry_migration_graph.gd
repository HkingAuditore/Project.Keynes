extends RefCounted

## Rebuild the technology prerequisite, research-route, and visual-edge graphs.

const MigrationFiles = preload("res://tools/technology_tree/industry_migration_files.gd")

const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
	"steam", "electrical", "atomic", "information", "intelligent",
]
const HARD_PREREQUISITE_OVERRIDES := {
	# Electronic control is the indispensable technical basis. Laboratories,
	# agricultural computation and institutional scale remain alternative routes.
	"tech.digital_computing": ["tech.electronic_control"],
	"tech.bronze_casting": ["tech.tin_identification", "tech.copper_annealing"],
}


static func _rebuild_visual_edges(payload: Dictionary) -> Array:
	var edges := []
	var seen := {}
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		for prerequisite in node.get("hard_prerequisite_ids", []):
			_add_edge(edges, seen, String(prerequisite), String(node.id), "hard")
		for successor in node.get("branch_successor_ids", []):
			_add_edge(edges, seen, String(node.id), String(successor), "branch")
		for route_value in node.get("research_routes", []):
			var route: Dictionary = route_value
			_collect_route_edges(route.get("condition", {}), String(node.id), String(route.get("id", "")), edges, seen)
	for era_value in payload.get("eras", []):
		var era: Dictionary = era_value
		for candidate in era.get("milestone_candidate_ids", []):
			_add_edge(edges, seen, String(candidate), String(era.milestone_id), "milestone_candidate")
	return edges


static func _collect_route_edges(value: Variant, target: String, route_id: String, edges: Array, seen: Dictionary) -> void:
	if not value is Dictionary:
		return
	var condition: Dictionary = value
	if int(condition.get("kind", -1)) == 0:
		_add_edge(edges, seen, String(condition.get("id", "")), target, "alternative", route_id)
	for child in condition.get("children", []):
		_collect_route_edges(child, target, route_id, edges, seen)


static func _add_edge(edges: Array, seen: Dictionary, from: String, to: String, kind: String, route_id := "") -> void:
	var key := "%s|%s|%s|%s" % [from, to, kind, route_id]
	if from.is_empty() or to.is_empty() or seen.has(key):
		return
	seen[key] = true
	var edge := {"from": from, "to": to, "kind": kind}
	if not route_id.is_empty(): edge["route_id"] = route_id
	edges.append(edge)


static func _ensure_medicinal_herb_technologies(payload: Dictionary) -> void:
	var nodes: Array = payload.get("nodes", [])
	var by_id := {}
	for value in nodes:
		var node: Dictionary = value
		by_id[String(node.get("id", ""))] = node
	if not by_id.has("tech.medicinal_herb_identification"):
		var identification: Dictionary = (by_id.get("tech.spice_identification", {}) as Dictionary).duplicate(true)
		identification["id"] = "tech.medicinal_herb_identification"
		identification["display_name"] = "野生药草辨识"
		identification["layout_order"] = 50.5
		identification["secondary_route_tags"] = ["route.crop.medicinal_herb"]
		identification["hard_prerequisite_ids"] = ["tech.natural_observation"]
		identification["reveal_condition"] = {
			"operator": 2,
			"children": [
				{"kind": 1, "id": "bio.medicinal_herb", "value": 1},
				{"kind": 1, "id": "contact.medicinal_herb", "value": 1},
			],
		}
		identification["expected_bindings"] = []
		identification["content_effects"] = []
		identification["modifier_terms"] = []
		identification["effect_summary"] = "辨识可采集的野生药草，并揭示安全采集与处理路线。"
		identification["opportunity_cost"] = "需要持续观察药性、毒性与生境，延后其他自然辨识路线。"
		identification["application_target_ids"] = []
		identification["branch_successor_ids"] = ["tech.wild_medicinal_herb_collection"]
		identification["prerequisite_rationales"] = ["该科技需要先掌握 tech.natural_observation。"]
		identification["branch_successor_rationales"] = ["该知识继续发展为 tech.wild_medicinal_herb_collection。"]
		identification["application_target_rationales"] = []
		identification["terminal_reason"] = ""
		identification["reveal_category"] = "biological_observation"
		identification["reveal_summary"] = "由本地药草目击或带来源的药草样本接触揭示。"
		identification["reveal_template_reason"] = "药草具有独立的药性与毒性辨识问题。"
		identification["building_unlock_review"] = {
			"policy": "none",
			"rationale": "辨识只揭示采集路线，不直接授予生产能力。",
		}
		identification["knowledge_basis"] = {
			"required_ids": ["tech.natural_observation"],
			"alternative_groups": [],
			"exemption_reason": "",
		}
		nodes.append(identification)
		by_id["tech.medicinal_herb_identification"] = identification
	if not by_id.has("tech.wild_medicinal_herb_collection"):
		var collection: Dictionary = (by_id.get("tech.wild_spice_collection", {}) as Dictionary).duplicate(true)
		collection["id"] = "tech.wild_medicinal_herb_collection"
		collection["display_name"] = "野生药草采集"
		collection["layout_order"] = 50.6
		collection["secondary_route_tags"] = ["route.crop.medicinal_herb"]
		collection["hard_prerequisite_ids"] = ["tech.medicinal_herb_identification"]
		collection["reveal_condition"] = {}
		collection["expected_bindings"] = []
		collection["content_effects"] = []
		collection["modifier_terms"] = []
		collection["effect_summary"] = "解锁建筑：野生药草采集地；解锁物资：药草。"
		collection["opportunity_cost"] = "需要专门的采集、分拣与安全处理劳动。"
		collection["application_target_ids"] = []
		collection["branch_successor_ids"] = []
		collection["prerequisite_rationales"] = ["该科技需要先掌握 tech.medicinal_herb_identification。"]
		collection["branch_successor_rationales"] = []
		collection["application_target_rationales"] = []
		collection["terminal_reason"] = "野生药草采集是药草产业的自然获取入口，后续由试种、园圃和商业种植继续发展。"
		collection["reveal_category"] = "method_progression"
		collection["reveal_summary"] = "完成野生药草辨识后揭示。"
		collection["reveal_template_reason"] = "药草采集包含独立的安全采收与处理知识。"
		collection["building_unlock_review"] = {
			"policy": "single",
			"rationale": "同代直接提供最低阶野生药草采集设施。",
		}
		collection["knowledge_basis"] = {
			"required_ids": ["tech.medicinal_herb_identification"],
			"alternative_groups": [],
			"exemption_reason": "",
		}
		nodes.append(collection)
		by_id["tech.wild_medicinal_herb_collection"] = collection
	var identification: Dictionary = by_id["tech.medicinal_herb_identification"]
	var collection: Dictionary = by_id["tech.wild_medicinal_herb_collection"]
	identification["research_routes"] = []
	identification["route_exemption_reason"] = "石器时代对象辨识由本地观察或带来源样本直接揭示。"
	collection["research_routes"] = []
	collection["route_exemption_reason"] = "完成药草辨识后直接进入安全采集方法。"
	nodes.erase(identification)
	nodes.erase(collection)
	var insertion_index := 0
	for index in range(nodes.size()):
		if String((nodes[index] as Dictionary).get("id", "")) == "tech.wild_spice_collection":
			insertion_index = index + 1
			break
	nodes.insert(insertion_index, identification)
	nodes.insert(insertion_index + 1, collection)
	payload["nodes"] = nodes


static func _topologically_sort_nodes(payload: Dictionary) -> void:
	var nodes: Array = payload.get("nodes", [])
	var by_id := {}
	var indegree := {}
	var successors := {}
	for value in nodes:
		var node: Dictionary = value
		var id := String(node.get("id", ""))
		by_id[id] = node
		indegree[id] = 0
		successors[id] = []
	for value in nodes:
		var node: Dictionary = value
		var target := String(node.get("id", ""))
		for prerequisite_value in node.get("hard_prerequisite_ids", []):
			_add_sort_edge(String(prerequisite_value), target, by_id, indegree, successors)
	for era_value in payload.get("eras", []):
		var era: Dictionary = era_value
		var milestone := String(era.get("milestone_id", ""))
		for candidate_value in era.get("milestone_candidate_ids", []):
			_add_sort_edge(String(candidate_value), milestone, by_id, indegree, successors)
	var ready := []
	for id in indegree:
		if int(indegree[id]) == 0:
			ready.append(by_id[id])
	var sorted := []
	while not ready.is_empty():
		ready.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var era_a := ERA_IDS.find(String(a.get("era_id", "")))
			var era_b := ERA_IDS.find(String(b.get("era_id", "")))
			if era_a != era_b: return era_a < era_b
			var order_a := float(a.get("layout_order", 0.0))
			var order_b := float(b.get("layout_order", 0.0))
			if order_a != order_b: return order_a < order_b
			return String(a.get("id", "")) < String(b.get("id", "")))
		var node: Dictionary = ready.pop_front()
		var id := String(node.get("id", ""))
		sorted.append(node)
		for successor_value in successors[id]:
			var successor := String(successor_value)
			indegree[successor] = int(indegree[successor]) - 1
			if int(indegree[successor]) == 0:
				ready.append(by_id[successor])
	if sorted.size() != nodes.size():
		MigrationFiles._fail("technology dependency cycle prevents deterministic ordering")
		return
	payload["nodes"] = sorted


static func _reduce_hard_prerequisites(payload: Dictionary) -> void:
	var nodes: Array = payload.get("nodes", [])
	var by_id := {}
	for value in nodes:
		var node: Dictionary = value
		by_id[String(node.get("id", ""))] = node
	for value in nodes:
		var node: Dictionary = value
		var prerequisites: Array = node.get("hard_prerequisite_ids", [])
		var technology_id := String(node.get("id", ""))
		if HARD_PREREQUISITE_OVERRIDES.has(technology_id):
			prerequisites = (HARD_PREREQUISITE_OVERRIDES[technology_id] as Array).duplicate()
		var reduced := []
		for candidate_value in prerequisites:
			var candidate := String(candidate_value)
			var redundant := false
			for other_value in prerequisites:
				var other := String(other_value)
				if other == candidate:
					continue
				if _technology_depends_on(other, candidate, by_id, {}):
					redundant = true
					break
			if not redundant and not reduced.has(candidate):
				reduced.append(candidate)
		node["hard_prerequisite_ids"] = reduced
		node["prerequisite_rationales"] = _rationales_for(reduced,
			"该科技需要先掌握")


static func _technology_depends_on(technology_id: String, ancestor_id: String,
		by_id: Dictionary, visiting: Dictionary) -> bool:
	if technology_id == ancestor_id:
		return true
	if visiting.has(technology_id) or not by_id.has(technology_id):
		return false
	visiting[technology_id] = true
	var node: Dictionary = by_id[technology_id]
	for prerequisite_value in node.get("hard_prerequisite_ids", []):
		if _technology_depends_on(String(prerequisite_value), ancestor_id,
				by_id, visiting):
			return true
	return false


static func _remove_redundant_research_routes(payload: Dictionary) -> void:
	var nodes: Array = payload.get("nodes", [])
	var by_id := {}
	for value in nodes:
		var node: Dictionary = value
		by_id[String(node.get("id", ""))] = node
	for value in nodes:
		var node: Dictionary = value
		var hard_ancestors := {}
		_collect_hard_ancestor_ids(String(node.get("id", "")), by_id, hard_ancestors)
		var retained := []
		for route_value in node.get("research_routes", []):
			var route: Dictionary = route_value
			var route_technologies := []
			_collect_route_technology_ids(route.get("condition", {}), route_technologies)
			var duplicates_core := false
			for technology_value in route_technologies:
				if hard_ancestors.has(String(technology_value)):
					duplicates_core = true
					break
			if not duplicates_core:
				retained.append(route)
		node["research_routes"] = retained
		if retained.is_empty() and String(node.get("route_exemption_reason", "")).strip_edges().is_empty():
			node["route_exemption_reason"] = "不可替代知识已经由可见硬前置完整表达。"


static func _add_sort_edge(source: String, target: String, by_id: Dictionary,
		indegree: Dictionary, successors: Dictionary) -> void:
	if source == target or not by_id.has(source) or not by_id.has(target):
		return
	var targets: Array = successors[source]
	if targets.has(target):
		return
	targets.append(target)
	successors[source] = targets
	indegree[target] = int(indegree[target]) + 1


static func _repair_v4_knowledge_basis(payload: Dictionary) -> void:
	var nodes: Array = payload.get("nodes", [])
	var by_id := {}
	for value in nodes:
		var node: Dictionary = value
		by_id[String(node.get("id", ""))] = node
	for value in nodes:
		var node: Dictionary = value
		var required: Array = (node.get("hard_prerequisite_ids", []) as Array).duplicate()
		var hard_ancestors := {}
		_collect_hard_ancestor_ids(String(node.get("id", "")), by_id, hard_ancestors)
		var alternatives := []
		for route_value in node.get("research_routes", []):
			var route: Dictionary = route_value
			_collect_route_technology_ids(route.get("condition", {}), alternatives)
		var filtered_alternatives := []
		for alternative_value in alternatives:
			var alternative := String(alternative_value)
			if not hard_ancestors.has(alternative) and not filtered_alternatives.has(alternative):
				filtered_alternatives.append(alternative)
		var groups := []
		if not filtered_alternatives.is_empty():
			groups.append(filtered_alternatives)
		var exemption := ""
		if required.is_empty() and groups.is_empty():
			exemption = _knowledge_exemption(node)
		node["knowledge_basis"] = {
			"required_ids": required,
			"alternative_groups": groups,
			"exemption_reason": exemption,
		}


static func _collect_hard_ancestor_ids(technology_id: String, by_id: Dictionary,
		out: Dictionary) -> void:
	if not by_id.has(technology_id):
		return
	var node: Dictionary = by_id[technology_id]
	for prerequisite_value in node.get("hard_prerequisite_ids", []):
		var prerequisite := String(prerequisite_value)
		if out.has(prerequisite):
			continue
		out[prerequisite] = true
		_collect_hard_ancestor_ids(prerequisite, by_id, out)


static func _collect_route_technology_ids(value: Variant, out: Array) -> void:
	if not value is Dictionary:
		return
	var condition: Dictionary = value
	if int(condition.get("kind", -1)) == 0:
		var technology_id := String(condition.get("id", ""))
		if technology_id.begins_with("tech.") and not out.has(technology_id):
			out.append(technology_id)
	for child in condition.get("children", []):
		_collect_route_technology_ids(child, out)
	if condition.has("child"):
		_collect_route_technology_ids(condition.get("child", {}), out)


static func _rationales_for(ids: Array, prefix: String) -> Array:
	var out := []
	for id in ids: out.append("%s %s。" % [prefix, String(id)])
	return out


static func _knowledge_exemption(node: Dictionary) -> String:
	if not (node.get("hard_prerequisite_ids", []) as Array).is_empty(): return ""
	if bool(node.get("is_starter_eligible", false)): return "开局生存能力不依赖更早工艺。"
	if bool(node.get("is_milestone", false)): return "时代里程碑由候选完成数构成。"
	if String(node.get("node_role", "")) == "identification": return "辨识知识由对象证据揭示。"
	return "该基础知识是产业入口。"
