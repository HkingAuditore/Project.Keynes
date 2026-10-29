extends RefCounted
class_name UITokens

# 顶部时代纸徽：半藏在视口外，交互时下滑；晋升只播放一次。
const ERA_BADGE_SIZE := 220.0
const ERA_BADGE_REST_Y := -110.0
const ERA_BADGE_OPEN_Y := 10.0
const ERA_BADGE_HOVER_Y := -82.0
const ERA_BADGE_HOVER_SCALE := 1.045
const ERA_BADGE_SLIDE_SECONDS := 0.20
const ERA_BADGE_HOVER_SECONDS := 0.13
const ERA_POPUP_WIDTH := 580.0
const ERA_POPUP_GAP := 8.0
const ERA_BADGE_ADVANCE_SECONDS := 2.8
const ERA_BADGE_GOLD := Color(1.0, 0.79, 0.30)

const UI_FONT: FontFile = preload("res://assets/fonts/swei/SweiGothicLegCJKsc-Regular.ttf")
const UI_FONT_BOLD: FontFile = preload("res://assets/fonts/swei/SweiGothicLegCJKsc-Bold.ttf")
const UI_DISPLAY_FONT: Font = preload("res://assets/fonts/muyao/display_handwritten.tres")
const CHRONICLE_SERIF: FontFile = preload("res://assets/fonts/source_han_serif/SourceHanSerifCN-Regular.otf")
const CHRONICLE_INK := Color(0.19, 0.15, 0.12)
const CHRONICLE_MUTED := Color(0.39, 0.32, 0.25)
const CHRONICLE_PAPER := Color(0.94, 0.89, 0.78)
const CHRONICLE_RED := Color(0.46, 0.16, 0.13)
const CHRONICLE_BRASS := Color(0.65, 0.44, 0.18)
const CHRONICLE_RULE := Color(0.36, 0.25, 0.13, 0.22)
const CHRONICLE_LIGHT_INK := Color(0.96, 0.91, 0.80)
const CHRONICLE_LIGHT_MUTED := Color(0.74, 0.72, 0.62)
const CHRONICLE_PENCIL_BLUE := Color(0.25, 0.43, 0.58)
const CHRONICLE_PENCIL_GREEN := Color(0.31, 0.47, 0.25)
const CHRONICLE_PENCIL_GOLD := Color(0.78, 0.55, 0.16)
const CHRONICLE_PENCIL_RED := Color(0.72, 0.19, 0.16)
const CHRONICLE_BODY_SIZE := 18
const CHRONICLE_NOTE_SIZE := 14
const CHRONICLE_CHAPTER_SECONDS := 0.15
const CHRONICLE_OPEN_SECONDS := 0.40

# ── 年度报告「纸本长卷」字阶 ───────────────────────────────────────────────
# 旧版最大字号 36px，与 14px 注释只差 2.6 倍；纸本编辑风需要 8–12 倍的尺度对比，
# 否则封面永远没有气势。display 级一律走真正的 SemiBold 字重，不再用伪粗。
const CHRONICLE_DISPLAY_MAX := 168
const CHRONICLE_DISPLAY_COVER := 132
const CHRONICLE_DISPLAY_COVER_WIDE := 156
const CHRONICLE_DISPLAY_COVER_SMALL := 88
const CHRONICLE_NUMERAL_XL := 96
const CHRONICLE_NUMERAL_LG := 56
const CHRONICLE_NUMERAL_MD := 40
const CHRONICLE_H1 := 48
const CHRONICLE_LEAD := 19
const CHRONICLE_LABEL := 13
const CHRONICLE_LEADING_BODY := 8
const CHRONICLE_LEADING_LEAD := 14

# 纸面与墨色（比 CHRONICLE_PAPER 更亮一档，用于全幅纸场）
const CHRONICLE_SHEET_LIGHT := Color(0.965, 0.925, 0.835)
const CHRONICLE_SHEET_DEEP := Color(0.905, 0.845, 0.720)
const CHRONICLE_SHEET_EDGE := Color(0.855, 0.780, 0.640)

# 展示级衬线：与现有 SourceHanSerifCN-Regular 同族（Noto Serif CJK = 思源宋体），
# 只为拿到真正的 SemiBold 笔画，避免 132px 伪粗糊成一团。
const ANNUAL_DISPLAY_SERIF: FontFile = preload("res://assets/fonts/noto_serif_sc/NotoSerifSC-SemiBold.otf")
const ANNUAL_PENCIL_DISPLAY: FontFile = preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf")
const ANNUAL_PENCIL_BODY: FontFile = preload("res://assets/fonts/annual_pencil/PFanHuTuTi_Min.ttf")

static var _annual_fonts: Dictionary = {}


## 年度报告字体族。kind ∈ display / display_soft / numeral / label / body / body_soft。
static func annual_font(kind: String) -> Font:
	if _annual_fonts.has(kind):
		return _annual_fonts[kind]
	var font: Font
	match kind:
		"display":
			font = ANNUAL_PENCIL_DISPLAY
		"display_soft":
			var soft := FontVariation.new()
			soft.base_font = ANNUAL_PENCIL_BODY
			soft.variation_embolden = 0.08
			font = soft
		"numeral":
			var numeral := FontVariation.new()
			numeral.base_font = ANNUAL_PENCIL_DISPLAY
			numeral.spacing_glyph = 0
			font = numeral
		"label":
			var label := FontVariation.new()
			label.base_font = ANNUAL_PENCIL_BODY
			label.variation_embolden = 0.12
			label.spacing_glyph = 0.6
			font = label
		"body_soft":
			var body_soft := FontVariation.new()
			body_soft.base_font = ANNUAL_PENCIL_BODY
			body_soft.variation_embolden = 0.02
			font = body_soft
		_:
			var body := FontVariation.new()
			body.base_font = ANNUAL_PENCIL_BODY
			body.variation_embolden = 0.06
			font = body
	_annual_fonts[kind] = font
	return font


## 无底文本链：常态完全透明（纸本编辑风不允许按钮盒），只有底部朱红细线随焦点出现。
static func chronicle_link_style(state: String) -> StyleBox:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0, 0, 0, 0)
	box.content_margin_left = 2
	box.content_margin_right = 2
	box.content_margin_top = 4
	box.content_margin_bottom = 4
	if state == "focus":
		box.border_width_bottom = 2
		box.border_color = CHRONICLE_RED
	return box


static func chronicle_button_style(state: String, rail: bool = false) -> StyleBox:
	if state == "focus":
		var focus := StyleBoxFlat.new()
		focus.bg_color = Color(0, 0, 0, 0)
		focus.set_border_width_all(2)
		focus.border_color = CHRONICLE_RED
		return focus
	if rail:
		var ink := StyleBoxFlat.new()
		ink.bg_color = Color(0, 0, 0, 0)
		ink.content_margin_left = 12
		ink.content_margin_right = 12
		ink.content_margin_top = 6
		ink.content_margin_bottom = 6
		if state in ["pressed", "focus", "hover"]:
			ink.border_width_left = 3 if state == "pressed" else 1
			ink.border_color = CHRONICLE_RED if state != "hover" else CHRONICLE_RULE
		return ink
	var paper := StyleBoxTexture.new()
	paper.texture = preload("res://assets/ui/archive_material_v1/button_pressed_v1.tres") if state == "pressed" else preload("res://assets/ui/archive_material_v1/button_normal_v1.tres")
	paper.texture_margin_left = 12
	paper.texture_margin_right = 12
	paper.texture_margin_top = 12
	paper.texture_margin_bottom = 12
	paper.content_margin_left = 14
	paper.content_margin_right = 14
	paper.content_margin_top = 5
	paper.content_margin_bottom = 5
	if state in ["hover", "focus"]:
		paper.modulate_color = ARCHIVE_BUTTON_HOVER
	elif state == "disabled":
		paper.modulate_color = ARCHIVE_BUTTON_DISABLED
	return paper

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
const IDEOLOGY_HEADING_PLATE := Color(0.18, 0.25, 0.19, 0.93)
const IDEOLOGY_HEADING_INK := Color(0.97, 0.88, 0.68, 1.0)
const IDEOLOGY_HEADING_MUTED := Color(0.84, 0.73, 0.54, 0.90)
const IDEOLOGY_CARD_WELL := Color(0.12, 0.08, 0.045, 0.20)
const IDEOLOGY_LEVEL_TRACK := Color(0.18, 0.10, 0.05, 0.88)
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
# 地块屏幕宽度门控，兼容窗口缩放；不同情况共用位图图集，恒定屏幕尺寸。
const MAP_SITUATION_SHOW_WIDTH := 80.0
const MAP_SITUATION_HIDE_WIDTH := 72.0
# 地块告警图标需要在高分辨率地图上保持可辨识；绘制与命中区域共用此基准尺寸。
const MAP_SITUATION_ICON_SIZE := 36.0
const MAP_SITUATION_REFRESH_SECONDS := 0.25
const MAP_SITUATION_BATCH_CELLS := 128
const MAP_SITUATION_VISIBLE_CAP := 1024
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
const TRADE_SHADOW_HEIGHT_RATIO := 0.12
const TRADE_SHADOW_MAX_LENGTH_RATIO := 0.60
const TRADE_SHADOW_FOOTPRINT := Vector2(0.95, 0.90)
const TRADE_SHADOW_EDGE_SOFTNESS := 0.35
# 图集各格中实际图像的 UV 中心与范围，排除透明留白；与 12 种陆/水外观一一对应。
# 固定美术元数据，只在装配时上传，不在运行时扫描图片。
const TRADE_SHADOW_SHAPES := [
	Vector4(0.513672, 0.552734, 0.707031, 0.425781), # 搬运队
	Vector4(0.500977, 0.548828, 0.873047, 0.464844), # 独木舟
	Vector4(0.516602, 0.458984, 0.826172, 0.535156), # 马车
	Vector4(0.505859, 0.453125, 0.863281, 0.500000), # 木船
	Vector4(0.500977, 0.437500, 0.912109, 0.640625), # 篷车
	Vector4(0.486328, 0.414062, 0.968750, 0.828125), # 帆船
	Vector4(0.494141, 0.429688, 0.890625, 0.640625), # 蒸汽时代货队
	Vector4(0.492188, 0.427734, 0.953125, 0.535156), # 蒸汽船
	Vector4(0.500977, 0.458984, 0.767578, 0.597656), # 早期货车
	Vector4(0.486328, 0.445312, 0.960938, 0.601562), # 机动货船
	Vector4(0.495117, 0.427734, 0.896484, 0.519531), # 现代货车
	Vector4(0.485352, 0.412109, 0.970703, 0.582031), # 货轮

]
# 相对高度：人、车与船各自缩放投影长度，避免小对象继承现代货车的高度。
const TRADE_SHADOW_HEIGHTS := [0.45, 0.20, 0.60, 0.35, 0.75, 0.55, 0.65, 0.65, 0.80, 0.65, 1.0, 0.80]


const FAMILY_FOUNDING_WIDTH := 480.0
const FAMILY_FOUNDING_WIDE_WIDTH := 520.0
const FAMILY_FOUNDING_COLLAPSED_WIDTH := 320.0
const FAMILY_FOUNDING_MAP_GAP := 240.0

# 按屏幕像素设计：Swei 负责阅读与数值，Muyao 负责短标题的手写表现。
const FONT_BODY := 18
const FONT_SMALL := 15
const FONT_SECTION := 20
const FONT_TITLE := 34
const FONT_VALUE := 24
const FONT_HUD_TIME := 21
const ICON_INLINE := 24
const ICON_ACTION := 32
const ICON_HUD := 44

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
	font.base_font = UI_FONT_BOLD if weight >= 600 else UI_FONT
	return font


## 缓存字面：sans/sans_strong/numeral = Swei，serif 为兼容旧调用的 Muyao 标题别名。
static func dossier_font(kind: String) -> Font:
	if _dossier_fonts.has(kind):
		return _dossier_fonts[kind]
	var font: FontVariation
	match kind:
		"serif":
			font = FontVariation.new()
			font.base_font = UI_DISPLAY_FONT
		"numeral":
			font = font_with_weight(650)
		"sans_strong":
			font = font_with_weight(650)
		_:
			font = font_with_weight(500)
	_dossier_fonts[kind] = font
	return font
