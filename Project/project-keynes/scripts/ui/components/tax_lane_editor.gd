extends VBoxContainer
class_name TaxLaneEditor

signal override_requested(scope: String, kind: String, item_id: String, rate: int)
signal reset_requested(scope: String, kind: String, item_id: String)
signal editing_finished()

const COMMIT_DELAY_SEC := 0.18

var _data: Dictionary = {}
var _pending := false
var _dirty := false
var _applying := false
var _spin: SpinBox
var _reset: Button
var _clock: Control
var _note: Label
var _label: Label
var _commit_timer: Timer


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
	_spin.get_line_edit().focus_entered.connect(_on_text_focus_entered)
	_spin.get_line_edit().focus_exited.connect(_on_focus_exited)
	_spin.value_changed.connect(_on_value_changed)
	_reset.pressed.connect(_on_reset_pressed)
	IconButton.apply(_reset, &"action.reset", IconButton.SMALL, "恢复继承税率")
	_commit_timer = Timer.new()
	_commit_timer.one_shot = true
	_commit_timer.wait_time = COMMIT_DELAY_SEC
	_commit_timer.process_mode = Node.PROCESS_MODE_ALWAYS
	_commit_timer.timeout.connect(_on_commit_timeout)
	add_child(_commit_timer)


func set_data(data: Dictionary) -> void:
	if _spin == null:
		_ready()
	var previous_base := int(_data.get("base", int(_spin.value)))
	_data = data.duplicate(true)
	var editable := bool(_data.get("editable", false))
	var accent: Color = _data.get("accent", UITokens.ACCENT)
	_label.text = String(_data.get("kind_label", _data.get("kind", "税率")))
	_label.add_theme_color_override("font_color", accent)
	_spin.editable = editable
	# 箭头/拖动不会让 LineEdit 获焦。只要当前显示值已经离开上次权威税率，
	# 就视为草稿，避免 live patch 把仍未提交的继承税率（常见是 0%）写回去。
	var displayed := int(_spin.value)
	var new_base := int(_data.get("base", 0))
	if not _pending and displayed != previous_base and displayed != new_base:
		var was_dirty := _dirty
		_dirty = true
		if not was_dirty and not _spin.get_line_edit().has_focus() \
				and _commit_timer != null:
			_commit_timer.start()
	if not _pending and not _dirty and not _has_edit_focus():
		_apply_authoritative_value()
	_reset.visible = editable and bool(_data.get("has_override", false)) \
		and not _pending and not _dirty
	_refresh_note()


func editor_key(cell_idx: int) -> String:
	var item_key := String(_data.get("item_id", ""))
	if String(_data.get("scope", "item")) == "default":
		item_key = "default"
	return "cell:%d/%s/%s" % [cell_idx, String(_data.get("kind", "")), item_key]


func mark_pending(rate: int) -> void:
	_pending = true
	_dirty = false
	_stop_commit_timer()
	_spin.set_value_no_signal(rate)
	_spin.get_line_edit().add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	_reset.visible = false
	_clock.visible = true
	_refresh_note()


func resolve_pending() -> void:
	_pending = false
	_dirty = false
	_stop_commit_timer()
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
	return _dirty or _has_edit_focus()


func _has_edit_focus() -> bool:
	return _spin != null and (_spin.has_focus() or _spin.get_line_edit().has_focus())


func _apply_authoritative_value() -> void:
	var base := int(_data.get("base", 0))
	_applying = true
	_spin.set_value_no_signal(base)
	_applying = false
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


func _on_text_focus_entered() -> void:
	_stop_commit_timer()


func _on_focus_exited() -> void:
	_submit(false)
	editing_finished.emit()


func _on_value_changed(_value: float) -> void:
	if _applying or _pending or not bool(_data.get("editable", false)):
		return
	var rate := int(_spin.value)
	if rate == int(_data.get("base", 0)):
		_dirty = false
		_stop_commit_timer()
		_reset.visible = bool(_data.get("editable", false)) \
			and bool(_data.get("has_override", false))
		_refresh_note()
		return
	_dirty = true
	_reset.visible = false
	_spin.get_line_edit().add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	_refresh_note()
	if _spin.get_line_edit().has_focus():
		_stop_commit_timer()
		return
	if _commit_timer != null:
		_commit_timer.start()


func _on_commit_timeout() -> void:
	if _pending or not _dirty:
		return
	_submit(true)
	if not _has_edit_focus():
		editing_finished.emit()


func _submit(explicit: bool) -> void:
	if _pending or not bool(_data.get("editable", false)):
		return
	var rate := int(_spin.value)
	if not explicit and rate == int(_data.get("base", 0)):
		_dirty = false
		_stop_commit_timer()
		return
	_dirty = false
	_stop_commit_timer()
	override_requested.emit(
		String(_data.get("scope", "item")),
		String(_data.get("kind", "")),
		String(_data.get("item_id", "")),
		rate)


func _on_reset_pressed() -> void:
	if _pending or not bool(_data.get("editable", false)):
		return
	_dirty = false
	_stop_commit_timer()
	reset_requested.emit(
		String(_data.get("scope", "item")),
		String(_data.get("kind", "")),
		String(_data.get("item_id", "")))


func _stop_commit_timer() -> void:
	if _commit_timer != null:
		_commit_timer.stop()
