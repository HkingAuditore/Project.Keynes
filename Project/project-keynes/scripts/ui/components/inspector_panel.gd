extends PanelContainer
class_name InspectorPanel

const MetricCardScene := preload("res://scenes/ui/metric_card.tscn")
const InsightShellScene := preload("res://scenes/ui/insight_shell.tscn")
const ResourceListScene := preload("res://scenes/ui/resource_list.tscn")
const FamilyListScene := preload("res://scenes/ui/family_list.tscn")
const MarketListScene := preload("res://scenes/ui/market_list.tscn")
const CohortListScene := preload("res://scenes/ui/cohort_list.tscn")
const BuildingListScene := preload("res://scenes/ui/building_list.tscn")
const ConstructionEntryScene := preload("res://scenes/ui/construction_entry.tscn")
const GaugeBarScene := preload("res://scenes/ui/gauge_bar.tscn")
const BadgeRowScene := preload("res://scenes/ui/badge_row.tscn")
const MetricGridScene := preload("res://scenes/ui/metric_grid.tscn")
const SectionHeaderScene := preload("res://scenes/ui/section_header.tscn")
const GroupSeparatorScene := preload("res://scenes/ui/group_separator.tscn")

const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const CLEAR_ALL_MENU_ID := 1

signal close_requested()
signal tab_data_requested(tab_id: String)
signal object_details_requested(request: Dictionary)
signal detail_visibility_changed(open: bool)
signal family_colonization_requested(family_handle: int, source_cell: int)
signal construction_page_requested(search: String, offset: int)
signal construction_requested(request: Dictionary)
signal colonization_requested(request: Dictionary)

var _model: Dictionary = {}
var _current_tab := "geography"
var _tabs_signature_cache := ""
var _cell_index := -1
var _scroll_by_tab: Dictionary = {}
var _compact_detail := false

var _title_label: Label
var _subtitle_label: Label
var _score_gauge: RadialGauge
var _summary_grid: GridContainer
var _summary_cards: Dictionary = {}
var _tabs: CategoryTabs
var _scroll: ScrollContainer
var _content_box: VBoxContainer
var _inspector_root: VBoxContainer
var _detail_shell: PanelContainer
var _object_detail_dialog: ObjectDetailDialog
var _construction_pane: VBoxContainer
var _construction_picker: ConstructionPicker
var _more_button: MenuButton
var _clear_tax_confirmation: ConfirmationDialog

var _insight_list: InsightList
var _badge_row: BadgeRow
var _resource_list: ResourceList
var _cohort_list
var _building_list
var _market_list
var _family_list
var _metric_controls: Dictionary = {}
var _gauge_controls: Dictionary = {}
var _chart_controls: Dictionary = {}
var _summary_trends: Dictionary = {}
var _last_score_band := -1
var _player_controller = null
var _colonization_button: Button
var _tax_context: Dictionary = {}
var _tax_editors: Dictionary = {}
var _pending_tax: Dictionary = {}
var _construction_model: Dictionary = {}
var _detail_change_notify := true


func _ready() -> void:
	if _content_box != null:
		return
	_title_label = get_node_or_null("%TitleLabel") as Label
	_subtitle_label = get_node_or_null("%SubtitleLabel") as Label
	_score_gauge = get_node_or_null("%ScoreGauge") as RadialGauge
	_summary_grid = get_node_or_null("%SummaryGrid") as GridContainer
	_tabs = get_node_or_null("%CategoryTabs") as CategoryTabs
	_scroll = get_node_or_null("%Scroll") as ScrollContainer
	_content_box = get_node_or_null("%ContentBox") as VBoxContainer
	_inspector_root = get_node_or_null("%InspectorRoot") as VBoxContainer
	_detail_shell = get_node_or_null("%DetailShell") as PanelContainer
	_object_detail_dialog = get_node_or_null("%ObjectDetail") as ObjectDetailDialog
	_construction_pane = get_node_or_null("%ConstructionPane") as VBoxContainer
	_construction_picker = get_node_or_null("%ConstructionPicker") as ConstructionPicker
	_more_button = get_node_or_null("%MoreButton") as MenuButton
	_clear_tax_confirmation = get_node_or_null("%ClearTaxConfirmation") as ConfirmationDialog
	_colonization_button = get_node_or_null("%ColonizationButton") as Button
	var close_button := get_node_or_null("%CloseButton") as Button
	if _title_label == null or _subtitle_label == null or _score_gauge == null \
			or _summary_grid == null or _tabs == null or _scroll == null \
			or _content_box == null or close_button == null or _detail_shell == null \
			or _object_detail_dialog == null or _construction_picker == null:
		push_error("InspectorPanel 必须通过 inspector_panel.tscn 实例化。")
		return
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭地块档案")
	close_button.pressed.connect(func() -> void:
		if detail_open():
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
	var construction_back := get_node(
		"Margin/Split/DetailShell/ConstructionPane/Header/BackButton") as Button
	IconButton.apply(construction_back, &"action.back", IconButton.SMALL, "返回地块档案")
	construction_back.pressed.connect(close_detail)
	_construction_picker.page_requested.connect(
		func(search: String, offset: int) -> void:
			construction_page_requested.emit(search, offset))
	_construction_picker.build_requested.connect(
		func(request: Dictionary) -> void: construction_requested.emit(request))
	_tabs.tab_selected.connect(_on_tab_selected)


func set_model(model: Dictionary, _rebuild_visible: bool = true) -> void:
	set_model_for_selection(model)


func set_player_controller(controller) -> void:
	_player_controller = controller
	if _object_detail_dialog != null:
		_object_detail_dialog.set_player_controller(controller)


func set_model_for_selection(model: Dictionary) -> void:
	if _content_box == null:
		_ready()
	var new_cell_index := int(model.get("cell_index", -1))
	if new_cell_index != _cell_index:
		_scroll_by_tab.clear()
		_pending_tax.clear()
		close_detail(false)
		_cell_index = new_cell_index
		if _scroll != null:
			_scroll.scroll_vertical = 0
	_model = model
	if _model.is_empty():
		return
	_apply_header(_model.get("header", {}), false)
	_apply_colonization_action(_model.get("colonization_action", {}))
	_render_summary(_model.get("score", {}), _model.get("summary_cards", []))
	var tabs: Array = _model.get("tabs", [])
	if not _has_tab(tabs, _current_tab):
		_current_tab = "geography"
	# 页签集合会随视野状态变化（未探索 0 个 / 已探索 1 个 / 可见 5 个），
	# 所以不能只在首次装配时 set_tabs，得按签名判断是否需要重建页签栏。
	var signature := _tabs_signature(tabs)
	if signature != _tabs_signature_cache:
		_tabs_signature_cache = signature
		_tabs.set_tabs(tabs, _current_tab, true)
	else:
		_tabs.select_tab(_current_tab)
	if not tabs.is_empty():
		_request_tab_data_if_missing(_current_tab)
	_render_content(false)


func apply_live_patch(patch: Dictionary) -> void:
	if patch.is_empty() or _content_box == null:
		return
	_apply_header(patch.get("header", {}), true)
	_apply_score(patch.get("score", {}), true)
	for raw in patch.get("summary_cards", []):
		var data: Dictionary = raw
		var card_id := String(data.get("id", ""))
		var card := _summary_cards.get(card_id) as MetricCard
		if card != null:
			_apply_metric_card(card, data)
			var trend := String(data.get("trend", ""))
			var previous_trend := String(_summary_trends.get(card_id, ""))
			if previous_trend != "" and trend != "" and trend != previous_trend:
				UIAnimation.pulse(card, UITokens.ANIM_MED)
			_summary_trends[card_id] = trend
	var patch_tab := String(patch.get("tab_id", ""))
	if patch.has("category") and patch_tab != "":
		set_tab_category(patch_tab, patch.get("category", {}))
	if patch_tab != _current_tab:
		return
	_apply_category_patch(patch.get("category", {}))


func set_tab_category(tab_id: String, category: Dictionary) -> void:
	if tab_id == "" or category.is_empty():
		return
	var categories: Dictionary = _model.get("categories", {})
	categories[tab_id] = category
	_model["categories"] = categories


func current_tab() -> String:
	return _current_tab


func select_tab(tab_id: String) -> void:
	if tab_id == _current_tab or not _has_tab(_model.get("tabs", []), tab_id):
		return
	_tabs.select_tab(tab_id)
	_on_tab_selected(tab_id)


func reset_for_world() -> void:
	_model.clear()
	_cell_index = -1
	_current_tab = "geography"
	_scroll_by_tab.clear()
	_pending_tax.clear()
	close_detail(false)
	_tabs_signature_cache = ""
	_last_score_band = -1
	_summary_cards.clear()
	_summary_trends.clear()
	_metric_controls.clear()
	_gauge_controls.clear()
	_chart_controls.clear()
	if _tabs != null:
		_tabs.clear_tabs()
	if _scroll != null:
		_scroll.scroll_vertical = 0


func visible_node_count() -> int:
	return _count_nodes(self)


func _apply_header(header: Dictionary, _live_patch: bool) -> void:
	_title_label.text = String(header.get("title", "地块档案"))
	_subtitle_label.text = String(header.get("subtitle", ""))


func _apply_colonization_action(action: Dictionary) -> void:
	if _colonization_button == null:
		return
	var available := bool(action.get("available", false))
	_colonization_button.visible = available
	_colonization_button.disabled = not available
	_colonization_button.tooltip_text = "派遣境内家族分支开拓这块无主地" \
		if available else String(action.get("reason", ""))


func _render_summary(score: Dictionary, cards: Array) -> void:
	_apply_score(score, false)
	for child in _summary_grid.get_children():
		child.queue_free()
	_summary_cards.clear()
	for raw in cards:
		var data: Dictionary = raw
		var card := MetricCardScene.instantiate() as MetricCard
		card.custom_minimum_size = Vector2(0.0, 42.0)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_summary_grid.add_child(card)
		_apply_metric_card(card, data)
		var card_id := String(data.get("id", "summary_%d" % _summary_cards.size()))
		_summary_cards[card_id] = card
		_summary_trends[card_id] = String(data.get("trend", ""))


func _apply_score(score: Dictionary, live_patch: bool) -> void:
	if score.is_empty():
		# 未探索格没有适宜度可言，留着上一格的表盘会读成这一格的数据。
		# live patch 里的空 score 只表示「这次没更新」，不能据此隐藏。
		if not live_patch and _score_gauge != null:
			_score_gauge.visible = false
			_last_score_band = -1
		return
	if _score_gauge != null:
		_score_gauge.visible = true
	var score_value := float(score.get("value", 0.0))
	var score_band := _score_band(score_value)
	if live_patch and _last_score_band >= 0 and score_band != _last_score_band:
		UIAnimation.pulse(_score_gauge, UITokens.ANIM_MED)
	_last_score_band = score_band
	_score_gauge.set_data(
		String(score.get("title", "适宜度")),
		score_value,
		String(score.get("caption", "")),
		score.get("accent", UITokens.ACCENT)
	)


func _render_content(reset_scroll: bool) -> void:
	for child in _content_box.get_children():
		child.queue_free()
	_insight_list = null
	_badge_row = null
	_resource_list = null
	_cohort_list = null
	_building_list = null
	_market_list = null
	_tax_context = {}
	_tax_editors.clear()
	_metric_controls.clear()
	_gauge_controls.clear()
	_chart_controls.clear()
	var categories: Dictionary = _model.get("categories", {})
	var data: Dictionary = categories.get(_current_tab, categories.get("geography", {}))
	_build_category_content(data)
	if reset_scroll and _scroll != null:
		_scroll.scroll_vertical = 0


func _build_category_content(data: Dictionary) -> void:
	_tax_context = data.get("tax_context", {})
	_update_more_button()
	var root_data := data.duplicate(false)
	root_data.erase("sections")
	root_data.erase("tax_context")
	_build_category_block(root_data)
	for raw_section in data.get("sections", []):
		var section: Dictionary = raw_section
		_add_section_header(section)
		_build_category_block(section)


func _build_category_block(data: Dictionary) -> void:
	var insights: Array = data.get("insights", [])
	if not insights.is_empty():
		var insight_shell := InsightShellScene.instantiate() as PanelContainer
		_content_box.add_child(insight_shell)
		_insight_list = insight_shell.get_node("InsightList") as InsightList
		_insight_list.set_items(insights)

	var cohort_rows: Array = data.get("cohort_rows", [])
	if data.has("family_rows"):
		_family_list = FamilyListScene.instantiate()
		_family_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_family_list.details_requested.connect(
			_request_object_detail)
		_family_list.set_rows(data.get("family_rows", []))
		_content_box.add_child(_family_list)
	if data.has("cohort_rows"):
		_add_group_separator()
		_cohort_list = CohortListScene.instantiate() as CohortList
		_cohort_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_cohort_list.details_requested.connect(
			_request_object_detail)
		_cohort_list.set_rows(cohort_rows)
		_content_box.add_child(_cohort_list)

	var resource_rows: Array = data.get("resource_rows", [])
	if data.has("resource_rows"):
		_add_group_separator()
		_resource_list = ResourceListScene.instantiate() as ResourceList
		_resource_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_resource_list.details_requested.connect(
			_request_object_detail)
		_resource_list.set_rows(resource_rows)
		_content_box.add_child(_resource_list)

	var market_rows: Array = data.get("market_rows", [])
	if data.has("market_rows"):
		_add_group_separator()
		_market_list = MarketListScene.instantiate()
		_market_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_market_list.details_requested.connect(
			_request_object_detail)
		_market_list.set_rows(market_rows)
		_content_box.add_child(_market_list)

	var building_rows: Array = data.get("building_rows", [])
	if data.has("building_rows"):
		_add_group_separator()
		if data.has("construction"):
			_construction_model = data.get("construction", {})
			_construction_picker.set_model(_construction_model)
			var entry := ConstructionEntryScene.instantiate() as PanelContainer
			(entry.get_node("Row/Icon") as IconBadge).set_semantic(
				&"economy.building", UITokens.CLIMATE)
			(entry.get_node("Row/OpenButton") as Button).pressed.connect(
				_open_construction)
			_content_box.add_child(entry)
			_add_group_separator()
		_building_list = BuildingListScene.instantiate() as BuildingList
		_building_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_building_list.details_requested.connect(
			_request_object_detail)
		_building_list.set_rows(building_rows)
		_content_box.add_child(_building_list)

	var metrics: Array = data.get("metrics", [])
	if not metrics.is_empty():
		_add_group_separator()
		var grid := MetricGridScene.instantiate() as GridContainer
		_content_box.add_child(grid)
		for raw in metrics:
			var metric: Dictionary = raw
			var card := MetricCardScene.instantiate() as MetricCard
			card.custom_minimum_size = Vector2(184.0, 56.0)
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(card)
			_apply_metric_card(card, metric)
			_metric_controls[String(metric.get("id", "metric_%d" % _metric_controls.size()))] = card

	var gauges: Array = data.get("gauges", [])
	if not gauges.is_empty():
		_add_group_separator()
		for raw in gauges:
			var gauge: Dictionary = raw
			var bar := GaugeBarScene.instantiate() as GaugeBar
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_content_box.add_child(bar)
			_apply_gauge(bar, gauge)
			_gauge_controls[String(gauge.get("id", "gauge_%d" % _gauge_controls.size()))] = bar

	var charts: Array = data.get("charts", [])
	if not charts.is_empty():
		_add_group_separator()
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
			_content_box.add_child(spark)
			_chart_controls[String(chart.get("id", "chart_%d" % _chart_controls.size()))] = spark

	var badges: Array = data.get("badges", [])
	if not badges.is_empty():
		_add_group_separator()
		var row := BadgeRowScene.instantiate() as BadgeRow
		row.set_badges(badges)
		_content_box.add_child(row)
		_badge_row = row


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
		rate: int
) -> void:
	if _player_controller == null or _cell_index < 0:
		return
	var kind_id := int(TAX_KIND_IDS.get(kind, -1))
	if kind_id < 0:
		return
	var command := &"country.tax.cell.set_default" \
		if scope == "default" else &"country.tax.cell.set_override"
	var args := {"cell": _cell_index, "kind": kind_id, "rate_percent": rate}
	if scope != "default":
		args["item_id"] = StringName(item_id)
	var result: Dictionary = _player_controller.request_command(command, args)
	var key := _tax_key(kind, item_id if scope != "default" else "default")
	if bool(result.get("ok", false)):
		_mark_tax_pending(key, rate)
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
		_mark_tax_pending(key, rate)
	else:
		_resolve_tax_editor_key(key)


func _mark_tax_pending(key: String, rate: int) -> void:
	_pending_tax[key] = {
		"effective_day": int(_tax_context.get("current_day", -1)) + 1,
		"policy_version": int(_tax_context.get("policy_version", -1)),
		"rate": rate,
	}
	for editor_value in _tax_editors.get(key, []):
		(editor_value as TaxLaneEditor).mark_pending(rate)


func _resolve_tax_pending(context: Dictionary) -> void:
	var current_day := int(context.get("current_day", -1))
	var policy_version := int(context.get("policy_version", -1))
	var resolved: Array[String] = []
	for key_value in _pending_tax.keys():
		var key := String(key_value)
		var pending: Dictionary = _pending_tax[key]
		if current_day >= int(pending.get("effective_day", current_day + 1)) \
				and policy_version > int(pending.get("policy_version", policy_version)):
			resolved.append(key)
	for key in resolved:
		_pending_tax.erase(key)
		if key == _clear_all_pending_key():
			for editor_key in _tax_editors.keys():
				_resolve_tax_editor_key(String(editor_key))
		else:
			_resolve_tax_editor_key(key)


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
	}
	for editor_key in _tax_editors.keys():
		for editor_value in _tax_editors[editor_key]:
			var editor := editor_value as TaxLaneEditor
			editor.mark_pending(int(editor.lane_data().get("base", 0)))


func _apply_category_patch(data: Dictionary) -> void:
	if data.has("tax_context"):
		_tax_context = data.get("tax_context", {})
		_resolve_tax_pending(_tax_context)
		_update_more_button()
	_apply_category_block_patch(data)
	for raw_section in data.get("sections", []):
		_apply_category_block_patch(raw_section as Dictionary)


func _apply_category_block_patch(data: Dictionary) -> void:
	if _insight_list != null:
		_insight_list.update_items(data.get("insights", []))
	if _badge_row != null and data.has("badges"):
		_badge_row.update_badges(data.get("badges", []))
	if _cohort_list != null and data.has("cohort_rows"):
		_cohort_list.update_rows(data.get("cohort_rows", []))
	if _family_list != null and data.has("family_rows"):
		_family_list.update_rows(data.get("family_rows", []))
	if _resource_list != null:
		_resource_list.update_rows(data.get("resource_rows", []))
	if _building_list != null and data.has("building_rows"):
		_building_list.update_rows(data.get("building_rows", []))
	if _construction_picker != null and data.has("construction"):
		_construction_model = data.get("construction", {})
		_construction_picker.set_model(_construction_model)
	if _market_list != null and data.has("market_rows"):
		_market_list.update_rows(data.get("market_rows", []))
	for raw in data.get("metrics", []):
		var metric: Dictionary = raw
		var card := _metric_controls.get(String(metric.get("id", ""))) as MetricCard
		if card != null:
			_apply_metric_card(card, metric)
	for raw in data.get("gauges", []):
		var gauge: Dictionary = raw
		var bar := _gauge_controls.get(String(gauge.get("id", ""))) as GaugeBar
		if bar != null:
			_apply_gauge(bar, gauge)
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


func _add_section_header(section: Dictionary) -> void:
	if _content_box.get_child_count() > 0:
		_add_group_separator()
	var row := SectionHeaderScene.instantiate() as HBoxContainer
	var icon := row.get_node("Icon") as IconBadge
	icon.set_semantic(
		StringName(section.get("icon", &"summary.overview")),
		section.get("accent", UITokens.ACCENT)
	)
	var label := row.get_node("Label") as Label
	label.text = String(section.get("title", "资料"))
	_content_box.add_child(row)


func _apply_metric_card(card: MetricCard, data: Dictionary) -> void:
	card.set_data(
		String(data.get("title", "")),
		String(data.get("value", "")),
		String(data.get("subtitle", "")),
		data.get("accent", UITokens.ACCENT),
		String(data.get("trend", "")),
		String(data.get("icon", ""))
	)


func _apply_gauge(bar: GaugeBar, gauge: Dictionary) -> void:
	bar.set_data(
		String(gauge.get("label", "")),
		float(gauge.get("value", 0.0)),
		String(gauge.get("min_label", "")),
		String(gauge.get("max_label", "")),
		gauge.get("accent", UITokens.ACCENT),
		float(gauge.get("marker", -1.0)),
		String(gauge.get("status_label", "")),
		String(gauge.get("value_text", ""))
	)


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
	_construction_pane.visible = false
	_tax_editors.clear()
	_object_detail_dialog.visible = true
	_object_detail_dialog.show_details(payload)
	_register_tax_editors(_object_detail_dialog.tax_editors())
	_show_detail_shell()


func refresh_object_detail(payload: Dictionary) -> void:
	if payload.is_empty() or _object_detail_dialog == null \
			or not _object_detail_dialog.visible:
		return
	_object_detail_dialog.refresh_details(payload)
	_tax_editors.clear()
	_register_tax_editors(_object_detail_dialog.tax_editors())


func _request_object_detail(request: Dictionary) -> void:
	var row_id := String(request.get("row_id", ""))
	for list in [_cohort_list, _market_list, _building_list, _resource_list, _family_list]:
		if list != null and list.has_method("set_selected"):
			list.set_selected(row_id)
	object_details_requested.emit(request)


func close_detail(notify: bool = true) -> void:
	_detail_change_notify = notify
	if _object_detail_dialog != null and _object_detail_dialog.visible:
		_object_detail_dialog.close_dialog()
	else:
		_on_detail_closed()


func detail_open() -> bool:
	return _detail_shell != null and _detail_shell.visible


func set_compact_detail_mode(compact: bool) -> void:
	_compact_detail = compact
	if _inspector_root != null:
		_inspector_root.visible = not compact or not detail_open()


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not detail_open() or not (event is InputEventKey) \
			or not event.pressed or event.echo or event.keycode != KEY_ESCAPE:
		return
	close_detail()
	get_viewport().set_input_as_handled()


func _open_construction() -> void:
	_object_detail_dialog.visible = false
	_construction_pane.visible = true
	_construction_picker.set_model(_construction_model)
	_show_detail_shell()


func _show_detail_shell() -> void:
	_detail_shell.visible = true
	_inspector_root.visible = not _compact_detail
	detail_visibility_changed.emit(true)


func _on_detail_closed() -> void:
	if _detail_shell == null:
		return
	_object_detail_dialog.visible = false
	_construction_pane.visible = false
	_detail_shell.visible = false
	_inspector_root.visible = true
	for list in [_cohort_list, _market_list, _building_list, _resource_list, _family_list]:
		if list != null and list.has_method("set_selected"):
			list.set_selected("")
	if _detail_change_notify:
		detail_visibility_changed.emit(false)
	_detail_change_notify = true


func _add_group_separator() -> void:
	if _content_box.get_child_count() == 0:
		return
	var line := GroupSeparatorScene.instantiate() as HSeparator
	_content_box.add_child(line)


func _on_tab_selected(tab_id: String) -> void:
	if _scroll != null:
		_scroll_by_tab[_current_tab] = _scroll.scroll_vertical
	close_detail()
	_current_tab = tab_id
	tab_data_requested.emit(tab_id)
	_render_content(false)
	call_deferred("_restore_tab_scroll", tab_id)
	UIAnimation.crossfade(_content_box, UITokens.ANIM_FAST)


func _restore_tab_scroll(tab_id: String) -> void:
	if _scroll != null and tab_id == _current_tab:
		_scroll.scroll_vertical = int(_scroll_by_tab.get(tab_id, 0))


func _request_tab_data_if_missing(tab_id: String) -> void:
	var categories: Dictionary = _model.get("categories", {})
	if not categories.has(tab_id):
		tab_data_requested.emit(tab_id)


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


func _score_band(value: float) -> int:
	if value >= 0.80: return 4
	if value >= 0.62: return 3
	if value >= 0.42: return 2
	if value >= 0.24: return 1
	return 0
