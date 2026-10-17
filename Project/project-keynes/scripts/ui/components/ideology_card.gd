class_name IdeologyCard
extends Control

## One papercut ideology card. Pure presentation: the workspace feeds it a
## card dictionary and listens to `activated`; drag-and-drop carries
## {"ideology_card": id, "location": loc} to slot niches.

signal activated(ideology_id: int)
signal drag_started(ideology_id: int)

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const CARD_SIZE := Vector2(150.0, 206.0)
const CARD_SIZE_COMPACT := Vector2(124.0, 170.0)

var ideology_id := -1
var location := 0
var draggable := true
var _data: Dictionary = {}
var _face_up := true
var _compact := false
var _hover := 0.0
var _hover_tween: Tween

var _pivot: Control
var _frame: TextureRect
var _back: TextureRect
var _face: Control
var _emblem: TextureRect
var _name: Label
var _rarity: Label
var _school: Label
var _effects: Label
var _level_row: HBoxContainer
var _stamp: Label
var _gloss: ColorRect


func _init() -> void:
	custom_minimum_size = CARD_SIZE
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()


func _build() -> void:
	_pivot = Control.new()
	_pivot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pivot.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_pivot)
	_frame = TextureRect.new()
	_frame.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_frame.stretch_mode = TextureRect.STRETCH_SCALE
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pivot.add_child(_frame)
	_face = VBoxContainer.new()
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_face.offset_left = 14
	_face.offset_right = -14
	_face.offset_top = 14
	_face.offset_bottom = -12
	(_face as VBoxContainer).add_theme_constant_override("separation", 2)
	_pivot.add_child(_face)
	_rarity = ArtScript.label("", 10, ArtScript.INK_MUTED)
	_face.add_child(_rarity)
	_emblem = TextureRect.new()
	_emblem.custom_minimum_size = Vector2(0, 52)
	_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(_emblem)
	_name = ArtScript.label("", 15, ArtScript.INK)
	_name.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_face.add_child(_name)
	_school = ArtScript.label("", 10, ArtScript.INK_MUTED)
	_face.add_child(_school)
	_effects = ArtScript.label("", 10, ArtScript.INK)
	_effects.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effects.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_effects.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_effects.clip_text = true
	_face.add_child(_effects)
	_level_row = HBoxContainer.new()
	_level_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_level_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level_row.add_theme_constant_override("separation", 4)
	_face.add_child(_level_row)
	_back = TextureRect.new()
	_back.texture = ArtScript.texture(ArtScript.CARD_BACK)
	_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_back.stretch_mode = TextureRect.STRETCH_SCALE
	_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_back.visible = false
	_pivot.add_child(_back)
	# Gold-leaf sweep: a slanted light band animated across rare/legendary faces.
	_gloss = ColorRect.new()
	_gloss.color = Color(1.0, 0.93, 0.66, 0.0)
	_gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gloss.size = Vector2(26, CARD_SIZE.y * 1.6)
	_gloss.rotation = 0.35
	_gloss.position = Vector2(-60, -40)
	_pivot.add_child(_gloss)
	_pivot.clip_contents = true
	_stamp = ArtScript.label("", 13, Color(0.97, 0.88, 0.80))
	_stamp.visible = false
	_stamp.add_theme_constant_override("outline_size", 3)
	_stamp.add_theme_color_override("font_outline_color", ArtScript.VERMILION)
	_stamp.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_stamp.position = Vector2(0, 6)
	add_child(_stamp)
	resized.connect(_on_resized)
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))
	focus_entered.connect(_set_hover.bind(true))
	focus_exited.connect(_set_hover.bind(false))


func set_compact(compact: bool) -> void:
	_compact = compact
	custom_minimum_size = CARD_SIZE_COMPACT if compact else CARD_SIZE
	_emblem.custom_minimum_size.y = 38 if compact else 52
	_name.add_theme_font_size_override("font_size", 13 if compact else 15)


## data keys: ideology_id, display_name, school_id, rarity, rarity_label,
## effects (PackedStringArray), level, level_count, location, pending,
## stamp_text, tooltip.
func set_card(data: Dictionary) -> void:
	_data = data
	ideology_id = int(data.get("ideology_id", -1))
	location = int(data.get("location", 0))
	var rarity := int(data.get("rarity", 1))
	var school_id := String(data.get("school_id", ""))
	_frame.texture = ArtScript.frame_for(rarity)
	_emblem.texture = ArtScript.emblem_for(school_id)
	_name.text = String(data.get("display_name", "未命名道路"))
	_rarity.text = String(data.get("rarity_label", ArtScript.RARITY_LABELS.get(rarity, "")))
	_rarity.add_theme_color_override("font_color",
		ArtScript.RARITY_COLORS.get(rarity, ArtScript.INK_MUTED))
	_school.text = "〔%s〕" % ArtScript.school_name(school_id) if not school_id.is_empty() else ""
	_school.add_theme_color_override("font_color", ArtScript.school_color(school_id))
	var effects: PackedStringArray = data.get("effects", PackedStringArray())
	_effects.text = "\n".join(effects)
	_rebuild_level_pips(int(data.get("level", 0)), int(data.get("level_count", 3)))
	var stamp := String(data.get("stamp_text", ""))
	_stamp.visible = not stamp.is_empty()
	_stamp.text = stamp
	tooltip_text = String(data.get("tooltip", ""))
	modulate = Color(1, 1, 1, 0.72) if bool(data.get("dimmed", false)) else Color.WHITE


func card_data() -> Dictionary:
	return _data


func summary_text() -> String:
	return "%s：%s" % [_name.text, _effects.text.replace("\n", "、")]


func _rebuild_level_pips(level: int, count: int) -> void:
	for child in _level_row.get_children():
		child.queue_free()
	for index in maxi(1, count):
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(14, 5)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.color = ArtScript.VERMILION if index <= level else Color(0.45, 0.36, 0.26, 0.35)
		_level_row.add_child(pip)


func set_face_up(face_up: bool) -> void:
	_face_up = face_up
	_back.visible = not face_up
	_face.visible = face_up
	_frame.visible = face_up


func is_face_up() -> bool:
	return _face_up


## Horizontal squash flip: back -> face. Returns the tween for chaining.
func flip_to_face(duration := 0.28) -> Tween:
	var tween := create_tween()
	tween.tween_property(_pivot, "scale:x", 0.0, duration * 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_callback(set_face_up.bind(true))
	tween.tween_property(_pivot, "scale:x", 1.0, duration * 0.5) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tween


## Gold-leaf sweep across the face; legendary cards sweep twice.
func play_gloss(times := 1) -> void:
	var tween := create_tween()
	for _i in times:
		tween.tween_property(_gloss, "color:a", 0.55, 0.0)
		tween.tween_property(_gloss, "position:x", -60.0, 0.0)
		tween.tween_property(_gloss, "position:x", size.x + 40.0, 0.55) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(_gloss, "color:a", 0.0, 0.08)


## Card falls onto the table from above after `delay` seconds.
func play_drop(delay: float, height := 72.0) -> Tween:
	_pivot.position.y = -height
	_pivot.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_interval(maxf(0.0, delay))
	tween.tween_property(_pivot, "modulate:a", 1.0, 0.10)
	tween.parallel().tween_property(_pivot, "position:y", 0.0, 0.34) \
		.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	return tween


## Unchosen offer cards fold vertically and fade out.
func fold_away(duration := 0.26) -> Tween:
	var tween := create_tween()
	tween.tween_property(_pivot, "scale:y", 0.04, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_pivot, "modulate:a", 0.0, duration)
	return tween


## Seal impact: brief overscale that settles back with a springy ease.
func stamp_punch() -> Tween:
	var tween := create_tween()
	tween.tween_property(_pivot, "scale", Vector2(1.14, 1.14), 0.07) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_pivot, "scale", Vector2.ONE, 0.22) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tween


## Restore every animated channel (used when motion is reduced or reset).
func reset_motion() -> void:
	_pivot.position = Vector2.ZERO
	_pivot.scale = Vector2.ONE
	_pivot.modulate = Color.WHITE
	_gloss.color.a = 0.0


func frame_texture() -> Texture2D:
	return _frame.texture


func _on_resized() -> void:
	_pivot.pivot_offset = size * 0.5
	pivot_offset = size * 0.5
	_gloss.size.y = size.y * 1.6


func _set_hover(on: bool) -> void:
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween()
	_hover_tween.tween_property(_pivot, "position:y", -6.0 if on else 0.0, 0.12) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_LEFT and mouse.pressed \
				and mouse.double_click:
			activated.emit(ideology_id)
			accept_event()
	elif event.is_action_pressed(&"ui_accept"):
		activated.emit(ideology_id)
		accept_event()


func _get_drag_data(_at_position: Vector2) -> Variant:
	if not draggable or ideology_id < 0 or bool(_data.get("pending", false)):
		return null
	var preview := TextureRect.new()
	preview.texture = _frame.texture
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.size = size * 0.8
	preview.modulate = Color(1, 1, 1, 0.85)
	preview.rotation = -0.06
	var holder := Control.new()
	holder.add_child(preview)
	preview.position = -preview.size * 0.5
	var title := ArtScript.label(_name.text, 13, ArtScript.INK)
	title.position = Vector2(-preview.size.x * 0.5, -10)
	title.size = Vector2(preview.size.x, 20)
	holder.add_child(title)
	set_drag_preview(holder)
	drag_started.emit(ideology_id)
	return {"ideology_card": ideology_id, "location": location}
