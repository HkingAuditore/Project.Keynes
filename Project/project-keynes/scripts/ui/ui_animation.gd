extends RefCounted
class_name UIAnimation


static func fade_slide_in(control: Control, offset: Vector2 = Vector2(28.0, 0.0), duration: float = UITokens.ANIM_MED) -> void:
	if control == null:
		return
	var rest := _rest_position(control)
	control.visible = true
	control.modulate.a = 0.0
	control.position = rest + offset
	var tween := control.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(control, "position", rest, duration)
	tween.parallel().tween_property(control, "modulate:a", 1.0, duration)


static func fade_slide_out(control: Control, offset: Vector2 = Vector2(28.0, 0.0), duration: float = UITokens.ANIM_FAST) -> void:
	if control == null or not control.visible:
		return
	var rest := _rest_position(control)
	var tween := control.create_tween()
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(control, "position", rest + offset, duration)
	tween.parallel().tween_property(control, "modulate:a", 0.0, duration)
	tween.tween_callback(func() -> void:
		if control != null:
			control.visible = false
			control.position = rest
			control.modulate.a = 1.0
	)


static func crossfade(control: Control, duration: float = UITokens.ANIM_FAST) -> void:
	if control == null:
		return
	control.modulate.a = 0.0
	var tween := control.create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate:a", 1.0, duration)


static func pulse(control: CanvasItem, duration: float = UITokens.ANIM_MED) -> void:
	if control == null:
		return
	var tween := control.create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate", Color(1.25, 1.25, 1.20, 1.0), duration * 0.45)
	tween.tween_property(control, "modulate", Color.WHITE, duration * 0.55)


static func _rest_position(control: Control) -> Vector2:
	if not control.has_meta("_ui_rest_position"):
		control.set_meta("_ui_rest_position", control.position)
	return control.get_meta("_ui_rest_position")
