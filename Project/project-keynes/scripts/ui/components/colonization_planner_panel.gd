extends PanelContainer
class_name ColonizationPlannerPanel

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
var _title: Label
var _subtitle: Label
var _list: VBoxContainer
var _population: SpinBox
var _composition: Label
var _route_summary: Label
var _feedback: Label
var _start: Button
var _quotes_button: Button
var _expeditions_button: Button


func _ready() -> void:
	if _list != null:
		return
	custom_minimum_size = Vector2(540.0, 0.0)
	var material := StyleBoxFlat.new()
	material.bg_color = UITokens.PANEL_BG
	material.border_color = UITokens.PANEL_BORDER
	material.set_border_width_all(1)
	material.corner_radius_top_left = UITokens.RADIUS_LG
	material.corner_radius_top_right = UITokens.RADIUS_LG
	material.corner_radius_bottom_left = UITokens.RADIUS_LG
	material.corner_radius_bottom_right = UITokens.RADIUS_LG
	material.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
	material.shadow_size = 14
	add_theme_stylebox_override("panel", material)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_LG)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin.add_child(root)
	var head := HBoxContainer.new()
	root.add_child(head)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(titles)
	_title = Label.new()
	_title.text = "家族开拓"
	_title.add_theme_font_override("font", UITokens.font_with_weight(700))
	_title.add_theme_font_size_override("font_size", UITokens.FONT_TITLE)
	titles.add_child(_title)
	_subtitle = Label.new()
	_subtitle.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	titles.add_child(_subtitle)
	var close := Button.new()
	close.text = "关闭"
	close.pressed.connect(close_panel)
	head.add_child(close)
	var tabs := HBoxContainer.new()
	root.add_child(tabs)
	_quotes_button = Button.new()
	_quotes_button.text = "分支报价"
	_quotes_button.toggle_mode = true
	_quotes_button.pressed.connect(_show_quotes)
	tabs.add_child(_quotes_button)
	_expeditions_button = Button.new()
	_expeditions_button.text = "在途队伍"
	_expeditions_button.toggle_mode = true
	_expeditions_button.pressed.connect(_show_expeditions)
	tabs.add_child(_expeditions_button)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0.0, 270.0)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", UITokens.SPACE_SM)
	scroll.add_child(_list)
	var population_row := HBoxContainer.new()
	root.add_child(population_row)
	var population_label := Label.new()
	population_label.text = "派遣人数"
	population_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	population_row.add_child(population_label)
	_population = SpinBox.new()
	_population.min_value = 1
	_population.max_value = 1
	_population.value = 1
	_population.allow_greater = false
	_population.custom_minimum_size.x = 150.0
	population_row.add_child(_population)
	_composition = Label.new()
	_composition.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_composition.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	root.add_child(_composition)
	_route_summary = Label.new()
	_route_summary.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	root.add_child(_route_summary)
	_feedback = Label.new()
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	root.add_child(_feedback)
	_start = Button.new()
	_start.text = "确认派遣"
	_start.disabled = true
	_start.pressed.connect(_submit_selected)
	root.add_child(_start)
	visible = false


func set_player_controller(controller) -> void:
	_controller = controller


func open_target(target_cell: int, family_filter: int = 0,
		source_filter: int = -1) -> void:
	_target_cell = target_cell
	_family_filter = family_filter
	_source_filter = source_filter
	_selected_quote.clear()
	_title.text = "家族开拓 · 目标地块 %d" % target_cell
	_subtitle.text = "仅显示路径完全可见且只经过本国或无主陆地的分支"
	_feedback.text = ""
	visible = true
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
	_feedback.text = message
	_feedback.add_theme_color_override("font_color",
		UITokens.GOOD if ok else UITokens.RISK)
	if ok:
		_show_expeditions()


func refresh_expeditions_if_visible() -> void:
	if visible and _expeditions_button.button_pressed:
		_show_expeditions()


func _show_quotes() -> void:
	_quotes_button.set_pressed_no_signal(true)
	_expeditions_button.set_pressed_no_signal(false)
	_start.visible = true
	_population.get_parent().visible = true
	_clear_list()
	if _controller == null:
		_add_note("玩家控制器尚未就绪。", UITokens.RISK)
		return
	var page: Dictionary = _controller.get_family_colonization_quotes(
		_target_cell, _family_filter, _source_filter, 0, 128)
	if not bool(page.get("ok", false)):
		_add_note(_reason_text(String(page.get("code", "command_rejected"))),
			UITokens.RISK)
		return
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var sources: PackedInt32Array = page.get("source_cells", PackedInt32Array())
	var maximums: PackedInt64Array = page.get("maximum_populations", PackedInt64Array())
	var costs: PackedInt32Array = page.get("route_costs", PackedInt32Array())
	var days: PackedInt32Array = page.get("travel_days", PackedInt32Array())
	var tokens: PackedInt64Array = page.get("quote_tokens", PackedInt64Array())
	var surnames: PackedStringArray = page.get("surnames", PackedStringArray())
	var disambiguators: PackedInt32Array = page.get(
		"surname_disambiguators", PackedInt32Array())
	for index in range(families.size()):
		var surname := String(surnames[index]) if index < surnames.size() else "家族"
		var disambiguator := int(disambiguators[index]) if index < disambiguators.size() else 0
		var label := "%s氏%s · 源地 %d · 最多 %s 人 · 成本 %d · %d 日" % [
			surname, "（%d）" % (disambiguator + 1) if disambiguator > 0 else "",
			int(sources[index]), UITokens.format_compact_number_cn(float(maximums[index]), 0),
			int(costs[index]), int(days[index])]
		var button := Button.new()
		button.text = label
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_select_quote.bind({
			"family_handle": int(families[index]), "source_cell": int(sources[index]),
			"target_cell": _target_cell, "maximum_population": int(maximums[index]),
			"route_cost": int(costs[index]), "travel_days": int(days[index]),
			"quote_token": int(tokens[index]), "surname": surname,
		}))
		_list.add_child(button)
	if families.is_empty():
		_add_note("没有满足人口、视野和通行条件的家族分支。", UITokens.WARN)


func _select_quote(quote: Dictionary) -> void:
	_selected_quote = quote
	_population.max_value = maxi(1, int(quote.maximum_population))
	_population.value = 1
	var detail: Dictionary = _controller.get_family_colonization_quote_detail(
		int(quote.quote_token))
	if not bool(detail.get("ok", false)):
		_start.disabled = true
		_feedback.text = _reason_text(String(detail.get("code", "command_rejected")))
		return
	_selected_quote.merge(detail, true)
	_route_summary.text = "路线成本 %d · 预计 %d 日抵达 · 抵达时重新核验目标归属" % [
		int(detail.get("route_cost", 0)), int(detail.get("travel_days", 1))]
	var names: PackedStringArray = detail.get(
		"profession_display_names", PackedStringArray())
	var populations: PackedInt64Array = detail.get(
		"profession_populations", PackedInt64Array())
	var parts := PackedStringArray()
	for index in range(mini(names.size(), populations.size())):
		parts.append("%s %s" % [String(names[index]),
			UITokens.format_compact_number_cn(float(populations[index]), 0)])
	_composition.text = "源分支职业构成：%s。抽取时失业人口优先，其余按比例。" % \
		("、".join(parts) if not parts.is_empty() else "暂无明细")
	_start.disabled = false
	route_requested.emit(detail)


func _submit_selected() -> void:
	if _selected_quote.is_empty():
		return
	start_requested.emit({
		"family_handle": int(_selected_quote.family_handle),
		"source_cell": int(_selected_quote.source_cell),
		"target_cell": int(_selected_quote.target_cell),
		"population": int(_population.value),
		"quote_token": int(_selected_quote.quote_token),
	})


func _show_expeditions() -> void:
	_quotes_button.set_pressed_no_signal(false)
	_expeditions_button.set_pressed_no_signal(true)
	_start.visible = false
	_population.get_parent().visible = false
	_composition.text = ""
	_route_summary.text = ""
	_clear_list()
	if _controller == null:
		return
	var page: Dictionary = _controller.get_family_expeditions(0, 128)
	if not bool(page.get("ok", false)):
		_add_note(_reason_text(String(page.get("code", "command_rejected"))),
			UITokens.RISK)
		return
	var handles: PackedInt64Array = page.get("expedition_handles", PackedInt64Array())
	var families: PackedInt64Array = page.get("family_handles", PackedInt64Array())
	var targets: PackedInt32Array = page.get("target_cells", PackedInt32Array())
	var populations: PackedInt64Array = page.get("populations", PackedInt64Array())
	var dues: PackedInt64Array = page.get("due_days", PackedInt64Array())
	var states: PackedInt32Array = page.get("states", PackedInt32Array())
	for index in range(handles.size()):
		var row := HBoxContainer.new()
		var select := Button.new()
		select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select.alignment = HORIZONTAL_ALIGNMENT_LEFT
		select.text = "家族 #%d · 目标 %d · %s 人 · %s · 第 %d 日" % [
			int(families[index]), int(targets[index]),
			UITokens.format_compact_number_cn(float(populations[index]), 0),
			_state_text(int(states[index])), int(dues[index])]
		select.pressed.connect(expedition_selected.emit.bind(int(handles[index])))
		row.add_child(select)
		var cancel := Button.new()
		cancel.text = "取消"
		cancel.disabled = int(states[index]) == 3
		cancel.tooltip_text = "返程中的队伍不能重复取消" if cancel.disabled else "按当前进度返程"
		cancel.pressed.connect(cancel_requested.emit.bind(int(handles[index])))
		row.add_child(cancel)
		_list.add_child(row)
	if handles.is_empty():
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
		"colonization_target_invalid": "目标必须是当前可见、可通行的无主陆地。",
		"colonization_population_insufficient": "源分支人口不足，必须至少留下一人。",
		"colonization_duplicate_target": "本国已有一支开拓队前往该目标。",
		"colonization_requote_required": "地图、视野或领土已经变化，请重新确认报价。",
		"economy_busy_retry": "经济系统正在提交，请稍后重试。",
		"colonization_expedition_invalid": "开拓队已结束或句柄已过期。",
	}.get(code, "当前无法执行开拓。")
