extends SceneTree

const MigrationFiles = preload("res://tools/technology_tree/industry_migration_files.gd")

const MigrationGraph = preload("res://tools/technology_tree/industry_migration_graph.gd")

const ReleaseArtifacts = preload("res://tools/technology_tree/industry_migration_release_artifacts.gd")

const MATURITY_NAMES := [
	"", "自然获取", "家户试作", "专业生产", "组织化生产", "机械化", "精准/数字化", "自动化",
]
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
var _nodes_by_id := {}
var _application_requirements := {}
var _application_primary := {}
var _application_buildings := {}
var _expansion_visiting := {}


func _init() -> void:
	var payload := MigrationFiles._read_json(MigrationFiles.NETWORK_PATH)
	if payload.is_empty():
		quit(1)
		return
	if int(payload.get("schema_version", 0)) == 4:
		MigrationGraph._ensure_medicinal_herb_technologies(payload)
		MigrationGraph._reduce_hard_prerequisites(payload)
		MigrationGraph._remove_redundant_research_routes(payload)
		MigrationGraph._topologically_sort_nodes(payload)
		MigrationGraph._repair_v4_knowledge_basis(payload)
		_repair_v4_progression_profiles()
		_repair_v4_intersections(payload)
		_repair_v4_bindings(payload)
		payload["visual_edges"] = MigrationGraph._rebuild_visual_edges(payload)
		MigrationFiles._write_json(MigrationFiles.NETWORK_PATH, payload)
		if not ReleaseArtifacts._write_release_artifacts(payload):
			quit(1)
			return
		print("[PASS] technology-industry v2 bindings repaired")
		quit(0)
		return
	_replace_stable_ids(payload, MigrationFiles.SUBSTANTIVE_RENAMES)
	var nodes: Array = payload.get("nodes", [])
	for node_value in nodes:
		var node: Dictionary = node_value
		_nodes_by_id[String(node.get("id", ""))] = node
	for renamed_id in SUBSTANTIVE_NAMES:
		var renamed: Dictionary = _nodes_by_id.get(renamed_id, {})
		if renamed.is_empty():
			MigrationFiles._fail("missing substantive application: %s" % renamed_id)
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
			MigrationFiles._fail("application has no real knowledge foundation: %s" % id)
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
		node["prerequisite_rationales"] = MigrationGraph._rationales_for(
			node.hard_prerequisite_ids, "该科技需要先掌握")
		node["branch_successor_ids"] = _filter_reference_list(
			node.get("branch_successor_ids", []), retained_ids)
		node["branch_successor_rationales"] = MigrationGraph._rationales_for(
			node.branch_successor_ids, "该知识继续发展为")
		node["application_target_ids"] = _filter_reference_list(
			node.get("application_target_ids", []), retained_ids)
		node["application_target_rationales"] = MigrationGraph._rationales_for(
			node.application_target_ids, "该知识参与形成")
		node["knowledge_basis"] = {
			"required_ids": (node.hard_prerequisite_ids as Array).duplicate(),
			"alternative_groups": [],
			"exemption_reason": MigrationGraph._knowledge_exemption(node),
		}

	_move_application_bindings(retained)
	_rebuild_milestone_candidates(payload, retained)
	payload["nodes"] = retained
	payload["application_intersections"] = intersections
	payload["schema_version"] = 4
	payload["visual_edges"] = MigrationGraph._rebuild_visual_edges(payload)
	var review: Dictionary = payload.get("semantic_review", {})
	review["unlock_policy"] = "研究节点只表达独立知识；多科技生产交汇是零成本自动应用，不进入研究状态。"
	review["technology_industry_revision"] = 2
	payload["semantic_review"] = review

	if not _migrate_resources(retained):
		quit(1)
		return
	MigrationFiles._write_json(MigrationFiles.NETWORK_PATH, payload)
	if not ReleaseArtifacts._write_release_artifacts(payload):
		quit(1)
		return
	print("[PASS] technology-industry v2: %d research nodes / %d automatic intersections" % [
		retained.size(), intersections.size()])
	quit(0)


func _expand_application(id: String) -> Array:
	if _application_requirements.has(id):
		return (_application_requirements[id] as Array).duplicate()
	if _expansion_visiting.has(id):
		MigrationFiles._fail("application dependency cycle: %s" % id)
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
		era_by_technology[String(node.id)] = MigrationGraph.ERA_IDS.find(String(node.era_id))
	var profiles := []
	for path in MigrationFiles._resource_paths(MigrationFiles.BUILDING_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null:
			return MigrationFiles._fail_bool("cannot load building: %s" % path)
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
			return MigrationFiles._fail_bool("cannot save building: %s" % row.path)
	for path in MigrationFiles._resource_paths(MigrationFiles.GOOD_DIR):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null:
			return MigrationFiles._fail_bool("cannot load good: %s" % path)
		profile.technology_tags = _replace_resource_tags(profile.technology_tags)
		if ResourceSaver.save(profile, path) != OK:
			return MigrationFiles._fail_bool("cannot save good: %s" % path)
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
		if MigrationFiles.SUBSTANTIVE_RENAMES.has(tag):
			tag = String(MigrationFiles.SUBSTANTIVE_RENAMES[tag])
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
	for path in MigrationFiles._resource_paths(MigrationFiles.BUILDING_DIR):
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
	for path in MigrationFiles._resource_paths(MigrationFiles.GOOD_DIR):
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
	for path in MigrationFiles._resource_paths(MigrationFiles.BUILDING_DIR):
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
		if MigrationGraph.ERA_IDS.find(String(a.era_id)) != MigrationGraph.ERA_IDS.find(String(b.era_id)):
			return MigrationGraph.ERA_IDS.find(String(a.era_id)) < MigrationGraph.ERA_IDS.find(String(b.era_id))
		if float(a.layout_order) != float(b.layout_order):
			return float(a.layout_order) < float(b.layout_order)
		return String(a.id) < String(b.id))
	payload["application_intersections"] = intersections


func _repair_v4_progression_profiles() -> void:
	var by_chain := {}
	for path in MigrationFiles._resource_paths(MigrationFiles.BUILDING_DIR):
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
				MigrationFiles._fail("cannot save progression profile: %s" % String(row.path))


func _is_application(id: String) -> bool:
	return _nodes_by_id.has(id) and String((_nodes_by_id[id] as Dictionary).get("anchor_kind", "")) == "application"
