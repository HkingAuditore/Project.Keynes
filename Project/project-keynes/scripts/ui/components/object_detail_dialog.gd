extends Control
class_name ObjectDetailDialog

signal closed()

const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const PANEL_MIN_SIZE := Vector2(620.0, 520.0)

var _header_icon: IconBadge
var _title_label: Label
var _subtitle_label: Label
var _content: VBoxContainer
var _status_label: Label
var _facade = null
var _country_handle := 0
var _editable := false
var _current_day := -1
var _policy_version := -1
var _sequence := 1
var _lanes: Dictionary = {}
var _pending: Dictionary = {}
var _last_command_result: Dictionary = {}
var _fact_columns: Array[int] = []


func _ready() -> void:
	if _content != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_dialog()


func show_details(payload: Dictionary) -> void:
	if _content == null:
		_ready()
	_pending.clear()
	_lanes.clear()
	_fact_columns.clear()
	_facade = payload.get("country_facade", null)
	_country_handle = 0
	_header_icon.set_semantic(StringName(payload.get("icon", "resource")),
		payload.get("accent", UITokens.ACCENT))
	_title_label.text = String(payload.get("name", "对象详情"))
	_subtitle_label.text = String(payload.get("subtitle", ""))
	_clear_content()
	var kind := String(payload.get("kind", ""))
	var row: Dictionary = payload.get("row", {})
	match kind:
		"cohort":
			_build_cohort_details(row)
		"building":
			_build_building_details(row)
		"good":
			_build_good_details(row)
		"resource":
			_build_resource_details(row)
	var tax: Dictionary = payload.get("tax", {})
	if bool(tax.get("available", false)):
		_build_tax_section(tax)
	elif kind != "resource" and not String(tax.get("reason", "")).is_empty():
		_add_muted_note(String(tax.get("reason", "")))
	visible = true
	UIAnimation.crossfade(self, UITokens.ANIM_FAST)


func close_dialog() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


# country_committed 之后由装配层调用的原地刷新：只更新税率 lane 的数值与
# pending 状态，不重建详情区节点，快进时弹窗保持稳定。
func refresh_tax(tax: Dictionary) -> void:
	if not visible or not bool(tax.get("available", false)):
		return
	_current_day = int(tax.get("current_day", _current_day))
	_policy_version = int(tax.get("policy_version", _policy_version))
	_resolve_pending_lanes()
	for raw in tax.get("items", []):
		var item: Dictionary = raw
		var kind := String(item.get("kind", ""))
		if not _lanes.has(kind):
			continue
		var lane: Dictionary = _lanes[kind]
		lane["data"] = item.duplicate(true)
		if _pending.has(kind):
			continue
		_apply_lane_authoritative(kind, lane)


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close_dialog()
		get_viewport().set_input_as_handled()


func _build_dialog() -> void:
	var backdrop := Button.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.focus_mode = Control.FOCUS_NONE
	backdrop.mouse_default_cursor_shape = Control.CURSOR_ARROW
	var backdrop_style := StyleBoxFlat.new()
	backdrop_style.bg_color = Color(0.012, 0.010, 0.008, 0.76)
	for state in ["normal", "hover", "pressed", "focus"]:
		backdrop.add_theme_stylebox_override(state, backdrop_style)
	backdrop.pressed.connect(close_dialog)
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = PANEL_MIN_SIZE
	panel.add_theme_stylebox_override("panel", UITokens.panel_style(
		Color(0.038, 0.034, 0.029, 0.99), UITokens.RADIUS_MD,
		Color(UITokens.BRASS_HIGHLIGHT.r, UITokens.BRASS_HIGHLIGHT.g,
			UITokens.BRASS_HIGHLIGHT.b, 0.60)))
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_top", UITokens.SPACE_MD)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_LG)
	margin.add_theme_constant_override("margin_bottom", UITokens.SPACE_LG)
	panel.add_child(margin)

	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", UITokens.SPACE_MD)
	margin.add_child(body)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	body.add_child(title_row)
	_header_icon = IconBadge.new()
	_header_icon.custom_minimum_size = Vector2(32.0, 32.0)
	title_row.add_child(_header_icon)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	title_row.add_child(titles)
	_title_label = Label.new()
	_title_label.add_theme_font_override("font", UITokens.font_with_weight(700))
	_title_label.add_theme_font_size_override("font_size", UITokens.FONT_TITLE)
	_title_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	titles.add_child(_title_label)
	_subtitle_label = Label.new()
	_subtitle_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_subtitle_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	titles.add_child(_subtitle_label)
	var close_button := Button.new()
	close_button.custom_minimum_size = Vector2(34.0, 34.0)
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.tooltip_text = "关闭"
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_dialog)
	title_row.add_child(close_button)

	body.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", UITokens.SPACE_SM)
	scroll.add_child(_content)

	body.add_child(HSeparator.new())
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	_status_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_status_label.visible = false
	body.add_child(_status_label)


func _clear_content() -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	_set_status("")


# ─── 详情区 ──────────────────────────────────────────────────────────────

func _build_cohort_details(row: Dictionary) -> void:
	var status := String(row.get("status", ""))
	if not status.is_empty():
		_add_muted_note(status)
	_add_fact_grid([
		{"label": "人口", "value": String(row.get("population", "—")), "accent": UITokens.ACCENT},
		{"label": "身份", "value": String(row.get("cohort_identity", "本地人口")), "accent": UITokens.TEXT_MAIN},
		{"label": "人均财富", "value": String(row.get("wealth", "—")).trim_prefix("人均 "), "accent": UITokens.RESOURCE},
		{"label": "满意度", "value": String(row.get("satisfaction", "—")), "accent": row.get("living_accent", UITokens.ACCENT)},
		{"label": "生活水平", "value": String(row.get("living_standard", "—")), "accent": row.get("living_accent", UITokens.ACCENT)},
		{"label": "收入/人", "value": String(row.get("income", "—")), "accent": UITokens.GOOD},
		{"label": "支出/人", "value": String(row.get("expense", "—")), "accent": UITokens.RISK},
		{"label": "净额/人", "value": String(row.get("net", "—")),
			"accent": UITokens.GOOD if bool(row.get("net_positive", true)) else UITokens.RISK},
	])
	_add_rows_card("收入构成", "trend_up", UITokens.GOOD, row.get("income_rows", []))
	_add_rows_card("支出构成", "trend_down", UITokens.RISK, row.get("expense_rows", []))
	var demand: Dictionary = row.get("demand_summary", {})
	if not demand.is_empty():
		_add_muted_note("消费需求 · %s · %s" % [
			String(demand.get("value", "—")), String(demand.get("subtitle", ""))])


func _build_building_details(row: Dictionary) -> void:
	_add_fact_grid([
		{"label": "栋数", "value": String(row.get("count", "—")), "accent": UITokens.ACCENT},
		{"label": "状态", "value": String(row.get("status", "—")), "accent": row.get("accent", UITokens.ACCENT)},
		{"label": String(row.get("profit_label", "利润")), "value": String(row.get("profit", "—")),
			"accent": row.get("accent", UITokens.ACCENT)},
	])
	var owner := String(row.get("owner", ""))
	if not owner.is_empty():
		_add_muted_note(owner)
	var state: Dictionary = row.get("state_summary", {})
	if not state.is_empty():
		_add_state_card(state)
	_add_rows_card("岗位配置", "growth", UITokens.ACCENT, row.get("job_rows", []))
	_add_rows_card("生产概览", "resource", UITokens.RESOURCE, row.get("production_rows", []))
	var finance: Dictionary = row.get("finance", {})
	if not finance.is_empty():
		_add_finance_card(finance)


func _build_good_details(row: Dictionary) -> void:
	var risk := String(row.get("risk", ""))
	_add_fact_grid([
		{"label": "本地库存", "value": String(row.get("stock", "—")), "accent": UITokens.RESOURCE},
		{"label": "本地价格", "value": String(row.get("price", "—")), "accent": UITokens.RESOURCE},
		{"label": "库存日变化", "value": String(row.get("delta", "—")),
			"accent": _delta_accent(String(row.get("delta", "")))},
		{"label": "短缺风险", "value": risk if not risk.is_empty() else "无",
			"accent": UITokens.RISK if not risk.is_empty() else UITokens.TEXT_MUTED},
	])
	_add_rows_card("供需明细", "resource", UITokens.RESOURCE, row.get("detail_rows", []))


func _build_resource_details(row: Dictionary) -> void:
	_add_fact_grid([
		{"label": "储量指数", "value": String(row.get("value", "—")), "accent": UITokens.RESOURCE},
		{"label": "密度", "value": String(row.get("density", "—")), "accent": UITokens.RESOURCE},
		{"label": "日变化", "value": String(row.get("delta", "—")),
			"accent": _delta_accent(String(row.get("delta", "")))},
		{"label": "开采条件", "value": "本地建筑可开采" if bool(row.get("extractable", false)) \
			else "本地无可开采建筑", "accent": UITokens.GOOD if bool(row.get("extractable", false)) \
			else UITokens.TEXT_MUTED},
	])


func _delta_accent(delta: String) -> Color:
	if delta.begins_with("+"):
		return UITokens.GOOD
	if delta.begins_with("-") or delta.begins_with("−"):
		return UITokens.RISK
	return UITokens.TEXT_MUTED


func _add_fact_grid(facts: Array) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.045, 0.039, 0.032, 0.98), UITokens.PANEL_BORDER_SOFT))
	_content.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)
	var grid := GridContainer.new()
	grid.columns = _balanced_fact_columns(facts.size())
	_fact_columns.append(grid.columns)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", UITokens.SPACE_SM)
	grid.add_theme_constant_override("v_separation", UITokens.SPACE_XS)
	margin.add_child(grid)
	for raw in facts:
		var fact: Dictionary = raw
		var cell := VBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_theme_constant_override("separation", 0)
		grid.add_child(cell)
		var label := Label.new()
		label.text = String(fact.get("label", ""))
		label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		cell.add_child(label)
		var value := Label.new()
		value.text = String(fact.get("value", "—"))
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		value.add_theme_color_override("font_color",
			fact.get("accent", UITokens.TEXT_MAIN))
		cell.add_child(value)


# 事实网格按数量选列，保证最后一行不留孤格：4 项用 2×2，8 项用 4×2，
# 其余尽量 3 列；7 项拆成 4+3 也比 3+3+1 更整齐。
static func _balanced_fact_columns(fact_count: int) -> int:
	if fact_count <= 1:
		return 1
	if fact_count == 2 or fact_count == 4:
		return 2
	if fact_count % 4 == 0:
		return 4
	if fact_count % 3 == 0 or fact_count % 3 == 2:
		return 3
	return 4


func _add_rows_card(title_text: String, icon_key: String, accent: Color, rows: Array) -> void:
	if rows.is_empty():
		return
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.040, 0.035, 0.029, 0.98), Color(accent.r, accent.g, accent.b, 0.34)))
	_content.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	box.add_child(title_row)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(18.0, 18.0)
	icon.set_semantic(StringName(icon_key), accent)
	title_row.add_child(icon)
	var title := Label.new()
	title.text = title_text
	title.add_theme_font_override("font", UITokens.font_with_weight(650))
	title.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	title.add_theme_color_override("font_color", accent)
	title_row.add_child(title)
	for raw in rows:
		var data: Dictionary = raw
		if not bool(data.get("visible", true)):
			continue
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", UITokens.SPACE_SM)
		box.add_child(line)
		var name_label := Label.new()
		name_label.text = String(data.get("name", ""))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		name_label.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		line.add_child(name_label)
		var value_label := Label.new()
		value_label.text = String(data.get("value", ""))
		value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		value_label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		value_label.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
		line.add_child(value_label)


func _add_state_card(state: Dictionary) -> void:
	var accent: Color = state.get("accent", UITokens.WARN)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.045, 0.039, 0.032, 0.98), Color(accent.r, accent.g, accent.b, 0.46)))
	_content.add_child(panel)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)
	var label := Label.new()
	label.text = String(state.get("label", "经营状态"))
	label.add_theme_font_override("font", UITokens.font_with_weight(650))
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", accent)
	box.add_child(label)
	var detail := Label.new()
	detail.text = String(state.get("detail", ""))
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	detail.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	box.add_child(detail)
	var meta_text := String(state.get("meta", ""))
	if not meta_text.is_empty():
		var meta := Label.new()
		meta.text = meta_text
		meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		meta.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		meta.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		box.add_child(meta)


func _add_finance_card(finance: Dictionary) -> void:
	_add_fact_grid([
		{"label": "本期收入", "value": String(finance.get("revenue", "—")), "accent": UITokens.GOOD},
		{"label": "本期总成本", "value": String(finance.get("cost", "—")), "accent": UITokens.RISK},
		{"label": "本期盈亏", "value": String(finance.get("profit", "—")),
			"accent": UITokens.GOOD if bool(finance.get("profit_positive", true)) else UITokens.RISK},
	])
	var breakdown := String(finance.get("breakdown", ""))
	if not breakdown.is_empty():
		_add_muted_note(breakdown)
	var warning := String(finance.get("warning", ""))
	if not warning.is_empty():
		_add_muted_note(warning, UITokens.RISK)


func _add_muted_note(text: String, color: Color = UITokens.TEXT_MUTED) -> void:
	var note := Label.new()
	note.text = text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	note.add_theme_color_override("font_color", color)
	_content.add_child(note)


# ─── 税收区 ──────────────────────────────────────────────────────────────

func _build_tax_section(tax: Dictionary) -> void:
	_current_day = int(tax.get("current_day", -1))
	_policy_version = int(tax.get("policy_version", -1))
	_country_handle = int(tax.get("country_handle", 0))
	_editable = bool(tax.get("editable", false))
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", UITokens.SPACE_SM)
	_content.add_child(section)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UITokens.SPACE_SM)
	section.add_child(head)
	var icon := IconBadge.new()
	icon.custom_minimum_size = Vector2(20.0, 20.0)
	icon.set_semantic(&"tax.section", UITokens.BRASS_HIGHLIGHT)
	head.add_child(icon)
	var title := Label.new()
	title.text = "税收政策 · %s" % String(tax.get("country_name", ""))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_override("font", UITokens.font_with_weight(650))
	title.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	title.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	head.add_child(title)
	if not _editable:
		var readonly := Label.new()
		readonly.text = "只读"
		readonly.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		readonly.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		readonly.add_theme_color_override("font_color", UITokens.TEXT_FAINT)
		head.add_child(readonly)
		var hint := Label.new()
		hint.text = "仅可调整本国税率；上方为该国当前政策。"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
		section.add_child(hint)
	for raw in tax.get("items", []):
		section.add_child(_make_tax_lane(raw))


func _make_tax_lane(item: Dictionary) -> Control:
	var kind := String(item.get("kind", ""))
	var accent: Color = item.get("accent", UITokens.ACCENT)
	var has_override := bool(item.get("has_override", false))
	var base := int(item.get("base", 0))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UITokens.inset_panel_style(
		Color(0.045, 0.039, 0.032, 0.98), Color(accent.r, accent.g, accent.b, 0.34)))
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_right", UITokens.SPACE_SM)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITokens.SPACE_XS)
	box.add_child(row)
	var label := Label.new()
	label.text = String(item.get("kind_label", kind))
	label.custom_minimum_size.x = 64.0
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	label.add_theme_color_override("font_color", accent)
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = -100
	spin.max_value = 100
	spin.step = 1
	spin.suffix = "%"
	spin.editable = _editable
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.custom_minimum_size = Vector2(88.0, 30.0)
	spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	spin.set_value_no_signal(base)
	spin.get_line_edit().add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT if has_override else UITokens.TEXT_MUTED)
	spin.get_line_edit().text_submitted.connect(_on_lane_text_submitted.bind(kind))
	spin.get_line_edit().focus_exited.connect(_on_lane_focus_exited.bind(kind))
	row.add_child(spin)
	var reset := Button.new()
	reset.focus_mode = Control.FOCUS_NONE
	reset.visible = _editable and has_override
	reset.custom_minimum_size = Vector2(24.0, 26.0)
	IconButton.apply(reset, &"action.reset", IconButton.SMALL, "重置为默认税率")
	reset.pressed.connect(_on_lane_reset_pressed.bind(kind))
	row.add_child(reset)
	var clock := IconBadge.new()
	clock.custom_minimum_size = Vector2(18.0, 20.0)
	clock.visible = false
	clock.tooltip_text = "命令已确认，将于下一日生效"
	clock.set_semantic(&"system.clock", UITokens.BRASS_HIGHLIGHT)
	row.add_child(clock)
	var note := Label.new()
	note.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	note.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	box.add_child(note)
	_lanes[kind] = {"panel": panel, "spin": spin, "reset": reset, "clock": clock,
		"note": note, "data": item.duplicate(true)}
	_refresh_lane_note(kind)
	return panel


func _refresh_lane_note(kind: String) -> void:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return
	var data: Dictionary = lane.get("data", {})
	var parts: Array[String] = ["默认 %d%%" % int(data.get("default_rate", 0))]
	var base := int(data.get("base", 0))
	var effective := int(data.get("effective", base))
	if effective != base:
		parts.append("修正后 %d%%" % effective)
	var placeholder := String(data.get("placeholder_note", ""))
	if not placeholder.is_empty():
		parts.append(placeholder)
	(lane.get("note") as Label).text = " · ".join(parts)


# 与 EconomyWorkspace 的语义一致：输入即覆盖；值回到默认即清除覆盖；
# 命令次日生效并进入 pending，直到 country_daily 原子提交后由 refresh_tax 解除。
func _on_lane_text_submitted(_text: String, kind: String) -> void:
	_confirm_lane(kind)


func _on_lane_focus_exited(kind: String) -> void:
	_confirm_lane(kind)


func _confirm_lane(kind: String) -> void:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return
	var spin := lane.get("spin") as SpinBox
	var data: Dictionary = lane.get("data", {})
	var rate := int(spin.value)
	var base := int(data.get("base", 0))
	var overridden := bool(data.get("has_override", false))
	var default_rate := int(data.get("default_rate", 0))
	if not overridden and rate == default_rate:
		return
	if rate == base and not overridden:
		return
	if rate == default_rate and overridden:
		_clear_lane_override(kind, StringName(data.get("item_id", "")))
	elif rate != base:
		_submit_lane_override(kind, StringName(data.get("item_id", "")), rate)


func _on_lane_reset_pressed(kind: String) -> void:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return
	var data: Dictionary = lane.get("data", {})
	_clear_lane_override(kind, StringName(data.get("item_id", "")))


func _submit_lane_override(kind: String, item_id: StringName, rate: int) -> void:
	if not _editable or _facade == null:
		return
	var result: Dictionary = _facade.set_tax_override(_country_handle,
		int(TAX_KIND_IDS[kind]), item_id, rate, _effective_day(), _next_sequence())
	_last_command_result = result
	var lane: Dictionary = _lanes.get(kind, {})
	if bool(result.get("ok", false)):
		_mark_pending(kind)
		if not lane.is_empty():
			var spin := lane.get("spin") as SpinBox
			spin.set_value_no_signal(rate)
			spin.get_line_edit().add_theme_color_override("font_color",
				UITokens.BRASS_HIGHLIGHT)
			(lane.get("data") as Dictionary)["base"] = rate
			(lane.get("data") as Dictionary)["has_override"] = true
			(lane.get("reset") as Button).visible = true
		_set_status("税率命令已确认，将于第 %d 日生效" % (_effective_day() + 1))
	else:
		if not lane.is_empty():
			(lane.get("spin") as SpinBox).set_value_no_signal(
				int((lane.get("data") as Dictionary).get("base", 0)))
		_set_status(String(result.get("reason", "税率命令提交失败")), true)


func _clear_lane_override(kind: String, item_id: StringName) -> void:
	if not _editable or _facade == null:
		return
	var result: Dictionary = _facade.clear_tax_override(_country_handle,
		int(TAX_KIND_IDS[kind]), item_id, _effective_day(), _next_sequence())
	_last_command_result = result
	var lane: Dictionary = _lanes.get(kind, {})
	if bool(result.get("ok", false)):
		_mark_pending(kind)
		if not lane.is_empty():
			var data := lane.get("data") as Dictionary
			var default_rate := int(data.get("default_rate", 0))
			var spin := lane.get("spin") as SpinBox
			spin.set_value_no_signal(default_rate)
			spin.get_line_edit().add_theme_color_override("font_color", UITokens.TEXT_MUTED)
			data["base"] = default_rate
			data["has_override"] = false
			(lane.get("reset") as Button).visible = false
		_set_status("已恢复默认税率，将于第 %d 日生效" % (_effective_day() + 1))
	else:
		_set_status(String(result.get("reason", "税率覆盖清除命令提交失败")), true)


func _mark_pending(kind: String) -> void:
	_pending[kind] = {
		"effective_day": _effective_day(),
		"policy_version": _policy_version,
	}
	var lane: Dictionary = _lanes.get(kind, {})
	if not lane.is_empty():
		(lane.get("clock") as Control).visible = true


func _resolve_pending_lanes() -> void:
	var resolved: Array[String] = []
	for key_value in _pending:
		var kind := String(key_value)
		var pending: Dictionary = _pending[kind]
		if _current_day >= int(pending.get("effective_day", _current_day + 1)) \
				and _policy_version > int(pending.get("policy_version", _policy_version)):
			resolved.append(kind)
	for kind in resolved:
		_pending.erase(kind)


func _apply_lane_authoritative(kind: String, lane: Dictionary) -> void:
	var data: Dictionary = lane.get("data", {})
	var base := int(data.get("base", 0))
	var overridden := bool(data.get("has_override", false))
	var spin := lane.get("spin") as SpinBox
	if not spin.get_line_edit().has_focus():
		spin.set_value_no_signal(base)
		spin.get_line_edit().add_theme_color_override("font_color",
			UITokens.BRASS_HIGHLIGHT if overridden else UITokens.TEXT_MUTED)
	(lane.get("reset") as Button).visible = _editable and overridden
	(lane.get("clock") as Control).visible = false
	_refresh_lane_note(kind)


func _effective_day() -> int:
	return _current_day + 1


func _next_sequence() -> int:
	var result := _sequence
	_sequence += 1
	return result


func _set_status(text: String, warn: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.visible = text != ""
	_status_label.add_theme_color_override("font_color",
		UITokens.WARN if warn else UITokens.TEXT_MUTED)


# ─── 测试钩子 ────────────────────────────────────────────────────────────

func title_text() -> String:
	return _title_label.text if _title_label != null else ""


func subtitle_text() -> String:
	return _subtitle_label.text if _subtitle_label != null else ""


func tax_lane_count() -> int:
	return _lanes.size()


func tax_lane_editable() -> bool:
	return _editable


func tax_lane_rate(kind: String) -> int:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return 0
	return int((lane.get("spin") as SpinBox).value)


func tax_lane_instance_id(kind: String) -> int:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return 0
	return (lane.get("panel") as Control).get_instance_id()


func set_lane_rate_for_test(kind: String, rate: int) -> void:
	var lane: Dictionary = _lanes.get(kind, {})
	if not lane.is_empty():
		(lane.get("spin") as SpinBox).value = rate


func confirm_lane_for_test(kind: String) -> void:
	_confirm_lane(kind)


func reset_lane_for_test(kind: String) -> void:
	_on_lane_reset_pressed(kind)


func pending_lane_count() -> int:
	return _pending.size()


func last_command_ok() -> bool:
	return bool(_last_command_result.get("ok", false))


func last_command_pending() -> int:
	return int(_last_command_result.get("pending", -1))


func status_text() -> String:
	return _status_label.text if _status_label != null else ""


func fact_grid_columns() -> Array[int]:
	return _fact_columns.duplicate()
