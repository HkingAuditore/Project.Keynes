extends PanelContainer
class_name ResearchToast

# Thin HUD toast for research completion. Owned by GameUIManager; not a runtime.

const DISPLAY_MSEC := 3200
const MAX_VISIBLE := 2

var _stack: VBoxContainer
var _entries: Array = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme_type_variation = &"PKWorkspaceStatus"
	if _stack != null:
		return
	_stack = VBoxContainer.new()
	_stack.add_theme_constant_override("separation", 6)
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stack)
	visible = false


func show_research_completed(display_name: String) -> void:
	if display_name.strip_edges().is_empty():
		return
	_ready()
	while _entries.size() >= MAX_VISIBLE:
		_dismiss_oldest()
	var row := PanelContainer.new()
	row.theme_type_variation = &"PKInsetPanel"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 8)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(body)
	var icon := Label.new()
	IconButton.apply_to_label(icon, &"technology.state.completed", 14)
	icon.add_theme_color_override("font_color", UITokens.GOOD)
	body.add_child(icon)
	var text := Label.new()
	text.text = "「%s」研究完成，明日生效" % display_name
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.theme_type_variation = &"PKWorkspaceLabel"
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(text)
	_stack.add_child(row)
	visible = true
	UIAnimation.fade_slide_in(row, Vector2(0.0, 18.0), UITokens.ANIM_FAST)
	var token := {"row": row, "until": Time.get_ticks_msec() + DISPLAY_MSEC}
	_entries.append(token)
	get_tree().create_timer(float(DISPLAY_MSEC) / 1000.0).timeout.connect(
		func() -> void: _expire(token))


func _expire(token: Dictionary) -> void:
	if token not in _entries:
		return
	_entries.erase(token)
	var row: Control = token.get("row", null)
	if row != null and is_instance_valid(row):
		UIAnimation.fade_slide_out(row, Vector2(0.0, -12.0), UITokens.ANIM_FAST)
		get_tree().create_timer(UITokens.ANIM_FAST + 0.05).timeout.connect(
			func() -> void:
				if is_instance_valid(row):
					row.queue_free()
				if _entries.is_empty():
					visible = false
		)
	elif _entries.is_empty():
		visible = false


func _dismiss_oldest() -> void:
	if _entries.is_empty():
		return
	_expire(_entries[0])
