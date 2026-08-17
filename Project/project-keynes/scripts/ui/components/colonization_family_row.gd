extends Button
class_name ColonizationFamilyRow

var _icon: IconBadge
var _name: Label
var _badges: BadgeRow
var _effect: Label
var _population: Label
var _family_name := ""


func _ready() -> void:
	if _name != null:
		return
	_icon = get_node("Margin/Line/Icon") as IconBadge
	_name = get_node("Margin/Line/Info/Name") as Label
	_badges = get_node("Margin/Line/Info/Badges") as BadgeRow
	_effect = get_node("Margin/Line/Info/Effect") as Label
	_population = get_node("Margin/Line/Population") as Label
	toggle_mode = true
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_population.add_theme_font_override("font", UITokens.font_with_weight(650))
	_population.add_theme_font_size_override("font_size", UITokens.FONT_VALUE)
	_population.add_theme_color_override("font_color", UITokens.BRASS_HIGHLIGHT)


func set_row(data: Dictionary) -> void:
	if _name == null:
		_ready()
	var accent: Color = data.get("accent", UITokens.ACCENT)
	_icon.set_semantic(StringName(data.get("icon", "family.house")), accent)
	_family_name = String(data.get("name", "家族"))
	_name.text = _family_name
	var badges: Array = data.get("badges", [])
	_badges.visible = not badges.is_empty()
	_badges.mouse_filter = Control.MOUSE_FILTER_PASS
	_badges.set_badges(badges)
	var effect := String(data.get("effect", "")).strip_edges()
	_effect.text = effect
	_effect.visible = not effect.is_empty()
	_population.text = UITokens.format_compact_number_cn(
		float(data.get("population", 0)), 0)
	tooltip_text = String(data.get("tooltip", ""))


func display_name() -> String:
	return _family_name
