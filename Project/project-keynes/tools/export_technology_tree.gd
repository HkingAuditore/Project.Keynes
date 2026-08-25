extends SceneTree

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
const PLACEHOLDER := "__TECHNOLOGY_TREE_DATA__"

const EXPECTED_NODE_COUNT := 661
const EXPECTED_ERA_COUNT := 11
const EXPECTED_DOMAIN_COUNT := 4
const EXPECTED_MILESTONE_CANDIDATE_COUNTS := [8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18]
const EXPECTED_MILESTONE_REQUIRED_COUNTS := [4, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7]
const MAX_VISUAL_EDGE_COUNT := 4000
const VISUAL_EDGE_KINDS := ["hard", "alternative", "application", "branch", "milestone_candidate"]


func _init() -> void:
	var definitions := TechnologyCatalogScript.public_definitions()
	var eras := TechnologyCatalogScript.public_era_metadata()
	var domains := TechnologyCatalogScript.public_domain_metadata()
	var visual_edges := TechnologyCatalogScript.public_visual_edges()
	var lanes := TechnologyCatalogScript.public_lane_metadata()
	var error := _validate(definitions, eras, domains, visual_edges)
	if error != "":
		push_error("[export_technology_tree] %s" % error)
		quit(1)
		return
	var signal_names := _signal_display_names()
	var tech_names := {}
	for definition in definitions:
		tech_names[String(definition.get("id", ""))] = String(definition.get("display_name", ""))
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
	var payload := {
		"eras": _era_records(eras, definitions),
		"domains": _domain_records(domains),
		"lanes": lanes,
		"edges": visual_edges,
		"nodes": nodes,
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
		print("[PASS] technology tree reports are current: %d nodes / %d edges" % [
			nodes.size(), visual_edges.size()])
		quit(0)
		return
	if not _write_report(HTML_OUTPUT_PATH, html_report):
		quit(1)
		return
	if not _write_report(MARKDOWN_OUTPUT_PATH, markdown_report):
		quit(1)
		return
	print("[PASS] technology tree reports: %d nodes / %d eras -> %s, %s" % [
		nodes.size(), eras.size(), HTML_OUTPUT_PATH, MARKDOWN_OUTPUT_PATH])
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


func _validate(definitions: Array[Dictionary], eras: Array[Dictionary],
		domains: Array[Dictionary], visual_edges: Array[Dictionary]) -> String:
	if definitions.size() != EXPECTED_NODE_COUNT:
		return "node_count_mismatch: %d" % definitions.size()
	if eras.size() != EXPECTED_ERA_COUNT:
		return "era_count_mismatch: %d" % eras.size()
	if domains.size() != EXPECTED_DOMAIN_COUNT:
		return "domain_count_mismatch: %d" % domains.size()
	if visual_edges.is_empty() or visual_edges.size() > MAX_VISUAL_EDGE_COUNT:
		return "visual_edge_count_invalid: %d" % visual_edges.size()
	var order := {}
	for i in range(definitions.size()):
		order[String(definitions[i].get("id", ""))] = i
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
			if (definition.get("milestone_candidate_ids", PackedStringArray())
					as PackedStringArray).size() != EXPECTED_MILESTONE_CANDIDATE_COUNTS[
					milestone_era_index]:
				return "milestone_candidate_count_invalid: %s" % id
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


func _era_records(eras: Array[Dictionary], definitions: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for era in eras:
		var era_id := String(era.get("id", ""))
		var count := 0
		var min_cost := -1
		var max_cost := 0
		for definition in definitions:
			if String(definition.get("era_id", "")) != era_id:
				continue
			count += 1
			var cost := int(definition.get("cost_points", 0))
			min_cost = cost if min_cost < 0 else mini(min_cost, cost)
			max_cost = maxi(max_cost, cost)
		out.append({
			"id": era_id,
			"display_name": String(era.get("display_name", era_id)),
			"milestone_id": String(era.get("milestone_id", "")),
			"node_count": count,
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
	var eras: Array = payload.get("eras", [])
	var domains: Array = payload.get("domains", [])
	var nodes: Array = payload.get("nodes", [])
	var edges: Array = payload.get("edges", [])
	var tech_names := {}
	var domain_names := {}
	var milestone_count := 0
	var edge_kind_counts := {}
	for domain in domains:
		domain_names[String(domain.get("id", ""))] = String(domain.get("display_name", ""))
	for node in nodes:
		tech_names[String(node.get("id", ""))] = String(node.get("display_name", ""))
		if bool(node.get("is_milestone", false)):
			milestone_count += 1
	for edge in edges:
		var kind := String((edge as Dictionary).get("kind", ""))
		edge_kind_counts[kind] = int(edge_kind_counts.get(kind, 0)) + 1

	var lines := PackedStringArray()
	lines.append("# 科技目录审计报告")
	lines.append("")
	lines.append("> 自动生成文件，请勿手工编辑。权威来源为 `TechnologyCatalog`；内容解锁来自已编译的 `EconomyCatalog` 反向绑定。")
	lines.append("")
	lines.append("## 总览")
	lines.append("")
	lines.append("| 项目 | 数量 |")
	lines.append("| --- | ---: |")
	lines.append("| 科技 | %d |" % nodes.size())
	lines.append("| 时代 | %d |" % eras.size())
	lines.append("| 领域 | %d |" % domains.size())
	lines.append("| 里程碑 | %d |" % milestone_count)
	lines.append("| 硬前置边 | %d |" % int(edge_kind_counts.get("hard", 0)))
	lines.append("| 应用交汇边 | %d |" % int(edge_kind_counts.get("application", 0)))
	lines.append("| 替代说明边 | %d |" % int(edge_kind_counts.get("alternative", 0)))
	lines.append("| 分支关系边 | %d |" % int(edge_kind_counts.get("branch", 0)))
	lines.append("| 里程碑候选边 | %d |" % int(
		edge_kind_counts.get("milestone_candidate", 0)))
	lines.append("")
	lines.append("## 时代目录")
	lines.append("")
	for era_index in range(eras.size()):
		var era: Dictionary = eras[era_index]
		lines.append("- [%s](#era-%d)（%d 项，成本 %d-%d）" % [
			_md_inline(String(era.get("display_name", era.get("id", "")))),
			era_index + 1,
			int(era.get("node_count", 0)),
			int(era.get("min_cost", 0)),
			int(era.get("max_cost", 0)),
		])

	for era_index in range(eras.size()):
		var era: Dictionary = eras[era_index]
		var era_id := String(era.get("id", ""))
		lines.append("")
		lines.append("<a id=\"era-%d\"></a>" % (era_index + 1))
		lines.append("## %s" % _md_inline(String(era.get("display_name", era_id))))
		lines.append("")
		lines.append("共 %d 项科技，研究成本范围 %d-%d；时代里程碑：%s。" % [
			int(era.get("node_count", 0)),
			int(era.get("min_cost", 0)),
			int(era.get("max_cost", 0)),
			_named_technology(String(era.get("milestone_id", "")), tech_names),
		])
		for node in nodes:
			if String(node.get("era_id", "")) == era_id:
				_append_markdown_node(lines, node, era, domain_names, tech_names)
	return "\n".join(lines) + "\n"


func _append_markdown_node(lines: PackedStringArray, node: Dictionary, era: Dictionary,
		domain_names: Dictionary, tech_names: Dictionary) -> void:
	var id := String(node.get("id", ""))
	var domain_id := String(node.get("domain_id", ""))
	var flags := PackedStringArray()
	if bool(node.get("is_starting", false)):
		flags.append("开局科技")
	if bool(node.get("is_starter_eligible", false)):
		flags.append("区域开局候选")
	if bool(node.get("is_era_key", false)):
		flags.append("时代关键")
	if bool(node.get("is_milestone", false)):
		flags.append("时代里程碑")

	lines.append("")
	lines.append("### %s (`%s`)" % [
		_md_inline(String(node.get("display_name", id))), _md_code(id)])
	lines.append("")
	lines.append("| 字段 | 内容 |")
	lines.append("| --- | --- |")
	lines.append("| 稳定 ID | `%s` |" % _md_code(id))
	lines.append("| 时代 | %s (`%s`) |" % [
		_md_table(String(era.get("display_name", node.get("era_id", "")))),
		_md_code(String(node.get("era_id", "")))])
	lines.append("| 领域 | %s (`%s`) |" % [
		_md_table(String(domain_names.get(domain_id, domain_id))), _md_code(domain_id)])
	lines.append("| 研究成本 | %d 科技点（`technology_points`） |" % int(node.get("cost_points", 0)))
	lines.append("| 节点标记 | %s |" % _md_table("、".join(flags) if not flags.is_empty() else "无"))
	lines.append("| 网络角色 | %s |" % _md_table(_value_or_none(
		node.get("network_role", ""))))
	lines.append("| 锚点类型 | %s |" % _md_table(_value_or_none(
		node.get("anchor_kind", ""))))
	lines.append("| 节点角色 | %s |" % _md_table(_value_or_none(node.get("node_role", ""))))
	lines.append("| 布局路线 | %s |" % _md_table(_value_or_none(node.get("layout_lane", ""))))
	lines.append("| 主要路线 | %s |" % _md_table(_route_value(
		String(node.get("primary_route_tag", "")), node)))
	lines.append("| 全部路线 | %s |" % _md_table(_route_values(node)))
	var topology_review: Dictionary = node.get("topology_review", {})
	if not topology_review.is_empty():
		lines.append("| 拓扑审查 | %s：%s |" % [
			_md_table(String(topology_review.get("role", ""))),
			_md_table(String(topology_review.get("rationale", ""))),
		])
	var building_review: Dictionary = node.get("building_unlock_review", {})
	if not building_review.is_empty():
		lines.append("| 建筑解锁审查 | %s：%s |" % [
			_md_table(String(building_review.get("policy", ""))),
			_md_table(String(building_review.get("rationale", ""))),
		])
	lines.append("| 开局能力标签 | %s |" % _md_table(_id_values(
		node.get("starter_capability_tags", PackedStringArray()))))
	lines.append("| 效果配置 | %s |" % _md_table(_value_or_none(node.get("effect_profile", ""))))

	_append_relation_section(lines, "硬前置（决定研发资格）",
		node.get("prerequisite_ids", PackedStringArray()),
		node.get("prerequisite_rationales", PackedStringArray()), tech_names)
	if not (node.get("condition_lines", []) as Array).is_empty():
		_append_condition_section(lines, "额外研发条件", node.get("condition_lines", []))
	_append_condition_section(lines, "发现启发（仅用于揭示）",
		node.get("reveal_condition_lines", []))

	lines.append("")
	lines.append("#### 效果摘要")
	lines.append("")
	lines.append(_md_inline(_value_or_none(node.get("effect_summary", ""))))
	lines.append("")
	lines.append("#### 机会成本")
	lines.append("")
	lines.append(_md_inline(_value_or_none(node.get("opportunity_cost", ""))))

	if bool(node.get("is_milestone", false)):
		lines.append("")
		lines.append("#### 里程碑候选")
		lines.append("")
		lines.append("需要完成下列 %d 项候选中的任意 %d 项：" % [
			(node.get("milestone_candidate_ids", PackedStringArray()) as PackedStringArray).size(),
			int(node.get("milestone_required_count", 0)),
		])
		_append_named_id_items(lines,
			node.get("milestone_candidate_ids", PackedStringArray()), tech_names)

	_append_unlock_section(lines, node.get("unlocks", {}))
	_append_content_effect_section(lines, node.get("content_effects", []))
	_append_modifier_section(lines, node.get("modifier_terms", []))
	_append_relation_section(lines, "被以下科技作为硬前置",
		node.get("hard_successor_ids", PackedStringArray()),
		node.get("hard_successor_rationales", PackedStringArray()), tech_names)
	_append_relation_section(lines, "主题路线后继",
		node.get("branch_successor_ids", PackedStringArray()),
		node.get("branch_successor_rationales", PackedStringArray()), tech_names)
	_append_relation_section(lines, "跨领域应用",
		node.get("application_target_ids", PackedStringArray()),
		node.get("application_target_rationales", PackedStringArray()), tech_names)
	_append_named_id_section(lines, "作为候选参与的里程碑",
		node.get("candidate_milestone_ids", PackedStringArray()),
		tech_names)


func _append_named_id_section(lines: PackedStringArray, title: String, ids,
		tech_names: Dictionary) -> void:
	lines.append("")
	lines.append("#### %s" % title)
	lines.append("")
	if ids.is_empty():
		lines.append("无")
		return
	_append_named_id_items(lines, ids, tech_names)


func _append_named_id_items(lines: PackedStringArray, ids, tech_names: Dictionary) -> void:
	for raw_id in ids:
		lines.append("- %s" % _named_technology(String(raw_id), tech_names))


func _append_relation_section(lines: PackedStringArray, title: String, ids,
		rationales, tech_names: Dictionary) -> void:
	lines.append("")
	lines.append("#### %s" % title)
	lines.append("")
	if ids.is_empty():
		lines.append("无")
		return
	for cursor in range(ids.size()):
		var reason := String(rationales[cursor]) if cursor < rationales.size() else ""
		lines.append("- %s%s" % [_named_technology(String(ids[cursor]), tech_names),
			("：%s" % _md_inline(reason)) if not reason.is_empty() else ""])


func _append_condition_section(lines: PackedStringArray, title: String, condition_lines) -> void:
	lines.append("")
	lines.append("#### %s" % title)
	lines.append("")
	if condition_lines.is_empty():
		lines.append("无")
		return
	for line in condition_lines:
		lines.append("%s- %s" % [
			"  ".repeat(int(line.get("depth", 0))),
			_md_inline(String(line.get("text", ""))),
		])


func _append_unlock_section(lines: PackedStringArray, unlocks: Dictionary) -> void:
	lines.append("")
	lines.append("#### 内容解锁")
	lines.append("")
	var groups := [
		["物资", unlocks.get("goods", [])],
		["建筑 / 生产方式", unlocks.get("buildings", [])],
		["自然资源", unlocks.get("resources", [])],
		["作为 ALL 支撑条件参与的建筑 / 生产方式", unlocks.get("support_buildings", [])],
	]
	for group in groups:
		lines.append("- **%s：** %s" % [group[0], _named_record_values(group[1])])


func _append_modifier_section(lines: PackedStringArray, terms) -> void:
	lines.append("")
	lines.append("#### 永久 Modifier 条款")
	lines.append("")
	if terms.is_empty():
		lines.append("无")
		return
	for term in terms:
		var subject_name := String(term.get("subject_display_name", ""))
		var subject_prefix := "%s：" % _md_inline(subject_name) \
			if not subject_name.is_empty() else ""
		lines.append("- %s`%s`：%s" % [subject_prefix,
			_md_code(String(term.get("stat", ""))),
			_modifier_value(int(term.get("operation", -1)), float(term.get("value", 0.0))),
		])

	for term in terms:
		lines.append("  - 效果机制：%s" % _md_inline(String(
			term.get("effect_rationale", ""))))
		lines.append("  - 运行时消费者：`%s`" % _md_code(String(
			term.get("runtime_consumer", ""))))


func _append_content_effect_section(lines: PackedStringArray, effects) -> void:
	lines.append("")
	lines.append("#### 结构化内容效果")
	lines.append("")
	if effects.is_empty():
		lines.append("无")
		return
	for effect in effects:
		var item: Dictionary = effect
		var display_name := String(item.get("display_name", item.get("id", "")))
		lines.append("- **%s**（`%s`）：`%s` → `%s` `%s` `%s`；`%s`" % [
			_md_inline(display_name),
			_md_code(String(item.get("kind", ""))),
			_md_code(String(item.get("subject", ""))),
			_md_code(String(item.get("attribute", ""))),
			_md_code(String(item.get("operation", ""))),
			_md_code(str(item.get("value", ""))),
			_md_code(String(item.get("status", ""))),
		])


func _route_value(route_tag: String, node: Dictionary) -> String:
	if route_tag.is_empty():
		return "无"
	var tags: PackedStringArray = node.get("route_tags", PackedStringArray())
	var names: PackedStringArray = node.get("route_display_names", PackedStringArray())
	var index := tags.find(route_tag)
	var display_name := String(names[index]) if index >= 0 and index < names.size() else route_tag
	return "%s (`%s`)" % [display_name, _md_code(route_tag)]


func _route_values(node: Dictionary) -> String:
	var tags: PackedStringArray = node.get("route_tags", PackedStringArray())
	var names: PackedStringArray = node.get("route_display_names", PackedStringArray())
	if tags.is_empty():
		return "无"
	var values := PackedStringArray()
	for i in range(tags.size()):
		var tag := String(tags[i])
		var display_name := String(names[i]) if i < names.size() else tag
		values.append("%s (`%s`)" % [display_name, _md_code(tag)])
	return "；".join(values)


func _id_values(values) -> String:
	if values.is_empty():
		return "无"
	var formatted := PackedStringArray()
	for value in values:
		formatted.append("`%s`" % _md_code(String(value)))
	return "；".join(formatted)


func _named_record_values(records) -> String:
	if records.is_empty():
		return "无"
	var values := PackedStringArray()
	for record in records:
		values.append("%s (`%s`)" % [
			_md_inline(String(record.get("name", record.get("id", "")))),
			_md_code(String(record.get("id", ""))),
		])
	return "；".join(values)


func _named_technology(id: String, tech_names: Dictionary) -> String:
	if id.is_empty():
		return "无"
	return "%s (`%s`)" % [_md_inline(String(tech_names.get(id, id))), _md_code(id)]


func _modifier_value(operation: int, value: float) -> String:
	match operation:
		0:
			return "+%s%%" % _decimal(absf(value * 100.0), 1)
		1:
			return "-%s%%" % _decimal(absf(value * 100.0), 1)
		2:
			return "×%s" % _decimal(value, 4)
		3:
			return "÷%s" % _decimal(value, 4)
	return "未知运算 %d（%s）" % [operation, _decimal(value, 4)]


func _decimal(value: float, precision: int) -> String:
	var formatted := ("%.1f" % value) if precision == 1 else ("%.4f" % value)
	formatted = formatted.rstrip("0").rstrip(".")
	return "0" if formatted in ["", "-0"] else formatted


func _value_or_none(value) -> String:
	var text := String(value).strip_edges()
	return text if not text.is_empty() else "无"


func _md_table(value: String) -> String:
	return _md_inline(value).replace("\r\n", "<br>").replace("\n", "<br>").replace("\r", "<br>")


func _md_inline(value: String) -> String:
	var out := value.replace("\\", "\\\\")
	for token in ["`", "*", "_", "[", "]", "<", ">", "|"]:
		out = out.replace(token, "\\" + token)
	return out


func _md_code(value: String) -> String:
	return value.replace("`", "\\`").replace("|", "\\|")
