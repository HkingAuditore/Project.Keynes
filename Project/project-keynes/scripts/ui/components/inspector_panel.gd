class_name InspectorPanel
extends PanelContainer

const DetailWorkspaces = preload("res://scripts/ui/components/inspector_details.gd")

const TaxPanel = preload("res://scripts/ui/components/inspector_tax.gd")

const CategoryContent = preload("res://scripts/ui/components/inspector_categories.gd")

const LivePresentation = preload("res://scripts/ui/components/inspector_live_presentation.gd")

const SceneBindings = preload("res://scripts/ui/components/inspector_scene_bindings.gd")
const InspectorTaxDrafts = preload("res://scripts/ui/components/inspector_tax_drafts.gd")

const InspectorStructure = preload("res://scripts/ui/components/inspector_structure.gd")
const InspectorCategoryPatch = preload("res://scripts/ui/components/inspector_category_patch.gd")


const ResourceListScene := preload("res://scenes/ui/resource_list.tscn")
const FamilyListScene := preload("res://scenes/ui/family_list.tscn")
const MarketListScene := preload("res://scenes/ui/market_list.tscn")
const CohortListScene := preload("res://scenes/ui/cohort_list.tscn")
const BuildingListScene := preload("res://scenes/ui/building_list.tscn")
const InspectorTaxGroups := preload("res://scripts/ui/components/inspector_tax_groups.gd")
const ConstructionEntryScene := preload("res://scenes/ui/construction_entry.tscn")
const BadgeRowScene := preload("res://scenes/ui/badge_row.tscn")
const FactGridScene := preload("res://scenes/ui/inspector_fact_grid.tscn")
const MeterListScene := preload("res://scenes/ui/inspector_meter_list.tscn")
const NoteListScene := preload("res://scenes/ui/inspector_note_list.tscn")
const ColumnHeaderScene := preload("res://scenes/ui/inspector_column_header.tscn")
const CollapsibleSectionScene := preload("res://scenes/ui/inspector_collapsible_section.tscn")
const TaxSectionScene := preload("res://scenes/ui/object_tax_section.tscn")
const TaxLaneScene := preload("res://scenes/ui/object_tax_lane.tscn")
const ActionButtonScene := preload("res://scenes/ui/object_action_button.tscn")
const MilitaryCellLedgerScene := preload("res://scenes/ui/military_cell_ledger.tscn")

const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
## 「全部」分组轴：取国家税快照自己那份 item 列表（命令层校验的也是这份）。
const TAX_GROUP_ALL_MODE := "all_items"
## 整组调税一次能提交多少条：内核 host 队列单批上限 256
## （gdext/src/runtime_pod_protocol.h:1350；检查在
## gdext/src/world_ext_country_commands.cpp:76-87），超出整批被拒。
const TAX_GROUP_BATCH_LIMIT := 256
const SPLIT_DETAIL_MIN_WIDTH := 800.0
## 档案列低于此高度时 KPI 条改为单行，给正文多留约 34px。
const DENSE_KPI_MAX_HEIGHT := 500.0
## 标题字号区间：地名越长越降，最低 18px；不靠省略号截断。
const TITLE_FONT_BASE := 34
const TITLE_FONT_MIN := 18
const ROW_LIST_KEYS = InspectorStructure.ROW_LIST_KEYS

signal close_requested()
signal population_discontent_changed(cell_index: int, discontent: Dictionary)
signal tab_data_requested(tab_id: String)
signal object_details_requested(request: Dictionary)
signal detail_visibility_changed(open: bool)
signal list_wing_visibility_changed(open: bool)
signal family_colonization_requested(family_handle: int, source_cell: int)
signal construction_page_requested(sector: String, search: String, sort: String, offset: int)
signal construction_requested(request: Dictionary)
## 折叠卡展开/收起：交给宿主切换视图模型的展开状态并重算本页。
signal construction_fold_action_requested(action: Dictionary)
signal colonization_requested(request: Dictionary)
signal trade_orders_page_requested(offset: int)
signal trade_order_locate_requested(cell_idx: int)
## 军事页签的官营建筑请求：{cell, role, op, building}。接收方（GameUIManager）翻成正式命令。
signal military_state_building_requested(request: Dictionary)
signal military_army_create_requested(request: Dictionary)
## 军事页签里点了一支部队：接收方按 handle 打开军务档案。
signal military_army_selected(handle: int)
## 军务档案（部队 / 战线页）的动作与换页请求。接收方是 GameUIManager。
signal military_dossier_action_requested(action: StringName, payload: Dictionary)
signal military_dossier_army_selected(handle: int)

var _model: Dictionary = {}
var _presented_population_discontent: Dictionary = {}
var _current_tab := "geography"
var _tabs_signature_cache := ""
var _cell_index := -1
var _scroll_by_tab: Dictionary = {}
var _list_scroll_by_tab: Dictionary = {}
var _compact_detail := false
var _list_wing_enabled := false
var _has_list_wing := false
var _list_wing_notified := false

var _kicker_label: Label
var _title_label: Label
var _subtitle_label: Label
var _titles_box: Control
var _summary_band: Control
var _kpi_cards: Array = []
var _chapter_nav: DossierChapterNav
var _scroll: ScrollContainer
var _content_box: VBoxContainer
var _list_shell: PanelContainer
var _list_scroll: ScrollContainer
var _list_content: VBoxContainer
var _inspector_root: VBoxContainer
var _detail_shell: PanelContainer
var _object_detail_dialog: ObjectDetailDialog
var _family_workspace: FamilyWorkspace
var _military_dossier: MilitaryDossier
## 没有选中地块时（只开着军务档案），目录列必须收起，否则会露出空档案。
var _directory_available := true
var _construction_workspace: BuildingWorkspace
var _construction_entry_hint: Label
var _construction_feedback := ""
var _construction_ok := true
var _reset_tax_button: Button
var _tax_reset_request: Dictionary = {}
var _clear_tax_confirmation: ConfirmationDialog

## 以下控件表都按“块 id”（根块为 "_root"，其余为 section id）索引，
## 每日补丁按 id 改值，不增删节点。
var _note_controls: Dictionary = {}
var _metric_controls: Dictionary = {}
var _gauge_controls: Dictionary = {}
var _list_caption_controls: Dictionary = {}
var _section_refs: Dictionary = {}
var _chart_controls: Dictionary = {}
var _badge_row: BadgeRow
## 军事页的撕纸台账（一张纸承载驻军/部队/训练/三行官营建筑）。
var _military_ledger
var _resource_list: ResourceList
var _cohort_list
var _building_list
var _market_list
var _family_list
var _kpi_values: Dictionary = {}
var _player_controller = null
var _colonization_button: Button
var _tax_context: Dictionary = {}
## 页尾税务节所属地块：给「全部」分组轴查国家税快照用。
var _tax_page_cell := -1
var _tax_editors: Dictionary = {}
var _page_tax_editors: Array = []
var _page_tax_lane_summaries: Dictionary = {}
var _page_tax_section: Control = null
var _pending_tax: Dictionary = {}
var _draft_tax: Dictionary = {}
var _deferred_object_detail_payload: Dictionary = {}
var _construction_model: Dictionary = {}
var _detail_change_notify := true
var _section_collapsed: Dictionary = {}
var _family_chrome_active := false
var _empty_panel_style := StyleBoxEmpty.new()
var _content_structure := ""


func _ready() -> void:
	if _content_box != null:
		return
	var close_button := SceneBindings.bind(self)
	if close_button == null:
		return
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(func() -> void:
		if family_workspace_open():
			close_detail(false)
			close_requested.emit()
		elif detail_open():
			close_detail()
		else:
			close_requested.emit())
	_colonization_button.pressed.connect(func() -> void:
		colonization_requested.emit(_model.get("colonization_action", {})))
	_clear_tax_confirmation.confirmed.connect(_on_category_tax_reset_confirmed)
	_object_detail_dialog.set_embedded(true)
	# 「整组设为」的能力宿主是本面板：tax_group_axes / tax_group_ids_for /
	# request_tax_group_override 都在这里。dialog 里那个 host 只负责挂载父节点。
	_object_detail_dialog.set_tax_group_host(self)
	_object_detail_dialog.closed.connect(_on_detail_closed)
	_object_detail_dialog.colonization_requested.connect(
		func(family_handle: int, source_cell: int) -> void:
			family_colonization_requested.emit(family_handle, source_cell))
	_object_detail_dialog.tax_override_requested.connect(_on_tax_override_requested)
	_object_detail_dialog.tax_reset_requested.connect(_on_tax_reset_requested)
	_object_detail_dialog.tax_editing_finished.connect(
		_on_object_tax_editing_finished)
	_object_detail_dialog.trade_orders_page_requested.connect(
		func(offset: int) -> void: trade_orders_page_requested.emit(offset))
	_object_detail_dialog.trade_order_locate_requested.connect(
		func(cell_idx: int) -> void: trade_order_locate_requested.emit(cell_idx))
	_family_workspace.closed.connect(_on_detail_closed)
	_family_workspace.colonization_requested.connect(
		func(family_handle: int, source_cell: int) -> void:
			family_colonization_requested.emit(family_handle, source_cell))
	if _military_dossier != null:
		_military_dossier.closed.connect(_on_detail_closed)
		_military_dossier.action_requested.connect(
			func(action: StringName, payload: Dictionary) -> void:
				military_dossier_action_requested.emit(action, payload))
		_military_dossier.army_selected.connect(
			func(handle: int) -> void: military_dossier_army_selected.emit(handle))
	_construction_workspace.closed.connect(func() -> void: close_detail())
	_construction_workspace.page_requested.connect(
		func(sector: String, search: String, sort: String, offset: int) -> void:
			construction_page_requested.emit(sector, search, sort, offset))
	_construction_workspace.build_requested.connect(
		func(request: Dictionary) -> void: construction_requested.emit(request))
	_construction_workspace.fold_action_requested.connect(
		func(action: Dictionary) -> void: construction_fold_action_requested.emit(action))
	(_kpi_cards[_kpi_cards.size() - 1] as DossierKpiCard).show_divider = false
	_chapter_nav.custom_minimum_size = Vector2(0.0, DossierChapterNav.HEIGHT)
	_chapter_nav.chapter_selected.connect(_on_tab_selected)
	resized.connect(_on_inspector_resized)
	_inspector_root.resized.connect(_sync_kpi_density)
	_inspector_root.visibility_changed.connect(_emit_population_discontent)
	_title_label.resized.connect(_fit_title_font)
	_sync_split_layout()


func set_model(model: Dictionary, _rebuild_visible: bool = true) -> void:
	LivePresentation.set_model(self, model, _rebuild_visible)


func set_player_controller(controller) -> void:
	LivePresentation.set_player_controller(self, controller)


func set_model_for_selection(model: Dictionary) -> void:
	LivePresentation.set_model_for_selection(self, model)


func apply_live_patch(patch: Dictionary) -> void:
	LivePresentation.apply_live_patch(self, patch)


func apply_published_gdp(gdp_kpi: Dictionary) -> void:
	LivePresentation.apply_published_gdp(self, gdp_kpi)


func set_tab_category(tab_id: String, category: Dictionary) -> void:
	LivePresentation.set_tab_category(self, tab_id, category)


func current_tab() -> String:
	return _current_tab


func select_tab(tab_id: String) -> void:
	if tab_id == _current_tab or not _has_tab(_model.get("tabs", []), tab_id):
		return
	_on_tab_selected(tab_id)


func reset_for_world() -> void:
	LivePresentation.reset_for_world(self)


func visible_node_count() -> int:
	return _count_nodes(self)


func _apply_header(header: Dictionary, _live_patch: bool) -> void:
	LivePresentation._apply_header(self, header, _live_patch)


func _fit_title_font() -> void:
	LivePresentation._fit_title_font(self)


func _apply_kpis(kpis: Array, live_patch: bool) -> void:
	LivePresentation._apply_kpis(self, kpis, live_patch)


func _apply_colonization_action(action: Dictionary) -> void:
	LivePresentation._apply_colonization_action(self, action)


func _sync_kpi_density() -> void:
	LivePresentation._sync_kpi_density(self)


func _clear_block_controls() -> void:
	_note_controls.clear()
	_metric_controls.clear()
	_gauge_controls.clear()
	_list_caption_controls.clear()
	_section_refs.clear()
	_chart_controls.clear()
	_badge_row = null
	_military_ledger = null
	_resource_list = null
	_cohort_list = null
	_building_list = null
	_market_list = null
	_family_list = null


func _render_content(reset_scroll: bool) -> void:
	LivePresentation._render_content(self, reset_scroll)


func _publish_population_discontent(category: Dictionary) -> void:
	LivePresentation._publish_population_discontent(self, category)


func _emit_population_discontent() -> void:
	LivePresentation._emit_population_discontent(self)


func _capture_tax_drafts() -> void:
	InspectorTaxDrafts._capture_tax_drafts(_draft_tax, _tax_editors, _pending_tax)


func _restore_tax_drafts() -> void:
	InspectorTaxDrafts._restore_tax_drafts(_draft_tax, _tax_editors, _pending_tax)


func _build_category_content(data: Dictionary) -> void:
	CategoryContent._build_category_content(self, data)


func _build_category_block(host: Control, data: Dictionary) -> void:
	CategoryContent._build_category_block(self, host, data)


## 军事页台账：节点树只在这里建一次（三个建筑行由组件自己在 _ready 建好），
## 之后的每日补丁只调 set_model 写值。
func _build_military_ledger(host: Control, model: Dictionary) -> void:
	if MilitaryCellLedgerScene == null:
		return
	var ledger := MilitaryCellLedgerScene.instantiate()
	host.add_child(ledger)
	ledger.set_preview_boundary(self)
	ledger.action_requested.connect(func(request: Dictionary) -> void:
		military_state_building_requested.emit(request))
	ledger.army_create_requested.connect(func(request: Dictionary) -> void:
		military_army_create_requested.emit(request))
	ledger.army_selected.connect(func(handle: int) -> void:
		military_army_selected.emit(handle))
	ledger.set_model(model)
	_military_ledger = ledger


func _build_row_list(host: Control, data: Dictionary, row_key: String,
		block_id: String) -> void:
	var rows: Array = data.get(row_key, [])
	var header_spec: Dictionary = data.get("list_header", {})
	if not header_spec.is_empty() and not rows.is_empty():
		var header := ColumnHeaderScene.instantiate() as InspectorColumnHeader
		header.lead_indent = float(header_spec.get("indent", header.lead_indent))
		header.set_columns(String(header_spec.get("lead", "")),
			header_spec.get("columns", []))
		host.add_child(header)
	var list: Control
	match row_key:
		"family_rows":
			_family_list = FamilyListScene.instantiate()
			_family_list.dispatch_requested.connect(func(family_handle: int, source_cell: int) -> void:
				family_colonization_requested.emit(family_handle, source_cell))
			list = _family_list
		"cohort_rows":
			_cohort_list = CohortListScene.instantiate() as CohortList
			list = _cohort_list
		"resource_rows":
			_resource_list = ResourceListScene.instantiate() as ResourceList
			list = _resource_list
		"market_rows":
			_market_list = MarketListScene.instantiate()
			list = _market_list
		"building_rows":
			_building_list = BuildingListScene.instantiate() as BuildingList
			list = _building_list
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.connect(&"details_requested", _request_object_detail)
	list.call(&"set_rows", rows)
	host.add_child(list)
	if data.has("list_caption"):
		var caption := NoteListScene.instantiate() as InspectorNoteList
		host.add_child(caption)
		_set_list_caption(caption, String(data.get("list_caption", "")))
		_list_caption_controls[block_id] = caption


func _set_list_caption(caption: InspectorNoteList, text: String) -> void:
	CategoryContent._set_list_caption(self, caption, text)


func _build_page_tax_section(context: Dictionary) -> void:
	TaxPanel._build_page_tax_section(self, context)


func _add_page_tax_lane(parent: VBoxContainer, lane: Dictionary) -> void:
	TaxPanel._add_page_tax_lane(self, parent, lane)


## 一个税种一个可折叠子节：节头给出该税种当前税率，展开才是可编辑的那一行。
## 折叠状态按「页签 + page_tax + 税种」记，和其他节的 _section_collapsed 同源。
func _add_page_tax_lane_subsection(parent: VBoxContainer, lane: Dictionary) -> void:
	var kind := String(lane.get("kind", ""))
	var key := "%s:page_tax:%s" % [_current_tab, kind]
	var collapsed := bool(_section_collapsed.get(key, true))
	_section_collapsed[key] = collapsed
	var root := CollapsibleSectionScene.instantiate() as VBoxContainer
	parent.add_child(root)
	var header := root.get_node("Header") as Button
	var chevron := root.get_node("Header/Row/Chevron") as IconBadge
	var icon := root.get_node("Header/Row/Icon") as IconBadge
	var label := root.get_node("Header/Row/Label") as Label
	var summary := root.get_node("Header/Row/Summary") as Label
	var body := root.get_node("Body") as VBoxContainer
	var caption := body.get_node_or_null("Caption") as Label
	if caption != null:
		caption.visible = false
	icon.set_semantic(_tax_lane_icon(kind), UITokens.BRASS_HIGHLIGHT)
	label.text = String(lane.get("kind_label", "")).trim_prefix("此地")
	summary.text = TaxLaneEditor._format_value(int(lane.get("base", 0)),
		int(lane.get("mode", 0)))
	summary.visible = not summary.text.is_empty()
	_page_tax_lane_summaries[kind] = summary
	header.set_pressed_no_signal(not collapsed)
	_apply_section_chevron(chevron, collapsed)
	body.visible = not collapsed
	header.toggled.connect(func(expanded: bool) -> void:
		_section_collapsed[key] = not expanded
		_apply_section_chevron(chevron, not expanded)
		body.visible = expanded
	)
	_add_page_tax_lane(body, lane)


func _tax_lane_icon(kind: String) -> StringName:
	return TaxPanel._tax_lane_icon(self, kind)


func _page_tax_title(tab_id: String) -> String:
	return TaxPanel._page_tax_title(self, tab_id)


func _tax_summary(lanes: Array) -> String:
	return TaxPanel._tax_summary(self, lanes)


func _restore_lane_pending(editor: TaxLaneEditor, lane: Dictionary) -> void:
	TaxPanel._restore_lane_pending(self, editor, lane)


func _rebuild_tax_editor_registry() -> void:
	TaxPanel._rebuild_tax_editor_registry(self)


func _sync_page_tax_visibility() -> void:
	TaxPanel._sync_page_tax_visibility(self)


func _apply_page_tax_patch(context: Dictionary) -> void:
	TaxPanel._apply_page_tax_patch(self, context)


func _register_tax_editors(editors: Array) -> void:
	TaxPanel._register_tax_editors(self, editors)


func _register_tax_editor(editor: TaxLaneEditor) -> void:
	TaxPanel._register_tax_editor(self, editor)


func tax_group_axes(subject: String = "building") -> Array:
	return TaxPanel.tax_group_axes(self, subject)


func tax_group_ids_for(mode: String, item_id: String,
		subject: String = "building") -> Dictionary:
	return TaxPanel.tax_group_ids_for(self, mode, item_id, subject)


func request_tax_group_override(kind: int, item_ids: PackedStringArray,
		rate_basis_points: int, assessment_mode: int = 0) -> Dictionary:
	return TaxPanel.request_tax_group_override(self, kind, item_ids, rate_basis_points, assessment_mode)


func _on_tax_override_requested(
		scope: String,
		kind: String,
		item_id: String,
		rate: int,
		mode: int = 0
) -> void:
	TaxPanel._on_tax_override_requested(self, scope, kind, item_id, rate, mode)


func _on_tax_reset_requested(scope: String, kind: String, item_id: String) -> void:
	TaxPanel._on_tax_reset_requested(self, scope, kind, item_id)


func _mark_tax_pending(key: String, rate: int, receipt: Dictionary, op: String,
		mode: int = 0) -> void:
	TaxPanel._mark_tax_pending(self, key, rate, receipt, op, mode)


func show_tax_rejection(result: Dictionary) -> void:
	TaxPanel.show_tax_rejection(self, result)


func _resolve_tax_pending(context: Dictionary, category: Dictionary = {}) -> void:
	TaxPanel._resolve_tax_pending(self, context, category)


func _resolve_tax_editor_key(key: String) -> void:
	TaxPanel._resolve_tax_editor_key(self, key)


func _tax_key(kind: String, item_key: String) -> String:
	return TaxPanel._tax_key(self, kind, item_key)


func _update_reset_tax_button() -> void:
	TaxPanel._update_reset_tax_button(self)


func _request_category_tax_reset() -> void:
	TaxPanel._request_category_tax_reset(self)


func _on_category_tax_reset_confirmed() -> void:
	TaxPanel._on_category_tax_reset_confirmed(self)


func _apply_category_patch(data: Dictionary) -> void:
	CategoryContent._apply_category_patch(self, data)


func _apply_category_block_patch(data: Dictionary) -> void:
	CategoryContent._apply_category_block_patch(self, data)


func _add_collapsible_section(section: Dictionary, host: Control = null) -> VBoxContainer:
	var section_id := String(section.get("id", "section"))
	var key := "%s:%s" % [_current_tab, section_id]
	var collapsed := bool(_section_collapsed.get(key, section.get("collapsed", false)))
	_section_collapsed[key] = collapsed
	var root := CollapsibleSectionScene.instantiate() as VBoxContainer
	var header := root.get_node("Header") as Button
	var chevron := root.get_node("Header/Row/Chevron") as IconBadge
	var icon := root.get_node("Header/Row/Icon") as IconBadge
	var label := root.get_node("Header/Row/Label") as Label
	var body := root.get_node("Body") as VBoxContainer
	var refs := {
		"summary": root.get_node("Header/Row/Summary") as Label,
		"caption": root.get_node("Body/Caption") as Label,
	}
	header.set_pressed_no_signal(not collapsed)
	icon.set_semantic(
		StringName(IconBadge.normalize_icon(section.get("icon", &"summary.overview"))),
		section.get("accent", UITokens.ACCENT)
	)
	label.text = String(section.get("title", "资料"))
	_apply_section_texts(refs, section)
	body.visible = not collapsed
	_apply_section_chevron(chevron, collapsed)
	header.toggled.connect(func(expanded: bool) -> void:
		_section_collapsed[key] = not expanded
		_apply_section_chevron(chevron, not expanded)
		body.visible = expanded
		if expanded:
			UIAnimation.crossfade(body, UITokens.ANIM_FAST)
	)
	var parent_box: Control = host if host != null else _content_box
	parent_box.add_child(root)
	_section_refs[section_id] = refs
	return body


func _apply_section_texts(refs: Dictionary, section: Dictionary) -> void:
	if section.has("summary"):
		var summary := refs.summary as Label
		summary.text = String(section.get("summary", ""))
		summary.visible = not summary.text.is_empty()
	if section.has("caption"):
		var caption := refs.caption as Label
		caption.text = String(section.get("caption", ""))
		caption.visible = not caption.text.is_empty()


func _apply_section_chevron(chevron: IconBadge, collapsed: bool) -> void:
	chevron.set_semantic(
		&"action.chevron_right" if collapsed else &"action.chevron_down",
		UITokens.DOSSIER_INK_SOFT
	)


func _chapter_spec(tabs: Array) -> Array:
	var chapters := []
	for raw in tabs:
		var tab: Dictionary = raw
		chapters.append({
			"id": String(tab.get("id", "")),
			"label": String(tab.get("label", "")),
			"icon": IconBadge.normalize_icon(tab.get("icon", "")),
			"question": String(tab.get("tooltip", "")),
		})
	return chapters


func _on_inspector_resized() -> void:
	_sync_split_layout()


func _animate_content_in() -> void:
	LivePresentation._animate_content_in(self)


func set_construction_model(model: Dictionary) -> void:
	DetailWorkspaces.set_construction_model(self, model)


func set_construction_feedback(message: String, ok: bool) -> void:
	DetailWorkspaces.set_construction_feedback(self, message, ok)


func building_workspace_open() -> bool:
	return DetailWorkspaces.building_workspace_open(self)


func release_military_ledger_busy() -> void:
	DetailWorkspaces.release_military_ledger_busy(self)


func set_military_ledger_feedback(message: String, ok: bool) -> void:
	DetailWorkspaces.set_military_ledger_feedback(self, message, ok)


func set_military_army_feedback(message: String, ok: bool) -> void:
	DetailWorkspaces.set_military_army_feedback(self, message, ok)


func request_construction_refresh() -> void:
	DetailWorkspaces.request_construction_refresh(self)


func show_military_dossier(payload: Dictionary) -> void:
	DetailWorkspaces.show_military_dossier(self, payload)


func refresh_military_dossier(payload: Dictionary) -> void:
	DetailWorkspaces.refresh_military_dossier(self, payload)


func military_dossier_open() -> bool:
	return DetailWorkspaces.military_dossier_open(self)


func military_dossier_identity() -> String:
	return DetailWorkspaces.military_dossier_identity(self)


func update_military_arm_order(state: Dictionary) -> void:
	DetailWorkspaces.update_military_arm_order(self, state)


func set_military_dossier_feedback(message: String, ok: bool) -> void:
	DetailWorkspaces.set_military_dossier_feedback(self, message, ok)


func set_directory_available(available: bool) -> void:
	DetailWorkspaces.set_directory_available(self, available)


func show_object_detail(payload: Dictionary) -> void:
	DetailWorkspaces.show_object_detail(self, payload)


func show_family_workspace(payload: Dictionary, animate: bool = true) -> void:
	DetailWorkspaces.show_family_workspace(self, payload, animate)


func refresh_family_workspace(payload: Dictionary) -> void:
	DetailWorkspaces.refresh_family_workspace(self, payload)


func family_workspace_open() -> bool:
	return DetailWorkspaces.family_workspace_open(self)


func refresh_object_detail(payload: Dictionary) -> void:
	DetailWorkspaces.refresh_object_detail(self, payload)


func _on_object_tax_editing_finished() -> void:
	DetailWorkspaces._on_object_tax_editing_finished(self)


func _apply_deferred_object_detail_refresh() -> void:
	DetailWorkspaces._apply_deferred_object_detail_refresh(self)


func _request_object_detail(request: Dictionary) -> void:
	DetailWorkspaces._request_object_detail(self, request)


func close_detail(notify: bool = true) -> void:
	DetailWorkspaces.close_detail(self, notify)


func detail_open() -> bool:
	return DetailWorkspaces.detail_open(self)


func set_compact_detail_mode(compact: bool) -> void:
	DetailWorkspaces.set_compact_detail_mode(self, compact)


func set_list_wing_enabled(enabled: bool) -> void:
	DetailWorkspaces.set_list_wing_enabled(self, enabled)


func has_list_wing() -> bool:
	return DetailWorkspaces.has_list_wing(self)


func list_wing_open() -> bool:
	return DetailWorkspaces.list_wing_open(self)


func _notify_list_wing_changed() -> void:
	DetailWorkspaces._notify_list_wing_changed(self)


func _unhandled_key_input(event: InputEvent) -> void:
	if military_dossier_open() and _military_dossier.handle_order_key(event):
		get_viewport().set_input_as_handled()
		return
	if not visible or not detail_open() or not (event is InputEventKey) \
			or not event.pressed or event.echo or event.keycode != KEY_ESCAPE:
		return
	close_detail()
	get_viewport().set_input_as_handled()


func _build_construction_entry(host: Control, entry_data: Dictionary) -> void:
	DetailWorkspaces._build_construction_entry(self, host, entry_data)


func _open_building_workspace() -> void:
	DetailWorkspaces._open_building_workspace(self)


func _show_detail_shell() -> void:
	DetailWorkspaces._show_detail_shell(self)


func _on_detail_closed() -> void:
	DetailWorkspaces._on_detail_closed(self)


func _set_family_chrome(active: bool) -> void:
	DetailWorkspaces._set_family_chrome(self, active)


func _sync_split_layout() -> void:
	DetailWorkspaces._sync_split_layout(self)


func _on_tab_selected(tab_id: String) -> void:
	LivePresentation._on_tab_selected(self, tab_id)


func _restore_tab_scroll(tab_id: String) -> void:
	LivePresentation._restore_tab_scroll(self, tab_id)


func _request_tab_data_if_missing(tab_id: String) -> void:
	LivePresentation._request_tab_data_if_missing(self, tab_id)


func _category_structure(data: Dictionary) -> String:
	return LivePresentation._category_structure(self, data)


func _tabs_signature(tabs: Array) -> String:
	return LivePresentation._tabs_signature(self, tabs)


func _has_tab(tabs: Array, tab_id: String) -> bool:
	return LivePresentation._has_tab(self, tabs, tab_id)


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count
