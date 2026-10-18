class_name IdeologyCard
extends Control

## One papercut ideology card. Pure presentation: the workspace feeds it a
## card dictionary and listens to `activated`; drag-and-drop carries
## {"ideology_card": id, "location": loc} to slot niches.
##
## Three size tiers keep the card legible without breaking the panel:
## `stage` for the three-card offer, `CARD_SIZE` for slots/collection, and the
## compact variants used below 900x520 logical pixels.

signal activated(ideology_id: int)
signal drag_started(ideology_id: int)

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const CARD_SIZE := Vector2(196.0, 260.0)
const CARD_SIZE_COMPACT := Vector2(146.0, 194.0)
## Fallback offer size until the tray reports its own height.
const CARD_SIZE_STAGE := Vector2(208.0, 276.0)
const CARD_ASPECT := 0.754

var ideology_id := -1
var location := 0
var draggable := true
## Offer cards take a plain left click; slots and collection rows keep the
## deliberate double click so browsing never equips by accident.
var activate_on_single_click := false
var _data: Dictionary = {}
var _face_up := true
var _compact := false
var _stage := false
var _stage_size := Vector2.ZERO
var _hover := 0.0
var _hover_tween: Tween
var _level := 0
var _level_count := 3
var _pip_size := Vector2(15, 5)

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
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_build()
	_apply_metrics()


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
	(_face as VBoxContainer).add_theme_constant_override("separation", 2)
	_pivot.add_child(_face)
	_rarity = ArtScript.label("", 11, ArtScript.INK_MUTED)
	_face.add_child(_rarity)
	_emblem = TextureRect.new()
	_emblem.custom_minimum_size = Vector2(0, 52)
	_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(_emblem)
	_name = ArtScript.label("", 17, ArtScript.INK)
	_name.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_face.add_child(_name)
	_school = ArtScript.label("", 11, ArtScript.INK_MUTED)
	_face.add_child(_school)
	_effects = ArtScript.label("", 12, ArtScript.INK)
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
	add_child(_stamp)
	resized.connect(_on_resized)
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))
	focus_entered.connect(_set_hover.bind(true))
	focus_exited.connect(_set_hover.bind(false))


func set_compact(compact: bool) -> void:
	if _compact == compact:
		return
	_compact = compact
	_apply_metrics()


## Offer cards are drawn larger so the mechanical effect lines stay readable.
func set_stage(stage: bool) -> void:
	if _stage == stage:
		return
	_stage = stage
	_apply_metrics()


## The offer tray sizes its cards from the panel height; text scales with it.
func set_stage_size(card_size: Vector2) -> void:
	if _stage and _stage_size.is_equal_approx(card_size):
		return
	_stage = true
	_stage_size = card_size
	_apply_metrics()


func is_stage() -> bool:
	return _stage


func _apply_metrics() -> void:
	var stage_fonts := _stage
	var card_size := CARD_SIZE
	if _stage:
		card_size = _stage_size if _stage_size.y > 0.0 else CARD_SIZE_STAGE
	var pad_x := 13
	var pad_top := 13
	var pad_bottom := 11
	var rarity_font := 11
	var name_font := 18
	var meta_font := 11
	var effect_font := 13
	var emblem_height := 56
	var stamp_font := 13
	_pip_size = Vector2(16, 5)
	if _compact:
		if not _stage:
			card_size = CARD_SIZE_COMPACT
		pad_x = 9
		pad_top = 9
		pad_bottom = 8
		rarity_font = 10
		name_font = 15
		meta_font = 10
		effect_font = 11
		emblem_height = 40
		stamp_font = 11
		_pip_size = Vector2(12, 4)
	if stage_fonts:
		# Stage cards are metered by the tray: every glyph follows card height so
		# 720p stays legible and 1080p reads like a real card, not a thumbnail.
		var height := card_size.y
		pad_x = clampi(int(round(card_size.x * 0.068)), 9, 22)
		pad_top = pad_x
		pad_bottom = maxi(8, pad_x - 2)
		rarity_font = clampi(int(round(height * 0.042)), 10, 15)
		name_font = clampi(int(round(height * 0.070)), 16, 27)
		meta_font = clampi(int(round(height * 0.040)), 10, 14)
		effect_font = clampi(int(round(height * 0.047)), 11, 17)
		emblem_height = clampi(int(round(height * 0.225)), 40, 96)
		stamp_font = clampi(int(round(height * 0.052)), 11, 19)
		_pip_size = Vector2(clampi(int(round(card_size.x * 0.08)), 12, 24), 5)
	custom_minimum_size = card_size
	_face.offset_left = pad_x
	_face.offset_right = -pad_x
	_face.offset_top = pad_top
	_face.offset_bottom = -pad_bottom
	_rarity.add_theme_font_size_override("font_size", rarity_font)
	_name.add_theme_font_size_override("font_size", name_font)
	_school.add_theme_font_size_override("font_size", meta_font)
	_effects.add_theme_font_size_override("font_size", effect_font)
	_emblem.custom_minimum_size.y = emblem_height
	_stamp.add_theme_font_size_override("font_size", stamp_font)
	_gloss.size.y = card_size.y * 1.6
	_rebuild_level_pips()


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
	_level = int(data.get("level", 0))
	_level_count = int(data.get("level_count", 3))
	_rebuild_level_pips()
	var stamp := String(data.get("stamp_text", ""))
	_stamp.visible = not stamp.is_empty()
	_stamp.text = stamp
	_place_stamp()
	tooltip_text = String(data.get("tooltip", ""))
	modulate = Color(1, 1, 1, 0.72) if bool(data.get("dimmed", false)) else Color.WHITE


func card_data() -> Dictionary:
	return _data


func summary_text() -> String:
	return "%s：%s" % [_name.text, _effects.text.replace("\n", "、")]


func _rebuild_level_pips() -> void:
	for child in _level_row.get_children():
		_level_row.remove_child(child)
		child.queue_free()
	for index in maxi(1, _level_count):
		var pip := ColorRect.new()
		pip.custom_minimum_size = _pip_size
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.color = ArtScript.VERMILION if index <= _level else Color(0.45, 0.36, 0.26, 0.35)
		_level_row.add_child(pip)


func set_face_up(face_up: bool) -> void:
	_face_up = face_up
	_back.visible = not face_up
	_face.visible = face_up
	_frame.visible = face_up


func is_face_up() -> bool:
	return _face_up


## Horizontal squash flip: back -> face. Returns the tween for chaining.
func flip_to_face(duration := 0.24) -> Tween:
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
		tween.tween_property(_gloss, "position:x", size.x + 40.0, 0.5) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(_gloss, "color:a", 0.0, 0.08)


## Card falls onto the table from above after `delay` seconds.
func play_drop(delay: float, height := 64.0) -> Tween:
	_pivot.position.y = -height
	_pivot.modulate.a = 0.0
	var tween := create_tween()
	tween.tween_interval(maxf(0.0, delay))
	tween.tween_property(_pivot, "modulate:a", 1.0, 0.09)
	tween.parallel().tween_property(_pivot, "position:y", 0.0, 0.3) \
		.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	return tween


## Unchosen offer cards fold vertically and fade out.
func fold_away(duration := 0.22) -> Tween:
	var tween := create_tween()
	tween.tween_property(_pivot, "scale:y", 0.04, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_pivot, "modulate:a", 0.0, duration)
	return tween


## Seal impact: brief overscale that settles back with a springy ease.
func stamp_punch() -> Tween:
	var tween := create_tween()
	tween.tween_property(_pivot, "scale", Vector2(1.1, 1.1), 0.07) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_pivot, "scale", Vector2.ONE, 0.2) \
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
	_place_stamp()


## The state stamp is a free-standing label, so it owns its own size: a preset
## anchor alone left it 0x0 and therefore invisible.
func _place_stamp() -> void:
	if _stamp == null:
		return
	_stamp.reset_size()
	_stamp.position = Vector2(roundf((size.x - _stamp.size.x) * 0.5), 8.0)


func _set_hover(on: bool) -> void:
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween()
	_hover_tween.tween_property(_pivot, "position:y", -6.0 if on else 0.0, 0.12) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index != MOUSE_BUTTON_LEFT:
			return
		if activate_on_single_click:
			# Offer cards: one press-release selects the road.
			if not mouse.pressed and not mouse.double_click:
				grab_focus()
				activated.emit(ideology_id)
				accept_event()
		elif mouse.pressed and mouse.double_click:
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
