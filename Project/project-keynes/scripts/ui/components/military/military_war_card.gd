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
	_action.pressed.connect(func() -> void: action_requested.emit(war_id))


func set_action(text: String) -> void:
	_action.text = text
	_action.get_parent().visible = not text.is_empty()


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
	_score.text = String(data.get("score_text", "0"))
	_score.add_theme_color_override("font_color",
		UITokens.DOSSIER_VERDIGRIS if score >= 0.0 else UITokens.DOSSIER_OXBLOOD)
	_losses.text = String(data.get("losses_text", ""))
	var parts: Array = data.get("score_parts", [])
	_parts.visible = not parts.is_empty()
	_parts.set_rows(parts)
	tooltip_text = "对方全境沦陷：接受和议的意愿大幅提高。" if bool(
		data.get("fully_occupied", false)) else ""
