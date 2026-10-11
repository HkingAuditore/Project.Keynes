extends DossierChart
class_name TechnologyQueueRow

## 研究队列中的一项：序号、名称、细进度线与预计完成。
## 行只在队列组成变化时创建；每日进度经 update_dynamic()/set_eta() 只重绘。

const DragPreviewScene := preload("res://scenes/ui/technology_drag_preview.tscn")
const ROW_HEIGHT := 32.0
const REMOVE_SIZE := 18.0

signal move_requested(technology: int, domain: int, position: int)
signal remove_requested(technology: int)
signal selected_requested(technology: int)

var technology_index := -1
var domain_index := -1
var queue_position := -1
var display_name := ""

var _accent: Color = UITokens.DOSSIER_UMBER
var _state := 3
var _fraction := 0.0
var _eta := ""
var _hover := false
var _remove_hover := false


func _init() -> void:
	super()
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func setup(technology: int, domain: int, position: int, title: String,
		accent: Color) -> void:
	technology_index = technology
	domain_index = domain
	queue_position = position
	display_name = title
	_accent = accent
	tooltip_text = "%s\n点击查看详情 · 拖动调整顺序或改换领域" % title
	queue_redraw()


func update_dynamic(state: int, fraction: float) -> void:
	var clamped := clampf(fraction, 0.0, 1.0)
	if state == _state and is_equal_approx(clamped, _fraction):
		return
	_state = state
	_fraction = clamped
	queue_redraw()


func set_eta(text: String) -> void:
	if text == _eta:
		return
	_eta = text
	queue_redraw()


func eta_text() -> String:
	return _eta


func _remove_rect() -> Rect2:
	return Rect2(size.x - REMOVE_SIZE - 2.0, (ROW_HEIGHT - REMOVE_SIZE) * 0.5 - 2.0,
		REMOVE_SIZE, REMOVE_SIZE)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var position := (event as InputEventMouseMotion).position
		var remove_hover := _remove_rect().has_point(position)
		if not _hover or remove_hover != _remove_hover:
			_hover = true
			_remove_hover = remove_hover
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			queue_redraw()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
			return
		if _remove_rect().has_point(button.position):
			remove_requested.emit(technology_index)
		else:
			selected_requested.emit(technology_index)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and (_hover or _remove_hover):
		_hover = false
		_remove_hover = false
		queue_redraw()


func _get_drag_data(_at_position: Vector2) -> Variant:
	if technology_index < 0:
		return null
	var preview := DragPreviewScene.instantiate() as Label
	preview.text = display_name
	set_drag_preview(preview)
	return {
		"type": "technology_queue_item",
		"technology": technology_index,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and String(data.get("type", "")) == "technology_queue_item"


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	move_requested.emit(int(data.get("technology", -1)), domain_index, queue_position)


func _draw() -> void:
	var w := size.x
	var head := queue_position == 0
	if _hover:
		draw_rect(Rect2(Vector2.ZERO, size), UITokens.DOSSIER_HOVER)
	if head:
		draw_rect(Rect2(0.0, 3.0, 2.0, ROW_HEIGHT - 8.0), _accent.lerp(UITokens.DOSSIER_INK, 0.2))
	_text(Vector2(6.0, 18.0), "%d" % (queue_position + 1), 12,
		UITokens.DOSSIER_INK_MUTED, "serif")
	var eta_width := _text_width(_eta, 11) if not _eta.is_empty() else 0.0
	var name_right := w - REMOVE_SIZE - 8.0 - (eta_width + 8.0 if eta_width > 0.0 else 0.0)
	_text(Vector2(22.0, 18.0), _fit_text(display_name, 13, name_right - 22.0,
		"sans_strong" if head else "sans"), 13, UITokens.DOSSIER_INK,
		"sans_strong" if head else "sans")
	if eta_width > 0.0:
		_text(Vector2(w - REMOVE_SIZE - 6.0 - eta_width, 18.0), _eta, 11,
			UITokens.DOSSIER_OXBLOOD if head else UITokens.DOSSIER_INK_MUTED)
	var track := Rect2(22.0, ROW_HEIGHT - 8.0, maxf(8.0, w - REMOVE_SIZE - 30.0), 3.0)
	_rounded_bar(track, UITokens.DOSSIER_TRACK, 1.5)
	if _fraction > 0.0:
		_rounded_bar(Rect2(track.position, Vector2(track.size.x * _fraction, track.size.y)),
			_accent.lerp(UITokens.DOSSIER_INK, 0.2), 1.5)
	var remove := _remove_rect()
	if _remove_hover:
		draw_rect(remove, UITokens.DOSSIER_SELECTED)
	_icon(&"action.close", remove.grow(-4.0),
		UITokens.DOSSIER_OXBLOOD if _remove_hover \
			else Color(UITokens.DOSSIER_INK_MUTED, 0.55 if _hover else 0.3))
	draw_line(Vector2(0.0, ROW_HEIGHT - 0.5), Vector2(w, ROW_HEIGHT - 0.5),
		UITokens.DOSSIER_RULE, 1.0)
