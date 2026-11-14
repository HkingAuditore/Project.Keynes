extends PanelContainer
class_name ColonizationPlannerPanel

const PlannerPresentation = preload("res://scripts/ui/components/colonization_planner_presentation.gd")
const FamilyRowScene := preload("res://scenes/ui/colonization_family_row.tscn")
const TraitMeterScene := preload("res://scenes/ui/inspector_meter_list.tscn")
const EffectNoteScene := preload("res://scenes/ui/inspector_note_list.tscn")
const TouchUI := preload("res://scripts/ui/touch_ui.gd")

# 路线失败时玩家看到的说明。原生只回 `colonization_route_*` 错误码（或把它塞进
# message），不解释原因；水面在拓扑里是 `passable=0` 的走廊而不是可走地块，
# 所以「跨不过水」在 UI 上表现为「没有城市能到达」，必须在这里把科技门槛讲清楚。
const ROUTE_BLOCKED_SHORT := "路线被水域或不可通行地形隔断，本国没有城市能连通此地。"
const ROUTE_WATER_HINT := "跨水需要「河运」（湖泊）、「天文导航」（浅海）、「远洋航海」（远海）或「远洋船舶设计」（深海）。"
# 城市列表为空时无法区分「水域隔断」与「本国没有可外派家族」——两种都只会
# 返回 total=0，所以这一档的文案两个原因都要留，别把玩家指向错误方向。
const ROUTE_UNREACHABLE_NOTE := "没有城市能到达此地：路线可能被水域或不可通行地形隔断，也可能本国暂无可外派家族。" + ROUTE_WATER_HINT

signal target_selection_requested()
signal source_selection_requested()
signal planning_context_changed(context: Dictionary)
signal closed()
signal route_requested(detail: Dictionary)
signal route_cleared()
signal start_requested(args: Dictionary)
signal cancel_requested(expedition_handle: int)
signal expedition_selected(expedition_handle: int)

var _search: LineEdit
var _sort: OptionButton
var _workflow: Label
var _target_button: Button
var _preview_title: Label
var _preview_metrics: Label
var _preview_traits: Label
var _preview_preferences: Label
var _preview_effects: Label
var _preview_route: Label
var _footer_selection: Label
var _preview_cache: Dictionary = {}
var _quote_preview_cache: Dictionary = {}
var _local_families: Dictionary = {}
var _display_order: Array = []
var _hover_family := ""
var _directory_mode := false
var _source_headers: Dictionary = {}
var _selected_expedition := 0
var _preview_family := 0
var _hover_timer: Timer
var _target_picking := false
var _detail_valid := false
var _source_first := false
var _controller
var _target_cell := -1
var _family_filter := 0
var _source_filter := -1
var _sources_loaded := false
var _source_cities_identity := ""
var _source_city: OptionButton
var _selected_quote: Dictionary = {}
var _economy_busy := false
var _quotes_identity := ""
var _expeditions_identity := ""
var _quote_row_refs: Dictionary = {}
var _expedition_row_refs: Dictionary = {}
var _family_view_cache: Dictionary = {}
var _current_tab := "quotes"
var _title: Label
var _subtitle: Label
var _status: Label
var _tabs: CategoryTabs
var _list: VBoxContainer
var _population_row: HBoxContainer
var _population_label: Label
var _population: SpinBox
var _population_slider: HSlider
var _feedback: Label
var _start: Button
var _expedition_cancel: Button
var _header_icon: IconBadge
var _route_stepper: Control
var _source_pick_button: Button
var _family_step_label: Label
var _source_step_icon: IconBadge
var _family_step_icon: IconBadge
var _target_step_icon: IconBadge
var _city_picker: Control
var _city_cards_box: VBoxContainer
var _city_cards_identity := ""
var _city_card_buttons: Array[Button] = []
var _source_picking := false
var _guide_card: Control
var _guide_icon: IconBadge
var _guide_title: Label
var _guide_facts: InspectorFactGrid
var _guide_notes: InspectorNoteList
var _identity_card: Control
var _preview_crest: IconBadge
var _preview_origin: Label
var _preview_state_pill: Label
var _preview_trait_summary: RichTextLabel
var _preview_effect_summary: RichTextLabel
var _preview_facts: InspectorFactGrid
var _preview_meters: InspectorMeterList
var _detail_section: Control
var _route_block: Control
var _route_card_icon: IconBadge
var _route_ready_pill: Label
var _route_facts: InspectorFactGrid
var _kit_badges: BadgeRow
var _route_notes: InspectorNoteList
var _traits_block: Control
var _traits_box: VBoxContainer
var _trait_meters: InspectorMeterList
var _pref_badges: BadgeRow
var _effects_block: Control
var _effects_box: VBoxContainer
var _effect_notes: InspectorNoteList
var _max_population_button: Button
var _preview_hovering := false
var _planning_identity := ""
var _identity_pulse_tween: Tween


func _ready() -> void:
	if _list != null:
		return
	_title = get_node_or_null("%Title") as Label
	_subtitle = get_node_or_null("%Subtitle") as Label
	_status = get_node_or_null("%StatusLabel") as Label
	_tabs = get_node_or_null("%CategoryTabs") as CategoryTabs
	_list = get_node_or_null("%QuoteList") as VBoxContainer
	_population_row = get_node_or_null("%PopulationRow") as HBoxContainer
	_population_label = get_node_or_null("%PopulationLabel") as Label
	_population = get_node_or_null("%PopulationSpin") as SpinBox
	_feedback = get_node_or_null("%FeedbackLabel") as Label
	_start = get_node_or_null("%StartButton") as Button
	_expedition_cancel = get_node("%ExpeditionCancelButton") as Button
	_expedition_cancel.pressed.connect(func() -> void:
		if _selected_expedition != 0:
			cancel_requested.emit(_selected_expedition))
	_source_city = get_node_or_null("%SourceCity") as OptionButton
	_search = get_node("%FamilySearch") as LineEdit
	_sort = get_node("%FamilySort") as OptionButton
	_workflow = get_node("%Workflow") as Label
	_target_button = get_node("%TargetButton") as Button
	_preview_title = get_node("%PreviewTitle") as Label
	_preview_metrics = get_node("%PreviewMetrics") as Label
	_preview_traits = get_node("%PreviewTraits") as Label
	_preview_preferences = get_node("%PreviewPreferences") as Label
	_preview_effects = get_node("%PreviewEffects") as Label
	_preview_route = get_node("%PreviewRoute") as Label
	# Legacy text mirrors remain available to tests and external readers, but the
	# visual hierarchy uses the dossier cards instead of stacking hidden labels.
	for mirror in [_preview_metrics, _preview_traits, _preview_preferences, _preview_effects, _preview_route]:
		mirror.visible = false
	_footer_selection = get_node("%FooterSelection") as Label
	_hover_timer = get_node("%HoverTimer") as Timer
	_hover_timer.timeout.connect(_show_hover_preview)
	_search.text_changed.connect(func(_text: String) -> void: _apply_list_filter_sort())
	_sort.add_item("可派人数", 0)
	_sort.add_item("威望", 1)
	_sort.add_item("名称", 2)
	_sort.item_selected.connect(func(_index: int) -> void:
		_display_order.clear()
		_apply_list_filter_sort())
	_target_button.pressed.connect(begin_target_selection)
	var close_button := get_node_or_null("%CloseButton") as Button
	if _title == null or _subtitle == null or _status == null or _tabs == null \
			or _list == null or _population_row == null or _population_label == null or _population == null \
			or _feedback == null or _start == null or _source_city == null or close_button == null:
		push_error("ColonizationPlannerPanel 必须通过 colonization_planner_panel.tscn 实例化。")
		return
	theme_type_variation = &"PKArchivePanel"
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_panel)
	_tabs.set_tabs([
		{"id": "quotes", "label": "可派遣", "icon": "family.house",
			"tooltip": "可派往此地的家族", "accent": UITokens.ACCENT},
		{"id": "expeditions", "label": "进行中", "icon": "action.history",
			"tooltip": "筹备中和已出发的开拓队", "accent": UITokens.CLIMATE},
	], "quotes", true)
	_tabs.tab_selected.connect(_on_tab_selected)
	_population.value_changed.connect(func(_value: float) -> void:
		_refresh_selected_kit()
		if _hover_family.is_empty() and not _selected_quote.is_empty() and _preview_family > 0:
			_show_family_preview(_selected_quote))
	_start.pressed.connect(_submit_selected)
	_source_city.item_selected.connect(_on_source_city_selected)
	_bind_atlas_shell()
	if is_inside_tree():
		get_viewport().size_changed.connect(_layout_left_panel)
	_layout_left_panel()
	visible = false


func set_player_controller(controller) -> void:
	_controller = controller


func open_target(target_cell: int, family_filter: int = 0,
		source_filter: int = -1) -> void:
	if _list == null:
		_ready()
	_target_cell = target_cell
	_target_picking = false
	_source_picking = false
	_source_first = target_cell < 0
	_directory_mode = target_cell >= 0 and source_filter < 0
	_selected_expedition = 0
	_detail_valid = false
	_preview_cache.clear()
	_quote_preview_cache.clear()
	_local_families.clear()
	_display_order.clear()
	_hover_family = ""
	_hover_timer.stop()
	_search.clear()
	_show_family_preview({})
	_family_filter = family_filter
	_source_filter = source_filter
	_sources_loaded = false
	_source_cities_identity = ""
	_source_city.clear()
	_source_city.add_item("先选择出发城市", -1)
	_source_city.disabled = true
	_selected_quote.clear()
	_quotes_identity = ""
	_expeditions_identity = ""
	_clear_list()
	_family_view_cache.clear()
	_economy_busy = false
	_title.text = "开拓"
	_subtitle.text = "按出发地选择当地家族"
	_feedback.text = ""
	visible = true
	if is_inside_tree():
		_layout_left_panel()
		UIAnimation.crossfade(self)
	# 从家族档案进来时已经锁定了出发城与家族，玩家的意图就是派遣：
	# 不能因为本国还有在途队伍就先把「在途」页签顶上来，否则被锁的家族行还不存在，
	# 面板会停在选不了任何东西的状态。
	if _controller != null and source_filter < 0:
		var page := _filter_expedition_page(_expedition_page())
		if bool(page.get("ok", false)) and int(page.get("total", 0)) > 0:
			_show_expeditions()
			return
	_show_quotes()
	_update_workflow()
	if _search.is_visible_in_tree():
		_search.grab_focus()
	else:
		(get_node("%CloseButton") as Button).grab_focus()


func _layout_left_panel() -> void:
	PlannerPresentation._layout_left_panel(self)


func _apply_narrow_density(narrow: bool) -> void:
	PlannerPresentation._apply_narrow_density(self, narrow)


func close_panel() -> void:
	if not visible:
		return
	visible = false
	_target_picking = false
	_source_picking = false
	_hover_timer.stop()
	_selected_quote.clear()
	route_cleared.emit()
	_planning_identity = ""
	planning_context_changed.emit({})
	closed.emit()


func set_feedback(message: String, ok: bool) -> void:
	set_command_result({"ok": ok, "message": message})


func set_command_result(result: Dictionary) -> void:
	var ok := bool(result.get("ok", false))
	var code := String(result.get("code", ""))
	var message := _diagnostic_message(code, String(result.get("message", "")).strip_edges())
	_feedback.text = message
	_feedback.visible = not message.is_empty()
	_feedback.tooltip_text = message
	if ok:
		_feedback.add_theme_color_override("font_color", UITokens.GOOD)
		if code == "colonization_queued" or code == "colonization_cancel_queued":
			return
		_show_expeditions()
		return
	if _transient_query_failure(code, result):
		_economy_busy = true
		_set_busy_status(true)
		_update_start_enabled()
		if message.is_empty():
			_feedback.text = "经济正在结算，提交完成后即可派遣。"
		_feedback.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
		return
	_feedback.add_theme_color_override("font_color", UITokens.RISK)
	if code == "colonization_requote_required" \
			or code == "colonization_kit_requote_required" \
			or code == "colonization_quote_expired":
		_quotes_identity = ""
		_show_quotes()


func refresh_expeditions_if_visible() -> void:
	if visible and _current_tab == "expeditions":
		_show_expeditions()


func refresh_visible() -> void:
	if not visible:
		return
	if _current_tab == "quotes":
		_preview_cache.clear()
		_quote_preview_cache.clear()
		if _economy_busy and _controller != null and _has_quote_rows():
			var probe: Dictionary = _controller.get_family_expeditions(0, 1)
			if bool(probe.get("ok", true)) and probe.has("busy") \
					and bool(probe.get("busy", false)):
				return
		_show_quotes()
		if _hover_family.is_empty():
			_show_family_preview(_selected_quote)
		else:
			_show_hover_preview()
		return
	_show_expeditions()


func _on_tab_selected(tab_id: String) -> void:
	if tab_id == "expeditions":
		_show_expeditions()
	else:
		_show_quotes()


func _load_source_cities() -> Dictionary:
	var cities := {}
	var page := _get_source_quotes()
	if not bool(page.get("ok", false)):
		return page
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var names: PackedStringArray = page.get("source_settlement_names", PackedStringArray())
	for index in range(sources.size()):
		var cell := int(sources[index])
		cities[cell] = String(names[index]) if index < names.size() else _cell_name(cell)
	var cells: Array = cities.keys()
	cells.sort()
	var parts := PackedStringArray()
	for cell in cells:
		parts.append("%d:%s" % [int(cell), String(cities[cell])])
	var identity := "|".join(parts)
	if identity != _source_cities_identity or not _sources_loaded:
		_source_cities_identity = identity
		_source_city.clear()
		_source_city.add_item("先选择出发城市", -1)
		for cell in cells:
			_source_city.add_item(String(cities[cell]), int(cell))
	_source_city.disabled = cells.is_empty()
	_sources_loaded = true
	if _directory_mode:
		if cells.size() == 1 and _selected_quote.is_empty():
			_source_filter = int(cells[0])
			_source_city.select(1)
		return page
	if _source_filter >= 0:
		var selected := _source_city.get_item_index(_source_filter)
		if selected > 0:
			_source_city.select(selected)
			return _get_source_quotes()
		_source_filter = -1
	# 只有一座城能派人时没有可选项，直接锁定它，别让玩家再点一次。
	if cells.size() == 1:
		_source_filter = int(cells[0])
		_source_city.select(1)
		return _get_source_quotes()
	_source_city.select(0)
	return page


func _on_source_city_selected(index: int) -> void:
	var source := _source_city.get_item_id(index)
	if source >= 0:
		_source_picking = false
	if source == _source_filter:
		_update_start_enabled()
		return
	_source_filter = source
	if _directory_mode:
		_selected_quote.clear()
		_detail_valid = false
		for row in _quote_row_refs.values():
			row.set_pressed_no_signal(false)
		_source_city.select(index)
		_show_family_preview({})
		_update_start_enabled()
		return
	_source_city.select(index)
	_local_families.clear()
	_preview_cache.clear()
	_display_order.clear()
	_show_family_preview({})
	_selected_quote.clear()
	_quotes_identity = ""
	_feedback.text = ""
	_clear_list()
	route_cleared.emit()
	_show_quotes()


func _show_quotes() -> void:
	_current_tab = "quotes"
	if _tabs != null:
		_tabs.select_tab("quotes")
	_discard_expedition_rows()
	if _controller == null:
		_clear_list()
		_quotes_identity = ""
		_set_busy_status(false)
		_add_note("玩家控制器尚未就绪。", UITokens.RISK)
		_update_start_enabled()
		return
	if _target_cell < 0:
		_show_source_families()
		return
	var page: Dictionary
	if not _sources_loaded or _directory_mode or _source_filter < 0:
		page = _load_source_cities()
	else:
		page = _get_source_quotes()
	_economy_busy = bool(page.get("busy", false))
	if not bool(page.get("ok", false)):
		var code := String(page.get("code", "command_rejected"))
		if _transient_query_failure(code, page):
			_economy_busy = true
			_set_busy_status(true)
			if _has_quote_rows():
				_update_start_enabled()
				return
			_clear_list()
			_quotes_identity = ""
			_add_note("正在等待经济提交完成后显示可派遣家族。", UITokens.ARCHIVE_INK_MUTED)
			_update_start_enabled()
			return
		_clear_list()
		_quotes_identity = ""
		_selected_quote.clear()
		_set_busy_status(_economy_busy)
		_add_note(_reason_text(code), UITokens.RISK)
		_update_start_enabled()
		return
	if _source_filter < 0 and not _directory_mode:
		_clear_list()
		_selected_quote.clear()
		_apply_kind(String(page.get("kind", "colonize")))
		_set_busy_status(_economy_busy)
		if _source_city.item_count > 1:
			_add_note("请选择出发城市，然后选择该城要派遣的家族。", UITokens.ARCHIVE_INK_MUTED)
		elif _economy_busy:
			_sources_loaded = false
			_add_note("经济正在结算，提交后刷新可派遣的城市与家族。", UITokens.ARCHIVE_INK_MUTED)
		elif int(page.get("total", 0)) <= 0:
			# 城市列表为空不是「没有家族」，而是没有城市能连通这个目标：
			# 水面在拓扑里不可走，只能靠航道门户跳跃，缺科技时整片水就是墙。
			_add_note(ROUTE_UNREACHABLE_NOTE, UITokens.WARN)
		else:
			_add_note("可派遣城市：无", UITokens.WARN)
		_update_start_enabled()
		return
	_local_families.clear()
	if _directory_mode:
		for index in range(1, _source_city.item_count):
			_load_local_families(_source_city.get_item_id(index))
	else:
		_load_local_families()
	var identity := _quotes_identity_of(page) + str(_local_families.hash())
	if identity == _quotes_identity and _has_quote_rows():
		_apply_kind(String(page.get("kind", "colonize")))
		_set_busy_status(_economy_busy)
		_refresh_selected_kit()
		return
	_quotes_identity = identity
	_apply_kind(String(page.get("kind", "colonize")))
	_set_busy_status(_economy_busy)
	var quotes := _quotes_for_source(page)
	var keep_population := int(_population.value) if not _selected_quote.is_empty() else 0
	var restored := _sync_quote_rows(quotes, keep_population)
	if not restored:
		_selected_quote.clear()
		_detail_valid = false
		_show_family_preview({})
		route_cleared.emit()
	if quotes.is_empty():
		_clear_list()
		if _economy_busy:
			_add_note("经济正在结算。家族列表将在提交后刷新，也可先查看在途队伍。",
				UITokens.ARCHIVE_INK_MUTED)
		elif int(page.get("total", 0)) <= 0 and _source_city.item_count <= 1:
			# 全国都没城市能到达：换出发城市没有意义，直接点出航道门槛。
			_add_note(ROUTE_UNREACHABLE_NOTE, UITokens.WARN)
		else:
			_add_note("可派遣家族：无", UITokens.WARN)
	if restored:
		_refresh_selected_kit()
	else:
		_update_start_enabled()


func _sync_quote_rows(quotes: Array, keep_population: int) -> bool:
	return PlannerPresentation._sync_quote_rows(self, quotes, keep_population)


func _on_reusable_quote_pressed(row: Button) -> void:
	var quote: Dictionary = row.get_meta("quote", {})
	if quote.is_empty():
		return
	_on_quote_row_pressed(quote, row)


func _on_quote_row_pressed(quote: Dictionary, row: Button) -> void:
	for child in _list.get_children():
		if child is Button and child != row:
			(child as Button).set_pressed_no_signal(false)
	row.set_pressed_no_signal(true)
	_select_quote(quote)


func _select_quote(quote: Dictionary) -> void:
	_hover_family = ""
	_hover_timer.stop()
	_feedback.text = ""
	_selected_quote = quote.duplicate(true)
	_source_filter = int(quote.get("source_cell", _source_filter))
	var source_index := _source_city.get_item_index(_source_filter)
	if source_index >= 0:
		_source_city.select(source_index)
	_detail_valid = false
	var maximum := maxi(1, int(quote.get("maximum_population", 1)))
	_population.max_value = maximum
	_population.set_value_no_signal(maximum)
	_show_family_preview(quote)
	_refresh_selected_kit()


func _submit_selected() -> void:
	if _selected_quote.is_empty() or _start.disabled:
		return
	start_requested.emit({
		"family_handle": int(_selected_quote.get("family_handle", 0)),
		"source_cell": int(_selected_quote.get("source_cell", 0)),
		"target_cell": int(_selected_quote.get("target_cell", 0)),
		"population": int(_population.value),
		"quote_token": int(_selected_quote.get("quote_token", 0)),
	})


func _show_expeditions() -> void:
	PlannerPresentation._show_expeditions(self)


func _filter_expedition_page(page: Dictionary) -> Dictionary:
	# The native query is country-wide. Keep the planner scoped to the target
	# currently open, and to the selected family when the panel was opened from
	# a family dossier.
	var targets: PackedInt32Array = page.get("target_cells", PackedInt32Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	if targets.is_empty() or (_target_cell < 0 and _family_filter == 0):
		return page
	var keep := PackedInt32Array()
	for index in range(handles.size()):
		var target_ok := _target_cell < 0 or \
			(index < targets.size() and int(targets[index]) == _target_cell)
		var family_ok := _family_filter == 0 or \
			(index < families.size() and int(families[index]) == _family_filter)
		if target_ok and family_ok:
			keep.append(index)
	var filtered := page.duplicate()
	for key in [&"expedition_handles", &"family_handles", &"source_cells",
			&"target_cells", &"populations", &"departure_days", &"due_days",
			&"route_costs", &"states", &"kit_missing_stock_identities"]:
		var values: Variant = page.get(key, null)
		if values == null:
			continue
		var rebuilt = values.duplicate()
		rebuilt.clear()
		for source_index in keep:
			if source_index < values.size():
				rebuilt.append(values[source_index])
		filtered[key] = rebuilt
	filtered["total"] = keep.size()
	filtered["has_more"] = false
	return filtered


func _sync_expedition_rows(page: Dictionary) -> void:
	PlannerPresentation._sync_expedition_rows(self, page)


func _on_reusable_expedition_pressed(row: Button) -> void:
	_selected_expedition = int(row.get_meta("expedition_handle", 0))
	_refresh_expedition_detail()
	expedition_selected.emit(_selected_expedition)


func open_expeditions() -> void:
	open_target(-1)
	_show_expeditions()


func _expedition_page() -> Dictionary:
	var page: Dictionary = _controller.get_family_expeditions(0, 128)
	var offset := (page.get("expedition_handles", PackedInt64Array()) as PackedInt64Array).size()
	while bool(page.get("ok", false)) and bool(page.get("has_more", false)) and offset > 0:
		var next: Dictionary = _controller.get_family_expeditions(offset, 128)
		if not bool(next.get("ok", false)):
			return next
		var handles: PackedInt64Array = next.get("expedition_handles", PackedInt64Array())
		if handles.is_empty():
			break
		for key in ["expedition_handles", "family_handles", "source_cells", "target_cells",
				"populations", "departure_days", "due_days", "route_costs", "states", "kit_missing_stock_identities"]:
			if page.has(key) and next.has(key):
				var values: Variant = page[key]
				values.append_array(next[key])
				page[key] = values
		offset += handles.size()
		page["has_more"] = bool(next.get("has_more", false))
	return page


func _refresh_expedition_detail() -> void:
	PlannerPresentation._refresh_expedition_detail(self)


func _clear_list() -> void:
	_hover_family = ""
	_hover_timer.stop()
	_quote_row_refs.clear()
	_source_headers.clear()
	_display_order.clear()
	_expedition_row_refs.clear()
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()


func _discard_quote_rows() -> void:
	for row_value in _quote_row_refs.values():
		var row := row_value as Node
		if row != null and is_instance_valid(row):
			_list.remove_child(row)
			row.queue_free()
	_quote_row_refs.clear()
	_display_order.clear()
	for header in _source_headers.values():
		header.queue_free()
	_source_headers.clear()


func _discard_expedition_rows() -> void:
	for row_value in _expedition_row_refs.values():
		var row := row_value as Node
		if row != null and is_instance_valid(row):
			_list.remove_child(row)
			row.queue_free()
	_expedition_row_refs.clear()


func _remove_note_children() -> void:
	if _list == null:
		return
	for child in _list.get_children():
		if child is Label and not child.has_meta("source_header"):
			_list.remove_child(child)
			child.queue_free()


func _add_note(text: String, color: Color) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", color)
	_list.add_child(label)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# 右键是地图平移键（MapCamera.pan_button），这里绝不能吃它，
	# 否则一边看选点一遍拖视角就会把面板关掉。
	if not (event is InputEventKey) or not event.pressed or event.echo \
			or event.keycode != KEY_ESCAPE:
		return
	if _source_picking:
		cancel_source_selection()
	elif _target_picking:
		cancel_target_selection()
	else:
		close_panel()
	get_viewport().set_input_as_handled()


static func _state_text(state: int) -> String:
	return {1: "前往中", 2: "落地结算中", 3: "返程中", 4: "筹备中"}.get(state, "未知")


## 原生有些失败会把具体原因写进 `message` 而不是 `code`
## （`colonization_requote_required` + `message="colonization_route_unreachable"`）。
## 把裸错误码贴进反馈栏比不给理由更糟，这里统一先按错误码翻一遍。
static func _diagnostic_message(code: String, raw_message: String) -> String:
	var raw := raw_message.strip_edges()
	if raw.begins_with("colonization_") or raw.begins_with("PREPARING_"):
		return _reason_text(raw)
	if not raw.is_empty():
		return raw
	return _reason_text(code) if not code.is_empty() else ""


static func _reason_text(code: String) -> String:
	return {
		"colonization_target_invalid": "目标必须是当前可见、可通行的无主或本国陆地。",
		"colonization_route_unreachable": ROUTE_BLOCKED_SHORT + ROUTE_WATER_HINT,
		"colonization_route_not_passable": "目标或途经地块不可通行：" + ROUTE_WATER_HINT,
		"colonization_route_not_visible": "路线经过尚未探索的地块，请先扩大视野。",
		"colonization_route_territory_invalid": "路线会经过他国领土，无法通行。",
		"colonization_route_water_invalid": "水域航道无法还原，请重新选择目的地。",
		"colonization_route_expansion_limit": "目标过远，路线搜索超出预算，请选择更近的目的地。",
		"colonization_population_insufficient": "源分支人口不足，必须至少留下一人。",
		"colonization_duplicate_target": "本国已有一支开拓队前往该目标。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"colonization_kit_requote_required": "目标资源或科技已经变化，请重新确认开工包。",
		"colonization_kit_materials_short": "源地市场库存不足，无法抽出开工包物资。",
		"colonization_preparing": "开拓队已开始筹备，人仍留在源地生产缺货物资。",
		"colonization_cancelled": "开拓筹备已取消，目标占用已释放。",
		"PREPARING_UNBUILDABLE": "源地无法获得开工包所需建材，筹备已中止，托管物资已退回。",
		"PREPARING_ABORTED": "源分支人口已不足，开拓筹备中止。",
		"colonization_quote_expired": "报价已过期，请重新选择要派遣的家族。",
		"colonization_quote_corrupt": "报价数据已失效，请重新打开开拓面板。",
		"colonization_quote_forbidden": "报价不属于玩家国家。",
		"colonization_command_invalid": "开拓命令参数不完整。",
		"colonization_country_snapshot_unavailable": "国家快照尚未就绪，请稍后再试。",
		"colonization_country_invalid": "玩家国家句柄无效。",
		"family_colonization_unavailable": "开拓报价接口尚未就绪。",
		"colonization_family_cell_capacity": "目标地块的家族数量已达上限。",
		"economy_busy_retry": "经济正在结算。派遣已可排队，提交完成后自动出发。",
		"colonization_queued": "派遣已排队，将在经济结算完成后出发。",
		"colonization_cancel_queued": "取消已排队，将在经济结算完成后执行。",
		"colonization_started": "开拓队已经出发。",
		"economy_paused": "经济已因守恒失败暂停，无法派遣。",
		"economy_not_available": "经济运行时尚未就绪。",
		"colonization_topology_not_ready": "地图通行数据尚未就绪。",
		"colonization_visibility_unavailable": "当前视野数据不可用。",
		"colonization_expedition_invalid": "开拓队已结束或句柄已过期。",
	}.get(code, "当前无法执行开拓。")


func _apply_kind(kind: String) -> void:
	_title.text = "迁徙" if kind == "relocate" else "开拓"
	if _header_icon != null:
		_header_icon.set_semantic(
			&"metric.territory" if kind == "relocate" else &"family.house",
			UITokens.DOSSIER_OXBLOOD)
	_update_workflow()


func _set_busy_status(busy: bool) -> void:
	if _status == null:
		return
	_status.visible = busy
	_status.text = "结算中 · 派遣与取消将排队执行" if busy else ""
	_status.tooltip_text = "经济正在结算，提交完成后自动执行排队命令。"
	_status.add_theme_color_override("font_color", UITokens.WARN)


func _refresh_selected_kit() -> void:
	if _selected_quote.is_empty():
		_update_start_enabled()
		return
	if int(_selected_quote.get("quote_token", 0)) <= 0 or _target_cell < 0:
		_update_start_enabled()
		return
	var detail: Dictionary = {}
	if _controller != null:
		detail = _controller.get_family_colonization_quote_detail(
			int(_selected_quote.get("quote_token", 0)), int(_population.value))
	_economy_busy = _economy_busy or bool(detail.get("busy", false))
	if not bool(detail.get("ok", false)):
		_detail_valid = _transient_query_failure(String(detail.get("code", "")), detail)
		_update_start_enabled()
		var detail_code := String(detail.get("code", "command_rejected"))
		if _transient_query_failure(detail_code, detail):
			_feedback.text = "经济正在结算，提交完成后即可派遣。"
			_feedback.add_theme_color_override("font_color", UITokens.ARCHIVE_INK_MUTED)
			return
		_feedback.text = _reason_text(detail_code)
		_feedback.visible = true
		_feedback.add_theme_color_override("font_color", UITokens.RISK)
		return
	_detail_valid = true
	_selected_quote.merge(detail, true)
	_update_start_enabled()
	if _hover_family.is_empty():
		_update_preview_route(_selected_quote)
	route_requested.emit(detail)


func _update_start_enabled() -> void:
	if _start == null:
		return
	var on_quotes := _current_tab == "quotes"
	_expedition_cancel.visible = not on_quotes and _expedition_row_refs.has(_selected_expedition)
	_footer_selection.visible = false
	_source_city.get_parent().visible = false
	_search.get_parent().visible = on_quotes
	_target_button.visible = on_quotes
	if _route_stepper != null:
		_route_stepper.visible = on_quotes
	_sync_population_slider()
	_update_workflow()
	var has_selection := not _selected_quote.is_empty()
	_population_row.visible = on_quotes and has_selection
	_start.visible = on_quotes
	_start.disabled = not has_selection or _target_cell < 0 or _target_picking \
		or int(_selected_quote.get("quote_token", 0)) <= 0 or not _detail_valid \
		or int(_population.value) > int(_selected_quote.get("maximum_population", 1))
	var count := int(_population.value) if has_selection else 0
	var count_text := UITokens.format_compact_number_cn(float(count), 0)
	var kit_partial := bool(_selected_quote.get("kit_partial", false))
	var place_buildings := bool(_selected_quote.get("kit_place_buildings", false))
	var kit_ids: PackedInt32Array = _selected_quote.get(
		"kit_building_ids", PackedInt32Array())
	var complete_kit := place_buildings and not kit_partial and not kit_ids.is_empty()
	var preparing_kit := place_buildings and (kit_partial or kit_ids.is_empty())
	if _target_cell < 0 or _target_picking:
		_start.text = "请先选择目的地"
	elif _economy_busy:
		_start.text = "排队派遣 %s 人" % count_text if has_selection else "排队派遣"
		_start.tooltip_text = "经济正在结算。现在确认后会排队，提交完成后自动出发。"
	elif complete_kit:
		_start.text = "派遣 %s 人并安家" % count_text if has_selection else "确认派遣"
		_start.tooltip_text = _kit_summary_text(_selected_quote)
	elif preparing_kit:
		_start.text = "开始筹备 %s 人" % count_text if has_selection else "开始筹备"
		_start.tooltip_text = "占用目标；人留在源地继续生产，每日把源地可用现货收进队伍库存，凑齐后自动出发。"
	else:
		_start.text = "派遣 %s 人" % count_text if has_selection else "确认派遣"
		_start.tooltip_text = "基础物资不足，只携带当前可用物资" if kit_partial \
			else _kit_summary_text(_selected_quote)
	if has_selection and kit_partial and not preparing_kit \
			and not _economy_busy \
			and _feedback.text.find("排队") < 0 \
			and _feedback.text.find("已经出发") < 0:
		_feedback.text = "基础物资不足，只携带当前可用物资"
		_feedback.add_theme_color_override("font_color", UITokens.WARN)
	_feedback.visible = not _feedback.text.is_empty()
	_feedback.tooltip_text = _feedback.text


static func _transient_query_failure(code: String, page: Dictionary) -> bool:
	if bool(page.get("fatal", false)) or code == "economy_paused":
		return false
	if code == "economy_busy_retry":
		return true
	if code == "economy_not_available":
		return bool(page.get("busy", false))
	if not bool(page.get("busy", false)):
		return false
	return code == "colonization_topology_not_ready" \
		or code == "colonization_visibility_unavailable"


func _has_quote_rows() -> bool:
	for row_value in _quote_row_refs.values():
		if row_value != null and is_instance_valid(row_value):
			return true
	return false


func _has_expedition_rows() -> bool:
	for row_value in _expedition_row_refs.values():
		if row_value != null and is_instance_valid(row_value):
			return true
	return false


static func _quotes_identity_of(page: Dictionary) -> String:
	var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
	var parts := PackedStringArray()
	for token in tokens:
		parts.append(str(int(token)))
	return "%s|%s|%s" % [int(page.get("total", 0)),
		String(page.get("kind", "")), ",".join(parts)]


static func _expeditions_identity_of(page: Dictionary) -> String:
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	var due_days: PackedInt64Array = page.get("due_days", PackedInt64Array())
	var parts := PackedStringArray()
	for index in range(handles.size()):
		var state := int(states[index]) if index < states.size() else 0
		var missing := 0
		var identities: PackedInt64Array = page.get(
			"kit_missing_stock_identities", PackedInt64Array())
		if index < identities.size():
			missing = int(identities[index])
		# A pending purchase can advance without changing stock or party state.
		# The next preparation retry must refresh its tooltip as well.
		var due := int(due_days[index]) if index < due_days.size() else -1
		parts.append("%d:%d:%d:%d" % [int(handles[index]), state, missing, due])
	return "%s|%s" % [int(page.get("total", 0)), ",".join(parts)]




func _preparing_missing_text(handle: int, state: int, snapshot: Dictionary = {}, include_progress: bool = true) -> String:
	if state != 4 or _controller == null or not _controller.has_method(
			"get_family_expedition_snapshot"):
		return ""
	var snap := snapshot
	if snap.is_empty():
		snap = _controller.get_family_expedition_snapshot(handle)
	if not bool(snap.get("ok", false)):
		return ""
	var lines := PackedStringArray()
	# The party only leaves once both the survival bridge and the whole opening
	# build plan are funded, so a single percentage has to cover both. Showing
	# the bridge alone is what used to read 100% while the kit was still short.
	var bridge_required := int(snap.get("kit_bridge_required_units", 0))
	var bridge_missing := int(snap.get("kit_bridge_missing_units", 0))
	var material_required := int(snap.get("kit_material_required_units", 0))
	var material_missing := int(snap.get("kit_material_missing_units", 0))
	var required := bridge_required + material_required
	var missing := bridge_missing + material_missing
	if required > 0 and include_progress:
		lines.append("已囤积 %d%%（补给 %d%% / 建材 %d%%），每日自动收进源地可用现货" % [
			clampi(required - missing, 0, required) * 100 / required,
			_stock_percent(bridge_required, bridge_missing),
			_stock_percent(material_required, material_missing)])
	var blocker := String(snap.get("kit_blocker", ""))
	match blocker:
		"UNBUILDABLE":
			lines.append("源地无法获得开工包所需的某组建材，筹备将中止并退回托管物资")
		"NO_BUILDINGS":
			lines.append("目标地块放不下任何开工建筑，筹备无法完成")
		"READY":
			lines.append("开工包已齐套，等待出发")
		"BRIDGE":
			lines.append("仍缺旅途补给（食品、衣物或必需工具），等源地备货")
		"MATERIALS":
			lines.append("仍缺开工建材，等源地产出")
		"INCOMPLETE":
			lines.append("开工包尚未凑齐可出发的完整方案，等源地备货")
	var procurement := _procurement_status_text(snap)
	if not procurement.is_empty():
		lines.append(procurement)
	var ids: PackedInt32Array = snap.get("kit_missing_good_ids", PackedInt32Array())
	var qtys: PackedInt64Array = snap.get(
		"kit_missing_good_quantities", PackedInt64Array())
	if not ids.is_empty():
		var parts := PackedStringArray()
		for i in range(ids.size()):
			var qty := int(qtys[i]) if i < qtys.size() else 0
			var good_name := "物资#%d" % int(ids[i])
			if _controller.has_method("good_display_name"):
				good_name = String(_controller.good_display_name(int(ids[i])))
			parts.append("%s %s 件" % [good_name,
				UITokens.format_compact_number_cn(float(qty) / 1000.0, 1)])
		lines.append("可用替代物资与源地现货：" + "，".join(parts))
	return "\n".join(lines)


func _procurement_status_text(snap: Dictionary) -> String:
	if bool(snap.get("kit_procurement_blocked_by_peer", false)):
		return "等待另一支开拓队的国库采购完成"
	if bool(snap.get("kit_procurement_pending", false)):
		return "正在用国库采购%s（第 %d 日开始）" % [
			_good_name(int(snap.get("kit_procurement_good_id", -1))),
			int(snap.get("kit_procurement_started_day", -1))]
	var reason := String(snap.get("kit_procurement_rejection", ""))
	if reason.is_empty():
		return ""
	return "第 %d 日采购%s被拒：%s" % [
		int(snap.get("kit_procurement_rejected_day", -1)),
		_good_name(int(snap.get("kit_procurement_rejected_good_id", -1))),
		_procurement_reason_text(reason)]


func _good_name(good_id: int) -> String:
	if good_id < 0:
		return ""
	if _controller != null and _controller.has_method("good_display_name"):
		return String(_controller.good_display_name(good_id))
	return "物资#%d" % good_id


static func _procurement_reason_text(reason: String) -> String:
	if reason.find("cash_insufficient") >= 0:
		return "国库现金不足"
	if reason.find("stock_insufficient") >= 0 or reason.find("goods_insufficient") >= 0 \
			or reason.find("stock_drift") >= 0:
		return "源地库存在成交前已被消耗"
	if reason.find("gate_closed") >= 0:
		return "国家资产通道未开放"
	if reason.find("merchant_missing") >= 0:
		return "源地没有可收款的商人"
	return reason


static func _stock_percent(required: int, missing: int) -> int:
	if required <= 0:
		return 100
	return clampi(required - missing, 0, required) * 100 / required


func _expedition_row_tooltip(handle: int, state: int, due_day: int) -> String:
	var missing := _preparing_missing_text(handle, state)
	if not missing.is_empty():
		return missing
	if due_day >= 0:
		return "第 %d 日抵达" % due_day
	return ""

func _quotes_for_source(page: Dictionary) -> Array:
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var maximums: PackedInt64Array = page.get("maximum_populations", PackedInt64Array())
	var costs: PackedInt32Array = page.get("route_costs", PackedInt32Array())
	var days: PackedInt32Array = page.get("travel_days", PackedInt32Array())
	var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
	var surnames: PackedStringArray = page.get("surnames", PackedStringArray())
	var disambiguators: PackedInt32Array = page.get(
		"surname_disambiguators", PackedInt32Array())
	var quotes: Array = []
	for index in range(families.size()):
		if index >= sources.size() or (not _directory_mode and int(sources[index]) != _source_filter):
			continue
		var handle := int(families[index])
		var surname := String(surnames[index]) if index < surnames.size() else "家族"
		var disambiguator := int(disambiguators[index]) if index < disambiguators.size() else 0
		var candidate := {
			"family_handle": handle,
			"source_cell": int(sources[index]) if index < sources.size() else 0,
			"target_cell": _target_cell,
			"maximum_population": int(maximums[index]) if index < maximums.size() else 0,
			"route_cost": int(costs[index]) if index < costs.size() else 0,
			"travel_days": int(days[index]) if index < days.size() else 1,
			"quote_token": int(tokens[index]) if index < tokens.size() else 0,
			"surname": surname,
			"display_name": _family_display_name(surname, disambiguator),
		}
		quotes.append(candidate)
	quotes.sort_custom(func(a, b) -> bool:
		return String(a.get("display_name", "")) < String(b.get("display_name", "")))
	return quotes


static func _family_display_name(surname: String, disambiguator: int) -> String:
	var stem := surname if not surname.is_empty() else "家族"
	if stem.ends_with("氏"):
		pass
	elif stem != "家族":
		stem = "%s氏" % stem
	if disambiguator > 0:
		return "%s（%d）" % [stem, disambiguator + 1]
	return stem


static func _kit_summary_text(quote: Dictionary) -> String:
	var names: PackedStringArray = quote.get(
		"kit_building_display_names", quote.get("kit_building_stable_ids", PackedStringArray()))
	var counts: PackedInt64Array = quote.get(
		"kit_building_counts", PackedInt64Array())
	if names.is_empty():
		return ""
	var parts := PackedStringArray()
	for index in range(names.size()):
		var label := String(names[index]).strip_edges()
		if label.is_empty():
			continue
		var count := int(counts[index]) if index < counts.size() else 1
		parts.append("%s×%d" % [label, count])
	return "开工包：%s" % "、".join(parts) if not parts.is_empty() else ""


func _family_view_for(family_handle: int, fallback_people: int) -> Dictionary:
	if _family_view_cache.has(family_handle):
		return _family_view_cache[family_handle]
	var view := {
		"family_population": maxi(0, fallback_people),
		"trait_badges": [],
		"effect_text": "特性：无",
	}
	if _controller != null and _controller.has_method("get_family_snapshot"):
		var snapshot: Dictionary = _controller.get_family_snapshot(family_handle)
		if bool(snapshot.get("ok", false)):
			view["family_population"] = int(snapshot.get("population",
				view.family_population))
			var family_name := String(snapshot.get("family_name", "")).strip_edges()
			var surname := String(snapshot.get("surname", ""))
			var disambiguator := int(snapshot.get("surname_disambiguator", 0))
			if not family_name.is_empty():
				view["display_name"] = family_name
			elif not surname.is_empty():
				view["display_name"] = _family_display_name(surname, disambiguator)
	if int(view.family_population) <= 0:
		view["family_population"] = maxi(0, fallback_people)
	_family_view_cache[family_handle] = view
	return view


func open_source(source_cell: int, family_handle: int) -> void:
	open_target(-1, 0, source_cell)
	var row := _quote_row_refs.get(_quote_key({"source_cell": source_cell, "family_handle": family_handle})) as Button
	if row != null and not row.disabled:
		_on_reusable_quote_pressed(row)
		_scroll_to_pinned_family()
		begin_target_selection()
	else:
		_feedback.text = "该城分支已无法派遣，请重新选择家族。"
		_feedback.visible = true


func _scroll_to_pinned_family() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	var row := _quote_row_refs.get(_quote_key(_selected_quote)) as Control
	if visible and row != null:
		(get_node("%RowsScroll") as ScrollContainer).ensure_control_visible(row)


func begin_target_selection() -> void:
	_source_picking = false
	_target_picking = true
	_update_start_enabled()
	target_selection_requested.emit()


func cancel_target_selection() -> void:
	_target_picking = false
	_update_start_enabled()


func is_target_picking() -> bool:
	return visible and _target_picking


func begin_source_selection() -> void:
	if _source_first or _source_picking:
		return
	_target_picking = false
	_source_picking = true
	_update_start_enabled()
	source_selection_requested.emit()


func cancel_source_selection() -> void:
	_source_picking = false
	_update_start_enabled()


func is_source_picking() -> bool:
	return visible and _source_picking


## 当前这次地图点按该落到哪一步。派发界面不再要求玩家先按“选点按钮”进入模式：
## 没定出发城就落到出发城，定了出发城就落到目的地。
func map_stage() -> StringName:
	if _target_picking:
		return &"target"
	if _source_picking:
		return &"source"
	if _source_first:
		return &"target"
	return &"source" if _source_filter < 0 else &"target"


## 地图左键点选的唯一入口：面板可见时每一步都直接吃地图点击。
## 返回 true 表示这次点按已被派发界面消费（调用方不应再打开地块档案）。
func handle_map_cell(cell: int) -> bool:
	if not visible or cell < 0 or _current_tab != "quotes":
		return false
	if map_stage() == &"source":
		if _select_source_cell(cell):
			return true
		# 不是可派遣城市：把这次点按当成“改目的地”，
		# 省掉“先按按钮才能在地图上选点”的往返。
		if try_target_cell(cell, true):
			return true
		_set_feedback_line("点地图上的青绿环换出发城；点可见空地改目的地。", UITokens.RISK)
		return false
	if try_target_cell(cell):
		return true
	# 目的地不合法，但这格本身是另一个候选出发城 —— 玩家要点的是出发地。
	if not _source_first and cell != _source_filter and _select_source_cell(cell):
		_set_feedback_line("已把出发城改为 %s。" % _cell_name(_source_filter),
			UITokens.ARCHIVE_INK_MUTED)
		return true
	return false


func _select_source_cell(cell: int) -> bool:
	if _source_city == null or cell < 0:
		return false
	var index := _source_city.get_item_index(cell)
	if index <= 0:
		return false
	_source_picking = false
	_source_city.select(index)
	_on_source_city_selected(index)
	_update_start_enabled()
	return true


func try_target_cell(cell: int, quiet: bool = false) -> bool:
	if _controller == null or cell < 0:
		return false
	var family := int(_selected_quote.get("family_handle", 0))
	var page: Dictionary = _controller.get_family_colonization_quotes(cell, family, _source_filter, 0, 256)
	if not bool(page.get("ok", false)):
		if not quiet:
			_set_feedback_line(_reason_text(String(page.get("code", "colonization_target_invalid"))),
				UITokens.RISK)
		return false
	if family > 0 and int(page.get("total", 0)) <= 0:
		if not quiet:
			# total 为 0 有两种完全不同的原因：全国无路可达（水域或不可通行
			# 地形隔断），或这条路线不收这个家族。补一条「不限城市、不限家族」
			# 的报价就能分开；只有失败路径才会多发这一次查询。
			if _any_source_reaches(cell):
				_set_feedback_line("该家族当前无法从此城前往此地，请选择其他目的地。",
					UITokens.RISK)
			else:
				_set_feedback_line(ROUTE_BLOCKED_SHORT, UITokens.RISK,
					_reason_text("colonization_route_unreachable"))
		return false
	_target_cell = cell
	_target_picking = false
	_sources_loaded = false
	_quotes_identity = ""
	_feedback.text = ""
	_show_quotes()
	_update_start_enabled()
	return true


func _any_source_reaches(cell: int) -> bool:
	var probe: Dictionary = _controller.get_family_colonization_quotes(cell, 0, -1, 0, 1)
	# 查询本身失败（结算中、快照未就绪）时不要断言「无路可走」，
	# 回退到不指明原因的家族文案。
	if not bool(probe.get("ok", true)):
		return true
	return int(probe.get("total", 0)) > 0


func _set_feedback_line(message: String, color: Color, tooltip: String = "") -> void:
	_feedback.text = message
	_feedback.visible = not message.is_empty()
	_feedback.tooltip_text = tooltip if not tooltip.is_empty() else message
	_feedback.add_theme_color_override("font_color", color)


func _cell_name(cell: int) -> String:
	if cell < 0:
		return "待选目的地"
	if _controller != null and _controller.has_method("dispatch_cell_display_name"):
		return String(_controller.dispatch_cell_display_name(cell))
	return "地块 %d" % (cell + 1)


func _update_workflow() -> void:
	if _workflow == null:
		return
	var source := _source_city.text if _source_filter >= 0 else "待选城市"
	var family := String(_selected_quote.get("display_name", "待选家族"))
	_workflow.text = "%s → %s → %s" % [source, family, _cell_name(_target_cell)]
	_footer_selection.text = "已选：%s" % family if not _selected_quote.is_empty() else "点击家族确定派遣对象"
	_subtitle.text = _stage_hint()
	_subtitle.visible = _current_tab == "quotes"
	# 目的地这一格显示真实地名：点地图能改，但玩家首先要能确认「现在打的是哪」。
	_target_button.text = "正在选点" if _target_picking else (
		_cell_name(_target_cell) if _target_cell >= 0 else "点地图选目的地")
	_target_button.tooltip_text = "正在选点：点地图上的任意地块，Esc 退出" \
		if _target_picking else "点地图上的任意地块即可改目的地"
	_refresh_route_stepper(source, family)
	_refresh_city_cards()
	_publish_planning_context()


## 地图当前在听哪一步，就用一句话说清楚，玩家不必猜“要不要先按按钮”。
func _stage_hint() -> String:
	if _current_tab != "quotes":
		return ""
	if _source_picking:
		return "点地图上的青绿环换出发城 · Esc 退出选点"
	if _target_picking:
		return "点地图上任意地块选目的地 · Esc 退出选点"
	if _source_first:
		return "直接点地图上任意地块选目的地"
	if _directory_mode and _selected_quote.is_empty():
		return "从左侧按出发地选择家族，再确定派遣人数"
	if _source_filter < 0:
		return "点地图上的青绿环选出发城"
	if _selected_quote.is_empty():
		return "直接点地图上任意地块改目的地，再从左侧挑选家族"
	return "出发城与家族已就绪：直接点地图上任意地块改目的地"



func _load_local_families(source_cell: int = -1) -> Dictionary:
	if source_cell < 0:
		source_cell = _source_filter
	if source_cell < 0 or _controller == null or not _controller.has_method("get_family_dispatch_candidates"):
		return {"ok": true}
	var rebuilt := {}
	var offset := 0
	while true:
		var page: Dictionary = _controller.get_family_dispatch_candidates(source_cell, offset, 256)
		if not bool(page.get("ok", false)):
			return page
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		for index in range(handles.size()):
			var data := {"family_handle": int(handles[index]), "source_cell": source_cell,
				"target_cell": _target_cell, "quote_token": 0}
			for pair in [["family_names", "display_name"], ["populations", "population"],
					["cash_claims", "cash_claim"], ["owned_buildings", "owned_buildings"], ["prestige_levels", "prestige_level"]]:
				var values: Variant = page.get(pair[0], [])
				if index < values.size():
					data[pair[1]] = values[index]
			data["maximum_population"] = maxi(0, int(data.get("population", 0)) - 1)
			rebuilt[_quote_key(data)] = data
		if not bool(page.get("has_more", false)) or handles.is_empty():
			break
		offset += handles.size()
	for key in _local_families.keys():
		if int(_local_families[key].get("source_cell", -1)) == source_cell:
			_local_families.erase(key)
	_local_families.merge(rebuilt, true)
	return {"ok": true}


func _get_source_quotes() -> Dictionary:
	var source := -1 if _directory_mode else _source_filter
	var page: Dictionary = _controller.get_family_colonization_quotes(
		_target_cell, _family_filter, source, 0, 256)
	var offset := (page.get("family_handles", PackedInt64Array()) as PackedInt64Array).size()
	while bool(page.get("ok", false)) and bool(page.get("has_more", false)) and offset > 0:
		var next: Dictionary = _controller.get_family_colonization_quotes(
			_target_cell, _family_filter, source, offset, 256)
		if not bool(next.get("ok", false)):
			return next
		var handles: PackedInt64Array = next.get("family_handles", PackedInt64Array())
		if handles.is_empty():
			break
		for key in ["family_handles", "source_cells", "maximum_populations", "route_costs",
				"travel_days", "quote_tokens", "surnames", "surname_disambiguators", "source_settlement_names"]:
			if page.has(key) and next.has(key):
				var values: Variant = page[key]
				values.append_array(next[key])
				page[key] = values
		offset += handles.size()
		page["has_more"] = bool(next.get("has_more", false))
	return page


func _show_source_families() -> void:
	_title.text = "家族派遣"
	if _source_city.item_count == 1:
		_source_city.add_item(_cell_name(_source_filter), _source_filter)
		_source_city.select(1)
	_source_city.disabled = true
	var page := _load_local_families()
	if not bool(page.get("ok", false)):
		_selected_quote.clear()
		_clear_list()
		_add_note(String(page.get("message", "当地家族暂不可用。")), UITokens.RISK)
	else:
		var restored := _sync_quote_rows(_local_families.values(), int(_population.value))
		if not restored:
			_selected_quote.clear()
			_show_family_preview({})
	_update_start_enabled()


static func _quote_key(quote: Dictionary) -> String:
	return "%d:%d" % [int(quote.get("source_cell", -1)), int(quote.get("family_handle", 0))]


func _apply_list_filter_sort() -> void:
	if _current_tab != "quotes":
		return
	var added: Array = []
	for key in _quote_row_refs:
		if not _display_order.has(key):
			added.append(key)
	added.sort_custom(func(a, b) -> bool:
		var left: Dictionary = _quote_row_refs[a].get_meta("quote", {})
		var right: Dictionary = _quote_row_refs[b].get_meta("quote", {})
		var field := "prestige_level" if _sort.selected == 1 else "maximum_population"
		if _sort.selected < 2 and int(left.get(field, 0)) != int(right.get(field, 0)):
			return int(left.get(field, 0)) > int(right.get(field, 0))
		return String(left.get("display_name", "")) < String(right.get("display_name", "")))
	_display_order.append_array(added)
	var query := _search.text.strip_edges().to_lower()
	var sources: Array = []
	for key in _display_order:
		if _quote_row_refs.has(key):
			var quote: Dictionary = _quote_row_refs[key].get_meta("quote", {})
			var source := int(quote.get("source_cell", -1))
			if not sources.has(source):
				sources.append(source)
	sources.sort()
	var child_index := 0
	for header in _source_headers.values():
		header.visible = false
	for source in sources:
		var source_index := _source_city.get_item_index(source)
		var city := _source_city.get_item_text(source_index) if source_index >= 0 else _cell_name(source)
		var header := _source_headers.get(source) as Label
		if header == null:
			header = Label.new()
			header.set_meta("source_header", true)
			header.theme_type_variation = &"PKDossierSectionTitle"
			header.autowrap_mode = TextServer.AUTOWRAP_OFF
			header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_list.add_child(header)
			_source_headers[source] = header
		header.text = city
		_list.move_child(header, child_index)
		child_index += 1
		for key in _display_order:
			if not _quote_row_refs.has(key):
				continue
			var row := _quote_row_refs[key] as Button
			var quote: Dictionary = row.get_meta("quote", {})
			if int(quote.get("source_cell", -1)) != source:
				continue
			row.visible = query.is_empty() or (city + String(quote.get("display_name", ""))).to_lower().contains(query)
			header.visible = header.visible or row.visible
			_list.move_child(row, child_index)
			child_index += 1
	var focus_rows: Array[Button] = []
	for child in _list.get_children():
		if child is Button and child.visible and not child.disabled:
			focus_rows.append(child)
	_wire_row_focus(focus_rows)
	if not _hover_family.is_empty():
		var hovered := _quote_row_refs.get(_hover_family) as Control
		if hovered == null or not hovered.visible:
			_hover_family = ""
			_hover_timer.stop()
			_show_family_preview(_selected_quote)


func _wire_row_focus(rows: Array[Button]) -> void:
	var close := get_node("%CloseButton") as Button
	for index in range(rows.size()):
		rows[index].focus_neighbor_top = rows[index].get_path_to(rows[index - 1] if index > 0 else close)
		rows[index].focus_neighbor_bottom = rows[index].get_path_to(rows[index + 1] if index + 1 < rows.size() else close)
	if not rows.is_empty():
		close.focus_neighbor_bottom = close.get_path_to(rows[0])


func _on_row_preview_entered(row: Button) -> void:
	if TouchUI.is_touch():
		return
	_hover_family = _quote_key(row.get_meta("quote", {}))
	_hover_timer.start()


func _on_row_preview_exited(row: Button) -> void:
	if TouchUI.is_touch():
		return
	if _hover_family == _quote_key(row.get_meta("quote", {})):
		_hover_family = ""
		_hover_timer.stop()
		_show_family_preview(_selected_quote)


func _show_hover_preview() -> void:
	if TouchUI.is_touch():
		return
	var row := _quote_row_refs.get(_hover_family) as Button
	if visible and _current_tab == "quotes" and row != null and row.visible:
		_show_family_preview(row.get_meta("quote", {}), true)


func _show_family_preview(quote: Dictionary, hovering: bool = false) -> void:
	PlannerPresentation._show_family_preview(self, quote, hovering)


func _update_preview_route(quote: Dictionary) -> void:
	PlannerPresentation._update_preview_route(self, quote)


func _bind_atlas_shell() -> void:
	PlannerPresentation._bind_atlas_shell(self)


func _set_shell_icon(icon: IconBadge, key: StringName, accent: Color) -> void:
	PlannerPresentation._set_shell_icon(self, icon, key, accent)


func _on_source_pick_pressed() -> void:
	if _source_first:
		return
	if _source_picking:
		cancel_source_selection()
		return
	begin_source_selection()


func _on_population_slider_changed(value: float) -> void:
	if _population == null or int(_population.value) == int(value):
		return
	_population.value = value


func _on_max_population_pressed() -> void:
	if _population == null:
		return
	_population.value = _population.max_value


func _sync_population_slider() -> void:
	PlannerPresentation._sync_population_slider(self)


func _refresh_route_stepper(source_name: String, family_name: String) -> void:
	PlannerPresentation._refresh_route_stepper(self, source_name, family_name)


func _tint_step(button: Button, active: bool, chosen: bool) -> void:
	PlannerPresentation._tint_step(self, button, active, chosen)


func _refresh_city_cards() -> void:
	PlannerPresentation._refresh_city_cards(self)


func _on_city_card_pressed(card: Button) -> void:
	var index := int(card.get_meta("source_index", -1))
	if _source_city == null or index <= 0:
		return
	_source_picking = false
	_source_city.select(index)
	_on_source_city_selected(index)
	_update_start_enabled()


func _planning_sources() -> PackedInt32Array:
	var sources := PackedInt32Array()
	if _source_city == null:
		return sources
	for index in range(1, _source_city.item_count):
		sources.append(_source_city.get_item_id(index))
	if sources.is_empty() and _source_filter >= 0:
		sources.append(_source_filter)
	return sources


func _publish_planning_context() -> void:
	if not visible:
		return
	var sources := _planning_sources()
	var parts := PackedStringArray()
	for cell in sources:
		parts.append(str(int(cell)))
	var identity := "%s|%d|%d" % ["+".join(parts), _source_filter, _target_cell]
	if identity == _planning_identity:
		return
	_planning_identity = identity
	planning_context_changed.emit({
		"sources": sources,
		"selected_source": _source_filter,
		"target_cell": _target_cell,
	})


func _show_preview_cards(guide: bool, identity: bool, route: bool,
		traits: bool, effects: bool) -> void:
	PlannerPresentation._show_preview_cards(self, guide, identity, route, traits, effects)


func _paint_waiting_guide() -> void:
	PlannerPresentation._paint_waiting_guide(self)


func _paint_identity_card(quote: Dictionary, branch: Dictionary, hovering: bool,
		traits: Dictionary, effects: Dictionary) -> void:
	PlannerPresentation._paint_identity_card(self, quote, branch, hovering, traits, effects)


func _paint_quick_read(traits: Dictionary, effects: Dictionary) -> void:
	PlannerPresentation._paint_quick_read(self, traits, effects)


static func _compact_effect_text(value: String) -> String:
	var clean := value.strip_edges()
	for prefix in ["当地当前威望档：", "当前威望档："]:
		if clean.begins_with(prefix):
			return clean.trim_prefix(prefix).strip_edges()
	return clean


static func _bbcode_escape(value: String) -> String:
	return value.replace("[", "[lb]")


static func _highlight_effect_metrics(value: String) -> String:
	var safe := _bbcode_escape(value)
	var regex := RegEx.new()
	regex.compile("[+-]?[0-9]+(?:\\.[0-9]+)?%?")
	var matches := regex.search_all(safe)
	for index in range(matches.size() - 1, -1, -1):
		var found := matches[index]
		var highlighted := "[b][color=#%s]%s[/color][/b]" % [
			UITokens.DOSSIER_OXBLOOD.to_html(false), found.get_string()]
		safe = safe.substr(0, found.get_start()) + highlighted + safe.substr(found.get_end())
	return safe


func _pulse_identity_card(hovering: bool) -> void:
	PlannerPresentation._pulse_identity_card(self, hovering)


func _paint_trait_card(traits: Dictionary) -> void:
	PlannerPresentation._paint_trait_card(self, traits)


func _paint_effect_card(effects: Dictionary) -> void:
	PlannerPresentation._paint_effect_card(self, effects)


func _preview_party_count(quote: Dictionary) -> float:
	return PlannerPresentation._preview_party_count(self, quote)


func _paint_route_card(quote: Dictionary) -> void:
	PlannerPresentation._paint_route_card(self, quote)


func _kit_badge_items(quote: Dictionary) -> Array:
	return PlannerPresentation._kit_badge_items(self, quote)


func _paint_expedition_card(title: String, metrics: String, effects: String, route: String) -> void:
	PlannerPresentation._paint_expedition_card(self, title, metrics, effects, route)
