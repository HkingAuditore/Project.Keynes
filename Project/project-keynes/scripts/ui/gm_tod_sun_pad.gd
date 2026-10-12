class_name GmTodSunPad
extends VBoxContainer

signal sun_preview_requested(active: bool, uv: Vector2, height_scale: float)

const _TRACK_HEIGHT := 112.0
const _INSET := 12.0
const _LABEL_BAND := 16.0

var _status: Label
var _hint: Label
var _track: Control
var _height_slider: HSlider
var _follow_button: Button
var _uv := Vector2(0.25, 0.5)
var _height_scale := 1.0
var _preview := false
var _dragging := false
var _available := true


func _ready() -> void:
	add_theme_constant_override("separation", UITokens.SPACE_XS)
	var header := Label.new()
	header.text = "太阳位置"
	header.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	header.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	add_child(header)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	_status.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	add_child(_status)
	_hint = Label.new()
	_hint.text = "在方框内拖动太阳。锁定后可关闭本面板再截图；点「恢复跟随」交还时钟。"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	_hint.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	add_child(_hint)
	_track = Control.new()
	_track.custom_minimum_size = Vector2(0.0, _TRACK_HEIGHT)
	_track.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_track.mouse_filter = Control.MOUSE_FILTER_STOP
	_track.gui_input.connect(_on_track_input)
	_track.draw.connect(_draw_track)
	add_child(_track)
	var presets := HBoxContainer.new()
	presets.add_theme_constant_override("separation", UITokens.SPACE_XS)
	for preset in [["日出", 0.0], ["正午", 0.25], ["日落", 0.5], ["午夜", 0.75]]:
		var button := Button.new()
		button.text = String(preset[0])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_on_preset_pressed.bind(float(preset[1])))
		presets.add_child(button)
	add_child(presets)
	_follow_button = Button.new()
	_follow_button.text = "恢复跟随"
	_follow_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_follow_button.focus_mode = Control.FOCUS_NONE
	_follow_button.disabled = true
	_follow_button.pressed.connect(_on_follow_pressed)
	add_child(_follow_button)
	var height_row := HBoxContainer.new()
	height_row.add_theme_constant_override("separation", UITokens.SPACE_SM)
	var height_label := Label.new()
	height_label.text = "太阳高度"
	height_label.custom_minimum_size.x = 72.0
	height_row.add_child(height_label)
	_height_slider = HSlider.new()
	_height_slider.min_value = 0.2
	_height_slider.max_value = 1.5
	_height_slider.step = 0.01
	_height_slider.value = 1.0
	_height_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height_slider.focus_mode = Control.FOCUS_NONE
	_height_slider.value_changed.connect(_on_height_changed)
	height_row.add_child(_height_slider)
	add_child(height_row)
	_refresh_status()


func apply_runtime_state(state: Dictionary) -> void:
	if _dragging or not bool(state.get("ok", false)):
		return
	_preview = bool(state.get("preview", false))
	var uv_value: Variant = state.get("uv", _uv)
	if uv_value is Vector2:
		_uv = uv_value
	_height_scale = clampf(float(state.get("height_scale", _height_scale)), 0.2, 1.5)
	if _height_slider != null and not is_equal_approx(float(_height_slider.value), _height_scale):
		_height_slider.set_value_no_signal(_height_scale)
	if _follow_button != null:
		_follow_button.disabled = not _preview
	_refresh_status()
	if _track != null:
		_track.queue_redraw()


func set_available(enabled: bool) -> void:
	_available = enabled
	if _track != null:
		_track.mouse_filter = Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	if _height_slider != null:
		_height_slider.editable = enabled
	if _follow_button != null:
		_follow_button.disabled = not enabled or not _preview
	if _status != null and not enabled:
		_status.text = "当前运行时不能预览太阳位置"


func _on_track_input(event: InputEvent) -> void:
	if not _available:
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_dragging = true
			_set_uv_from_local(button.position)
			_commit(true)
		else:
			_dragging = false
		_track.accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_set_uv_from_local((event as InputEventMouseMotion).position)
		_commit(true)
		_track.accept_event()


func _on_preset_pressed(phase: float) -> void:
	if not _available:
		return
	_uv.x = fposmod(phase, 1.0)
	_commit(true)


func _on_follow_pressed() -> void:
	if not _available:
		return
	_commit(false)


func _on_height_changed(value: float) -> void:
	if not _available:
		return
	_height_scale = value
	_commit(true)


func _commit(active: bool) -> void:
	_preview = active
	if _follow_button != null:
		_follow_button.disabled = not active
	_refresh_status()
	if _track != null:
		_track.queue_redraw()
	sun_preview_requested.emit(active, _uv, _height_scale)


func _set_uv_from_local(local: Vector2) -> void:
	var rect := _content_rect()
	if rect.size.x <= 1.0 or rect.size.y <= 1.0:
		return
	var u := clampf((local.x - rect.position.x) / rect.size.x, 0.0, 0.999999)
	var v := 1.0 - clampf((local.y - rect.position.y) / rect.size.y, 0.0, 1.0)
	_uv = Vector2(u, v)


func _content_rect() -> Rect2:
	var size := _track.size if _track != null else Vector2.ZERO
	return Rect2(Vector2(_INSET, _INSET), Vector2(
		maxf(size.x - _INSET * 2.0, 1.0),
		maxf(size.y - _INSET - _LABEL_BAND, 1.0)))


func _draw_track() -> void:
	if _track == null:
		return
	var full := Rect2(Vector2.ZERO, _track.size)
	_track.draw_rect(full, UITokens.CARD_BG)
	_track.draw_rect(full, UITokens.PANEL_BORDER, false, 1.0)
	var rect := _content_rect()
	_track.draw_line(
		Vector2(rect.position.x, rect.position.y + rect.size.y * 0.5),
		Vector2(rect.end.x, rect.position.y + rect.size.y * 0.5),
		UITokens.PANEL_BORDER_SOFT, 1.0)
	for mark in [0.0, 0.25, 0.5, 0.75]:
		var x := rect.position.x + float(mark) * rect.size.x
		_track.draw_line(
			Vector2(x, rect.position.y),
			Vector2(x, rect.end.y),
			UITokens.PANEL_BORDER_SOFT, 1.0)
	var knob := Vector2(
		rect.position.x + _uv.x * rect.size.x,
		rect.position.y + (1.0 - _uv.y) * rect.size.y)
	_track.draw_circle(knob, 8.0, UITokens.BRASS_HIGHLIGHT)
	_track.draw_circle(knob, 3.5, Color(1.0, 0.96, 0.86))
	var font := UITokens.UI_FONT
	var labels := ["日出", "正午", "日落", "午夜"]
	var marks: Array[float] = [0.0, 0.25, 0.5, 0.75]
	for i in labels.size():
		var text_x := rect.position.x + marks[i] * rect.size.x
		_track.draw_string(font, Vector2(text_x - 12.0, rect.end.y + 14.0), labels[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, UITokens.FONT_SMALL, UITokens.TEXT_MUTED)
	_track.draw_string(font, Vector2(rect.position.x, rect.position.y + 11.0), "北",
		HORIZONTAL_ALIGNMENT_LEFT, -1, UITokens.FONT_SMALL, UITokens.TEXT_MUTED)
	_track.draw_string(font, Vector2(rect.position.x, rect.end.y - 2.0), "南",
		HORIZONTAL_ALIGNMENT_LEFT, -1, UITokens.FONT_SMALL, UITokens.TEXT_MUTED)


func _refresh_status() -> void:
	if _status == null:
		return
	_status.text = _format_status(_preview, _uv, _height_scale)


static func _format_status(preview: bool, uv: Vector2, height_scale: float) -> String:
	var phase := fposmod(uv.x, 1.0)
	var hour := int(floor(fposmod(phase - 0.75, 1.0) * 24.0)) % 24
	var name := "日出"
	if phase >= 0.125 and phase < 0.375:
		name = "正午"
	elif phase >= 0.375 and phase < 0.625:
		name = "日落"
	elif phase >= 0.625 and phase < 0.875:
		name = "午夜"
	var lat := int(round(clampf(uv.y * 2.0 - 1.0, -1.0, 1.0) * 90.0))
	var lat_text := "赤道"
	if lat > 0:
		lat_text = "北纬 %d°" % lat
	elif lat < 0:
		lat_text = "南纬 %d°" % abs(lat)
	var mode := "已锁定" if preview else "跟随时钟"
	return "%s  %02d:00  %s  ·  %s  ·  高度 x%.2f" % [
		mode, hour, name, lat_text, height_scale]
