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
	var span := minf(size.x, size.y)
	var radius := span * 0.44
	var ink := accent.lerp(UITokens.DOSSIER_INK, 0.46)
	var cut_edge := Color(1.0, 0.96, 0.86, 0.88)
	var texture := IconCatalog.texture_for_key(icon_key)
	if texture != null:
		var fam := IconCatalog.family_for_key(icon_key)
		if fam == &"project_keynes":
			var crest_size := span * 0.92
			draw_texture_rect(texture, Rect2(center - Vector2.ONE * crest_size * 0.5,
				Vector2.ONE * crest_size), false, Color.WHITE)
			return
		var icon_size := span * 0.82
		var tex_rect := Rect2(center - Vector2.ONE * icon_size * 0.5, Vector2.ONE * icon_size)
		draw_texture_rect(texture, tex_rect, false, ink)
		return
	var is_chevron := icon_key == &"action.chevron_right" or icon_key == &"action.chevron_down"
	var material_label := IconCatalog.label_for_key(icon_key)
	if not material_label.is_empty():
		var glyph := IconCatalog.glyph_for_key(icon_key)
		var glyph_size := clampi(int(round(span * 0.58)), 11, 18)
		var glyph_extent := FA_SOLID_FONT.get_string_size(
			glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size)
		var glyph_baseline := center + Vector2(
			-glyph_extent.x * 0.5 - 1.5, glyph_extent.y * 0.30 - 1.5)
		draw_string(FA_SOLID_FONT, glyph_baseline + Vector2(0.8, 1.0), glyph,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size, cut_edge)
		draw_string(FA_SOLID_FONT, glyph_baseline, glyph,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size,
			Color(ink.r, ink.g, ink.b, 0.82))
		var label_font := get_theme_default_font()
		var label_size := 8 if material_label.length() <= 2 else 6
		var measured := label_font.get_string_size(
			material_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size)
		var label_baseline := center + Vector2(
			radius - measured.x, radius)
		var pill_center := label_baseline + Vector2(measured.x * 0.5, -measured.y * 0.32)
		var pill_r := maxf(4.5, measured.x * 0.58)
		draw_circle(pill_center, pill_r + 0.8, cut_edge)
		draw_circle(pill_center, pill_r, UITokens.DOSSIER_PAPER_DEEP)
		draw_string(label_font, label_baseline, material_label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_size, UITokens.DOSSIER_OXBLOOD)
		return
	var overlay_glyph := String(IconCatalog.spec_for(icon_key).get("overlay_glyph", ""))
	if not overlay_glyph.is_empty():
		_draw_composite_glyph(center, radius, span, ink, cut_edge, overlay_glyph)
		return
	var glyph := IconCatalog.glyph_for_key(icon_key)
	var font_size := clampi(int(round(span * (0.64 if is_chevron else 0.72))), 11, 20)
	var text_size := FA_SOLID_FONT.get_string_size(
		glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.36)
	draw_string(FA_SOLID_FONT, baseline + Vector2(0.8, 1.0), glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, cut_edge)
	draw_string(FA_SOLID_FONT, baseline, glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)


func _draw_composite_glyph(center: Vector2, radius: float, span: float, ink: Color,
		cut_edge: Color, overlay_glyph: String) -> void:
	var base_glyph := IconCatalog.glyph_for_key(icon_key)
	var base_size := clampi(int(round(span * 0.58)), 11, 18)
	var base_extent := FA_SOLID_FONT.get_string_size(
		base_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, base_size)
	var base_line := center + Vector2(-base_extent.x * 0.5 - 1.5, base_extent.y * 0.28 - 1.5)
	draw_string(FA_SOLID_FONT, base_line + Vector2(0.8, 1.0), base_glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, base_size, cut_edge)
	draw_string(FA_SOLID_FONT, base_line, base_glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, base_size,
		Color(ink.r, ink.g, ink.b, 0.78))
	var overlay_size := clampi(int(round(span * 0.44)), 9, 14)
	var overlay_extent := FA_SOLID_FONT.get_string_size(
		overlay_glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, overlay_size)
	var overlay_line := center + Vector2(
		radius - overlay_extent.x, radius)
	var pill_center := overlay_line + Vector2(overlay_extent.x * 0.5, -overlay_extent.y * 0.32)
	var pill_r := maxf(4.5, overlay_extent.x * 0.62)
	draw_circle(pill_center, pill_r + 0.8, cut_edge)
	draw_circle(pill_center, pill_r, UITokens.DOSSIER_PAPER_DEEP)
	draw_string(FA_SOLID_FONT, overlay_line, overlay_glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, overlay_size, UITokens.DOSSIER_OXBLOOD)


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
