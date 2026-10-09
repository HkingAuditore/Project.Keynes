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

# Family dossier palette.  These tones are scoped by the family workspace theme;
# keeping them here prevents feature code from scattering one-off parchment colors.
const FAMILY_PAPER := Color(0.93, 0.87, 0.73, 1.0)
const FAMILY_PAPER_SOFT := Color(0.97, 0.93, 0.82, 0.82)
const FAMILY_INK := Color(0.14, 0.105, 0.075, 1.0)
const FAMILY_INK_MUTED := Color(0.34, 0.27, 0.20, 1.0)
const FAMILY_OXBLOOD := Color(0.51, 0.23, 0.17, 1.0)
const FAMILY_BRASS := Color(0.69, 0.49, 0.24, 1.0)
const FAMILY_GREEN := Color(0.34, 0.48, 0.31, 1.0)
const FAMILY_BLUE := Color(0.31, 0.43, 0.53, 1.0)

# Formal player-session archive surfaces. Keep these separate from the legacy
# dark theme used by the development menu and GM tooling.
const ARCHIVE_REFERENCE_SIZE := Vector2i(1600, 960)
# Ordinary tile/object detail keeps the map visible until the narrower drawer
# no longer has room for its dossier column. Family workspaces use the wider
# archival breakpoint because their two-page composition needs more breathing
# room.
const DETAIL_BREAKPOINT_COMPACT := 1180.0
const ARCHIVE_BREAKPOINT_COMPACT := 1280.0
const ARCHIVE_BREAKPOINT_MEDIUM := 1366.0
const ARCHIVE_PAPER := Color(0.93, 0.87, 0.73, 1.0)
const ARCHIVE_PAPER_LIGHT := Color(0.98, 0.94, 0.82, 1.0)
const ARCHIVE_INK := Color(0.12, 0.07, 0.035, 1.0)
const ARCHIVE_INK_MUTED := Color(0.29, 0.20, 0.13, 0.92)
const ARCHIVE_WALNUT := Color(0.09, 0.065, 0.045, 0.97)
const ARCHIVE_OXBLOOD := Color(0.48, 0.16, 0.10, 1.0)
const ARCHIVE_BRASS := Color(0.69, 0.49, 0.24, 1.0)
const ARCHIVE_RULE := Color(0.40, 0.28, 0.16, 0.55)
const ARCHIVE_CONTENT_MARGIN := 16


static func accent_for_key(key: String) -> Color:
	match key:
		"geo", "elevation", "land": return GEO
		"climate", "temp", "sun": return CLIMATE
		"water", "hydrology", "weather": return WATER
		"eco", "vegetation", "vitality": return ECO
		"resource": return RESOURCE
		"risk": return RISK
		"good": return GOOD
		"warn": return WARN
		_: return ACCENT


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


static func font_with_weight(weight: int) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = UI_FONT
	font.variation_opentype = {&"wght": float(clampi(weight, 200, 900))}
	return font
