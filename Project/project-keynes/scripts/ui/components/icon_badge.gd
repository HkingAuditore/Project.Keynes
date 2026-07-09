extends Control
class_name IconBadge

const FA_SOLID_FONT: FontFile = preload("res://assets/fonts/fontawesome/fa-solid-900.woff2")

var icon_key: String = ""
var accent: Color = UITokens.ACCENT


func _ready() -> void:
	custom_minimum_size = Vector2(26.0, 28.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_icon(icon: String, p_accent: Color = UITokens.ACCENT) -> void:
	icon_key = _normalize_icon(icon)
	accent = p_accent
	visible = icon_key != ""
	queue_redraw()


func _draw() -> void:
	if icon_key == "":
		return
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.38
	var edge := accent.lerp(UITokens.TEXT_MAIN, 0.22)
	var ink := accent.lerp(UITokens.TEXT_MAIN, 0.38)
	var glyph := _glyph_for_key(icon_key)
	draw_circle(center + Vector2(0.0, 1.0), radius + 2.0, Color(0.0, 0.0, 0.0, 0.28))
	draw_circle(center, radius + 1.4, Color(edge.r, edge.g, edge.b, 0.62))
	draw_circle(center, radius, Color(0.085, 0.065, 0.043, 0.96))
	draw_arc(center, radius - 1.0, deg_to_rad(205.0), deg_to_rad(335.0), 18, Color(1.0, 0.90, 0.66, 0.16), 1.2, true)
	var font_size := 13
	var text_size := FA_SOLID_FONT.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.36)
	draw_string(FA_SOLID_FONT, baseline + Vector2(0.0, 1.0), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, 0.36))
	draw_string(FA_SOLID_FONT, baseline, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)


func _normalize_icon(icon: String) -> String:
	match icon:
		"☼", "太阳", "sun", "climate":
			return "sun"
		"♣", "↟", "tree", "eco", "leaf":
			return "eco"
		"≈", "☁", "☂", "water", "hydrology":
			return "water"
		"◆", "◇", "◈", "resource", "ore":
			return "resource"
		"⌖", "coord", "target":
			return "target"
		"↗", "↑", "wind", "arrow":
			return "arrow"
		"✦", "snow", "ice":
			return "snow"
		"♥", "heart", "life":
			return "heart"
		"", "—":
			return ""
		_:
			return "geo"


func _glyph_for_key(key: String) -> String:
	match key:
		"sun":
			return "\uf185" # sun
		"eco":
			return "\uf06c" # leaf
		"water":
			return "\uf773" # water
		"resource":
			return "\uf3a5" # gem
		"target":
			return "\uf05b" # crosshairs
		"arrow":
			return "\uf72e" # wind
		"snow":
			return "\uf2dc" # snowflake
		"heart":
			return "\uf004" # heart
		_:
			return "\uf6fc" # mountain
