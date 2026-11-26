extends RefCounted

## Builds the Markdown projection of the compiled technology report.

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")


static func _markdown_report(payload: Dictionary) -> String:
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
	lines.append("| 研究科技 (`tech.*`) | %d |" % int(payload.get("technology_count", 0)))
	lines.append("| 自动应用 (`app.*`) | %d |" % int(payload.get("application_count", 0)))
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
		lines.append("- [%s](#era-%d)（%d 项科技、%d 项自动应用，科技成本 %d-%d）" % [
			_md_inline(String(era.get("display_name", era.get("id", "")))),
			era_index + 1,
			int(era.get("technology_count", 0)),
			int(era.get("application_count", 0)),
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
		lines.append("共 %d 项研究科技、%d 项自动应用，科技研究成本范围 %d-%d；时代里程碑：%s。" % [
			int(era.get("technology_count", 0)),
			int(era.get("application_count", 0)),
			int(era.get("min_cost", 0)),
			int(era.get("max_cost", 0)),
			_named_technology(String(era.get("milestone_id", "")), tech_names),
		])
		for node in nodes:
			if String(node.get("era_id", "")) == era_id:
				_append_markdown_node(lines, node, era, domain_names, tech_names)
	return "\n".join(lines) + "\n"


static func _append_markdown_node(lines: PackedStringArray, node: Dictionary, era: Dictionary,
		domain_names: Dictionary, tech_names: Dictionary) -> void:
	var id := String(node.get("id", ""))
	var is_application := bool(node.get("is_automatic_application", false))
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
	if is_application:
		flags.append("零成本自动应用")

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
	if is_application:
		lines.append("| 生效方式 | 所需科技全部完成后立即自动应用；无研究成本、队列或进度 |")
	else:
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

	_append_relation_section(lines,
		"所需科技（ALL，决定自动应用）" if is_application else "硬前置（决定研发资格）",
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


static func _append_named_id_section(lines: PackedStringArray, title: String, ids,
		tech_names: Dictionary) -> void:
	lines.append("")
	lines.append("#### %s" % title)
	lines.append("")
	if ids.is_empty():
		lines.append("无")
		return
	_append_named_id_items(lines, ids, tech_names)


static func _append_named_id_items(lines: PackedStringArray, ids, tech_names: Dictionary) -> void:
	for raw_id in ids:
		lines.append("- %s" % _named_technology(String(raw_id), tech_names))


static func _append_relation_section(lines: PackedStringArray, title: String, ids,
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


static func _append_condition_section(lines: PackedStringArray, title: String, condition_lines) -> void:
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


static func _append_unlock_section(lines: PackedStringArray, unlocks: Dictionary) -> void:
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


static func _append_modifier_section(lines: PackedStringArray, terms) -> void:
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


static func _append_content_effect_section(lines: PackedStringArray, effects) -> void:
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


static func _route_value(route_tag: String, node: Dictionary) -> String:
	if route_tag.is_empty():
		return "无"
	var tags: PackedStringArray = node.get("route_tags", PackedStringArray())
	var names: PackedStringArray = node.get("route_display_names", PackedStringArray())
	var index := tags.find(route_tag)
	var display_name := String(names[index]) if index >= 0 and index < names.size() else route_tag
	return "%s (`%s`)" % [display_name, _md_code(route_tag)]


static func _route_values(node: Dictionary) -> String:
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


static func _id_values(values) -> String:
	if values.is_empty():
		return "无"
	var formatted := PackedStringArray()
	for value in values:
		formatted.append("`%s`" % _md_code(String(value)))
	return "；".join(formatted)


static func _named_record_values(records) -> String:
	if records.is_empty():
		return "无"
	var values := PackedStringArray()
	for record in records:
		values.append("%s (`%s`)" % [
			_md_inline(String(record.get("name", record.get("id", "")))),
			_md_code(String(record.get("id", ""))),
		])
	return "；".join(values)


static func _named_technology(id: String, tech_names: Dictionary) -> String:
	if id.is_empty():
		return "无"
	return "%s (`%s`)" % [_md_inline(String(tech_names.get(id, id))), _md_code(id)]


static func _modifier_value(operation: int, value: float) -> String:
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


static func _decimal(value: float, precision: int) -> String:
	var formatted := ("%.1f" % value) if precision == 1 else ("%.4f" % value)
	formatted = formatted.rstrip("0").rstrip(".")
	return "0" if formatted in ["", "-0"] else formatted


static func _value_or_none(value) -> String:
	var text := String(value).strip_edges()
	return text if not text.is_empty() else "无"


static func _md_table(value: String) -> String:
	return _md_inline(value).replace("\r\n", "<br>").replace("\n", "<br>").replace("\r", "<br>")


static func _md_inline(value: String) -> String:
	var out := value.replace("\\", "\\\\")
	for token in ["`", "*", "_", "[", "]", "<", ">", "|"]:
		out = out.replace(token, "\\" + token)
	return out


static func _md_code(value: String) -> String:
	return value.replace("`", "\\`").replace("|", "\\|")
