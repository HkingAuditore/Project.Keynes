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
const ANIM_DISCLOSURE := 0.14
const TECH_PAGE_REVEAL := 0.52
const TECH_FOCUS_SECONDS := 0.65
const TECH_DISCOVERY_SECONDS := 0.9
const TECH_BREAKTHROUGH_SECONDS := 1.25
const TECH_FLOW_SECONDS := 2.8
const TECH_EFFECT_FPS := 30.0
const TECH_EFFECT_BRASS := Color(0.88, 0.68, 0.34, 1.0)
const TECH_EFFECT_LIGHT := Color(1.0, 0.93, 0.71, 1.0)
const MENU_PREVIEW_DEBOUNCE := 0.18
const MENU_PARALLAX_MAX := 12.0
const MENU_PAGE_TRANSITION := 0.30
const LOADING_MAIN_SLICE_USEC := 4000

# 地图活动：开拓的仪式感与日常发展使用不同的密度预算（墙钟秒）。
const MAP_COLONY_DURATION := 2.8
const MAP_GROWTH_DURATION := 1.8
const MAP_BUILD_DURATION := 2.2
const MAP_ACTIVITY_INTERVAL := 0.65
const MAP_ACTIVITY_MIN_ZOOM := 0.35
const MAP_ACTIVITY_TEXT_ZOOM := 0.9
const MAP_GROWTH_COOLDOWN := 9.0
const MAP_BUILD_COOLDOWN := 5.0
const MAP_ACTIVITY_GOLD := Color(0.96, 0.76, 0.39, 1.0)
const MAP_ACTIVITY_GREEN := Color(0.65, 0.82, 0.50, 1.0)

# 贸易载具：固定 GPU 容量与墙钟节流，不随模拟倍速增加工作量。
const TRADE_ROUTE_CAP := 32
const TRADE_VEHICLE_CAP := 96
const TRADE_LOW_ROUTE_CAP := 12
const TRADE_LOW_VEHICLE_CAP := 24
const TRADE_REFRESH_SECONDS := 0.5
const TRADE_LOW_REFRESH_SECONDS := 1.0
const TRADE_FADE_SECONDS := 2.0
const TRADE_MIN_ZOOM := 0.35
const TRADE_FULL_ZOOM := 0.55
const TRADE_VEHICLE_WORLD_SIZE := 25.0
const TRADE_VEHICLE_SCREEN_CAP := 36.0
const TRADE_SPEED := 11.0
const TRADE_SHADOW_STRENGTH := 0.32
const TRADE_SHADOW_COLOR := Color(0.11, 0.13, 0.17, 1.0)
const TRADE_VEHICLE_HEIGHT := 3.0
const TRADE_SHADOW_MAX_LENGTH := 15.0

const FAMILY_FOUNDING_WIDTH := 480.0
const FAMILY_FOUNDING_WIDE_WIDTH := 520.0
const FAMILY_FOUNDING_COLLAPSED_WIDTH := 320.0
const FAMILY_FOUNDING_MAP_GAP := 240.0

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
# Ordinary object details fold below their compact breakpoint. Family details
# retain the tile directory and adapt their own chapters to the allocated width.
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

# 材质透明留白只用于绘制投影，不参与布局或点击区域。
const ARCHIVE_EDGE_INSET := 16.0
const ARCHIVE_SHADOW_SIZE := 18.0
const ARCHIVE_SHADOW_OFFSET := Vector2(0.0, 5.0)
const HUD_SHADOW_SIZE := 12.0
const HUD_SHADOW_OFFSET := Vector2(0.0, 3.0)
const ARCHIVE_BUTTON_HOVER := Color(1.06, 1.04, 0.98, 1.0)
const ARCHIVE_BUTTON_DISABLED := Color(0.78, 0.75, 0.68, 0.74)

# 辅助纸片比主档案框轻：只留纤维边和接触阴影。
const PAPER_NOTE_PAD_X := 12.0
const PAPER_NOTE_PAD_Y := 8.0
const PAPER_NOTE_LINE_GAP := 6.0

# Hybrid Atlas-Dossier HUD & ornament tokens (walnut + burnished brass + oxblood).
const HUD_WALNUT_BG := Color(0.082, 0.058, 0.038, 0.98)
const HUD_WALNUT_INSET := Color(0.135, 0.095, 0.058, 0.98)
const HUD_BRASS_BORDER := Color(0.74, 0.52, 0.27, 0.95)
const HUD_BRASS_GLOW := Color(0.95, 0.76, 0.40, 1.0)
const HUD_OXBLOOD_ACTIVE := Color(0.48, 0.17, 0.10, 1.0)
const DOSSIER_BADGE_BG := Color(0.94, 0.88, 0.74, 0.92)
const DOSSIER_BADGE_POSITIVE := Color(0.24, 0.46, 0.40, 0.16)
const DOSSIER_BADGE_NEGATIVE := Color(0.55, 0.19, 0.13, 0.15)

# Dossier palette shared by the country-affairs shell, the national economy
# dossier and the family archive. Semantic tones are for lines, ticks and
# glyphs only; large fills stay on paper so the page reads like a ledger.
const DOSSIER_PAPER := Color(0.955, 0.915, 0.80, 1.0)
const DOSSIER_PAPER_DEEP := Color(0.90, 0.835, 0.69, 1.0)
const DOSSIER_PAPER_SHADE := Color(0.36, 0.25, 0.13, 0.07)
const DOSSIER_INK := Color(0.12, 0.075, 0.04, 1.0)
const DOSSIER_INK_SOFT := Color(0.27, 0.19, 0.12, 1.0)
const DOSSIER_INK_MUTED := Color(0.40, 0.31, 0.22, 0.92)
const DOSSIER_RULE := Color(0.42, 0.29, 0.16, 0.38)
const DOSSIER_RULE_STRONG := Color(0.48, 0.16, 0.10, 0.70)
const DOSSIER_TRACK := Color(0.40, 0.29, 0.17, 0.15)
const DOSSIER_HOVER := Color(0.69, 0.49, 0.24, 0.13)
const DOSSIER_SELECTED := Color(0.48, 0.16, 0.10, 0.10)
const DOSSIER_OXBLOOD := Color(0.55, 0.19, 0.13, 1.0)
const DOSSIER_BRASS := Color(0.69, 0.49, 0.24, 1.0)
const DOSSIER_VERDIGRIS := Color(0.24, 0.46, 0.40, 1.0)
const DOSSIER_SLATE := Color(0.31, 0.43, 0.53, 1.0)
const DOSSIER_UMBER := Color(0.47, 0.37, 0.27, 1.0)
const DOSSIER_SERIF: FontFile = preload("res://assets/fonts/source_han_serif/SourceHanSerifCN-Regular.otf")

# Formal HUD archival medallion & plaque tokens (unified with Dossier/Archive popups).
const HUD_LEATHER_BG := Color(0.165, 0.108, 0.070, 0.96)
const HUD_PARCMENT_SURFACE := Color(0.945, 0.885, 0.755, 0.96)
const HUD_PARCMENT_HOVER := Color(0.99, 0.945, 0.83, 0.99)
const HUD_INK := Color(0.14, 0.082, 0.042, 1.0)
const HUD_INK_MUTED := Color(0.38, 0.29, 0.20, 0.88)
const HUD_ACTIVE_TEXT := Color(0.99, 0.93, 0.78, 1.0)

# Papercut Atlas & Classical Tome palette for Main Menu, New Game Workbench, and Loading Atlas.
const PAPERCUT_SEA_ABYSS := Color(0.115, 0.165, 0.185, 1.0)
const PAPERCUT_SEA_DEEP := Color(0.155, 0.225, 0.245, 1.0)
const PAPERCUT_SEA_MID := Color(0.215, 0.305, 0.315, 1.0)
const PAPERCUT_SEA_SHALLOW := Color(0.315, 0.425, 0.405, 1.0)
const PAPERCUT_COAST_FOAM := Color(0.84, 0.79, 0.66, 0.78)
const PAPERCUT_LAND_PLAIN := Color(0.76, 0.71, 0.56, 1.0)
const PAPERCUT_LAND_LUSH := Color(0.54, 0.61, 0.45, 1.0)
const PAPERCUT_LAND_ARID := Color(0.81, 0.69, 0.49, 1.0)
const PAPERCUT_LAND_HIGHLAND := Color(0.66, 0.55, 0.41, 1.0)
const PAPERCUT_LAND_MOUNTAIN := Color(0.52, 0.42, 0.32, 1.0)
const PAPERCUT_LAND_PEAK := Color(0.93, 0.89, 0.80, 1.0)
const PAPERCUT_EDGE_CREAM := Color(0.97, 0.93, 0.83, 0.88)
const PAPERCUT_EDGE_BRASS := Color(0.84, 0.66, 0.36, 0.85)
const PAPERCUT_SHADOW := Color(0.04, 0.03, 0.02, 0.42)
const PAPERCUT_SEAL_RED := Color(0.58, 0.17, 0.11, 1.0)
const PAPERCUT_SEAL_GOLD := Color(0.95, 0.84, 0.58, 1.0)

static var _dossier_fonts: Dictionary = {}


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


## Cached fonts for self-drawn dossier charts: "sans", "sans_strong", "serif".
static func dossier_font(kind: String) -> Font:
	if _dossier_fonts.has(kind):
		return _dossier_fonts[kind]
	var font: FontVariation
	match kind:
		"serif":
			font = FontVariation.new()
			font.base_font = DOSSIER_SERIF
			font.variation_embolden = 0.7
		"sans_strong":
			font = font_with_weight(760)
		_:
			font = font_with_weight(560)
	_dossier_fonts[kind] = font
	return font
