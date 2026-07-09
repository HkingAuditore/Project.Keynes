extends RefCounted
class_name UITokens

const SPACE_XS := 4
const SPACE_SM := 8
const SPACE_MD := 12
const SPACE_LG := 16
const SPACE_XL := 24

const RADIUS_SM := 6
const RADIUS_MD := 10
const RADIUS_LG := 16

const ANIM_FAST := 0.12
const ANIM_MED := 0.18
const ANIM_SLOW := 0.28

const PANEL_BG := Color(0.075, 0.060, 0.046, 0.94)
const PANEL_BG_SOFT := Color(0.125, 0.100, 0.074, 0.90)
const CARD_BG := Color(0.155, 0.125, 0.090, 0.92)
const PARCHMENT_BG := Color(0.245, 0.205, 0.150, 0.90)
const PANEL_BORDER := Color(0.56, 0.43, 0.25, 0.58)
const TEXT_MAIN := Color(0.98, 0.94, 0.84, 1.0)
const TEXT_MUTED := Color(0.84, 0.76, 0.60, 1.0)
const TEXT_FAINT := Color(0.62, 0.54, 0.42, 1.0)
const ACCENT := Color(0.78, 0.58, 0.30, 1.0)
const ACCENT_SOFT := Color(0.30, 0.22, 0.13, 0.84)
const GEO := Color(0.68, 0.48, 0.28, 1.0)
const CLIMATE := Color(0.75, 0.43, 0.25, 1.0)
const WATER := Color(0.32, 0.48, 0.62, 1.0)
const ECO := Color(0.37, 0.56, 0.34, 1.0)
const RESOURCE := Color(0.73, 0.59, 0.32, 1.0)
const RISK := Color(0.70, 0.29, 0.22, 1.0)
const GOOD := Color(0.44, 0.62, 0.38, 1.0)
const WARN := Color(0.76, 0.52, 0.25, 1.0)


static func accent_for_key(key: String) -> Color:
	match key:
		"geo", "elevation", "land":
			return GEO
		"climate", "temp", "sun":
			return CLIMATE
		"water", "hydrology", "weather":
			return WATER
		"eco", "vegetation", "vitality":
			return ECO
		"resource":
			return RESOURCE
		"risk":
			return RISK
		"good":
			return GOOD
		"warn":
			return WARN
		_:
			return ACCENT


static func panel_style(bg: Color = PANEL_BG, radius: int = RADIUS_MD, border: Color = PANEL_BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.content_margin_left = SPACE_MD
	style.content_margin_top = SPACE_SM
	style.content_margin_right = SPACE_MD
	style.content_margin_bottom = SPACE_SM
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0.0, 3.0)
	return style


static func button_style(bg: Color, border: Color, radius: int = RADIUS_SM) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.corner_detail = 10
	style.content_margin_left = SPACE_MD
	style.content_margin_right = SPACE_MD
	style.content_margin_top = SPACE_SM
	style.content_margin_bottom = SPACE_SM
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.36)
	style.shadow_size = 5
	style.shadow_offset = Vector2(0.0, 2.0)
	style.anti_aliasing = true
	style.anti_aliasing_size = 0.9
	return style


static func make_player_theme() -> Theme:
	var theme := Theme.new()
	theme.set_color("font_color", "Label", TEXT_MAIN)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.28))
	theme.set_font_size("font_size", "Label", 14)
	theme.set_font_size("font_size", "Button", 14)
	theme.set_stylebox("panel", "PanelContainer", panel_style())
	theme.set_stylebox("normal", "Button", button_style(Color(0.105, 0.078, 0.050, 0.96), Color(0.58, 0.43, 0.22, 0.72)))
	theme.set_stylebox("hover", "Button", button_style(Color(0.155, 0.108, 0.062, 0.98), Color(0.90, 0.68, 0.34, 0.90)))
	theme.set_stylebox("pressed", "Button", button_style(Color(0.31, 0.215, 0.115, 0.98), Color(0.96, 0.74, 0.38, 0.96)))
	theme.set_stylebox("disabled", "Button", button_style(Color(0.065, 0.052, 0.040, 0.62), Color(0.30, 0.23, 0.15, 0.42)))
	theme.set_color("font_color", "Button", TEXT_MAIN)
	theme.set_color("font_hover_color", "Button", Color(1.0, 0.95, 0.78, 1.0))
	theme.set_color("font_pressed_color", "Button", TEXT_MAIN)
	theme.set_color("font_disabled_color", "Button", TEXT_FAINT)
	return theme
