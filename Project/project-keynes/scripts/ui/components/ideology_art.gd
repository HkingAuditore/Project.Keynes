class_name IdeologyArt
extends RefCounted

## Layered paper materials and palette for the ideology workspace. V3 paper
## and transparent edition edges compose with the existing school illustrations.

const ROOT := "res://assets/ui/ideology_v2/"
const LEGACY_ROOT := "res://assets/ui/ideology_v1/"
const RARITY_FRAMES := {
	1: ROOT + "frame_common.png",
	2: ROOT + "frame_rare.png",
	3: ROOT + "frame_legendary.png",
}
const LEGACY_RARITY_FRAMES := {
	1: LEGACY_ROOT + "card_frame_common.png",
	2: LEGACY_ROOT + "card_frame_rare.png",
	3: LEGACY_ROOT + "card_frame_legendary.png",
}
const SCHOOL_SIGILS := {
	"agrarian": ROOT + "school_agrarian.png",
	"commerce": ROOT + "school_commerce.png",
	"learning": ROOT + "school_learning.png",
	"mobilization": ROOT + "school_mobilization.png",
	"industry": ROOT + "school_industry.png",
	"harmony": ROOT + "school_harmony.png",
}
const CARD_BACK := ROOT + "card_back_v2.png"
const LEGACY_CARD_BACK := LEGACY_ROOT + "card_back.png"
const ARCHIVE_INDEX := ROOT + "archive_index_v2.png"
const SLOT_NICHE := LEGACY_ROOT + "slot_niche.png"
const SPIRIT_NICHE := LEGACY_ROOT + "spirit_niche.png"
const WAX_SEAL := "decoration.wax_seal"
const SCROLL_BAR := LEGACY_ROOT + "scroll_bar.png"
const INK_SPLASH := ROOT + "fx_ink_stroke.png"
const INK_RING := ROOT + "fx_ink_ring.png"
const PAPER_CONFETTI := ROOT + "fx_paper_burst.png"
const PAPER_BURST := ROOT + "fx_paper_burst.png"
const SUN_BURST := ROOT + "fx_sun_burst.png"
const RIBBON_SWEEP := ROOT + "fx_ribbon_sweep.png"
const RED_SEAL := ROOT + "fx_red_seal.png"
const STAGE_DESK := ROOT + "stage_archive_desk_soft.png"
## A quietly varnished cabinet board for the equipped-roads column. Generated
## from the same watercolour papercut set as the cards; no borrowed UI art.
const CABINET_PANEL := ROOT + "cabinet_panel_v2.png"
## Landscape archive-card frame used only by collection entries. Keeping it
## separate from the portrait offer frame preserves both silhouettes instead of
## stretching ornate corners to fit a wide row.
const COLLECTION_CARD_FRAME := ROOT + "collection_card_frame_v2.png"
const COLLECTION_RARITY_FRAMES := {
	1: COLLECTION_CARD_FRAME,
	2: ROOT + "collection_card_frame_rare_v2.png",
	3: ROOT + "collection_card_frame_legendary_v2.png",
}
## Per-side source margins for the stretchable paper frames. The ornate corner
## clusters stay fixed while the braided rails and paper field stretch.
const FRAME_MARGINS := {
	1: 86,
	2: 104,
	3: 122,
}
const SCHOOL_ORDER := ["agrarian", "commerce", "learning", "mobilization",
	"industry", "harmony"]
const SCHOOL_NAMES := {
	"agrarian": "农本", "commerce": "商贸", "learning": "学识",
	"mobilization": "动员", "industry": "工造", "harmony": "调和",
}
const SCHOOL_ICONS := {
	"agrarian": &"good.grain", "commerce": &"hud.country.economy",
	"learning": &"hud.country.technology", "mobilization": &"family.workspace.people",
	"industry": &"economy.building.factory", "harmony": &"hud.country.diplomacy",
}
## Ink tones per school, used for pips, link threads and tab underlines.
const SCHOOL_COLORS := {
	"agrarian": Color(0.66, 0.50, 0.16),
	"commerce": Color(0.20, 0.42, 0.52),
	"learning": Color(0.24, 0.36, 0.30),
	"mobilization": Color(0.62, 0.17, 0.12),
	"industry": Color(0.34, 0.31, 0.29),
	"harmony": Color(0.27, 0.50, 0.42),
}
const RARITY_COLORS := {
	1: Color(0.36, 0.27, 0.18),
	2: Color(0.18, 0.44, 0.42),
	3: Color(0.70, 0.20, 0.12),
}
const RARITY_LABELS := {1: "寻常", 2: "珍稀", 3: "传世"}
const RARITY_NAMES := {1: "寻常", 2: "珍稀", 3: "传世"}
const RARITY_TAGS := {1: "通行", 2: "稀见", 3: "传世"}
const RARITY_ACCENTS := {
	1: Color(0.30, 0.24, 0.17),
	2: Color(0.13, 0.38, 0.36),
	3: Color(0.62, 0.18, 0.10),
}
const RARITY_GLOWS := {
	1: Color(0.88, 0.79, 0.59, 0.20),
	2: Color(0.30, 0.67, 0.59, 0.34),
	3: Color(0.92, 0.55, 0.20, 0.52),
}
const VERMILION := Color(0.66, 0.15, 0.09)
const GOLD_LEAF := Color(0.86, 0.67, 0.30)
const INK := Color(0.12, 0.07, 0.035)
const INK_MUTED := Color(0.31, 0.22, 0.14)
const PAPER := Color(0.95, 0.90, 0.78)
const PAPER_SHEET := "res://assets/ui/ideology_paper_v3/ivory_sheet.png"
const PAPER_REGION := Rect2(8, 16, 496, 309)
const PAPER_SHADOW = preload("res://shaders/ui/ideology_paper_shadow.gdshader")
const EDITION_EDGES := {
	2: "res://assets/ui/ideology_paper_v3/edge_jade.png",
	3: "res://assets/ui/ideology_paper_v3/edge_cinnabar_gold.png",
}

static var _cache := {}
static var _active_detail: WeakRef


static func paper_texture() -> Texture2D:
	if not _cache.has("paper_region"):
		var sheet := AtlasTexture.new()
		sheet.atlas = texture(PAPER_SHEET)
		sheet.region = PAPER_REGION
		_cache["paper_region"] = sheet
	return _cache["paper_region"]


static func edition_style(rarity: int) -> StyleBoxTexture:
	if rarity < 2:
		return null
	var style := StyleBoxTexture.new()
	style.texture = texture(String(EDITION_EDGES[clampi(rarity, 2, 3)]))
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_texture_margin(side, 48.0)
	return style


static func paper_tint(rarity: int) -> Color:
	return Color(0.975, 1.0, 0.985) if rarity == 2 else \
		Color(1.0, 0.975, 0.92) if rarity >= 3 else Color.WHITE


## Material only: the engine owns shadows, tabs, icons, text and motion.
static func paper_style(inset := 14.0, tint := Color.WHITE) -> StyleBoxTexture:
	var style := StyleBoxTexture.new()
	# 九切片直接取原图区域，避免 AtlasTexture 的偏移再次参与边缘采样。
	style.texture = texture(PAPER_SHEET)
	style.region_rect = PAPER_REGION
	style.axis_stretch_horizontal = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	style.axis_stretch_vertical = StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
	style.modulate_color = tint
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_texture_margin(side, 12.0)
		style.set_content_margin(side, inset)
	return style


static func attach_paper_shadow(surface: Control, opacity := 0.19, inset := 0.0) -> Control:
	var shadow := ColorRect.new()
	shadow.name = "SoftPaperShadow"
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.show_behind_parent = true
	var material := ShaderMaterial.new()
	material.shader = PAPER_SHADOW
	material.set_shader_parameter("shadow_color", Color(0.12, 0.08, 0.045, opacity))
	shadow.material = material
	surface.add_child(shadow)
	shadow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shadow.offset_left = -24 - inset
	shadow.offset_top = -24 - inset
	shadow.offset_right = 24 + inset
	shadow.offset_bottom = 24 + inset
	shadow.resized.connect(func() -> void:
		material.set_shader_parameter("canvas_size", shadow.size))
	material.set_shader_parameter("canvas_size", shadow.size)
	return shadow


## Containers own their children's bounds. A plain host lets the blur extend
## beyond those bounds while compensating for the panel's content padding.
static func attach_panel_shadow(panel: PanelContainer, opacity := 0.24,
		inset := 0.0) -> Control:
	var host := Control.new()
	host.name = "PaperShadowHost"
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.show_behind_parent = true
	panel.add_child(host)
	return attach_paper_shadow(host, opacity, inset)


static func detail_tooltip(text: String, details: Dictionary = {}) -> Control:
	if not details.is_empty():
		var tooltip := (load("res://scripts/ui/components/ideology_detail_tooltip.gd") as GDScript).new() as Control
		tooltip.call("setup", details)
		_active_detail = weakref(tooltip)
		return tooltip
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_theme_stylebox_override("panel", paper_style(18.0))
	var copy := label(text, 15, INK, HORIZONTAL_ALIGNMENT_LEFT)
	copy.custom_minimum_size.x = 390.0
	copy.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(copy)
	return panel


static func scroll_detail(event: InputEvent) -> bool:
	if not event is InputEventMouseButton or not event.pressed or _active_detail == null:
		return false
	if event.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return false
	var tooltip = _active_detail.get_ref()
	if tooltip == null or not tooltip.is_visible_in_tree():
		return false
	tooltip.scroll_by(-64 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 64)
	return true


static func texture(path: String) -> Texture2D:
	if path == WAX_SEAL:
		return IconCatalog.texture_for_key(&"decoration.wax_seal")
	if _cache.has(path):
		return _cache[path]
	var loaded: Texture2D = null
	if ResourceLoader.exists(path):
		loaded = load(path) as Texture2D
	_cache[path] = loaded
	return loaded


static func frame_for(_rarity: int) -> Texture2D:
	return paper_texture()


static func card_back() -> Texture2D:
	var authored := texture(CARD_BACK)
	return authored if authored != null else texture(LEGACY_CARD_BACK)


static func frame_margin_for(rarity: int) -> int:
	return int(FRAME_MARGINS.get(clampi(rarity, 1, 3), 64))


static func collection_frame_for(_rarity: int) -> Texture2D:
	return paper_texture()


static func emblem_for(school_id: String) -> Texture2D:
	if school_id.is_empty():
		return null
	var sigil := texture(String(SCHOOL_SIGILS.get(school_id, "")))
	if sigil != null:
		return sigil
	return IconCatalog.texture_for_key(SCHOOL_ICONS.get(school_id, &"system.unknown"))


static func school_color(school_id: String) -> Color:
	return SCHOOL_COLORS.get(school_id, INK_MUTED)


static func school_name(school_id: String) -> String:
	return String(SCHOOL_NAMES.get(school_id, school_id))


static func label(text: String, size: int, color: Color,
		align := HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var node := Label.new()
	node.text = text
	node.horizontal_alignment = align
	node.add_theme_font_size_override("font_size", maxi(UITokens.FONT_SMALL, size))
	node.add_theme_font_override("font", UITokens.dossier_font("sans"))
	node.add_theme_color_override("font_color", color)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func nine_patch(tex: Texture2D, margin: int) -> NinePatchRect:
	var patch := NinePatchRect.new()
	patch.texture = tex
	patch.patch_margin_left = margin
	patch.patch_margin_right = margin
	patch.patch_margin_top = margin
	patch.patch_margin_bottom = margin
	patch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	patch.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return patch


static func q16(value: int) -> String:
	return "%.2f" % (float(value) / 65536.0)


static func rarity_accent(rarity: int) -> Color:
	return RARITY_ACCENTS.get(clampi(rarity, 1, 3), INK_MUTED)


static func rarity_glow(rarity: int) -> Color:
	return RARITY_GLOWS.get(clampi(rarity, 1, 3), RARITY_GLOWS[1])
