extends RefCounted
class_name UITokens

const UI_FONT: FontFile = preload("res://assets/fonts/source_han/SourceHanSansCN-VF.woff2")

const SPACE_XS := 4
const SPACE_SM := 8
const SPACE_MD := 12
const SPACE_LG := 16
const SPACE_XL := 24
const SPACE_XXL := 32

const RADIUS_SM := 4
const RADIUS_MD := 7
const RADIUS_LG := 12

const ANIM_FAST := 0.12
const ANIM_MED := 0.18
const ANIM_SLOW := 0.28

const FONT_BODY := 14
const FONT_SMALL := 12
const FONT_SECTION := 13
const FONT_TITLE := 20
const FONT_VALUE := 18
const FONT_HUD_TIME := 17

const INK_DEEP := Color(0.027, 0.025, 0.022, 0.98)
const INK_PANEL := Color(0.052, 0.047, 0.039, 0.965)
const WALNUT := Color(0.105, 0.076, 0.050, 0.97)
const WALNUT_SOFT := Color(0.145, 0.108, 0.071, 0.94)
const PARCHMENT_BG := Color(0.245, 0.205, 0.150, 0.94)
const PANEL_BG := INK_PANEL
const PANEL_BG_SOFT := Color(0.090, 0.075, 0.057, 0.94)
const CARD_BG := Color(0.105, 0.087, 0.066, 0.96)
const CARD_BG_HOVER := Color(0.135, 0.108, 0.076, 0.98)
const PANEL_BORDER := Color(0.53, 0.41, 0.24, 0.72)
const PANEL_BORDER_SOFT := Color(0.36, 0.29, 0.19, 0.64)
const BRASS_HIGHLIGHT := Color(0.92, 0.72, 0.38, 0.96)
const TEXT_MAIN := Color(0.965, 0.925, 0.825, 1.0)
const TEXT_MUTED := Color(0.78, 0.70, 0.56, 1.0)
const TEXT_FAINT := Color(0.55, 0.49, 0.40, 1.0)
const TEXT_DARK := Color(0.105, 0.082, 0.052, 1.0)
const ACCENT := Color(0.78, 0.57, 0.28, 1.0)
const ACCENT_SOFT := Color(0.27, 0.20, 0.12, 0.90)
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


static func format_compact_number_cn(value: float, decimals: int = 2) -> String:
	var sign := "-" if value < 0.0 else ""
	var abs_value := absf(value)
	if abs_value >= 100000000.0:
		return "%s%s亿" % [sign, _trim_number(abs_value / 100000000.0, decimals)]
	if abs_value >= 10000.0:
		return "%s%s万" % [sign, _trim_number(abs_value / 10000.0, decimals)]
	return "%s%s" % [sign, _trim_number(abs_value, decimals)]


static func _trim_number(value: float, decimals: int) -> String:
	var places := clampi(decimals, 0, 6)
	var text := "%.*f" % [places, value]
	if text.find(".") >= 0:
		while text.ends_with("0"):
			text = text.substr(0, text.length() - 1)
		if text.ends_with("."):
			text = text.substr(0, text.length() - 1)
	return text


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
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.52)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0.0, 4.0)
	style.anti_aliasing = true
	return style


static func inset_panel_style(bg: Color = CARD_BG, accent: Color = PANEL_BORDER_SOFT, radius: int = RADIUS_SM) -> StyleBoxFlat:
	var style := panel_style(bg, radius, accent)
	style.border_width_left = 2
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
	style.shadow_size = 4
	style.shadow_offset = Vector2(0.0, 2.0)
	return style


static func button_style(bg: Color, border: Color, radius: int = RADIUS_SM, pressed: bool = false) -> StyleBoxFlat:
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
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	style.shadow_size = 3 if pressed else 6
	style.shadow_offset = Vector2(0.0, 1.0 if pressed else 2.0)
	style.anti_aliasing = true
	style.anti_aliasing_size = 0.9
	return style


static func font_with_weight(weight: int) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = UI_FONT
	font.variation_opentype = {&"wght": float(clampi(weight, 200, 900))}
	return font


static func make_player_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = UI_FONT
	theme.default_font_size = FONT_BODY
	theme.set_font("font", "Label", UI_FONT)
	theme.set_font("font", "Button", UI_FONT)
	theme.set_font("font", "LineEdit", UI_FONT)
	theme.set_color("font_color", "Label", TEXT_MAIN)
	theme.set_color("font_shadow_color", "Label", Color(0, 0, 0, 0.36))
	theme.set_constant("shadow_offset_x", "Label", 1)
	theme.set_constant("shadow_offset_y", "Label", 1)
	theme.set_font_size("font_size", "Label", FONT_BODY)
	theme.set_font_size("font_size", "Button", FONT_BODY)
	theme.set_stylebox("panel", "PanelContainer", panel_style())
	theme.set_stylebox("normal", "Button", button_style(WALNUT, Color(0.52, 0.39, 0.22, 0.80)))
	theme.set_stylebox("hover", "Button", button_style(WALNUT_SOFT, BRASS_HIGHLIGHT))
	theme.set_stylebox("pressed", "Button", button_style(Color(0.30, 0.205, 0.105, 0.99), BRASS_HIGHLIGHT, RADIUS_SM, true))
	theme.set_stylebox("disabled", "Button", button_style(Color(0.050, 0.046, 0.039, 0.72), Color(0.25, 0.21, 0.15, 0.55)))
	var focus := button_style(Color(0.0, 0.0, 0.0, 0.0), BRASS_HIGHLIGHT)
	focus.border_width_left = 2
	focus.border_width_top = 2
	focus.border_width_right = 2
	focus.border_width_bottom = 2
	focus.shadow_size = 0
	theme.set_stylebox("focus", "Button", focus)
	theme.set_color("font_color", "Button", TEXT_MAIN)
	theme.set_color("font_hover_color", "Button", Color(1.0, 0.94, 0.72, 1.0))
	theme.set_color("font_pressed_color", "Button", TEXT_MAIN)
	theme.set_color("font_disabled_color", "Button", TEXT_FAINT)

	var line_edit := inset_panel_style(Color(0.055, 0.050, 0.043, 0.96), PANEL_BORDER_SOFT)
	line_edit.content_margin_left = SPACE_SM
	line_edit.content_margin_right = SPACE_SM
	theme.set_stylebox("normal", "LineEdit", line_edit)
	theme.set_stylebox("focus", "LineEdit", inset_panel_style(Color(0.070, 0.058, 0.044, 0.98), BRASS_HIGHLIGHT))
	theme.set_color("font_color", "LineEdit", TEXT_MAIN)
	theme.set_color("font_placeholder_color", "LineEdit", TEXT_FAINT)
	theme.set_color("caret_color", "LineEdit", BRASS_HIGHLIGHT)

	var progress_bg := inset_panel_style(Color(0.035, 0.032, 0.028, 0.96), PANEL_BORDER_SOFT, RADIUS_SM)
	progress_bg.content_margin_left = 0
	progress_bg.content_margin_top = 0
	progress_bg.content_margin_right = 0
	progress_bg.content_margin_bottom = 0
	var progress_fill := inset_panel_style(Color(0.55, 0.39, 0.18, 1.0), BRASS_HIGHLIGHT, RADIUS_SM)
	progress_fill.content_margin_left = 0
	progress_fill.content_margin_top = 0
	progress_fill.content_margin_right = 0
	progress_fill.content_margin_bottom = 0
	progress_fill.shadow_size = 0
	theme.set_stylebox("background", "ProgressBar", progress_bg)
	theme.set_stylebox("fill", "ProgressBar", progress_fill)
	theme.set_color("font_color", "ProgressBar", TEXT_MAIN)

	var scroll_bg := StyleBoxFlat.new()
	scroll_bg.bg_color = Color(0.025, 0.023, 0.020, 0.44)
	scroll_bg.corner_radius_top_left = 3
	scroll_bg.corner_radius_top_right = 3
	scroll_bg.corner_radius_bottom_left = 3
	scroll_bg.corner_radius_bottom_right = 3
	var scroll_grabber := StyleBoxFlat.new()
	scroll_grabber.bg_color = Color(0.48, 0.36, 0.21, 0.78)
	scroll_grabber.corner_radius_top_left = 3
	scroll_grabber.corner_radius_top_right = 3
	scroll_grabber.corner_radius_bottom_left = 3
	scroll_grabber.corner_radius_bottom_right = 3
	theme.set_stylebox("scroll", "VScrollBar", scroll_bg)
	theme.set_stylebox("grabber", "VScrollBar", scroll_grabber)
	theme.set_stylebox("grabber_highlight", "VScrollBar", inset_panel_style(WALNUT_SOFT, BRASS_HIGHLIGHT, 3))
	theme.set_stylebox("grabber_pressed", "VScrollBar", inset_panel_style(Color(0.30, 0.20, 0.10, 1.0), BRASS_HIGHLIGHT, 3))
	theme.set_constant("minimum_grab_thickness", "VScrollBar", 7)

	theme.set_stylebox("panel", "TooltipPanel", panel_style(Color(0.035, 0.032, 0.028, 0.985), RADIUS_SM, BRASS_HIGHLIGHT))
	theme.set_color("font_color", "TooltipLabel", TEXT_MAIN)
	theme.set_font("font", "TooltipLabel", UI_FONT)
	theme.set_font_size("font_size", "TooltipLabel", FONT_SMALL)

	var horizontal_rule := StyleBoxLine.new()
	horizontal_rule.color = PANEL_BORDER_SOFT
	horizontal_rule.thickness = 1
	horizontal_rule.vertical = false
	theme.set_stylebox("separator", "HSeparator", horizontal_rule)
	var vertical_rule := StyleBoxLine.new()
	vertical_rule.color = PANEL_BORDER_SOFT
	vertical_rule.thickness = 1
	vertical_rule.vertical = true
	theme.set_stylebox("separator", "VSeparator", vertical_rule)
	return theme
