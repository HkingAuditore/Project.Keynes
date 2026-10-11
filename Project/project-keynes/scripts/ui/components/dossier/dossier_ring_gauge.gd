extends DossierChart
class_name DossierRingGauge

## 阶层满意度小环：外圈是满意度，中心是百分比，下方是阶层名与人口占比。
## 点击发出 pressed，用于从总览跳转到对应阶层。

signal pressed(gauge_id: Variant)

var gauge_id: Variant = null
var label := ""
var caption := ""
var accent := UITokens.DOSSIER_BRASS
var _value := 0.0
var _from := 0.0
var _hover := false


func _init() -> void:
	super()
	custom_minimum_size = Vector2(84.0, 104.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func set_gauge(p_id: Variant, p_label: String, value: float, p_caption: String,
		p_accent: Color, tooltip: String = "") -> void:
	_from = lerpf(_from, _value, _blend)
	gauge_id = p_id
	label = p_label
	caption = p_caption
	accent = p_accent
	_value = clampf(value, 0.0, 1.0)
	tooltip_text = tooltip
	_start_animation()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit(gauge_id)
			accept_event()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_MOUSE_ENTER:
			_hover = true
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			_hover = false
			queue_redraw()


func _draw() -> void:
	if _hover:
		draw_rect(Rect2(Vector2.ZERO, size), UITokens.DOSSIER_HOVER)
	var radius := minf(size.x * 0.5 - 8.0, 28.0)
	var center := Vector2(size.x * 0.5, radius + 8.0)
	draw_arc(center, radius, 0.0, TAU, 48, UITokens.DOSSIER_TRACK, 6.0, true)
	var value := lerpf(_from, _value, _blend) * _grow
	if value > 0.001:
		draw_arc(center, radius, -PI * 0.5, -PI * 0.5 + TAU * value, 48, accent, 6.0, true)
	var text := "%d%%" % int(round(value * 100.0))
	var width := _text_width(text, 15, "serif")
	_text(Vector2(center.x - width * 0.5, center.y + 6.0), text, 15, UITokens.DOSSIER_INK, "serif")
	var label_y := center.y + radius + 18.0
	_text(Vector2(0.0, label_y), _fit_text(label, 12, size.x - 4.0), 12, UITokens.DOSSIER_INK,
		"sans_strong", HORIZONTAL_ALIGNMENT_CENTER, size.x)
	_text(Vector2(0.0, label_y + 15.0), _fit_text(caption, 11, size.x - 4.0), 11,
		UITokens.DOSSIER_INK_MUTED, "sans", HORIZONTAL_ALIGNMENT_CENTER, size.x)
