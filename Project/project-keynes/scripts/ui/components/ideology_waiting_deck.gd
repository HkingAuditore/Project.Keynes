extends RefCounted

## A physical deck shares the candidate row's footprint while the worker settles.
class DrawStack:
	extends Control
	const BACK_COUNT := 4
	var _backs: Array[Control] = []
	var _card_size := Vector2.ZERO
	var _tween: Tween
	var _shuffling := false

	func _init() -> void:
		name = "WaitingDeck"
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		for index in BACK_COUNT:
			var back := DeckBack.new()
			back.name = "DeckBack%d" % index
			back.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(back)
			IdeologyArt.attach_paper_shadow(back, 0.23 if index == BACK_COUNT - 1 else 0.12)
			_backs.append(back)
		set_card_size(Vector2(208, 276))

	func set_card_size(card_size: Vector2) -> void:
		if _card_size.is_equal_approx(card_size):
			return
		var resume := _shuffling
		stop()
		_card_size = card_size
		custom_minimum_size = card_size
		_layout()
		if resume:
			play(true)

	func play(animate: bool) -> void:
		stop()
		if not animate:
			return
		_shuffling = true
		var top := _backs.back() as Control
		var rest := top.position
		var rest_rotation := top.rotation
		_tween = create_tween().set_loops()
		_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(top, "position", rest + Vector2(_card_size.x * 0.12, -8), 0.65)
		_tween.parallel().tween_property(top, "rotation", rest_rotation + 0.08, 0.65)
		_tween.tween_property(top, "position", rest, 0.65)
		_tween.parallel().tween_property(top, "rotation", rest_rotation, 0.65)

	func stop() -> void:
		_shuffling = false
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_tween = null
		_layout()

	func is_shuffling() -> bool:
		return _shuffling

	func _layout() -> void:
		for index in _backs.size():
			var back := _backs[index]
			back.size = _card_size * 0.84
			back.pivot_offset = back.size * 0.5
			back.position = (_card_size - back.size) * 0.5 + Vector2(index * 2 - 3, -index * 2)
			back.rotation = deg_to_rad(-5.0 + index * 2.0)
			back.queue_redraw()


## Paper, inset, stamped linework and emblem remain separate material layers.
class DeckBack:
	extends Control
	func _draw() -> void:
		if size.x < 20:
			return
		IdeologyArt.paper_style(0).draw(get_canvas_item(), Rect2(Vector2.ZERO, size))
		var inset := maxf(8, size.x * 0.065)
		var face := Rect2(Vector2.ZERO, size).grow(-inset)
		IdeologyArt.paper_style(0, Color(0.27, 0.36, 0.29)).draw(get_canvas_item(), face)
		var line := Color(0.87, 0.72, 0.42, 0.68)
		draw_rect(face.grow(-6), line, false, 1.0)
		draw_rect(face.grow(-10), Color(line, 0.20), false, 1.0)
		var center := size * 0.5
		var radius := size.x * 0.23
		for side in [-1, 1]:
			var y: float = center.y + side * size.y * 0.29
			draw_line(Vector2(center.x - radius, y), Vector2(center.x + radius, y), line, 1, true)
			draw_circle(Vector2(center.x, y), 3, line)
		draw_circle(center + Vector2(0, 2), radius + 3, Color(0.05, 0.04, 0.02, 0.15))
		draw_circle(center, radius, Color(0.91, 0.83, 0.65))
		draw_arc(center, radius - 4, 0, TAU, 64, line.darkened(0.25), 1, true)
		var emblem := IconCatalog.texture_for_key(&"hud.country.ideology")
		if emblem != null:
			var extent := Vector2.ONE * radius * 1.45
			draw_texture_rect(emblem, Rect2(center - extent * 0.5, extent), false)
