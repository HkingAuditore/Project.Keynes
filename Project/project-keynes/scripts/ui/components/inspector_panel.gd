extends PanelContainer
class_name InspectorPanel

const ResourceListScene := preload("res://scenes/ui/resource_list.tscn")
const FamilyListScene := preload("res://scenes/ui/family_list.tscn")
const MarketListScene := preload("res://scenes/ui/market_list.tscn")
const CohortListScene := preload("res://scenes/ui/cohort_list.tscn")
const BuildingListScene := preload("res://scenes/ui/building_list.tscn")
const ConstructionEntryScene := preload("res://scenes/ui/construction_entry.tscn")
const BadgeRowScene := preload("res://scenes/ui/badge_row.tscn")
const FactGridScene := preload("res://scenes/ui/inspector_fact_grid.tscn")
const MeterListScene := preload("res://scenes/ui/inspector_meter_list.tscn")
const NoteListScene := preload("res://scenes/ui/inspector_note_list.tscn")
const ColumnHeaderScene := preload("res://scenes/ui/inspector_column_header.tscn")
const CollapsibleSectionScene := preload("res://scenes/ui/inspector_collapsible_section.tscn")
const TaxSectionScene := preload("res://scenes/ui/object_tax_section.tscn")
const TaxLaneScene := preload("res://scenes/ui/object_tax_lane.tscn")

const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const CLEAR_ALL_MENU_ID := 1
const SPLIT_DETAIL_MIN_WIDTH := 800.0
## 档案列低于此高度时 KPI 条改为单行，给正文多留约 34px。
const DENSE_KPI_MAX_HEIGHT := 500.0
const ROW_LIST_KEYS := ["family_rows", "cohort_rows", "resource_rows",
	"market_rows", "building_rows"]

signal close_requested()
signal tab_data_requested(tab_id: String)
signal object_details_requested(request: Dictionary)
signal detail_visibility_changed(open: bool)
signal family_colonization_requested(family_handle: int, source_cell: int)
signal construction_page_requested(search: String, offset: int)
signal construction_requested(request: Dictionary)
signal colonization_requested(request: Dictionary)
signal trade_orders_page_requested(offset: int)
signal trade_order_locate_requested(cell_idx: int)

var _model: Dictionary = {}
var _current_tab := "geography"
var _tabs_signature_cache := ""
var _cell_index := -1
var _scroll_by_tab: Dictionary = {}
var _compact_detail := false

var _kicker_label: Label
var _title_label: Label
var _subtitle_label: Label
var _titles_box: Control
var _summary_band: Control
var _kpi_cards: Array = []
var _chapter_nav: DossierChapterNav
var _scroll: ScrollContainer
var _content_box: VBoxContainer
var _inspector_root: VBoxContainer
var _detail_shell: PanelContainer
var _object_detail_dialog: ObjectDetailDialog
var _family_workspace: FamilyWorkspace
var _construction_pane: VBoxContainer
var _construction_picker: ConstructionPicker
var _more_button: MenuButton
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
var _resource_list: ResourceList
var _cohort_list
var _building_list
var _market_list
var _family_list
var _kpi_values: Dictionary = {}
var _player_controller = null
var _colonization_button: Button
var _tax_context: Dictionary = {}
var _tax_editors: Dictionary = {}
var _page_tax_editors: Array = []
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
	_kicker_label = get_node_or_null("%KickerLabel") as Label
	_title_label = get_node_or_null("%TitleLabel") as Label
	_subtitle_label = get_node_or_null("%SubtitleLabel") as Label
	_titles_box = get_node_or_null("%Titles") as Control
	_summary_band = get_node_or_null("%Summary") as Control
	var kpi_row := get_node_or_null("%KpiRow")
	_kpi_cards.clear()
	if kpi_row != null:
		for child in kpi_row.get_children():
			if child is DossierKpiCard:
				(child as Control).custom_minimum_size = Vector2(80.0, DossierKpiCard.HEIGHT)
				_kpi_cards.append(child)
	_chapter_nav = get_node_or_null("%ChapterNav") as DossierChapterNav
	_scroll = get_node_or_null("%Scroll") as ScrollContainer
	_content_box = get_node_or_null("%ContentBox") as VBoxContainer
	_inspector_root = get_node_or_null("%InspectorRoot") as VBoxContainer
	_detail_shell = get_node_or_null("%DetailShell") as PanelContainer
	_object_detail_dialog = get_node_or_null("%ObjectDetail") as ObjectDetailDialog
	_family_workspace = get_node_or_null("%FamilyWorkspace") as FamilyWorkspace
	_construction_pane = get_node_or_null("%ConstructionPane") as VBoxContainer
	_construction_picker = get_node_or_null("%ConstructionPicker") as ConstructionPicker
	_more_button = get_node_or_null("%MoreButton") as MenuButton
	_clear_tax_confirmation = get_node_or_null("%ClearTaxConfirmation") as ConfirmationDialog
	_colonization_button = get_node_or_null("%ColonizationButton") as Button
	var close_button := get_node_or_null("%CloseButton") as Button
	if _title_label == null or _subtitle_label == null or _kicker_label == null \
			or _kpi_cards.size() != 4 or _chapter_nav == null or _scroll == null \
			or _content_box == null or close_button == null or _detail_shell == null \
			or _object_detail_dialog == null or _family_workspace == null \
			or _construction_picker == null:
		push_error("InspectorPanel 必须通过 inspector_panel.tscn 实例化。")
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
	IconButton.apply(_more_button, &"action.more", IconButton.SMALL, "更多操作")
	_more_button.get_popup().id_pressed.connect(_on_more_menu_pressed)
	_clear_tax_confirmation.confirmed.connect(_on_clear_all_tax_confirmed)
	_object_detail_dialog.set_embedded(true)
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
	var construction_back := get_node(
		"Margin/Split/DetailShell/ConstructionPane/Header/BackButton") as Button
	IconButton.apply(construction_back, &"action.back", IconButton.SMALL, "返回")
	construction_back.pressed.connect(close_detail)
	_construction_picker.page_requested.connect(
		func(search: String, offset: int) -> void:
			construction_page_requested.emit(search, offset))
	_construction_picker.build_requested.connect(
		func(request: Dictionary) -> void: construction_requested.emit(request))
	(_kpi_cards[_kpi_cards.size() - 1] as DossierKpiCard).show_divider = false
	_chapter_nav.custom_minimum_size = Vector2(0.0, DossierChapterNav.HEIGHT)
	_chapter_nav.chapter_selected.connect(_on_tab_selected)
	resized.connect(_on_inspector_resized)
	_inspector_root.resized.connect(_sync_kpi_density)
	_sync_split_layout()


func set_model(model: Dictionary, _rebuild_visible: bool = true) -> void:
	set_model_for_selection(model)


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _object_detail_dialog != null:
		_object_detail_dialog.set_player_controller(controller)
	if _family_workspace != null:
		_family_workspace.set_player_controller(controller)


func set_model_for_selection(model: Dictionary) -> void:
	if _content_box == null:
		_ready()
	var new_cell_index := int(model.get("cell_index", -1))
	var cell_changed := new_cell_index != _cell_index
	if cell_changed:
		_scroll_by_tab.clear()
		_pending_tax.clear()
		_draft_tax.clear()
		_deferred_object_detail_payload.clear()
		_section_collapsed.clear()
		_kpi_values.clear()
		close_detail(false)
		_cell_index = new_cell_index
		if _scroll != null:
			_scroll.scroll_vertical = 0
	_model = model
	if _model.is_empty():
		return
	_apply_header(_model.get("header", {}), false)
	if cell_changed and visible and is_inside_tree():
		UIAnimation.crossfade(_titles_box, UITokens.ANIM_FAST)
	_apply_colonization_action(_model.get("colonization_action", {}))
	_apply_kpis(_model.get("kpis", []), not cell_changed)
	var tabs: Array = _model.get("tabs", [])
	if not _has_tab(tabs, _current_tab):
		_current_tab = "geography"
	# 页签集合会随视野状态变化（未探索 0 个 / 已探索 1 个 / 可见 5 个），
	# 所以按签名判断是否需要重设章节索引。
	var signature := _tabs_signature(tabs)
	if signature != _tabs_signature_cache:
		_tabs_signature_cache = signature
		_chapter_nav.set_chapters(_chapter_spec(tabs), _current_tab)
	else:
		_chapter_nav.select(_current_tab, false)
	_chapter_nav.visible = tabs.size() > 1
	if not tabs.is_empty():
		_request_tab_data_if_missing(_current_tab)
	_render_content(false)
	if cell_changed:
		_animate_content_in()


func apply_live_patch(patch: Dictionary) -> void:
	if patch.is_empty() or _content_box == null:
		return
	if patch.has("header"):
		_apply_header(patch.get("header", {}), true)
	if patch.has("kpis"):
		_apply_kpis(patch.get("kpis", []), true)
	var patch_tab := String(patch.get("tab_id", ""))
	if not patch.has("category"):
		return
	if patch_tab != "":
		set_tab_category(patch_tab, patch.get("category", {}))
	if patch_tab != _current_tab:
		return
	var category: Dictionary = (_model.get("categories", {}) as Dictionary).get(patch_tab, {})
	if _category_structure(category) != _content_structure:
		_render_content(false)
	else:
		_apply_category_patch(category)


func set_tab_category(tab_id: String, category: Dictionary) -> void:
	if tab_id == "" or category.is_empty():
		return
	var categories: Dictionary = _model.get("categories", {})
	# 忙碌是暂态，不能用它覆盖已经显示的已提交内容。
	if bool(category.get("data_pending", false)) and categories.has(tab_id) \
			and not bool((categories[tab_id] as Dictionary).get("data_pending", false)):
		return
	categories[tab_id] = category
	_model["categories"] = categories


func current_tab() -> String:
	return _current_tab


func select_tab(tab_id: String) -> void:
	if tab_id == _current_tab or not _has_tab(_model.get("tabs", []), tab_id):
		return
	_on_tab_selected(tab_id)


func reset_for_world() -> void:
	_model.clear()
	_cell_index = -1
	_current_tab = "geography"
	_scroll_by_tab.clear()
	_pending_tax.clear()
	_draft_tax.clear()
	close_detail(false)
	_tabs_signature_cache = ""
	_section_collapsed.clear()
	_kpi_values.clear()
	_clear_block_controls()
	if _chapter_nav != null:
		_chapter_nav.set_chapters([], "")
	if _scroll != null:
		_scroll.scroll_vertical = 0


func visible_node_count() -> int:
	return _count_nodes(self)


func _apply_header(header: Dictionary, _live_patch: bool) -> void:
	_kicker_label.text = String(header.get("kicker", ""))
	_title_label.text = String(header.get("title", "地块"))
	_title_label.tooltip_text = _title_label.text
	_subtitle_label.text = String(header.get("subtitle", ""))
	_subtitle_label.tooltip_text = _subtitle_label.text
	_subtitle_label.visible = not _subtitle_label.text.is_empty()


## KPI 卡片固定 4 张：多余的隐藏，补丁只改值（卡片自带数值补间）。
## 数值相同的补丁不重启动画，避免每日刷新时卡片反复闪动。
func _apply_kpis(kpis: Array, live_patch: bool) -> void:
	if _summary_band != null:
		_summary_band.visible = not kpis.is_empty()
	var visible_count := mini(kpis.size(), _kpi_cards.size())
	for i in range(_kpi_cards.size()):
		var card := _kpi_cards[i] as DossierKpiCard
		card.visible = i < visible_count
		card.show_divider = i < visible_count - 1
		if i >= visible_count:
			continue
		var data: Dictionary = kpis[i]
		var signature := "%s|%s|%s|%s|%s" % [String(data.get("id", "")),
			str(data.get("value", "")), String(data.get("text", "")),
			String(data.get("caption", "")), String(data.get("tone", ""))]
		var slot := "kpi_%d" % i
		if live_patch and String(_kpi_values.get(slot, "")) == signature:
			continue
		_kpi_values[slot] = signature
		card.set_metric(data)


func _apply_colonization_action(action: Dictionary) -> void:
	if _colonization_button == null:
		return
	var available := bool(action.get("available", false))
	var kind := String(action.get("kind", "colonize"))
	_colonization_button.visible = available
	_colonization_button.disabled = not available
	_colonization_button.text = "迁徙" if kind == "relocate" else "开拓"
	if available:
		_colonization_button.tooltip_text = "向此地派遣家族分支迁徙" \
			if kind == "relocate" else "派遣境内家族分支开拓这块无主地"
	else:
		_colonization_button.tooltip_text = String(action.get("reason", ""))


func _sync_kpi_density() -> void:
	if _inspector_root == null:
		return
	var dense := _inspector_root.size.y > 1.0 \
		and _inspector_root.size.y < DENSE_KPI_MAX_HEIGHT
	for card_value in _kpi_cards:
		(card_value as DossierKpiCard).dense = dense


func _clear_block_controls() -> void:
	_note_controls.clear()
	_metric_controls.clear()
	_gauge_controls.clear()
	_list_caption_controls.clear()
	_section_refs.clear()
	_chart_controls.clear()
	_badge_row = null
	_resource_list = null
	_cohort_list = null
	_building_list = null
	_market_list = null
	_family_list = null


func _render_content(reset_scroll: bool) -> void:
	_capture_tax_drafts()
	for child in _content_box.get_children():
		_content_box.remove_child(child)
		child.queue_free()
	_clear_block_controls()
	_tax_context = {}
	_tax_editors.clear()
	_page_tax_editors.clear()
	_page_tax_section = null
	var categories: Dictionary = _model.get("categories", {})
	var data: Dictionary = categories.get(_current_tab, {})
	_content_structure = _category_structure(data)
	_build_category_content(data)
	_rebuild_tax_editor_registry()
	_restore_tax_drafts()
	if reset_scroll and _scroll != null:
		_scroll.scroll_vertical = 0


func _capture_tax_drafts() -> void:
	_draft_tax.clear()
	for key_value in _tax_editors.keys():
		var key := String(key_value)
		if _pending_tax.has(key):
			continue
		for editor_value in _tax_editors[key]:
			var editor := editor_value as TaxLaneEditor
			if editor == null or not editor.is_editing():
				continue
			_draft_tax[key] = editor.displayed_rate()
			break


func _restore_tax_drafts() -> void:
	if _draft_tax.is_empty():
		return
	for key_value in _draft_tax.keys():
		var key := String(key_value)
		if _pending_tax.has(key):
			continue
		var rate := int(_draft_tax[key])
		for editor_value in _tax_editors.get(key, []):
			var editor := editor_value as TaxLaneEditor
			if editor != null and not editor.is_pending():
				editor.apply_draft(rate)
	_draft_tax.clear()


func _build_category_content(data: Dictionary) -> void:
	_tax_context = data.get("tax_context", {})
	_update_more_button()
	var root_data := data.duplicate(false)
	root_data.erase("sections")
	root_data.erase("tax_context")
	_build_category_block(_content_box, root_data)
	for raw_section in data.get("sections", []):
		var section: Dictionary = raw_section
		var body := _add_collapsible_section(section)
		_build_category_block(body, section)
	_build_page_tax_section(_tax_context)


## 一个块（页根或折叠节）的固定阅读顺序：
## 批注（警示）→ 事实表 → 指标条 → 趋势 → 物种徽记 → 建造入口 → 列头 + 名录 → 名录附注。
## 键存在就建控件（空则隐藏），这样补丁里内容由无到有时也只改可见性、不增删节点。
func _build_category_block(host: Control, data: Dictionary) -> void:
	var block_id := String(data.get("id", "_root"))
	if data.has("insights"):
		var notes := NoteListScene.instantiate() as InspectorNoteList
		host.add_child(notes)
		var insights: Array = data.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
		_note_controls[block_id] = notes

	if data.has("metrics"):
		var facts := FactGridScene.instantiate() as InspectorFactGrid
		host.add_child(facts)
		var metrics: Array = data.get("metrics", [])
		facts.set_facts(metrics)
		facts.visible = not metrics.is_empty()
		_metric_controls[block_id] = facts

	if data.has("gauges"):
		var meters := MeterListScene.instantiate() as InspectorMeterList
		host.add_child(meters)
		var gauges: Array = data.get("gauges", [])
		meters.set_meters(gauges)
		meters.visible = not gauges.is_empty()
		_gauge_controls[block_id] = meters

	var charts: Array = data.get("charts", [])
	if not charts.is_empty():
		for raw in charts:
			var chart: Dictionary = raw
			var spark := ChartAdapter.make_sparkline(
				String(chart.get("title", "")),
				chart.get("values", []),
				chart.get("accent", UITokens.ACCENT),
				float(chart.get("min_value", NAN)),
				float(chart.get("max_value", NAN)),
				int(chart.get("window_size", 0)),
				String(chart.get("value_text", ""))
			)
			spark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			host.add_child(spark)
			_chart_controls[String(chart.get("id", "chart_%d" % _chart_controls.size()))] = spark

	var badges: Array = data.get("badges", [])
	if not badges.is_empty():
		var row := BadgeRowScene.instantiate() as BadgeRow
		host.add_child(row)
		row.set_badges(badges)
		_badge_row = row

	if data.has("building_rows") and data.has("construction"):
		_construction_model = data.get("construction", {})
		_construction_picker.set_model(_construction_model)
		var entry := ConstructionEntryScene.instantiate() as PanelContainer
		(entry.get_node("Row/Icon") as IconBadge).set_semantic(
			&"economy.building", UITokens.CLIMATE)
		(entry.get_node("Row/OpenButton") as Button).pressed.connect(
			_open_construction)
		host.add_child(entry)

	for row_key in ROW_LIST_KEYS:
		if data.has(row_key):
			_build_row_list(host, data, String(row_key), block_id)


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
	caption.visible = not text.is_empty()
	caption.set_notes([] if text.is_empty() else [{"id": "list_caption", "text": text,
		"accent": UITokens.TEXT_MUTED}])


## 税率编辑收进页尾的折叠「税务」节：默认收起，节头直接给出当前税率，
## 展开后才是可编辑的税档。_page_tax_section 指向整个折叠节，
## 打开对象详情时整节隐藏（对象详情自带对象级税档）。
func _build_page_tax_section(context: Dictionary) -> void:
	_page_tax_editors.clear()
	_page_tax_section = null
	var defaults: Array = context.get("default_lanes", [])
	if defaults.is_empty():
		return
	var body := _add_collapsible_section({
		"id": "page_tax", "title": _page_tax_title(_current_tab),
		"icon": "tax.section", "accent": UITokens.BRASS_HIGHLIGHT,
		"collapsed": true, "summary": _tax_summary(defaults),
	})
	_page_tax_section = body.get_parent() as Control
	var section := TaxSectionScene.instantiate() as VBoxContainer
	body.add_child(section)
	(section.get_node("Head") as Control).visible = false
	var editable := bool(context.get("editable", false))
	var hint := section.get_node("Hint") as Label
	if not bool(context.get("available", true)):
		hint.text = String(context.get("reason", "该领土没有可调整的税收政策。"))
	elif not editable:
		hint.text = "仅可查看该国当前政策。"
	else:
		hint.text = "未单独设档的项目适用此地税率，次日生效。"
	hint.visible = true
	var lanes := section.get_node("Lanes") as VBoxContainer
	for raw in defaults:
		var lane: Dictionary = raw
		var editor := TaxLaneScene.instantiate() as TaxLaneEditor
		lanes.add_child(editor)
		editor.set_data(lane)
		_restore_lane_pending(editor, lane)
		_page_tax_editors.append(editor)
	lanes.visible = not defaults.is_empty()
	_sync_page_tax_visibility()


func _page_tax_title(tab_id: String) -> String:
	return {
		"population": "此地所得税",
	"market": "此地交易税与关税",
		"buildings": "此地营业税",
	}.get(tab_id, "此地税率")


func _tax_summary(lanes: Array) -> String:
	var parts := PackedStringArray()
	var adjusted := false
	for lane_value in lanes:
		var lane: Dictionary = lane_value
		var label := String(lane.get("kind_label", "")).trim_prefix("此地")
		parts.append("%s %s" % [label, TaxLaneEditor._format_value(
			int(lane.get("base", 0)), int(lane.get("mode", 0)))])
		adjusted = adjusted or bool(lane.get("has_override", false))
	var text := " · ".join(parts) if parts.size() <= 1 \
		else "%s 等 %d 项" % [parts[0], parts.size()]
	return "%s · %s" % [text, "已调整" if adjusted else "沿用国家"]


func _restore_lane_pending(editor: TaxLaneEditor, lane: Dictionary) -> void:
	if editor == null:
		return
	var item_key := "default" if String(lane.get("scope", "item")) == "default" \
		else String(lane.get("item_id", ""))
	var key := _tax_key(String(lane.get("kind", "")), item_key)
	if _pending_tax.has(key):
		editor.mark_pending(
			int(_pending_tax[key].get("rate", lane.get("base", 0))),
			int(_pending_tax[key].get("mode", lane.get("mode", 0))))
	elif _pending_tax.has(_clear_all_pending_key()):
		editor.mark_pending(
			int(lane.get("base", 0)), int(lane.get("mode", 0)))


func _rebuild_tax_editor_registry() -> void:
	_tax_editors.clear()
	_register_tax_editors(_page_tax_editors)
	if _object_detail_dialog != null and _object_detail_dialog.visible:
		_register_tax_editors(_object_detail_dialog.tax_editors())
	_sync_page_tax_visibility()


func _sync_page_tax_visibility() -> void:
	if _page_tax_section == null:
		return
	var inspecting := _object_detail_dialog != null and _object_detail_dialog.visible
	_page_tax_section.visible = not inspecting


func _apply_page_tax_patch(context: Dictionary) -> void:
	var by_kind := {}
	for lane_value in context.get("default_lanes", []):
		var lane: Dictionary = lane_value
		by_kind[String(lane.get("kind", ""))] = lane
	for editor_value in _page_tax_editors:
		var editor := editor_value as TaxLaneEditor
		if editor == null:
			continue
		var kind := String(editor.lane_data().get("kind", ""))
		if by_kind.has(kind):
			editor.set_data(by_kind[kind])
			_restore_lane_pending(editor, by_kind[kind])


func _register_tax_editors(editors: Array) -> void:
	for editor_value in editors:
		_register_tax_editor(editor_value as TaxLaneEditor)


func _register_tax_editor(editor: TaxLaneEditor) -> void:
	if editor == null:
		return
	if not editor.override_requested.is_connected(_on_tax_override_requested):
		editor.override_requested.connect(_on_tax_override_requested)
	if not editor.reset_requested.is_connected(_on_tax_reset_requested):
		editor.reset_requested.connect(_on_tax_reset_requested)
	var key := editor.editor_key(_cell_index)
	var refs: Array = _tax_editors.get(key, [])
	if not refs.has(editor):
		refs.append(editor)
	_tax_editors[key] = refs
	if _pending_tax.has(key):
		var pending: Dictionary = _pending_tax[key]
		editor.mark_pending(int(pending.get(
			"rate", editor.lane_data().get("base", 0))))
	elif _pending_tax.has(_clear_all_pending_key()):
		editor.mark_pending(int(editor.lane_data().get("base", 0)))


func _on_tax_override_requested(
		scope: String,
		kind: String,
		item_id: String,
		rate: int,
		mode: int = 0
) -> void:
	if _player_controller == null or _cell_index < 0:
		return
	var kind_id := int(TAX_KIND_IDS.get(kind, -1))
	if kind_id < 0:
		return
	var command := &"country.tax.cell.set_default" \
		if scope == "default" else &"country.tax.cell.set_override"
	var args := {
		"cell": _cell_index,
		"kind": kind_id,
		"rate_basis_points": rate,
		"tax_assessment_mode": mode,
	}
	if scope != "default":
		args["item_id"] = StringName(item_id)
	var result: Dictionary = _player_controller.request_command(command, args)
	var key := _tax_key(kind, item_id if scope != "default" else "default")
	if bool(result.get("ok", false)):
		_mark_tax_pending(key, rate, "set", mode)
	else:
		_resolve_tax_editor_key(key)


func _on_tax_reset_requested(scope: String, kind: String, item_id: String) -> void:
	if _player_controller == null or _cell_index < 0:
		return
	var kind_id := int(TAX_KIND_IDS.get(kind, -1))
	if kind_id < 0:
		return
	var command := &"country.tax.cell.clear_default" \
		if scope == "default" else &"country.tax.cell.clear_override"
	var args := {"cell": _cell_index, "kind": kind_id}
	if scope != "default":
		args["item_id"] = StringName(item_id)
	var result: Dictionary = _player_controller.request_command(command, args)
	var key := _tax_key(kind, item_id if scope != "default" else "default")
	if bool(result.get("ok", false)):
		var refs: Array = _tax_editors.get(key, [])
		var rate := 0
		if not refs.is_empty():
			rate = int((refs[0] as TaxLaneEditor).lane_data().get("default_rate", 0))
		_mark_tax_pending(key, rate, "clear")
	else:
		_resolve_tax_editor_key(key)


func _mark_tax_pending(key: String, rate: int, op: String = "set",
		mode: int = 0) -> void:
	_pending_tax[key] = {
		"effective_day": int(_tax_context.get("current_day", -1)) + 1,
		"policy_version": int(_tax_context.get("policy_version", -1)),
		"rate": rate,
		"mode": mode,
		"op": op,
	}
	for editor_value in _tax_editors.get(key, []):
		(editor_value as TaxLaneEditor).mark_pending(rate, mode)


func _resolve_tax_pending(context: Dictionary, category: Dictionary = {}) -> void:
	var current_day := int(context.get("current_day", -1))
	var policy_version := int(context.get("policy_version", -1))
	var resolved: Array[String] = []
	for key_value in _pending_tax.keys():
		var key := String(key_value)
		var pending: Dictionary = _pending_tax[key]
		if current_day < int(pending.get("effective_day", current_day + 1)) \
				or policy_version <= int(pending.get("policy_version", policy_version)):
			continue
		if not _pending_visible_in_snapshot(key, pending, context, category):
			continue
		resolved.append(key)
	for key in resolved:
		_pending_tax.erase(key)
		if key == _clear_all_pending_key():
			for editor_key in _tax_editors.keys():
				_resolve_tax_editor_key(String(editor_key))
		else:
			_resolve_tax_editor_key(key)


func _pending_visible_in_snapshot(
		key: String,
		pending: Dictionary,
		context: Dictionary,
		category: Dictionary
) -> bool:
	var op := String(pending.get("op", "set"))
	if key == _clear_all_pending_key() or op == "clear_all":
		var lanes: Array = context.get("default_lanes", [])
		if lanes.is_empty():
			return false
		for lane_value in lanes:
			if bool((lane_value as Dictionary).get("has_override", true)):
				return false
		return true
	var parts := key.split("/")
	if parts.size() < 3:
		return false
	var lane := _find_snapshot_tax_lane(parts[1], parts[2], context, category)
	if lane.is_empty():
		return false
	if op == "clear":
		return not bool(lane.get("has_override", true))
	return bool(lane.get("has_override", false)) \
		and int(lane.get("base", -999)) == int(pending.get("rate", -1))


func _find_snapshot_tax_lane(
		kind: String,
		item_key: String,
		context: Dictionary,
		category: Dictionary
) -> Dictionary:
	if item_key == "default":
		for lane_value in context.get("default_lanes", []):
			var lane: Dictionary = lane_value
			if String(lane.get("kind", "")) == kind:
				return lane
		return {}
	for row_key in ["cohort_rows", "market_rows", "building_rows"]:
		for row_value in category.get(row_key, []):
			for lane_value in (row_value as Dictionary).get("tax_lanes", []):
				var lane: Dictionary = lane_value
				if String(lane.get("kind", "")) == kind \
						and String(lane.get("item_id", "")) == item_key:
					return lane
	return {}


func _resolve_tax_editor_key(key: String) -> void:
	for editor_value in _tax_editors.get(key, []):
		(editor_value as TaxLaneEditor).resolve_pending()


func _tax_key(kind: String, item_key: String) -> String:
	return "cell:%d/%s/%s" % [_cell_index, kind, item_key]


func _clear_all_pending_key() -> String:
	return "cell:%d/all" % _cell_index


func _update_more_button() -> void:
	if _more_button == null:
		return
	_more_button.visible = bool(_tax_context.get("editable", false))


func _on_more_menu_pressed(id: int) -> void:
	if id == CLEAR_ALL_MENU_ID and bool(_tax_context.get("editable", false)):
		_clear_tax_confirmation.popup_centered(Vector2i(480, 220))


func _on_clear_all_tax_confirmed() -> void:
	if _player_controller == null or _cell_index < 0:
		return
	var result: Dictionary = _player_controller.request_command(
		&"country.tax.cell.clear_all", {"cell": _cell_index})
	if not bool(result.get("ok", false)):
		return
	var key := _clear_all_pending_key()
	_pending_tax[key] = {
		"effective_day": int(_tax_context.get("current_day", -1)) + 1,
		"policy_version": int(_tax_context.get("policy_version", -1)),
		"op": "clear_all",
	}
	for editor_key in _tax_editors.keys():
		for editor_value in _tax_editors[editor_key]:
			var editor := editor_value as TaxLaneEditor
			editor.mark_pending(int(editor.lane_data().get("base", 0)))


func _apply_category_patch(data: Dictionary) -> void:
	if data.has("tax_context"):
		_tax_context = data.get("tax_context", {})
		_update_more_button()
		_apply_page_tax_patch(_tax_context)
		_resolve_tax_pending(_tax_context, data)
		var tax_refs: Dictionary = _section_refs.get("page_tax", {})
		if not tax_refs.is_empty():
			(tax_refs.summary as Label).text = _tax_summary(
				_tax_context.get("default_lanes", []))
	var root_data := data.duplicate(false)
	root_data.erase("sections")
	_apply_category_block_patch(root_data)
	for raw_section in data.get("sections", []):
		_apply_category_block_patch(raw_section as Dictionary)


func _apply_category_block_patch(data: Dictionary) -> void:
	var block_id := String(data.get("id", "_root"))
	var notes := _note_controls.get(block_id) as InspectorNoteList
	if notes != null and data.has("insights"):
		var insights: Array = data.get("insights", [])
		notes.set_notes(insights)
		notes.visible = not insights.is_empty()
	var facts := _metric_controls.get(block_id) as InspectorFactGrid
	if facts != null and data.has("metrics"):
		var metrics: Array = data.get("metrics", [])
		facts.set_facts(metrics)
		facts.visible = not metrics.is_empty()
	var meters := _gauge_controls.get(block_id) as InspectorMeterList
	if meters != null and data.has("gauges"):
		var gauges: Array = data.get("gauges", [])
		meters.set_meters(gauges)
		meters.visible = not gauges.is_empty()
	var caption := _list_caption_controls.get(block_id) as InspectorNoteList
	if caption != null and data.has("list_caption"):
		_set_list_caption(caption, String(data.get("list_caption", "")))
	var refs: Dictionary = _section_refs.get(block_id, {})
	if not refs.is_empty():
		_apply_section_texts(refs, data)
	if _badge_row != null and data.has("badges"):
		_badge_row.update_badges(data.get("badges", []))
	if _cohort_list != null and data.has("cohort_rows"):
		_cohort_list.update_rows(data.get("cohort_rows", []))
	if _family_list != null and data.has("family_rows"):
		_family_list.update_rows(data.get("family_rows", []))
	if _resource_list != null and data.has("resource_rows"):
		_resource_list.update_rows(data.get("resource_rows", []))
	if _building_list != null and data.has("building_rows"):
		_building_list.update_rows(data.get("building_rows", []))
	if _construction_picker != null and data.has("construction"):
		_construction_model = data.get("construction", {})
		_construction_picker.set_model(_construction_model)
	if _market_list != null and data.has("market_rows"):
		_market_list.update_rows(data.get("market_rows", []))
	for raw in data.get("charts", []):
		var chart: Dictionary = raw
		var spark := _chart_controls.get(String(chart.get("id", ""))) as SparklineChart
		if spark != null:
			spark.set_data(
				String(chart.get("title", "")),
				chart.get("values", []),
				chart.get("accent", UITokens.ACCENT),
				float(chart.get("min_value", NAN)),
				float(chart.get("max_value", NAN)),
				int(chart.get("window_size", 0)),
				String(chart.get("value_text", ""))
			)


func _add_collapsible_section(section: Dictionary) -> VBoxContainer:
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
			UIAnimation.fade_slide_in(body, Vector2(0.0, -6.0), UITokens.ANIM_FAST)
	)
	_content_box.add_child(root)
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


## 切页或换格后正文逐块淡入：每块错开 28ms，总时长不超过约 0.3s。
func _animate_content_in() -> void:
	if not visible or not is_inside_tree():
		return
	UIAnimation.stagger_children_in(_content_box, 0.028, 8, UITokens.ANIM_FAST)


func set_construction_model(model: Dictionary) -> void:
	_construction_model = model
	if _construction_picker != null:
		_construction_picker.set_model(_construction_model)


func set_construction_feedback(message: String, ok: bool) -> void:
	if _construction_picker != null:
		_construction_picker.set_feedback(message, ok)


func show_object_detail(payload: Dictionary) -> void:
	if payload.is_empty() or _object_detail_dialog == null:
		return
	_set_family_chrome(false)
	_construction_pane.visible = false
	_family_workspace.hide_immediately()
	_deferred_object_detail_payload.clear()
	_object_detail_dialog.visible = true
	_object_detail_dialog.show_details(payload)
	_rebuild_tax_editor_registry()
	_show_detail_shell()


func show_family_workspace(payload: Dictionary, animate: bool = true) -> void:
	if payload.is_empty() or _family_workspace == null:
		return
	var was_open := family_workspace_open()
	_set_family_chrome(true)
	_deferred_object_detail_payload.clear()
	_object_detail_dialog.visible = false
	_construction_pane.visible = false
	_family_workspace.show_family(payload, animate)
	if not was_open:
		_show_detail_shell()


func refresh_family_workspace(payload: Dictionary) -> void:
	if payload.is_empty() or _family_workspace == null \
			or not _family_workspace.visible:
		return
	_family_workspace.set_model(payload)


func family_workspace_open() -> bool:
	return _family_workspace != null and _family_workspace.visible


func refresh_object_detail(payload: Dictionary) -> void:
	if payload.is_empty() or _object_detail_dialog == null \
			or not _object_detail_dialog.visible:
		return
	if not _object_detail_dialog.refresh_details(payload):
		_deferred_object_detail_payload = payload.duplicate(true)
		return
	_deferred_object_detail_payload.clear()
	_rebuild_tax_editor_registry()


func _on_object_tax_editing_finished() -> void:
	if _deferred_object_detail_payload.is_empty():
		return
	call_deferred("_apply_deferred_object_detail_refresh")


func _apply_deferred_object_detail_refresh() -> void:
	if _deferred_object_detail_payload.is_empty() \
			or _object_detail_dialog == null or not _object_detail_dialog.visible:
		return
	var payload := _deferred_object_detail_payload
	if not _object_detail_dialog.refresh_details(payload):
		return
	_deferred_object_detail_payload.clear()
	_rebuild_tax_editor_registry()


func _request_object_detail(request: Dictionary) -> void:
	var row_id := String(request.get("row_id", ""))
	for list in [_cohort_list, _market_list, _building_list, _resource_list, _family_list]:
		if list != null and list.has_method("set_selected"):
			list.set_selected(row_id)
	object_details_requested.emit(request)


func close_detail(notify: bool = true) -> void:
	_deferred_object_detail_payload.clear()
	_detail_change_notify = notify
	if _family_workspace != null and _family_workspace.visible:
		if notify:
			_family_workspace.request_close()
		else:
			_family_workspace.hide_immediately()
			_on_detail_closed()
	elif _object_detail_dialog != null and _object_detail_dialog.visible:
		_object_detail_dialog.close_dialog()
	else:
		_on_detail_closed()


func detail_open() -> bool:
	return _detail_shell != null and _detail_shell.visible


func set_compact_detail_mode(compact: bool) -> void:
	_compact_detail = compact
	_sync_split_layout()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not detail_open() or not (event is InputEventKey) \
			or not event.pressed or event.echo or event.keycode != KEY_ESCAPE:
		return
	close_detail()
	get_viewport().set_input_as_handled()


func _open_construction() -> void:
	_set_family_chrome(false)
	_object_detail_dialog.visible = false
	_family_workspace.hide_immediately()
	_construction_pane.visible = true
	_construction_picker.set_model(_construction_model)
	_rebuild_tax_editor_registry()
	_show_detail_shell()


func _show_detail_shell() -> void:
	_detail_shell.visible = true
	_sync_split_layout()
	detail_visibility_changed.emit(true)


func _on_detail_closed() -> void:
	if _detail_shell == null:
		return
	var was_open := _detail_shell.visible
	var restore_family_focus := _family_chrome_active and _detail_change_notify
	_object_detail_dialog.visible = false
	_family_workspace.hide_immediately()
	_construction_pane.visible = false
	_detail_shell.visible = false
	_set_family_chrome(false)
	_sync_split_layout()
	_inspector_root.visible = true
	if restore_family_focus and _family_list != null:
		_family_list.focus_selected()
	for list in [_cohort_list, _market_list, _building_list, _resource_list, _family_list]:
		if list != null and list.has_method("set_selected"):
			list.set_selected("")
	if was_open:
		detail_visibility_changed.emit(false)
	_detail_change_notify = true
	_rebuild_tax_editor_registry()


func _set_family_chrome(active: bool) -> void:
	if _family_chrome_active == active:
		return
	_family_chrome_active = active
	if active:
		# 只撤掉左侧详情的重复外框；右侧地块档案保留原有材质和边距。
		if _detail_shell != null:
			_detail_shell.add_theme_stylebox_override(&"panel", _empty_panel_style)
	else:
		if _detail_shell != null:
			_detail_shell.remove_theme_stylebox_override(&"panel")


func _sync_split_layout() -> void:
	if _inspector_root == null or _detail_shell == null:
		return
	var split := _inspector_root.get_parent() as Control
	if split != null:
		split.clip_contents = not _family_chrome_active
	var inspecting := _detail_shell.visible
	_detail_shell.clip_contents = not _family_chrome_active
	# 家族栏始终保留右侧目录；普通对象详情仍沿用窄窗独占策略。
	var family_open := _family_workspace != null and _family_workspace.visible
	var can_split := family_open or (not _compact_detail \
		and size.x >= SPLIT_DETAIL_MIN_WIDTH)
	var show_dossier := not inspecting or can_split
	_inspector_root.visible = show_dossier
	_inspector_root.size_flags_horizontal = Control.SIZE_FILL if inspecting \
		else Control.SIZE_EXPAND_FILL
	_inspector_root.size_flags_stretch_ratio = 0.0 if inspecting else 1.0
	_detail_shell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_shell.size_flags_stretch_ratio = 1.0


func _on_tab_selected(tab_id: String) -> void:
	if _scroll != null:
		_scroll_by_tab[_current_tab] = _scroll.scroll_vertical
	close_detail()
	_current_tab = tab_id
	if _chapter_nav != null:
		_chapter_nav.select(tab_id)
	tab_data_requested.emit(tab_id)
	_render_content(false)
	call_deferred("_restore_tab_scroll", tab_id)
	_animate_content_in()


func _restore_tab_scroll(tab_id: String) -> void:
	if _scroll != null and tab_id == _current_tab:
		_scroll.scroll_vertical = int(_scroll_by_tab.get(tab_id, 0))


func _request_tab_data_if_missing(tab_id: String) -> void:
	var categories: Dictionary = _model.get("categories", {})
	if not categories.has(tab_id):
		tab_data_requested.emit(tab_id)


func _category_structure(data: Dictionary) -> String:
	var parts := PackedStringArray()
	for key in ["insights", "metrics", "gauges", "construction"] + ROW_LIST_KEYS:
		if data.has(key):
			parts.append(String(key))
	if not (data.get("badges", []) as Array).is_empty():
		parts.append("badges:%d" % (data["badges"] as Array).size())
	for key in ROW_LIST_KEYS:
		if data.has("list_header") and not (data.get(key, []) as Array).is_empty():
			parts.append("header:%s:%s" % [key, str(data.get("list_header", {}))])
	if data.has("list_caption"):
		parts.append("caption")
	for chart in data.get("charts", []):
		parts.append("chart:%s" % String((chart as Dictionary).get("id", "")))
	for section in data.get("sections", []):
		parts.append("section:%s:%s" % [String((section as Dictionary).get("id", "")),
			_category_structure(section)])
	parts.append("tax:%s" % str((data.get("tax_context", {}) as Dictionary).get("available", false)))
	return "|".join(parts)


func _tabs_signature(tabs: Array) -> String:
	var ids := PackedStringArray()
	for raw in tabs:
		var tab: Dictionary = raw
		ids.append(String(tab.get("id", "")))
	return "|".join(ids)


func _has_tab(tabs: Array, tab_id: String) -> bool:
	for raw in tabs:
		var tab: Dictionary = raw
		if String(tab.get("id", "")) == tab_id:
			return true
	return false


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count
