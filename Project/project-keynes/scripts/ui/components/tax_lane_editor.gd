extends VBoxContainer
class_name TaxLaneEditor

signal override_requested(scope: String, kind: String, item_id: String, rate: int, mode: int)
signal reset_requested(scope: String, kind: String, item_id: String)
signal editing_finished()

const COMMIT_DELAY_SEC := 0.18
const TAX_RATE_MIN_BP := -100000
const TAX_RATE_MAX_BP := 10000
const TAX_MODE_PERCENT_BP := 0
const TAX_MODE_ABSOLUTE := 1
const TAX_ABSOLUTE_MIN := -1000000000
const TAX_ABSOLUTE_MAX := 1000000000

var _data: Dictionary = {}
var _pending := false
var _pending_rate := 0
var _pending_mode := TAX_MODE_PERCENT_BP
var _dirty := false
var _applying := false
var _spin: SpinBox
var _mode_button: OptionButton
var _reset: Button
var _clock: Control
var _note: Label
var _label: Label
var _commit_timer: Timer


func _ready() -> void:
	if _spin != null:
		return
	_label = get_node("Box/Row/Label") as Label
	_mode_button = get_node_or_null("Box/Row/Mode") as OptionButton
	_spin = get_node("Box/Row/Spin") as SpinBox
	_reset = get_node("Box/Row/Reset") as Button
	_clock = get_node("Box/Row/Clock") as Control
	_note = get_node("Box/Note") as Label
	if _mode_button != null:
		_mode_button.clear()
		_mode_button.add_item("%", TAX_MODE_PERCENT_BP)
		_mode_button.add_item("定额", TAX_MODE_ABSOLUTE)
		_mode_button.item_selected.connect(_on_mode_selected)
	_spin.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_spin.get_line_edit().text_changed.connect(_on_text_changed)
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
	var previous_base := int(_data.get("base", _current_value()))
	var previous_mode := int(_data.get("mode", TAX_MODE_PERCENT_BP))
	var snapshot := data.duplicate(true)
	var editable := bool(snapshot.get("editable", false))
	var accent: Color = snapshot.get("accent", UITokens.ACCENT)
	_label.text = String(snapshot.get("kind_label", snapshot.get("kind", "税率")))
	_label.add_theme_color_override("font_color", accent)
	_spin.editable = editable
	if _mode_button != null:
		_mode_button.disabled = not editable
	if _pending:
		# Godot 4.6 SpinBox 的 text_submitted / editing_toggled 是延迟信号，
		# 会在提交后按旧 Range 值把 LineEdit 刷成继承 0%。pending 期间每次
		# live patch 都必须把已确认税率写回去，不能只是“跳过覆盖”。
		_data = snapshot
		_data["base"] = _pending_rate
		_data["mode"] = _pending_mode
		_data["has_override"] = true
		_set_spin_value(_pending_rate, _pending_mode)
		_set_mode_button(_pending_mode)
		_reset.visible = false
		_clock.visible = true
		_refresh_note()
		return
	_data = snapshot
	# 箭头/拖动不会让 LineEdit 获焦。只要当前显示值已经离开上次权威税率，
	# 就视为草稿，避免 live patch 把仍未提交的继承税率（常见是 0%）写回去。
	var displayed := _current_value()
	var displayed_mode := _current_mode()
	var new_base := int(_data.get("base", 0))
	var new_mode := int(_data.get("mode", TAX_MODE_PERCENT_BP))
	if (displayed != previous_base or displayed_mode != previous_mode) \
			and (displayed != new_base or displayed_mode != new_mode):
		var was_dirty := _dirty
		_dirty = true
		if not was_dirty and not _spin.get_line_edit().has_focus():
			_start_commit_timer()
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


func mark_pending(rate: int, mode: int = TAX_MODE_PERCENT_BP) -> void:
	_pending = true
	_pending_rate = rate
	_pending_mode = mode
	_dirty = false
	_stop_commit_timer()
	_data["base"] = rate
	_data["mode"] = mode
	_data["has_override"] = true
	_set_spin_value(rate, mode)
	_set_mode_button(mode)
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


func blocks_rebuild() -> bool:
	# pending 允许就地 patch（set_data 会保住待生效税率），但不能拆树重建。
	return _pending or is_editing()


func displayed_rate() -> int:
	return _current_value()


func displayed_mode() -> int:
	return _current_mode()


func apply_draft(rate: int, mode: int = -1) -> void:
	if _pending or not bool(_data.get("editable", false)):
		return
	var resolved_mode := mode if mode >= 0 else _current_mode()
	_dirty = true
	_set_spin_value(rate, resolved_mode)
	_set_mode_button(resolved_mode)
	_spin.get_line_edit().add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	_reset.visible = false
	_refresh_note()
	_start_commit_timer()


func _has_edit_focus() -> bool:
	return _spin != null and (_spin.has_focus() or _spin.get_line_edit().has_focus())


func _apply_authoritative_value() -> void:
	var mode := int(_data.get("mode", TAX_MODE_PERCENT_BP))
	_set_spin_value(int(_data.get("base", 0)), mode)
	_set_mode_button(mode)
	_spin.get_line_edit().add_theme_color_override("font_color",
		UITokens.BRASS_HIGHLIGHT if bool(_data.get("has_override", false)) \
		else UITokens.ARCHIVE_INK_MUTED)


func _configure_spin_for_mode(mode: int) -> void:
	if _spin == null:
		return
	if mode == TAX_MODE_ABSOLUTE:
		_spin.min_value = float(TAX_ABSOLUTE_MIN)
		_spin.max_value = float(TAX_ABSOLUTE_MAX)
		_spin.step = 1.0
		_spin.suffix = ""
		return
	_spin.min_value = -1000.0
	_spin.max_value = 100.0
	_spin.step = 0.01
	_spin.suffix = "%"


func _set_spin_value(rate: int, mode: int) -> void:
	if _spin == null:
		return
	_applying = true
	_configure_spin_for_mode(mode)
	if mode == TAX_MODE_ABSOLUTE:
		_spin.set_value_no_signal(float(rate))
	else:
		_spin.set_value_no_signal(basis_points_to_percent(rate))
	var line := _spin.get_line_edit()
	if line != null:
		var shown := _format_value(rate, mode, false)
		if not line.has_focus() and mode == TAX_MODE_PERCENT_BP \
				and not String(_spin.suffix).is_empty():
			shown = "%s %s" % [shown, _spin.suffix]
		if line.text != shown:
			line.text = shown
		line.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)
	_applying = false


func _set_mode_button(mode: int) -> void:
	if _mode_button == null:
		return
	_applying = true
	_mode_button.select(mode if mode == TAX_MODE_ABSOLUTE else TAX_MODE_PERCENT_BP)
	_applying = false


func _restore_pending_spin() -> void:
	if _pending and _spin != null:
		_set_spin_value(_pending_rate, _pending_mode)
		_set_mode_button(_pending_mode)


func _refresh_note() -> void:
	var inherited := int(_data.get("default_rate", 0))
	var inherited_mode := int(_data.get("default_mode", TAX_MODE_PERCENT_BP))
	var base := int(_data.get("base", inherited))
	var mode := int(_data.get("mode", inherited_mode))
	var effective := int(_data.get("effective", base))
	var effective_mode := int(_data.get("effective_mode", mode))
	var prefix := "国家默认" if String(_data.get("scope", "item")) == "default" else "此地默认"
	if _pending:
		_note.text = "当前有效 %s · 待生效 %s · 次日生效" % [
			_format_value(effective, effective_mode),
			_format_value(_pending_rate, _pending_mode)]
		return
	var parts := PackedStringArray(["%s %s" % [
		prefix, _format_value(inherited, inherited_mode)]])
	if effective != base or effective_mode != mode:
		parts.append("效果后 %s" % _format_value(effective, effective_mode))
	_note.text = " · ".join(parts)


func _on_mode_selected(index: int) -> void:
	if _applying or _pending or not bool(_data.get("editable", false)):
		return
	var mode := TAX_MODE_ABSOLUTE if index == TAX_MODE_ABSOLUTE else TAX_MODE_PERCENT_BP
	# 切换模式时归零，避免把 bp 误读成货币额。
	_dirty = true
	_set_spin_value(0, mode)
	_reset.visible = false
	_refresh_note()
	_start_commit_timer()


func _on_text_submitted(text: String) -> void:
	_sync_spin_from_text(text)
	_submit(true)


func _on_text_changed(text: String) -> void:
	if _applying or _pending or not bool(_data.get("editable", false)):
		return
	var mode := _current_mode()
	var fallback := _current_value()
	if text.strip_edges().is_empty():
		return
	var rate := parse_value_text(text, fallback, mode)
	if rate == fallback:
		return
	_applying = true
	if mode == TAX_MODE_ABSOLUTE:
		_spin.set_value_no_signal(float(rate))
	else:
		_spin.set_value_no_signal(basis_points_to_percent(rate))
	_applying = false
	_on_value_changed(_spin.value)


func _on_text_focus_entered() -> void:
	_stop_commit_timer()


func _on_focus_exited() -> void:
	_sync_spin_from_text(_spin.get_line_edit().text)
	_submit(false)
	editing_finished.emit()


static func parse_rate_text(text: String, fallback: int) -> int:
	return parse_value_text(text, fallback, TAX_MODE_PERCENT_BP)


static func parse_value_text(text: String, fallback: int, mode: int) -> int:
	var cleaned := text.strip_edges().replace("%", "").replace("+", "").strip_edges()
	cleaned = cleaned.replace(",", ".")
	if cleaned.is_empty():
		return fallback
	if mode == TAX_MODE_ABSOLUTE:
		if cleaned.is_valid_int():
			return clampi(cleaned.to_int(), TAX_ABSOLUTE_MIN, TAX_ABSOLUTE_MAX)
		if cleaned.is_valid_float():
			return clampi(int(round(cleaned.to_float())), TAX_ABSOLUTE_MIN, TAX_ABSOLUTE_MAX)
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
	return _format_value(rate_basis_points, TAX_MODE_PERCENT_BP, include_suffix)


static func _format_value(value: int, mode: int, include_suffix: bool = true) -> String:
	if mode == TAX_MODE_ABSOLUTE:
		return str(value)
	var percent := basis_points_to_percent(value)
	var shown := "%d" % int(round(percent)) \
		if is_equal_approx(percent, round(percent)) else "%.2f" % percent
	return "%s%%" % shown if include_suffix else shown


func _current_mode() -> int:
	if _mode_button != null:
		return TAX_MODE_ABSOLUTE if _mode_button.selected == TAX_MODE_ABSOLUTE \
			else TAX_MODE_PERCENT_BP
	return int(_data.get("mode", TAX_MODE_PERCENT_BP))


func _current_value() -> int:
	if _spin == null:
		return int(_data.get("base", 0))
	if _current_mode() == TAX_MODE_ABSOLUTE:
		return clampi(int(round(_spin.value)), TAX_ABSOLUTE_MIN, TAX_ABSOLUTE_MAX)
	return percent_to_basis_points(float(_spin.value))


func _sync_spin_from_text(text: String) -> void:
	if _spin == null:
		return
	var mode := _current_mode()
	var rate := parse_value_text(text, _current_value(), mode)
	if rate != _current_value():
		_set_spin_value(rate, mode)


func _on_value_changed(_value: float) -> void:
	if _applying or _pending or not bool(_data.get("editable", false)):
		return
	var rate := _current_value()
	var mode := _current_mode()
	if rate == int(_data.get("base", 0)) and mode == int(_data.get("mode", TAX_MODE_PERCENT_BP)):
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
	_start_commit_timer()


func _on_commit_timeout() -> void:
	if _pending or not _dirty:
		return
	_submit(true)
	if not _has_edit_focus():
		editing_finished.emit()


func _submit(explicit: bool) -> void:
	if _pending or not bool(_data.get("editable", false)):
		return
	var rate := _current_value()
	var mode := _current_mode()
	if not explicit and rate == int(_data.get("base", 0)) \
			and mode == int(_data.get("mode", TAX_MODE_PERCENT_BP)):
		_dirty = false
		_stop_commit_timer()
		return
	# 保持 dirty 穿过同步命令握手，避免 emit 期间的 live patch 把未 pending 的草稿盖回继承值。
	_stop_commit_timer()
	override_requested.emit(
		String(_data.get("scope", "item")),
		String(_data.get("kind", "")),
		String(_data.get("item_id", "")),
		rate,
		mode)
	if _pending:
		return
	if rate != int(_data.get("base", 0)) or mode != int(_data.get("mode", TAX_MODE_PERCENT_BP)):
		_dirty = true
	else:
		_dirty = false


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


func _start_commit_timer() -> void:
	if _commit_timer != null and _commit_timer.is_inside_tree():
		_commit_timer.start()
