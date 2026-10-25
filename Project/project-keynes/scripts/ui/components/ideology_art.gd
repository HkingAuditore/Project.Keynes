class_name IdeologyArt
extends RefCounted

## Shared bitmap + palette lookups for the papercut ideology workspace. All
## textures live in res://assets/ui/ideology_v1/ (see its README).

const ROOT := "res://assets/ui/ideology_v1/"
const RARITY_FRAMES := {
	1: ROOT + "card_frame_common.png",
	2: ROOT + "card_frame_rare.png",
	3: ROOT + "card_frame_legendary.png",
}
const CARD_BACK := ROOT + "card_back.png"
const SLOT_NICHE := ROOT + "slot_niche.png"
const SPIRIT_NICHE := ROOT + "spirit_niche.png"
const WAX_SEAL := "decoration.wax_seal"
const SCROLL_BAR := ROOT + "scroll_bar.png"
const INK_SPLASH := ROOT + "ink_splash.png"
const PAPER_CONFETTI := ROOT + "paper_confetti.png"
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
const VERMILION := Color(0.66, 0.15, 0.09)
const GOLD_LEAF := Color(0.86, 0.67, 0.30)
const INK := Color(0.12, 0.07, 0.035)
const INK_MUTED := Color(0.31, 0.22, 0.14)
const PAPER := Color(0.95, 0.90, 0.78)

static var _cache := {}


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


static func frame_for(rarity: int) -> Texture2D:
	return texture(String(RARITY_FRAMES.get(clampi(rarity, 1, 3), RARITY_FRAMES[1])))


static func emblem_for(school_id: String) -> Texture2D:
	if school_id.is_empty():
		return null
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
