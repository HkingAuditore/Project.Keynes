extends Control
class_name IconBadge


const FA_SOLID_FONT: FontFile = IconCatalog.FONT_AWESOME
# Deprecated compatibility constants. New callers never choose a family.
const FAMILY_FONT_AWESOME := IconCatalog.FAMILY_FONT_AWESOME
const FAMILY_LUCIDE := IconCatalog.FAMILY_LUCIDE
const FAMILY_TABLER := IconCatalog.FAMILY_TABLER

var icon_key := &""
var accent: Color = UITokens.ACCENT


func _ready() -> void:
	custom_minimum_size = custom_minimum_size.max(Vector2(26.0, 28.0))
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_semantic(semantic_key: StringName, p_accent: Color = UITokens.ACCENT) -> void:
	accent = p_accent
	icon_key = IconCatalog.resolve_semantic(semantic_key)
	visible = icon_key != &""
	queue_redraw()


func set_icon(icon: String, p_accent: Color = UITokens.ACCENT, _legacy_family = null) -> void:
	set_semantic(StringName(icon), p_accent)


func _draw() -> void:
	if icon_key == &"":
		return
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.38
	var edge := accent.lerp(UITokens.TEXT_MAIN, 0.22)
	var ink := accent.lerp(UITokens.TEXT_MAIN, 0.38)
	var texture := IconCatalog.texture_for_key(icon_key)
	draw_circle(center + Vector2(0.0, 1.0), radius + 2.0, Color(0.0, 0.0, 0.0, 0.28))
	draw_circle(center, radius + 1.4, Color(edge.r, edge.g, edge.b, 0.62))
	draw_circle(center, radius, UITokens.WALNUT)
	draw_arc(center, radius - 1.0, deg_to_rad(205.0), deg_to_rad(335.0), 18,
		Color(1.0, 0.90, 0.66, 0.16), 1.2, true)
	if texture != null:
		var icon_size := radius * 1.35
		draw_texture_rect(texture, Rect2(center - Vector2.ONE * icon_size * 0.5,
			Vector2.ONE * icon_size), false, ink)
		return
	var material_label := IconCatalog.label_for_key(icon_key)
	if not material_label.is_empty():
		var glyph := IconCatalog.glyph_for_key(icon_key)
		var glyph_size := 11
		var glyph_extent := FA_SOLID_FONT.get_string_size(
			glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size)
		var glyph_baseline := center + Vector2(
			-glyph_extent.x * 0.5 - 1.5, glyph_extent.y * 0.22 - 1.5)
		draw_string(FA_SOLID_FONT, glyph_baseline, glyph,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size,
			Color(ink.r, ink.g, ink.b, 0.58))
		var label_font := get_theme_default_font()
		var label_size := 8 if material_label.length() <= 2 else 6
		var measured := label_font.get_string_size(
			material_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size)
		var label_baseline := center + Vector2(
			radius - measured.x - 1.0, radius - 1.0)
		draw_circle(label_baseline + Vector2(measured.x * 0.5, -measured.y * 0.32),
			maxf(4.0, measured.x * 0.58), UITokens.WALNUT)
		draw_string(label_font, label_baseline, material_label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size, ink)
		return
	var overlay_glyph := String(IconCatalog.spec_for(icon_key).get("overlay_glyph", ""))
	if not overlay_glyph.is_empty():
		_draw_composite_glyph(center, radius, ink, overlay_glyph)
		return
	var glyph := IconCatalog.glyph_for_key(icon_key)
	var font_size := 13
	var text_size := FA_SOLID_FONT.get_string_size(
		glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.36)
	draw_string(FA_SOLID_FONT, baseline + Vector2(0.0, 1.0), glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, 0.36))
	draw_string(FA_SOLID_FONT, baseline, glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)


func _draw_composite_glyph(center: Vector2, radius: float, ink: Color,
		overlay_glyph: String) -> void:
	var base_glyph := IconCatalog.glyph_for_key(icon_key)
	var base_size := 11
	var base_extent := FA_SOLID_FONT.get_string_size(
		base_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, base_size)
	var base_line := center + Vector2(-base_extent.x * 0.5 - 2.0, base_extent.y * 0.25 - 2.0)
	draw_string(FA_SOLID_FONT, base_line, base_glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, base_size,
		Color(ink.r, ink.g, ink.b, 0.52))
	var overlay_size := 9
	var overlay_extent := FA_SOLID_FONT.get_string_size(
		overlay_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, overlay_size)
	var overlay_line := center + Vector2(
		radius - overlay_extent.x - 1.0, radius - 1.0)
	draw_circle(overlay_line + Vector2(overlay_extent.x * 0.5, -overlay_extent.y * 0.32),
		maxf(4.0, overlay_extent.x * 0.62), UITokens.WALNUT)
	draw_string(FA_SOLID_FONT, overlay_line, overlay_glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, overlay_size, ink)


# Compatibility wrappers keep existing components source-compatible while all
# mapping and presentation decisions live in the dedicated icon modules.
static func normalize_icon(icon: String) -> String:
	return IconCatalog.resolve_key(icon)


static func glyph_for_key(key: String) -> String:
	return IconCatalog.glyph_for_key(StringName(key))


static func texture_for_key(key: String, _legacy_family = null) -> Texture2D:
	return IconCatalog.texture_for_key(StringName(key))


static func apply_to_button(button: Button, icon: String, font_size: int = 16) -> void:
	IconButton.apply(button, StringName(icon), font_size)
