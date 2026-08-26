extends VBoxContainer
class_name TaxLaneEditor

signal override_requested(scope: String, kind: String, item_id: String, rate: int)
signal reset_requested(scope: String, kind: String, item_id: String)
signal editing_finished()

const COMMIT_DELAY_SEC := 0.18
const TAX_RATE_MIN_BP := -100000
const TAX_RATE_MAX_BP := 10000

var _data: Dictionary = {}
var _pending := false
var _pending_rate := 0
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
	var snapshot := data.duplicate(true)
	var editable := bool(snapshot.get("editable", false))
	var accent: Color = snapshot.get("accent", UITokens.ACCENT)
	_label.text = String(snapshot.get("kind_label", snapshot.get("kind", "税率")))
	_label.add_theme_color_override("font_color", accent)
	_spin.editable = editable
	if _pending:
		# Godot 4.6 SpinBox 的 text_submitted / editing_toggled 是延迟信号，
		# 会在提交后按旧 Range 值把 LineEdit 刷成继承 0%。pending 期间每次
		# live patch 都必须把已确认税率写回去，不能只是“跳过覆盖”。
		_data = snapshot
		_data["base"] = _pending_rate
		_data["has_override"] = true
		_set_spin_rate(_pending_rate)
		_reset.visible = false
		_clock.visible = true
		_refresh_note()
		return
	_data = snapshot
	# 箭头/拖动不会让 LineEdit 获焦。只要当前显示值已经离开上次权威税率，
	# 就视为草稿，避免 live patch 把仍未提交的继承税率（常见是 0%）写回去。
	var displayed := percent_to_basis_points(float(_spin.value))
	var new_base := int(_data.get("base", 0))
	if displayed != previous_base and displayed != new_base:
		var was_dirty := _dirty
		_dirty = true
		if not was_dirty and not _spin.get_line_edit().has_focus() \
				and _commit_timer != null:
			_commit_timer.start()
	if not _dirty and not _has_edit_focus():
		_apply_authoritative_value()
	_reset.visible = editable and bool(_data.get("has_override", false)) \
		and not _dirty
	_refresh_note()


func editor_key(cell_idx: int) -> String:
	var item_key := String(_data.get("item_id", ""))
	if String(_data.get("scope", "item")) == "default":
		item_key = "default"
	return "cell:%d/%s/%s" % [cell_idx, String(_data.get("kind", "")), item_key]


func mark_pending(rate: int) -> void:
	_pending = true
	_pending_rate = rate
	_dirty = false
	_stop_commit_timer()
	_data["base"] = rate
	_data["has_override"] = true
	_set_spin_rate(rate)
	_reset.visible = false
	_clock.visible = true
	_refresh_note()
	# 排在 SpinBox 自身的 DEFERRED text_submitted / editing_toggled 之后。
	call_deferred("_restore_pending_spin")


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
	_set_spin_rate(int(_data.get("base", 0)))
	_spin.get_line_edit().add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT if bool(_data.get("has_override", false)) \
		else UITokens.ARCHIVE_INK_MUTED)


func _set_spin_rate(rate: int) -> void:
	if _spin == null:
		return
	_applying = true
	_spin.set_value_no_signal(basis_points_to_percent(rate))
	var line := _spin.get_line_edit()
	if line != null:
		var shown := _format_rate(rate, false)
		if not line.has_focus() and not String(_spin.suffix).is_empty():
			shown = "%s %s" % [shown, _spin.suffix]
		if line.text != shown:
			line.text = shown
		line.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	_applying = false


func _restore_pending_spin() -> void:
	if _pending and _spin != null:
		_set_spin_rate(_pending_rate)


func _refresh_note() -> void:
	var inherited := int(_data.get("default_rate", 0))
	var base := int(_data.get("base", inherited))
	var effective := int(_data.get("effective", base))
	var prefix := "国家默认" if String(_data.get("scope", "item")) == "default" else "此地默认"
	var parts := PackedStringArray(["%s %s" % [prefix, _format_rate(inherited)]])
	if effective != base:
		parts.append("效果后 %s" % _format_rate(effective))
	if _pending:
		parts.append("次日生效")
	_note.text = " · ".join(parts)


func _on_text_submitted(text: String) -> void:
	_sync_spin_from_text(text)
	_submit(true)


func _on_text_focus_entered() -> void:
	_stop_commit_timer()


func _on_focus_exited() -> void:
	_sync_spin_from_text(_spin.get_line_edit().text)
	_submit(false)
	editing_finished.emit()


static func parse_rate_text(text: String, fallback: int) -> int:
	var cleaned := text.strip_edges().replace("%", "").replace("+", "").strip_edges()
	cleaned = cleaned.replace(",", ".")
	if cleaned.is_empty():
		return fallback
	if cleaned.is_valid_int():
		return clampi(cleaned.to_int() * 100, TAX_RATE_MIN_BP, TAX_RATE_MAX_BP)
	if cleaned.is_valid_float():
		return percent_to_basis_points(cleaned.to_float())
	return fallback


static func basis_points_to_percent(rate_basis_points: int) -> float:
	return float(rate_basis_points) / 100.0


static func percent_to_basis_points(rate_percent: float) -> int:
	return clampi(int(round(rate_percent * 100.0)), TAX_RATE_MIN_BP,
		TAX_RATE_MAX_BP)


static func _format_rate(rate_basis_points: int, include_suffix: bool = true) -> String:
	var percent := basis_points_to_percent(rate_basis_points)
	var shown := "%d" % int(round(percent)) \
		if is_equal_approx(percent, round(percent)) else "%.2f" % percent
	return "%s%%" % shown if include_suffix else shown


func _sync_spin_from_text(text: String) -> void:
	if _spin == null:
		return
	var rate := parse_rate_text(text, percent_to_basis_points(float(_spin.value)))
	if rate != percent_to_basis_points(float(_spin.value)):
		_set_spin_rate(rate)


func _on_value_changed(_value: float) -> void:
	if _applying or _pending or not bool(_data.get("editable", false)):
		return
	var rate := percent_to_basis_points(float(_spin.value))
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
	var rate := percent_to_basis_points(float(_spin.value))
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
