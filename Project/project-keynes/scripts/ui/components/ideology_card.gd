class_name IdeologyCard
extends Control

## One physical papercut ideology card. Pure presentation: the workspace feeds a
## card dictionary and listens to `activated`; drag-and-drop carries the stable
## idea id and location.
##
## Rarity is carried by the authored frame, gem count and reveal choreography,
## not by a line of explanatory text. The face reserves its text for the road's
## name and the effect a player is actually choosing.

signal activated(ideology_id: int)
signal locate_requested(ideology_id: int)
signal drag_started(ideology_id: int)

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const TITLE_FONT: FontFile = preload("res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf")
const BODY_FONT: FontFile = preload("res://assets/fonts/source_han_serif/SourceHanSerifCN-Regular.otf")
const UI_FONT: FontFile = preload("res://assets/fonts/source_han/SourceHanSansCN-VF.woff2")

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
var stage_rest_offset := Vector2.ZERO
var stage_rest_rotation := 0.0
var _hover_tween: Tween
var _deal_tween: Tween
var _motion_locked := false
var _level := 0
var _level_count := 3
var _rarity := 1
var _pip_size := Vector2(10, 2)

var _pivot: Control
var _aura: CardAura
var _shadow: NinePatchRect
var _frame: NinePatchRect
var _ornament: CardOrnament
var _face: MarginContainer
var _column: VBoxContainer
var _top_row: HBoxContainer
var _rarity_gems: RarityGems
var _edition: Label
var _edge: Panel
var _emblem: TextureRect
var _name: Label
var _subtitle: Label
var _rule: Control
var _effects_caption: Label
var _effects_primary: Label
var _effects_more: Label
var _effect_scroll: ScrollContainer
var _effect_column: VBoxContainer
var _footer: HBoxContainer
var _level_row: HBoxContainer
var _level_label: Label
var _back: TextureRect
var _gloss_layer: Control
var _gloss: GlossSweep
var _stamp_root: Control
var _stamp_seal: TextureRect
var _stamp: Label


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
	_pivot.clip_contents = false
	add_child(_pivot)

	_aura = CardAura.new()
	_aura.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_aura.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_aura.offset_left = -10.0
	_aura.offset_top = -10.0
	_aura.offset_right = 10.0
	_aura.offset_bottom = 10.0
	_pivot.add_child(_aura)

	_shadow = NinePatchRect.new()
	_shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shadow.modulate = Color(0.08, 0.055, 0.035, 0.32)
	_pivot.add_child(_shadow)
	_shadow.visible = false
	ArtScript.attach_paper_shadow(_pivot, 0.18)

	_frame = NinePatchRect.new()
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pivot.add_child(_frame)
	_edge = Panel.new()
	_edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pivot.add_child(_edge)

	_ornament = CardOrnament.new()
	_ornament.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ornament.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pivot.add_child(_ornament)

	_face = MarginContainer.new()
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pivot.add_child(_face)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 2)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(_column)

	_top_row = HBoxContainer.new()
	_top_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_top_row.add_theme_constant_override("separation", 4)
	_top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_top_row)
	_rarity_gems = RarityGems.new()
	_rarity_gems.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rarity_gems.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rarity_gems.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top_row.add_child(_rarity_gems)
	_rarity_gems.visible = false
	_edition = ArtScript.label("", 14, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	_top_row.add_child(_edition)

	_emblem = TextureRect.new()
	_emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_emblem)

	_name = ArtScript.label("", 22, ArtScript.INK)
	_name.add_theme_font_override("font", TITLE_FONT)
	_name.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_name.max_lines_visible = 2
	_name.clip_text = true
	_name.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_column.add_child(_name)

	_subtitle = ArtScript.label("", 9, ArtScript.INK_MUTED)
	_subtitle.add_theme_font_override("font", BODY_FONT)
	_subtitle.clip_text = true
	_subtitle.max_lines_visible = 1
	_column.add_child(_subtitle)

	_rule = Control.new()
	_rule.custom_minimum_size = Vector2(0, 4)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.add_child(_rule)

	_effects_caption = ArtScript.label("", 8, ArtScript.INK_MUTED,
		HORIZONTAL_ALIGNMENT_LEFT)
	_effects_caption.add_theme_font_override("font", UI_FONT)
	_effects_caption.clip_text = true
	_effects_caption.max_lines_visible = 1
	_column.add_child(_effects_caption)

	_effects_primary = ArtScript.label("", 11, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_effects_primary.add_theme_font_override("font", BODY_FONT)
	_effects_primary.add_theme_constant_override("outline_size", 0)
	_effects_primary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effects_primary.clip_text = true
	_effects_primary.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_effect_scroll = ScrollContainer.new()
	_effect_scroll.name = "EffectScroll"
	_effect_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_effect_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_effect_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_column.add_child(_effect_scroll)
	_effect_column = VBoxContainer.new()
	_effect_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_effect_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_effect_column.add_theme_constant_override("separation", 6)
	_effect_scroll.add_child(_effect_column)
	_effect_column.add_child(_effects_primary)

	_effects_more = ArtScript.label("", 9, ArtScript.INK,
		HORIZONTAL_ALIGNMENT_LEFT)
	_effects_more.add_theme_font_override("font", BODY_FONT)
	_effects_more.add_theme_constant_override("outline_size", 0)
	_effects_more.max_lines_visible = 3
	_effects_more.clip_text = true
	_effects_more.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_effects_more.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_effect_column.add_child(_effects_more)

	_footer = HBoxContainer.new()
	_footer.alignment = BoxContainer.ALIGNMENT_CENTER
	_footer.add_theme_constant_override("separation", 5)
	_footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.custom_minimum_size = Vector2(0, 13)
	_column.add_child(_footer)
	_level_label = ArtScript.label("", 9, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_LEFT)
	_level_label.add_theme_font_override("font", BODY_FONT)
	_level_label.clip_text = true
	_level_label.max_lines_visible = 1
	_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_footer.add_child(_level_label)
	_level_row = HBoxContainer.new()
	_level_row.alignment = BoxContainer.ALIGNMENT_END
	_level_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_row.add_theme_constant_override("separation", 3)
	_level_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.add_child(_level_row)

	_gloss_layer = Control.new()
	_gloss_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gloss_layer.clip_contents = true
	_gloss_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pivot.add_child(_gloss_layer)
	_gloss = GlossSweep.new()
	_gloss.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gloss.modulate.a = 0.0
	var gloss_material := CanvasItemMaterial.new()
	gloss_material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_gloss.material = gloss_material
	_gloss_layer.add_child(_gloss)

	_stamp_root = Control.new()
	_stamp_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamp_root.rotation = deg_to_rad(-7.0)
	_pivot.add_child(_stamp_root)
	_stamp_seal = TextureRect.new()
	_stamp_seal.texture = ArtScript.texture(ArtScript.RED_SEAL)
	_stamp_seal.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_stamp_seal.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_stamp_seal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamp_seal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stamp_root.add_child(_stamp_seal)
	_stamp = ArtScript.label("", 10, Color(1.0, 0.91, 0.67),
		HORIZONTAL_ALIGNMENT_CENTER)
	_stamp.add_theme_font_override("font", BODY_FONT)
	_stamp.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_stamp.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stamp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamp_root.add_child(_stamp)
	_stamp_root.visible = false

	_back = TextureRect.new()
	_back.texture = ArtScript.card_back()
	_back.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_back.stretch_mode = TextureRect.STRETCH_SCALE
	_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_back.visible = false
	_pivot.add_child(_back)

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
	var card_size := _stage_size if _stage and _stage_size.y > 0 else CARD_SIZE_STAGE
	if _compact and not _stage:
		card_size = CARD_SIZE_COMPACT
	var small := card_size.y < 350
	var pad := (16.0 if small else 22.0) + (8.0 if _rarity >= 2 else 0.0)
	var body_size := 17
	custom_minimum_size = card_size
	_face.offset_left = pad
	_face.offset_right = -pad
	_face.offset_top = pad
	_face.offset_bottom = -pad
	_column.add_theme_constant_override("separation", 5)
	_top_row.custom_minimum_size.y = 22
	_emblem.custom_minimum_size.y = roundf(card_size.y * 0.16)
	_name.add_theme_font_size_override("font_size", 21 if small else 25)
	_name.custom_minimum_size.y = 34 if small else 42
	_subtitle.visible = false
	_rule.visible = false
	_effects_caption.visible = false
	_effects_primary.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_effects_primary.add_theme_font_size_override("font_size", body_size)
	_effects_primary.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_effects_primary.custom_minimum_size.y = 0
	_effects_primary.size_flags_vertical = Control.SIZE_FILL
	_effects_primary.max_lines_visible = -1
	_effects_primary.clip_text = false
	_effects_more.add_theme_font_size_override("font_size", body_size)
	_effects_more.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_effects_more.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effects_more.custom_minimum_size.y = 0
	_effects_more.max_lines_visible = -1
	_effects_more.clip_text = false
	_effects_more.size_flags_vertical = Control.SIZE_FILL
	_effect_scroll.custom_minimum_size.y = 32
	_level_label.add_theme_font_size_override("font_size", 15)
	_footer.custom_minimum_size.y = 22
	_rarity_gems.custom_minimum_size = Vector2(40, 22)
	_rarity_gems.configure(_rarity, ArtScript.rarity_accent(_rarity), 22)
	_pip_size = Vector2(10, 3)
	_layout_decorations(card_size)
	_rebuild_level_pips()


func set_card(data: Dictionary) -> void:
	if _data == data:
		return
	_data = data
	ideology_id = int(data.get("ideology_id", -1))
	location = int(data.get("location", 0))
	_rarity = clampi(int(data.get("rarity", 1)), 1, 3)
	var school_id := String(data.get("school_id", ""))
	_frame.texture = ArtScript.frame_for(_rarity)
	_frame.self_modulate = ArtScript.paper_tint(_rarity)
	_edition.text = String(ArtScript.RARITY_NAMES[_rarity])
	_edition.add_theme_color_override("font_color", ArtScript.rarity_accent(_rarity))
	_edge.visible = _rarity >= 2
	if _rarity >= 2:
		_edge.add_theme_stylebox_override("panel", ArtScript.edition_style(_rarity))
	_shadow.texture = _frame.texture
	_emblem.texture = ArtScript.emblem_for(school_id)
	_name.text = String(data.get("display_name", "未命名道路"))
	_rarity_gems.configure(_rarity, ArtScript.rarity_accent(_rarity),
		int(_top_row.custom_minimum_size.y))
	_apply_effects(data.get("effects", PackedStringArray()))
	_level = int(data.get("level", 0))
	_level_count = int(data.get("level_count", 3))
	_rebuild_level_pips()
	var level_label := String(data.get("level_label", ""))
	if level_label.is_empty():
		level_label = "境界 %d / %d" % [_level, _level_count]
	_level_label.text = level_label
	_level_label.text += " · 第%d境" % (_level + 1)
	var stamp := String(data.get("stamp_text", ""))
	_stamp_root.visible = not stamp.is_empty()
	_stamp.text = stamp
	_place_stamp()
	tooltip_text = String(data.get("tooltip", ""))
	modulate = Color(1, 1, 1, 0.70) if bool(data.get("dimmed", false)) else Color.WHITE
	_apply_metrics()


func _apply_effects(effect_values: Variant) -> void:
	var effects: PackedStringArray
	if effect_values is PackedStringArray:
		effects = effect_values
	elif effect_values is Array:
		effects = PackedStringArray(effect_values)
	else:
		effects = PackedStringArray()
	var clean := PackedStringArray()
	for value in effects:
		var text := String(value).strip_edges()
		if not text.is_empty():
			clean.append(text)
	_effects_primary.text = clean[0] if not clean.is_empty() else "尚待践行"
	var more := PackedStringArray()
	for index in range(1, clean.size()):
		more.append("· %s" % clean[index])
	_effects_more.text = "\n".join(more)
	_effects_more.visible = not more.is_empty()


func card_data() -> Dictionary:
	return _data


func summary_text() -> String:
	return "%s：%s" % [_name.text, _effects_primary.text]


func rarity_tier() -> int:
	return _rarity


func _rebuild_level_pips() -> void:
	if _level_row == null:
		return
	for child in _level_row.get_children():
		_level_row.remove_child(child)
		child.queue_free()
	var reached := ArtScript.rarity_accent(_rarity)
	for index in maxi(1, _level_count):
		var pip := ColorRect.new()
		pip.custom_minimum_size = _pip_size
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.color = reached if index <= _level else Color(0.36, 0.27, 0.18, 0.24)
		_level_row.add_child(pip)


func set_face_up(face_up: bool) -> void:
	_face_up = face_up
	_back.visible = not face_up
	_face.visible = face_up
	_frame.visible = face_up
	_edge.visible = face_up and _rarity >= 2
	_ornament.visible = false
	_stamp_root.visible = face_up and not _stamp.text.is_empty()


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
		tween.tween_property(_gloss, "modulate:a", 0.68, 0.0)
		tween.tween_property(_gloss, "position:x", -_gloss.size.x - 16.0, 0.0)
		tween.tween_property(_gloss, "position:x", size.x + 20.0, 0.5) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tween.tween_property(_gloss, "modulate:a", 0.0, 0.08)


## Card falls onto the table from above after `delay` seconds.
func play_drop(delay: float, height := 64.0) -> Tween:
	_motion_locked = true
	_pivot.position = stage_rest_offset + Vector2(0.0, -height)
	_pivot.rotation = stage_rest_rotation
	_pivot.modulate.a = 0.0
	var tween := create_tween()
	_deal_tween = tween
	tween.tween_interval(maxf(0.0, delay))
	tween.tween_property(_pivot, "modulate:a", 1.0, 0.09)
	tween.parallel().tween_property(_pivot, "position:y", stage_rest_offset.y, 0.34) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_pivot, "rotation", stage_rest_rotation, 0.26) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: _motion_locked = false)
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
	tween.tween_property(_pivot, "scale", Vector2(1.025, 1.025), 0.07) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_pivot, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return tween


## Restore every animated channel (used when motion is reduced or reset).
func reset_motion() -> void:
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	if _deal_tween != null and _deal_tween.is_valid():
		_deal_tween.kill()
	_motion_locked = false
	_pivot.position = stage_rest_offset
	_pivot.scale = Vector2.ONE
	_pivot.rotation = stage_rest_rotation
	_pivot.modulate = Color.WHITE
	_gloss.modulate.a = 0.0
	_aura.set_glow(0.0)
	_layout_stage_hit_box()


func frame_texture() -> Texture2D:
	return _frame.texture


func _on_resized() -> void:
	_pivot.pivot_offset = size * 0.5
	pivot_offset = size * 0.5
	_layout_decorations(size)
	_place_stamp()
	_layout_stage_hit_box()


## The visual rest pose is tilted and lifted, so its hit rect and aura need the
## same inset. Otherwise a left-click can land on empty space beside a card.
func _layout_stage_hit_box() -> void:
	if _pivot == null:
		return
	_pivot.pivot_offset = size * 0.5
	_pivot.position = stage_rest_offset
	_pivot.rotation = stage_rest_rotation


func _layout_decorations(card_size: Vector2) -> void:
	if _frame == null or _frame.texture == null:
		return
	for node in [_frame, _shadow]:
		var patch := node as NinePatchRect
		patch.patch_margin_left = 12
		patch.patch_margin_right = 12
		patch.patch_margin_top = 12
		patch.patch_margin_bottom = 12
	_shadow.size = card_size
	_shadow.position = Vector2(4.0, 6.0)
	_gloss.size = Vector2(maxf(18.0, card_size.x * 0.085), card_size.y * 1.65)
	_gloss.position = Vector2(-_gloss.size.x - 16.0, -card_size.y * 0.3)
	_gloss.rotation = deg_to_rad(13.0)
	_aura.accent = ArtScript.rarity_glow(_rarity)
	_aura.visible = false
	_ornament.visible = false


## The state stamp is a free-standing label, so it owns its own size: a preset
## anchor alone left it 0x0 and therefore invisible.
func _place_stamp() -> void:
	if _stamp_root == null:
		return
	var seal_width := maxf(38.0, size.x * (0.30 if _compact and not _stage else 0.25))
	var seal_height := seal_width * 1.18
	_stamp_root.size = Vector2(seal_width, seal_height)
	_stamp_root.position = Vector2(
		maxf(3.0, size.x * 0.035),
		maxf(3.0, size.y - seal_height + seal_width * 0.12))
	_stamp.position = Vector2(seal_width * 0.20, seal_height * 0.14)
	_stamp.size = Vector2(seal_width * 0.60, seal_height * 0.46)
	_stamp.add_theme_font_size_override("font_size",
		clampi(int(round(seal_width * 0.19)), 8, 15))


func _set_hover(on: bool) -> void:
	if _motion_locked:
		return
	if UIAnimation.reduced_motion():
		_frame.modulate = Color(1.02, 1.01, 0.97) if on else Color.WHITE
		return
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel(true)
	_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var target_y := stage_rest_offset.y - 6.0 if on else stage_rest_offset.y
	_hover_tween.tween_property(_pivot, "position:y", target_y, 0.13)
	_hover_tween.tween_property(_pivot, "rotation",
		stage_rest_rotation - deg_to_rad(0.45) if on else stage_rest_rotation, 0.13)
	_frame.modulate = Color(1.02, 1.01, 0.97) if on else Color.WHITE


func _make_custom_tooltip(for_text: String) -> Object:
	return ArtScript.detail_tooltip(for_text, _data.get("detail_model", {}))


func _gui_input(event: InputEvent) -> void:
	if ArtScript.scroll_detail(event):
		accept_event()
		return
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.button_index == MOUSE_BUTTON_RIGHT:
			# Press and release both arrive here; answering once on press keeps
			# the map from being re-framed twice for one click.
			if mouse.pressed:
				locate_requested.emit(ideology_id)
				accept_event()
			return
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
	var holder := Control.new()
	var preview_size := size * 0.76
	var preview := NinePatchRect.new()
	preview.texture = _frame.texture
	preview.size = preview_size
	preview.patch_margin_left = int(_frame.patch_margin_left * 0.76)
	preview.patch_margin_right = int(_frame.patch_margin_right * 0.76)
	preview.patch_margin_top = int(_frame.patch_margin_top * 0.76)
	preview.patch_margin_bottom = int(_frame.patch_margin_bottom * 0.76)
	preview.modulate = Color(1, 1, 1, 0.86)
	preview.rotation = -0.045
	preview.position = -preview_size * 0.5
	holder.add_child(preview)
	var emblem := TextureRect.new()
	emblem.texture = _emblem.texture
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem.size = Vector2(preview_size.x * 0.52, preview_size.x * 0.52)
	emblem.position = -preview_size * 0.5 + Vector2(
		(preview_size.x - emblem.size.x) * 0.5, preview_size.y * 0.12)
	holder.add_child(emblem)
	var title := Label.new()
	title.text = _name.text
	title.add_theme_font_override("font", TITLE_FONT)
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", ArtScript.INK)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = -preview_size * 0.5 + Vector2(0, preview_size.y * 0.64)
	title.size = Vector2(preview_size.x, 24)
	holder.add_child(title)
	var label := Label.new()
	label.text = "拖至槽位"
	label.add_theme_font_override("font", BODY_FONT)
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", ArtScript.VERMILION)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-preview_size.x * 0.5, preview_size.y * 0.5 + 6.0)
	label.size = Vector2(preview_size.x, 20)
	holder.add_child(label)
	set_drag_preview(holder)
	drag_started.emit(ideology_id)
	return {"ideology_card": ideology_id, "location": location}


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
