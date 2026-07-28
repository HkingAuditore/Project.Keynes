extends PanelContainer
class_name TechnologyDetailCard

signal enqueue_requested(index: int)
signal remove_requested(index: int)

const STATE_NAMES := ["未知", "已揭示 · 前置未完成", "可研究", "研究队列中", "待生效", "已掌握"]

var _index := -1
var _state := 0
var _submitted := false
var _accent: Color = UITokens.ACCENT
var _header_icon: IconBadge
var _name: Label
var _state_label: Label
var _chips: BadgeRow
var _gauge: RadialGauge
var _effects: InsightList
var _body: VBoxContainer
var _detail_block: VBoxContainer
var _prerequisite_title: Label
var _prerequisites: VBoxContainer
var _successor_title: Label
var _successors: VBoxContainer
var _action: Button
var _placeholder: Label


func _ready() -> void:
	if _body != null:
		return
	add_theme_stylebox_override("panel", UITokens.panel_style(
		Color(0.044, 0.037, 0.030, 0.98), UITokens.RADIUS_SM, UITokens.PANEL_BORDER))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", UITokens.SPACE_SM)
	scroll.add_child(_body)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_header_icon = IconBadge.new()
	_header_icon.custom_minimum_size = Vector2(30.0, 30.0)
	_header_icon.set_semantic(&"country.technology", UITokens.CLIMATE)
	header.add_child(_header_icon)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 1)
	_name = Label.new()
	_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_name.add_theme_font_override("font", UITokens.font_with_weight(700))
	_name.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
	titles.add_child(_name)
	_state_label = Label.new()
	_state_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_state_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	titles.add_child(_state_label)
	header.add_child(titles)
	_body.add_child(header)
	_placeholder = Label.new()
	_placeholder.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_placeholder.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_placeholder.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_body.add_child(_placeholder)
	_detail_block = VBoxContainer.new()
	_detail_block.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_body.add_child(_detail_block)
	_chips = BadgeRow.new()
	_detail_block.add_child(_chips)
	_gauge = RadialGauge.new()
	_gauge.custom_minimum_size = Vector2(118.0, 122.0)
	_gauge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_detail_block.add_child(_gauge)
	_effects = InsightList.new()
	_effects.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_block.add_child(_effects)
	_prerequisite_title = _make_section_title("前置条件")
	_detail_block.add_child(_prerequisite_title)
	_prerequisites = VBoxContainer.new()
	_prerequisites.add_theme_constant_override("separation", 2)
	_detail_block.add_child(_prerequisites)
	_successor_title = _make_section_title("将解锁")
	_detail_block.add_child(_successor_title)
	_successors = VBoxContainer.new()
	_successors.add_theme_constant_override("separation", 2)
	_detail_block.add_child(_successors)
	_action = Button.new()
	_action.focus_mode = Control.FOCUS_NONE
	_action.custom_minimum_size.y = 30.0
	_action.pressed.connect(_on_action_pressed)
	_detail_block.add_child(_action)
	show_empty()


func show_empty() -> void:
	if _body == null:
		_ready()
	_index = -1
	_state = 0
	_submitted = false
	_header_icon.set_semantic(&"country.technology", UITokens.TEXT_MUTED)
	_name.text = "研究档案"
	_state_label.text = ""
	_placeholder.visible = true
	_placeholder.text = "在科技树中选择一个节点查看它的成本、效果与前后置链条。"
	_detail_block.visible = false


func show_unknown() -> void:
	if _body == null:
		_ready()
	_index = -1
	_state = 0
	_submitted = false
	_header_icon.set_semantic(&"technology.state.unknown", UITokens.TEXT_MUTED)
	_name.text = "未知科技"
	_state_label.text = STATE_NAMES[0]
	_placeholder.visible = true
	_placeholder.text = "完成任意一项直接前置后，这个节点的名称、成本与效果才会揭示。"
	_detail_block.visible = false


func show_technology(index: int, definition: Dictionary, state: int, fraction: float,
		accent: Color, era_name: String, domain_name: String,
		relations: Dictionary) -> void:
	if _body == null:
		_ready()
	_index = index
	_state = state
	_accent = accent
	_placeholder.visible = false
	_detail_block.visible = true
	_submitted = false
	_header_icon.set_semantic(IconCatalog.technology_domain_semantic(
		String(definition.get("domain_id", ""))), accent)
	_header_icon.tooltip_text = "%s · %s" % [domain_name, era_name]
	_name.text = String(definition.get("display_name", ""))
	_state_label.text = STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]
	_state_label.add_theme_color_override("font_color", _state_colour(state))
	var chips: Array = [
		{"text": era_name, "accent": UITokens.BRASS_HIGHLIGHT},
		{"text": "成本 %s" % UITokens.format_compact_number_cn(
			float(definition.get("cost_points", 0)), 1), "accent": UITokens.CLIMATE},
	]
	if bool(definition.get("is_milestone", false)):
		chips.append({"text": "时代里程碑", "accent": UITokens.WARN})
	elif bool(definition.get("is_era_key", false)):
		chips.append({"text": "时代关键", "accent": UITokens.RESOURCE})
	_chips.set_badges(chips)
	_gauge.set_data("研究进度", clampf(fraction, 0.0, 1.0),
		_progress_caption(definition, fraction, state), accent)
	_effects.set_items(_effect_items(String(definition.get("effect_summary", ""))))
	var required := int(definition.get("milestone_required_count", 0))
	var prerequisites: Array = relations.get("prerequisites", [])
	if required > 0:
		_prerequisite_title.text = "前置条件（任选 %d 项）" % required
	else:
		_prerequisite_title.text = "前置条件"
	_prerequisite_title.visible = not prerequisites.is_empty()
	_fill_relation_rows(_prerequisites, prerequisites)
	var successors: Array = relations.get("successors", [])
	_successor_title.visible = not successors.is_empty()
	_fill_relation_rows(_successors, successors)
	_apply_action(state)


# Daily ticks take this path: gauge value, state text and the action button only.
func update_progress(state: int, fraction: float, definition: Dictionary) -> void:
	if _index < 0 or _detail_block == null or not _detail_block.visible:
		return
	_state = state
	_state_label.text = STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]
	_state_label.add_theme_color_override("font_color", _state_colour(state))
	_gauge.set_data("研究进度", clampf(fraction, 0.0, 1.0),
		_progress_caption(definition, fraction, state), _accent)
	if not _submitted:
		_apply_action(state)


func _progress_caption(definition: Dictionary, fraction: float, state: int) -> String:
	if state >= 5:
		return "已掌握"
	if state <= 1:
		return "尚未开始"
	var cost := float(definition.get("cost_points", 0))
	var remaining := maxf(0.0, cost * (1.0 - clampf(fraction, 0.0, 1.0)))
	return "还需 %s" % UITokens.format_compact_number_cn(remaining, 1)


func _effect_items(summary: String) -> Array:
	var items: Array = []
	for chunk in summary.replace("，", "、").split("、", false):
		var text := String(chunk).strip_edges()
		if text.is_empty():
			continue
		var unlocks := text.begins_with("解锁") or text.begins_with("开启") \
			or text.begins_with("完成")
		items.append({
			"text": text,
			"icon": &"economy.building" if unlocks else &"metric.technology",
			"accent": UITokens.RESOURCE if unlocks else UITokens.CLIMATE,
		})
	return items


func _fill_relation_rows(host: VBoxContainer, entries: Array) -> void:
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	for entry in entries:
		var data: Dictionary = entry
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", UITokens.SPACE_XS)
		var marker := Label.new()
		marker.custom_minimum_size.x = 15.0
		var state := int(data.get("state", 0))
		IconButton.apply_to_label(marker, IconCatalog.technology_state_semantic(state), 11)
		marker.add_theme_color_override("font_color", _state_colour(state))
		row.add_child(marker)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		label.text = String(data.get("name", "未知科技"))
		label.add_theme_color_override("font_color",
			UITokens.TEXT_MAIN if state >= 1 else UITokens.TEXT_FAINT)
		row.add_child(label)
		host.add_child(row)


func _apply_action(state: int) -> void:
	match state:
		2:
			_action.visible = true
			_action.disabled = false
			_action.text = "加入研究队列"
		3:
			_action.visible = true
			_action.disabled = false
			_action.text = "移出研究队列"
		1:
			_action.visible = true
			_action.disabled = true
			_action.text = "前置尚未完成"
		_:
			_action.visible = state < 4
			_action.disabled = true
			_action.text = "无可用操作"


# Research commands land on the next country day, so the button states the delay
# instead of pretending the queue already changed.
func mark_submitted() -> void:
	if _action == null:
		return
	_submitted = true
	_action.disabled = true
	_action.text = "已提交 · 次日生效"


func _on_action_pressed() -> void:
	if _index < 0:
		return
	if _state == 3:
		remove_requested.emit(_index)
		return
	if _state == 2:
		enqueue_requested.emit(_index)


func _make_section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", UITokens.font_with_weight(680))
	label.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	return label


func _state_colour(state: int) -> Color:
	match state:
		2:
			return UITokens.BRASS_HIGHLIGHT
		3:
			return UITokens.WATER.lerp(UITokens.TEXT_MAIN, 0.30)
		4:
			return UITokens.WARN
		5:
			return UITokens.GOOD
		_:
			return UITokens.TEXT_FAINT
