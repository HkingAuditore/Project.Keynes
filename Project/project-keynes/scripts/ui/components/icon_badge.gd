extends Control
class_name IconBadge

# 保留旧调用签名；玩家界面统一使用纸贴位图。
const FAMILY_FONT_AWESOME := IconCatalog.FAMILY_FONT_AWESOME
const FAMILY_LUCIDE := IconCatalog.FAMILY_LUCIDE
const FAMILY_TABLER := IconCatalog.FAMILY_TABLER

var icon_key := &""
var accent: Color = UITokens.ACCENT

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_semantic(semantic_key: StringName, p_accent: Color = UITokens.ACCENT) -> void:
	accent = p_accent
	icon_key = IconCatalog.resolve_semantic(semantic_key)
	visible = icon_key != &""
	queue_redraw()

func set_icon(icon: String, p_accent: Color = UITokens.ACCENT, _legacy_family = null) -> void:
	set_semantic(StringName(icon), p_accent)

func _draw() -> void:
	IconCatalog.draw_icon(self, icon_key, Rect2(Vector2.ZERO, size).grow(-minf(size.x, size.y) * 0.04))

static func normalize_icon(icon: String) -> String:
	return IconCatalog.resolve_key(icon)

static func glyph_for_key(_key: String) -> String:
	return ""

static func texture_for_key(key: String, _legacy_family = null) -> Texture2D:
	return IconCatalog.texture_for_key(StringName(key))

static func apply_to_button(button: Button, icon: String, font_size: int = 16) -> void:
	IconButton.apply(button, StringName(icon), font_size)
