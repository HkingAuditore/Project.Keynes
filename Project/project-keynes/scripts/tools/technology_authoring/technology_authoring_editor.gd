extends Control

## Technology authoring workbench.
##
## Everything the author edits goes through TechnologyAuthoringModel, so paired
## rationale arrays cannot drift and structural edits are undoable. Validation
## is the same TechnologyNetworkValidator the headless gate runs, executed in
## process on a short debounce, so problems appear while typing instead of
## after a save is rejected.

const ServiceScript = preload("res://scripts/technology/technology_authoring_service.gd")
const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")
const InspectorScript = preload(
	"res://scripts/tools/technology_authoring/technology_authoring_inspector.gd")
const CanvasScript = preload(
	"res://scripts/tools/technology_authoring/technology_authoring_canvas.gd")

const VALIDATION_DEBOUNCE := 0.12
const TABLE_COLUMNS := ["ID", "名称", "时代", "领域", "分支族", "成本", "角色",
	"效果", "解锁", "问题"]
const TABLE_WIDTHS := [220, 160, 90, 90, 170, 90, 90, 60, 60, 60]
const ALL_LABEL := "全部"

const CONTEXT_ADD_SUCCESSOR := 0
const CONTEXT_DUPLICATE := 1
const CONTEXT_DELETE := 2
const CONTEXT_MILESTONE_CANDIDATE := 3
const CONTEXT_RENAME := 4
const CONTEXT_FOCUS := 5

const BINDING_KIND_BY_CONTENT := {"good": 1, "building": 2, "resource": 3}

const EDGE_KIND_LABELS := {
	"hard": "硬前置",
	"branch": "分支后继",
	"application": "应用交汇",
	"alternative": "替代路线",
	"milestone_candidate": "里程碑候选",
}

var _service: TechnologyAuthoringService = ServiceScript.new()
var _inspector
var _selected := ""
var _selection: PackedStringArray = PackedStringArray()
var _findings: Array = []
var _findings_by_node: Dictionary = {}
var _severity_by_node: Dictionary = {}
var _match_ids: Dictionary = {}
var _search_blobs: Dictionary = {}
var _edge_kinds: Dictionary = {}
var _filtered := false
var _table_items: Dictionary = {}
var _validation_timer: Timer
var _context_menu: PopupMenu
var _context_target := ""
var _picker_callback: Callable = Callable()
var _picker_options: PackedStringArray = PackedStringArray()
var _picker_labels: PackedStringArray = PackedStringArray()
var _confirm_action := ""
var _confirm_payload: Dictionary = {}
var _text_input_action := ""
var _text_input_payload: Dictionary = {}
var _meta_mode := "eras"
var _rebakes := 0
var _last_filter_msec := 0.0

@onready var _canvas: Control = %GraphCanvas
@onready var _table: Tree = %TableTree
@onready var _outline: Tree = %OutlineTree
@onready var _problems: Tree = %ProblemsTree
@onready var _status: Label = %StatusLabel
@onready var _search: LineEdit = %SearchField
@onready var _era_filter: OptionButton = %EraFilter
@onready var _domain_filter: OptionButton = %DomainFilter
@onready var _family_filter: OptionButton = %FamilyFilter
@onready var _role_filter: OptionButton = %RoleFilter
@onready var _problem_only: CheckBox = %ProblemOnlyToggle
@onready var _inspector_box: VBoxContainer = %InspectorBox
@onready var _message_dialog: AcceptDialog = %MessageDialog
@onready var _message_text: RichTextLabel = %MessageText
@onready var _confirm_dialog: ConfirmationDialog = %ConfirmDialog
@onready var _confirm_text: RichTextLabel = %ConfirmText
@onready var _text_dialog: ConfirmationDialog = %TextInputDialog
@onready var _new_node_dialog: ConfirmationDialog = %NewNodeDialog
@onready var _meta_dialog: AcceptDialog = %MetaDialog
@onready var _meta_tree: Tree = %MetaTree
@onready var _picker_popup: PopupPanel = %PickerPopup
@onready var _picker_query: LineEdit = %PickerQuery
@onready var _picker_list: ItemList = %PickerList
@onready var _problems_label: Label = %ProblemsLabel
@onready var _save_button: Button = %SaveButton
@onready var _undo_button: Button = %UndoButton
@onready var _redo_button: Button = %RedoButton
@onready var _graph_view_button: Button = %GraphViewButton
@onready var _table_view_button: Button = %TableViewButton
@onready var _meta_hint: Label = %MetaHint
@onready var _picker_title: Label = %PickerTitle
@onready var _new_node_hint: Label = %NewNodeHint
@onready var _new_id_edit: LineEdit = %IdEdit
@onready var _new_name_edit: LineEdit = %NameEdit
@onready var _new_era_option: OptionButton = %EraOption
@onready var _new_domain_option: OptionButton = %DomainOption
@onready var _new_family_option: OptionButton = %FamilyOption
@onready var _primary_label: Label = %PrimaryLabel
@onready var _primary_edit: LineEdit = %PrimaryEdit
@onready var _secondary_label: Label = %SecondaryLabel
@onready var _secondary_edit: LineEdit = %SecondaryEdit
@onready var _hint_label: Label = %HintLabel


func _ready() -> void:
	_inspector = InspectorScript.new(_inspector_box, self)
	_validation_timer = Timer.new()
	_validation_timer.one_shot = true
	_validation_timer.wait_time = VALIDATION_DEBOUNCE
	_validation_timer.timeout.connect(_run_validation)
	add_child(_validation_timer)
	_context_menu = PopupMenu.new()
	add_child(_context_menu)
	_context_menu.id_pressed.connect(_on_context_selected)
	_configure_table()
	_configure_edge_filters()
	_configure_problems()
	_connect_toolbar()
	_connect_views()
	_service.model.batch_committed.connect(_on_batch_committed)
	_load_everything()


func _configure_table() -> void:
	_table.columns = TABLE_COLUMNS.size()
	_table.column_titles_visible = true
	for index in range(TABLE_COLUMNS.size()):
		_table.set_column_title(index, String(TABLE_COLUMNS[index]))
		_table.set_column_expand(index, false)
		_table.set_column_custom_minimum_width(index, int(TABLE_WIDTHS[index]))
	_table.set_column_expand(1, true)


## The canvas hides route evidence and milestone candidacy by default, which is
## the difference between 1331 and 553 drawn edges. That default only stays
## honest if the author can see it and put the edges back.
func _configure_edge_filters() -> void:
	var box := %EdgeKindBox as VBoxContainer
	var defaults: Dictionary = CanvasScript.DEFAULT_EDGE_KINDS
	for kind in EDGE_KIND_LABELS.keys():
		var toggle := CheckBox.new()
		toggle.text = String(EDGE_KIND_LABELS[kind])
		toggle.button_pressed = bool(defaults.get(kind, true))
		toggle.toggled.connect(_on_edge_kind_toggled.bind(String(kind)))
		box.add_child(toggle)
		_edge_kinds[kind] = toggle.button_pressed
	(%SelectionOnlyEdges as CheckBox).toggled.connect(
		func(pressed: bool) -> void:
			_canvas.call("set_selection_only_edges", pressed))


func _on_edge_kind_toggled(pressed: bool, kind: String) -> void:
	_edge_kinds[kind] = pressed
	_canvas.call("set_edge_kinds", _edge_kinds)


func _configure_problems() -> void:
	_problems.columns = 3
	_problems.column_titles_visible = true
	_problems.set_column_title(0, "严重度 / 代码")
	_problems.set_column_title(1, "节点")
	_problems.set_column_title(2, "说明")
	# Column minimums add straight into the dock's minimum width, which then
	# pushes the whole shell wider than the window. Keep them modest and let the
	# message column absorb the slack.
	_problems.set_column_custom_minimum_width(0, 180)
	_problems.set_column_custom_minimum_width(1, 120)
	_problems.set_column_expand(0, false)
	_problems.set_column_expand(1, false)
	_problems.set_column_expand(2, true)
	_problems.set_column_clip_content(0, true)
	_problems.set_column_clip_content(1, true)
	_problems.set_column_clip_content(2, true)


func _connect_toolbar() -> void:
	_save_button.pressed.connect(_on_save_pressed)
	(%DraftSaveButton as Button).pressed.connect(_on_draft_save_pressed)
	(%ValidateButton as Button).pressed.connect(_run_validation)
	(%ReloadButton as Button).pressed.connect(_on_reload_pressed)
	(%GateButton as Button).pressed.connect(_on_gate_pressed)
	(%ReportButton as Button).pressed.connect(_on_report_pressed)
	_undo_button.pressed.connect(_on_undo_pressed)
	_redo_button.pressed.connect(_on_redo_pressed)
	_graph_view_button.pressed.connect(_show_graph_view.bind(true))
	_table_view_button.pressed.connect(_show_graph_view.bind(false))
	(%NewNodeButton as Button).pressed.connect(_on_new_node_pressed)
	(%RenameNodeButton as Button).pressed.connect(_on_rename_pressed)
	(%DeleteNodeButton as Button).pressed.connect(_on_delete_pressed)
	(%EraEditorButton as Button).pressed.connect(_open_meta_dialog.bind("eras"))
	(%MetaEditorButton as Button).pressed.connect(_open_meta_dialog.bind("families"))
	(%ProblemsCopyButton as Button).pressed.connect(_on_copy_problems)


func _connect_views() -> void:
	_canvas.selection_changed.connect(_on_canvas_selection)
	_canvas.node_activated.connect(_focus_technology)
	_canvas.connect_requested.connect(_on_connect_requested)
	_canvas.context_requested.connect(_on_context_requested)
	_canvas.reorder_requested.connect(_on_reorder_requested)
	_table.item_selected.connect(_on_table_selected)
	_table.item_edited.connect(_on_table_edited)
	_outline.item_selected.connect(_on_outline_selected)
	_problems.item_activated.connect(_on_problem_activated)
	_search.text_changed.connect(func(_text: String) -> void: _apply_filters())
	for option in [_era_filter, _domain_filter, _family_filter, _role_filter]:
		option.item_selected.connect(func(_index: int) -> void: _apply_filters())
	_problem_only.toggled.connect(func(_pressed: bool) -> void: _apply_filters())
	_confirm_dialog.confirmed.connect(_on_confirm_accepted)
	_text_dialog.confirmed.connect(_on_text_input_accepted)
	_new_node_dialog.confirmed.connect(_on_new_node_confirmed)
	_picker_query.text_changed.connect(func(_text: String) -> void: _refresh_picker())
	_picker_list.item_activated.connect(_on_picker_activated)
	_meta_tree.item_edited.connect(_on_meta_edited)


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

func _load_everything() -> void:
	var loaded := _service.load_network()
	if not bool(loaded.ok):
		_status.text = "载入失败：%s" % String(loaded.reason)
		return
	var content := _service.load_content_index()
	_rebuild_search_index()
	_populate_filters()
	_populate_new_node_dialog()
	_rebake_canvas()
	_rebuild_table()
	_rebuild_outline()
	_run_validation()
	_canvas.call("fit_to_content")
	_status.text = "已载入 %d 节点 / %d 应用交汇 · 内容索引 %d 建筑 / %d 物资 / %d stat（%dms%s）" % [
		int(loaded.nodes), int(loaded.application_intersections),
		int(content.buildings), int(content.goods), int(content.modifier_stats),
		int(content.msec), "，命中缓存" if bool(content.cached) else ""]


## Keyboard shortcuts run through `_shortcut_input`, which fires only after the
## focused control had its chance. A LineEdit therefore keeps its own Ctrl+Z and
## Delete while typing instead of deleting the selected technology.
func _shortcut_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo or _dialog_open():
		return
	var control := key.is_command_or_control_pressed()
	match key.keycode:
		KEY_S when control and key.shift_pressed:
			_on_draft_save_pressed()
		KEY_S when control:
			_on_save_pressed()
		KEY_Z when control and key.shift_pressed:
			if _service.model.can_redo():
				_on_redo_pressed()
		KEY_Y when control:
			if _service.model.can_redo():
				_on_redo_pressed()
		KEY_Z when control:
			if _service.model.can_undo():
				_on_undo_pressed()
		KEY_DELETE when not control:
			if _selected.is_empty():
				return
			_on_delete_pressed()
		KEY_F when not control:
			if _selected.is_empty():
				return
			_focus_technology(_selected)
		_:
			return
	get_viewport().set_input_as_handled()


func _dialog_open() -> bool:
	for dialog in [_message_dialog, _confirm_dialog, _text_dialog, _new_node_dialog,
			_meta_dialog]:
		if (dialog as Window).visible:
			return true
	return _picker_popup.visible


func _rebake_canvas() -> void:
	_rebakes += 1
	var payload := _service.model.payload()
	var edges := ValidatorScript.build_visual_edges(payload)
	_canvas.call("set_catalog", _service.model.nodes(), _service.model.meta_array("eras"),
		_service.model.meta_array("domains"), edges)
	_canvas.call("select", _selection, _selected)


func authoring_model() -> TechnologyAuthoringModel:
	return _service.model


func report() -> Dictionary:
	var canvas_report: Dictionary = _canvas.call("report")
	return {
		"nodes": _service.model.node_count(),
		"findings": _findings.size(),
		"rebakes": _rebakes,
		"canvas": canvas_report,
		"filter_msec": _last_filter_msec,
		"matches": _match_ids.size(),
		"table_rows": _table_items.size(),
		"selected": _selected,
	}


func is_match(id: String) -> bool:
	return _match_ids.has(id)


## Hands the smoke test a real `.tres` unlock so it can prove the cross-file
## search path works against the shipped content, not a fixture.
func unlock_search_probe() -> Dictionary:
	for technology_id in _service.index.unlocks_by_technology:
		for entry_value in _service.index.unlocks_by_technology[technology_id]:
			var entry: Dictionary = entry_value
			var display_name := String(entry.display_name).strip_edges()
			if display_name.length() < 2 or not _service.model.has_technology(
					String(technology_id)):
				continue
			return {"technology_id": String(technology_id), "needle": display_name}
	return {}


# --------------------------------------------------------------------------
# Filters, outline and table
# --------------------------------------------------------------------------

func _populate_filters() -> void:
	_fill_option(_era_filter, _service.model.meta_array("eras"))
	_fill_option(_domain_filter, _service.model.meta_array("domains"))
	var families: Array = _service.model.meta_array("backbones") \
		+ _service.model.meta_array("branch_families")
	_fill_option(_family_filter, families)
	_role_filter.clear()
	_role_filter.add_item("%s（角色）" % ALL_LABEL, 0)
	var roles := distinct_values("network_role")
	for index in range(roles.size()):
		_role_filter.add_item(String(roles[index]), index + 1)


func _fill_option(option: OptionButton, rows: Array) -> void:
	option.clear()
	option.add_item(ALL_LABEL, 0)
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		option.add_item("%s（%s）" % [String(row.get("display_name", "")),
			String(row.get("id", ""))], index + 1)
		option.set_item_metadata(index + 1, String(row.get("id", "")))


func _selected_filter(option: OptionButton) -> String:
	var index := option.get_selected()
	if index <= 0:
		return ""
	var metadata: Variant = option.get_item_metadata(index)
	return String(metadata) if metadata != null else option.get_item_text(index)


func _apply_filters() -> void:
	var started := Time.get_ticks_usec()
	var needle := _search.text.strip_edges().to_lower()
	var era := _selected_filter(_era_filter)
	var domain := _selected_filter(_domain_filter)
	var family := _selected_filter(_family_filter)
	var role := _role_filter.get_item_text(_role_filter.get_selected()) \
		if _role_filter.get_selected() > 0 else ""
	var problems_only := _problem_only.button_pressed
	_filtered = not needle.is_empty() or not era.is_empty() or not domain.is_empty() \
		or not family.is_empty() or not role.is_empty() or problems_only
	_match_ids.clear()
	for node_value in _service.model.nodes():
		var row: Dictionary = node_value
		var id := String(row.get("id", ""))
		if not era.is_empty() and String(row.get("era_id", "")) != era:
			continue
		if not domain.is_empty() and String(row.get("domain_id", "")) != domain:
			continue
		if not family.is_empty() and String(row.get("branch_family_id", "")) != family:
			continue
		if not role.is_empty() and String(row.get("network_role", "")) != role:
			continue
		if problems_only and not _findings_by_node.has(id):
			continue
		if not needle.is_empty() and not _matches_text(id, needle):
			continue
		_match_ids[id] = true
	_last_filter_msec = float(Time.get_ticks_usec() - started) / 1000.0
	_canvas.call("set_matches", _match_ids, _filtered)
	_rebuild_outline()
	_refresh_table_visibility()


## Real text search across identity, player text, effects and unlocked content,
## replacing the prototype's cosmetic dimming.
##
## The haystack is precomputed per technology because rebuilding it inside the
## keystroke loop cost more than 10ms across 369 nodes, which is felt as lag
## while typing.
func _matches_text(id: String, needle: String) -> bool:
	return String(_search_blobs.get(id, "")).contains(needle)


func _rebuild_search_index() -> void:
	_search_blobs.clear()
	for node_value in _service.model.nodes():
		_write_search_blob(String((node_value as Dictionary).get("id", "")))


func _write_search_blob(id: String) -> void:
	var row := _service.model.node(id)
	if row.is_empty():
		_search_blobs.erase(id)
		return
	var parts := PackedStringArray([id])
	for key in ["display_name", "effect_summary", "reveal_summary", "terminal_reason",
			"opportunity_cost", "network_role", "node_role", "effect_profile",
			"branch_family_id"]:
		parts.append(String(row.get(key, "")))
	for term_value in row.get("modifier_terms", []):
		var term: Dictionary = term_value
		parts.append(String(term.get("stat", "")))
		parts.append(String(term.get("subject_id", "")))
		parts.append(String(term.get("subject_display_name", "")))
	for effect_value in row.get("content_effects", []):
		var effect: Dictionary = effect_value
		parts.append(String(effect.get("id", "")))
		parts.append(String(effect.get("display_name", "")))
	for entry_value in _service.index.unlocks_by_technology.get(id, []):
		var entry: Dictionary = entry_value
		parts.append(String(entry.id))
		parts.append(String(entry.display_name))
	_search_blobs[id] = "\u0001".join(parts).to_lower()


func _rebuild_outline() -> void:
	_outline.clear()
	var root := _outline.create_item()
	for era_value in _service.model.meta_array("eras"):
		var era: Dictionary = era_value
		var era_id := String(era.get("id", ""))
		var members: Array[Dictionary] = []
		for node_value in _service.model.nodes():
			var row: Dictionary = node_value
			if String(row.get("era_id", "")) != era_id:
				continue
			var id := String(row.get("id", ""))
			if _filtered and not _match_ids.has(id):
				continue
			members.append(row)
		if members.is_empty():
			continue
		var era_item := _outline.create_item(root)
		era_item.set_text(0, "%s（%d）" % [String(era.get("display_name", era_id)),
			members.size()])
		era_item.set_selectable(0, false)
		era_item.set_collapsed(members.size() > 24)
		for row in members:
			var id := String(row.get("id", ""))
			var item := _outline.create_item(era_item)
			item.set_text(0, "%s  %s" % [String(row.get("display_name", id)),
				id.trim_prefix("tech.")])
			item.set_metadata(0, id)
			var severity := String(_severity_by_node.get(id, ""))
			if severity == "error":
				item.set_custom_color(0, UITokens.RISK)
			elif severity == "warning":
				item.set_custom_color(0, UITokens.WARN)


func _rebuild_table() -> void:
	_table.clear()
	_table_items.clear()
	var root := _table.create_item()
	for node_value in _service.model.nodes():
		var row: Dictionary = node_value
		var item := _table.create_item(root)
		_table_items[String(row.get("id", ""))] = item
		_write_table_row(item, row)


func _write_table_row(item: TreeItem, row: Dictionary) -> void:
	var id := String(row.get("id", ""))
	item.set_metadata(0, id)
	item.set_text(0, id)
	item.set_text(1, String(row.get("display_name", "")))
	item.set_editable(1, true)
	item.set_text(2, String(row.get("era_id", "")))
	item.set_text(3, String(row.get("domain_id", "")))
	item.set_text(4, String(row.get("branch_family_id", "")))
	item.set_cell_mode(5, TreeItem.CELL_MODE_RANGE)
	item.set_range_config(5, 0.0, 100000000.0, 100.0)
	item.set_range(5, float(row.get("cost_points", 0.0)))
	item.set_editable(5, true)
	item.set_text(6, String(row.get("network_role", "")))
	item.set_text(7, str((row.get("modifier_terms", []) as Array).size()))
	item.set_text(8, str((row.get("content_effects", []) as Array).size()))
	var problems: Array = _findings_by_node.get(id, [])
	item.set_text(9, str(problems.size()))
	var severity := String(_severity_by_node.get(id, ""))
	for column in range(TABLE_COLUMNS.size()):
		if severity == "error":
			item.set_custom_color(column, UITokens.RISK)
		elif severity == "warning":
			item.set_custom_color(column, UITokens.WARN)
		else:
			item.clear_custom_color(column)


func _refresh_table_visibility() -> void:
	for id in _table_items:
		var item: TreeItem = _table_items[id]
		item.visible = not _filtered or _match_ids.has(id)


## Applies a search term as if it were typed, for scripted checks.
func set_search_text(text: String) -> void:
	_search.text = text
	_apply_filters()


func show_view(graph: bool) -> void:
	_show_graph_view(graph)


func validate_now() -> void:
	_run_validation()


func inspector_row_count() -> int:
	return _inspector_box.get_child_count()


func findings() -> Array:
	return _findings


func save_blocked() -> bool:
	return _save_button.disabled


func draft_save_blocked() -> bool:
	return (%DraftSaveButton as Button).disabled


func focus_search_field() -> void:
	_search.grab_focus()


func focus_canvas() -> void:
	_canvas.grab_focus()


func _show_graph_view(graph: bool) -> void:
	_canvas.visible = graph
	_table.visible = not graph
	_graph_view_button.button_pressed = graph
	_table_view_button.button_pressed = not graph


# --------------------------------------------------------------------------
# Validation and problems
# --------------------------------------------------------------------------

func _queue_validation() -> void:
	_validation_timer.start()


func _run_validation() -> void:
	var result := _service.validate()
	_findings = result.findings
	_findings_by_node = ServiceScript.group_findings(_findings)
	_severity_by_node.clear()
	for id in _findings_by_node:
		var severity := "warning"
		for value in _findings_by_node[id]:
			if String((value as Dictionary).get("severity", "")) == "error":
				severity = "error"
				break
		_severity_by_node[String(id)] = severity
	_canvas.call("set_problems", _severity_by_node)
	_rebuild_problems(float(result.msec))
	for id in _table_items:
		_write_table_row(_table_items[id], _service.model.node(String(id)))
	_rebuild_outline()
	_save_button.disabled = not bool(result.ok)
	if not _selected.is_empty():
		_refresh_inspector()


func _rebuild_problems(msec: float) -> void:
	_problems.clear()
	var root := _problems.create_item()
	var errors := ValidatorScript.error_count(_findings)
	_problems_label.text = "问题：%d 错误 / %d 警告（校验 %.2fms）" % [
		errors, _findings.size() - errors, msec]
	var ordered: Array = _findings.duplicate()
	ordered.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		var left_key := "%s|%s" % [
			"0" if String(left.get("severity", "")) == "error" else "1",
			String(left.get("code", ""))]
		var right_key := "%s|%s" % [
			"0" if String(right.get("severity", "")) == "error" else "1",
			String(right.get("code", ""))]
		return left_key < right_key)
	for value in ordered:
		var row: Dictionary = value
		var item := _problems.create_item(root)
		var severity := String(row.get("severity", ""))
		item.set_text(0, "%s  %s" % ["错误" if severity == "error" else "警告",
			String(row.get("code", ""))])
		item.set_text(1, String(row.get("node_id", "")))
		item.set_text(2, String(row.get("message", "")))
		item.set_metadata(0, {"node_id": String(row.get("node_id", "")),
			"field": String(row.get("field", ""))})
		item.set_custom_color(0, UITokens.RISK if severity == "error" else UITokens.WARN)


func _on_problem_activated() -> void:
	var item := _problems.get_selected()
	if item == null:
		return
	var metadata: Dictionary = item.get_metadata(0)
	await focus_problem(String(metadata.get("node_id", "")),
		String(metadata.get("field", "")))


## Jumps to the node and then to the field the finding names. The inspector is
## rebuilt synchronously but only laid out next frame, so the scroll has to wait.
func focus_problem(id: String, field: String) -> bool:
	if id.is_empty() or not _service.model.has_technology(id):
		return false
	select_technology(id)
	_focus_technology(id)
	if field.is_empty():
		return false
	await get_tree().process_frame
	return bool(_inspector.focus_field(field))


func _on_copy_problems() -> void:
	var lines := PackedStringArray()
	for value in _findings:
		var row: Dictionary = value
		lines.append("%s\t%s\t%s\t%s" % [String(row.get("severity", "")),
			String(row.get("code", "")), String(row.get("node_id", "")),
			String(row.get("message", ""))])
	DisplayServer.clipboard_set("\n".join(lines))
	_status.text = "已复制 %d 条问题到剪贴板" % _findings.size()


# --------------------------------------------------------------------------
# Selection
# --------------------------------------------------------------------------

func select_technology(id: String) -> void:
	_selected = id
	_selection = PackedStringArray([id]) if not id.is_empty() else PackedStringArray()
	_canvas.call("select", _selection, id)
	var item: TreeItem = _table_items.get(id, null)
	if item != null and _table.visible:
		item.select(0)
	_refresh_inspector()


func _refresh_inspector() -> void:
	if _selected.is_empty():
		_inspector.clear()
		return
	_inspector.show_technology(_selected, _findings_by_node.get(_selected, []))


func _on_canvas_selection(ids: PackedStringArray) -> void:
	_selection = ids
	_selected = String(ids[0]) if not ids.is_empty() else ""
	_refresh_inspector()


func _on_table_selected() -> void:
	var item := _table.get_selected()
	if item == null:
		return
	var id := String(item.get_metadata(0))
	_selected = id
	_selection = PackedStringArray([id])
	_canvas.call("select", _selection, id)
	_refresh_inspector()


func _on_outline_selected() -> void:
	var item := _outline.get_selected()
	if item == null:
		return
	var metadata: Variant = item.get_metadata(0)
	if metadata == null:
		return
	select_technology(String(metadata))
	_focus_technology(String(metadata))


func _focus_technology(id: String) -> void:
	_canvas.call("focus_technology", id)


func _on_table_edited() -> void:
	var item := _table.get_edited()
	if item == null:
		return
	var id := String(item.get_metadata(0))
	match _table.get_edited_column():
		1: commit_field(id, "display_name", item.get_text(1))
		5: commit_field(id, "cost_points", item.get_range(5))


# --------------------------------------------------------------------------
# Editing entry points used by the inspector
# --------------------------------------------------------------------------

func technology_row(id: String) -> Dictionary:
	return _service.model.node(id)


func technology_display_name(id: String) -> String:
	var row := _service.model.node(id)
	return String(row.get("display_name", id)) if not row.is_empty() else "（不存在）%s" % id


func enum_source(source: String) -> PackedStringArray:
	var out := PackedStringArray()
	match source:
		"eras":
			for row in _service.model.meta_array("eras"):
				out.append(String((row as Dictionary).get("id", "")))
		"domains":
			for row in _service.model.meta_array("domains"):
				out.append(String((row as Dictionary).get("id", "")))
		"families":
			for row in _service.model.meta_array("backbones"):
				out.append(String((row as Dictionary).get("id", "")))
			for row in _service.model.meta_array("branch_families"):
				out.append(String((row as Dictionary).get("id", "")))
		"reveal_categories":
			for value in ValidatorScript.ALLOWED_REVEAL_CATEGORIES:
				out.append(String(value))
		"technologies_optional":
			out.append("")
			out.append_array(_service.model.ids())
	return out


## Distinct authored values for a free-text field, used by the "…" pickers so
## authors stay consistent without inventing a schema enum.
func distinct_values(key: String) -> PackedStringArray:
	var seen := {}
	for node_value in _service.model.nodes():
		var value := String((node_value as Dictionary).get(key, ""))
		if value.is_empty():
			continue
		seen[value] = true
	var out := PackedStringArray()
	for value in seen:
		out.append(String(value))
	out.sort()
	return out


func distinct_term_values(key: String) -> PackedStringArray:
	var seen := {}
	for node_value in _service.model.nodes():
		for term_value in (node_value as Dictionary).get("modifier_terms", []):
			var value := String((term_value as Dictionary).get(key, ""))
			if value.is_empty():
				continue
			seen[value] = true
	var out := PackedStringArray()
	for value in seen:
		out.append(String(value))
	out.sort()
	return out


func commit_field(id: String, key: String, value: Variant) -> void:
	_service.model.begin_batch("编辑 %s" % key)
	_service.model.set_field(id, key, value)
	_service.model.commit_batch()


func relation_entries(id: String, field: String) -> Array:
	return _service.model.relation(id, field)


func commit_relation_rationale(id: String, field: String, slot: int,
		text: String) -> void:
	var entries := _service.model.relation(id, field)
	if slot < 0 or slot >= entries.size():
		return
	(entries[slot] as Dictionary)["rationale"] = text
	_service.model.begin_batch("编辑 %s 理由" % field)
	_service.model.set_relation(id, field, entries)
	_service.model.commit_batch()


func remove_relation_entry(id: String, field: String, target_id: String) -> void:
	_service.model.begin_batch("移除 %s" % field)
	_service.model.remove_relation_entry(id, field, target_id)
	_service.model.commit_batch()
	_refresh_inspector()


## Relations always ask for the rationale, because the gate rejects any entry
## without one and the arrays must stay equally long.
func prompt_relation_entry(id: String, field: String, label: String) -> void:
	open_technology_picker("选择%s" % label, func(picked: String) -> void:
		_open_text_input("添加%s" % label, "目标科技", picked, "理由（必填）", "",
			"两个输入都会写入配对数组，缺理由会被闸门拒绝。",
			"relation", {"id": id, "field": field}))


func _apply_relation_entry(payload: Dictionary, target_id: String,
		rationale: String) -> void:
	var id := String(payload.id)
	var field := String(payload.field)
	if not _service.model.has_technology(target_id):
		_show_message("未知科技", "科技 %s 不存在。" % target_id)
		return
	_service.model.begin_batch("添加 %s" % field)
	_service.model.add_relation_entry(id, field, target_id, rationale)
	_service.model.commit_batch()
	_refresh_inspector()


func open_value_picker(title: String, key: String, callback: Callable) -> void:
	_open_picker(title, distinct_values(key), PackedStringArray(), callback)


func open_term_value_picker(key: String, callback: Callable) -> void:
	if key == "runtime_consumer" or key == "effect_class" or key == "subject_kind":
		_open_picker("已有取值：%s" % key, distinct_term_values(key),
			PackedStringArray(), callback)
		return
	_open_picker("已有取值：%s" % key, distinct_term_values(key),
		PackedStringArray(), callback)


func open_stat_picker(callback: Callable) -> void:
	var options := _service.index.modifier_stat_keys
	if options.is_empty():
		_show_message("Modifier 目录不可用",
			"无法编译 Modifier 目录（%s），stat 选择器为空。" % _service.index.stat_registry_reason)
		return
	_open_picker("选择 Modifier stat（%d 个合法键）" % options.size(), options,
		PackedStringArray(), callback)


func open_technology_picker(title: String, callback: Callable) -> void:
	var ids := _service.model.ids()
	var labels := PackedStringArray()
	for id in ids:
		labels.append("%s  —  %s" % [String(id), technology_display_name(String(id))])
	_open_picker(title, ids, labels, callback)


func stat_hint(stat: String) -> String:
	if stat.is_empty():
		return "尚未选择 stat"
	var meta: Dictionary = _service.index.modifier_stats.get(stat, {})
	if meta.is_empty():
		return "%s 不在 Modifier 目录中，编译经济目录时会失败。" % stat
	return "%s\n取值范围 %.3f – %.3f" % [stat, float(meta.min), float(meta.max)]


func term_subject_label(term: Dictionary) -> String:
	var subject := String(term.get("subject_display_name", ""))
	if not subject.is_empty():
		return subject
	var stat := String(term.get("stat", ""))
	return String(ValidatorScript.MODIFIER_SUBJECT_NAMES.get(stat, stat))


func commit_term_field(id: String, slot: int, key: String, value: Variant) -> void:
	var row := _service.model.node(id)
	var terms: Array = (row.get("modifier_terms", []) as Array).duplicate(true)
	if slot < 0 or slot >= terms.size():
		return
	(terms[slot] as Dictionary)[key] = value
	_service.model.begin_batch("编辑效果 %s" % key)
	_service.model.set_field(id, "modifier_terms", terms)
	_service.model.commit_batch()
	if key == "stat" or key == "implementation_status":
		_refresh_inspector()


func add_term(id: String) -> void:
	var row := _service.model.node(id)
	var terms: Array = (row.get("modifier_terms", []) as Array).duplicate(true)
	terms.append({
		"stat": "",
		"operation": 0.0,
		"value": 0.05,
		"subject_kind": "country",
		"subject_id": "",
		"subject_display_name": "",
		"effect_class": "",
		"effect_rationale": "",
		"implementation_status": "runtime_consumed",
		"runtime_consumer": "",
	})
	_service.model.begin_batch("添加效果项")
	_service.model.set_field(id, "modifier_terms", terms)
	_service.model.commit_batch()
	_refresh_inspector()


func remove_term(id: String, slot: int) -> void:
	remove_array_entry(id, "modifier_terms", slot)


func remove_array_entry(id: String, key: String, slot: int) -> void:
	var row := _service.model.node(id)
	var values: Array = (row.get(key, []) as Array).duplicate(true)
	if slot < 0 or slot >= values.size():
		return
	values.remove_at(slot)
	_service.model.begin_batch("移除 %s 条目" % key)
	_service.model.set_field(id, key, values)
	_service.model.commit_batch()
	_refresh_inspector()


func content_exists(kind: String, id: String) -> bool:
	return _service.index.has_entry(kind, id)


func unlock_reconciliation(id: String) -> Dictionary:
	return _service.reconcile_unlocks(id)


func sync_unlock_to_tres(id: String, kind: String, content_id: String) -> void:
	var result := _service.set_content_technology(kind, content_id, id, true)
	if not bool(result.ok):
		_show_message("写入 .tres 失败", String(result.reason))
		return
	_status.text = "已把 %s 写入 %s" % [id, String(result.path)]
	_refresh_inspector()


func adopt_unlock_from_tres(id: String, kind: String, content_id: String,
		display_name: String) -> void:
	var row := _service.model.node(id)
	var effects: Array = (row.get("content_effects", []) as Array).duplicate(true)
	effects.append({
		"kind": kind,
		"id": content_id,
		"display_name": display_name,
		"operation": "unlock",
	})
	_service.model.begin_batch("补入解锁效果")
	_service.model.set_field(id, "content_effects", effects)
	_service.model.commit_batch()
	_refresh_inspector()


func prompt_content_effect(id: String) -> void:
	_open_picker("选择解锁内容类型", PackedStringArray(["building", "good", "resource"]),
		PackedStringArray(["建筑", "物资", "自然资源"]),
		func(kind: String) -> void: _prompt_content_id(id, kind))


func _prompt_content_id(id: String, kind: String) -> void:
	var options := _service.index.options(kind)
	var ids := PackedStringArray()
	var labels := PackedStringArray()
	for option_value in options:
		var option: Dictionary = option_value
		ids.append(String(option.id))
		labels.append("%s  —  %s" % [String(option.id), String(option.display_name)])
	_open_picker("选择%s" % kind, ids, labels, func(picked: String) -> void:
		adopt_unlock_from_tres(id, kind, picked,
			_service.index.display_name(kind, picked)))


## expected_bindings is the audited mirror of content_effects, so it is derived
## rather than typed twice.
func sync_expected_bindings(id: String) -> void:
	var row := _service.model.node(id)
	var bindings: Array = []
	var seen := {}
	for effect_value in row.get("content_effects", []):
		var effect: Dictionary = effect_value
		if String(effect.get("operation", "")) != "unlock":
			continue
		var kind := int(BINDING_KIND_BY_CONTENT.get(String(effect.get("kind", "")), 0))
		var content_id := String(effect.get("id", ""))
		if kind <= 0 or content_id.is_empty():
			continue
		var key := "%d|%s" % [kind, content_id]
		if seen.has(key):
			continue
		seen[key] = true
		bindings.append({"kind": kind, "id": content_id})
	_service.model.begin_batch("同步预期绑定")
	_service.model.set_field(id, "expected_bindings", bindings)
	_service.model.commit_batch()
	_refresh_inspector()


func prompt_support_building(id: String) -> void:
	var options := _service.index.options("building")
	var ids := PackedStringArray()
	var labels := PackedStringArray()
	for option_value in options:
		var option: Dictionary = option_value
		ids.append(String(option.id))
		labels.append("%s  —  %s" % [String(option.id), String(option.display_name)])
	_open_picker("选择支撑建筑", ids, labels, func(picked: String) -> void:
		var row := _service.model.node(id)
		var rows: Array = (row.get("support_buildings", []) as Array).duplicate(true)
		rows.append({"id": picked,
			"name": _service.index.display_name("building", picked)})
		_service.model.begin_batch("添加支撑建筑")
		_service.model.set_field(id, "support_buildings", rows)
		_service.model.commit_batch()
		_refresh_inspector())


func commit_route_field(id: String, slot: int, key: String, value: Variant) -> void:
	var row := _service.model.node(id)
	var routes: Array = (row.get("research_routes", []) as Array).duplicate(true)
	if slot < 0 or slot >= routes.size():
		return
	(routes[slot] as Dictionary)[key] = value
	_service.model.begin_batch("编辑研究路线 %s" % key)
	_service.model.set_field(id, "research_routes", routes)
	_service.model.commit_batch()


func add_route(id: String) -> void:
	var row := _service.model.node(id)
	var routes: Array = (row.get("research_routes", []) as Array).duplicate(true)
	routes.append({
		"id": "research_route.%s.route_%d" % [id.trim_prefix("tech."), routes.size() + 1],
		"display_name": "",
		"route_type": "",
		"description": "",
		"condition": {},
	})
	_service.model.begin_batch("添加研究路线")
	_service.model.set_field(id, "research_routes", routes)
	_service.model.commit_batch()
	_refresh_inspector()


## Route evidence must be defined earlier in the node array, so the picker only
## offers technologies that already satisfy that ordering rule.
func prompt_route_condition(id: String, slot: int) -> void:
	var position := _service.model.node_position(id)
	var ids := PackedStringArray()
	var labels := PackedStringArray()
	var hard: Array = _service.model.node(id).get("hard_prerequisite_ids", [])
	for candidate in _service.model.ids():
		var candidate_id := String(candidate)
		if _service.model.node_position(candidate_id) >= position:
			continue
		if hard.has(candidate_id):
			continue
		ids.append(candidate_id)
		labels.append("%s  —  %s" % [candidate_id, technology_display_name(candidate_id)])
	_open_picker("选择路线证据科技（须先于本节点且不与硬前置重复）", ids, labels,
		func(picked: String) -> void:
			commit_route_field(id, slot, "condition",
				{"operator": 0.0, "kind": 0.0, "id": picked, "value": 1.0})
			_refresh_inspector())


func rebuild_knowledge_basis(id: String) -> void:
	var row := _service.model.node(id)
	var required: Array = (row.get("hard_prerequisite_ids", []) as Array).duplicate()
	var groups: Array = []
	for route_value in row.get("research_routes", []):
		var atoms := PackedStringArray()
		ValidatorScript.collect_technology_atoms(
			(route_value as Dictionary).get("condition", {}), atoms)
		if atoms.is_empty():
			continue
		groups.append(Array(atoms))
	var basis: Dictionary = (row.get("knowledge_basis", {}) as Dictionary).duplicate(true)
	basis["required_ids"] = required
	basis["alternative_groups"] = groups
	_service.model.begin_batch("重建知识基础")
	_service.model.set_field(id, "knowledge_basis", basis)
	_service.model.commit_batch()
	_refresh_inspector()


func commit_basis_exemption(id: String, text: String) -> void:
	var row := _service.model.node(id)
	var basis: Dictionary = (row.get("knowledge_basis", {}) as Dictionary).duplicate(true)
	basis["exemption_reason"] = text
	commit_field(id, "knowledge_basis", basis)


func commit_review_field(id: String, key: String, sub_key: String,
		value: Variant) -> void:
	var row := _service.model.node(id)
	var review: Dictionary = (row.get(key, {}) as Dictionary).duplicate(true)
	review[sub_key] = value
	commit_field(id, key, review)


# --------------------------------------------------------------------------
# Canvas interactions
# --------------------------------------------------------------------------

func _on_connect_requested(from_id: String, to_id: String) -> void:
	_open_text_input("添加硬前置", "前置科技", from_id, "理由（必填）", "",
		"%s 将成为 %s 的硬前置。理由会写入配对的 prerequisite_rationales。" % [from_id, to_id],
		"relation", {"id": to_id, "field": "hard_prerequisite_ids"})


func _on_reorder_requested(era_id: String, ordered_ids: PackedStringArray) -> void:
	_service.model.begin_batch("调整 %s 序位" % era_id)
	_service.model.reorder_layout(era_id, ordered_ids)
	_service.model.commit_batch()
	_rebake_canvas()


func _on_context_requested(id: String, screen_position: Vector2) -> void:
	_context_target = id
	_context_menu.clear()
	_context_menu.add_item("聚焦", CONTEXT_FOCUS)
	_context_menu.add_item("新建后继科技", CONTEXT_ADD_SUCCESSOR)
	_context_menu.add_item("复制为新科技", CONTEXT_DUPLICATE)
	_context_menu.add_item("设为本时代里程碑候选", CONTEXT_MILESTONE_CANDIDATE)
	_context_menu.add_item("改 ID", CONTEXT_RENAME)
	_context_menu.add_separator()
	_context_menu.add_item("删除…", CONTEXT_DELETE)
	_context_menu.position = Vector2i(screen_position)
	_context_menu.popup()


func _on_context_selected(id: int) -> void:
	match id:
		CONTEXT_FOCUS:
			select_technology(_context_target)
			_focus_technology(_context_target)
		CONTEXT_ADD_SUCCESSOR:
			_selected = _context_target
			_on_new_node_pressed()
		CONTEXT_DUPLICATE:
			_duplicate_technology(_context_target)
		CONTEXT_MILESTONE_CANDIDATE:
			_add_milestone_candidate(_context_target)
		CONTEXT_RENAME:
			_selected = _context_target
			_on_rename_pressed()
		CONTEXT_DELETE:
			_selected = _context_target
			_on_delete_pressed()


func _add_milestone_candidate(id: String) -> void:
	var row := _service.model.node(id)
	var era_id := String(row.get("era_id", ""))
	var era := _service.model.meta_row("eras", era_id)
	if era.is_empty():
		return
	var candidates: Array = (era.get("milestone_candidate_ids", []) as Array).duplicate()
	if candidates.has(id):
		_status.text = "%s 已经是 %s 的里程碑候选" % [id, era_id]
		return
	candidates.append(id)
	_service.model.begin_batch("添加里程碑候选")
	_service.model.set_meta_field("eras", era_id, "milestone_candidate_ids", candidates)
	_service.model.commit_batch()
	_status.text = "%s 已加入 %s 的里程碑候选（共 %d 个）" % [id, era_id, candidates.size()]


# --------------------------------------------------------------------------
# Structural operations
# --------------------------------------------------------------------------

func _populate_new_node_dialog() -> void:
	_fill_dialog_option(_new_era_option, _service.model.meta_array("eras"))
	_fill_dialog_option(_new_domain_option, _service.model.meta_array("domains"))
	_fill_dialog_option(_new_family_option, _service.model.meta_array("backbones")
		+ _service.model.meta_array("branch_families"))


func _fill_dialog_option(option: OptionButton, rows: Array) -> void:
	option.clear()
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		option.add_item("%s（%s）" % [String(row.get("display_name", "")),
			String(row.get("id", ""))], index)
		option.set_item_metadata(index, String(row.get("id", "")))


func _on_new_node_pressed() -> void:
	var anchor := _service.model.node(_selected)
	_new_id_edit.text = "tech."
	_new_name_edit.text = ""
	if not anchor.is_empty():
		_select_dialog_option(_new_era_option, String(anchor.get("era_id", "")))
		_select_dialog_option(_new_domain_option, String(anchor.get("domain_id", "")))
		_select_dialog_option(_new_family_option,
			String(anchor.get("branch_family_id", "")))
	_new_node_hint.text = "新节点会插入到 %s 之后，并预填全部校验必需字段。" % (
		_selected if not _selected.is_empty() else "网络末尾")
	_new_node_dialog.popup_centered()


func _select_dialog_option(option: OptionButton, id: String) -> void:
	for index in range(option.item_count):
		if String(option.get_item_metadata(index)) == id:
			option.select(index)
			return


func _dialog_option_value(option: OptionButton) -> String:
	if option.get_selected() < 0:
		return ""
	return String(option.get_item_metadata(option.get_selected()))


func _on_new_node_confirmed() -> void:
	var id := _new_id_edit.text.strip_edges()
	var reason := _service.model.validate_new_id(id)
	if not reason.is_empty():
		_show_message("无法创建", reason)
		return
	var display_name := _new_name_edit.text.strip_edges()
	if display_name.is_empty():
		_show_message("无法创建", "显示名称不能为空。")
		return
	var template := _service.model.new_node_template(id, display_name,
		_dialog_option_value(_new_era_option), _dialog_option_value(_new_domain_option),
		_dialog_option_value(_new_family_option))
	_service.model.begin_batch("新建科技 %s" % id)
	var added := _service.model.add_node(template, _selected)
	if not _selected.is_empty():
		_service.model.add_relation_entry(id, "hard_prerequisite_ids", _selected,
			"该科技需要先掌握 %s。" % _selected)
	_service.model.commit_batch()
	if not bool(added.ok):
		_show_message("无法创建", String(added.reason))
		return
	select_technology(id)
	_focus_technology(id)
	_status.text = "已创建 %s" % id


func _duplicate_technology(id: String) -> void:
	var source := _service.model.node(id)
	if source.is_empty():
		return
	var copy: Dictionary = source.duplicate(true)
	var suffix := 2
	var new_id := "%s_copy" % id
	while not _service.model.validate_new_id(new_id).is_empty():
		new_id = "%s_copy%d" % [id, suffix]
		suffix += 1
		if suffix > 64:
			return
	copy["id"] = new_id
	copy["display_name"] = "%s（副本）" % String(source.get("display_name", ""))
	copy["is_milestone"] = false
	copy["is_era_key"] = false
	copy["research_routes"] = []
	copy["route_exemption_reason"] = "副本尚未编写替代研究路线。"
	_service.model.begin_batch("复制科技 %s" % id)
	_service.model.add_node(copy, id)
	_service.model.commit_batch()
	select_technology(new_id)
	_status.text = "已复制为 %s" % new_id


func _on_rename_pressed() -> void:
	if _selected.is_empty():
		_show_message("改 ID", "请先选中一个科技。")
		return
	_open_text_input("改 ID", "新的稳定 ID", _selected, "", "",
		"改 ID 会原子重写所有引用点：硬前置、分支后继、应用目标、研究路线条件、知识基础、时代里程碑与候选、应用交汇。",
		"rename", {"id": _selected})


func _apply_rename(old_id: String, new_id: String) -> void:
	_service.model.begin_batch("改 ID %s → %s" % [old_id, new_id])
	var result := _service.model.rename_node(old_id, new_id)
	if not bool(result.ok):
		_service.model.abort_batch()
		_show_message("改 ID 失败", String(result.reason))
		return
	_service.model.commit_batch()
	select_technology(new_id)
	_status.text = "已把 %s 改名为 %s（.tres 标签需要单独同步）" % [old_id, new_id]


func _on_delete_pressed() -> void:
	if _selected.is_empty():
		_show_message("删除科技", "请先选中一个科技。")
		return
	var preview := _service.model.delete_preview(_selected)
	var blockers := _service.deletion_blockers(_selected)
	var lines := PackedStringArray(["将删除 [b]%s[/b]（%s）。" % [
		technology_display_name(_selected), _selected]])
	var references: Array = preview.references
	if references.is_empty():
		lines.append("没有其他记录引用它。")
	else:
		lines.append("以下 %d 个引用点会被自动修复：" % references.size())
		for value in references:
			var row: Dictionary = value
			lines.append("· %s %s 的 %s%s" % [String(row.owner_kind), String(row.owner_id),
				String(row.field),
				"（%s）" % String(row.label) if not String(row.label).is_empty() else ""])
	for reason in preview.blocking:
		lines.append("[color=#c94f3a]阻止：%s[/color]" % String(reason))
	for blocker_value in blockers:
		lines.append("[color=#c94f3a]阻止：%s[/color]" % String(
			(blocker_value as Dictionary).message))
	if not bool(preview.ok):
		_show_message("无法删除", "\n".join(lines))
		return
	if not blockers.is_empty():
		lines.append("")
		lines.append("确认后将先为上述建筑挑选替代解锁科技。")
		_confirm_action = "reassign_unlocks"
		_confirm_payload = {"id": _selected, "blockers": blockers}
		_confirm_text.clear()
		_confirm_text.bbcode_enabled = true
		_confirm_text.append_text("\n".join(lines))
		_confirm_dialog.popup_centered()
		return
	_confirm_action = "delete"
	_confirm_payload = {"id": _selected}
	_confirm_text.clear()
	_confirm_text.bbcode_enabled = true
	_confirm_text.append_text("\n".join(lines))
	_confirm_dialog.popup_centered()


## A building must keep exactly one primary `tech.*` unlock, so deleting its
## only unlock is offered as a reassignment rather than a dead end.
func _prompt_replacement_unlock(doomed_id: String, blockers: Array) -> void:
	open_technology_picker("为建筑挑选替代解锁科技", func(replacement: String) -> void:
		if replacement == doomed_id:
			_show_message("无法指定", "替代科技不能是即将删除的 %s。" % doomed_id)
			return
		var moved := PackedStringArray()
		for blocker_value in blockers:
			var blocker: Dictionary = blocker_value
			var result := _service.set_building_primary_technology(String(blocker.id),
				replacement)
			if not bool(result.ok):
				_show_message("改写 .tres 失败", String(result.reason))
				return
			moved.append(String(blocker.id))
		_rebuild_search_index()
		_status.text = "已把 %s 的解锁科技改为 %s，可以继续删除 %s" % [
			", ".join(moved), replacement, doomed_id]
		select_technology(doomed_id)
		_on_delete_pressed())


func _apply_delete(id: String) -> void:
	_service.model.begin_batch("删除科技 %s" % id)
	var removed := _service.model.remove_node(id)
	if not bool(removed.ok):
		_service.model.abort_batch()
		_show_message("删除失败", String(removed.reason))
		return
	_service.model.commit_batch()
	_selected = ""
	_selection = PackedStringArray()
	_inspector.clear()
	_status.text = "已删除 %s，并修复 %d 个引用点" % [id, (removed.repaired as Array).size()]


# --------------------------------------------------------------------------
# Undo, save and gates
# --------------------------------------------------------------------------

func _on_batch_committed(dirty_ids: PackedStringArray, structural: bool) -> void:
	if structural:
		_rebuild_search_index()
		_rebake_canvas()
		_rebuild_table()
		_populate_filters()
	else:
		for id in dirty_ids:
			_write_search_blob(String(id))
			var item: TreeItem = _table_items.get(String(id), null)
			if item != null:
				_write_table_row(item, _service.model.node(String(id)))
		_canvas.queue_redraw()
	_undo_button.disabled = not _service.model.can_undo()
	_redo_button.disabled = not _service.model.can_redo()
	_queue_validation()


func _on_undo_pressed() -> void:
	var dirty := _service.model.undo()
	_after_history(dirty)


func _on_redo_pressed() -> void:
	var dirty := _service.model.redo()
	_after_history(dirty)


func _after_history(dirty: PackedStringArray) -> void:
	if not dirty.is_empty():
		var id := String(dirty[0])
		if _service.model.has_technology(id):
			select_technology(id)
		else:
			_selected = ""
			_selection = PackedStringArray()
			_inspector.clear()
	_refresh_inspector()


## The committed network already carries errors, so a workbench that only ever
## saves a clean file would strand a long authoring session. Draft saves keep
## the progress and say plainly that the gate will still reject the file.
func _on_draft_save_pressed() -> void:
	var errors := ValidatorScript.error_count(_findings)
	if errors == 0:
		_on_save_pressed()
		return
	_confirm_action = "save_draft"
	_confirm_payload = {}
	_confirm_text.clear()
	_confirm_text.bbcode_enabled = true
	_confirm_text.append_text("\n".join(PackedStringArray([
		"仍有 [b]%d[/b] 条错误未修完。" % errors,
		"草稿会写入 %s（先备份为 .bak），但 CLI 闸门仍会拒绝它，不要就此提交。" % ServiceScript.NETWORK_PATH,
		"",
		ServiceScript.SAVE_WARNING,
	])))
	_confirm_dialog.popup_centered()


func _apply_draft_save() -> void:
	var result := _service.save_draft()
	if not bool(result.ok):
		_show_message("草稿保存失败", String(result.get("reason", "")))
		return
	_status.text = "已保存草稿 %s（%d 字节，仍有错误）" % [String(result.path),
		int(result.get("bytes", 0))]
	_rebake_canvas()
	_run_validation()


func _on_save_pressed() -> void:
	var result := _service.save()
	if not bool(result.ok):
		_show_message("保存被拒绝", "%s\n\n错误必须先修完；问题栏已列出全部条目。" % String(
			result.get("reason", "")))
		return
	_status.text = "已保存 %s" % String(result.path)
	_show_message("已保存", "%s\n\n%s" % [String(result.path), String(result.warning)])
	_rebake_canvas()
	_run_validation()


func _on_reload_pressed() -> void:
	if _service.model.is_dirty():
		_confirm_action = "reload"
		_confirm_payload = {}
		_confirm_text.clear()
		_confirm_text.bbcode_enabled = true
		_confirm_text.append_text("有未保存的改动，重新载入会丢弃它们。继续？")
		_confirm_dialog.popup_centered()
		return
	_load_everything()


func _on_gate_pressed() -> void:
	_status.text = "正在运行 CLI 闸门…"
	var result := _service.run_gate(true)
	_show_message("CLI 闸门（退出码 %d）" % int(result.code), String(result.output))
	_status.text = "CLI 闸门 %s" % ("通过" if bool(result.ok) else "失败")


func _on_report_pressed() -> void:
	var result := _service.export_report()
	_show_message("导出报告（退出码 %d）" % int(result.code), String(result.output))


# --------------------------------------------------------------------------
# Meta editors
# --------------------------------------------------------------------------

func _open_meta_dialog(mode: String) -> void:
	_meta_mode = mode
	_rebuild_meta_tree()
	_meta_hint.text = "直接编辑「值」列。数组按顿号或逗号分隔；时代的候选需 8–18 个、candidate_required 需 4–7。" \
		if mode == "eras" else "直接编辑「值」列。应用交汇的 required_technology_ids 至少 2 个已存在的科技。"
	_meta_dialog.get_ok_button().text = "关闭"
	_meta_dialog.title = "时代与里程碑" if mode == "eras" else "分支族与应用交汇"
	_meta_dialog.popup_centered()


func _rebuild_meta_tree() -> void:
	_meta_tree.clear()
	_meta_tree.columns = 4
	_meta_tree.column_titles_visible = true
	_meta_tree.set_column_title(0, "记录")
	_meta_tree.set_column_title(1, "字段")
	_meta_tree.set_column_title(2, "值")
	_meta_tree.set_column_title(3, "说明")
	_meta_tree.set_column_custom_minimum_width(0, 200)
	_meta_tree.set_column_custom_minimum_width(1, 200)
	_meta_tree.set_column_expand(2, true)
	var root := _meta_tree.create_item()
	if _meta_mode == "eras":
		_meta_section("eras", ["display_name", "milestone_id", "entry_milestone_id",
			"candidate_required", "milestone_candidate_ids"], root)
		return
	_meta_section("backbones", ["display_name"], root)
	_meta_section("branch_families", ["display_name"], root)
	_meta_section("application_intersections", ["display_name", "era_id", "domain_id",
		"branch_family_id", "layout_lane", "required_technology_ids", "building_ids"], root)


func _meta_section(key: String, fields: Array, root: TreeItem) -> void:
	var header := _meta_tree.create_item(root)
	header.set_text(0, "%s（%d）" % [key, _service.model.meta_array(key).size()])
	header.set_selectable(0, false)
	header.set_collapsed(key == "application_intersections")
	for row_value in _service.model.meta_array(key):
		var row: Dictionary = row_value
		var id := String(row.get("id", ""))
		var item := _meta_tree.create_item(header)
		item.set_text(0, id)
		item.set_selectable(0, false)
		item.set_collapsed(true)
		for field_value in fields:
			var field := String(field_value)
			if not row.has(field):
				continue
			var child := _meta_tree.create_item(item)
			child.set_text(0, id)
			child.set_text(1, field)
			child.set_text(2, _meta_display(row[field]))
			child.set_editable(2, true)
			child.set_metadata(2, {"key": key, "id": id, "field": field,
				"array": row[field] is Array})
			if field == "milestone_candidate_ids":
				var count := (row[field] as Array).size()
				child.set_text(3, "%d 个候选，必须在 8–18 之间" % count)
				if count < 8 or count > 18:
					child.set_custom_color(3, UITokens.RISK)
			elif field == "candidate_required":
				child.set_text(3, "必须在 4–7 之间")
				var required := int(row[field])
				if required < 4 or required > 7:
					child.set_custom_color(3, UITokens.RISK)
			elif field == "entry_milestone_id":
				child.set_text(3, "由上一时代 milestone_id 自动维护")
				child.set_editable(2, false)
		_meta_tree.create_item(item)


func _meta_display(value: Variant) -> String:
	if value is Array:
		var parts := PackedStringArray()
		for item in value as Array:
			parts.append(String(item))
		return ", ".join(parts)
	if value is float:
		return str(int(value)) if is_equal_approx(value, floorf(value)) else str(value)
	return String(value)


func _on_meta_edited() -> void:
	var item := _meta_tree.get_edited()
	if item == null:
		return
	var metadata: Variant = item.get_metadata(2)
	if not metadata is Dictionary:
		return
	var info: Dictionary = metadata
	var text := item.get_text(2)
	var value: Variant = text
	if bool(info.array):
		var out: Array = []
		for token in text.replace("、", ",").split(","):
			var trimmed := String(token).strip_edges()
			if not trimmed.is_empty():
				out.append(trimmed)
		value = out
	elif text.is_valid_float():
		value = float(text)
	_service.model.begin_batch("编辑 %s.%s" % [String(info.key), String(info.field)])
	_service.model.set_meta_field(String(info.key), String(info.id),
		String(info.field), value)
	if String(info.field) == "milestone_id":
		_service.model.repair_era_entry_chain()
	_service.model.commit_batch()
	_rebuild_meta_tree()


# --------------------------------------------------------------------------
# Dialog plumbing
# --------------------------------------------------------------------------

func _show_message(title: String, body: String) -> void:
	_message_dialog.title = title
	_message_text.clear()
	_message_text.bbcode_enabled = true
	_message_text.append_text(body)
	_message_dialog.popup_centered()


func _on_confirm_accepted() -> void:
	match _confirm_action:
		"delete": _apply_delete(String(_confirm_payload.id))
		"reload": _load_everything()
		"reassign_unlocks": _prompt_replacement_unlock(String(_confirm_payload.id),
			_confirm_payload.blockers as Array)
		"save_draft": _apply_draft_save()
	_confirm_action = ""
	_confirm_payload = {}


func _open_text_input(title: String, primary_label: String, primary: String,
		secondary_label: String, secondary: String, hint: String,
		action: String, payload: Dictionary) -> void:
	_text_input_action = action
	_text_input_payload = payload
	_text_dialog.title = title
	_primary_label.text = primary_label
	_primary_edit.text = primary
	_secondary_label.text = secondary_label
	_secondary_edit.text = secondary
	var secondary_visible := not secondary_label.is_empty()
	_secondary_edit.visible = secondary_visible
	_secondary_label.visible = secondary_visible
	_hint_label.text = hint
	_text_dialog.popup_centered()


func _on_text_input_accepted() -> void:
	var primary := _primary_edit.text.strip_edges()
	var secondary := _secondary_edit.text.strip_edges()
	match _text_input_action:
		"relation":
			if secondary.is_empty():
				_show_message("需要理由", "配对的理由数组不能为空，闸门会拒绝。")
				return
			_apply_relation_entry(_text_input_payload, primary, secondary)
		"rename":
			_apply_rename(String(_text_input_payload.id), primary)
	_text_input_action = ""
	_text_input_payload = {}


func _open_picker(title: String, options: PackedStringArray,
		labels: PackedStringArray, callback: Callable) -> void:
	_picker_options = options
	_picker_labels = labels
	_picker_callback = callback
	_picker_title.text = title
	_picker_query.text = ""
	_refresh_picker()
	_picker_popup.popup_centered(Vector2i(560, 460))
	_picker_query.grab_focus()


func _refresh_picker() -> void:
	var needle := _picker_query.text.strip_edges().to_lower()
	_picker_list.clear()
	for index in range(_picker_options.size()):
		var id := String(_picker_options[index])
		var label := String(_picker_labels[index]) if index < _picker_labels.size() else id
		if not needle.is_empty() and not label.to_lower().contains(needle) \
				and not id.to_lower().contains(needle):
			continue
		_picker_list.add_item(label)
		_picker_list.set_item_metadata(_picker_list.item_count - 1, id)
		if _picker_list.item_count >= 400:
			break


func _on_picker_activated(index: int) -> void:
	var id := String(_picker_list.get_item_metadata(index))
	_picker_popup.hide()
	if _picker_callback.is_valid():
		_picker_callback.call(id)
	_picker_callback = Callable()
