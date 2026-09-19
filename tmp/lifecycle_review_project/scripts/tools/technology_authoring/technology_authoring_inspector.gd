extends RefCounted

## Builds the full-field inspector for one technology.
##
## The field table below is the contract: every schema field the gate validates
## has exactly one editor here, so "edit the effects" no longer means hand-
## writing JSON into a text area. Enumerated fields become dropdowns, relation
## fields keep their rationale next to each entry, and Modifier terms expose the
## four semantic fields the gate requires.

const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")

const LABEL_WIDTH := 132
const OPERATION_NAMES := ["加 (+v)", "减 (-v)", "乘 (×v)", "除 (÷v)"]
const CONTENT_KINDS := ["building", "good", "resource"]

## section -> ordered field descriptors.
const SECTIONS := [
	{
		"title": "身份与分类",
		"fields": [
			{"key": "display_name", "label": "显示名称", "type": "line"},
			{"key": "era_id", "label": "时代", "type": "enum", "source": "eras"},
			{"key": "domain_id", "label": "领域", "type": "enum", "source": "domains"},
			{"key": "branch_family_id", "label": "分支族", "type": "enum", "source": "families"},
			{"key": "network_role", "label": "网络角色", "type": "suggest"},
			{"key": "anchor_kind", "label": "锚点类型", "type": "suggest"},
			{"key": "node_role", "label": "节点职能", "type": "suggest"},
			{"key": "effect_profile", "label": "效果画像", "type": "suggest"},
		],
	},
	{
		"title": "数值与标志",
		"fields": [
			{"key": "cost_points", "label": "研究成本", "type": "number",
				"min": 0.0, "max": 1000000000.0, "step": 100.0},
			{"key": "layout_order", "label": "布局序位", "type": "number",
				"min": 0.0, "max": 100000.0, "step": 1.0},
			{"key": "is_milestone", "label": "时代里程碑", "type": "bool"},
			{"key": "is_era_key", "label": "时代关键", "type": "bool"},
			{"key": "is_starting", "label": "开局已完成", "type": "bool"},
			{"key": "is_starter_eligible", "label": "可作开局科技", "type": "bool"},
			{"key": "era_entry_milestone_id", "label": "时代入口里程碑",
				"type": "enum", "source": "technologies_optional"},
		],
	},
	{
		"title": "玩家文本",
		"fields": [
			{"key": "effect_summary", "label": "效果摘要（保存时自动生成）",
				"type": "multiline", "editable": false},
			{"key": "reveal_category", "label": "揭示类别", "type": "enum",
				"source": "reveal_categories"},
			{"key": "reveal_summary", "label": "揭示摘要", "type": "multiline"},
			{"key": "reveal_template_reason", "label": "揭示模板理由", "type": "multiline"},
			{"key": "opportunity_cost", "label": "机会成本", "type": "multiline"},
			{"key": "terminal_reason", "label": "终点理由", "type": "multiline"},
			{"key": "route_exemption_reason", "label": "路线豁免理由", "type": "multiline"},
		],
	},
	{
		"title": "拓扑关系",
		"fields": [
			{"key": "hard_prerequisite_ids", "label": "硬前置", "type": "relation"},
			{"key": "branch_successor_ids", "label": "分支后继", "type": "relation"},
			{"key": "application_target_ids", "label": "应用交汇目标", "type": "relation"},
			{"key": "application_foundation_ids", "label": "应用基础科技",
				"type": "string_list"},
			{"key": "secondary_route_tags", "label": "次要路线标签", "type": "string_list"},
			{"key": "starter_capability_tags", "label": "开局能力标签", "type": "string_list"},
			{"key": "runtime_capability_tags", "label": "运行时能力标签",
				"type": "string_list"},
		],
	},
	{
		"title": "效果",
		"fields": [
			{"key": "modifier_terms", "label": "永久 Modifier", "type": "modifier_terms"},
		],
	},
	{
		"title": "内容解锁",
		"fields": [
			{"key": "content_effects", "label": "解锁效果", "type": "content_effects"},
			{"key": "expected_bindings", "label": "预期绑定", "type": "expected_bindings"},
			{"key": "support_buildings", "label": "支撑建筑", "type": "support_buildings"},
		],
	},
	{
		"title": "研究路线与知识基础",
		"fields": [
			{"key": "research_routes", "label": "研究路线", "type": "research_routes"},
			{"key": "knowledge_basis", "label": "知识基础", "type": "knowledge_basis"},
			{"key": "reveal_condition", "label": "揭示条件", "type": "json"},
		],
	},
	{
		"title": "审核元数据",
		"fields": [
			{"key": "topology_review", "label": "拓扑审核", "type": "review_topology"},
			{"key": "building_unlock_review", "label": "建筑解锁审核",
				"type": "review_building"},
			{"key": "effect_design_review", "label": "效果设计审核", "type": "json"},
		],
	},
]

var _host: VBoxContainer
var _editor: Node
var _technology_id := ""
var _problem_fields: Dictionary = {}
## schema key -> the container holding its editor, for Problems-dock jumps.
var _field_hosts: Dictionary = {}


func _init(host: VBoxContainer, editor: Node) -> void:
	_host = host
	_editor = editor


## Every schema key the inspector claims to cover, for contract tests.
static func covered_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for section_value in SECTIONS:
		for field_value in (section_value as Dictionary).fields:
			out.append(String((field_value as Dictionary).key))
	return out


func technology_id() -> String:
	return _technology_id


func clear() -> void:
	_technology_id = ""
	_field_hosts.clear()
	for child in _host.get_children():
		child.queue_free()


## Scrolls the editor for `key` into view and takes keyboard focus, so a click
## in the Problems dock lands on the offending field instead of the node's top.
func focus_field(key: String) -> bool:
	var host: Control = _field_hosts.get(key, null)
	if host == null or not host.is_inside_tree():
		return false
	var scroll := _host.get_parent() as ScrollContainer
	if scroll != null:
		scroll.set_deferred("scroll_vertical", int(host.position.y))
	var focusable := _first_focusable(host)
	if focusable != null:
		focusable.call_deferred("grab_focus")
	return true


func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		var control := child as Control
		if control != null and control.focus_mode != Control.FOCUS_NONE:
			return control
		var nested := _first_focusable(child)
		if nested != null:
			return nested
	return null


func show_technology(id: String, findings: Array) -> void:
	_technology_id = id
	_field_hosts.clear()
	_problem_fields.clear()
	for value in findings:
		var row: Dictionary = value
		var field := String(row.get("field", ""))
		if field.is_empty():
			continue
		var bucket: Array = _problem_fields.get(field, [])
		bucket.append(row)
		_problem_fields[field] = bucket
	for child in _host.get_children():
		child.queue_free()
	var row_data: Dictionary = _editor.call("technology_row", id)
	if row_data.is_empty():
		var empty := Label.new()
		empty.text = "未选中科技"
		_host.add_child(empty)
		return
	_add_heading("%s\n%s" % [String(row_data.get("display_name", id)), id])
	_add_unlock_summary(id)
	for section_value in SECTIONS:
		var section: Dictionary = section_value
		_add_section(String(section.title))
		for field_value in section.fields:
			_add_field(row_data, field_value as Dictionary)


# --------------------------------------------------------------------------
# Chrome
# --------------------------------------------------------------------------

func _add_heading(text: String) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_override("font", UITokens.font_with_weight(680))
	label.add_theme_font_size_override("font_size", 16)
	_host.add_child(label)


func _add_section(title: String) -> void:
	var separator := HSeparator.new()
	_host.add_child(separator)
	var label := Label.new()
	label.text = title
	label.add_theme_font_override("font", UITokens.font_with_weight(620))
	label.add_theme_color_override("font_color", UITokens.ACCENT)
	_host.add_child(label)


func _add_unlock_summary(id: String) -> void:
	var report: Dictionary = _editor.call("unlock_reconciliation", id)
	if report.is_empty():
		return
	var matched: Array = report.get("matched", [])
	var missing_tres: Array = report.get("missing_in_tres", [])
	var missing_node: Array = report.get("missing_in_node", [])
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.text = ".tres 对账：%d 一致 / %d 仅在节点 / %d 仅在 .tres" % [
		matched.size(), missing_tres.size(), missing_node.size()]
	if not missing_tres.is_empty() or not missing_node.is_empty():
		label.add_theme_color_override("font_color", UITokens.WARN)
	_host.add_child(label)
	if missing_tres.is_empty() and missing_node.is_empty():
		return
	var actions := HBoxContainer.new()
	_host.add_child(actions)
	for entry_value in missing_tres:
		var entry: Dictionary = entry_value
		var button := Button.new()
		button.text = "写入 .tres：%s %s" % [String(entry.kind), String(entry.id)]
		button.pressed.connect(func() -> void:
			_editor.call("sync_unlock_to_tres", id, String(entry.kind), String(entry.id)))
		actions.add_child(button)
	for entry_value in missing_node:
		var entry: Dictionary = entry_value
		var button := Button.new()
		button.text = "补入节点：%s %s" % [String(entry.kind), String(entry.id)]
		button.pressed.connect(func() -> void:
			_editor.call("adopt_unlock_from_tres", id, String(entry.kind), String(entry.id),
				String(entry.display_name)))
		actions.add_child(button)


func _field_row(label_text: String, key: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size.x = LABEL_WIDTH
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _problem_fields.has(key):
		label.add_theme_color_override("font_color", UITokens.RISK)
		label.tooltip_text = _problem_tooltip(key)
	row.add_child(label)
	_host.add_child(row)
	_field_hosts[key] = row
	return row


func _problem_tooltip(key: String) -> String:
	var lines := PackedStringArray()
	for value in _problem_fields.get(key, []):
		lines.append(String((value as Dictionary).get("message", "")))
	return "\n".join(lines)


func _add_block(label_text: String, key: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	if _problem_fields.has(key):
		label.add_theme_color_override("font_color", UITokens.RISK)
		label.tooltip_text = _problem_tooltip(key)
	box.add_child(label)
	_host.add_child(box)
	_field_hosts[key] = box
	return box


# --------------------------------------------------------------------------
# Field dispatch
# --------------------------------------------------------------------------

func _add_field(row_data: Dictionary, field: Dictionary) -> void:
	var key := String(field.key)
	var label := String(field.label)
	match String(field.type):
		"line": _build_line(row_data, key, label, bool(field.get("editable", true)))
		"suggest": _build_suggest(row_data, key, label)
		"multiline": _build_multiline(row_data, key, label,
			bool(field.get("editable", true)))
		"number": _build_number(row_data, key, label, field)
		"bool": _build_bool(row_data, key, label)
		"enum": _build_enum(row_data, key, label, String(field.source))
		"string_list": _build_string_list(row_data, key, label)
		"relation": _build_relation(key, label)
		"modifier_terms": _build_modifier_terms(row_data, key, label)
		"content_effects": _build_content_effects(row_data, key, label)
		"expected_bindings": _build_expected_bindings(row_data, key, label)
		"support_buildings": _build_support_buildings(row_data, key, label)
		"research_routes": _build_research_routes(row_data, key, label)
		"knowledge_basis": _build_knowledge_basis(row_data, key, label)
		"review_topology": _build_topology_review(row_data, key, label)
		"review_building": _build_building_review(row_data, key, label)
		"json": _build_json(row_data, key, label)


func _commit(key: String, value: Variant) -> void:
	_editor.call("commit_field", _technology_id, key, value)


# --------------------------------------------------------------------------
# Scalar editors
# --------------------------------------------------------------------------

func _build_line(row_data: Dictionary, key: String, label: String,
		editable: bool) -> void:
	var row := _field_row(label, key)
	var field := LineEdit.new()
	field.text = String(row_data.get(key, ""))
	field.editable = editable
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	if not editable:
		return
	field.text_submitted.connect(func(text: String) -> void: _commit(key, text))
	field.focus_exited.connect(func() -> void: _commit(key, field.text))


## A free-text field whose existing values across the network are offered as a
## picker, so authors stay consistent without a closed schema enum.
func _build_suggest(row_data: Dictionary, key: String, label: String) -> void:
	var row := _field_row(label, key)
	var field := LineEdit.new()
	field.text = String(row_data.get(key, ""))
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	field.text_submitted.connect(func(text: String) -> void: _commit(key, text))
	field.focus_exited.connect(func() -> void: _commit(key, field.text))
	var pick := Button.new()
	pick.text = "…"
	pick.tooltip_text = "从网络中已有取值里选择"
	row.add_child(pick)
	pick.pressed.connect(func() -> void:
		_editor.call("open_value_picker", "已有取值：%s" % key, key,
			func(picked: String) -> void:
				field.text = picked
				_commit(key, picked)))


func _build_multiline(row_data: Dictionary, key: String, label: String,
		editable: bool) -> void:
	var box := _add_block(label, key)
	var field := TextEdit.new()
	field.text = String(row_data.get(key, ""))
	field.editable = editable
	field.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	field.custom_minimum_size.y = 62
	box.add_child(field)
	if editable:
		field.focus_exited.connect(func() -> void: _commit(key, field.text))


func _build_number(row_data: Dictionary, key: String, label: String,
		field_spec: Dictionary) -> void:
	var row := _field_row(label, key)
	var field := SpinBox.new()
	field.min_value = float(field_spec.get("min", 0.0))
	field.max_value = float(field_spec.get("max", 1000000.0))
	field.step = float(field_spec.get("step", 1.0))
	field.allow_greater = true
	field.value = float(row_data.get(key, 0.0))
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	field.value_changed.connect(func(next: float) -> void: _commit(key, next))


func _build_bool(row_data: Dictionary, key: String, label: String) -> void:
	var row := _field_row(label, key)
	var field := CheckBox.new()
	field.button_pressed = bool(row_data.get(key, false))
	row.add_child(field)
	field.toggled.connect(func(pressed: bool) -> void: _commit(key, pressed))


func _build_enum(row_data: Dictionary, key: String, label: String,
		source: String) -> void:
	var row := _field_row(label, key)
	var field := OptionButton.new()
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var options: PackedStringArray = _editor.call("enum_source", source)
	var current := String(row_data.get(key, ""))
	var selected := -1
	for index in range(options.size()):
		field.add_item(String(options[index]), index)
		if String(options[index]) == current:
			selected = index
	if selected < 0:
		field.add_item("（未知）%s" % current, options.size())
		selected = options.size()
		options.append(current)
	field.select(selected)
	row.add_child(field)
	field.item_selected.connect(func(index: int) -> void:
		_commit(key, String(options[index])))


func _build_string_list(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block("%s（每行一个）" % label, key)
	var field := TextEdit.new()
	var values: Array = row_data.get(key, [])
	var lines := PackedStringArray()
	for value in values:
		lines.append(String(value))
	field.text = "\n".join(lines)
	field.custom_minimum_size.y = 54
	box.add_child(field)
	field.focus_exited.connect(func() -> void:
		var out: Array = []
		for line in field.text.split("\n"):
			var trimmed := String(line).strip_edges()
			if not trimmed.is_empty():
				out.append(trimmed)
		_commit(key, out))


func _build_json(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block("%s（JSON）" % label, key)
	var field := TextEdit.new()
	field.text = JSON.stringify(row_data.get(key, {}), "  ")
	field.custom_minimum_size.y = 90
	box.add_child(field)
	var status := Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(status)
	field.focus_exited.connect(func() -> void:
		var parsed: Variant = JSON.parse_string(field.text)
		if parsed == null:
			status.text = "JSON 无法解析，未提交。"
			status.add_theme_color_override("font_color", UITokens.RISK)
			return
		status.text = ""
		_commit(key, parsed))


# --------------------------------------------------------------------------
# Relations
# --------------------------------------------------------------------------

func _build_relation(key: String, label: String) -> void:
	var box := _add_block(label, key)
	var entries: Array = _editor.call("relation_entries", _technology_id, key)
	for slot in range(entries.size()):
		var entry: Dictionary = entries[slot]
		var row := HBoxContainer.new()
		box.add_child(row)
		var id_label := Label.new()
		id_label.text = String(entry.id)
		id_label.custom_minimum_size.x = 190
		id_label.tooltip_text = _editor.call("technology_display_name", String(entry.id))
		row.add_child(id_label)
		var rationale := LineEdit.new()
		rationale.text = String(entry.rationale)
		rationale.placeholder_text = "必填：为什么需要它"
		rationale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(rationale)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		var captured_slot := slot
		rationale.text_submitted.connect(func(text: String) -> void:
			_editor.call("commit_relation_rationale", _technology_id, key,
				captured_slot, text))
		rationale.focus_exited.connect(func() -> void:
			_editor.call("commit_relation_rationale", _technology_id, key,
				captured_slot, rationale.text))
		remove.pressed.connect(func() -> void:
			_editor.call("remove_relation_entry", _technology_id, key, String(entry.id)))
	var add := Button.new()
	add.text = "添加%s" % label
	box.add_child(add)
	add.pressed.connect(func() -> void:
		_editor.call("prompt_relation_entry", _technology_id, key, label))


# --------------------------------------------------------------------------
# Modifier terms
# --------------------------------------------------------------------------

func _build_modifier_terms(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block("%s（上限 6 条）" % label, key)
	var terms: Array = row_data.get(key, [])
	for slot in range(terms.size()):
		var term: Dictionary = terms[slot]
		var captured := slot
		var frame := VBoxContainer.new()
		frame.add_theme_constant_override("separation", 2)
		box.add_child(frame)
		var head := HBoxContainer.new()
		frame.add_child(head)
		var stat_button := Button.new()
		stat_button.text = String(term.get("stat", "（选择 stat）"))
		stat_button.clip_text = true
		stat_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stat_button.tooltip_text = _editor.call("stat_hint", String(term.get("stat", "")))
		head.add_child(stat_button)
		stat_button.pressed.connect(func() -> void:
			_editor.call("open_stat_picker", func(picked: String) -> void:
				_editor.call("commit_term_field", _technology_id, captured, "stat", picked)))
		var operation := OptionButton.new()
		for index in range(OPERATION_NAMES.size()):
			operation.add_item(String(OPERATION_NAMES[index]), index)
		operation.select(clampi(int(term.get("operation", 0)), 0, 3))
		head.add_child(operation)
		operation.item_selected.connect(func(index: int) -> void:
			_editor.call("commit_term_field", _technology_id, captured, "operation",
				float(index)))
		var value := SpinBox.new()
		value.min_value = -1000.0
		value.max_value = 1000.0
		value.step = 0.01
		value.value = float(term.get("value", 0.0))
		head.add_child(value)
		value.value_changed.connect(func(next: float) -> void:
			_editor.call("commit_term_field", _technology_id, captured, "value", next))
		var remove := Button.new()
		remove.text = "移除"
		head.add_child(remove)
		remove.pressed.connect(func() -> void:
			_editor.call("remove_term", _technology_id, captured))
		var subject := HBoxContainer.new()
		frame.add_child(subject)
		_term_line(subject, "对象类型", String(term.get("subject_kind", "")), captured,
			"subject_kind", 96, true)
		_term_line(subject, "对象 ID", String(term.get("subject_id", "")), captured,
			"subject_id", 120, false)
		_term_line(subject, "对象名称", String(term.get("subject_display_name", "")),
			captured, "subject_display_name", 120, false)
		var semantics := HBoxContainer.new()
		frame.add_child(semantics)
		_term_line(semantics, "效果类别", String(term.get("effect_class", "")), captured,
			"effect_class", 120, true)
		_term_line(semantics, "运行时消费者", String(term.get("runtime_consumer", "")),
			captured, "runtime_consumer", 200, true)
		var rationale := HBoxContainer.new()
		frame.add_child(rationale)
		_term_line(rationale, "效果理由", String(term.get("effect_rationale", "")),
			captured, "effect_rationale", 320, false)
		var preview := Label.new()
		preview.text = "玩家文案预览：%s %s" % [
			_editor.call("term_subject_label", term),
			ValidatorScript.modifier_delta(term)]
		preview.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		frame.add_child(preview)
		if ValidatorScript.same_target_conflict(row_data, term):
			var conflict := Label.new()
			conflict.text = "冲突：本科技同时解锁并加成 %s（technology_unlock_same_target_modifier）" % String(
				term.get("subject_id", ""))
			conflict.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			conflict.add_theme_color_override("font_color", UITokens.RISK)
			frame.add_child(conflict)
		var status := String(term.get("implementation_status", ""))
		if status != "runtime_consumed":
			var warning := Label.new()
			warning.text = "implementation_status 必须为 runtime_consumed，当前为「%s」" % status
			warning.add_theme_color_override("font_color", UITokens.RISK)
			frame.add_child(warning)
			var fix := Button.new()
			fix.text = "修正为 runtime_consumed"
			frame.add_child(fix)
			fix.pressed.connect(func() -> void:
				_editor.call("commit_term_field", _technology_id, captured,
					"implementation_status", "runtime_consumed"))
		box.add_child(HSeparator.new())
	if terms.size() < 6:
		var add := Button.new()
		add.text = "添加 Modifier 项"
		box.add_child(add)
		add.pressed.connect(func() -> void: _editor.call("add_term", _technology_id))


func _term_line(row: HBoxContainer, label: String, value: String, slot: int,
		key: String, width: int, suggest: bool) -> void:
	var caption := Label.new()
	caption.text = label
	row.add_child(caption)
	var field := LineEdit.new()
	field.text = value
	field.custom_minimum_size.x = width
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	field.text_submitted.connect(func(text: String) -> void:
		_editor.call("commit_term_field", _technology_id, slot, key, text))
	field.focus_exited.connect(func() -> void:
		_editor.call("commit_term_field", _technology_id, slot, key, field.text))
	if not suggest:
		return
	var pick := Button.new()
	pick.text = "…"
	row.add_child(pick)
	pick.pressed.connect(func() -> void:
		_editor.call("open_term_value_picker", key,
			func(picked: String) -> void:
				field.text = picked
				_editor.call("commit_term_field", _technology_id, slot, key, picked)))


# --------------------------------------------------------------------------
# Content unlocks
# --------------------------------------------------------------------------

func _build_content_effects(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block(label, key)
	var effects: Array = row_data.get(key, [])
	for slot in range(effects.size()):
		var effect: Dictionary = effects[slot]
		var captured := slot
		var row := HBoxContainer.new()
		box.add_child(row)
		var caption := Label.new()
		caption.text = "%s · %s" % [String(effect.get("kind", "")), String(effect.get("id", ""))]
		caption.custom_minimum_size.x = 200
		caption.tooltip_text = JSON.stringify(effect, "  ")
		row.add_child(caption)
		var operation := Label.new()
		operation.text = String(effect.get("operation", ""))
		row.add_child(operation)
		var exists := bool(_editor.call("content_exists", String(effect.get("kind", "")),
			String(effect.get("id", ""))))
		var state := Label.new()
		state.text = "已存在" if exists else "内容不存在"
		state.add_theme_color_override("font_color",
			UITokens.GOOD if exists else UITokens.RISK)
		row.add_child(state)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			_editor.call("remove_array_entry", _technology_id, key, captured))
	var add := Button.new()
	add.text = "添加解锁效果"
	box.add_child(add)
	add.pressed.connect(func() -> void:
		_editor.call("prompt_content_effect", _technology_id))


func _build_expected_bindings(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block("%s（kind 1=物资 2=建筑 3=资源）" % label, key)
	var bindings: Array = row_data.get(key, [])
	for slot in range(bindings.size()):
		var binding: Dictionary = bindings[slot]
		var captured := slot
		var row := HBoxContainer.new()
		box.add_child(row)
		var caption := Label.new()
		caption.text = "kind %d · %s" % [int(binding.get("kind", 0)),
			String(binding.get("id", ""))]
		caption.custom_minimum_size.x = 240
		row.add_child(caption)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			_editor.call("remove_array_entry", _technology_id, key, captured))
	var add := Button.new()
	add.text = "从解锁效果同步预期绑定"
	box.add_child(add)
	add.pressed.connect(func() -> void:
		_editor.call("sync_expected_bindings", _technology_id))


func _build_support_buildings(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block(label, key)
	var rows: Array = row_data.get(key, [])
	for slot in range(rows.size()):
		var entry: Dictionary = rows[slot]
		var captured := slot
		var row := HBoxContainer.new()
		box.add_child(row)
		var caption := Label.new()
		caption.text = "%s（%s）" % [String(entry.get("name", "")), String(entry.get("id", ""))]
		caption.custom_minimum_size.x = 240
		row.add_child(caption)
		var remove := Button.new()
		remove.text = "移除"
		row.add_child(remove)
		remove.pressed.connect(func() -> void:
			_editor.call("remove_array_entry", _technology_id, key, captured))
	var add := Button.new()
	add.text = "添加支撑建筑"
	box.add_child(add)
	add.pressed.connect(func() -> void:
		_editor.call("prompt_support_building", _technology_id))


# --------------------------------------------------------------------------
# Research routes and knowledge basis
# --------------------------------------------------------------------------

func _build_research_routes(row_data: Dictionary, key: String, label: String) -> void:
	var box := _add_block(label, key)
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
			_editor.call("commit_route_field", _technology_id, captured, "id",
				id_field.text))
		var remove := Button.new()
		remove.text = "移除"
		head.add_child(remove)
		remove.pressed.connect(func() -> void:
			_editor.call("remove_array_entry", _technology_id, key, captured))
		var meta := HBoxContainer.new()
		frame.add_child(meta)
		_route_line(meta, "名称", String(route.get("display_name", "")), captured,
			"display_name")
		_route_line(meta, "类型", String(route.get("route_type", "")), captured,
			"route_type")
		var description := LineEdit.new()
		description.text = String(route.get("description", ""))
		description.placeholder_text = "描述（必填）"
		frame.add_child(description)
		description.focus_exited.connect(func() -> void:
			_editor.call("commit_route_field", _technology_id, captured, "description",
				description.text))
		var atoms: PackedStringArray = PackedStringArray()
		ValidatorScript.collect_technology_atoms(route.get("condition", {}), atoms)
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
			_editor.call("commit_route_field", _technology_id, captured, "condition",
				parsed))
		var helper := Button.new()
		helper.text = "以某科技为条件"
		frame.add_child(helper)
		helper.pressed.connect(func() -> void:
			_editor.call("prompt_route_condition", _technology_id, captured))
		box.add_child(HSeparator.new())
	var add := Button.new()
	add.text = "添加研究路线"
	box.add_child(add)
	add.pressed.connect(func() -> void: _editor.call("add_route", _technology_id))


func _route_line(row: HBoxContainer, label: String, value: String, slot: int,
		key: String) -> void:
	var caption := Label.new()
	caption.text = label
	row.add_child(caption)
	var field := LineEdit.new()
	field.text = value
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	field.focus_exited.connect(func() -> void:
		_editor.call("commit_route_field", _technology_id, slot, key, field.text))


func _build_knowledge_basis(row_data: Dictionary, key: String, label: String) -> void:
	var basis: Dictionary = row_data.get(key, {})
	var box := _add_block(label, key)
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
		_editor.call("rebuild_knowledge_basis", _technology_id))
	var exemption := LineEdit.new()
	exemption.text = String(basis.get("exemption_reason", ""))
	exemption.placeholder_text = "豁免理由"
	exemption.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(exemption)
	exemption.focus_exited.connect(func() -> void:
		_editor.call("commit_basis_exemption", _technology_id, exemption.text))


# --------------------------------------------------------------------------
# Review metadata
# --------------------------------------------------------------------------

func _build_topology_review(row_data: Dictionary, key: String, label: String) -> void:
	var review: Dictionary = row_data.get(key, {})
	var box := _add_block(label, key)
	var head := HBoxContainer.new()
	box.add_child(head)
	var role := OptionButton.new()
	var roles := ValidatorScript.TOPOLOGY_REVIEW_ROLES
	var current := String(review.get("role", ""))
	var selected := roles.find(current)
	for index in range(roles.size()):
		role.add_item(String(roles[index]), index)
	role.select(maxi(0, selected))
	head.add_child(role)
	role.item_selected.connect(func(index: int) -> void:
		_editor.call("commit_review_field", _technology_id, key, "role",
			String(roles[index])))
	var rationale := LineEdit.new()
	rationale.text = String(review.get("rationale", ""))
	rationale.placeholder_text = "理由（必填）"
	rationale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(rationale)
	rationale.focus_exited.connect(func() -> void:
		_editor.call("commit_review_field", _technology_id, key, "rationale",
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
		_editor.call("commit_review_field", _technology_id, key,
			"expected_hard_family_ids", out))


func _build_building_review(row_data: Dictionary, key: String, label: String) -> void:
	var review: Dictionary = row_data.get(key, {})
	var row := _field_row(label, key)
	var policy := OptionButton.new()
	var policies := ValidatorScript.BUILDING_UNLOCK_POLICIES
	var current := String(review.get("policy", ""))
	for index in range(policies.size()):
		policy.add_item(String(policies[index]), index)
	policy.select(maxi(0, policies.find(current)))
	row.add_child(policy)
	policy.item_selected.connect(func(index: int) -> void:
		_editor.call("commit_review_field", _technology_id, key, "policy",
			String(policies[index])))
	var rationale := LineEdit.new()
	rationale.text = String(review.get("rationale", ""))
	rationale.placeholder_text = "理由（必填）"
	rationale.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(rationale)
	rationale.focus_exited.connect(func() -> void:
		_editor.call("commit_review_field", _technology_id, key, "rationale",
			rationale.text))
