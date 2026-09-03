extends SceneTree

const NETWORK_PATH := "res://data/technology/technology_network.json"
const BUILDING_DIR := "res://data/economy/buildings"
const GOOD_DIR := "res://data/goods"
const RESOURCE_DIR := "res://data/resources"
const MIGRATION_MANIFEST_PATH := \
	"res://tools/technology_tree/technology_industry_v2_migration_manifest.json"
const STABLE_ID_MANIFEST_PATH := \
	"res://tools/technology_tree/technology_industry_v2_stable_id_manifest.json"
const LEGACY_NETWORK_GIT_PATH := \
	"Project/project-keynes/data/technology/technology_network.json"
const LEGACY_DIRECTORY_GIT_PATHS := {
	"buildings": "Project/project-keynes/data/economy/buildings",
	"goods": "Project/project-keynes/data/goods",
	"resources": "Project/project-keynes/data/resources",
}
const ERA_IDS := [
	"stone", "agrarian", "kingdom", "empire", "exploration", "enlightenment",
	"steam", "electrical", "atomic", "information", "intelligent",
]
const MATURITY_NAMES := [
	"", "自然获取", "家户试作", "专业生产", "组织化生产", "机械化", "精准/数字化", "自动化",
]
const SUBSTANTIVE_RENAMES := {
	"tech.application.solar_salt_pan": "tech.solar_evaporation",
	"tech.copper_mining_application": "tech.copper_mine_engineering",
	"tech.application.method_highland_precision_agriculture": "tech.highland_precision_agriculture",
	"tech.application.method_autonomous_forestry": "tech.autonomous_forestry_operations",
}
const SUBSTANTIVE_NAMES := {
	"tech.solar_evaporation": "太阳蒸发制盐",
	"tech.copper_mine_engineering": "铜矿井开采",
	"tech.highland_precision_agriculture": "高地精准农业",
	"tech.autonomous_forestry_operations": "自主林业经营",
}
const APPLICATION_DISPLAY_NAME_OVERRIDES := {
	"app.glassware_workshop_kingdom": "玻璃器皿作坊",
	"app.metal_housewares_workshop_kingdom": "金属家用品作坊",
	"app.leather_goods_workshop_kingdom": "皮革制品作坊",
	"app.glassware_manufactory_exploration": "玻璃器皿工场",
	"app.metal_housewares_manufactory_exploration": "金属家用品工场",
	"app.leather_goods_manufactory_exploration": "皮革制品工场",
	"app.glassware_factory_steam": "玻璃器皿工厂",
	"app.metal_housewares_factory_steam": "金属家用品工厂",
	"app.leather_goods_factory_steam": "皮革制品工厂",
	"app.glassware_factory_electrical": "电气化玻璃器皿工厂",
	"app.metal_housewares_factory_electrical": "电气化金属家用品工厂",
	"app.leather_goods_factory_electrical": "电气化皮革制品工厂",
	"app.glassware_smart_factory": "智能玻璃器皿工厂",
	"app.metal_housewares_smart_factory": "智能金属家用品工厂",
	"app.leather_goods_smart_factory": "智能皮革制品工厂",
}
const HARD_PREREQUISITE_OVERRIDES := {
	# Electronic control is the indispensable technical basis. Laboratories,
	# agricultural computation and institutional scale remain alternative routes.
	"tech.digital_computing": ["tech.electronic_control"],
	"tech.bronze_casting": ["tech.tin_identification", "tech.copper_annealing"],
}
const RETIRED_APPLICATION_TARGETS := {
	"tech.application.wild_tuber_patch": ["tech.wild_tuber_collection"],
	"tech.application.glassware_factory_steam": ["app.glassware_factory_electrical"],
	"tech.application.metal_housewares_factory_steam": ["app.metal_housewares_factory_electrical"],
	"tech.application.leather_goods_factory_steam": ["app.leather_goods_factory_electrical"],
}

var _nodes_by_id := {}
var _application_requirements := {}
var _application_primary := {}
var _application_buildings := {}
var _expansion_visiting := {}


func _init() -> void:
	var payload := _read_json(NETWORK_PATH)
	if payload.is_empty():
		quit(1)
		return
	if int(payload.get("schema_version", 0)) == 4:
		_ensure_medicinal_herb_technologies(payload)
		_reduce_hard_prerequisites(payload)
		_remove_redundant_research_routes(payload)
		_topologically_sort_nodes(payload)
		_repair_v4_knowledge_basis(payload)
		_repair_v4_progression_profiles()
		_repair_v4_intersections(payload)
		_repair_v4_bindings(payload)
		payload["visual_edges"] = _rebuild_visual_edges(payload)
		_write_json(NETWORK_PATH, payload)
		if not _write_release_artifacts(payload):
			quit(1)
			return
		print("[PASS] technology-industry v2 bindings repaired")
		quit(0)
		return
	_replace_stable_ids(payload, SUBSTANTIVE_RENAMES)
	var nodes: Array = payload.get("nodes", [])
	for node_value in nodes:
		var node: Dictionary = node_value
		_nodes_by_id[String(node.get("id", ""))] = node
	for renamed_id in SUBSTANTIVE_NAMES:
		var renamed: Dictionary = _nodes_by_id.get(renamed_id, {})
		if renamed.is_empty():
			_fail("missing substantive application: %s" % renamed_id)
			return
		renamed["display_name"] = SUBSTANTIVE_NAMES[renamed_id]
		renamed["anchor_kind"] = "branch"
		renamed["network_role"] = "branch"
		renamed["node_role"] = "applied_method"
		renamed["reveal_category"] = "method_progression"
		renamed["application_foundation_ids"] = []

	var intersections := []
	var retained := []
	for node_value in nodes:
		var node: Dictionary = node_value
		var id := String(node.get("id", ""))
		if String(node.get("anchor_kind", "")) != "application":
			retained.append(node)
			continue
		var requirements := _expand_application(id)
		if requirements.is_empty():
			_fail("application has no real knowledge foundation: %s" % id)
			return
		var primary := _choose_primary(node, requirements)
		_application_requirements[id] = requirements
		_application_primary[id] = primary
		var buildings := PackedStringArray()
		for binding_value in node.get("expected_bindings", []):
			var binding: Dictionary = binding_value
			if int(binding.get("kind", 0)) == 2:
				buildings.append(String(binding.get("id", "")))
		_application_buildings[id] = buildings
		intersections.append({
			"id": "app.%s" % id.trim_prefix("tech.application."),
			"display_name": String(node.get("display_name", "")).trim_prefix("应用："),
			"description": String(node.get("description", "")),
			"era_id": String(node.get("era_id", "")),
			"domain_id": String(node.get("domain_id", "")),
			"industry_chain_id": String(node.get("branch_family_id", "")),
			"layout_order": float(node.get("layout_order", 0.0)),
			"required_technology_ids": requirements,
			"building_ids": buildings,
		})

	var retained_ids := {}
	for node_value in retained:
		retained_ids[String((node_value as Dictionary).id)] = true
	for node_value in retained:
		var node: Dictionary = node_value
		node["hard_prerequisite_ids"] = _expand_reference_list(
			node.get("hard_prerequisite_ids", []), retained_ids)
		node["prerequisite_rationales"] = _rationales_for(
			node.hard_prerequisite_ids, "该科技需要先掌握")
		node["branch_successor_ids"] = _filter_reference_list(
			node.get("branch_successor_ids", []), retained_ids)
		node["branch_successor_rationales"] = _rationales_for(
			node.branch_successor_ids, "该知识继续发展为")
		node["application_target_ids"] = _filter_reference_list(
			node.get("application_target_ids", []), retained_ids)
		node["application_target_rationales"] = _rationales_for(
			node.application_target_ids, "该知识参与形成")
		node["knowledge_basis"] = {
			"required_ids": (node.hard_prerequisite_ids as Array).duplicate(),
			"alternative_groups": [],
			"exemption_reason": _knowledge_exemption(node),
		}

	_move_application_bindings(retained)
	_rebuild_milestone_candidates(payload, retained)
	payload["nodes"] = retained
	payload["application_intersections"] = intersections
	payload["schema_version"] = 4
	payload["visual_edges"] = _rebuild_visual_edges(payload)
	var review: Dictionary = payload.get("semantic_review", {})
	review["unlock_policy"] = "研究节点只表达独立知识；多科技生产交汇是零成本自动应用，不进入研究状态。"
	review["technology_industry_revision"] = 2
	payload["semantic_review"] = review

	if not _migrate_resources(retained):
		quit(1)
		return
	_write_json(NETWORK_PATH, payload)
	if not _write_release_artifacts(payload):
		quit(1)
		return
	print("[PASS] technology-industry v2: %d research nodes / %d automatic intersections" % [
		retained.size(), intersections.size()])
	quit(0)


func _expand_application(id: String) -> Array:
	if _application_requirements.has(id):
		return (_application_requirements[id] as Array).duplicate()
	if _expansion_visiting.has(id):
		_fail("application dependency cycle: %s" % id)
		return []
	_expansion_visiting[id] = true
	var node: Dictionary = _nodes_by_id.get(id, {})
	var result := []
	for prerequisite_value in node.get("hard_prerequisite_ids", []):
		var prerequisite := String(prerequisite_value)
		if _is_application(prerequisite):
			_append_unique(result, _expand_application(prerequisite))
		else:
			_append_unique(result, [prerequisite])
	_expansion_visiting.erase(id)
	_application_requirements[id] = result
	return result.duplicate()


func _choose_primary(node: Dictionary, requirements: Array) -> String:
	for foundation_value in node.get("application_foundation_ids", []):
		var foundation := String(foundation_value)
		if _is_application(foundation):
			var nested: Dictionary = _nodes_by_id.get(foundation, {})
			return _choose_primary(nested, _expand_application(foundation))
		if requirements.has(foundation):
			return foundation
	return String(requirements[0])


func _move_application_bindings(retained: Array) -> void:
	var retained_by_id := {}
	for node_value in retained:
		retained_by_id[String((node_value as Dictionary).id)] = node_value
	for application_id in _application_primary:
		var primary := String(_application_primary[application_id])
		var target: Dictionary = retained_by_id.get(primary, {})
		var source: Dictionary = _nodes_by_id.get(application_id, {})
		if target.is_empty():
			continue
		for binding_value in source.get("expected_bindings", []):
			_append_unique_dictionary(target, "expected_bindings", binding_value)
		for effect_value in source.get("content_effects", []):
			_append_unique_dictionary(target, "content_effects", effect_value)


func _migrate_resources(retained: Array) -> bool:
	var era_by_technology := {}
	for node_value in retained:
		var node: Dictionary = node_value
		era_by_technology[String(node.id)] = ERA_IDS.find(String(node.era_id))
	var profiles := []
	for path in _resource_paths(BUILDING_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null:
			return _fail_bool("cannot load building: %s" % path)
		var direct := _replace_resource_tags(profile.technology_tags)
		var required := _replace_resource_tags(profile.required_technology_tags)
		for application_id in _application_buildings:
			if not (_application_buildings[application_id] as PackedStringArray).has(String(profile.id)):
				continue
			var primary := String(_application_primary[application_id])
			direct = PackedStringArray([primary])
			for requirement in _application_requirements[application_id]:
				if String(requirement) != primary and not required.has(String(requirement)):
					required.append(String(requirement))
		profile.technology_tags = direct
		profile.required_technology_tags = required
		var era := 0
		for tag in direct:
			era = maxi(era, int(era_by_technology.get(String(tag), 0)))
		var chain_id := String(profile.industry_chain_id).strip_edges()
		if chain_id.is_empty():
			chain_id = _derive_chain_id(profile)
		profile.industry_chain_id = StringName(chain_id)
		profile.progression_step = maxi(1, int(profile.upgrade_tier) if int(profile.upgrade_tier) > 0 else era + 1)
		profile.maturity_rank = clampi(1 + int(floor(float(era) * 6.0 / 10.0)), 1, 7)
		profile.maturity_display_name = MATURITY_NAMES[int(profile.maturity_rank)]
		if String(profile.progression_role).is_empty():
			profile.progression_role = "mainline"
		profiles.append({"path": path, "profile": profile, "era": era, "chain": chain_id})
	_assign_predecessors(profiles)
	for row in profiles:
		if ResourceSaver.save(row.profile, row.path) != OK:
			return _fail_bool("cannot save building: %s" % row.path)
	for path in _resource_paths(GOOD_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null:
			return _fail_bool("cannot load good: %s" % path)
		profile.technology_tags = _replace_resource_tags(profile.technology_tags)
		if ResourceSaver.save(profile, path) != OK:
			return _fail_bool("cannot save good: %s" % path)
	return true


func _assign_predecessors(rows: Array) -> void:
	var by_chain := {}
	for row in rows:
		var chain_rows: Array = by_chain.get(row.chain, [])
		chain_rows.append(row)
		by_chain[row.chain] = chain_rows
	for chain_id in by_chain:
		var chain_rows: Array = by_chain[chain_id]
		chain_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a.era) != int(b.era): return int(a.era) < int(b.era)
			if int(a.profile.progression_step) != int(b.profile.progression_step):
				return int(a.profile.progression_step) < int(b.profile.progression_step)
			return String(a.profile.id) < String(b.profile.id))
		var previous := ""
		for row in chain_rows:
			if (row.profile.predecessor_building_ids as PackedStringArray).is_empty() and not previous.is_empty():
				row.profile.predecessor_building_ids = PackedStringArray([previous])
			previous = String(row.profile.id)


func _derive_chain_id(profile: Resource) -> String:
	var family := String(profile.upgrade_family_id).strip_edges()
	if not family.is_empty():
		return family
	var outputs: PackedStringArray = profile.output_good_ids
	if not outputs.is_empty():
		return "production.%s" % String(outputs[0])
	return "service.%s" % String(profile.id)


func _replace_resource_tags(tags: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for tag_value in tags:
		var tag := String(tag_value)
		if SUBSTANTIVE_RENAMES.has(tag):
			tag = String(SUBSTANTIVE_RENAMES[tag])
		if _application_primary.has(tag):
			tag = String(_application_primary[tag])
		if not out.has(tag):
			out.append(tag)
	return out


func _expand_reference_list(values: Variant, retained_ids: Dictionary) -> Array:
	var out := []
	for value in values:
		var id := String(value)
		if _is_application(id):
			_append_unique(out, _expand_application(id))
		elif retained_ids.has(id):
			_append_unique(out, [id])
	return out


func _filter_reference_list(values: Variant, retained_ids: Dictionary) -> Array:
	var out := []
	for value in values:
		var id := String(value)
		if retained_ids.has(id) and not out.has(id):
			out.append(id)
	return out


func _rebuild_milestone_candidates(payload: Dictionary, retained: Array) -> void:
	var by_id := {}
	for node_value in retained:
		by_id[String((node_value as Dictionary).id)] = node_value
	for era_value in payload.get("eras", []):
		var era: Dictionary = era_value
		var candidates := []
		for candidate_value in era.get("milestone_candidate_ids", []):
			var candidate := String(candidate_value)
			if _application_primary.has(candidate):
				candidate = String(_application_primary[candidate])
			if by_id.has(candidate) and String((by_id[candidate] as Dictionary).era_id) == String(era.id) \
					and candidate != String(era.milestone_id) and not candidates.has(candidate):
				candidates.append(candidate)
		var target := maxi(int(era.get("candidate_required", 4)), candidates.size())
		for node_value in retained:
			var node: Dictionary = node_value
			if candidates.size() >= target:
				break
			if String(node.era_id) == String(era.id) and String(node.id) != String(era.milestone_id) \
					and not candidates.has(String(node.id)):
				candidates.append(String(node.id))
		era["milestone_candidate_ids"] = candidates


func _rebuild_visual_edges(payload: Dictionary) -> Array:
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


func _collect_route_edges(value: Variant, target: String, route_id: String, edges: Array, seen: Dictionary) -> void:
	if not value is Dictionary:
		return
	var condition: Dictionary = value
	if int(condition.get("kind", -1)) == 0:
		_add_edge(edges, seen, String(condition.get("id", "")), target, "alternative", route_id)
	for child in condition.get("children", []):
		_collect_route_edges(child, target, route_id, edges, seen)


func _add_edge(edges: Array, seen: Dictionary, from: String, to: String, kind: String, route_id := "") -> void:
	var key := "%s|%s|%s|%s" % [from, to, kind, route_id]
	if from.is_empty() or to.is_empty() or seen.has(key):
		return
	seen[key] = true
	var edge := {"from": from, "to": to, "kind": kind}
	if not route_id.is_empty(): edge["route_id"] = route_id
	edges.append(edge)


func _replace_stable_ids(value: Variant, replacements: Dictionary) -> Variant:
	if value is Dictionary:
		var dictionary: Dictionary = value
		for key in dictionary.keys():
			dictionary[key] = _replace_stable_ids(dictionary[key], replacements)
		return dictionary
	if value is Array:
		var array: Array = value
		for index in range(array.size()):
			array[index] = _replace_stable_ids(array[index], replacements)
		return array
	if value is String and replacements.has(String(value)):
		return replacements[String(value)]
	return value


func _append_unique(target: Array, values: Array) -> void:
	for value in values:
		if not String(value).is_empty() and not target.has(String(value)):
			target.append(String(value))


func _append_unique_dictionary(node: Dictionary, field: String, value: Variant) -> void:
	var values: Array = node.get(field, [])
	var key := "%s:%s" % [str((value as Dictionary).get("kind", "")), String((value as Dictionary).get("id", ""))]
	for existing_value in values:
		var existing: Dictionary = existing_value
		if "%s:%s" % [str(existing.get("kind", "")), String(existing.get("id", ""))] == key:
			return
	values.append((value as Dictionary).duplicate(true))
	node[field] = values


func _repair_v4_bindings(payload: Dictionary) -> void:
	var nodes_by_id := {}
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		nodes_by_id[String(node.id)] = node
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		node["expected_bindings"] = []
		var retained_effects := []
		for effect_value in node.get("content_effects", []):
			var effect: Dictionary = effect_value
			if String(effect.get("kind", "")) not in ["building", "good"]:
				retained_effects.append(effect)
				var binding_kind := int(effect.get("binding_kind", 0))
				var binding_id := String(effect.get("id", ""))
				if binding_kind > 0 and not binding_id.is_empty():
					_append_unique_dictionary(node, "expected_bindings", {
						"kind": binding_kind,
						"id": binding_id,
					})
		node["content_effects"] = retained_effects
	for path in _resource_paths(BUILDING_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		for tag_value in profile.technology_tags:
			var tag := String(tag_value)
			if not tag.begins_with("tech.") or not nodes_by_id.has(tag): continue
			var node: Dictionary = nodes_by_id[tag]
			_append_unique_dictionary(node, "expected_bindings", {"kind": 2, "id": String(profile.id)})
			_append_unique_dictionary(node, "content_effects", {
				"kind": "building", "id": String(profile.id), "binding_kind": 2,
				"subject": "building.%s" % String(profile.id),
				"attribute": "construction_and_production_access", "operation": "unlock",
				"value": 1, "implementation": "BuildingProfile.technology_tags",
				"status": "catalog_rebind", "display_name": String(profile.display_name),
			})
	for path in _resource_paths(GOOD_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		for tag_value in profile.technology_tags:
			var tag := String(tag_value)
			if not tag.begins_with("tech.") or not nodes_by_id.has(tag): continue
			var node: Dictionary = nodes_by_id[tag]
			_append_unique_dictionary(node, "expected_bindings", {"kind": 1, "id": String(profile.id)})
			_append_unique_dictionary(node, "content_effects", {
				"kind": "good", "id": String(profile.id), "binding_kind": 1,
				"subject": "good.%s" % String(profile.id), "attribute": "production_access",
				"operation": "unlock", "value": 1,
				"implementation": "GoodProfile.technology_tags", "status": "catalog_rebind",
				"display_name": String(profile.display_name),
			})


func _ensure_medicinal_herb_technologies(payload: Dictionary) -> void:
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


func _topologically_sort_nodes(payload: Dictionary) -> void:
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
		_fail("technology dependency cycle prevents deterministic ordering")
		return
	payload["nodes"] = sorted


func _reduce_hard_prerequisites(payload: Dictionary) -> void:
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


func _technology_depends_on(technology_id: String, ancestor_id: String,
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


func _remove_redundant_research_routes(payload: Dictionary) -> void:
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


func _add_sort_edge(source: String, target: String, by_id: Dictionary,
		indegree: Dictionary, successors: Dictionary) -> void:
	if source == target or not by_id.has(source) or not by_id.has(target):
		return
	var targets: Array = successors[source]
	if targets.has(target):
		return
	targets.append(target)
	successors[source] = targets
	indegree[target] = int(indegree[target]) + 1


func _repair_v4_knowledge_basis(payload: Dictionary) -> void:
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


func _collect_hard_ancestor_ids(technology_id: String, by_id: Dictionary,
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


func _collect_route_technology_ids(value: Variant, out: Array) -> void:
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


## Application intersections are derived display data. Rebuild them from the
## complete building gates so stale application-shell prerequisites can never
## survive a content edit.
func _repair_v4_intersections(payload: Dictionary) -> void:
	var nodes_by_id := {}
	for node_value in payload.get("nodes", []):
		var node: Dictionary = node_value
		nodes_by_id[String(node.get("id", ""))] = node
	var previous_by_building := {}
	for value in payload.get("application_intersections", []):
		var previous: Dictionary = value
		for building_value in previous.get("building_ids", []):
			previous_by_building[String(building_value)] = previous
	var intersections := []
	for path in _resource_paths(BUILDING_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null:
			continue
		var requirements := []
		for tag_value in profile.technology_tags:
			var tag := String(tag_value)
			if tag.begins_with("tech.") and not requirements.has(tag):
				requirements.append(tag)
		for tag_value in profile.required_technology_tags:
			var tag := String(tag_value)
			if tag.begins_with("tech.") and not requirements.has(tag):
				requirements.append(tag)
		if requirements.size() < 2:
			continue
		var building_id := String(profile.id)
		var previous: Dictionary = previous_by_building.get(building_id, {})
		var primary: Dictionary = nodes_by_id.get(String(requirements[0]), {})
		var application_id := String(previous.get("id", "app.%s" % building_id))
		var display_name := String(previous.get("display_name", profile.display_name))
		if APPLICATION_DISPLAY_NAME_OVERRIDES.has(application_id):
			display_name = String(APPLICATION_DISPLAY_NAME_OVERRIDES[application_id])
		var era_id := String(previous.get("era_id", primary.get("era_id", "")))
		var domain_id := String(previous.get("domain_id", primary.get("domain_id", "")))
		var family_id := String(previous.get("industry_chain_id",
			primary.get("branch_family_id", "")))
		intersections.append({
			"id": application_id,
			"display_name": display_name,
			"description": "%s由%s项已掌握知识自动形成，不消耗研究点。" % [
				display_name, requirements.size()],
			"era_id": era_id,
			"domain_id": domain_id,
			"industry_chain_id": family_id,
			"layout_order": float(previous.get("layout_order",
				primary.get("layout_order", 0.0))) + (0.01 if previous.is_empty() else 0.0),
			"required_technology_ids": requirements,
			"building_ids": [building_id],
		})
	intersections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if ERA_IDS.find(String(a.era_id)) != ERA_IDS.find(String(b.era_id)):
			return ERA_IDS.find(String(a.era_id)) < ERA_IDS.find(String(b.era_id))
		if float(a.layout_order) != float(b.layout_order):
			return float(a.layout_order) < float(b.layout_order)
		return String(a.id) < String(b.id))
	payload["application_intersections"] = intersections


func _repair_v4_progression_profiles() -> void:
	var by_chain := {}
	for path in _resource_paths(BUILDING_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null:
			continue
		var chain_id := String(profile.industry_chain_id).strip_edges()
		if chain_id.is_empty():
			chain_id = _derive_chain_id(profile)
			profile.industry_chain_id = StringName(chain_id)
		var rows: Array = by_chain.get(chain_id, [])
		rows.append({"path": path, "profile": profile})
		by_chain[chain_id] = rows
	for chain_id in by_chain:
		var rows: Array = by_chain[chain_id]
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var a_profile: Resource = a.profile
			var b_profile: Resource = b.profile
			if int(a_profile.progression_step) != int(b_profile.progression_step):
				return int(a_profile.progression_step) < int(b_profile.progression_step)
			if int(a_profile.maturity_rank) != int(b_profile.maturity_rank):
				return int(a_profile.maturity_rank) < int(b_profile.maturity_rank)
			return String(a_profile.id) < String(b_profile.id))
		var known_ids := {}
		for row in rows:
			known_ids[String(row.profile.id)] = true
		var previous_mainline := ""
		var previous_rank := 1
		for index in range(rows.size()):
			var row: Dictionary = rows[index]
			var profile: Resource = row.profile
			profile.progression_step = index + 1
			profile.maturity_rank = clampi(maxi(previous_rank,
				int(profile.maturity_rank)), 1, 7)
			profile.maturity_display_name = MATURITY_NAMES[int(profile.maturity_rank)]
			var role := String(profile.progression_role)
			if role not in ["entry", "mainline", "specialization", "support", "terminal"]:
				role = "mainline"
			if index == 0:
				role = "entry"
				profile.predecessor_building_ids = PackedStringArray()
				profile.terminal_reason = ""
				previous_mainline = String(profile.id)
			else:
				if role == "entry":
					role = "mainline"
				var valid_predecessors := PackedStringArray()
				for predecessor_value in profile.predecessor_building_ids:
					var predecessor := String(predecessor_value)
					if known_ids.has(predecessor) and predecessor != String(profile.id):
						valid_predecessors.append(predecessor)
				if role not in ["specialization", "support"] or valid_predecessors.is_empty():
					valid_predecessors = PackedStringArray([previous_mainline])
				profile.predecessor_building_ids = valid_predecessors
				if role == "terminal" and String(profile.terminal_reason).strip_edges().is_empty():
					profile.terminal_reason = "%s在当前目录中是该产业路线的合理终点。" % String(profile.display_name)
				elif role != "terminal":
					profile.terminal_reason = ""
				if role not in ["specialization", "support"]:
					previous_mainline = String(profile.id)
			profile.progression_role = role
			previous_rank = int(profile.maturity_rank)
			if ResourceSaver.save(profile, String(row.path)) != OK:
				_fail("cannot save progression profile: %s" % String(row.path))


func _write_release_artifacts(payload: Dictionary) -> bool:
	var legacy := _load_legacy_inventory()
	if legacy.is_empty():
		return _fail_bool("cannot load technology-industry v1 inventory")
	var migration := _build_migration_manifest(payload, legacy)
	if migration.is_empty():
		return false
	_write_json(MIGRATION_MANIFEST_PATH, migration)
	var stable_manifest := _build_stable_id_manifest(payload)
	if stable_manifest.is_empty():
		return false
	_write_json(STABLE_ID_MANIFEST_PATH, stable_manifest)
	return true


func _load_legacy_inventory() -> Dictionary:
	if FileAccess.file_exists(MIGRATION_MANIFEST_PATH):
		var existing := _read_json(MIGRATION_MANIFEST_PATH)
		var stored: Variant = existing.get("legacy_inventory", {})
		if stored is Dictionary and not (stored as Dictionary).is_empty():
			return (stored as Dictionary).duplicate(true)
	var archive_path := ProjectSettings.globalize_path(
		"user://technology_industry_v1_inventory.zip")
	var root_output := []
	var root_exit_code := OS.execute(
		"git", PackedStringArray(["rev-parse", "--show-toplevel"]), root_output, true)
	if root_exit_code != 0:
		_fail("cannot resolve git repository root (%d): %s" % [
			root_exit_code, "".join(root_output)])
		return {}
	var repository_root := "".join(root_output).strip_edges()
	if repository_root.is_empty():
		_fail("git repository root is empty")
		return {}
	var archive_arguments := PackedStringArray([
		"-C", repository_root, "archive", "--format=zip",
		"--output=%s" % archive_path, "HEAD", LEGACY_NETWORK_GIT_PATH,
	])
	for git_path in LEGACY_DIRECTORY_GIT_PATHS.values():
		archive_arguments.append(String(git_path))
	var output := []
	var exit_code := OS.execute("git", archive_arguments, output, true)
	if exit_code != 0:
		_fail("git archive failed (%d): %s" % [exit_code, "".join(output)])
		return {}
	var archive := ZIPReader.new()
	if archive.open(archive_path) != OK:
		_fail("cannot open legacy inventory archive: %s" % archive_path)
		return {}
	var parsed: Variant = JSON.parse_string(
		archive.read_file(LEGACY_NETWORK_GIT_PATH).get_string_from_utf8())
	if not parsed is Dictionary or int((parsed as Dictionary).get("schema_version", 0)) != 3:
		_fail("legacy archive has no schema-v3 network: %s" % LEGACY_NETWORK_GIT_PATH)
		archive.close()
		DirAccess.remove_absolute(archive_path)
		return {}
	var inventory := {
		"source_schema_version": 3,
		"nodes": [],
		"buildings": [],
		"goods": [],
		"resources": [],
	}
	for value in (parsed as Dictionary).get("nodes", []):
		var node: Dictionary = value
		inventory.nodes.append({
			"id": String(node.get("id", "")),
			"display_name": String(node.get("display_name", "")),
			"anchor_kind": String(node.get("anchor_kind", "")),
		})
	for kind in LEGACY_DIRECTORY_GIT_PATHS:
		var prefix := "%s/" % String(LEGACY_DIRECTORY_GIT_PATHS[kind])
		for file_path in archive.get_files():
			if file_path.begins_with(prefix) and file_path.ends_with(".tres"):
				inventory[kind].append(file_path.get_file().trim_suffix(".tres"))
		inventory[kind].sort()
	archive.close()
	DirAccess.remove_absolute(archive_path)
	return inventory


func _build_migration_manifest(payload: Dictionary, legacy: Dictionary) -> Dictionary:
	var technology_ids := _ids_from_dictionaries(payload.get("nodes", []))
	var application_ids := _ids_from_dictionaries(payload.get("application_intersections", []))
	var current_ids := {
		"buildings": _resource_ids(BUILDING_DIR),
		"goods": _resource_ids(GOOD_DIR),
		"resources": _resource_ids(RESOURCE_DIR),
	}
	var technology_set := _id_set(technology_ids)
	var application_set := _id_set(application_ids)
	var classifications := {
		"nodes": [], "buildings": [], "goods": [], "resources": [],
	}
	var seen_nodes := {}
	for value in legacy.get("nodes", []):
		var old: Dictionary = value
		var id := String(old.get("id", ""))
		if id.is_empty() or seen_nodes.has(id):
			_fail("duplicate or empty legacy technology id: %s" % id)
			return {}
		seen_nodes[id] = true
		var classification := ""
		var targets := []
		if technology_set.has(id):
			classification = "retained_technology"
			targets = [id]
		elif SUBSTANTIVE_RENAMES.has(id):
			classification = "renamed_substantive_technology"
			targets = [String(SUBSTANTIVE_RENAMES[id])]
		elif RETIRED_APPLICATION_TARGETS.has(id):
			targets = (RETIRED_APPLICATION_TARGETS[id] as Array).duplicate()
			classification = ("direct_technology_rebind" if id == \
				"tech.application.wild_tuber_patch" else "merged_duplicate_application")
		else:
			var application_id := "app.%s" % id.trim_prefix("tech.application.")
			if String(old.get("anchor_kind", "")) == "application" \
					and application_set.has(application_id):
				classification = "automatic_application"
				targets = [application_id]
		if classification.is_empty():
			_fail("unclassified legacy technology: %s" % id)
			return {}
		classifications.nodes.append({
			"id": id,
			"display_name": String(old.get("display_name", "")),
			"classification": classification,
			"target_ids": targets,
		})
	for kind in ["buildings", "goods", "resources"]:
		var current_set := _id_set(current_ids[kind])
		var seen := {}
		for id_value in legacy.get(kind, []):
			var id := String(id_value)
			if id.is_empty() or seen.has(id):
				_fail("duplicate or empty legacy %s id: %s" % [kind, id])
				return {}
			seen[id] = true
			classifications[kind].append({
				"id": id,
				"classification": "retained" if current_set.has(id) else "retired",
				"target_ids": [id] if current_set.has(id) else [],
			})
	var added := {
		"technologies": _added_ids(technology_ids, _legacy_node_ids(legacy)),
		"applications": _added_application_ids(application_ids, legacy),
		"buildings": _added_ids(current_ids.buildings, legacy.get("buildings", [])),
		"goods": _added_ids(current_ids.goods, legacy.get("goods", [])),
		"resources": _added_ids(current_ids.resources, legacy.get("resources", [])),
	}
	return {
		"schema_version": 1,
		"technology_industry_revision": 2,
		"source_schema_version": int(legacy.get("source_schema_version", 3)),
		"target_schema_version": int(payload.get("schema_version", 0)),
		"legacy_inventory": legacy,
		"classifications": classifications,
		"added_ids": added,
		"legacy_counts": {
			"nodes": (legacy.get("nodes", []) as Array).size(),
			"buildings": (legacy.get("buildings", []) as Array).size(),
			"goods": (legacy.get("goods", []) as Array).size(),
			"resources": (legacy.get("resources", []) as Array).size(),
		},
		"classification_policy": \
			"Every legacy ID appears exactly once; added v2 IDs are listed separately.",
	}


func _build_stable_id_manifest(payload: Dictionary) -> Dictionary:
	var technology_ids := _ids_from_dictionaries(payload.get("nodes", []))
	var application_ids := _ids_from_dictionaries(payload.get("application_intersections", []))
	var building_paths := _resource_paths(BUILDING_DIR)
	var good_paths := _resource_paths(GOOD_DIR)
	var resource_paths := _resource_paths(RESOURCE_DIR)
	var building_ids := _resource_ids(BUILDING_DIR)
	var good_ids := _resource_ids(GOOD_DIR)
	var resource_ids := _resource_ids(RESOURCE_DIR)
	var hashes := {
		"technology_sha256": _sha256_files(PackedStringArray([NETWORK_PATH])),
		"buildings_sha256": _sha256_files(building_paths),
		"goods_sha256": _sha256_files(good_paths),
		"resources_sha256": _sha256_files(resource_paths),
	}
	for key in hashes:
		if String(hashes[key]).is_empty():
			return {}
	var combined_source := "technology:%s\nbuildings:%s\ngoods:%s\nresources:%s\n" % [
		hashes.technology_sha256, hashes.buildings_sha256,
		hashes.goods_sha256, hashes.resources_sha256]
	hashes["combined_sha256"] = _sha256_bytes(combined_source.to_utf8_buffer())
	return {
		"schema_version": 1,
		"technology_industry_revision": 2,
		"technology_network_schema_version": int(payload.get("schema_version", 0)),
		"technology_ids": technology_ids,
		"application_ids": application_ids,
		"building_ids": building_ids,
		"good_ids": good_ids,
		"resource_ids": resource_ids,
		"counts": {
			"technologies": technology_ids.size(),
			"applications": application_ids.size(),
			"buildings": building_ids.size(),
			"goods": good_ids.size(),
			"resources": resource_ids.size(),
		},
		"id_sha256": {
			"technologies": _sha256_id_list(technology_ids),
			"applications": _sha256_id_list(application_ids),
			"buildings": _sha256_id_list(building_ids),
			"goods": _sha256_id_list(good_ids),
			"resources": _sha256_id_list(resource_ids),
		},
		"content_sha256": hashes,
	}


func _resource_ids(directory_path: String) -> Array:
	var ids := []
	for path in _resource_paths(directory_path):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null or String(profile.get("id")).strip_edges().is_empty():
			_fail("cannot load stable ID from resource: %s" % path)
			return []
		ids.append(String(profile.get("id")))
	ids.sort()
	if _id_set(ids).size() != ids.size():
		_fail("duplicate stable resource ID in %s" % directory_path)
		return []
	return ids


func _ids_from_dictionaries(values: Variant) -> Array:
	var ids := []
	for value in values:
		ids.append(String((value as Dictionary).get("id", "")))
	ids.sort()
	return ids


func _legacy_node_ids(legacy: Dictionary) -> Array:
	var ids := []
	for value in legacy.get("nodes", []):
		ids.append(String((value as Dictionary).get("id", "")))
	return ids


func _added_ids(current_ids: Variant, legacy_ids: Variant) -> Array:
	var legacy_set := _id_set(legacy_ids)
	var added := []
	for id_value in current_ids:
		if not legacy_set.has(String(id_value)):
			added.append(String(id_value))
	added.sort()
	return added


func _added_application_ids(application_ids: Array, legacy: Dictionary) -> Array:
	var migrated := {}
	for value in legacy.get("nodes", []):
		var node: Dictionary = value
		if String(node.get("anchor_kind", "")) == "application":
			migrated["app.%s" % String(node.get("id", "")).trim_prefix("tech.application.")] = true
	var added := []
	for id in application_ids:
		if not migrated.has(String(id)):
			added.append(String(id))
	return added


func _id_set(ids: Variant) -> Dictionary:
	var result := {}
	for id in ids:
		result[String(id)] = true
	return result


func _sha256_id_list(ids: Array) -> String:
	return _sha256_bytes(("\n".join(ids) + "\n").to_utf8_buffer())


func _sha256_files(paths: PackedStringArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	for path in paths:
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty() and FileAccess.get_file_as_string(path).is_empty():
			_fail("cannot hash file: %s" % path)
			return ""
		context.update(String(path).replace("\\", "/").to_utf8_buffer())
		context.update(PackedByteArray([0]))
		context.update(bytes)
		context.update(PackedByteArray([0]))
	return context.finish().hex_encode()


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()


func _rationales_for(ids: Array, prefix: String) -> Array:
	var out := []
	for id in ids: out.append("%s %s。" % [prefix, String(id)])
	return out


func _knowledge_exemption(node: Dictionary) -> String:
	if not (node.get("hard_prerequisite_ids", []) as Array).is_empty(): return ""
	if bool(node.get("is_starter_eligible", false)): return "开局生存能力不依赖更早工艺。"
	if bool(node.get("is_milestone", false)): return "时代里程碑由候选完成数构成。"
	if String(node.get("node_role", "")) == "identification": return "辨识知识由对象证据揭示。"
	return "该基础知识是产业入口。"


func _is_application(id: String) -> bool:
	return _nodes_by_id.has(id) and String((_nodes_by_id[id] as Dictionary).get("anchor_kind", "")) == "application"


func _resource_paths(directory_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var directory := DirAccess.open(directory_path)
	if directory == null: return out
	for file_name in directory.get_files():
		if file_name.ends_with(".tres"): out.append("%s/%s" % [directory_path, file_name])
	out.sort()
	return out


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary: return parsed
	_fail("invalid JSON: %s" % path)
	return {}


func _write_json(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload, "\t", false, true) + "\n")
	file.close()


func _fail(message: String) -> void:
	push_error(message)


func _fail_bool(message: String) -> bool:
	_fail(message)
	return false
