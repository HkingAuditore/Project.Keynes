extends Control
class_name ObjectDetailDialog

const FactGridScene := preload("res://scenes/ui/object_fact_grid.tscn")
const FactCellScene := preload("res://scenes/ui/object_fact_cell.tscn")
const RowsCardScene := preload("res://scenes/ui/object_rows_card.tscn")
const DetailLineScene := preload("res://scenes/ui/object_detail_line.tscn")
const StateCardScene := preload("res://scenes/ui/object_state_card.tscn")
const NoteScene := preload("res://scenes/ui/object_note.tscn")
const ActionButtonScene := preload("res://scenes/ui/object_action_button.tscn")
const TaxSectionScene := preload("res://scenes/ui/object_tax_section.tscn")
const TaxLaneScene := preload("res://scenes/ui/object_tax_lane.tscn")

signal closed()
signal colonization_requested(family_handle: int, source_cell: int)
signal tax_override_requested(scope: String, kind: String, item_id: String, rate: int)
signal tax_reset_requested(scope: String, kind: String, item_id: String)
signal tax_editing_finished()

const PANEL_MIN_SIZE := Vector2(620.0, 520.0)

var _header_icon: IconBadge
var _title_label: Label
var _subtitle_label: Label
var _section_nav: HBoxContainer
var _section_buttons: Dictionary = {}
var _section_targets: Dictionary = {}
var _scroll: ScrollContainer
var _content: VBoxContainer
var _tax_section: VBoxContainer
var _tax_editors: Dictionary = {}
var _player_controller = null
var _fact_columns: Array[int] = []
var _embedded := false
var _fact_grids: Array[GridContainer] = []


func _ready() -> void:
	if _content != null:
		return
	_header_icon = get_node_or_null("Center/Dialog/Body/TitleRow/HeaderIcon") as IconBadge
	_title_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/Title") as Label
	_subtitle_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/Subtitle") as Label
	_section_nav = get_node_or_null("Center/Dialog/Body/SectionNav") as HBoxContainer
	_scroll = get_node_or_null("Center/Dialog/Body/Scroll") as ScrollContainer
	_content = get_node_or_null("Center/Dialog/Body/Scroll/Content") as VBoxContainer
	var close_button := get_node_or_null("Center/Dialog/Body/TitleRow/CloseButton") as Button
	var backdrop_close := get_node_or_null("BackdropClose") as Button
	if _header_icon == null or _title_label == null or _subtitle_label == null \
			or _section_nav == null or _scroll == null or _content == null \
			or close_button == null \
			or backdrop_close == null:
		push_error("ObjectDetailDialog 必须通过 object_detail_dialog.tscn 实例化。")
		return
	_section_buttons = {
		"overview": _section_nav.get_node("Overview"),
		"operations": _section_nav.get_node("Operations"),
		"effects": _section_nav.get_node("Effects"),
	}
	for section_id in _section_buttons:
		(_section_buttons[section_id] as Button).pressed.connect(
			_scroll_to_section.bind(String(section_id)))
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_dialog)
	backdrop_close.pressed.connect(close_dialog)


func show_details(payload: Dictionary) -> void:
	if _content == null:
		_ready()
	visible = true
	if _embedded:
		_apply_embedded_chrome(true)
	_section_targets.clear()
	_fact_columns.clear()
	_fact_grids.clear()
	_header_icon.set_semantic(StringName(payload.get("icon", "resource")),
		payload.get("accent", UITokens.ACCENT))
	_title_label.text = String(payload.get("name", "对象详情"))
	_subtitle_label.text = String(payload.get("subtitle", ""))
	_clear_content()
	_tax_section = null
	_tax_editors.clear()
	var kind := String(payload.get("kind", ""))
	var row: Dictionary = payload.get("row", {})
	_build_tax_section(kind, payload.get("tax_context", {}), row)
	match kind:
		"cohort":
			_build_cohort_details(row)
		"building":
			_build_building_details(row)
		"good":
			_build_good_details(row)
		"resource":
			_build_resource_details(row)
		"family":
			_build_family_details(row)
	_configure_section_nav(kind)
	call_deferred("_fit_embedded_layout")


func refresh_details(payload: Dictionary) -> bool:
	if not visible or payload.is_empty():
		return false
	if has_active_tax_edit():
		return false
	var saved_scroll := _scroll.scroll_vertical if _scroll != null else 0
	show_details(payload)
	call_deferred("_restore_scroll", saved_scroll)
	return true


func set_player_controller(controller) -> void:
	_player_controller = controller


func tax_editors() -> Array:
	return _tax_editors.values()


func has_active_tax_edit() -> bool:
	for editor_value in _tax_editors.values():
		var editor := editor_value as TaxLaneEditor
		if editor != null and editor.is_editing():
			return true
	return false


func _build_tax_section(kind: String, context_value: Variant, row: Dictionary) -> void:
	var context: Dictionary = context_value if context_value is Dictionary else {}
	# 对象详情只编辑本对象覆盖。地块税种默认留在检视器页上，打开详情时会收起，
	# 避免工匠/建筑/物资同时出现两层同名税率。
	var item_lanes := _item_tax_lanes(row)
	if item_lanes.is_empty():
		return
	_tax_section = TaxSectionScene.instantiate() as VBoxContainer
	_content.add_child(_tax_section)
	(_tax_section.get_node("Head/Icon") as IconBadge).set_semantic(
		&"tax.section", UITokens.BRASS_HIGHLIGHT)
	var title := _tax_title(kind)
	(_tax_section.get_node("Head/Title") as Label).text = title
	var lanes := _tax_section.get_node("Lanes") as VBoxContainer
	var editable := bool(context.get("editable", false))
	(_tax_section.get_node("Head/Readonly") as Control).visible = not editable
	var hint := _tax_section.get_node("Hint") as Label
	if not bool(context.get("available", true)):
		hint.text = String(context.get("reason", "该领土没有可调整的税收政策。"))
		hint.visible = true
	else:
		hint.text = _tax_hint(kind)
		hint.visible = true
	for raw in item_lanes:
		var lane: Dictionary = raw
		var editor := TaxLaneScene.instantiate() as TaxLaneEditor
		lanes.add_child(editor)
		editor.override_requested.connect(func(scope: String, lane_kind: String,
				item_id: String, rate: int) -> void:
			tax_override_requested.emit(scope, lane_kind, item_id, rate))
		editor.reset_requested.connect(func(scope: String, lane_kind: String,
				item_id: String) -> void:
			tax_reset_requested.emit(scope, lane_kind, item_id))
		editor.editing_finished.connect(func() -> void:
			tax_editing_finished.emit())
		editor.set_data(lane)
		_tax_editors[editor.editor_key(int(context.get("cell", -1)))] = editor
	lanes.visible = not item_lanes.is_empty()


func _item_tax_lanes(row: Dictionary) -> Array:
	var item_lanes: Array = []
	for lane_value in row.get("tax_lanes", []):
		var lane: Dictionary = lane_value
		if String(lane.get("scope", "item")) == "default":
			continue
		item_lanes.append(lane)
	return item_lanes


func _tax_title(kind: String) -> String:
	return {
		"cohort": "本阶层所得税",
		"good": "本物资交易税",
		"building": "本建筑营业税",
	}.get(kind, "税收调整")


func _tax_hint(kind: String) -> String:
	return {
		"cohort": "在此调整本阶层税率，次日生效。",
		"good": "在此调整本物资税率，次日生效。",
		"building": "在此调整本建筑税率，次日生效。",
	}.get(kind, "在此调整本项税率，次日生效。")


func set_embedded(embedded: bool = true) -> void:
	_embedded = embedded
	_apply_embedded_chrome(embedded)
	update_minimum_size()


# 嵌入右侧分栏时不能再按模态弹窗的 620 最小宽上报。家族效果长句会把
# DetailShell 撑破 HBox，盖住地块档案列。嵌入列宽由 Inspector 分配，这里只填满。
func _get_minimum_size() -> Vector2:
	return Vector2.ZERO if _embedded else custom_minimum_size


func _apply_embedded_chrome(embedded: bool) -> void:
	clip_contents = true
	var backdrop := get_node_or_null("Backdrop") as Control
	var backdrop_close := get_node_or_null("BackdropClose") as Control
	var center := get_node_or_null("Center") as Control
	var dialog := get_node_or_null("Center/Dialog") as Control
	if backdrop != null:
		backdrop.visible = not embedded
	if backdrop_close != null:
		backdrop_close.visible = not embedded
	if center != null:
		center.clip_contents = true
	if dialog == null:
		return
	dialog.clip_contents = true
	dialog.custom_minimum_size = Vector2.ZERO if embedded else PANEL_MIN_SIZE
	if embedded:
		dialog.theme_type_variation = &""
		dialog.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		dialog.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		dialog.theme_type_variation = &"PKDialog"
		dialog.remove_theme_stylebox_override("panel")
		dialog.set_anchors_and_offsets_preset(Control.PRESET_CENTER,
			Control.PRESET_MODE_MINSIZE)
	dialog.update_minimum_size()


func close_dialog() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		close_dialog()
		get_viewport().set_input_as_handled()


func _clear_content() -> void:
	for child in _content.get_children():
		_content.remove_child(child)
		child.queue_free()


# ─── 详情区 ──────────────────────────────────────────────────────────────

func _build_cohort_details(row: Dictionary) -> void:
	var status := String(row.get("status", ""))
	if not status.is_empty():
		_add_muted_note(status)
	_section_targets["overview"] = _add_fact_grid([
		{"label": "人口", "value": String(row.get("population", "—")), "accent": UITokens.ACCENT},
		{"label": "身份", "value": String(row.get("cohort_identity", "本地人口")), "accent": UITokens.ARCHIVE_INK},
		{"label": "人均财富", "value": String(row.get("wealth", "—")).trim_prefix("人均 "), "accent": UITokens.RESOURCE},
		{"label": "满意度", "value": String(row.get("satisfaction", "—")), "accent": row.get("living_accent", UITokens.ACCENT)},
		{"label": "生活水平", "value": String(row.get("living_standard", "—")), "accent": row.get("living_accent", UITokens.ACCENT)},
		{"label": "最短板", "value": String(row.get("worst_dimension", "—")), "accent": UITokens.WARN},
		{"label": "收入/人", "value": String(row.get("income", "—")), "accent": UITokens.GOOD},
		{"label": "支出/人", "value": String(row.get("expense", "—")), "accent": UITokens.RISK},
		{"label": "净额/人", "value": String(row.get("net", "—")),
			"accent": UITokens.GOOD if bool(row.get("net_positive", true)) else UITokens.RISK},
	])
	var needs_target := _add_rows_card("满意度维度", "growth", UITokens.ACCENT,
		row.get("satisfaction_rows", []))
	_add_rows_card("收入构成", "trend_up", UITokens.GOOD, row.get("income_rows", []))
	_add_rows_card("支出构成", "trend_down", UITokens.RISK, row.get("expense_rows", []))
	var demand: Dictionary = row.get("demand_summary", {})
	if not demand.is_empty():
		needs_target = _add_muted_note("消费需求 · %s · %s" % [
			String(demand.get("value", "—")), String(demand.get("subtitle", ""))])
	var demand_target := _add_rows_card("消费需求", "resource", UITokens.RESOURCE,
		row.get("demand_rows", []))
	if needs_target == null:
		needs_target = demand_target
	if needs_target != null:
		_section_targets["operations"] = needs_target


func _build_building_details(row: Dictionary) -> void:
	_section_targets["overview"] = _add_fact_grid([
		{"label": "栋数", "value": String(row.get("count", "—")), "accent": UITokens.ACCENT},
		{"label": "状态", "value": String(row.get("status", "—")), "accent": row.get("accent", UITokens.ACCENT)},
		{"label": String(row.get("profit_label", "利润")), "value": String(row.get("profit", "—")),
			"accent": row.get("accent", UITokens.ACCENT)},
	])
	var owner := String(row.get("owner", ""))
	if not owner.is_empty():
		_add_muted_note(owner)
	var state: Dictionary = row.get("state_summary", {})
	var operations_target: Control = null
	if not state.is_empty():
		operations_target = _add_state_card(state)
	var jobs_target := _add_rows_card("岗位配置", "growth", UITokens.ACCENT,
		row.get("job_rows", []))
	var production_target := _add_rows_card("生产概览", "resource", UITokens.RESOURCE,
		row.get("production_rows", []))
	if operations_target == null:
		operations_target = jobs_target if jobs_target != null else production_target
	var finance: Dictionary = row.get("finance", {})
	if not finance.is_empty():
		var finance_target := _add_finance_card(finance)
		if operations_target == null:
			operations_target = finance_target
	if operations_target != null:
		_section_targets["operations"] = operations_target


func _build_good_details(row: Dictionary) -> void:
	var risk := String(row.get("risk", ""))
	var inbound := String(row.get("trade_inbound", ""))
	var outbound := String(row.get("trade_outbound", ""))
	var facts := [
		{"label": "本地库存", "value": String(row.get("stock_plain", row.get("stock", "—"))),
			"accent": UITokens.RESOURCE},
		{"label": "本地价格", "value": String(row.get("price", "—")), "accent": UITokens.RESOURCE},
		{"label": "库存日变化", "value": String(row.get("delta", "—")),
			"accent": _delta_accent(String(row.get("delta", "")))},
		{"label": "短缺风险", "value": risk if not risk.is_empty() else "无",
			"accent": UITokens.RISK if not risk.is_empty() else UITokens.ARCHIVE_INK_MUTED},
	]
	if not inbound.is_empty():
		facts.append({"label": "运入", "value": inbound, "accent": UITokens.ACCENT})
	if not outbound.is_empty():
		facts.append({"label": "运出", "value": outbound, "accent": UITokens.ACCENT})
	_section_targets["overview"] = _add_fact_grid(facts)
	var operations_target := _add_rows_card("供需明细", "resource", UITokens.RESOURCE,
		row.get("detail_rows", []))
	if operations_target != null:
		_section_targets["operations"] = operations_target


func _build_resource_details(row: Dictionary) -> void:
	_section_targets["overview"] = _add_fact_grid([
		{"label": "储量指数", "value": String(row.get("value", "—")), "accent": UITokens.RESOURCE},
		{"label": "密度", "value": String(row.get("density", "—")), "accent": UITokens.RESOURCE},
		{"label": "日变化", "value": String(row.get("delta", "—")),
			"accent": _delta_accent(String(row.get("delta", "")))},
		{"label": "开采条件", "value": "本地建筑可开采" if bool(row.get("extractable", false)) \
			else "本地无可开采建筑", "accent": UITokens.GOOD if bool(row.get("extractable", false)) \
			else UITokens.ARCHIVE_INK_MUTED},
	])


func _build_family_details(row: Dictionary) -> void:
	_section_targets["overview"] = _add_fact_grid([
		{"label": "家族人口", "value": String(row.get("population", "—")), "accent": UITokens.ACCENT},
		{"label": "重要人物", "value": "%d 位" % int(row.get("notable_people", 0)), "accent": UITokens.ACCENT},
		{"label": "家族产业", "value": "%s 栋" % String(row.get("owned_buildings", "0")), "accent": UITokens.CLIMATE},
		{"label": "现金财产", "value": String(row.get("cash_claim", "—")), "accent": UITokens.RESOURCE},
		{"label": "生产资产", "value": String(row.get("productive_asset_value", "—")), "accent": UITokens.RESOURCE},
		{"label": "净资产", "value": String(row.get("net_worth", "—")), "accent": UITokens.GOOD},
		{"label": "创立日", "value": "第 %d 日" % int(row.get("founded_day", 0)), "accent": UITokens.ARCHIVE_INK},
		{"label": "衰退复核", "value": "%d 次" % int(row.get("decline_reviews", 0)), "accent": UITokens.ARCHIVE_INK_MUTED},
		{"label": "本地威望", "value": "%s · %s" % [
			["0", "I", "II", "III", "IV", "V"][clampi(int(row.get("prestige_level", 0)), 0, 5)],
			String(row.get("prestige_score", "0.0%"))], "accent": UITokens.ACCENT},
	])
	var people_target := _add_rows_card("家族特性", "family.house", UITokens.ACCENT,
		row.get("trait_rows", []))
	_add_rows_card("行为偏好", "growth", UITokens.GOOD,
		row.get("behavior_rows", []))
	var branch_target := _add_rows_card("地块威望", "family.house", UITokens.ACCENT,
		row.get("branch_rows", []))
	var action_target := _add_branch_colonization_buttons(int(row.get("family_handle", 0)),
		row.get("branch_rows", []))
	if branch_target != null:
		people_target = branch_target
	elif action_target != null:
		people_target = action_target
	var family_effect_target := _add_rows_card("家族效果", "growth", UITokens.CLIMATE,
		row.get("effect_rows", []))
	var effects_target := _add_rows_card("已激活加成", "growth", UITokens.CLIMATE,
		row.get("modifier_rows", []))
	var trigger_target := _add_rows_card("累计触发", "resource", UITokens.RESOURCE,
		row.get("trigger_rows", []))
	if family_effect_target != null:
		effects_target = family_effect_target
	elif effects_target == null:
		effects_target = trigger_target
	var people: Array = row.get("notable_person_rows", [])
	if people.is_empty():
		var empty_people := _add_muted_note("该家族目前没有重要人物。")
		if people_target == null:
			people_target = empty_people
	else:
		var notable_target := _add_rows_card("主要人物", "family.house", UITokens.ACCENT, people)
		if people_target == null:
			people_target = notable_target
	if people_target != null:
		_section_targets["operations"] = people_target
	if family_effect_target != null:
		_section_targets["effects"] = family_effect_target
	elif effects_target != null:
		_section_targets["effects"] = effects_target
	elif trigger_target != null:
		_section_targets["effects"] = trigger_target


func _add_branch_colonization_buttons(family_handle: int, branches: Array) -> Control:
	if family_handle == 0 or branches.is_empty():
		return null
	var panel := RowsCardScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.clip_contents = false
	_content.add_child(panel)
	(panel.get_node("Box/TitleRow/Icon") as IconBadge).set_semantic(
		&"family.house", UITokens.BRASS_HIGHLIGHT)
	var title := panel.get_node("Box/TitleRow/Title") as Label
	title.text = "选择开拓源分支"
	title.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	var rows := panel.get_node("Box/Rows") as VBoxContainer
	for raw in branches:
		var branch: Dictionary = raw
		var source_cell := int(branch.get("cell", -1))
		if source_cell < 0:
			continue
		var button := ActionButtonScene.instantiate() as Button
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.text = "%s · 进入地图选点" % String(branch.get(
			"name", "地块 %d" % source_cell))
		var owned: bool = _player_controller != null and \
			_player_controller.has_method("is_player_owned_cell") and \
			bool(_player_controller.is_player_owned_cell(source_cell))
		button.disabled = not owned
		button.tooltip_text = "仅玩家领土内的家族分支可以派遣" if not owned \
			else "选择一个可见的无主或本国陆地作为目标"
		button.pressed.connect(func() -> void:
			colonization_requested.emit(family_handle, source_cell))
		rows.add_child(button)
	return panel


func _delta_accent(delta: String) -> Color:
	if delta.begins_with("+"):
		return UITokens.GOOD
	if delta.begins_with("-") or delta.begins_with("−"):
		return UITokens.RISK
	return UITokens.ARCHIVE_INK_MUTED


func _add_fact_grid(facts: Array) -> Control:
	var panel := FactGridScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(panel)
	var grid := panel.get_node("Grid") as GridContainer
	grid.columns = _fact_columns_for_width(facts.size(), _content_width())
	_fact_columns.append(grid.columns)
	_fact_grids.append(grid)
	for raw in facts:
		var fact: Dictionary = raw
		var cell := FactCellScene.instantiate() as VBoxContainer
		grid.add_child(cell)
		var label := cell.get_node("Label") as Label
		label.text = String(fact.get("label", ""))
		var value := cell.get_node("Value") as Label
		value.text = String(fact.get("value", "—"))
		value.clip_text = false
		value.autowrap_mode = TextServer.AUTOWRAP_OFF
		value.custom_minimum_size.y = 18
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_color_override("font_color",
			fact.get("accent", UITokens.ARCHIVE_INK))
	return panel


# 事实网格按数量选列，保证最后一行不留孤格：4 项用 2×2，8 项用 4×2，
# 其余尽量 3 列；7 项拆成 4+3 也比 3+3+1 更整齐。窄列再降到 2 列，避免撑破分栏。
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


func _fact_columns_for_width(fact_count: int, width: float) -> int:
	var balanced := _balanced_fact_columns(fact_count)
	if width <= 1.0:
		return balanced
	if width < 220.0:
		return 1
	if width < 420.0:
		return mini(balanced, 2)
	return balanced


func _content_width() -> float:
	if _scroll != null and _scroll.size.x > 1.0:
		return _scroll.size.x
	if size.x > 1.0:
		return size.x
	return 0.0


func _fit_embedded_layout() -> void:
	_constrain_autowrap(_content)
	_fit_fact_grids()
	if _embedded and is_inside_tree():
		call_deferred("_fit_fact_grids")


func _constrain_autowrap(node: Node) -> void:
	if node == null:
		return
	if node is Label:
		var label := node as Label
		if label.autowrap_mode != TextServer.AUTOWRAP_OFF:
			label.custom_minimum_size.x = 0
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for child in node.get_children():
		_constrain_autowrap(child)


func _fit_fact_grids() -> void:
	if _fact_grids.is_empty():
		return
	var width := _content_width()
	if width <= 1.0:
		return
	for index in range(_fact_grids.size()):
		var grid := _fact_grids[index]
		if grid == null or not is_instance_valid(grid):
			continue
		var next_columns := _fact_columns_for_width(grid.get_child_count(), width)
		grid.columns = next_columns
		if index < _fact_columns.size():
			_fact_columns[index] = next_columns


func _add_rows_card(title_text: String, icon_key: String, accent: Color,
		rows: Array) -> Control:
	if rows.is_empty():
		return null
	var panel := RowsCardScene.instantiate() as PanelContainer
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.clip_contents = false
	_content.add_child(panel)
	var icon := panel.get_node("Box/TitleRow/Icon") as IconBadge
	icon.set_semantic(StringName(icon_key), accent)
	var title := panel.get_node("Box/TitleRow/Title") as Label
	title.text = title_text
	title.add_theme_color_override("font_color", accent)
	var row_box := panel.get_node("Box/Rows") as VBoxContainer
	for raw in rows:
		var data: Dictionary = raw
		if not bool(data.get("visible", true)):
			continue
		var line := DetailLineScene.instantiate() as VBoxContainer
		row_box.add_child(line)
		var name_label := line.get_node("Line/Name") as Label
		name_label.text = String(data.get("name", ""))
		name_label.clip_text = true
		var value_text := String(data.get("value", "")).strip_edges()
		var value_label := line.get_node("Line/Value") as Label
		value_label.text = value_text
		# clip_text 会把 Label 最小宽度收成 0。嵌入右侧分栏时 Name 会吃掉整行，
		# 满意度/收支这种短数字就只剩左边标签。短值必须按文字宽度占位。
		var detail := String(data.get("detail", "")).strip_edges()
		var value_too_long := value_text.length() > 22
		value_label.clip_text = false
		value_label.visible = not value_text.is_empty() and not value_too_long
		if value_too_long:
			if detail.is_empty():
				detail = value_text
			elif detail != value_text:
				detail = "%s\n%s" % [value_text, detail]
		var detail_label := line.get_node("Detail") as Label
		detail_label.text = detail
		detail_label.visible = not detail.is_empty()
		var tooltip := String(data.get("tooltip", "")).strip_edges()
		line.tooltip_text = tooltip if not tooltip.is_empty() else detail
	return panel


func _add_state_card(state: Dictionary) -> Control:
	var accent: Color = state.get("accent", UITokens.WARN)
	var panel := StateCardScene.instantiate() as PanelContainer
	_content.add_child(panel)
	var label := panel.get_node("Box/Label") as Label
	label.text = String(state.get("label", "经营状态"))
	label.add_theme_color_override("font_color", accent)
	var detail := panel.get_node("Box/Detail") as Label
	detail.text = String(state.get("detail", ""))
	var meta_text := String(state.get("meta", ""))
	var meta := panel.get_node("Box/Meta") as Label
	meta.text = meta_text
	meta.visible = not meta_text.is_empty()
	return panel


func _add_finance_card(finance: Dictionary) -> Control:
	var panel := _add_fact_grid([
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
	return panel


func _add_muted_note(text: String, color: Color = UITokens.ARCHIVE_INK_MUTED) -> Control:
	var note := NoteScene.instantiate() as Label
	note.text = text
	note.add_theme_color_override("font_color", color)
	_content.add_child(note)
	return note


func _configure_section_nav(kind: String) -> void:
	var labels := {
		"overview": "概览",
		"operations": "需求" if kind == "cohort" else \
			"人物与分支" if kind == "family" else "经营" if kind == "building" \
			else "供需",
		"effects": "效果",
	}
	var visible_count := 0
	for section_id in _section_buttons:
		var button := _section_buttons[section_id] as Button
		button.text = String(labels.get(section_id, section_id))
		button.visible = _section_targets.has(section_id)
		visible_count += 1 if button.visible else 0
	_section_nav.visible = visible_count > 1


func _scroll_to_section(section_id: String) -> void:
	if _scroll == null or not _section_targets.has(section_id):
		return
	call_deferred("_ensure_section_visible", section_id)


func _ensure_section_visible(section_id: String) -> void:
	var target := _section_targets.get(section_id) as Control
	if target != null and is_instance_valid(target):
		_scroll.ensure_control_visible(target)


func _restore_scroll(value: int) -> void:
	if _scroll != null:
		_scroll.scroll_vertical = value


# ─── 测试钩子 ────────────────────────────────────────────────────────────

func title_text() -> String:
	return _title_label.text if _title_label != null else ""


func subtitle_text() -> String:
	return _subtitle_label.text if _subtitle_label != null else ""


func fact_grid_columns() -> Array[int]:
	return _fact_columns.duplicate()
