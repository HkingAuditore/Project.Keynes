extends RefCounted
class_name UIAnimation

const TechnologyRevealShader := preload("res://shaders/ui/technology_page_reveal.gdshader")


## 材质扫描只在切页/切时代时运行；不移动 Container 管理的坐标。
static func reveal_technology_page(control: Control, page_top: float = 0.0,
		page_height: float = -1.0) -> void:
	if control == null or not control.is_inside_tree():
		return
	var old_tween = control.get_meta("_technology_reveal_tween") \
		if control.has_meta("_technology_reveal_tween") else null
	if old_tween is Tween and old_tween.is_valid():
		old_tween.kill()
	var shader_material = control.get_meta("_technology_reveal_material") \
		if control.has_meta("_technology_reveal_material") else null
	if shader_material == null:
		# Preserve a feature's own material instead of replacing it.
		if control.material != null:
			return
		shader_material = ShaderMaterial.new()
		shader_material.shader = TechnologyRevealShader
		control.set_meta("_technology_reveal_material", shader_material)
	if reduced_motion():
		control.material = null
		return
	control.material = shader_material
	var scale_y := control.get_global_transform().get_scale().y
	shader_material.set_shader_parameter("page_top", control.global_position.y + page_top * scale_y)
	shader_material.set_shader_parameter("page_height",
		(control.size.y if page_height < 0.0 else page_height) * scale_y)
	shader_material.set_shader_parameter("brass", UITokens.TECH_EFFECT_BRASS)
	shader_material.set_shader_parameter("reveal", 0.0)
	var tween := control.create_tween()
	control.set_meta("_technology_reveal_tween", tween)
	tween.tween_method(func(value: float) -> void:
		shader_material.set_shader_parameter("reveal", value), 0.0, 1.0,
		UITokens.TECH_PAGE_REVEAL).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void:
		control.material = null
		control.remove_meta("_technology_reveal_tween"))

static func reduced_motion() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var settings := tree.root.get_node_or_null("GameSettings") if tree != null else null
	return bool(settings.values().get("reduce_motion", false)) if settings != null else false


static func cancel(control: Control) -> void:
	if control == null:
		return
	_kill_active(control)
	control.modulate = Color.WHITE
	if is_equal_approx(control.anchor_right, 1.0) and is_equal_approx(control.anchor_bottom, 1.0):
		control.offset_left = 0.0
		control.offset_top = 0.0
		control.offset_right = 0.0
		control.offset_bottom = 0.0


## Animate a clipped wrapper's height; its Container parent still owns position.
static func reveal_vertical(wrapper: Control, content: Control, expanded: bool,
		duration: float = UITokens.ANIM_DISCLOSURE) -> void:
	_kill_active(wrapper)
	wrapper.visible = true
	var target_height := content.get_combined_minimum_size().y if expanded else 0.0
	var tween := wrapper.create_tween()
	wrapper.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(wrapper, "custom_minimum_size:y", target_height, duration)
	tween.parallel().tween_property(content, "modulate:a", 1.0 if expanded else 0.0, duration)
	tween.tween_callback(func() -> void:
		if not is_instance_valid(wrapper):
			return
		wrapper.visible = expanded
		if expanded:
			wrapper.custom_minimum_size.y = content.get_combined_minimum_size().y
		content.modulate.a = 1.0
		wrapper.remove_meta("_ui_active_tween"))


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


static func page_flip_in(control: Control, from_offset: Vector2 = Vector2(24.0, 0.0), duration: float = UITokens.ANIM_MED) -> void:
	if control == null:
		return
	_kill_active(control)
	var is_full_rect := is_equal_approx(control.anchor_right, 1.0) and is_equal_approx(control.anchor_bottom, 1.0)
	control.visible = true
	control.modulate = Color(1.04, 1.01, 0.96, 0.0)
	var tween := control.create_tween()
	control.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if is_full_rect:
		control.offset_left = from_offset.x
		control.offset_right = from_offset.x
		control.offset_top = from_offset.y
		control.offset_bottom = from_offset.y
		tween.parallel().tween_property(control, "offset_left", 0.0, duration)
		tween.parallel().tween_property(control, "offset_right", 0.0, duration)
		tween.parallel().tween_property(control, "offset_top", 0.0, duration)
		tween.parallel().tween_property(control, "offset_bottom", 0.0, duration)
	else:
		control.position = Vector2.ZERO
		refresh_rest_position(control)
		control.position = from_offset
		tween.parallel().tween_property(control, "position", Vector2.ZERO, duration)
	tween.parallel().tween_property(control, "modulate", Color.WHITE, duration)
	tween.tween_callback(func() -> void:
		if control != null:
			if is_full_rect:
				control.offset_left = 0.0
				control.offset_right = 0.0
				control.offset_top = 0.0
				control.offset_bottom = 0.0
			else:
				control.position = Vector2.ZERO
			control.modulate = Color.WHITE
			control.remove_meta("_ui_active_tween")
	)


static func bind_tactile_button(button: Button, inner_content: Control = null, shift_x: float = 5.0) -> void:
	if button == null or button.has_meta("_ui_tactile_bound"):
		return
	button.set_meta("_ui_tactile_bound", true)
	var target: Control = inner_content if inner_content != null else button
	var animate_state := func(hovered: bool, pressed: bool) -> void:
		if not is_instance_valid(button) or button.disabled:
			return
		_kill_hover_tween(button)
		var tween := button.create_tween()
		button.set_meta("_ui_hover_tween", tween)
		tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		if inner_content != null and is_instance_valid(inner_content):
			var target_x := shift_x if hovered and not pressed else (2.0 if pressed else 0.0)
			var target_y := 1.0 if pressed else 0.0
			tween.parallel().tween_property(inner_content, "position", Vector2(target_x, target_y), UITokens.ANIM_FAST)
		var modulate_target := Color(1.05, 1.02, 0.96, 1.0) if hovered and not pressed \
			else (Color(0.95, 0.92, 0.88, 1.0) if pressed else Color.WHITE)
		tween.parallel().tween_property(target, "modulate", modulate_target, UITokens.ANIM_FAST)
		tween.tween_callback(func() -> void:
			if is_instance_valid(button):
				button.remove_meta("_ui_hover_tween")
		)
	button.mouse_entered.connect(func() -> void: animate_state.call(true, button.button_pressed))
	button.mouse_exited.connect(func() -> void: animate_state.call(false, false))
	button.focus_entered.connect(func() -> void: animate_state.call(true, false))
	button.focus_exited.connect(func() -> void: animate_state.call(false, false))
	button.button_down.connect(func() -> void: animate_state.call(true, true))
	button.button_up.connect(func() -> void: animate_state.call(button.is_hovered(), false))


static func _kill_hover_tween(control: CanvasItem) -> void:
	if not control.has_meta("_ui_hover_tween"):
		return
	var active = control.get_meta("_ui_hover_tween")
	if active is Tween and (active as Tween).is_valid():
		(active as Tween).kill()
	control.remove_meta("_ui_hover_tween")


static func stagger_children_in(
		container: Control,
		step_sec: float = 0.025,
		max_items: int = 8,
		duration: float = UITokens.ANIM_FAST
) -> void:
	if container == null or not container.is_inside_tree():
		return
	var index := 0
	for child in container.get_children():
		var block := child as Control
		if block == null or not block.visible:
			continue
		if index >= max_items:
			break
		_kill_active(block)
		block.modulate.a = 0.0
		var tween := block.create_tween()
		block.set_meta("_ui_active_tween", tween)
		if index > 0:
			tween.tween_interval(step_sec * float(index))
		tween.tween_property(block, "modulate:a", 1.0, duration) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tween.tween_callback(func() -> void:
			if is_instance_valid(block):
				block.remove_meta("_ui_active_tween"))
		index += 1


static func tween_modulate(
		control: CanvasItem,
		target_color: Color,
		duration: float = UITokens.ANIM_FAST
) -> void:
	if control == null:
		return
	if not control.is_inside_tree():
		control.modulate = target_color
		return
	_kill_active(control)
	var tween := control.create_tween()
	control.set_meta("_ui_active_tween", tween)
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(control, "modulate", target_color, duration)
	tween.tween_callback(func() -> void:
		if is_instance_valid(control):
			control.remove_meta("_ui_active_tween"))


static func bind_hover_glow(
		control: Control,
		target: CanvasItem = null,
		hover_modulate: Color = Color(1.08, 1.05, 0.96, 1.0),
		pressed_modulate: Color = Color(0.93, 0.90, 0.85, 1.0)
) -> void:
	if control == null or control.has_meta("_ui_hover_glow_bound"):
		return
	control.set_meta("_ui_hover_glow_bound", true)
	var visual: CanvasItem = target if target != null else control
	control.mouse_entered.connect(func() -> void:
		if control is BaseButton and (control as BaseButton).disabled:
			return
		tween_modulate(visual, hover_modulate, UITokens.ANIM_FAST))
	control.mouse_exited.connect(func() -> void:
		tween_modulate(visual, Color.WHITE, UITokens.ANIM_FAST))
	if control is BaseButton:
		var button := control as BaseButton
		button.button_down.connect(func() -> void:
			if not button.disabled:
				tween_modulate(visual, pressed_modulate, 0.06))
		button.button_up.connect(func() -> void:
			tween_modulate(visual, Color.WHITE, UITokens.ANIM_FAST))


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
