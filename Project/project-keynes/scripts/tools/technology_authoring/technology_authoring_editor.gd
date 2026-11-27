class_name TechnologyAuthoringEditor
extends Control

const EditorSearch = preload("res://scripts/tools/technology_authoring/technology_authoring_editor_search.gd")
const EditorValidation = preload("res://scripts/tools/technology_authoring/technology_authoring_editor_validation.gd")
const EditorInspectorEdits = preload("res://scripts/tools/technology_authoring/technology_authoring_editor_inspector_edits.gd")
const EditorGraphEdits = preload("res://scripts/tools/technology_authoring/technology_authoring_editor_graph_edits.gd")
const EditorCatalogActions = preload("res://scripts/tools/technology_authoring/technology_authoring_editor_catalog_actions.gd")
const EditorDialogs = preload("res://scripts/tools/technology_authoring/technology_authoring_editor_dialogs.gd")

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
	EditorSearch._populate_filters(self)

func _fill_option(option: OptionButton, rows: Array) -> void:
	EditorSearch._fill_option(self, option, rows)

func _selected_filter(option: OptionButton) -> String:
	return EditorSearch._selected_filter(self, option)

func _apply_filters() -> void:
	EditorSearch._apply_filters(self)

func _matches_text(id: String, needle: String) -> bool:
	return EditorSearch._matches_text(self, id, needle)

func _rebuild_search_index() -> void:
	EditorSearch._rebuild_search_index(self)

func _write_search_blob(id: String) -> void:
	EditorSearch._write_search_blob(self, id)

func _rebuild_outline() -> void:
	EditorSearch._rebuild_outline(self)

func _rebuild_table() -> void:
	EditorSearch._rebuild_table(self)

func _write_table_row(item: TreeItem, row: Dictionary) -> void:
	EditorSearch._write_table_row(self, item, row)

func _refresh_table_visibility() -> void:
	EditorSearch._refresh_table_visibility(self)


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
	EditorValidation._queue_validation(self)

func _run_validation() -> void:
	EditorValidation._run_validation(self)

func _rebuild_problems(msec: float) -> void:
	EditorValidation._rebuild_problems(self, msec)


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
	EditorValidation._on_copy_problems(self)


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
	return EditorInspectorEdits.technology_row(self, id)

func technology_display_name(id: String) -> String:
	return EditorInspectorEdits.technology_display_name(self, id)

func enum_source(source: String) -> PackedStringArray:
	return EditorInspectorEdits.enum_source(self, source)

func distinct_values(key: String) -> PackedStringArray:
	return EditorInspectorEdits.distinct_values(self, key)

func distinct_term_values(key: String) -> PackedStringArray:
	return EditorInspectorEdits.distinct_term_values(self, key)

func commit_field(id: String, key: String, value: Variant) -> void:
	EditorInspectorEdits.commit_field(self, id, key, value)

func relation_entries(id: String, field: String) -> Array:
	return EditorInspectorEdits.relation_entries(self, id, field)

func commit_relation_rationale(id: String, field: String, slot: int,
		text: String) -> void:
	EditorInspectorEdits.commit_relation_rationale(self, id, field, slot, text)

func remove_relation_entry(id: String, field: String, target_id: String) -> void:
	EditorInspectorEdits.remove_relation_entry(self, id, field, target_id)

func prompt_relation_entry(id: String, field: String, label: String) -> void:
	EditorInspectorEdits.prompt_relation_entry(self, id, field, label)

func _apply_relation_entry(payload: Dictionary, target_id: String,
		rationale: String) -> void:
	EditorInspectorEdits._apply_relation_entry(self, payload, target_id, rationale)

func open_value_picker(title: String, key: String, callback: Callable) -> void:
	EditorInspectorEdits.open_value_picker(self, title, key, callback)

func open_term_value_picker(key: String, callback: Callable) -> void:
	EditorInspectorEdits.open_term_value_picker(self, key, callback)

func open_stat_picker(callback: Callable) -> void:
	EditorInspectorEdits.open_stat_picker(self, callback)

func open_technology_picker(title: String, callback: Callable) -> void:
	EditorInspectorEdits.open_technology_picker(self, title, callback)

func stat_hint(stat: String) -> String:
	return EditorInspectorEdits.stat_hint(self, stat)

func term_subject_label(term: Dictionary) -> String:
	return EditorInspectorEdits.term_subject_label(self, term)

func commit_term_field(id: String, slot: int, key: String, value: Variant) -> void:
	EditorInspectorEdits.commit_term_field(self, id, slot, key, value)

func add_term(id: String) -> void:
	EditorInspectorEdits.add_term(self, id)

func remove_term(id: String, slot: int) -> void:
	EditorInspectorEdits.remove_term(self, id, slot)

func remove_array_entry(id: String, key: String, slot: int) -> void:
	EditorInspectorEdits.remove_array_entry(self, id, key, slot)

func content_exists(kind: String, id: String) -> bool:
	return EditorInspectorEdits.content_exists(self, kind, id)

func unlock_reconciliation(id: String) -> Dictionary:
	return EditorInspectorEdits.unlock_reconciliation(self, id)

func sync_unlock_to_tres(id: String, kind: String, content_id: String) -> void:
	EditorInspectorEdits.sync_unlock_to_tres(self, id, kind, content_id)

func adopt_unlock_from_tres(id: String, kind: String, content_id: String,
		display_name: String) -> void:
	EditorInspectorEdits.adopt_unlock_from_tres(self, id, kind, content_id, display_name)

func prompt_content_effect(id: String) -> void:
	EditorInspectorEdits.prompt_content_effect(self, id)

func _prompt_content_id(id: String, kind: String) -> void:
	EditorInspectorEdits._prompt_content_id(self, id, kind)

func sync_expected_bindings(id: String) -> void:
	EditorInspectorEdits.sync_expected_bindings(self, id)

func prompt_support_building(id: String) -> void:
	EditorInspectorEdits.prompt_support_building(self, id)

func commit_route_field(id: String, slot: int, key: String, value: Variant) -> void:
	EditorInspectorEdits.commit_route_field(self, id, slot, key, value)

func add_route(id: String) -> void:
	EditorInspectorEdits.add_route(self, id)

func prompt_route_condition(id: String, slot: int) -> void:
	EditorInspectorEdits.prompt_route_condition(self, id, slot)

func rebuild_knowledge_basis(id: String) -> void:
	EditorInspectorEdits.rebuild_knowledge_basis(self, id)

func commit_basis_exemption(id: String, text: String) -> void:
	EditorInspectorEdits.commit_basis_exemption(self, id, text)

func commit_review_field(id: String, key: String, sub_key: String,
		value: Variant) -> void:
	EditorInspectorEdits.commit_review_field(self, id, key, sub_key, value)


func _on_connect_requested(from_id: String, to_id: String) -> void:
	EditorGraphEdits._on_connect_requested(self, from_id, to_id)

func _on_reorder_requested(era_id: String, ordered_ids: PackedStringArray) -> void:
	EditorGraphEdits._on_reorder_requested(self, era_id, ordered_ids)

func _on_context_requested(id: String, screen_position: Vector2) -> void:
	EditorGraphEdits._on_context_requested(self, id, screen_position)

func _on_context_selected(id: int) -> void:
	EditorGraphEdits._on_context_selected(self, id)

func _add_milestone_candidate(id: String) -> void:
	EditorGraphEdits._add_milestone_candidate(self, id)

func _populate_new_node_dialog() -> void:
	EditorGraphEdits._populate_new_node_dialog(self)

func _fill_dialog_option(option: OptionButton, rows: Array) -> void:
	EditorGraphEdits._fill_dialog_option(self, option, rows)

func _on_new_node_pressed() -> void:
	EditorGraphEdits._on_new_node_pressed(self)

func _select_dialog_option(option: OptionButton, id: String) -> void:
	EditorGraphEdits._select_dialog_option(self, option, id)

func _dialog_option_value(option: OptionButton) -> String:
	return EditorGraphEdits._dialog_option_value(self, option)

func _on_new_node_confirmed() -> void:
	EditorGraphEdits._on_new_node_confirmed(self)

func _duplicate_technology(id: String) -> void:
	EditorGraphEdits._duplicate_technology(self, id)

func _on_rename_pressed() -> void:
	EditorGraphEdits._on_rename_pressed(self)

func _apply_rename(old_id: String, new_id: String) -> void:
	EditorGraphEdits._apply_rename(self, old_id, new_id)

func _on_delete_pressed() -> void:
	EditorGraphEdits._on_delete_pressed(self)

func _prompt_replacement_unlock(doomed_id: String, blockers: Array) -> void:
	EditorGraphEdits._prompt_replacement_unlock(self, doomed_id, blockers)

func _apply_delete(id: String) -> void:
	EditorGraphEdits._apply_delete(self, id)


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
	EditorCatalogActions._on_draft_save_pressed(self)

func _apply_draft_save() -> void:
	EditorCatalogActions._apply_draft_save(self)

func _on_save_pressed() -> void:
	EditorCatalogActions._on_save_pressed(self)

func _on_reload_pressed() -> void:
	EditorCatalogActions._on_reload_pressed(self)

func _on_gate_pressed() -> void:
	EditorCatalogActions._on_gate_pressed(self)

func _on_report_pressed() -> void:
	EditorCatalogActions._on_report_pressed(self)

func _open_meta_dialog(mode: String) -> void:
	EditorCatalogActions._open_meta_dialog(self, mode)

func _rebuild_meta_tree() -> void:
	EditorCatalogActions._rebuild_meta_tree(self)

func _meta_section(key: String, fields: Array, root: TreeItem) -> void:
	EditorCatalogActions._meta_section(self, key, fields, root)

func _meta_display(value: Variant) -> String:
	return EditorCatalogActions._meta_display(self, value)

func _on_meta_edited() -> void:
	EditorCatalogActions._on_meta_edited(self)


func _show_message(title: String, body: String) -> void:
	EditorDialogs._show_message(self, title, body)

func _on_confirm_accepted() -> void:
	EditorDialogs._on_confirm_accepted(self)

func _open_text_input(title: String, primary_label: String, primary: String,
		secondary_label: String, secondary: String, hint: String,
		action: String, payload: Dictionary) -> void:
	EditorDialogs._open_text_input(self, title, primary_label, primary, secondary_label, secondary, hint, action, payload)

func _on_text_input_accepted() -> void:
	EditorDialogs._on_text_input_accepted(self)

func _open_picker(title: String, options: PackedStringArray,
		labels: PackedStringArray, callback: Callable) -> void:
	EditorDialogs._open_picker(self, title, options, labels, callback)

func _refresh_picker() -> void:
	EditorDialogs._refresh_picker(self)

func _on_picker_activated(index: int) -> void:
	EditorDialogs._on_picker_activated(self, index)
