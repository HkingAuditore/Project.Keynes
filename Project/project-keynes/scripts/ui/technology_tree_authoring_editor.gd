extends Control

const ServiceScript := preload("res://scripts/technology/technology_authoring_service.gd")
const NODE_SIZE := Vector2(190, 78)

var service: TechnologyAuthoringService
var graph: GraphEdit
var details: VBoxContainer
var search: LineEdit
var status: Label
var selected_id := ""
var undo_stack: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var node_controls := {}
var node_name_to_id := {}

func _ready() -> void:
	service = ServiceScript.new()
	var result := service.load_network()
	if not result.ok:
		_show_status(String(result.reason), true)
	_build_ui()
	_rebuild_graph()

func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)
	var toolbar := HBoxContainer.new()
	root.add_child(toolbar)
	for spec in [["保存", "_save"], ["校验", "_validate"], ["重新载入", "_reload"], ["导出报告", "_export_report"], ["撤销", "_undo"], ["重做", "_redo"]]:
		var button := Button.new()
		button.text = spec[0]
		button.pressed.connect(Callable(self, spec[1]))
		toolbar.add_child(button)
	search = LineEdit.new()
	search.placeholder_text = "搜索科技名称或 ID"
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(_on_search_changed)
	toolbar.add_child(search)
	status = Label.new()
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(status)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(split)
	graph = GraphEdit.new()
	graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.right_disconnects = true
	graph.connection_request.connect(_on_connection_request)
	graph.disconnection_request.connect(_on_disconnection_request)
	graph.gui_input.connect(_on_graph_input)
	split.add_child(graph)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.x = 390
	split.add_child(scroll)
	details = VBoxContainer.new()
	details.add_theme_constant_override("separation", 8)
	scroll.add_child(details)

func _rebuild_graph() -> void:
	for child in graph.get_children():
		child.queue_free()
	node_controls.clear()
	node_name_to_id.clear()
	for row_value in service.nodes():
		var row: Dictionary = row_value
		var id := String(row.id)
		var node := GraphNode.new()
		node.name = id.replace(".", "_")
		node.title = String(row.get("display_name", id))
		node.size = NODE_SIZE
		node.position_offset = Vector2(float(row.get("layout_order", 0)) * 210.0,
			float(row.get("ui_row", 0)) * 110.0)
		node.set_meta("technology_id", id)
		node.selected.connect(func() -> void: _select(id))
		var label := Label.new()
		label.text = id
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		node.add_child(label)
		node.set_slot(0, true, 0, Color("b9a56a"), true, 0, Color("b9a56a"))
		graph.add_child(node)
		node_controls[id] = node
		node_name_to_id[String(node.name)] = id
	for row_value in service.nodes():
		var row: Dictionary = row_value
		var target := String(row.id)
		for source_value in row.get("hard_prerequisite_ids", []):
			var source := String(source_value)
			if node_controls.has(source):
				graph.connect_node(node_controls[source].name, 0, node_controls[target].name, 0)
	if not service.nodes().is_empty():
		_select(String((service.nodes()[0] as Dictionary).id))

func _select(id: String) -> void:
	selected_id = id
	for child in details.get_children():
		child.queue_free()
	var row := service.node_by_id(id)
	if row.is_empty():
		return
	var heading := Label.new()
	heading.text = "%s  [%s]" % [row.get("display_name", id), id]
	details.add_child(heading)
	_add_text_field("名称", String(row.get("display_name", "")), "display_name")
	_add_multiline_field("描述", String(row.get("description", "")), "description")
	_add_text_field("时代", String(row.get("era_id", "")), "era_id")
	_add_text_field("领域", String(row.get("domain_id", "")), "domain_id")
	_add_spin_field("研究成本", int(row.get("cost_points", 0)), "cost_points")
	_add_multiline_field("效果摘要（自动规范化）", String(row.get("effect_summary", "")), "effect_summary", false)
	_add_multiline_field("揭示摘要", String(row.get("reveal_summary", "")), "reveal_summary")
	_add_multiline_field("机会成本", String(row.get("opportunity_cost", "")), "opportunity_cost")
	_add_multiline_field("终点理由", String(row.get("terminal_reason", "")), "terminal_reason")
	_add_relation_field("硬前置", "hard_prerequisite_ids", row.get("hard_prerequisite_ids", []))
	_add_relation_field("分支后继", "branch_successor_ids", row.get("branch_successor_ids", []))
	_add_relation_field("应用交汇", "application_target_ids", row.get("application_target_ids", []))
	_add_json_field("揭示条件", "reveal_condition", row.get("reveal_condition", {}))
	_add_json_field("研究路线", "research_routes", row.get("research_routes", []))
	_add_json_field("永久 Modifier", "modifier_terms", row.get("modifier_terms", []))
	_add_json_field("内容解锁", "content_effects", row.get("content_effects", []))

func _add_text_field(title: String, value: String, key: String, editable := true) -> void:
	var label := Label.new(); label.text = title; details.add_child(label)
	var field := LineEdit.new(); field.text = value; field.editable = editable; details.add_child(field)
	if editable: field.text_submitted.connect(func(next: String) -> void: _commit({key: next}))

func _add_multiline_field(title: String, value: String, key: String, editable := true) -> void:
	var label := Label.new(); label.text = title; details.add_child(label)
	var field := TextEdit.new(); field.text = value; field.custom_minimum_size.y = 72; field.editable = editable; details.add_child(field)
	if editable: field.focus_exited.connect(func() -> void: _commit({key: field.text}))

func _add_spin_field(title: String, value: int, key: String) -> void:
	var label := Label.new(); label.text = title; details.add_child(label)
	var field := SpinBox.new(); field.value = value; field.min_value = 0; field.max_value = 1000000000000; details.add_child(field)
	field.value_changed.connect(func(next: float) -> void: _commit({key: int(next)}))

func _add_relation_field(title: String, key: String, values: Array) -> void:
	var label := Label.new(); label.text = "%s（每行一个稳定 ID）" % title; details.add_child(label)
	var field := TextEdit.new(); field.text = "\n".join(values.map(func(v): return String(v))); field.custom_minimum_size.y = 80; details.add_child(field)
	field.focus_exited.connect(func() -> void:
		var ids := []
		for line in field.text.split("\n"):
			if not line.strip_edges().is_empty(): ids.append(line.strip_edges())
		_commit({key: ids}))

func _add_json_field(title: String, key: String, value: Variant) -> void:
	var label := Label.new(); label.text = "%s（受目录校验约束的 JSON）" % title; details.add_child(label)
	var field := TextEdit.new(); field.text = JSON.stringify(value, "  "); field.custom_minimum_size.y = 120; details.add_child(field)
	field.focus_exited.connect(func() -> void:
		var parsed := JSON.parse_string(field.text)
		if parsed == null:
			_show_status("%s JSON 无效" % title, true)
			return
		_commit({key: parsed}))

func _commit(changes: Dictionary) -> void:
	if selected_id.is_empty(): return
	var before := service.node_by_id(selected_id).duplicate(true)
	if service.update_node(selected_id, changes):
		undo_stack.append({"id": selected_id, "before": before, "after": service.node_by_id(selected_id).duplicate(true)})
		redo_stack.clear()
		_rebuild_graph()
		_show_status("未保存修改", false)

func _save() -> void:
	var result := service.save()
	if result.ok:
		var normalized := service.run_validator(false)
		var validation := service.run_validator(true) if normalized.ok else normalized
		_show_status("已保存并通过目录编译" if validation.ok else "已保存，但规范校验失败：%s" % validation.output, not validation.ok)
	else: _show_status(String(result.reason), true)

func _validate() -> void:
	var result := service.validate()
	_show_status("结构校验通过（%d 节点）" % int(result.get("nodes", 0)) if result.ok else String(result.reason), not result.ok)

func _reload() -> void:
	var result := service.load_network(); _rebuild_graph(); _show_status("已重新载入" if result.ok else String(result.reason), not result.ok)

func _export_report() -> void:
	var result := service.export_report(); _show_status("报告已刷新" if result.ok else String(result.output), not result.ok)

func _undo() -> void:
	if undo_stack.is_empty(): return
	var item: Dictionary = undo_stack.pop_back(); service.update_node(item.id, item.before); redo_stack.append(item); _rebuild_graph()

func _redo() -> void:
	if redo_stack.is_empty(): return
	var item: Dictionary = redo_stack.pop_back(); service.update_node(item.id, item.after); undo_stack.append(item); _rebuild_graph()

func _on_search_changed(query: String) -> void:
	var q := query.strip_edges().to_lower()
	for id in node_controls:
		var row := service.node_by_id(String(id))
		var hit := q.is_empty() or String(row.get("display_name", "")).to_lower().contains(q) or String(id).to_lower().contains(q)
		node_controls[id].modulate = Color.WHITE if hit else Color(0.35, 0.35, 0.35)

func _on_connection_request(from: StringName, _from_port: int, to: StringName, _to_port: int) -> void:
	var source := String(node_name_to_id.get(String(from), "")); var target := String(node_name_to_id.get(String(to), ""))
	var row := service.node_by_id(target); var ids: Array = row.get("hard_prerequisite_ids", []).duplicate(); if not ids.has(source): ids.append(source); _commit_for(target, {"hard_prerequisite_ids": ids})

func _on_disconnection_request(from: StringName, _from_port: int, to: StringName, _to_port: int) -> void:
	var source := String(node_name_to_id.get(String(from), "")); var target := String(node_name_to_id.get(String(to), "")); var row := service.node_by_id(target); var ids: Array = row.get("hard_prerequisite_ids", []).duplicate(); ids.erase(source); _commit_for(target, {"hard_prerequisite_ids": ids})

func _commit_for(id: String, changes: Dictionary) -> void:
	var old := selected_id; selected_id = id; _commit(changes); selected_id = old

func _on_graph_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		for id in node_controls:
			var node: GraphNode = node_controls[id]
			if node.position_offset != Vector2.ZERO:
				service.update_node(String(id), {"ui_row": int(node.position_offset.y / 110.0), "layout_order": node.position_offset.x / 210.0})

func _show_status(message: String, error: bool) -> void:
	if status == null: return
	status.text = message
	status.modulate = Color("d46a63") if error else Color("9ac6a1")
