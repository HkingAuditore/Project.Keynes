extends "res://scripts/ui/components/military/military_frame_panel.gd"
class_name MilitaryWarCard

## One active war on a cinnabar-edged sheet: opponent, war score and its four-part
## breakdown, losses, plus a single optional action.

signal action_requested(war_id: int)

var war_id := 0

@onready var _icon: IconBadge = $Box/Header/Icon
@onready var _title: Label = $Box/Header/Title
@onready var _role: Label = $Box/Header/Role
@onready var _days: Label = $Box/Header/Days
@onready var _score: Label = $Box/ScoreRow/ScoreValue
@onready var _losses: Label = $Box/ScoreRow/Losses
@onready var _parts: DossierBarList = $Box/Parts
@onready var _action: Button = $Box/Footer/Action


func _ready() -> void:
	_icon.set_semantic(&"military.war.front", UITokens.DOSSIER_OXBLOOD)
	_parts.diverging = true
	_parts.row_height = 22.0
	_parts.label_width = 64.0
	_parts.value_width = 40.0
	_style_action_button()
	_action.pressed.connect(func() -> void: action_requested.emit(war_id))


func set_action(text: String) -> void:
	if not text.is_empty():
		IconButton.apply_with_text(_action, &"military.war.peace", text, IconButton.SMALL,
			"打开议和窗口")
	else:
		_action.text = ""
	_action.get_parent().visible = not text.is_empty()


func _style_action_button() -> void:
	_action.custom_minimum_size = Vector2(96.0, 34.0)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.955, 0.915, 0.825, 0.95)
	normal.border_color = Color(UITokens.DOSSIER_OXBLOOD, 0.65)
	normal.set_border_width_all(1)
	normal.border_width_bottom = 2
	normal.set_corner_radius_all(4)
	normal.content_margin_left = 10
	normal.content_margin_right = 10
	normal.content_margin_top = 4
	normal.content_margin_bottom = 4
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.985, 0.95, 0.875, 1.0)
	hover.border_color = UITokens.DOSSIER_OXBLOOD
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.90, 0.82, 0.69, 1.0)
	_action.add_theme_stylebox_override("normal", normal)
	_action.add_theme_stylebox_override("hover", hover)
	_action.add_theme_stylebox_override("pressed", pressed)
	_action.add_theme_stylebox_override("focus", hover)
	_action.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	_action.add_theme_color_override("font_hover_color", UITokens.DOSSIER_OXBLOOD)
	_action.add_theme_color_override("font_pressed_color", UITokens.DOSSIER_INK)
	UIAnimation.bind_tactile_button(_action)


## Board type scale: the score reads at the same size as a dossier value, never
## larger than the card's own heading.
func set_type_scale(value_px: int) -> void:
	var size := maxi(UITokens.FONT_SMALL, value_px)
	_score.add_theme_font_size_override("font_size", size)
	_title.add_theme_font_size_override("font_size", size + 2)


func set_data(data: Dictionary) -> void:
	war_id = int(data.get("id", 0))
	_title.text = "对%s" % String(data.get("enemy_name", "敌国"))
	_role.text = String(data.get("role", ""))
	_days.text = "已战 %d 日" % int(data.get("days", 0))
	var score := float(data.get("score", 0.0))
	_score.text = String(data.get("score_text", ""))
	_score.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if score >= 0.0 else UITokens.DOSSIER_OXBLOOD)
	var losses := String(data.get("losses_text", ""))
	if bool(data.get("fully_occupied", false)):
		losses = ("%s · 对方全境沦陷" % losses) if not losses.is_empty() else "对方全境沦陷"
	_losses.text = losses
	var parts: Array = data.get("score_parts", [])
	_parts.visible = not parts.is_empty()
	_parts.set_rows(parts)
	tooltip_text = "对方全境沦陷：接受和议的意愿大幅提高。" if bool(
		data.get("fully_occupied", false)) else ""
