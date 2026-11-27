class_name ColonizationPlannerPanel
extends PanelContainer

const MapWorkflow = preload("res://scripts/ui/components/colonization_map_workflow.gd")

const QuoteDetails = preload("res://scripts/ui/components/colonization_quote_details.gd")

const PlannerLists = preload("res://scripts/ui/components/colonization_planner_lists.gd")

const PlannerControls = preload("res://scripts/ui/components/colonization_planner_controls.gd")
const ColonizationKitStatusText = preload("res://scripts/ui/components/colonization_kit_status_text.gd")

const PlannerLabels = preload("res://scripts/ui/components/colonization_planner_labels.gd")

const PlannerPresentation = preload("res://scripts/ui/components/colonization_planner_presentation.gd")
const FamilyRowScene := preload("res://scenes/ui/colonization_family_row.tscn")
const TraitMeterScene := preload("res://scenes/ui/inspector_meter_list.tscn")
const EffectNoteScene := preload("res://scenes/ui/inspector_note_list.tscn")
const TouchUI := preload("res://scripts/ui/touch_ui.gd")

# 路线失败时玩家看到的说明。原生只回 `colonization_route_*` 错误码（或把它塞进
# message），不解释原因；水面在拓扑里是 `passable=0` 的走廊而不是可走地块，
# 所以「跨不过水」在 UI 上表现为「没有城市能到达」，必须在这里把科技门槛讲清楚。
const ROUTE_BLOCKED_SHORT = PlannerLabels.ROUTE_BLOCKED_SHORT
const ROUTE_WATER_HINT = PlannerLabels.ROUTE_WATER_HINT
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
var _pending_quote_reads: Dictionary = {}
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
	PlannerControls._ready(self)


func set_player_controller(controller) -> void:
	if _controller == controller:
		return
	var ready := _on_colonization_quotes_ready
	if _controller != null and is_instance_valid(_controller) \
			and _controller.has_signal("colonization_quotes_ready") \
			and _controller.colonization_quotes_ready.is_connected(ready):
		_controller.colonization_quotes_ready.disconnect(ready)
	_pending_quote_reads.clear()
	_controller = controller
	if _controller != null and is_instance_valid(_controller) \
			and _controller.has_signal("colonization_quotes_ready") \
			and not _controller.colonization_quotes_ready.is_connected(ready):
		_controller.colonization_quotes_ready.connect(ready)


func _await_quote_read(key: StringName, response: Dictionary, retry: Callable) -> bool:
	var pending := not bool(response.get("ok", false)) and (
		bool(response.get("pending", false)) or bool(response.get("read_view_pending", false)))
	if not pending:
		_pending_quote_reads.erase(key)
		return false
	_pending_quote_reads[key] = retry
	return true


func _clear_pending_quote_reads(key: StringName = &"") -> void:
	if key == &"":
		_pending_quote_reads.clear()
	else:
		_pending_quote_reads.erase(key)


func _on_colonization_quotes_ready() -> void:
	if not visible or _pending_quote_reads.is_empty():
		return
	var pending := _pending_quote_reads.duplicate()
	_pending_quote_reads.clear()
	for callback in pending.values():
		if callback is Callable and (callback as Callable).is_valid():
			(callback as Callable).call()


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
	_clear_pending_quote_reads()
	_preview_cache.clear()
	_quote_preview_cache.clear()
	_pending_quote_reads.clear()
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
	elif is_inside_tree():
		(get_node("%CloseButton") as Button).grab_focus()


func _layout_left_panel() -> void:
	PlannerPresentation._layout_left_panel(self)


func _apply_narrow_density(narrow: bool) -> void:
	PlannerPresentation._apply_narrow_density(self, narrow)


func close_panel() -> void:
	if not visible:
		return
	visible = false
	_pending_quote_reads.clear()
	_target_picking = false
	_source_picking = false
	_hover_timer.stop()
	_clear_pending_quote_reads()
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
			_feedback.text = EconomyStatusCopy.BUSY
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
		_pending_quote_reads.clear()
		_show_expeditions()
	else:
		_show_quotes()


func _load_source_cities() -> Dictionary:
	return PlannerLists._load_source_cities(self)


func _on_source_city_selected(index: int) -> void:
	PlannerLists._on_source_city_selected(self, index)


func _show_quotes() -> void:
	PlannerLists._show_quotes(self)


func _sync_quote_rows(quotes: Array, keep_population: int) -> bool:
	return PlannerLists._sync_quote_rows(self, quotes, keep_population)


func _on_reusable_quote_pressed(row: Button) -> void:
	PlannerLists._on_reusable_quote_pressed(self, row)


func _on_quote_row_pressed(quote: Dictionary, row: Button) -> void:
	PlannerLists._on_quote_row_pressed(self, quote, row)


func _select_quote(quote: Dictionary) -> void:
	PlannerLists._select_quote(self, quote)


func _submit_selected() -> void:
	PlannerLists._submit_selected(self)


func _show_expeditions() -> void:
	PlannerLists._show_expeditions(self)


func _filter_expedition_page(page: Dictionary) -> Dictionary:
	return PlannerLists._filter_expedition_page(self, page)


func _sync_expedition_rows(page: Dictionary) -> void:
	PlannerLists._sync_expedition_rows(self, page)


func _on_reusable_expedition_pressed(row: Button) -> void:
	PlannerLists._on_reusable_expedition_pressed(self, row)


func open_expeditions() -> void:
	PlannerLists.open_expeditions(self)


func _expedition_page() -> Dictionary:
	return PlannerLists._expedition_page(self)


func _refresh_expedition_detail() -> void:
	PlannerLists._refresh_expedition_detail(self)


func _clear_list() -> void:
	PlannerLists._clear_list(self)


func _discard_quote_rows() -> void:
	PlannerLists._discard_quote_rows(self)


func _discard_expedition_rows() -> void:
	PlannerLists._discard_expedition_rows(self)


func _remove_note_children() -> void:
	PlannerLists._remove_note_children(self)


func _add_note(text: String, color: Color) -> void:
	PlannerLists._add_note(self, text, color)


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
	return PlannerLabels._state_text(state)


## 原生有些失败会把具体原因写进 `message` 而不是 `code`
## （`colonization_requote_required` + `message="colonization_route_unreachable"`）。
## 把裸错误码贴进反馈栏比不给理由更糟，这里统一先按错误码翻一遍。
static func _diagnostic_message(code: String, raw_message: String) -> String:
	return PlannerLabels._diagnostic_message(code, raw_message)


static func _reason_text(code: String) -> String:
	return PlannerLabels._reason_text(code)


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
	_status.tooltip_text = EconomyStatusCopy.BUSY
	_status.add_theme_color_override("font_color", UITokens.WARN)


func _refresh_selected_kit() -> void:
	QuoteDetails._refresh_selected_kit(self)


func _update_start_enabled() -> void:
	QuoteDetails._update_start_enabled(self)


static func _transient_query_failure(code: String, page: Dictionary) -> bool:
	return QuoteDetails._transient_query_failure(code, page)


func _has_quote_rows() -> bool:
	return QuoteDetails._has_quote_rows(self)


func _has_expedition_rows() -> bool:
	return QuoteDetails._has_expedition_rows(self)


static func _quotes_identity_of(page: Dictionary) -> String:
	return QuoteDetails._quotes_identity_of(page)


static func _expeditions_identity_of(page: Dictionary) -> String:
	return QuoteDetails._expeditions_identity_of(page)


func _preparing_missing_text(handle: int, state: int, snapshot: Dictionary = {}, include_progress: bool = true) -> String:
	return QuoteDetails._preparing_missing_text(self, handle, state, snapshot, include_progress)


func _expedition_row_tooltip(handle: int, state: int, due_day: int) -> String:
	return QuoteDetails._expedition_row_tooltip(self, handle, state, due_day)


func _quotes_for_source(page: Dictionary) -> Array:
	return QuoteDetails._quotes_for_source(self, page)


static func _family_display_name(surname: String, disambiguator: int) -> String:
	return QuoteDetails._family_display_name(surname, disambiguator)


static func _kit_summary_text(quote: Dictionary) -> String:
	return QuoteDetails._kit_summary_text(quote)


func _family_view_for(family_handle: int, fallback_people: int) -> Dictionary:
	return QuoteDetails._family_view_for(self, family_handle, fallback_people)


func open_source(source_cell: int, family_handle: int) -> void:
	MapWorkflow.open_source(self, source_cell, family_handle)


func _scroll_to_pinned_family() -> void:
	if not is_inside_tree():
		return
	await get_tree().process_frame
	var row := _quote_row_refs.get(_quote_key(_selected_quote)) as Control
	if visible and row != null:
		(get_node("%RowsScroll") as ScrollContainer).ensure_control_visible(row)


func begin_target_selection() -> void:
	MapWorkflow.begin_target_selection(self)


func cancel_target_selection() -> void:
	MapWorkflow.cancel_target_selection(self)


func is_target_picking() -> bool:
	return MapWorkflow.is_target_picking(self)


func begin_source_selection() -> void:
	MapWorkflow.begin_source_selection(self)


func cancel_source_selection() -> void:
	MapWorkflow.cancel_source_selection(self)


func is_source_picking() -> bool:
	return MapWorkflow.is_source_picking(self)


func map_stage() -> StringName:
	return MapWorkflow.map_stage(self)


func handle_map_cell(cell: int) -> bool:
	return MapWorkflow.handle_map_cell(self, cell)


func _select_source_cell(cell: int) -> bool:
	return MapWorkflow._select_source_cell(self, cell)


func try_target_cell(cell: int, quiet: bool = false, on_read: Callable = Callable()) -> bool:
	return MapWorkflow.try_target_cell(self, cell, quiet, on_read)


func _set_feedback_line(message: String, color: Color, tooltip: String = "") -> void:
	MapWorkflow._set_feedback_line(self, message, color, tooltip)


func _cell_name(cell: int) -> String:
	return MapWorkflow._cell_name(self, cell)


func _update_workflow() -> void:
	MapWorkflow._update_workflow(self)


func _stage_hint() -> String:
	return MapWorkflow._stage_hint(self)


func _load_local_families(source_cell: int = -1) -> Dictionary:
	return MapWorkflow._load_local_families(self, source_cell)


func _get_source_quotes() -> Dictionary:
	return MapWorkflow._get_source_quotes(self)


func _show_source_families() -> void:
	MapWorkflow._show_source_families(self)


static func _quote_key(quote: Dictionary) -> String:
	return MapWorkflow._quote_key(quote)


func _apply_list_filter_sort() -> void:
	MapWorkflow._apply_list_filter_sort(self)


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
		_clear_pending_quote_reads(&"hover")
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
