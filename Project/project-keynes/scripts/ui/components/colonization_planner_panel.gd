extends PanelContainer
class_name ColonizationPlannerPanel

const FamilyRowScene := preload("res://scenes/ui/colonization_family_row.tscn")
const TraitMeterScene := preload("res://scenes/ui/inspector_meter_list.tscn")
const EffectNoteScene := preload("res://scenes/ui/inspector_note_list.tscn")

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
var _hover_family := 0
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
var _population: SpinBox
var _population_slider: HSlider
var _feedback: Label
var _start: Button
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
var _source_pick_armed := true
var _guide_card: Control
var _guide_icon: IconBadge
var _guide_title: Label
var _guide_facts: InspectorFactGrid
var _guide_notes: InspectorNoteList
var _identity_card: Control
var _preview_crest: IconBadge
var _preview_origin: Label
var _preview_state_pill: Label
var _preview_facts: InspectorFactGrid
var _preview_meters: InspectorMeterList
var _route_card: Control
var _route_card_icon: IconBadge
var _route_ready_pill: Label
var _route_facts: InspectorFactGrid
var _kit_badges: BadgeRow
var _route_notes: InspectorNoteList
var _traits_card: Control
var _traits_box: VBoxContainer
var _trait_meters: InspectorMeterList
var _pref_badges: BadgeRow
var _effects_card: Control
var _effects_box: VBoxContainer
var _effect_notes: InspectorNoteList
var _max_population_button: Button
var _preview_hovering := false
var _planning_identity := ""


func _ready() -> void:
	if _list != null:
		return
	_title = get_node_or_null("%Title") as Label
	_subtitle = get_node_or_null("%Subtitle") as Label
	_status = get_node_or_null("%StatusLabel") as Label
	_tabs = get_node_or_null("%CategoryTabs") as CategoryTabs
	_list = get_node_or_null("%QuoteList") as VBoxContainer
	_population_row = get_node_or_null("%PopulationRow") as HBoxContainer
	_population = get_node_or_null("%PopulationSpin") as SpinBox
	_feedback = get_node_or_null("%FeedbackLabel") as Label
	_start = get_node_or_null("%StartButton") as Button
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
			or _list == null or _population_row == null or _population == null \
			or _feedback == null or _start == null or _source_city == null or close_button == null:
		push_error("ColonizationPlannerPanel 必须通过 colonization_planner_panel.tscn 实例化。")
		return
	theme_type_variation = &"PKArchivePanel"
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_panel)
	_tabs.set_tabs([
		{"id": "quotes", "label": "可派遣", "icon": "family.house",
			"tooltip": "可派往此地的家族", "accent": UITokens.ACCENT},
		{"id": "expeditions", "label": "在途", "icon": "action.history",
			"tooltip": "筹备中和已出发的开拓队", "accent": UITokens.CLIMATE},
	], "quotes", true)
	_tabs.tab_selected.connect(_on_tab_selected)
	_population.value_changed.connect(func(_value: float) -> void:
		_refresh_selected_kit())
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
	_source_pick_armed = true
	_source_first = target_cell < 0
	_detail_valid = false
	_preview_cache.clear()
	_quote_preview_cache.clear()
	_local_families.clear()
	_display_order.clear()
	_hover_family = 0
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
	_subtitle.text = "先选出发城市，再选当地家族"
	_feedback.text = ""
	visible = true
	if is_inside_tree():
		_layout_left_panel()
		UIAnimation.crossfade(self)
	if _controller != null:
		var page := _filter_expedition_page(_controller.get_family_expeditions(0, 128))
		if bool(page.get("ok", false)) and int(page.get("total", 0)) > 0:
			_show_expeditions()
			return
	_show_quotes()
	_update_workflow()


func _layout_left_panel() -> void:
	if not is_inside_tree():
		return
	var viewport_size := get_viewport().get_visible_rect().size
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2(UITokens.ARCHIVE_EDGE_INSET, PlayerTopBar.BAR_HEIGHT + 4.0)
	size = Vector2(roundf(viewport_size.x * 0.45), maxf(0.0,
		viewport_size.y - position.y - CountryActionBar.BAR_HEIGHT - UITokens.ARCHIVE_EDGE_INSET))
	var body := get_node("%Body") as BoxContainer
	var narrow := size.x < 560.0
	body.vertical = narrow
	var list_pane := get_node("%ListPane") as Control
	var preview := get_node("%PreviewScroll") as Control
	list_pane.size_flags_stretch_ratio = 0.6 if narrow else 0.44
	preview.size_flags_stretch_ratio = 0.4 if narrow else 0.56


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
	var message := String(result.get("message", "")).strip_edges()
	if message.is_empty():
		message = _reason_text(code) if not code.is_empty() else ""
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
		if _hover_family == 0:
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
	var offset := 0
	var page: Dictionary
	while true:
		page = _controller.get_family_colonization_quotes(
			_target_cell, _family_filter, -1, offset, 256)
		if not bool(page.get("ok", false)):
			return page
		var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
		var names: PackedStringArray = page.get("source_settlement_names", PackedStringArray())
		for index in range(sources.size()):
			var cell := int(sources[index])
			cities[cell] = String(names[index]) if index < names.size() else "聚落 %d" % (cell + 1)
		if not bool(page.get("has_more", false)) or sources.is_empty():
			break
		offset += sources.size()
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
	if _source_filter >= 0:
		var selected := _source_city.get_item_index(_source_filter)
		if selected > 0:
			_source_city.select(selected)
			return _get_source_quotes()
		_source_filter = -1
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
	if not _sources_loaded or _source_filter < 0:
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
	if _source_filter < 0:
		_clear_list()
		_selected_quote.clear()
		_apply_kind(String(page.get("kind", "colonize")))
		_set_busy_status(_economy_busy)
		if _source_city.item_count > 1:
			_add_note("请选择出发城市，然后选择该城要派遣的家族。", UITokens.ARCHIVE_INK_MUTED)
		elif _economy_busy:
			_sources_loaded = false
			_add_note("经济正在结算，提交后刷新可派遣的城市与家族。", UITokens.ARCHIVE_INK_MUTED)
		else:
			_add_note("没有可向此地派遣家族的城市。", UITokens.WARN)
		_update_start_enabled()
		return
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
		else:
			_add_note("该城没有可向此地派遣的家族，请更换出发城市。", UITokens.WARN)
	if restored:
		_refresh_selected_kit()
	else:
		_update_start_enabled()


func _sync_quote_rows(quotes: Array, keep_population: int) -> bool:
	_remove_note_children()
	var keep := {}
	var restored := false
	for quote_value in quotes:
		var quote: Dictionary = quote_value.duplicate(true)
		var handle := int(quote.get("family_handle", 0))
		keep[handle] = true
		var local: Dictionary = _local_families.get(handle, {})
		for field in ["display_name", "population", "cash_claim", "owned_buildings", "prestige_level"]:
			if local.has(field):
				quote[field] = local[field]
		if not _local_families.has(handle) and _controller.has_method("get_family_snapshot"):
			var identity: Dictionary = _controller.get_family_snapshot(handle)
			quote["display_name"] = identity.get("family_name", quote.get("display_name", "家族"))
		var maximum := int(quote.get("maximum_population", 0))
		var row := _quote_row_refs.get(handle) as Button
		if row == null or not is_instance_valid(row):
			row = FamilyRowScene.instantiate() as Button
			row.pressed.connect(_on_reusable_quote_pressed.bind(row))
			row.mouse_entered.connect(_on_row_preview_entered.bind(row))
			row.mouse_exited.connect(_on_row_preview_exited.bind(row))
			row.focus_entered.connect(_on_row_preview_entered.bind(row))
			_list.add_child(row)
			_quote_row_refs[handle] = row
		row.set_meta("quote", quote)
		var local_people := int(quote.get("population", maximum + 1))
		var prestige_level := int(quote.get("prestige_level", 0))
		row.set_compact_summary({
			"name": String(quote.get("display_name", "家族")),
			"population": local_people,
			"population_tooltip": "当地分支人口；至少留下一人",
			"prestige_level": prestige_level,
			"icon": "family.workspace.crest" if prestige_level >= 1 else "family.house",
			"accent": UITokens.DOSSIER_OXBLOOD if prestige_level >= 3 else UITokens.DOSSIER_BRASS,
			"tag_text": "威望 %s" % str(quote.get("prestige_level", "—")),
			"tag_color": UITokens.DOSSIER_OXBLOOD if prestige_level >= 3 else UITokens.DOSSIER_BRASS,
			"bar_ratio": clampf(float(maximum) / float(maxi(local_people, 1)), 0.0, 1.0),
			"bar_color": UITokens.DOSSIER_VERDIGRIS if maximum > 0 else UITokens.DOSSIER_OXBLOOD,
			"effect": "可派 %s · 威望 %s · 产业 %s" % [
				UITokens.format_compact_number_cn(float(maximum), 0),
				str(quote.get("prestige_level", "—")),
				str(quote.get("owned_buildings", "—"))],
		})
		row.disabled = maximum <= 0
		var selected := int(_selected_quote.get("family_handle", 0)) == handle
		row.set_pressed_no_signal(selected)
		if selected:
			_selected_quote = quote.duplicate(true)
			var editor := _population.get_line_edit()
			if not _population.has_focus() and not editor.has_focus():
				_population.max_value = maxi(1, maximum)
				_population.set_value_no_signal(clampi(keep_population, 1, maxi(1, maximum)))
			restored = maximum > 0
	for handle in _quote_row_refs.keys():
		if not keep.has(handle):
			var row := _quote_row_refs[handle] as Node
			_list.remove_child(row)
			row.queue_free()
			_quote_row_refs.erase(handle)
	_apply_list_filter_sort()
	return restored


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
	_hover_family = 0
	_hover_timer.stop()
	_feedback.text = ""
	_selected_quote = quote.duplicate(true)
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
	_current_tab = "expeditions"
	if _tabs != null:
		_tabs.select_tab("expeditions")
	_hover_timer.stop()
	_hover_family = 0
	_preview_title.text = "在途队伍"
	_preview_metrics.text = "点击队伍查看路线；筹备与返程可在列表中取消。"
	_preview_traits.text = ""
	_preview_preferences.text = ""
	_preview_effects.text = ""
	_preview_route.text = ""
	_paint_expedition_card("在途队伍", _preview_metrics.text, "", "")
	_discard_quote_rows()
	_update_start_enabled()
	if _controller == null:
		_clear_list()
		_expeditions_identity = ""
		_set_busy_status(false)
		return
	var page: Dictionary = _controller.get_family_expeditions(0, 128)
	page = _filter_expedition_page(page)
	_economy_busy = bool(page.get("busy", false))
	if not bool(page.get("ok", false)):
		var code := String(page.get("code", "command_rejected"))
		if _transient_query_failure(code, page):
			_economy_busy = true
			_set_busy_status(true)
			if _has_expedition_rows():
				return
			_clear_list()
			_expeditions_identity = ""
			_add_note("正在等待经济提交完成后显示在途队伍。", UITokens.ARCHIVE_INK_MUTED)
			return
		_clear_list()
		_expeditions_identity = ""
		_set_busy_status(_economy_busy)
		_add_note(_reason_text(code), UITokens.RISK)
		return
	var identity := _expeditions_identity_of(page)
	if identity == _expeditions_identity and _has_expedition_rows():
		_set_busy_status(_economy_busy)
		return
	_expeditions_identity = identity
	_set_busy_status(_economy_busy)
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	if handles.is_empty():
		_clear_list()
		if _economy_busy:
			_add_note("经济正在结算。在途队伍将在提交后刷新。", UITokens.ARCHIVE_INK_MUTED)
		else:
			_add_note("当前没有活动开拓队。", UITokens.ARCHIVE_INK_MUTED)
		return
	_sync_expedition_rows(page)


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
	_remove_note_children()
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var populations: PackedInt64Array = page.get("populations", PackedInt64Array())
	var dues: PackedInt64Array = page.get("due_days", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	var keep := {}
	for index in range(handles.size()):
		var expedition_handle := int(handles[index])
		keep[expedition_handle] = true
		var family_handle := int(families[index]) if index < families.size() else 0
		var view: Dictionary = _family_view_for(family_handle,
			int(populations[index]) if index < populations.size() else 0)
		var state := int(states[index]) if index < states.size() else 0
		var returning := state == 3
		var row_wrap := _expedition_row_refs.get(expedition_handle) as HBoxContainer
		var row: Button
		var cancel: Button
		if row_wrap == null or not is_instance_valid(row_wrap):
			row_wrap = HBoxContainer.new()
			row_wrap.add_theme_constant_override("separation", UITokens.SPACE_SM)
			row = FamilyRowScene.instantiate() as Button
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.toggle_mode = false
			row.pressed.connect(_on_reusable_expedition_pressed.bind(row))
			row_wrap.add_child(row)
			cancel = Button.new()
			cancel.text = "取消"
			cancel.focus_mode = Control.FOCUS_NONE
			cancel.theme_type_variation = &"PKTabButton"
			cancel.custom_minimum_size = Vector2(64.0, 36.0)
			cancel.pressed.connect(_on_reusable_cancel_pressed.bind(cancel))
			row_wrap.add_child(cancel)
			_list.add_child(row_wrap)
			_expedition_row_refs[expedition_handle] = row_wrap
		else:
			row = row_wrap.get_child(0) as Button
			cancel = row_wrap.get_child(1) as Button
		row.set_meta("expedition_handle", expedition_handle)
		cancel.set_meta("expedition_handle", expedition_handle)
		var party_people := int(populations[index]) if index < populations.size() else 0
		var state_label := _state_text(state)
		var missing_line := _preparing_missing_text(expedition_handle, state).get_slice("\n", 0)
		row.set_compact_summary({
			"name": String(view.get("display_name", "家族")),
			"population": party_people,
			"icon": "economy.building" if state == 4 else "action.history",
			"accent": UITokens.DOSSIER_BRASS if state == 4 else UITokens.DOSSIER_VERDIGRIS,
			"tag_text": state_label,
			"tag_color": UITokens.DOSSIER_OXBLOOD if returning else (
				UITokens.DOSSIER_BRASS if state == 4 else UITokens.DOSSIER_VERDIGRIS),
			"bar_ratio": 0.35 if state == 4 else (1.0 if state == 2 else 0.62),
			"bar_color": UITokens.DOSSIER_BRASS if state == 4 else UITokens.DOSSIER_VERDIGRIS,
			"badges": [{
				"text": state_label,
				"accent": UITokens.WARN if returning else UITokens.ACCENT,
			}],
			"effect": missing_line if not missing_line.is_empty() else state_label,
			"tooltip": _expedition_row_tooltip(expedition_handle, state,
				int(dues[index]) if index < dues.size() else -1),
		})
		row.set_meta("expedition_view", {"name": String(view.get("display_name", "家族")),
			"population": int(populations[index]) if index < populations.size() else 0,
			"state": state, "due_day": int(dues[index]) if index < dues.size() else -1})
		cancel.disabled = returning
		if returning:
			cancel.tooltip_text = "返程中的队伍不能重复取消"
		else:
			cancel.tooltip_text = "按当前进度返程；结算中会先排队，提交完成后执行"
	var stale: Array = []
	for handle_value in _expedition_row_refs.keys():
		if not keep.has(handle_value):
			stale.append(handle_value)
	for handle_value in stale:
		var stale_wrap := _expedition_row_refs[handle_value] as Node
		_expedition_row_refs.erase(handle_value)
		if stale_wrap != null and is_instance_valid(stale_wrap):
			stale_wrap.queue_free()


func _on_reusable_expedition_pressed(row: Button) -> void:
	var handle := int(row.get_meta("expedition_handle", 0))
	var view: Dictionary = row.get_meta("expedition_view", {})
	_preview_title.text = "队伍 · " + String(view.get("name", "家族"))
	_preview_metrics.text = "%s · %s 人" % [_state_text(int(view.get("state", 0))),
		UITokens.format_compact_number_cn(float(view.get("population", 0)), 0)]
	_preview_traits.text = ""
	_preview_preferences.text = ""
	_preview_effects.text = _preparing_missing_text(handle, int(view.get("state", 0)))
	_preview_route.text = "第 %d 日抵达" % int(view.get("due_day", -1)) \
		if int(view.get("due_day", -1)) >= 0 else ""
	_paint_expedition_card(_preview_title.text, _preview_metrics.text,
		_preview_effects.text, _preview_route.text)
	expedition_selected.emit(handle)


func _on_reusable_cancel_pressed(cancel: Button) -> void:
	cancel_requested.emit(int(cancel.get_meta("expedition_handle", 0)))


func _clear_list() -> void:
	_hover_family = 0
	_hover_timer.stop()
	_quote_row_refs.clear()
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
		if child is Label:
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
	var cancel: bool = event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE
	cancel = cancel or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT)
	if cancel:
		if _source_picking:
			cancel_source_selection()
		elif _target_picking:
			cancel_target_selection()
		else:
			close_panel()
		get_viewport().set_input_as_handled()


static func _state_text(state: int) -> String:
	return {1: "前往中", 2: "落地结算中", 3: "返程中", 4: "筹备中"}.get(state, "未知")


static func _reason_text(code: String) -> String:
	return {
		"colonization_target_invalid": "目标必须是当前可见、可通行的无主或本国陆地。",
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
	if _hover_family == 0:
		_update_preview_route(_selected_quote)
	route_requested.emit(detail)


func _update_start_enabled() -> void:
	if _start == null:
		return
	var on_quotes := _current_tab == "quotes"
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
	var parts := PackedStringArray()
	for index in range(handles.size()):
		var state := int(states[index]) if index < states.size() else 0
		var missing := 0
		var identities: PackedInt64Array = page.get(
			"kit_missing_stock_identities", PackedInt64Array())
		if index < identities.size():
			missing = int(identities[index])
		parts.append("%d:%d:%d" % [int(handles[index]), state, missing])
	return "%s|%s" % [int(page.get("total", 0)), ",".join(parts)]




func _preparing_missing_text(handle: int, state: int) -> String:
	if state != 4 or _controller == null or not _controller.has_method(
			"get_family_expedition_snapshot"):
		return ""
	var snap: Dictionary = _controller.get_family_expedition_snapshot(handle)
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
	if required > 0:
		lines.append("已囤积 %d%%（口粮 %d%% / 建材 %d%%），每日自动收进源地可用现货" % [
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
			lines.append("仍缺路上口粮，等源地产出")
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
			parts.append("%s %s" % [good_name,
				UITokens.format_compact_number_cn(float(qty) / 1000.0, 1)])
		lines.append("下列物资任选其一即可顶替，源地现货：" + "，".join(parts))
	return "\n".join(lines)


func _procurement_status_text(snap: Dictionary) -> String:
	if bool(snap.get("kit_procurement_blocked_by_peer", false)):
		return "等待另一支开拓队的国库采购完成"
	if bool(snap.get("kit_procurement_pending", false)):
		return "正在用国库采购%s（第 %d 日起，阶段 %d）" % [
			_good_name(int(snap.get("kit_procurement_good_id", -1))),
			int(snap.get("kit_procurement_started_day", -1)),
			int(snap.get("kit_procurement_phase", 0))]
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
		if index >= sources.size() or int(sources[index]) != _source_filter:
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


static func _quote_tooltip(quote: Dictionary) -> String:
	return "路线成本 %d · 预计 %d 日抵达" % [
		int(quote.get("route_cost", 0)), int(quote.get("travel_days", 1))]


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
		"effect_text": "暂无特性",
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


static func _trait_badges(traits: Dictionary) -> Array:
	var badges: Array = []
	var names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var core: PackedByteArray = traits.get("core", PackedByteArray())
	var descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	for index in range(names.size()):
		var label := String(names[index]).strip_edges()
		if label.is_empty():
			continue
		var is_core := index < core.size() and int(core[index]) != 0
		var tooltip := String(descriptions[index]).strip_edges() \
			if index < descriptions.size() else ""
		badges.append({
			"text": label,
			"accent": UITokens.ACCENT if is_core else UITokens.ARCHIVE_INK_MUTED,
			"tooltip": tooltip,
		})
	var effect_names: PackedStringArray = traits.get(
		"bound_effect_display_names", PackedStringArray())
	var effect_descriptions: PackedStringArray = traits.get(
		"bound_effect_descriptions", PackedStringArray())
	if effect_names.is_empty():
		effect_names = traits.get("effect_display_names", PackedStringArray())
	for index in range(effect_names.size()):
		var label := String(effect_names[index]).strip_edges()
		if label.is_empty():
			continue
		var tooltip := String(effect_descriptions[index]).strip_edges() \
			if index < effect_descriptions.size() else ""
		badges.append({
			"text": label,
			"accent": UITokens.CLIMATE,
			"tooltip": tooltip,
		})
	return badges


static func _effect_text(traits: Dictionary) -> String:
	var names: PackedStringArray = traits.get(
		"behavior_selector_display_names", PackedStringArray())
	var seen := {}
	var parts := PackedStringArray()
	for raw in names:
		var label := String(raw).strip_edges()
		if label.is_empty() or seen.has(label):
			continue
		seen[label] = true
		parts.append(label)
		if parts.size() >= 3:
			break
	var effect_names: PackedStringArray = traits.get(
		"bound_effect_display_names", PackedStringArray())
	if effect_names.is_empty():
		effect_names = traits.get("effect_display_names", PackedStringArray())
	var effect_parts := PackedStringArray()
	for raw in effect_names:
		var label := String(raw).strip_edges()
		if label.is_empty() or seen.has(label):
			continue
		seen[label] = true
		effect_parts.append(label)
		if effect_parts.size() >= 3:
			break
	if not parts.is_empty() and not effect_parts.is_empty():
		return "偏好：%s · 效果：%s" % ["、".join(parts), "、".join(effect_parts)]
	if not parts.is_empty():
		return "偏好：%s" % "、".join(parts)
	if not effect_parts.is_empty():
		return "效果：%s" % "、".join(effect_parts)
	var trait_names: PackedStringArray = traits.get(
		"display_names", PackedStringArray())
	return "暂无特性" if trait_names.is_empty() else ""



func open_source(source_cell: int, family_handle: int) -> void:
	open_target(-1, 0, source_cell)
	var row := _quote_row_refs.get(family_handle) as Button
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
	var row := _quote_row_refs.get(int(_selected_quote.get("family_handle", 0))) as Control
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
	_source_pick_armed = true
	_update_start_enabled()
	source_selection_requested.emit()


func cancel_source_selection() -> void:
	_source_picking = false
	_source_pick_armed = false
	_update_start_enabled()


func is_source_picking() -> bool:
	return visible and _source_picking


func try_source_cell(cell: int) -> bool:
	if not _source_picking or _source_city == null:
		return false
	var index := _source_city.get_item_index(cell)
	if index <= 0:
		_feedback.text = "请点选带青绿环的可派遣城市。"
		_feedback.visible = true
		_feedback.tooltip_text = _feedback.text
		_feedback.add_theme_color_override("font_color", UITokens.RISK)
		return false
	_source_picking = false
	_source_city.select(index)
	_on_source_city_selected(index)
	_update_start_enabled()
	return true


func try_target_cell(cell: int) -> bool:
	if _controller == null or cell < 0:
		return false
	var family := int(_selected_quote.get("family_handle", 0))
	var page: Dictionary = _controller.get_family_colonization_quotes(cell, family, _source_filter, 0, 256)
	if not bool(page.get("ok", false)) or (family > 0 and int(page.get("total", 0)) <= 0):
		_feedback.text = _reason_text(String(page.get("code", "colonization_target_invalid"))) \
			if not bool(page.get("ok", false)) else "该家族当前无法从此城前往此地，请选择其他目的地。"
		_feedback.visible = true
		_feedback.tooltip_text = _feedback.text
		return false
	_target_cell = cell
	_target_picking = false
	_sources_loaded = false
	_quotes_identity = ""
	_feedback.text = ""
	_show_quotes()
	_update_start_enabled()
	return true


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
	if _source_picking:
		_subtitle.text = "请在地图上点选出发城市 · Esc 退出选点"
	elif _target_picking:
		_subtitle.text = "请在地图上选择目的地 · Esc 退出选点"
	else:
		_subtitle.text = "先选出发家族，再选目的地" if _source_first else "先在地图上点选出发城市，再选家族与目的地"
	_subtitle.visible = _source_picking or _target_picking
	_target_button.text = "正在选点" if _target_picking else (
		"重新选点" if _target_cell >= 0 else "选择目的地")
	_refresh_route_stepper(source, family)
	_refresh_city_cards()
	_publish_planning_context()


func _load_local_families() -> Dictionary:
	if _source_filter < 0 or _controller == null or not _controller.has_method("get_family_dispatch_candidates"):
		return {"ok": true}
	var rebuilt := {}
	var offset := 0
	while true:
		var page: Dictionary = _controller.get_family_dispatch_candidates(_source_filter, offset, 256)
		if not bool(page.get("ok", false)):
			return page
		var handles: PackedInt64Array = page.get("family_handles", PackedInt64Array())
		for index in range(handles.size()):
			var data := {"family_handle": int(handles[index]), "source_cell": _source_filter,
				"target_cell": _target_cell, "quote_token": 0}
			for pair in [["family_names", "display_name"], ["populations", "population"],
					["cash_claims", "cash_claim"], ["owned_buildings", "owned_buildings"], ["prestige_levels", "prestige_level"]]:
				var values: Variant = page.get(pair[0], [])
				if index < values.size():
					data[pair[1]] = values[index]
			data["maximum_population"] = maxi(0, int(data.get("population", 0)) - 1)
			rebuilt[int(handles[index])] = data
		if not bool(page.get("has_more", false)) or handles.is_empty():
			break
		offset += handles.size()
	_local_families = rebuilt
	return {"ok": true}


func _get_source_quotes() -> Dictionary:
	var page: Dictionary = _controller.get_family_colonization_quotes(
		_target_cell, _family_filter, _source_filter, 0, 256)
	var offset := (page.get("family_handles", PackedInt64Array()) as PackedInt64Array).size()
	while bool(page.get("ok", false)) and bool(page.get("has_more", false)) and offset > 0:
		var next: Dictionary = _controller.get_family_colonization_quotes(
			_target_cell, _family_filter, _source_filter, offset, 256)
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


func _apply_list_filter_sort() -> void:
	if _current_tab != "quotes":
		return
	var added: Array = []
	for handle in _quote_row_refs:
		if not _display_order.has(handle):
			added.append(handle)
	added.sort_custom(func(a, b) -> bool:
		var left: Dictionary = _quote_row_refs[a].get_meta("quote", {})
		var right: Dictionary = _quote_row_refs[b].get_meta("quote", {})
		var field := "prestige_level" if _sort.selected == 1 else "maximum_population"
		if _sort.selected < 2 and int(left.get(field, 0)) != int(right.get(field, 0)):
			return int(left.get(field, 0)) > int(right.get(field, 0))
		var ln := String(left.get("display_name", ""))
		var rn := String(right.get("display_name", ""))
		return ln < rn if ln != rn else int(a) < int(b))
	_display_order.append_array(added)
	var query := _search.text.strip_edges().to_lower()
	var child_index := 0
	for handle in _display_order:
		if not _quote_row_refs.has(handle):
			continue
		var row := _quote_row_refs[handle] as Button
		var quote: Dictionary = row.get_meta("quote", {})
		row.visible = query.is_empty() or String(quote.get("display_name", "")).to_lower().contains(query)
		_list.move_child(row, child_index)
		child_index += 1
	if _hover_family != 0:
		var hovered := _quote_row_refs.get(_hover_family) as Control
		if hovered == null or not hovered.visible:
			_hover_family = 0
			_hover_timer.stop()
			_show_family_preview(_selected_quote)


func _on_row_preview_entered(row: Button) -> void:
	_hover_family = int(row.get_meta("quote", {}).get("family_handle", 0))
	_hover_timer.start()


func _on_row_preview_exited(row: Button) -> void:
	if _hover_family == int(row.get_meta("quote", {}).get("family_handle", 0)):
		_hover_family = 0
		_hover_timer.stop()
		_show_family_preview(_selected_quote)


func _show_hover_preview() -> void:
	var row := _quote_row_refs.get(_hover_family) as Button
	if visible and _current_tab == "quotes" and row != null and row.visible:
		_show_family_preview(row.get_meta("quote", {}), true)


func _show_family_preview(quote: Dictionary, hovering: bool = false) -> void:
	if _preview_title == null:
		return
	_preview_family = int(quote.get("family_handle", 0))
	if quote.is_empty():
		_preview_title.text = "家族预览"
		_preview_metrics.text = "悬停查看详情，点击家族固定选择。"
		_preview_traits.text = ""
		_preview_preferences.text = ""
		_preview_effects.text = ""
		_preview_route.text = ""
		_paint_waiting_guide()
		return
	_preview_hovering = hovering
	_preview_title.text = ("预览 · " if hovering else "已选 · ") + String(quote.get("display_name", "家族"))
	var key := "%d:%d" % [_source_filter, _preview_family]
	var preview: Dictionary = _preview_cache.get(key, {})
	if preview.is_empty():
		if _controller != null and _controller.has_method("get_family_dispatch_preview"):
			preview = _controller.get_family_dispatch_preview(_preview_family, _source_filter)
		else:
			preview = {"ok": true, "traits": {}}
			if _controller != null and _controller.has_method("get_family_traits"):
				preview["traits"] = _controller.get_family_traits(_preview_family)
		if bool(preview.get("ok", false)):
			_preview_cache[key] = preview
	if not bool(preview.get("ok", false)):
		_preview_metrics.text = String(preview.get("message", "当地分支详情暂不可用。"))
		_preview_traits.text = ""
		_preview_preferences.text = ""
		_preview_effects.text = ""
		_preview_route.text = ""
		_paint_waiting_guide()
		return
	var branch: Dictionary = preview.get("branch", {})
	_preview_metrics.text = "当地族人 %s · 可派 %s
威望 %s · 产业 %s
资金归属 %s" % [
		UITokens.format_compact_number_cn(float(branch.get("populations", quote.get("population", int(quote.get("maximum_population", 0)) + 1))), 0),
		UITokens.format_compact_number_cn(float(quote.get("maximum_population", 0)), 0),
		str(branch.get("prestige_levels", quote.get("prestige_level", "—"))),
		str(branch.get("owned_buildings", quote.get("owned_buildings", "—"))),
		UITokens.format_compact_number_cn(float(branch.get("cash_claims", quote.get("cash_claim", 0))) / 10000.0, 2)]
	var traits: Dictionary = preview.get("traits", {})
	var names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var core: PackedByteArray = traits.get("core", PackedByteArray())
	var lines := PackedStringArray()
	for i in range(names.size()):
		lines.append("%s · %s
%s" % ["核心" if i < core.size() and core[i] != 0 else "附加",
			names[i], descriptions[i] if i < descriptions.size() else ""])
	_preview_traits.text = "特性
" + "

".join(lines) if not lines.is_empty() else "暂无特性"
	var preferences: PackedStringArray = traits.get("behavior_selector_display_names", PackedStringArray())
	_preview_preferences.text = "行为偏好
" + "、".join(preferences) if not preferences.is_empty() else ""
	var effects: Dictionary = preview.get("effects", traits)
	var effect_names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var effect_copy: PackedStringArray = effects.get("effect_current_descriptions", effects.get("effect_descriptions", PackedStringArray()))
	lines.clear()
	for i in range(effect_names.size()):
		lines.append(String(effect_names[i]) + ("
" + String(effect_copy[i]) if i < effect_copy.size() else ""))
	_preview_effects.text = "当地效果
" + "

".join(lines) if not lines.is_empty() else ""
	_paint_identity_card(quote, branch, hovering)
	_paint_trait_card(traits)
	_paint_effect_card(effects if not effects.is_empty() else traits)
	var route_quote := quote.duplicate(true)
	if hovering and _target_cell >= 0 and int(quote.get("quote_token", 0)) > 0:
		var people := maxi(1, int(quote.get("maximum_population", 1)))
		var route_key := "%d:%d" % [int(quote.quote_token), people]
		var detail: Dictionary = _quote_preview_cache.get(route_key, {})
		if detail.is_empty() and _controller != null:
			detail = _controller.get_family_colonization_quote_detail(int(quote.quote_token), people)
			if bool(detail.get("ok", false)):
				_quote_preview_cache[route_key] = detail
		if bool(detail.get("ok", false)):
			route_quote.merge(detail, true)
	_update_preview_route(route_quote)


func _update_preview_route(quote: Dictionary) -> void:
	if _target_cell < 0:
		_preview_route.text = "选定目的地后计算路线和开工物资。"
		_paint_route_card(quote)
		return
	_preview_route.text = "目的地 · %s
预计 %d 日抵达
%s" % [_cell_name(_target_cell),
		int(quote.get("travel_days", 1)), _kit_summary_text(quote)]
	if bool(quote.get("kit_partial", false)):
		_preview_route.text += "
" + ("物资不足，将先在源地筹备。" if bool(quote.get("kit_place_buildings", false)) else "仅携带当前可用的基础物资。")
	_paint_route_card(quote)


func _bind_atlas_shell() -> void:
	_header_icon = get_node_or_null("%HeaderIcon") as IconBadge
	_route_stepper = get_node_or_null("%RouteStepper") as Control
	_source_pick_button = get_node_or_null("%SourcePickButton") as Button
	_family_step_label = get_node_or_null("%FamilyStepLabel") as Label
	_source_step_icon = get_node_or_null("%SourceStepIcon") as IconBadge
	_family_step_icon = get_node_or_null("%FamilyStepIcon") as IconBadge
	_target_step_icon = get_node_or_null("%TargetStepIcon") as IconBadge
	_city_picker = get_node_or_null("%CityPickerPane") as Control
	_city_cards_box = get_node_or_null("%CityCardsBox") as VBoxContainer
	_population_slider = get_node_or_null("%PopulationSlider") as HSlider
	_max_population_button = get_node_or_null("%MaxPopButton") as Button
	_guide_card = get_node_or_null("%PreviewGuideCard") as Control
	_guide_icon = get_node_or_null("%GuideIcon") as IconBadge
	_guide_title = get_node_or_null("%GuideTitle") as Label
	_guide_facts = get_node_or_null("%GuideFacts") as InspectorFactGrid
	_guide_notes = get_node_or_null("%GuideNotes") as InspectorNoteList
	_identity_card = get_node_or_null("%PreviewIdentityCard") as Control
	_preview_crest = get_node_or_null("%PreviewCrest") as IconBadge
	_preview_origin = get_node_or_null("%PreviewOriginSub") as Label
	_preview_state_pill = get_node_or_null("%PreviewStatePill") as Label
	_preview_facts = get_node_or_null("%PreviewFactGrid") as InspectorFactGrid
	_preview_meters = get_node_or_null("%PreviewMeters") as InspectorMeterList
	_route_card = get_node_or_null("%PreviewRouteCard") as Control
	_route_card_icon = get_node_or_null("%RouteCardIcon") as IconBadge
	_route_ready_pill = get_node_or_null("%RouteReadyPill") as Label
	_route_facts = get_node_or_null("%RouteFactGrid") as InspectorFactGrid
	_kit_badges = get_node_or_null("%KitBadges") as BadgeRow
	_route_notes = get_node_or_null("%RouteNotes") as InspectorNoteList
	_traits_card = get_node_or_null("%PreviewTraitsCard") as Control
	_traits_box = get_node_or_null("%TraitsVisualBox") as VBoxContainer
	_pref_badges = get_node_or_null("%PrefBadges") as BadgeRow
	_effects_card = get_node_or_null("%PreviewEffectsCard") as Control
	_effects_box = get_node_or_null("%EffectsVisualBox") as VBoxContainer
	_set_shell_icon(_header_icon, &"family.house", UITokens.DOSSIER_OXBLOOD)
	_set_shell_icon(get_node_or_null("%SearchIcon") as IconBadge, &"summary.overview", UITokens.DOSSIER_UMBER)
	_set_shell_icon(get_node_or_null("%SortIcon") as IconBadge, &"trend.flat", UITokens.DOSSIER_UMBER)
	_set_shell_icon(_source_step_icon, &"metric.territory", UITokens.DOSSIER_VERDIGRIS)
	_set_shell_icon(_family_step_icon, &"family.house", UITokens.DOSSIER_BRASS)
	_set_shell_icon(_target_step_icon, &"system.target", UITokens.DOSSIER_BRASS)
	_set_shell_icon(get_node_or_null("%CityPinIcon") as IconBadge, &"metric.territory", UITokens.DOSSIER_VERDIGRIS)
	_set_shell_icon(get_node_or_null("%PopIcon") as IconBadge, &"family.metric.population", UITokens.DOSSIER_OXBLOOD)
	_set_shell_icon(_guide_icon, &"metric.territory", UITokens.DOSSIER_OXBLOOD)
	_set_shell_icon(get_node_or_null("%TraitsCardIcon") as IconBadge, &"technology.milestone", UITokens.DOSSIER_OXBLOOD)
	_set_shell_icon(get_node_or_null("%EffectsCardIcon") as IconBadge, &"ecology.growth", UITokens.DOSSIER_VERDIGRIS)
	_set_shell_icon(_route_card_icon, &"system.target", UITokens.DOSSIER_BRASS)
	if _source_pick_button != null and not _source_pick_button.pressed.is_connected(_on_source_pick_pressed):
		_source_pick_button.pressed.connect(_on_source_pick_pressed)
	if _population_slider != null and not _population_slider.value_changed.is_connected(_on_population_slider_changed):
		_population_slider.value_changed.connect(_on_population_slider_changed)
	if _max_population_button != null and not _max_population_button.pressed.is_connected(_on_max_population_pressed):
		_max_population_button.pressed.connect(_on_max_population_pressed)
	if _traits_box != null and _trait_meters == null:
		_trait_meters = TraitMeterScene.instantiate() as InspectorMeterList
		_traits_box.add_child(_trait_meters)
	if _effects_box != null and _effect_notes == null:
		_effect_notes = EffectNoteScene.instantiate() as InspectorNoteList
		_effects_box.add_child(_effect_notes)
	_paint_waiting_guide()


func _set_shell_icon(icon: IconBadge, key: StringName, accent: Color) -> void:
	if icon != null:
		icon.set_semantic(key, accent)


func _on_source_pick_pressed() -> void:
	if _source_first:
		return
	if _source_picking:
		cancel_source_selection()
		return
	_source_pick_armed = true
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
	if _population_slider == null or _population == null:
		return
	_population_slider.min_value = _population.min_value
	_population_slider.max_value = maxf(_population.min_value, _population.max_value)
	_population_slider.set_value_no_signal(_population.value)


func _refresh_route_stepper(source_name: String, family_name: String) -> void:
	if _source_pick_button == null:
		return
	_source_pick_button.disabled = _source_first
	if _source_first or _source_filter >= 0:
		_source_pick_button.text = source_name
	elif _source_picking:
		_source_pick_button.text = "正在选出发城"
	else:
		_source_pick_button.text = "地图点选出发城"
	_source_pick_button.tooltip_text = "出发城已由家族档案锁定" if _source_first \
		else "在地图上点选青绿环，或点击城市卡片"
	if _family_step_label != null:
		var waiting_family := _selected_quote.is_empty()
		_family_step_label.text = "待选世家" if waiting_family else family_name
		_family_step_label.add_theme_color_override("font_color",
			UITokens.ARCHIVE_INK_MUTED if waiting_family else UITokens.DOSSIER_OXBLOOD)
	_tint_step(_source_pick_button, _source_picking, _source_filter >= 0)
	_tint_step(_target_button, _target_picking, _target_cell >= 0)
	_set_shell_icon(_source_step_icon, &"metric.territory",
		UITokens.DOSSIER_BRASS if _source_filter >= 0 else UITokens.DOSSIER_VERDIGRIS)
	_set_shell_icon(_family_step_icon, &"family.house",
		UITokens.DOSSIER_OXBLOOD if not _selected_quote.is_empty() else UITokens.ARCHIVE_INK_MUTED)
	_set_shell_icon(_target_step_icon, &"system.target",
		UITokens.DOSSIER_BRASS if _target_cell >= 0 else UITokens.ARCHIVE_INK_MUTED)


func _tint_step(button: Button, active: bool, chosen: bool) -> void:
	if button == null:
		return
	var color := UITokens.DOSSIER_OXBLOOD if active else (
		UITokens.ARCHIVE_INK if chosen else UITokens.ARCHIVE_INK_MUTED)
	button.add_theme_color_override("font_color", color)
	button.add_theme_color_override("font_hover_color", color)
	button.add_theme_color_override("font_pressed_color", UITokens.DOSSIER_OXBLOOD)


func _refresh_city_cards() -> void:
	if _city_cards_box == null or _source_city == null:
		return
	var show_picker := _current_tab == "quotes" and not _source_first \
		and _source_city.item_count > 1 and (_source_filter < 0 or _source_picking)
	if _city_picker != null:
		_city_picker.visible = show_picker
	if not show_picker:
		return
	var prompt := get_node_or_null("%CityPromptLabel") as Label
	if prompt != null:
		prompt.text = "正在地图上点选出发城，也可点击卡片" if _source_picking \
			else "地图点选出发城市，或点击下方城市卡片"
	if _city_cards_identity != _source_cities_identity:
		_city_cards_identity = _source_cities_identity
		for child in _city_cards_box.get_children():
			_city_cards_box.remove_child(child)
			child.queue_free()
		_city_card_buttons.clear()
		for index in range(1, _source_city.item_count):
			var card := FamilyRowScene.instantiate() as Button
			var city_name := _source_city.get_item_text(index)
			card.set_compact_summary({
				"name": city_name,
				"population_text": "出发",
				"population_tooltip": "选择这座城作为出发地",
				"effect": "点击卡片，或点地图上的青绿环",
				"icon": "metric.territory",
				"accent": UITokens.DOSSIER_VERDIGRIS,
				"tag_text": "可出发",
				"tag_color": UITokens.DOSSIER_VERDIGRIS,
				"bar_ratio": 1.0,
				"bar_color": UITokens.DOSSIER_VERDIGRIS,
			})
			card.set_meta("source_index", index)
			card.pressed.connect(_on_city_card_pressed.bind(card))
			_city_cards_box.add_child(card)
			_city_card_buttons.append(card)
	for card in _city_card_buttons:
		if not is_instance_valid(card):
			continue
		var index := int(card.get_meta("source_index", -1))
		card.set_pressed_no_signal(index >= 0 and _source_city.get_item_id(index) == _source_filter)
	if _source_filter < 0:
		_maybe_arm_source_pick()


func _maybe_arm_source_pick() -> void:
	if _target_picking or _source_picking or not _source_pick_armed or _source_first or _source_filter >= 0:
		return
	begin_source_selection()


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
	if _guide_card != null:
		_guide_card.visible = guide
	if _identity_card != null:
		_identity_card.visible = identity
	if _route_card != null:
		_route_card.visible = route
	if _traits_card != null:
		_traits_card.visible = traits
	if _effects_card != null:
		_effects_card.visible = effects


func _paint_waiting_guide() -> void:
	_show_preview_cards(true, false, false, false, false)
	if _guide_title != null:
		_guide_title.text = "家族开拓与迁徙卷宗"
	if _guide_facts != null:
		var source_name := _source_city.text if _source_city != null and _source_filter >= 0 else "待选"
		_guide_facts.set_facts([
			{"id": "source", "title": "出发", "value": source_name,
				"subtitle": "地图青绿环", "icon": "metric.territory",
				"accent": UITokens.DOSSIER_VERDIGRIS},
			{"id": "family", "title": "世家", "value": "待选",
				"subtitle": "悬停预览，点击固定", "icon": "family.house",
				"accent": UITokens.DOSSIER_BRASS},
			{"id": "target", "title": "目的地", "value": _cell_name(_target_cell) if _target_cell >= 0 else "待选",
				"subtitle": "地图黄环", "icon": "system.target",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if _guide_notes != null:
		_guide_notes.set_notes([])
		_guide_notes.visible = false


func _paint_identity_card(quote: Dictionary, branch: Dictionary, hovering: bool) -> void:
	_show_preview_cards(false, true, _route_card.visible if _route_card != null else false,
		_traits_card.visible if _traits_card != null else false,
		_effects_card.visible if _effects_card != null else false)
	var people := float(branch.get("populations", quote.get("population",
		int(quote.get("maximum_population", 0)) + 1)))
	var maximum := float(quote.get("maximum_population", 0))
	var prestige_value: Variant = branch.get("prestige_levels", quote.get("prestige_level", 0))
	var prestige_number := float(prestige_value) if typeof(prestige_value) in [TYPE_INT, TYPE_FLOAT] else 0.0
	var buildings := str(branch.get("owned_buildings", quote.get("owned_buildings", "—")))
	var cash := float(branch.get("cash_claims", quote.get("cash_claim", 0))) / 10000.0
	var city_name := _source_city.text if _source_city != null and _source_filter >= 0 else "待选城市"
	if _preview_crest != null:
		_preview_crest.set_semantic(
			&"family.workspace.crest" if prestige_number >= 1.0 else &"family.house",
			UITokens.DOSSIER_OXBLOOD if prestige_number >= 3.0 else UITokens.DOSSIER_BRASS)
	if _preview_origin != null:
		_preview_origin.text = "从%s出发" % city_name
	if _preview_state_pill != null:
		_preview_state_pill.text = "预览" if hovering else ("迁徙" if _title != null and _title.text == "迁徙" else "开拓")
	if _preview_facts != null:
		_preview_facts.set_facts([
			{"id": "people", "title": "当地族人",
				"value": UITokens.format_compact_number_cn(people, 0),
				"subtitle": "人", "icon": "family.metric.population",
				"accent": UITokens.DOSSIER_OXBLOOD},
			{"id": "works", "title": "产业", "value": buildings,
				"subtitle": "本地", "icon": "economy.building",
				"accent": UITokens.DOSSIER_UMBER},
			{"id": "cash", "title": "资金归属",
				"value": UITokens.format_compact_number_cn(cash, 2),
				"subtitle": "随队", "icon": "metric.treasury",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if _preview_meters != null:
		_preview_meters.set_meters([
			{"id": "dispatch", "label": "可派",
				"value": clampf(maximum / maxf(people, 1.0), 0.0, 1.0),
				"value_text": "%s / %s" % [
					UITokens.format_compact_number_cn(maximum, 0),
					UITokens.format_compact_number_cn(people, 0)],
				"accent": UITokens.GOOD},
			{"id": "prestige", "label": "威望",
				"value": clampf(prestige_number / 5.0, 0.0, 1.0),
				"value_text": str(prestige_value),
				"accent": UITokens.WARN},
		])


func _paint_trait_card(traits: Dictionary) -> void:
	var names: PackedStringArray = traits.get("display_names", PackedStringArray())
	var descriptions: PackedStringArray = traits.get("descriptions", PackedStringArray())
	var core: PackedByteArray = traits.get("core", PackedByteArray())
	var show := not names.is_empty()
	if _traits_card != null:
		_traits_card.visible = show
	if not show:
		return
	var meters: Array = []
	for index in range(names.size()):
		var description := descriptions[index] if index < descriptions.size() else ""
		var is_core := index < core.size() and core[index] != 0
		var factor := FamilyBuffCopy.trait_factor_percent(description)
		var badges: Array[Dictionary] = FamilyBuffCopy.extract_trait_badges(description)
		var readout := str(badges[0].get("text", "")) if not badges.is_empty() else ("核心" if is_core else "附加")
		meters.append({
			"id": "trait-%d" % index,
			"label": String(names[index]),
			"value": clampf(factor / 200.0, 0.0, 1.0),
			"value_text": readout,
			"status_label": "核心" if is_core else "附加",
			"tooltip": description,
			"accent": UITokens.RISK if is_core else UITokens.WARN,
		})
	if _trait_meters != null:
		_trait_meters.set_meters(meters)
	var preferences: PackedStringArray = traits.get("behavior_selector_display_names", PackedStringArray())
	var pref_kicker := get_node_or_null("%PrefKicker") as Label
	if pref_kicker != null:
		pref_kicker.visible = not preferences.is_empty()
	if _pref_badges != null:
		_pref_badges.visible = not preferences.is_empty()
		var badges: Array = []
		for preference in preferences:
			badges.append({"text": String(preference), "accent": UITokens.DOSSIER_BRASS})
		_pref_badges.set_badges(badges)


func _paint_effect_card(effects: Dictionary) -> void:
	var names: PackedStringArray = effects.get("effect_display_names", PackedStringArray())
	var copy: PackedStringArray = effects.get("effect_current_descriptions",
		effects.get("effect_descriptions", PackedStringArray()))
	var show := not names.is_empty()
	if _effects_card != null:
		_effects_card.visible = show
	if not show or _effect_notes == null:
		return
	var notes: Array = []
	for index in range(mini(names.size(), 4)):
		var description := String(copy[index]) if index < copy.size() else ""
		var text := String(names[index])
		if not description.is_empty():
			text += " · " + description
		notes.append({
			"id": "effect-%d" % index,
			"text": text,
			"accent": UITokens.DOSSIER_VERDIGRIS if index == 0 else UITokens.DOSSIER_UMBER,
		})
	_effect_notes.set_notes(notes)


func _preview_party_count(quote: Dictionary) -> float:
	if not _preview_hovering and _population != null and not _selected_quote.is_empty():
		return float(_population.value)
	return float(quote.get("maximum_population", 0))


func _paint_route_card(quote: Dictionary) -> void:
	if _route_card == null:
		return
	if _preview_family <= 0 and _selected_quote.is_empty():
		return
	_route_card.visible = true
	var waiting := _target_cell < 0
	if _route_ready_pill != null:
		if waiting:
			_route_ready_pill.text = "待选落点"
		elif bool(quote.get("kit_partial", false)) and bool(quote.get("kit_place_buildings", false)):
			_route_ready_pill.text = "先筹备"
		elif bool(quote.get("kit_partial", false)):
			_route_ready_pill.text = "基础物资"
		else:
			_route_ready_pill.text = "可安家"
	if _route_facts != null:
		_route_facts.set_facts([
			{"id": "target", "title": "目的地", "value": _cell_name(_target_cell),
				"subtitle": "地图点选", "icon": "system.target",
				"accent": UITokens.DOSSIER_BRASS},
			{"id": "days", "title": "行程",
				"value": "待计算" if waiting else "%d 日" % int(quote.get("travel_days", 1)),
				"subtitle": "预计抵达", "icon": "family.metric.time",
				"accent": UITokens.DOSSIER_UMBER},
			{"id": "party", "title": "随行",
				"value": UITokens.format_compact_number_cn(_preview_party_count(quote), 0),
				"subtitle": "人", "icon": "family.metric.population",
				"accent": UITokens.DOSSIER_OXBLOOD},
		])
	var badges := _kit_badge_items(quote)
	if _kit_badges != null:
		_kit_badges.visible = not badges.is_empty()
		_kit_badges.set_badges(badges)
	var kicker := get_node_or_null("%KitKicker") as Label
	if kicker != null:
		kicker.visible = not badges.is_empty()
	if _route_notes != null:
		# 路线状态由 pill / facts / kit badges 表达，不再附修饰性引导批注。
		_route_notes.set_notes([])
		_route_notes.visible = false


func _kit_badge_items(quote: Dictionary) -> Array:
	var badges: Array = []
	var names: PackedStringArray = quote.get("kit_building_display_names", PackedStringArray())
	var counts: PackedInt64Array = quote.get("kit_building_counts", PackedInt64Array())
	for index in range(names.size()):
		var label := String(names[index]).strip_edges()
		if label.is_empty() or label.contains("_") or label.contains("."):
			continue
		var count := int(counts[index]) if index < counts.size() else 1
		badges.append({"text": "%s ×%d" % [label, count], "accent": UITokens.DOSSIER_VERDIGRIS})
	var professions: PackedStringArray = quote.get("profession_display_names", PackedStringArray())
	var populations: PackedInt64Array = quote.get("profession_populations", PackedInt64Array())
	for index in range(professions.size()):
		var label := String(professions[index]).strip_edges()
		if label.is_empty() or label.contains("_") or label.contains("."):
			continue
		var count := int(populations[index]) if index < populations.size() else 0
		var text := label if count <= 0 else "%s %s人" % [label, UITokens.format_compact_number_cn(float(count), 0)]
		badges.append({"text": text, "accent": UITokens.DOSSIER_BRASS})
	return badges


func _paint_expedition_card(title: String, metrics: String, effects: String, route: String) -> void:
	_show_preview_cards(false, true, true, false, false)
	if _preview_origin != null:
		_preview_origin.text = metrics
	if _preview_state_pill != null:
		_preview_state_pill.text = "在途"
	if _preview_crest != null:
		_preview_crest.set_semantic(&"action.history", UITokens.DOSSIER_BRASS)
	if _preview_facts != null:
		_preview_facts.set_facts([
			{"id": "party", "title": "队伍", "value": title,
				"subtitle": "点击列表查看", "icon": "action.history",
				"accent": UITokens.DOSSIER_BRASS},
		])
	if _preview_meters != null:
		_preview_meters.set_meters([])
	if _route_ready_pill != null:
		_route_ready_pill.text = "在途"
	if _route_facts != null:
		_route_facts.set_facts([
			{"id": "due", "title": "抵达", "value": route if not route.is_empty() else "筹备中",
				"subtitle": "进度", "icon": "family.metric.time",
				"accent": UITokens.DOSSIER_UMBER},
		])
	if _route_notes != null:
		if effects.is_empty():
			_route_notes.set_notes([])
			_route_notes.visible = false
		else:
			_route_notes.visible = true
			_route_notes.set_notes([{
				"id": "block", "text": effects, "accent": UITokens.DOSSIER_BRASS,
			}])
	if _kit_badges != null:
		_kit_badges.visible = false
	var kicker := get_node_or_null("%KitKicker") as Label
	if kicker != null:
		kicker.visible = false
