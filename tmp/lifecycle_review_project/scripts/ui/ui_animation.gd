extends RefCounted
class_name UIAnimation


static func fade_slide_in(control: Control, offset: Vector2 = Vector2(28.0, 0.0), duration: float = UITokens.ANIM_MED) -> void:
	if control == null:
		return
	_kill_active(control)
	var rest := _rest_position(control)
	control.visible = true
	control.modulate.a = 0.0
	control.position = rest + offset
	var tween := control.create_tween()
	control.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(control, "position", rest, duration)
	tween.parallel().tween_property(control, "modulate:a", 1.0, duration)
	tween.tween_callback(func() -> void: control.remove_meta("_ui_active_tween"))


static func fade_slide_out(control: Control, offset: Vector2 = Vector2(28.0, 0.0), duration: float = UITokens.ANIM_FAST) -> void:
	if control == null or not control.visible:
		return
	_kill_active(control)
	var rest := _rest_position(control)
	var tween := control.create_tween()
	control.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(control, "position", rest + offset, duration)
	tween.parallel().tween_property(control, "modulate:a", 0.0, duration)
	tween.tween_callback(func() -> void:
		if control != null:
			control.visible = false
			control.position = rest
			control.modulate.a = 1.0
			control.remove_meta("_ui_active_tween")
	)


static func crossfade(control: Control, duration: float = UITokens.ANIM_FAST) -> void:
	if control == null:
		return
	_kill_active(control)
	control.modulate.a = 0.0
	var tween := control.create_tween()
	control.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate:a", 1.0, duration)
	tween.tween_callback(func() -> void: control.remove_meta("_ui_active_tween"))


static func pulse(control: CanvasItem, duration: float = UITokens.ANIM_MED) -> void:
	if control == null:
		return
	_kill_active(control)
	var tween := control.create_tween()
	control.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate", Color(1.25, 1.25, 1.20, 1.0), duration * 0.45)
	tween.tween_property(control, "modulate", Color.WHITE, duration * 0.55)
	tween.tween_callback(func() -> void: control.remove_meta("_ui_active_tween"))


static func _rest_position(control: Control) -> Vector2:
	if not control.has_meta("_ui_rest_position"):
		control.set_meta("_ui_rest_position", control.position)
	return control.get_meta("_ui_rest_position")


# _rest_position() 只在第一次调用时从 control.position 取值并永久缓存——如果
# 那次快照发生在锚点还没结算出最终位置之前（比如面板首次从 hidden 切到
# visible 的那一帧），或者面板所在的 viewport 后续合法地变了尺寸（窗口缩放、
# Web 画布自适应），缓存值就会永久跟真实锚点位置错位，之后每次 slide 都会把
# 面板带到这个过期坐标上，而不是当前锚点算出来的正确位置。任何主动重新套用
# 锚点/offset 的布局代码（比如 GameUIManager._layout_right_panel）都应该在
# 确认控件当前不在动画中时，用这个函数把缓存刷新成最新的静止位置。
static func refresh_rest_position(control: Control) -> void:
	if control == null or control.has_meta("_ui_active_tween"):
		return
	control.set_meta("_ui_rest_position", control.position)


static func _kill_active(control: CanvasItem) -> void:
	if not control.has_meta("_ui_active_tween"):
		return
	var active = control.get_meta("_ui_active_tween")
	if active is Tween and (active as Tween).is_valid():
		(active as Tween).kill()
	control.remove_meta("_ui_active_tween")
