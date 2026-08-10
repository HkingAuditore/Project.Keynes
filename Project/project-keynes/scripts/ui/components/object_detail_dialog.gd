extends Control
class_name ObjectDetailDialog

const FactGridScene := preload("res://scenes/ui/object_fact_grid.tscn")
const FactCellScene := preload("res://scenes/ui/object_fact_cell.tscn")
const RowsCardScene := preload("res://scenes/ui/object_rows_card.tscn")
const DetailLineScene := preload("res://scenes/ui/object_detail_line.tscn")
const StateCardScene := preload("res://scenes/ui/object_state_card.tscn")
const NoteScene := preload("res://scenes/ui/object_note.tscn")
const TaxSectionScene := preload("res://scenes/ui/object_tax_section.tscn")
const TaxLaneScene := preload("res://scenes/ui/object_tax_lane.tscn")

signal closed()

const TAX_KIND_IDS := {"income": 0, "consumption": 1, "business": 2,
	"import": 3, "export": 4}
const PANEL_MIN_SIZE := Vector2(620.0, 520.0)

var _header_icon: IconBadge
var _title_label: Label
var _subtitle_label: Label
var _content: VBoxContainer
var _status_label: Label
var _player_controller = null
var _country_handle := 0
var _cell := -1
var _editable := false
var _current_day := -1
var _policy_version := -1
var _lanes: Dictionary = {}
var _pending: Dictionary = {}
var _last_command_result: Dictionary = {}
var _fact_columns: Array[int] = []


func _ready() -> void:
	if _content != null:
		return
	_header_icon = get_node_or_null("Center/Dialog/Body/TitleRow/HeaderIcon") as IconBadge
	_title_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/Title") as Label
	_subtitle_label = get_node_or_null("Center/Dialog/Body/TitleRow/Titles/Subtitle") as Label
	_content = get_node_or_null("Center/Dialog/Body/Scroll/Content") as VBoxContainer
	_status_label = get_node_or_null("Center/Dialog/Body/Status") as Label
	var close_button := get_node_or_null("Center/Dialog/Body/TitleRow/CloseButton") as Button
	var backdrop_close := get_node_or_null("BackdropClose") as Button
	if _header_icon == null or _title_label == null or _subtitle_label == null \
			or _content == null or _status_label == null or close_button == null \
			or backdrop_close == null:
		push_error("ObjectDetailDialog 必须通过 object_detail_dialog.tscn 实例化。")
		return
	IconButton.apply(close_button, &"action.close", IconButton.SMALL, "关闭")
	close_button.pressed.connect(close_dialog)
	backdrop_close.pressed.connect(close_dialog)


func show_details(payload: Dictionary) -> void:
	if _content == null:
		_ready()
	_pending.clear()
	_lanes.clear()
	_fact_columns.clear()
	_country_handle = 0
	_cell = -1
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
		"family":
			_build_family_details(row)
	var tax: Dictionary = payload.get("tax", {})
	if bool(tax.get("available", false)):
		_build_tax_section(tax)
	elif kind != "resource" and not String(tax.get("reason", "")).is_empty():
		_add_muted_note(String(tax.get("reason", "")))


func set_player_controller(controller) -> void:
	_player_controller = controller
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
		{"label": "最短板", "value": String(row.get("worst_dimension", "—")), "accent": UITokens.WARN},
		{"label": "收入/人", "value": String(row.get("income", "—")), "accent": UITokens.GOOD},
		{"label": "支出/人", "value": String(row.get("expense", "—")), "accent": UITokens.RISK},
		{"label": "净额/人", "value": String(row.get("net", "—")),
			"accent": UITokens.GOOD if bool(row.get("net_positive", true)) else UITokens.RISK},
	])
	_add_rows_card("满意度维度", "growth", UITokens.ACCENT,
		row.get("satisfaction_rows", []))
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


func _build_family_details(row: Dictionary) -> void:
	_add_fact_grid([
		{"label": "家族人口", "value": String(row.get("population", "—")), "accent": UITokens.ACCENT},
		{"label": "重要人物", "value": "%d 位" % int(row.get("notable_people", 0)), "accent": UITokens.ACCENT},
		{"label": "家族产业", "value": "%s 栋" % String(row.get("owned_buildings", "0")), "accent": UITokens.CLIMATE},
		{"label": "现金财产", "value": String(row.get("cash_claim", "—")), "accent": UITokens.RESOURCE},
		{"label": "生产资产", "value": String(row.get("productive_asset_value", "—")), "accent": UITokens.RESOURCE},
		{"label": "净资产", "value": String(row.get("net_worth", "—")), "accent": UITokens.GOOD},
		{"label": "创立日", "value": "第 %d 日" % int(row.get("founded_day", 0)), "accent": UITokens.TEXT_MAIN},
		{"label": "衰退复核", "value": "%d 次" % int(row.get("decline_reviews", 0)), "accent": UITokens.TEXT_MUTED},
		{"label": "本地威望", "value": "%s · %s" % [
			["0", "I", "II", "III", "IV", "V"][clampi(int(row.get("prestige_level", 0)), 0, 5)],
			String(row.get("prestige_score", "0.0%"))], "accent": UITokens.ACCENT},
	])
	_add_rows_card("家族特性", "family.house", UITokens.ACCENT,
		row.get("trait_rows", []))
	_add_rows_card("行为偏好", "growth", UITokens.GOOD,
		row.get("behavior_rows", []))
	_add_rows_card("地块威望", "family.house", UITokens.ACCENT,
		row.get("branch_rows", []))
	_add_rows_card("已激活加成", "growth", UITokens.CLIMATE,
		row.get("modifier_rows", []))
	_add_rows_card("累计触发", "resource", UITokens.RESOURCE,
		row.get("trigger_rows", []))
	var people: Array = row.get("notable_person_rows", [])
	if people.is_empty():
		_add_muted_note("该家族目前没有重要人物。")
	else:
		_add_rows_card("主要人物", "family.house", UITokens.ACCENT, people)


func _delta_accent(delta: String) -> Color:
	if delta.begins_with("+"):
		return UITokens.GOOD
	if delta.begins_with("-") or delta.begins_with("−"):
		return UITokens.RISK
	return UITokens.TEXT_MUTED


func _add_fact_grid(facts: Array) -> void:
	var panel := FactGridScene.instantiate() as PanelContainer
	_content.add_child(panel)
	var grid := panel.get_node("Grid") as GridContainer
	grid.columns = _balanced_fact_columns(facts.size())
	_fact_columns.append(grid.columns)
	for raw in facts:
		var fact: Dictionary = raw
		var cell := FactCellScene.instantiate() as VBoxContainer
		grid.add_child(cell)
		var label := cell.get_node("Label") as Label
		label.text = String(fact.get("label", ""))
		var value := cell.get_node("Value") as Label
		value.text = String(fact.get("value", "—"))
		value.add_theme_font_override("font", UITokens.font_with_weight(650))
		value.add_theme_color_override("font_color",
			fact.get("accent", UITokens.TEXT_MAIN))


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
	var panel := RowsCardScene.instantiate() as PanelContainer
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
		var line := DetailLineScene.instantiate() as HBoxContainer
		row_box.add_child(line)
		var name_label := line.get_node("Name") as Label
		name_label.text = String(data.get("name", ""))
		var value_label := line.get_node("Value") as Label
		value_label.text = String(data.get("value", ""))


func _add_state_card(state: Dictionary) -> void:
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
	var note := NoteScene.instantiate() as Label
	note.text = text
	note.add_theme_color_override("font_color", color)
	_content.add_child(note)


# ─── 税收区 ──────────────────────────────────────────────────────────────

func _build_tax_section(tax: Dictionary) -> void:
	_current_day = int(tax.get("current_day", -1))
	_policy_version = int(tax.get("policy_version", -1))
	_country_handle = int(tax.get("country_handle", 0))
	_cell = int(tax.get("cell", -1))
	_editable = bool(tax.get("editable", false)) and _player_controller != null
	var section := TaxSectionScene.instantiate() as VBoxContainer
	_content.add_child(section)
	var icon := section.get_node("Head/Icon") as IconBadge
	icon.set_semantic(&"tax.section", UITokens.BRASS_HIGHLIGHT)
	var title := section.get_node("Head/Title") as Label
	title.text = "税收政策 · %s" % String(tax.get("country_name", ""))
	(section.get_node("Head/Readonly") as Control).visible = not _editable
	(section.get_node("Hint") as Control).visible = not _editable
	var lanes := section.get_node("Lanes") as VBoxContainer
	for raw in tax.get("items", []):
		lanes.add_child(_make_tax_lane(raw))


func _make_tax_lane(item: Dictionary) -> Control:
	var kind := String(item.get("kind", ""))
	var accent: Color = item.get("accent", UITokens.ACCENT)
	var has_override := bool(item.get("has_override", false))
	var base := int(item.get("base", 0))
	var panel := TaxLaneScene.instantiate() as PanelContainer
	var label := panel.get_node("Box/Row/Label") as Label
	label.text = String(item.get("kind_label", kind))
	label.add_theme_color_override("font_color", accent)
	var spin := panel.get_node("Box/Row/Spin") as SpinBox
	spin.editable = _editable
	spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	spin.set_value_no_signal(base)
	spin.get_line_edit().add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT if has_override else UITokens.TEXT_MUTED)
	spin.get_line_edit().text_submitted.connect(_on_lane_text_submitted.bind(kind))
	spin.get_line_edit().focus_exited.connect(_on_lane_focus_exited.bind(kind))
	var reset := panel.get_node("Box/Row/Reset") as Button
	reset.visible = _editable and has_override
	IconButton.apply(reset, &"action.reset", IconButton.SMALL, "重置为默认税率")
	reset.pressed.connect(_on_lane_reset_pressed.bind(kind))
	var clock := panel.get_node("Box/Row/Clock") as IconBadge
	clock.set_semantic(&"system.clock", UITokens.BRASS_HIGHLIGHT)
	var note := panel.get_node("Box/Note") as Label
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


# 输入确认始终写入显式本地覆盖，即使数值等于父级；只有重置按钮清除覆盖。
# 命令次日生效并进入 pending，直到 country_daily 原子提交后由 refresh_tax 解除。
func _on_lane_text_submitted(_text: String, kind: String) -> void:
	_confirm_lane(kind, true)


func _on_lane_focus_exited(kind: String) -> void:
	_confirm_lane(kind)


func _confirm_lane(kind: String, explicit_confirm: bool = false) -> void:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return
	var spin := lane.get("spin") as SpinBox
	var data: Dictionary = lane.get("data", {})
	var rate := int(spin.value)
	var base := int(data.get("base", 0))
	var overridden := bool(data.get("has_override", false))
	if rate == base and not explicit_confirm:
		return
	_submit_lane_override(kind, StringName(data.get("item_id", "")), rate)


func _on_lane_reset_pressed(kind: String) -> void:
	var lane: Dictionary = _lanes.get(kind, {})
	if lane.is_empty():
		return
	var data: Dictionary = lane.get("data", {})
	_clear_lane_override(kind, StringName(data.get("item_id", "")))


func _submit_lane_override(kind: String, item_id: StringName, rate: int) -> void:
	if not _editable or _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		&"country.tax.cell.set_override", {
			"cell": _cell, "kind": int(TAX_KIND_IDS[kind]),
			"item_id": item_id, "rate_percent": rate})
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
		_set_status("税率命令已确认，将于第 %d 日生效" %
			int(result.get("effective_day", _effective_day())))
	else:
		if not lane.is_empty():
			(lane.get("spin") as SpinBox).set_value_no_signal(
				int((lane.get("data") as Dictionary).get("base", 0)))
		_set_status(String(result.get("reason", "税率命令提交失败")), true)


func _clear_lane_override(kind: String, item_id: StringName) -> void:
	if not _editable or _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		&"country.tax.cell.clear_override", {
			"cell": _cell, "kind": int(TAX_KIND_IDS[kind]),
			"item_id": item_id})
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
		_set_status("已恢复继承税率，将于第 %d 日生效" %
			int(result.get("effective_day", _effective_day())))
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
