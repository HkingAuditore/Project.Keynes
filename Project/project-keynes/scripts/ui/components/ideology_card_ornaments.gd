extends RefCounted

## Soft halo behind the physical card. It never participates in layout and is
## only animated on hover/focus, so its cost is one small draw during a tween.
class CardAura:
	extends Control
	var accent := Color(0.88, 0.79, 0.59, 0.20)
	var glow := 0.0
	var _tween: Tween

	func _draw() -> void:
		if glow <= 0.001:
			return
		var center := size * 0.5
		var radius := minf(size.x, size.y) * 0.60
		for index in range(5, 0, -1):
			var layer := float(index) / 5.0
			draw_circle(center, radius * (0.74 + layer * 0.18),
				Color(accent, accent.a * glow * (1.0 - layer) * 0.55))

	func set_glow(value: float) -> void:
		glow = value
		queue_redraw()

	func set_target(value: float, duration: float) -> void:
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_tween = create_tween()
		_tween.tween_method(func(next: float) -> void: set_glow(next), glow, value, duration) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Static paper, fibre, ink and rarity ornaments. Text lives in Labels; this
## layer only adds material depth and the visual grammar of rarity.
class CardOrnament:
	extends Control
	var rarity := 1
	var school_accent := Color(0.3, 0.22, 0.14)
	var content_rect := Rect2()
	var art_rect := Rect2()

	func configure(tier: int, _ignored: int, accent: Color, content: Rect2,
			art: Rect2) -> void:
		rarity = tier
		school_accent = accent
		content_rect = content
		art_rect = art
		queue_redraw()

	func _draw() -> void:
		if size.x <= 1.0 or size.y <= 1.0:
			return
		var paper := Color(0.98, 0.94, 0.84, 0.035)
		draw_rect(Rect2(Vector2(2, 2), size - Vector2(4, 4)), paper)
		if art_rect.size.x > 4.0:
			_draw_art_wash()
			_draw_rays()
		if content_rect.size.x > 4.0:
			_draw_content_marks()

	func _draw_art_wash() -> void:
		var c := school_accent
		var x0 := art_rect.position.x
		var x1 := art_rect.end.x
		var y0 := art_rect.position.y
		var y1 := art_rect.end.y
		var mid := (x0 + x1) * 0.5
		var notch := maxf(3.0, art_rect.size.x * 0.035)
		var polygon := PackedVector2Array([
			Vector2(x0 + notch, y0),
			Vector2(mid - notch * 1.8, y0 + notch * 0.55),
			Vector2(mid, y0),
			Vector2(mid + notch * 1.4, y0 + notch * 0.45),
			Vector2(x1 - notch, y0 + notch),
			Vector2(x1, y0 + art_rect.size.y * 0.72),
			Vector2(x1 - notch * 2.2, y1 - notch * 0.4),
			Vector2(mid + notch * 2.6, y1),
			Vector2(mid, y1 - notch * 0.55),
			Vector2(mid - notch * 2.4, y1),
			Vector2(x0 + notch * 1.5, y1 - notch * 0.35),
			Vector2(x0, y0 + art_rect.size.y * 0.68),
		])
		draw_colored_polygon(polygon, Color(c, 0.095))
		var edge := PackedVector2Array()
		for index in range(3, polygon.size()):
			edge.append(polygon[index])
		draw_polyline(edge, Color(c, 0.20), 1.0, true)

	func _draw_rays() -> void:
		var center := art_rect.get_center()
		var outer := minf(art_rect.size.x, art_rect.size.y) * 0.54
		var ray_color := Color(school_accent, 0.075 if rarity < 3 else 0.10)
		for index in 12:
			var angle := TAU * float(index) / 12.0 + 0.13
			var inner := outer * 0.44
			draw_line(center + Vector2(cos(angle), sin(angle)) * inner,
				center + Vector2(cos(angle), sin(angle)) * outer,
				ray_color, 1.0, true)

	func _draw_content_marks() -> void:
		var x0 := content_rect.position.x
		var x1 := content_rect.end.x
		var rule_y := art_rect.end.y + 2.0
		var rule := Color(0.38, 0.25, 0.13, 0.36)
		draw_line(Vector2(x0, rule_y), Vector2(x1, rule_y), rule, 1.0)
		draw_line(Vector2(x0 + content_rect.size.x * 0.16, rule_y + 2.0),
			Vector2(x1 - content_rect.size.x * 0.16, rule_y + 2.0),
			Color(rule, 0.45), 1.0)
		var diamond_x := (x0 + x1) * 0.5
		var diamond_y := rule_y + 1.0
		var d := 2.2
		draw_colored_polygon(PackedVector2Array([
			Vector2(diamond_x, diamond_y - d),
			Vector2(diamond_x + d, diamond_y),
			Vector2(diamond_x, diamond_y + d),
			Vector2(diamond_x - d, diamond_y),
		]), Color(0.72, 0.52, 0.22, 0.72))
		var effects_top := art_rect.end.y + 55.0
		if effects_top + 8.0 < size.y:
			# A very quiet vellum leaf separates ink from watercolour without
			# covering the authored paper grain.
			var plate := Rect2(Vector2(x0 - 2.0, effects_top - 1.0),
				Vector2(maxf(0.0, content_rect.size.x + 4.0),
					maxf(0.0, size.y - effects_top - content_rect.size.y * 0.06)))
			draw_rect(plate, Color(0.98, 0.94, 0.82, 0.13))
			draw_line(plate.position, plate.position + Vector2(plate.size.x, 0.0),
				Color(0.56, 0.39, 0.18, 0.16), 1.0)


## Rarity is a count of cut-gold gems inside a ruled cartouche. Three gems also
## emit short rays, making 传世 legible at a glance without a text label.
class RarityGems:
	extends Control
	var tier := 1
	var accent := Color(0.3, 0.24, 0.17)
	var row_height := 12.0

	func configure(value: int, color: Color, height: float) -> void:
		tier = clampi(value, 1, 3)
		accent = color
		row_height = maxf(8.0, height)
		queue_redraw()

	func _draw() -> void:
		if size.x <= 2.0:
			return
		var center_y := size.y * 0.5
		var gap := 7.0 if tier < 3 else 7.5
		var start_x := (size.x - gap * float(tier - 1)) * 0.5
		var radius := clampf(size.y * 0.25, 2.2, 4.0)
		var gold := Color(0.80, 0.59, 0.23, 0.96)
		for index in tier:
			var x := start_x + float(index) * gap
			var points := PackedVector2Array([
				Vector2(x, center_y - radius),
				Vector2(x + radius, center_y),
				Vector2(x, center_y + radius),
				Vector2(x - radius, center_y),
			])
			draw_colored_polygon(points, gold.lerp(accent, 0.22))
			points.append(points[0])
			draw_polyline(points, Color(0.24, 0.14, 0.06, 0.88), 1.0, true)
			if tier >= 3:
				draw_line(Vector2(x, center_y - radius - 2.5),
					Vector2(x, center_y - radius - 0.7),
					Color(0.80, 0.59, 0.23, 0.72), 1.0)
				draw_line(Vector2(x, center_y + radius + 0.7),
					Vector2(x, center_y + radius + 2.5),
					Color(0.80, 0.59, 0.23, 0.72), 1.0)


## A narrow additive band that reads as a leaf of light crossing the paper.
class GlossSweep:
	extends Control
	func _draw() -> void:
		var strips := 20
		for index in strips:
			var t := (float(index) + 0.5) / float(strips)
			var alpha := pow(sin(t * PI), 2.0) * 0.46
			var warm := Color(1.0, 0.93, 0.69, alpha)
			draw_rect(Rect2(size.x * float(index) / float(strips), 0.0,
				size.x / float(strips) + 1.0, size.y), warm)
