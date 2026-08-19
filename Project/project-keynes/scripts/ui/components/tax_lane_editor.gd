extends VBoxContainer
class_name TaxLaneEditor

signal override_requested(scope: String, kind: String, item_id: String, rate: int)
signal reset_requested(scope: String, kind: String, item_id: String)
signal editing_finished()

var _data: Dictionary = {}
var _pending := false
var _spin: SpinBox
var _reset: Button
var _clock: Control
var _note: Label
var _label: Label


func _ready() -> void:
	if _spin != null:
		return
	_label = get_node("Box/Row/Label") as Label
	_spin = get_node("Box/Row/Spin") as SpinBox
	_reset = get_node("Box/Row/Reset") as Button
	_clock = get_node("Box/Row/Clock") as Control
	_note = get_node("Box/Note") as Label
	_spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_spin.get_line_edit().text_submitted.connect(_on_text_submitted)
	_spin.get_line_edit().focus_exited.connect(_on_focus_exited)
	_reset.pressed.connect(_on_reset_pressed)
	IconButton.apply(_reset, &"action.reset", IconButton.SMALL, "恢复继承税率")


func set_data(data: Dictionary) -> void:
	if _spin == null:
		_ready()
	_data = data.duplicate(true)
	var editable := bool(_data.get("editable", false))
	var accent: Color = _data.get("accent", UITokens.ACCENT)
	_label.text = String(_data.get("kind_label", _data.get("kind", "税率")))
	_label.add_theme_color_override("font_color", accent)
	_spin.editable = editable
	if not _pending and not _spin.get_line_edit().has_focus():
		_apply_authoritative_value()
	_reset.visible = editable and bool(_data.get("has_override", false)) and not _pending
	_refresh_note()


func editor_key(cell_idx: int) -> String:
	var item_key := String(_data.get("item_id", ""))
	if String(_data.get("scope", "item")) == "default":
		item_key = "default"
	return "cell:%d/%s/%s" % [cell_idx, String(_data.get("kind", "")), item_key]


func mark_pending(rate: int) -> void:
	_pending = true
	_spin.set_value_no_signal(rate)
	_spin.get_line_edit().add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	_reset.visible = false
	_clock.visible = true
	_refresh_note()


func resolve_pending() -> void:
	_pending = false
	_clock.visible = false
	_apply_authoritative_value()
	_reset.visible = bool(_data.get("editable", false)) \
		and bool(_data.get("has_override", false))
	_refresh_note()


func is_pending() -> bool:
	return _pending


func lane_data() -> Dictionary:
	return _data.duplicate(true)


func is_editing() -> bool:
	return _spin != null and _spin.get_line_edit().has_focus()


func _apply_authoritative_value() -> void:
	var base := int(_data.get("base", 0))
	_spin.set_value_no_signal(base)
	_spin.get_line_edit().add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT if bool(_data.get("has_override", false)) \
		else UITokens.TEXT_MUTED)


func _refresh_note() -> void:
	var inherited := int(_data.get("default_rate", 0))
	var base := int(_data.get("base", inherited))
	var effective := int(_data.get("effective", base))
	var prefix := "国家默认" if String(_data.get("scope", "item")) == "default" else "此地默认"
	var parts := PackedStringArray(["%s %d%%" % [prefix, inherited]])
	if effective != base:
		parts.append("效果后 %d%%" % effective)
	if _pending:
		parts.append("次日生效")
	_note.text = " · ".join(parts)


func _on_text_submitted(_text: String) -> void:
	_submit(true)


func _on_focus_exited() -> void:
	_submit(false)
	editing_finished.emit()


func _submit(explicit: bool) -> void:
	if _pending or not bool(_data.get("editable", false)):
		return
	var rate := int(_spin.value)
	if not explicit and rate == int(_data.get("base", 0)):
		return
	override_requested.emit(
		String(_data.get("scope", "item")),
		String(_data.get("kind", "")),
		String(_data.get("item_id", "")),
		rate)


func _on_reset_pressed() -> void:
	if _pending or not bool(_data.get("editable", false)):
		return
	reset_requested.emit(
		String(_data.get("scope", "item")),
		String(_data.get("kind", "")),
		String(_data.get("item_id", "")))
