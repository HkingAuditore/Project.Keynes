extends SceneTree

const MarkdownReport = preload("res://tools/technology_tree/markdown_report.gd")

# Offline exporter for the authoritative TechnologyCatalog. Run headless:
#   <godot_console.exe> --headless --path . --script res://tools/export_technology_tree.gd
# Reads the Civ-style HTML template, embeds the compiled catalog as JSON, and
# writes self-contained HTML and Markdown reports for tech-tree inspection.
# Deterministic output: no timestamps, catalog order is preserved.

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const GoodProfileRegistryScript = preload("res://scripts/data/good_profile_registry.gd")
const ResourceRegistryScript = preload("res://scripts/data/resource_profile_registry.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")

const TEMPLATE_PATH := "res://tools/technology_tree/technology_tree_template.html"
const HTML_OUTPUT_PATH := "res://tools/technology_tree/technology_tree_report.html"
const MARKDOWN_OUTPUT_PATH := "res://tools/technology_tree/technology_tree_report.md"
const STABLE_ID_MANIFEST_PATH := \
	"res://tools/technology_tree/technology_industry_v2_stable_id_manifest.json"
const PLACEHOLDER := "__TECHNOLOGY_TREE_DATA__"

const EXPECTED_ERA_COUNT := 11
const EXPECTED_DOMAIN_COUNT := 4
const EXPECTED_MILESTONE_REQUIRED_COUNTS := [4, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7]
const MAX_VISUAL_EDGE_COUNT := 10000
const VISUAL_EDGE_KINDS := ["hard", "alternative", "application", "branch", "milestone_candidate"]


func _init() -> void:
	var definitions := TechnologyCatalogScript.public_definitions()
	var applications := TechnologyCatalogScript.public_application_intersections()
	var eras := TechnologyCatalogScript.public_era_metadata()
	var domains := TechnologyCatalogScript.public_domain_metadata()
	var visual_edges := TechnologyCatalogScript.public_visual_edges()
	visual_edges.append_array(TechnologyCatalogScript.public_application_visual_edges())
	var lanes := TechnologyCatalogScript.public_lane_metadata()
	var error := _validate(definitions, applications, eras, domains, visual_edges)
	if error != "":
		push_error("[export_technology_tree] %s" % error)
		quit(1)
		return
	var signal_names := _signal_display_names()
	var tech_names := {}
	for definition in definitions:
		tech_names[String(definition.get("id", ""))] = String(definition.get("display_name", ""))
	for application in applications:
		tech_names[String(application.get("id", ""))] = String(application.get("display_name", ""))
	# Economy content bindings are read through the authoritative EconomyCatalog
	# reverse index (kind 1 = Good, 2 = Building, 3 = Resource), never re-parsed.
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy.get("ok", false)):
		push_error("[export_technology_tree] economy_catalog_compile_failed: %s" % str(economy))
		quit(1)
		return
	var unlocks := _unlock_records(definitions, economy)
	var nodes: Array[Dictionary] = []
	for i in range(definitions.size()):
		nodes.append(_node_record(definitions[i], definitions, tech_names, signal_names,
			unlocks[i]))
	var building_names := _building_display_names()
	for application in applications:
		nodes.append(_application_record(application, building_names))
	var payload := {
		"schema_version": 4,
		"eras": _era_records(eras, definitions, applications),
		"domains": _domain_records(domains),
		"lanes": lanes,
		"edges": visual_edges,
		"nodes": nodes,
		"technology_count": definitions.size(),
		"application_count": applications.size(),
	}
	var template_file := FileAccess.open(TEMPLATE_PATH, FileAccess.READ)
	if template_file == null:
		push_error("[export_technology_tree] template_missing: %s" % TEMPLATE_PATH)
		quit(1)
		return
	var template := template_file.get_as_text()
	template_file.close()
	if template.count(PLACEHOLDER) != 1:
		push_error("[export_technology_tree] template_placeholder_invalid: %s" % TEMPLATE_PATH)
		quit(1)
		return
	var html_report := template.replace(PLACEHOLDER, JSON.stringify(payload))
	var markdown_report := _markdown_report(payload)
	if OS.get_cmdline_user_args().has("--check"):
		var stale_paths := PackedStringArray()
		if not _report_matches(HTML_OUTPUT_PATH, html_report):
			stale_paths.append(HTML_OUTPUT_PATH)
		if not _report_matches(MARKDOWN_OUTPUT_PATH, markdown_report):
			stale_paths.append(MARKDOWN_OUTPUT_PATH)
		if not stale_paths.is_empty():
			push_error("[export_technology_tree] technology_tree_report_stale: %s" %
				", ".join(stale_paths))
			quit(1)
			return
		print("[PASS] technology tree reports are current: %d technologies / %d applications / %d edges" % [
			definitions.size(), applications.size(), visual_edges.size()])
		quit(0)
		return
	if not _write_report(HTML_OUTPUT_PATH, html_report):
		quit(1)
		return
	if not _write_report(MARKDOWN_OUTPUT_PATH, markdown_report):
		quit(1)
		return
	print("[PASS] technology tree reports: %d technologies / %d applications / %d eras -> %s, %s" % [
		definitions.size(), applications.size(), eras.size(), HTML_OUTPUT_PATH,
		MARKDOWN_OUTPUT_PATH])
	quit(0)


func _report_matches(path: String, expected: String) -> bool:
	var report_file := FileAccess.open(path, FileAccess.READ)
	if report_file == null:
		return false
	var actual := report_file.get_as_text()
	report_file.close()
	return actual == expected


func _write_report(path: String, contents: String) -> bool:
	var output_file := FileAccess.open(path, FileAccess.WRITE)
	if output_file == null:
		push_error("[export_technology_tree] output_unwritable: %s" % path)
		return false
	output_file.store_string(contents)
	output_file.close()
	return true


func _validate(definitions: Array[Dictionary], applications: Array[Dictionary],
		eras: Array[Dictionary], domains: Array[Dictionary],
		visual_edges: Array[Dictionary]) -> String:
	if eras.size() != EXPECTED_ERA_COUNT:
		return "era_count_mismatch: %d" % eras.size()
	if domains.size() != EXPECTED_DOMAIN_COUNT:
		return "domain_count_mismatch: %d" % domains.size()
	if visual_edges.is_empty() or visual_edges.size() > MAX_VISUAL_EDGE_COUNT:
		return "visual_edge_count_invalid: %d" % visual_edges.size()
	var order := {}
	for i in range(definitions.size()):
		var technology_id := String(definitions[i].get("id", ""))
		if not technology_id.begins_with("tech.") or order.has(technology_id):
			return "technology_id_invalid: %s" % technology_id
		order[technology_id] = i
	for i in range(applications.size()):
		var application_id := String(applications[i].get("id", ""))
		if not application_id.begins_with("app.") or order.has(application_id):
			return "application_id_invalid: %s" % application_id
		order[application_id] = definitions.size() + i
	var manifest_error := _validate_stable_id_manifest(definitions, applications)
	if manifest_error != "":
		return manifest_error
	var milestone_count := 0
	var milestone_era_index := 0
	for i in range(definitions.size()):
		var definition: Dictionary = definitions[i]
		var id := String(definition.get("id", ""))
		for prerequisite in definition.get("prerequisite_ids", PackedStringArray()):
			var parent := int(order.get(String(prerequisite), -1))
			if parent < 0:
				return "prerequisite_missing: %s" % id
			if parent >= i:
				return "catalog_not_topological: %s" % id
		if bool(definition.get("is_milestone", false)):
			milestone_count += 1
			if int(definition.get("milestone_required_count", 0)) \
					!= EXPECTED_MILESTONE_REQUIRED_COUNTS[milestone_era_index]:
				return "milestone_required_count_invalid: %s" % id
			milestone_era_index += 1
		if (definition.get("route_tags", PackedStringArray()) as PackedStringArray).is_empty():
			return "route_tags_missing: %s" % id
	if milestone_count != EXPECTED_ERA_COUNT:
		return "milestone_count_mismatch: %d" % milestone_count
	for edge in visual_edges:
		var kind := String(edge.get("kind", ""))
		var from_id := String(edge.get("from", ""))
		var to_id := String(edge.get("to", ""))
		if kind not in VISUAL_EDGE_KINDS:
			return "visual_edge_kind_invalid: %s" % kind
		if not order.has(from_id) or not order.has(to_id):
			return "visual_edge_endpoint_missing: %s -> %s" % [from_id, to_id]
	return ""


func _validate_stable_id_manifest(definitions: Array[Dictionary],
		applications: Array[Dictionary]) -> String:
	var file := FileAccess.open(STABLE_ID_MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return "stable_id_manifest_missing: %s" % STABLE_ID_MANIFEST_PATH
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return "stable_id_manifest_invalid"
	var manifest: Dictionary = parsed
	if int(manifest.get("technology_industry_revision", 0)) != 2 \
			or int(manifest.get("technology_network_schema_version", 0)) != 4:
		return "stable_id_manifest_revision_invalid"
	var technology_ids := PackedStringArray()
	for definition in definitions:
		technology_ids.append(String(definition.get("id", "")))
	technology_ids.sort()
	var application_ids := PackedStringArray()
	for application in applications:
		application_ids.append(String(application.get("id", "")))
	application_ids.sort()
	if technology_ids != PackedStringArray(manifest.get("technology_ids", [])):
		return "stable_technology_id_manifest_mismatch"
	if application_ids != PackedStringArray(manifest.get("application_ids", [])):
		return "stable_application_id_manifest_mismatch"
	return ""


# Builds per-technology unlock lists (goods / buildings / resources) from the
# EconomyCatalog content-binding CSR, with Chinese display names resolved
# through the profile registries.
func _unlock_records(definitions: Array[Dictionary], economy: Dictionary) -> Array:
	var out: Array = []
	out.resize(definitions.size())
	var definition_index := {}
	for i in range(definitions.size()):
		definition_index[String(definitions[i].get("id", ""))] = i
	var good_names := {}
	GoodProfileRegistryScript.ensure_loaded()
	for profile in GoodProfileRegistryScript.ordered():
		good_names[String(profile.id)] = String(profile.display_name)
	var resource_names := {}
	ResourceRegistryScript.ensure_loaded()
	for profile in ResourceRegistryScript.ordered():
		resource_names[String(profile.id)] = String(profile.display_name)
	var building_names := _building_display_names()
	var offsets: PackedInt32Array = economy.technology_content_binding_offsets
	var kinds: PackedByteArray = economy.technology_content_binding_kinds
	var ids: PackedStringArray = economy.technology_content_binding_ids
	for i in range(definitions.size()):
		var goods: Array[Dictionary] = []
		var buildings: Array[Dictionary] = []
		var resources: Array[Dictionary] = []
		for edge in range(offsets[i], offsets[i + 1]):
			var binding_id := String(ids[edge])
			match int(kinds[edge]):
				1:
					goods.append({"id": binding_id,
						"name": String(good_names.get(binding_id, binding_id))})
				2:
					buildings.append({"id": binding_id,
						"name": String(building_names.get(binding_id, binding_id))})
				3:
					resources.append({"id": binding_id,
						"name": String(resource_names.get(binding_id, binding_id))})
		out[i] = {"goods": goods, "buildings": buildings, "resources": resources,
			"support_buildings": []}
	var building_ids: PackedStringArray = economy.building_type_ids
	var required_offsets: PackedInt32Array = \
		economy.building_required_technology_tag_offsets
	var required_tags: PackedStringArray = economy.building_required_technology_tags
	for building_index in range(building_ids.size()):
		var building_id := String(building_ids[building_index])
		for edge in range(required_offsets[building_index],
				required_offsets[building_index + 1]):
			var technology_id := String(required_tags[edge])
			var technology_index := int(definition_index.get(technology_id, -1))
			if technology_index < 0:
				continue
			(out[technology_index].support_buildings as Array).append({
				"id": building_id,
				"name": String(building_names.get(building_id, building_id)),
			})
	return out


# Presentation-only name lookup: the building list itself comes from the
# compiled EconomyCatalog CSR; only the display string is read from disk.
func _building_display_names() -> Dictionary:
	var names := {}
	var dir := DirAccess.open(EconomyCatalogScript.BUILDING_DIR)
	if dir == null:
		return names
	for file_name in dir.get_files():
		if not file_name.ends_with(".tres"):
			continue
		var profile := load(EconomyCatalogScript.BUILDING_DIR + "/" + file_name)
		if profile == null:
			continue
		names[String(profile.id)] = String(profile.display_name)
	return names


func _node_record(definition: Dictionary, definitions: Array[Dictionary],
		tech_names: Dictionary, signal_names: Dictionary, unlocks: Dictionary) -> Dictionary:
	var id := String(definition.get("id", ""))
	var successors := PackedStringArray()
	var hard_successors := PackedStringArray()
	var hard_successor_rationales := PackedStringArray()
	var candidate_milestones := PackedStringArray()
	for other in definitions:
		var prerequisites: PackedStringArray = other.get("prerequisite_ids", PackedStringArray())
		var candidates: PackedStringArray = other.get("milestone_candidate_ids", PackedStringArray())
		var other_id := String(other.get("id", ""))
		if prerequisites.has(id):
			hard_successors.append(other_id)
			var rationale_index := prerequisites.find(id)
			var other_rationales: PackedStringArray = other.get(
				"prerequisite_rationales", PackedStringArray())
			hard_successor_rationales.append(String(other_rationales[rationale_index]) \
				if rationale_index >= 0 and rationale_index < other_rationales.size() else "")
			successors.append(other_id)
		if bool(other.get("is_milestone", false)) and candidates.has(id):
			candidate_milestones.append(other_id)
			if not successors.has(other_id):
				successors.append(other_id)
	var condition: Dictionary = definition.get("research_condition", {})
	var condition_lines: Array[Dictionary] = []
	if not condition.is_empty():
		_append_condition_lines(condition, 0, condition_lines, tech_names, signal_names)
	var reveal_condition: Dictionary = definition.get("reveal_condition", {})
	var reveal_condition_lines: Array[Dictionary] = []
	if not reveal_condition.is_empty():
		_append_condition_lines(reveal_condition, 0, reveal_condition_lines,
			tech_names, signal_names)
	var milestone_names := PackedStringArray()
	for candidate in definition.get("milestone_candidate_ids", PackedStringArray()):
		milestone_names.append(String(tech_names.get(String(candidate), String(candidate))))
	return {
		"id": id,
		"display_name": String(definition.get("display_name", "")),
		"era_id": String(definition.get("era_id", "")),
		"domain_id": String(definition.get("domain_id", "")),
		"cost_points": int(definition.get("cost_points", 0)),
		"prerequisite_ids": definition.get("prerequisite_ids", PackedStringArray()),
		"prerequisite_rationales": definition.get(
			"prerequisite_rationales", PackedStringArray()),
		"successor_ids": successors,
		"hard_successor_ids": hard_successors,
		"hard_successor_rationales": hard_successor_rationales,
		"candidate_milestone_ids": candidate_milestones,
		"is_milestone": bool(definition.get("is_milestone", false)),
		"is_era_key": bool(definition.get("is_era_key", false)),
		"is_starting": bool(definition.get("is_starting", false)),
		"is_starter_eligible": bool(definition.get("is_starter_eligible", false)),
		"node_role": String(definition.get("node_role", "")),
		"network_role": String(definition.get("network_role", "")),
		"anchor_kind": String(definition.get("anchor_kind", "")),
		"primary_route_tag": String(definition.get("primary_route_tag", "")),
		"layout_lane": String(definition.get("layout_lane", "")),
		"starter_capability_tags": definition.get(
			"starter_capability_tags", PackedStringArray()),
		"milestone_candidate_ids": definition.get("milestone_candidate_ids", PackedStringArray()),
		"milestone_candidate_names": milestone_names,
		"milestone_required_count": int(definition.get("milestone_required_count", 0)),
		"effect_summary": String(definition.get("effect_summary", "")),
		"effect_profile": String(definition.get("effect_profile", "")),
		"route_tags": definition.get("route_tags", PackedStringArray()),
		"route_display_names": definition.get("route_display_names", PackedStringArray()),
		"condition_lines": condition_lines,
		"reveal_condition_lines": reveal_condition_lines,
		"modifier_terms": _node_modifier_terms(definition),
		"content_effects": (definition.get("content_effects", []) as Array).duplicate(true),
		"opportunity_cost": String(definition.get("opportunity_cost", "")),
		"topology_review": (definition.get("topology_review", {}) as Dictionary).duplicate(true),
		"building_unlock_review": (definition.get(
			"building_unlock_review", {}) as Dictionary).duplicate(true),
		"branch_successor_ids": definition.get(
			"branch_successor_ids", PackedStringArray()),
		"branch_successor_rationales": definition.get(
			"branch_successor_rationales", PackedStringArray()),
		"application_target_ids": definition.get(
			"application_target_ids", PackedStringArray()),
		"application_target_rationales": definition.get(
			"application_target_rationales", PackedStringArray()),
		"terminal_reason": String(definition.get("terminal_reason", "")),
		"unlocks": unlocks,
	}


func _application_record(application: Dictionary, building_names: Dictionary) -> Dictionary:
	var required_ids := PackedStringArray(application.get("required_technology_ids", []))
	var rationales := PackedStringArray()
	for _required_id in required_ids:
		rationales.append("该知识是此产业交汇自动生效的必要条件。")
	var buildings: Array[Dictionary] = []
	for building_id_value in application.get("building_ids", PackedStringArray()):
		var building_id := String(building_id_value)
		buildings.append({
			"id": building_id,
			"name": String(building_names.get(building_id, building_id)),
		})
	return {
		"id": String(application.get("id", "")),
		"display_name": String(application.get("display_name", "")),
		"era_id": String(application.get("era_id", "")),
		"domain_id": String(application.get("domain_id", "")),
		"cost_points": 0,
		"prerequisite_ids": required_ids,
		"prerequisite_rationales": rationales,
		"successor_ids": PackedStringArray(),
		"hard_successor_ids": PackedStringArray(),
		"hard_successor_rationales": PackedStringArray(),
		"candidate_milestone_ids": PackedStringArray(),
		"is_milestone": false,
		"is_era_key": false,
		"is_starting": false,
		"is_starter_eligible": false,
		"is_automatic_application": true,
		"node_role": "automatic_application",
		"network_role": "application",
		"anchor_kind": "application_intersection",
		"primary_route_tag": "",
		"layout_lane": String(application.get("layout_lane",
			application.get("industry_chain_id", ""))),
		"starter_capability_tags": PackedStringArray(),
		"milestone_candidate_ids": PackedStringArray(),
		"milestone_candidate_names": PackedStringArray(),
		"milestone_required_count": 0,
		"effect_summary": "全部所需科技完成后自动应用；不进入研究队列、进度、Modifier 或存档。",
		"effect_profile": "",
		"route_tags": PackedStringArray(),
		"route_display_names": PackedStringArray(),
		"condition_lines": [],
		"reveal_condition_lines": [],
		"modifier_terms": [],
		"content_effects": [],
		"opportunity_cost": "无需研究点。",
		"topology_review": {},
		"building_unlock_review": {},
		"branch_successor_ids": PackedStringArray(),
		"branch_successor_rationales": PackedStringArray(),
		"application_target_ids": PackedStringArray(),
		"application_target_rationales": PackedStringArray(),
		"terminal_reason": "",
		"unlocks": {
			"goods": [],
			"buildings": buildings,
			"resources": [],
			"support_buildings": [],
		},
	}


func _node_modifier_terms(definition: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for term_value in definition.get("modifier_terms", []):
		out.append((term_value as Dictionary).duplicate(true))
	return out


func _signal_display_names() -> Dictionary:
	var out := {}
	for entry in ResearchSignalCatalogScript.public_metadata():
		out[String(entry.get("id", ""))] = String(entry.get("display_name", ""))
	return out


func _append_condition_lines(spec, depth: int, lines: Array[Dictionary],
		tech_names: Dictionary, signal_names: Dictionary) -> void:
	if spec is ResearchPredicateScript:
		lines.append({"depth": depth, "text": _predicate_text({
			"kind": int(spec.kind), "id": String(spec.reference_id),
			"value": int(spec.value)}, tech_names, signal_names)})
		return
	if spec is Dictionary and spec.has("kind"):
		lines.append({"depth": depth, "text": _predicate_text(spec, tech_names, signal_names)})
		return
	var operator_value := -1
	var children: Array = []
	var required_count := 0
	if spec is ResearchConditionScript:
		operator_value = int(spec.operator)
		children = spec.children
		required_count = int(spec.required_count)
	elif spec is Dictionary:
		operator_value = int(spec.get("operator", -1))
		children = spec.get("children", [])
		required_count = int(spec.get("required_count", 0))
	else:
		lines.append({"depth": depth, "text": "（无法识别的条件节点）"})
		return
	if operator_value == ResearchConditionScript.Operator.ATOM:
		var atom = spec.atom if spec is ResearchConditionScript else (spec as Dictionary).get("atom", null)
		_append_condition_lines(atom, depth, lines, tech_names, signal_names)
		return
	match operator_value:
		ResearchConditionScript.Operator.ALL_OF:
			lines.append({"depth": depth, "text": "全部满足："})
		ResearchConditionScript.Operator.ANY_OF:
			lines.append({"depth": depth, "text": "满足其一："})
		ResearchConditionScript.Operator.AT_LEAST:
			lines.append({"depth": depth, "text": "至少满足 %d 项：" % required_count})
		ResearchConditionScript.Operator.NOT:
			lines.append({"depth": depth, "text": "不满足："})
		ResearchConditionScript.Operator.NONE_OF:
			lines.append({"depth": depth, "text": "全部不满足："})
		_:
			lines.append({"depth": depth, "text": "（暂不支持的条件算子 %d）" % operator_value})
	for child in children:
		_append_condition_lines(child, depth + 1, lines, tech_names, signal_names)


func _predicate_text(predicate: Dictionary, tech_names: Dictionary,
		signal_names: Dictionary) -> String:
	var kind := int(predicate.get("kind", -1))
	var id := String(predicate.get("id", predicate.get("reference_id", "")))
	var value := int(predicate.get("value", 1))
	match kind:
		ResearchPredicateScript.Kind.TECH_COMPLETED:
			return "已完成科技「%s」（%s）" % [String(tech_names.get(id, id)), id]
		ResearchPredicateScript.Kind.SIGNAL_PRESENT:
			return "已发现信号「%s」（%s）" % [String(signal_names.get(id, id)), id]
		ResearchPredicateScript.Kind.SIGNAL_COUNT:
			return "信号「%s」（%s）数量 ≥ %d" % [String(signal_names.get(id, id)), id, value]
	return "（暂不支持的条件谓词 %d：%s）" % [kind, id]


func _era_records(eras: Array[Dictionary], definitions: Array[Dictionary],
		applications: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for era in eras:
		var era_id := String(era.get("id", ""))
		var technology_count := 0
		var application_count := 0
		var min_cost := -1
		var max_cost := 0
		for definition in definitions:
			if String(definition.get("era_id", "")) != era_id:
				continue
			technology_count += 1
			var cost := int(definition.get("cost_points", 0))
			min_cost = cost if min_cost < 0 else mini(min_cost, cost)
			max_cost = maxi(max_cost, cost)
		for application in applications:
			if String(application.get("era_id", "")) == era_id:
				application_count += 1
		out.append({
			"id": era_id,
			"display_name": String(era.get("display_name", era_id)),
			"milestone_id": String(era.get("milestone_id", "")),
			"node_count": technology_count + application_count,
			"technology_count": technology_count,
			"application_count": application_count,
			"min_cost": maxi(min_cost, 0),
			"max_cost": max_cost,
		})
	return out


func _domain_records(domains: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for domain in domains:
		var accent: Color = domain.get("accent", Color.WHITE)
		out.append({
			"id": String(domain.get("id", "")),
			"display_name": String(domain.get("display_name", "")),
			"accent": "#" + accent.to_html(false),
		})
	return out


func _markdown_report(payload: Dictionary) -> String:
	return MarkdownReport._markdown_report(payload)
