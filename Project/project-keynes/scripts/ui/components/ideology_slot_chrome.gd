extends RefCounted

## Section chrome is drawn at the section boundary so the difference is legible
## before its rows enter the scroll viewport. Ordinary ideas get a clipped
## vermilion bookmark; spirits get a forest ribbon with a centred gold crest.
class SlotSectionChrome:
	extends Control
	var kind := 1

	func _draw() -> void:
		if size.x < 24.0 or size.y < 16.0:
			return
		if kind == 1:
			var spine := Rect2(0.0, 3.0, 7.0, size.y - 6.0)
			draw_rect(spine, Color(0.53, 0.15, 0.10, 0.84))
			draw_rect(Rect2(7.0, 5.0, size.x - 7.0, 1.0),
				Color(0.46, 0.29, 0.14, 0.34))
			draw_line(Vector2(12.0, size.y - 7.0),
				Vector2(size.x - 12.0, size.y - 7.0),
				Color(0.46, 0.29, 0.14, 0.20), 1.0)
			draw_colored_polygon(PackedVector2Array([
				Vector2(0.0, 3.0), Vector2(7.0, 3.0), Vector2(7.0, 9.0),
			]), Color(0.72, 0.52, 0.24, 0.64))
			return
		var inset := Rect2(2.0, 2.0, size.x - 4.0, size.y - 4.0)
		draw_rect(inset, Color(0.10, 0.18, 0.12, 0.72))
		draw_rect(inset.grow(-3.0), Color(0.79, 0.62, 0.30, 0.68),
			false, 1.0)
		draw_line(Vector2(18.0, inset.position.y + 7.0),
			Vector2(inset.end.x - 18.0, inset.position.y + 7.0),
			Color(0.89, 0.72, 0.39, 0.42), 1.0)
		draw_line(Vector2(18.0, inset.end.y - 7.0),
			Vector2(inset.end.x - 18.0, inset.end.y - 7.0),
			Color(0.89, 0.72, 0.39, 0.26), 1.0)
		var cx := size.x * 0.5
		draw_line(Vector2(cx - 12.0, inset.position.y + 7.0),
			Vector2(cx + 12.0, inset.position.y + 7.0),
			Color(0.86, 0.68, 0.35, 0.72), 1.0)


class ResonanceEmblem:
	extends VBoxContainer
	signal activated(school_id: String)
	var school_id := ""
	var _icon: TextureRect
	var _count: Label
	var _pips: HBoxContainer
	var _pressing := false
	var _press_pos := Vector2.ZERO

	func configure(school: String) -> void:
		school_id = school
		mouse_filter = Control.MOUSE_FILTER_PASS
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		alignment = BoxContainer.ALIGNMENT_CENTER
		add_theme_constant_override("separation", 1)
		custom_minimum_size = Vector2(52, 0)
		_icon = TextureRect.new()
		_icon.texture = IdeologyArt.emblem_for(school)
		_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon.custom_minimum_size = Vector2(22, 22)
		_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_icon)
		_count = IdeologyArt.label(IdeologyArt.school_name(school), 10,
			IdeologyArt.school_color(school))
		add_child(_count)
		_pips = HBoxContainer.new()
		_pips.visible = false
		_pips.alignment = BoxContainer.ALIGNMENT_CENTER
		_pips.add_theme_constant_override("separation", 4)
		_pips.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_pips)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mouse := event as InputEventMouseButton
			if mouse.button_index == MOUSE_BUTTON_LEFT:
				if mouse.pressed:
					_pressing = true
					_press_pos = mouse.position
				elif _pressing:
					_pressing = false
					if mouse.position.distance_to(_press_pos) <= 12.0:
						activated.emit(school_id)
						accept_event()

	func set_compact(compact: bool) -> void:
		_icon.custom_minimum_size = Vector2(18, 18) if compact else Vector2(22, 22)
		custom_minimum_size.x = 38 if compact else 52
		_count.add_theme_font_size_override("font_size", UITokens.FONT_SMALL)
		_pips.visible = false

	func set_state(count: int, preview_count: int, tiers: Array[Dictionary]) -> void:
		var school_label := IdeologyArt.school_name(school_id)
		_count.text = "%s %d" % [school_label, count] if preview_count == count \
			else "%s %d→%d" % [school_label, count, preview_count]
		_count.add_theme_color_override("font_color", IdeologyArt.VERMILION
			if preview_count != count else IdeologyArt.school_color(school_id))
		for child in _pips.get_children():
			_pips.remove_child(child)
			child.queue_free()
		var tips := PackedStringArray()
		var any_active := false
		for tier in tiers:
			var pip := ColorRect.new()
			pip.custom_minimum_size = Vector2(9, 9)
			pip.pivot_offset = Vector2(4.5, 4.5)
			# Diamonds read as inked seals; flat squares read as debug swatches.
			pip.rotation = PI * 0.25
			pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var active := bool(tier.get("active", false))
			var reach := preview_count >= int(tier.get("min_count", 99)) and not active
			any_active = any_active or active
			pip.color = IdeologyArt.VERMILION if active else (
				Color(0.86, 0.67, 0.30, 0.9) if reach else Color(0.45, 0.36, 0.26, 0.30))
			_pips.add_child(pip)
			tips.append("%s%s" % ["● " if active else "○ ", String(tier.get("tooltip", ""))])
		tooltip_text = "\n".join(tips)
		_icon.modulate = Color.WHITE if any_active or count > 0 else Color(1, 1, 1, 0.45)

	func celebrate() -> void:
		pivot_offset = size * 0.5
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2(1.05, 1.05), 0.1)
		tween.tween_property(self, "scale", Vector2.ONE, 0.3) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
