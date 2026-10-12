class_name GmTodSunPad
extends VBoxContainer

signal sun_preview_requested(active: bool, uv: Vector2, height_scale: float)

var _status: Label
var _map_drag_checkbox: CheckBox
var _height_slider: HSlider
var _follow_button: Button
var _uv := Vector2(0.25, 0.5)
var _height_scale := 1.0
var _preview := false
var _day_night := true
var _azimuth_deg := -60.0
var _elevation_deg := 37.0
var _available := true
var _suppress := false


func _ready() -> void:
	add_theme_constant_override("separation", UITokens.SPACE_XS)
	var header := Label.new()
	header.text = "太阳位置"
	header.add_theme_font_size_override("font_size", UITokens.FONT_SECTION)
	header.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	add_child(header)
	_map_drag_checkbox = CheckBox.new()
	_map_drag_checkbox.text = "在地图上拖动太阳"
	_map_drag_checkbox.focus_mode = Control.FOCUS_NONE
	_map_drag_checkbox.toggled.connect(_on_map_drag_toggled)
	add_child(_map_drag_checkbox)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", UITokens.TEXT_MAIN)
	_status.add_theme_font_size_override("font_size", UITokens.FONT_BODY)
	add_child(_status)
	var hint := Label.new()
	hint.text = "勾选后拖动地图上的太阳标记，关掉面板也能继续拖。昼夜循环开着时改时刻和纬度；永昼时标记在哪边，光就从哪边来，越靠近地图中心太阳越高。点「恢复跟随」交还时钟。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITokens.TEXT_MUTED)
	hint.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
	add_child(hint)
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
	_height_slider.editable = false
	_height_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_height_slider.focus_mode = Control.FOCUS_NONE
	_height_slider.value_changed.connect(_on_height_changed)
	height_row.add_child(_height_slider)
	add_child(height_row)
	_refresh_status()


func apply_runtime_state(state: Dictionary) -> void:
	if not bool(state.get("ok", false)):
		return
	_preview = bool(state.get("preview", false))
	_day_night = bool(state.get("day_night", true))
	_azimuth_deg = float(state.get("azimuth_deg", _azimuth_deg))
	_elevation_deg = float(state.get("elevation_deg", _elevation_deg))
	var uv_value: Variant = state.get("uv", _uv)
	if uv_value is Vector2:
		_uv = uv_value
	_height_scale = clampf(float(state.get("height_scale", _height_scale)), 0.2, 1.5)
	_suppress = true
	if _map_drag_checkbox != null and _map_drag_checkbox.button_pressed != _preview:
		_map_drag_checkbox.button_pressed = _preview
	if _height_slider != null and not is_equal_approx(float(_height_slider.value), _height_scale):
		_height_slider.set_value_no_signal(_height_scale)
	_suppress = false
	_apply_control_enabled()
	_refresh_status()


func set_available(enabled: bool) -> void:
	_available = enabled
	_apply_control_enabled()
	if _status != null and not enabled:
		_status.text = "当前运行时不能预览太阳位置"


func _on_map_drag_toggled(pressed: bool) -> void:
	if _suppress or not _available:
		return
	_preview = pressed
	_apply_control_enabled()
	_refresh_status()
	sun_preview_requested.emit(pressed, _uv, _height_scale)


func _on_follow_pressed() -> void:
	if not _available:
		return
	_preview = false
	_suppress = true
	if _map_drag_checkbox != null:
		_map_drag_checkbox.button_pressed = false
	_suppress = false
	_apply_control_enabled()
	_refresh_status()
	sun_preview_requested.emit(false, _uv, _height_scale)


func _on_height_changed(value: float) -> void:
	if _suppress or not _available or not _preview:
		return
	_height_scale = value
	_refresh_status()
	sun_preview_requested.emit(true, _uv, _height_scale)


func _apply_control_enabled() -> void:
	if _map_drag_checkbox != null:
		_map_drag_checkbox.disabled = not _available
	if _height_slider != null:
		_height_slider.editable = _available and _preview
	if _follow_button != null:
		_follow_button.disabled = not _available or not _preview


func _refresh_status() -> void:
	if _status == null or not _available:
		return
	_status.text = _format_status(_preview, _uv, _height_scale, _day_night, _azimuth_deg, _elevation_deg)


static func _format_status(preview: bool, uv: Vector2, height_scale: float,
		day_night: bool = true, azimuth_deg: float = -60.0, elevation_deg: float = 37.0) -> String:
	if not day_night:
		var eternal_mode := "地图拖动中" if preview else "永昼"
		return "%s  方位 %d°  ·  高度 %d°  ·  倍率 x%.2f" % [
			eternal_mode, int(round(azimuth_deg)), int(round(elevation_deg)), height_scale]
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
	var mode := "地图拖动中" if preview else "跟随时钟"
	return "%s  %02d:00  %s  ·  %s  ·  高度 x%.2f" % [
		mode, hour, name, lat_text, height_scale]
