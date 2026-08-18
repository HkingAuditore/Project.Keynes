extends PanelContainer
class_name ColonizationPlannerPanel

const FamilyRowScene := preload("res://scenes/ui/colonization_family_row.tscn")

signal closed()
signal route_requested(detail: Dictionary)
signal route_cleared()
signal start_requested(args: Dictionary)
signal cancel_requested(expedition_handle: int)
signal expedition_selected(expedition_handle: int)

var _controller
var _target_cell := -1
var _family_filter := 0
var _source_filter := -1
var _selected_quote: Dictionary = {}
var _economy_busy := false
var _quotes_identity := ""
var _expeditions_identity := ""
var _family_view_cache: Dictionary = {}
var _current_tab := "quotes"
var _title: Label
var _subtitle: Label
var _status: Label
var _tabs: CategoryTabs
var _list: VBoxContainer
var _population_row: HBoxContainer
var _population: SpinBox
var _feedback: Label
var _start: Button


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
	var close_button := get_node_or_null("%CloseButton") as Button
	if _title == null or _subtitle == null or _status == null or _tabs == null \
			or _list == null or _population_row == null or _population == null \
			or _feedback == null or _start == null or close_button == null:
		push_error("ColonizationPlannerPanel 必须通过 colonization_planner_panel.tscn 实例化。")
		return
	theme_type_variation = &"PKDialog"
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_panel)
	_tabs.set_tabs([
		{"id": "quotes", "label": "可派遣", "icon": "family.house",
			"tooltip": "可派往此地的家族", "accent": UITokens.ACCENT},
		{"id": "expeditions", "label": "在途", "icon": "action.history",
			"tooltip": "已出发的开拓队", "accent": UITokens.CLIMATE},
	], "quotes", true)
	_tabs.tab_selected.connect(_on_tab_selected)
	_population.value_changed.connect(func(_value: float) -> void:
		_refresh_selected_kit())
	_start.pressed.connect(_submit_selected)
	visible = false


func set_player_controller(controller) -> void:
	_controller = controller


func open_target(target_cell: int, family_filter: int = 0,
		source_filter: int = -1) -> void:
	if _list == null:
		_ready()
	_target_cell = target_cell
	_family_filter = family_filter
	_source_filter = source_filter
	_selected_quote.clear()
	_quotes_identity = ""
	_expeditions_identity = ""
	_family_view_cache.clear()
	_economy_busy = false
	_title.text = "开拓"
	_subtitle.text = "选择要派遣的家族"
	_feedback.text = ""
	visible = true
	if is_inside_tree():
		UIAnimation.fade_slide_in(self, Vector2(0.0, 18.0))
	_show_quotes()


func close_panel() -> void:
	if not visible:
		return
	visible = false
	_selected_quote.clear()
	route_cleared.emit()
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
		_feedback.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
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
		if _economy_busy:
			if _controller != null and _has_quote_rows():
				var probe: Dictionary = _controller.get_family_expeditions(0, 1)
				if bool(probe.get("ok", true)) and probe.has("busy") \
						and bool(probe.get("busy", false)):
					return
			_show_quotes()
		elif not _has_quote_rows():
			_show_quotes()
		return
	_show_expeditions()


func _on_tab_selected(tab_id: String) -> void:
	if tab_id == "expeditions":
		_show_expeditions()
	else:
		_show_quotes()


func _show_quotes() -> void:
	_current_tab = "quotes"
	if _tabs != null:
		_tabs.select_tab("quotes")
	if _controller == null:
		_clear_list()
		_quotes_identity = ""
		_set_busy_status(false)
		_add_note("玩家控制器尚未就绪。", UITokens.RISK)
		_update_start_enabled()
		return
	var page: Dictionary = _controller.get_family_colonization_quotes(
		_target_cell, _family_filter, _source_filter, 0, 128)
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
			_add_note("正在等待经济提交完成后显示可派遣家族。", UITokens.TEXT_MUTED)
			_update_start_enabled()
			return
		_clear_list()
		_quotes_identity = ""
		_selected_quote.clear()
		_set_busy_status(_economy_busy)
		_add_note(_reason_text(code), UITokens.RISK)
		_update_start_enabled()
		return
	var identity := _quotes_identity_of(page)
	if identity == _quotes_identity and _has_quote_rows():
		_apply_kind(String(page.get("kind", "colonize")))
		_set_busy_status(_economy_busy)
		_update_start_enabled()
		return
	_quotes_identity = identity
	_clear_list()
	_apply_kind(String(page.get("kind", "colonize")))
	_set_busy_status(_economy_busy)
	var quotes := _collapse_quotes(page)
	var keep_population := int(_population.value) if not _selected_quote.is_empty() else 0
	var restored := false
	for quote in quotes:
		var family_handle := int(quote.get("family_handle", 0))
		var maximum_population := int(quote.get("maximum_population", 0))
		var decorated: Dictionary = quote
		decorated.merge(_family_view_for(family_handle,
			maximum_population + 1), true)
		var row := FamilyRowScene.instantiate()
		row.set_row({
			"name": String(decorated.get("display_name", "家族")),
			"population": int(decorated.get("family_population",
				maximum_population + 1)),
			"badges": decorated.get("trait_badges", []),
			"effect": String(decorated.get("effect_text", "")),
			"tooltip": _quote_tooltip(quote),
		})
		row.pressed.connect(_on_quote_row_pressed.bind(decorated, row))
		_list.add_child(row)
		if int(_selected_quote.get("family_handle", 0)) == family_handle:
			row.set_pressed_no_signal(true)
			_selected_quote = decorated.duplicate(true)
			var maximum := maxi(1, maximum_population)
			_population.max_value = maximum
			_population.value = clampi(keep_population, 1, maximum) \
				if keep_population > 0 else maximum
			restored = true
	if quotes.is_empty():
		if _economy_busy:
			_add_note("经济正在结算。家族列表将在提交后刷新，也可先查看在途队伍。",
				UITokens.TEXT_MUTED)
		else:
			_add_note("没有可派遣的家族。", UITokens.WARN)
	if restored:
		_refresh_selected_kit()
	else:
		_update_start_enabled()


func _on_quote_row_pressed(quote: Dictionary, row: Button) -> void:
	for child in _list.get_children():
		if child is Button and child != row:
			(child as Button).set_pressed_no_signal(false)
	row.set_pressed_no_signal(true)
	_select_quote(quote)


func _select_quote(quote: Dictionary) -> void:
	_selected_quote = quote.duplicate(true)
	var maximum := maxi(1, int(quote.get("maximum_population", 1)))
	_population.max_value = maximum
	_population.value = maximum
	_refresh_selected_kit()


func _submit_selected() -> void:
	if _selected_quote.is_empty():
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
	_selected_quote.clear()
	_update_start_enabled()
	if _controller == null:
		_clear_list()
		_expeditions_identity = ""
		_set_busy_status(false)
		return
	var page: Dictionary = _controller.get_family_expeditions(0, 128)
	_economy_busy = bool(page.get("busy", false))
	if not bool(page.get("ok", false)):
		var code := String(page.get("code", "command_rejected"))
		if _transient_query_failure(code, page):
			_economy_busy = true
			_set_busy_status(true)
			_clear_list()
			_expeditions_identity = ""
			_add_note("正在等待经济提交完成后显示在途队伍。", UITokens.TEXT_MUTED)
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
	_clear_list()
	_set_busy_status(_economy_busy)
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var populations: PackedInt64Array = page.get("populations", PackedInt64Array())
	var dues: PackedInt64Array = page.get("due_days", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	for index in range(handles.size()):
		var family_handle := int(families[index]) if index < families.size() else 0
		var view: Dictionary = _family_view_for(family_handle, int(populations[index]))
		var state := int(states[index]) if index < states.size() else 0
		var returning := state == 3
		var row_wrap := HBoxContainer.new()
		row_wrap.add_theme_constant_override("separation", UITokens.SPACE_SM)
		var row := FamilyRowScene.instantiate()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.set_row({
			"name": String(view.get("display_name", "家族")),
			"population": int(populations[index]) if index < populations.size() else 0,
			"badges": [{
				"text": _state_text(state),
				"accent": UITokens.WARN if returning else UITokens.ACCENT,
			}],
			"effect": "",
			"tooltip": "第 %d 日抵达" % int(dues[index]) if index < dues.size() else "",
		})
		row.toggle_mode = false
		row.pressed.connect(expedition_selected.emit.bind(int(handles[index])))
		row_wrap.add_child(row)
		var cancel := Button.new()
		cancel.text = "取消"
		cancel.focus_mode = Control.FOCUS_NONE
		cancel.theme_type_variation = &"PKTabButton"
		cancel.custom_minimum_size = Vector2(64.0, 36.0)
		cancel.disabled = returning
		if returning:
			cancel.tooltip_text = "返程中的队伍不能重复取消"
		else:
			cancel.tooltip_text = "按当前进度返程；结算中会先排队，提交完成后执行"
		cancel.pressed.connect(cancel_requested.emit.bind(int(handles[index])))
		row_wrap.add_child(cancel)
		_list.add_child(row_wrap)
	if handles.is_empty():
		if _economy_busy:
			_add_note("经济正在结算。在途队伍将在提交后刷新。", UITokens.TEXT_MUTED)
		else:
			_add_note("当前没有活动开拓队。", UITokens.TEXT_MUTED)


func _clear_list() -> void:
	for child in _list.get_children():
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
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close_panel()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_RIGHT:
		close_panel()
		get_viewport().set_input_as_handled()


static func _state_text(state: int) -> String:
	return {1: "前往中", 2: "落地结算中", 3: "返程中"}.get(state, "未知")


static func _reason_text(code: String) -> String:
	return {
		"colonization_target_invalid": "目标必须是当前可见、可通行的无主或本国陆地。",
		"colonization_population_insufficient": "源分支人口不足，必须至少留下一人。",
		"colonization_duplicate_target": "本国已有一支开拓队前往该目标。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"colonization_kit_requote_required": "目标资源或科技已经变化，请重新确认开工包。",
		"colonization_kit_materials_short": "源地市场库存不足，无法抽出开工包物资。",
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
	if kind == "relocate":
		_title.text = "迁徙"
		_subtitle.text = "向本国地块派遣家族人口"
	else:
		_title.text = "开拓"
		_subtitle.text = "选择要派遣的家族"


func _set_busy_status(busy: bool) -> void:
	if _status == null:
		return
	_status.visible = busy
	_status.text = "经济正在结算。可查看家族与在途队伍；派遣和取消会先排队，提交完成后自动执行。" \
		if busy else ""
	_status.add_theme_color_override("font_color", UITokens.WARN)


func _refresh_selected_kit() -> void:
	if _selected_quote.is_empty():
		_update_start_enabled()
		return
	var detail: Dictionary = {}
	if _controller != null:
		detail = _controller.get_family_colonization_quote_detail(
			int(_selected_quote.get("quote_token", 0)), int(_population.value))
	_economy_busy = _economy_busy or bool(detail.get("busy", false))
	if not bool(detail.get("ok", false)):
		_update_start_enabled()
		var detail_code := String(detail.get("code", "command_rejected"))
		if _transient_query_failure(detail_code, detail):
			_feedback.text = "经济正在结算，提交完成后即可派遣。"
			_feedback.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
			return
		_feedback.text = _reason_text(detail_code)
		_feedback.add_theme_color_override("font_color", UITokens.RISK)
		return
	_selected_quote.merge(detail, true)
	_update_start_enabled()
	route_requested.emit(detail)


func _update_start_enabled() -> void:
	if _start == null:
		return
	var on_quotes := _current_tab == "quotes"
	var has_selection := not _selected_quote.is_empty()
	_population_row.visible = on_quotes and has_selection
	_start.visible = on_quotes
	_start.disabled = not has_selection
	var count := int(_population.value) if has_selection else 0
	var count_text := UITokens.format_compact_number_cn(float(count), 0)
	var kit_partial := bool(_selected_quote.get("kit_partial", false))
	var place_buildings := bool(_selected_quote.get("kit_place_buildings", false))
	var kit_ids: PackedInt32Array = _selected_quote.get(
		"kit_building_ids", PackedInt32Array())
	var complete_kit := place_buildings and not kit_partial and not kit_ids.is_empty()
	if _economy_busy:
		_start.text = "排队派遣 %s 人" % count_text if has_selection else "排队派遣"
		_start.tooltip_text = "经济正在结算。现在确认后会排队，提交完成后自动出发。"
	elif complete_kit:
		_start.text = "派遣 %s 人并安家" % count_text if has_selection else "确认派遣"
		_start.tooltip_text = _kit_summary_text(_selected_quote)
	else:
		_start.text = "派遣 %s 人" % count_text if has_selection else "确认派遣"
		_start.tooltip_text = "建材不足，只携带口粮" if kit_partial \
			else _kit_summary_text(_selected_quote)
	if has_selection and kit_partial and not _economy_busy \
			and _feedback.text.find("排队") < 0 \
			and _feedback.text.find("已经出发") < 0:
		_feedback.text = "建材不足，只携带口粮"
		_feedback.add_theme_color_override("font_color", UITokens.WARN)


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
	if _list == null:
		return false
	for child in _list.get_children():
		if child is Button:
			return true
	return false


func _has_expedition_rows() -> bool:
	if _list == null:
		return false
	for child in _list.get_children():
		if child is HBoxContainer:
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
		parts.append("%d:%d" % [int(handles[index]), state])
	return "%s|%s" % [int(page.get("total", 0)), ",".join(parts)]


func _collapse_quotes(page: Dictionary) -> Array:
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var maximums: PackedInt64Array = page.get("maximum_populations", PackedInt64Array())
	var costs: PackedInt32Array = page.get("route_costs", PackedInt32Array())
	var days: PackedInt32Array = page.get("travel_days", PackedInt32Array())
	var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
	var surnames: PackedStringArray = page.get("surnames", PackedStringArray())
	var disambiguators: PackedInt32Array = page.get(
		"surname_disambiguators", PackedInt32Array())
	var best: Dictionary = {}
	for index in range(families.size()):
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
		if not best.has(handle) or _quote_better(candidate, best[handle]):
			best[handle] = candidate
	var quotes: Array = best.values()
	quotes.sort_custom(func(a, b) -> bool:
		return String(a.get("display_name", "")) < String(b.get("display_name", "")))
	return quotes


static func _quote_better(candidate: Dictionary, current: Dictionary) -> bool:
	var candidate_people := int(candidate.get("maximum_population", 0))
	var current_people := int(current.get("maximum_population", 0))
	if candidate_people != current_people:
		return candidate_people > current_people
	var candidate_cost := int(candidate.get("route_cost", 0))
	var current_cost := int(current.get("route_cost", 0))
	if candidate_cost != current_cost:
		return candidate_cost < current_cost
	return int(candidate.get("source_cell", 0)) < int(current.get("source_cell", 0))


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
		"kit_building_stable_ids", PackedStringArray())
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
			var surname := String(snapshot.get("surname", ""))
			var disambiguator := int(snapshot.get("surname_disambiguator", 0))
			if not surname.is_empty():
				view["display_name"] = _family_display_name(surname, disambiguator)
	if _controller != null and _controller.has_method("get_family_traits"):
		var traits: Dictionary = _controller.get_family_traits(family_handle)
		if bool(traits.get("ok", false)):
			view["trait_badges"] = _trait_badges(traits)
			view["effect_text"] = _effect_text(traits)
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
			"accent": UITokens.ACCENT if is_core else UITokens.TEXT_MUTED,
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
	if not parts.is_empty():
		return "偏好：%s" % "、".join(parts)
	var effect_names: PackedStringArray = traits.get(
		"effect_display_names", PackedStringArray())
	var effect_parts := PackedStringArray()
	for raw in effect_names:
		var label := String(raw).strip_edges()
		if label.is_empty() or seen.has(label):
			continue
		seen[label] = true
		effect_parts.append(label)
		if effect_parts.size() >= 3:
			break
	if not effect_parts.is_empty():
		return "效果：%s" % "、".join(effect_parts)
	var trait_names: PackedStringArray = traits.get(
		"display_names", PackedStringArray())
	return "暂无特性" if trait_names.is_empty() else ""
