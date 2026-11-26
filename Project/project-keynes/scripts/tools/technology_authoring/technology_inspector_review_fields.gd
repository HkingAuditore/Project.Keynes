extends RefCounted

## Builds the research route, knowledge basis and review editors.

static func _build_research_routes(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var box := inspector._add_block(label, key)
	var routes: Array = row_data.get(key, [])
	for slot in range(routes.size()):
		var route: Dictionary = routes[slot]
		var captured := slot
		var frame := VBoxContainer.new()
		box.add_child(frame)
		var head := HBoxContainer.new()
		frame.add_child(head)
		var id_field := LineEdit.new()
		id_field.text = String(route.get("id", ""))
		id_field.placeholder_text = "research_route.<名称>"
		id_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(id_field)
		id_field.focus_exited.connect(func() -> void:
			inspector._editor.call("commit_route_field", inspector._technology_id, captured, "id",
				id_field.text))
		var remove := Button.new()
		remove.text = "移除"
		head.add_child(remove)
		remove.pressed.connect(func() -> void:
			inspector._editor.call("remove_array_entry", inspector._technology_id, key, captured))
		var meta := HBoxContainer.new()
		frame.add_child(meta)
		inspector._route_line(meta, "名称", String(route.get("display_name", "")), captured,
			"display_name")
		inspector._route_line(meta, "类型", String(route.get("route_type", "")), captured,
			"route_type")
		var description := LineEdit.new()
		description.text = String(route.get("description", ""))
		description.placeholder_text = "描述（必填）"
		frame.add_child(description)
		description.focus_exited.connect(func() -> void:
			inspector._editor.call("commit_route_field", inspector._technology_id, captured, "description",
				description.text))
		var atoms: PackedStringArray = PackedStringArray()
		TechnologyAuthoringInspector.ValidatorScript.collect_technology_atoms(route.get("condition", {}), atoms)
		var atom_label := Label.new()
		atom_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		atom_label.text = "条件引用：%s" % ("、".join(atoms) if not atoms.is_empty() else "（无）")
		frame.add_child(atom_label)
		var condition := TextEdit.new()
		condition.text = JSON.stringify(route.get("condition", {}), "  ")
		condition.custom_minimum_size.y = 74
		frame.add_child(condition)
		var status := Label.new()
		frame.add_child(status)
		condition.focus_exited.connect(func() -> void:
			var parsed: Variant = JSON.parse_string(condition.text)
			if not parsed is Dictionary:
				status.text = "条件必须是 JSON 对象，未提交。"
				status.add_theme_color_override("font_color", UITokens.RISK)
				return
			status.text = ""
			inspector._editor.call("commit_route_field", inspector._technology_id, captured, "condition",
				parsed))
		var helper := Button.new()
		helper.text = "以某科技为条件"
		frame.add_child(helper)
		helper.pressed.connect(func() -> void:
			inspector._editor.call("prompt_route_condition", inspector._technology_id, captured))
		box.add_child(HSeparator.new())
	var add := Button.new()
	add.text = "添加研究路线"
	box.add_child(add)
	add.pressed.connect(func() -> void: inspector._editor.call("add_route", inspector._technology_id))


static func _route_line(inspector: TechnologyAuthoringInspector, row: HBoxContainer, label: String, value: String, slot: int,
		key: String) -> void:
	var caption := Label.new()
	caption.text = label
	row.add_child(caption)
	var field := LineEdit.new()
	field.text = value
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	field.focus_exited.connect(func() -> void:
		inspector._editor.call("commit_route_field", inspector._technology_id, slot, key, field.text))


static func _build_knowledge_basis(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var basis: Dictionary = row_data.get(key, {})
	var box := inspector._add_block(label, key)
	var required := Label.new()
	required.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var required_ids: Array = basis.get("required_ids", [])
	required.text = "必需：%s" % ("、".join(PackedStringArray(
		required_ids.map(func(v): return String(v)))) if not required_ids.is_empty() else "（无）")
	box.add_child(required)
	var groups: Array = basis.get("alternative_groups", [])
	for group_value in groups:
		var group_label := Label.new()
		group_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		group_label.text = "任一：%s" % "、".join(PackedStringArray(
			(group_value as Array).map(func(v): return String(v))))
		box.add_child(group_label)
	var actions := HBoxContainer.new()
	box.add_child(actions)
	var sync := Button.new()
	sync.text = "按硬前置与路线重建"
	actions.add_child(sync)
	sync.pressed.connect(func() -> void:
		inspector._editor.call("rebuild_knowledge_basis", inspector._technology_id))
	var exemption := LineEdit.new()
	exemption.text = String(basis.get("exemption_reason", ""))
	exemption.placeholder_text = "豁免理由"
	exemption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(exemption)
	exemption.focus_exited.connect(func() -> void:
		inspector._editor.call("commit_basis_exemption", inspector._technology_id, exemption.text))


# --------------------------------------------------------------------------
# Review metadata
# --------------------------------------------------------------------------


static func _build_topology_review(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var review: Dictionary = row_data.get(key, {})
	var box := inspector._add_block(label, key)
	var head := HBoxContainer.new()
	box.add_child(head)
	var role := OptionButton.new()
	var roles := TechnologyAuthoringInspector.ValidatorScript.TOPOLOGY_REVIEW_ROLES
	var current := String(review.get("role", ""))
	var selected := roles.find(current)
	for index in range(roles.size()):
		role.add_item(String(roles[index]), index)
	role.select(maxi(0, selected))
	head.add_child(role)
	role.item_selected.connect(func(index: int) -> void:
		inspector._editor.call("commit_review_field", inspector._technology_id, key, "role",
			String(roles[index])))
	var rationale := LineEdit.new()
	rationale.text = String(review.get("rationale", ""))
	rationale.placeholder_text = "理由（必填）"
	rationale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(rationale)
	rationale.focus_exited.connect(func() -> void:
		inspector._editor.call("commit_review_field", inspector._technology_id, key, "rationale",
			rationale.text))
	var families := TextEdit.new()
	var family_ids: Array = review.get("expected_hard_family_ids", [])
	families.text = "\n".join(PackedStringArray(
		family_ids.map(func(v): return String(v))))
	families.custom_minimum_size.y = 44
	box.add_child(families)
	var hint := Label.new()
	hint.text = "预期硬前置分支族（每行一个；汇聚角色不可为空）"
	box.add_child(hint)
	families.focus_exited.connect(func() -> void:
		var out: Array = []
		for line in families.text.split("\n"):
			var trimmed := String(line).strip_edges()
			if not trimmed.is_empty():
				out.append(trimmed)
		inspector._editor.call("commit_review_field", inspector._technology_id, key,
			"expected_hard_family_ids", out))


static func _build_building_review(inspector: TechnologyAuthoringInspector, row_data: Dictionary, key: String, label: String) -> void:
	var review: Dictionary = row_data.get(key, {})
	var row := inspector._field_row(label, key)
	var policy := OptionButton.new()
	var policies := TechnologyAuthoringInspector.ValidatorScript.BUILDING_UNLOCK_POLICIES
	var current := String(review.get("policy", ""))
	for index in range(policies.size()):
		policy.add_item(String(policies[index]), index)
	policy.select(maxi(0, policies.find(current)))
	row.add_child(policy)
	policy.item_selected.connect(func(index: int) -> void:
		inspector._editor.call("commit_review_field", inspector._technology_id, key, "policy",
			String(policies[index])))
	var rationale := LineEdit.new()
	rationale.text = String(review.get("rationale", ""))
	rationale.placeholder_text = "理由（必填）"
	rationale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(rationale)
	rationale.focus_exited.connect(func() -> void:
		inspector._editor.call("commit_review_field", inspector._technology_id, key, "rationale",
			rationale.text))
