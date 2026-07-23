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
	draw_circle(center, radius, UITokens.WALNUT)
	draw_arc(center, radius - 1.0, deg_to_rad(205.0), deg_to_rad(335.0), 18, Color(1.0, 0.90, 0.66, 0.16), 1.2, true)
	var font_size := 13
	var text_size := FA_SOLID_FONT.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
	var baseline := center + Vector2(-text_size.x * 0.5, text_size.y * 0.36)
	draw_string(FA_SOLID_FONT, baseline + Vector2(0.0, 1.0), glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.0, 0.0, 0.0, 0.36))
	draw_string(FA_SOLID_FONT, baseline, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)


func _normalize_icon(icon: String) -> String:
	return normalize_icon(icon)


static func normalize_icon(icon: String) -> String:
	match icon:
		"☼", "太阳", "sun", "climate":
			return "sun"
		"moon", "day_night", "night":
			return "moon"
		"overview", "summary", "总览":
			return "overview"
		"♣", "tree", "eco", "leaf", "forest", "timber":
			return "eco"
		"↟", "regen", "growth":
			return "growth"
		"≈", "☁", "☂", "water", "hydrology", "river", "ocean":
			return "water"
		"◆", "◇", "resource", "ore", "mineral", "stone":
			return "resource"
		"◈", "oil", "gas", "fuel":
			return "fuel"
		"crop", "grain", "wheat", "rice", "corn", "potato", "soil", "cotton", "flax":
			return "crop"
		"horse", "livestock", "pasture", "game":
			return "livestock"
		"⌖", "coord", "target":
			return "target"
		"↗", "wind":
			return "wind"
		"↑", "up", "trend_up":
			return "trend_up"
		"↓", "down", "trend_down":
			return "trend_down"
		"→", "flat", "trend_flat":
			return "trend_flat"
		"✦", "snow", "ice":
			return "snow"
		"♥", "heart", "life":
			return "heart"
		"history", "record", "记录":
			return "history"
		"geo", "terrain", "landform", "mountain":
			return "geo"
		"elevation":
			return "elevation"
		"vegetation":
			return "vegetation"
		"temperature":
			return "temperature"
		"humidity":
			return "humidity"
		"ocean_current":
			return "ocean_current"
		"resource_close", "eye_slash":
			return "eye_slash"
		"wood":
			return "wood"
		"rock":
			return "rock"
		"fire":
			return "fire"
		"metal":
			return "metal"
		"precious":
			return "precious"
		"fish":
			return "fish"
		"animal":
			return "animal"
		"earth":
			return "earth"
		"salt":
			return "salt"
		"flint":
			return "flint"
		"building", "buildings", "industry", "factory":
			return "building"
		"surface", "cover":
			return "surface"
		"weather", "cloud":
			return "weather"
		"settings", "setup":
			return "settings"
		"fit", "frame":
			return "fit"
		"regenerate", "refresh":
			return "regenerate"
		"pause":
			return "pause"
		"play":
			return "play"
		"close":
			return "close"
		"world", "globe":
			return "world"
		"clock", "time":
			return "clock"
		"calendar", "date":
			return "calendar"
		"seed":
			return "seed"
		"warning", "risk":
			return "warning"
		"", "—":
			return ""
		_:
			return "unknown"


func _glyph_for_key(key: String) -> String:
	return glyph_for_key(key)


static func glyph_for_key(key: String) -> String:
	match key:
		"sun":
			return "\uf185" # sun
		"moon":
			return "\uf186" # moon
		"eco":
			return "\uf06c" # leaf
		"water":
			return "\uf773" # water
		"resource":
			return "\uf3a5" # gem
		"fuel":
			return "\uf043" # droplet
		"crop":
			return "\uf722" # wheat-awn
		"livestock":
			return "\uf6f0" # horse-head
		"target":
			return "\uf05b" # crosshairs
		"wind":
			return "\uf72e" # wind
		"trend_up":
			return "\uf062" # arrow-up
		"trend_down":
			return "\uf063" # arrow-down
		"trend_flat":
			return "\uf061" # arrow-right
		"growth":
			return "\uf4d8" # seedling
		"snow":
			return "\uf2dc" # snowflake
		"heart":
			return "\uf004" # heart
		"overview":
			return "\uf0ca" # list
		"history":
			return "\uf1da" # rotate-left/history
		"surface":
			return "\uf5fd" # layer-group
		"weather":
			return "\uf0c2" # cloud
		"settings":
			return "\uf013" # gear
		"fit":
			return "\uf065" # expand
		"regenerate":
			return "\uf2f1" # rotate
		"pause":
			return "\uf04c"
		"play":
			return "\uf04b"
		"close":
			return "\uf00d"
		"world":
			return "\uf0ac" # globe
		"clock":
			return "\uf017"
		"calendar":
			return "\uf133"
		"seed":
			return "\uf1ec" # calculator/hash-like
		"warning":
			return "\uf071"
		"geo":
			return "\uf6fc" # mountain
		"elevation":
			return "\uf6fc" # mountain
		"vegetation":
			return "\uf1bb" # tree
		"temperature":
			return "\uf2c9" # thermometer-half
		"humidity":
			return "\uf043" # droplet
		"ocean_current":
			return "\uf773" # water
		"eye_slash":
			return "\uf070"
		"wood":
			return "\uf1bb"
		"rock":
			return "\uf6fc"
		"fire":
			return "\uf06d"
		"metal":
			return "\uf6e3" # hammer
		"precious":
			return "\uf3a5"
		"fish":
			return "\uf578"
		"animal":
			return "\uf1b0" # paw
		"earth":
			return "\uf1b2" # cube
		"salt":
			return "\uf5d2" # mortar-pestle
		"flint":
			return "\uf0e7" # bolt / spark silhouette
		"building":
			return "\uf1ad" # building
		_:
			return "\uf128" # question


static func apply_to_button(button: Button, icon: String, font_size: int = 16) -> void:
	if button == null:
		return
	var normalized := normalize_icon(icon)
	button.text = glyph_for_key(normalized)
	button.add_theme_font_override("font", FA_SOLID_FONT)
	button.add_theme_font_size_override("font_size", font_size)
