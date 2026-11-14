extends Node2D

## Standalone visual harness for the military formation prototype.
## It deliberately does not mount MilitaryMapLayers or read live military state.

const PREVIEW_LAYER_SCRIPT = preload(
	"res://scripts/rendering/military_formation_preview_layer.gd")
const THEME: Theme = preload("res://assets/themes/player_session_theme.tres")
const DISPLAY_FONT: Font = preload("res://assets/fonts/muyao/display_handwritten.tres")
const SANS_BOLD: Font = preload("res://assets/fonts/swei/SweiGothicLegCJKsc-Bold.ttf")
const SANS: Font = preload("res://assets/fonts/swei/SweiGothicLegCJKsc-Regular.ttf")

const INK := Color("2b2118")
const MUTED := Color("6b5742")
const RED := Color("9b3324")
const PARCHMENT_TOP := Color("d8c9aa")
const PARCHMENT_BOTTOM := Color("f1e8d2")
const CAPTURE_DIR := "res://tmp/military_formation_visual"

var _preview
var _status_label: Label
var _action_buttons: Dictionary = {}
var _lod_buttons: Dictionary = {}
var _pause_button: Button
var _motion_button: Button
var _capture_running := false


func _ready() -> void:
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	_preview = PREVIEW_LAYER_SCRIPT.new()
	_preview.name = "MilitaryFormationPreview"
	add_child(_preview)
	_preview.action_changed.connect(_on_action_changed)
	_preview.lod_changed.connect(_on_lod_changed)
	_preview.paused_changed.connect(_on_paused_changed)
	_preview.reduced_motion_changed.connect(_on_reduced_motion_changed)
	_preview.heading_changed.connect(_on_heading_changed)
	_build_ui()
	_refresh_controls()
	queue_redraw()
	call_deferred("_maybe_run_capture")


func _on_viewport_size_changed() -> void:
	queue_redraw()


func _draw() -> void:
	var size := get_viewport_rect().size
	var bands := 32
	for index in bands:
		var t := float(index) / float(bands - 1)
		var color := PARCHMENT_TOP.lerp(PARCHMENT_BOTTOM, t)
		draw_rect(Rect2(0.0, size.y * t, size.x, size.y / float(bands) + 2.0), color)

	# Archival folds, faint contour rings and registration marks.
	for x_fraction in [0.31, 0.69]:
		var points := PackedVector2Array()
		for step in 18:
			var y := size.y * float(step) / 17.0
			var wave := sin(float(step) * 1.7 + x_fraction * 13.0) * 3.5
			points.append(Vector2(size.x * x_fraction + wave, y))
		draw_polyline(points, Color(0.31, 0.24, 0.17, 0.08), 1.0, true)

	draw_rect(Rect2(0, 0, size.x, 7), Color(INK, 0.92))
	draw_rect(Rect2(0, 7, size.x, 2), Color(RED, 0.72))
	draw_line(Vector2(32, 26), Vector2(32, size.y - 26), Color(RED, 0.28), 1.0)
	draw_line(Vector2(26, 34), Vector2(38, 34), Color(RED, 0.55), 1.0)

	var compass_center := Vector2(size.x - 116.0, 104.0)
	draw_arc(compass_center, 68.0, 0.0, TAU, 64, Color(INK, 0.10), 1.0, true)
	draw_arc(compass_center, 52.0, 0.0, TAU, 64, Color(RED, 0.16), 1.0, true)
	draw_line(compass_center + Vector2(-78, 0), compass_center + Vector2(78, 0),
		Color(INK, 0.10), 1.0)
	draw_line(compass_center + Vector2(0, -78), compass_center + Vector2(0, 78),
		Color(INK, 0.10), 1.0)

	draw_rect(Rect2(42, 176, size.x - 84, 1), Color(RED, 0.34))
	draw_string(
		SANS,
		Vector2(48, size.y - 28),
		"FIELD STUDY · READ-ONLY VISUAL PROTOTYPE · PKMI / STATE HASH UNCHANGED",
		HORIZONTAL_ALIGNMENT_LEFT,
		size.x - 96,
		11,
		Color(MUTED, 0.72)
	)


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "HarnessUI"
	canvas.layer = 4
	add_child(canvas)

	var ui_root := Control.new()
	ui_root.name = "UIRoot"
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui_root.theme = THEME
	ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(ui_root)

	var header_margin := MarginContainer.new()
	header_margin.name = "Header"
	header_margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	header_margin.offset_left = 42
	header_margin.offset_top = 22
	header_margin.offset_right = -42
	header_margin.offset_bottom = 170
	header_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(header_margin)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 28)
	header_margin.add_child(header)

	var title_block := VBoxContainer.new()
	title_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_block.add_theme_constant_override("separation", 1)
	header.add_child(title_block)

	var kicker := _make_label("军事地图表现 / FORMATION FIELD STUDY", 12, RED)
	kicker.add_theme_font_override("font", SANS_BOLD)
	title_block.add_child(kicker)

	var title := _make_label("部队编队可视原型", 38, INK)
	title.add_theme_font_override("font", DISPLAY_FONT)
	title_block.add_child(title)

	var subtitle := _make_label(
		"4 个动作原型 · 1–5 成员档位 · 3 级 LOD · 统一朝东、运行时旋转",
		16,
		MUTED
	)
	title_block.add_child(subtitle)

	var note := _make_label(
		"只读视觉试验。当前运行时使用 v4.1 formation 过渡基线；本场景不读取也不改写 MilitaryCore。",
		12,
		Color(MUTED, 0.82)
	)
	title_block.add_child(note)

	var controls := VBoxContainer.new()
	controls.name = "Controls"
	controls.custom_minimum_size = Vector2(690, 0)
	controls.alignment = BoxContainer.ALIGNMENT_CENTER
	controls.add_theme_constant_override("separation", 7)
	header.add_child(controls)

	var action_group := ButtonGroup.new()
	var action_row := _make_control_row(controls, "动作")
	for index in 4:
		var action_id := ["idle", "move", "attack", "hit"][index] as String
		var action_name := ["待命", "行军", "攻击", "受击"][index] as String
		var button := _make_toggle_button("%d  %s" % [index + 1, action_name], action_group)
		button.pressed.connect(_on_action_button.bind(action_id))
		action_row.add_child(button)
		_action_buttons[action_id] = button

	var lod_group := ButtonGroup.new()
	var lod_row := _make_control_row(controls, "缩放")
	for index in 3:
		var lod_name := ["聚合", "代表", "编队"][index] as String
		var button := _make_toggle_button("%d  %s" % [index + 1, lod_name], lod_group)
		button.pressed.connect(_on_lod_button.bind(index))
		lod_row.add_child(button)
		_lod_buttons[index] = button

	var utility_row := _make_control_row(controls, "演示")
	_pause_button = _make_button("暂停  Space")
	_pause_button.pressed.connect(func() -> void: _preview.toggle_paused())
	utility_row.add_child(_pause_button)
	_motion_button = _make_button("降低动态  M")
	_motion_button.pressed.connect(func() -> void: _preview.toggle_reduced_motion())
	utility_row.add_child(_motion_button)
	var reset_button := _make_button("重置  R")
	reset_button.pressed.connect(func() -> void: _preview.reset_view())
	utility_row.add_child(reset_button)
	_status_label = _make_label("", 13, MUTED)
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	utility_row.add_child(_status_label)

	var footer_margin := MarginContainer.new()
	footer_margin.name = "Footer"
	footer_margin.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer_margin.offset_left = 42
	footer_margin.offset_top = -64
	footer_margin.offset_right = -42
	footer_margin.offset_bottom = -20
	footer_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_root.add_child(footer_margin)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 20)
	footer_margin.add_child(footer)
	var help := _make_label(
		"1–4 动作   [ / ] LOD   Q / E 朝向   Space 暂停   M 降低动态   R 重置",
		13,
		Color(INK, 0.80)
	)
	help.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(help)
	var legend := _make_label(
		"原型强调色：步兵  青 / 骑乘  赭 / 炮兵  金 / 装甲  铁灰",
		12,
		Color(MUTED, 0.88)
	)
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	footer.add_child(legend)


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", SANS)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _make_control_row(parent: Control, caption: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	var label := _make_label(caption, 12, MUTED)
	label.custom_minimum_size = Vector2(42, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	return row


func _make_toggle_button(text: String, group: ButtonGroup) -> Button:
	var button := _make_button(text)
	button.toggle_mode = true
	button.button_group = group
	return button


func _make_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(82, 32)
	button.add_theme_font_override("font", SANS_BOLD)
	button.add_theme_font_size_override("font_size", 14)
	return button


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1:
			_preview.set_action_index(0)
		KEY_2:
			_preview.set_action_index(1)
		KEY_3:
			_preview.set_action_index(2)
		KEY_4:
			_preview.set_action_index(3)
		KEY_BRACKETLEFT:
			_preview.step_lod(-1)
		KEY_BRACKETRIGHT:
			_preview.step_lod(1)
		KEY_Q:
			_preview.step_heading_degrees(-15.0)
		KEY_E:
			_preview.step_heading_degrees(15.0)
		KEY_SPACE:
			_preview.toggle_paused()
		KEY_M:
			_preview.toggle_reduced_motion()
		KEY_R:
			_preview.reset_view()
		_:
			return
	get_viewport().set_input_as_handled()


func _on_action_changed(_action_id: String) -> void:
	_refresh_controls()


func _on_lod_changed(_lod_index: int) -> void:
	_refresh_controls()


func _on_paused_changed(_is_paused: bool) -> void:
	_refresh_controls()


func _on_reduced_motion_changed(_enabled: bool) -> void:
	_refresh_controls()


func _on_heading_changed(_degrees: float) -> void:
	_refresh_controls()


func _on_action_button(action_id: String) -> void:
	_preview.set_action(action_id)


func _on_lod_button(index: int) -> void:
	_preview.set_lod_mode(index)


func _refresh_controls() -> void:
	if _preview == null:
		return
	var active_action := String(_preview.active_action_id())
	for action_id in _action_buttons:
		var button := _action_buttons[action_id] as Button
		button.set_pressed_no_signal(String(action_id) == active_action)
	var active_lod := int(_preview.active_lod_index())
	for index in _lod_buttons:
		var button := _lod_buttons[index] as Button
		button.set_pressed_no_signal(int(index) == active_lod)
	if _pause_button != null:
		_pause_button.text = "继续  Space" if _preview.is_paused() else "暂停  Space"
	if _motion_button != null:
		_motion_button.text = "恢复动态  M" if _preview.is_reduced_motion() else "降低动态  M"
	if _status_label != null:
		var state := "已暂停" if _preview.is_paused() else "播放中"
		if _preview.is_reduced_motion():
			state += " · 静态代表帧"
		_status_label.text = "动作 %s · LOD %s · 朝向 %s %.0f° · 实例 %d · %s" % [
			_preview.active_action_name(),
			_preview.active_lod_name(),
			_heading_name(float(_preview.heading_degrees())),
			float(_preview.heading_degrees()),
			int(_preview.debug_snapshot().get("visible_instances", 0)),
			state,
		]


func _heading_name(degrees: float) -> String:
	var names := ["东", "东南", "南", "西南", "西", "西北", "北", "东北"]
	var index := posmod(int(round(degrees / 45.0)), names.size())
	return names[index]


func _maybe_run_capture() -> void:
	if _capture_running:
		return
	for argument in OS.get_cmdline_user_args():
		if String(argument) == "--capture":
			_capture_running = true
			await _run_capture_sequence()
			return


func _run_capture_sequence() -> void:
	var output_path := ProjectSettings.globalize_path(CAPTURE_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	await get_tree().create_timer(0.35).timeout

	_preview.set_lod_mode(2)
	_preview.set_action("idle")
	await _capture("01_formation_idle")

	_preview.set_action("move")
	await get_tree().create_timer(0.30).timeout
	await _capture("02_formation_move")

	_preview.set_action("attack")
	await get_tree().create_timer(0.48).timeout
	await _capture("03_formation_attack")

	_preview.set_action("hit")
	await get_tree().create_timer(0.38).timeout
	await _capture("04_formation_hit")

	_preview.set_lod_mode(1)
	_preview.set_action("idle")
	await get_tree().create_timer(0.20).timeout
	await _capture("05_representative_lod")

	_preview.set_lod_mode(0)
	await get_tree().create_timer(0.20).timeout
	await _capture("06_aggregate_lod")

	_preview.set_lod_mode(2)
	_preview.step_heading_degrees(30.0)
	await _capture("07_heading_30deg")
	get_tree().quit(0)


func _capture(label: String) -> void:
	for _index in 4:
		await get_tree().process_frame
	await get_tree().create_timer(0.08).timeout
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [ProjectSettings.globalize_path(CAPTURE_DIR), label]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		push_error("Military formation capture failed: %s" % path)
		return
	print("[military-formation] %s" % path)
