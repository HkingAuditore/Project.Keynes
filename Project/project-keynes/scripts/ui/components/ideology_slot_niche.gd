class_name IdeologySlotNiche
extends PanelContainer

## One physical cabinet slot: an equipped ideology keeps its emblem, current
## effect, brass level seal and understanding track visible at a glance. Empty
## capacity collapses into a single card-shaped drop sleeve.

signal card_dropped(ideology_id: int, from_location: int, kind: int)
signal drag_hovered(ideology_id: int, kind: int, entered: bool)
signal command_requested(op: String, ideology_id: int)
signal promote_requested(ideology_id: int)
signal locate_requested(ideology_id: int)

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const LevelMeterScript = preload(
	"res://scripts/ui/components/ideology_level_meter.gd")
const TITLE_FONT: FontFile = preload(
	"res://assets/fonts/annual_pencil/Muyao-Softbrush-2.ttf")
const BODY_FONT: FontFile = preload(
	"res://assets/fonts/source_han_serif/SourceHanSerifCN-Regular.otf")

var kind := 1
var empty := true
var occupied_id := -1
var _compact := false
var _data: Dictionary = {}
var _drop_hover := false
var _empty_count := 0
var _hover_tween: Tween

var _backdrop: SlotBackdrop
var _rail: SlotRail
var _content: MarginContainer
var _row: HBoxContainer
var _emblem_stack: Control
var _icon_plate: PanelContainer
var _icon: TextureRect
var _info: VBoxContainer
var _head: HBoxContainer
var _name: Label
var _badge: Label
var _effects: Label
var _actions: HBoxContainer
var _unequip: Button
var _promote: Button
var _level_meter: Control
var _empty_label: Label
var _empty_hint: Label
var _empty_stack: EmptySleeve
var _empty_copy: VBoxContainer
var _slot_label: Label


func _init() -> void:
	theme_type_variation = &"PKPaperCard"
	mouse_filter = Control.MOUSE_FILTER_PASS
	custom_minimum_size = Vector2(0, 108)
	ArtScript.attach_panel_shadow(self, 0.25)
	_backdrop = SlotBackdrop.new()
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_backdrop)
	_rail = SlotRail.new()
	_rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_rail)
	_content = MarginContainer.new()
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_theme_constant_override("margin_left", 17)
	_content.add_theme_constant_override("margin_top", 8)
	_content.add_theme_constant_override("margin_right", 8)
	_content.add_theme_constant_override("margin_bottom", 8)
	add_child(_content)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 9)
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_row)

	_emblem_stack = Control.new()
	_emblem_stack.custom_minimum_size = Vector2(48, 48)
	_emblem_stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_emblem_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_emblem_stack)
	_icon_plate = PanelContainer.new()
	_icon_plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_icon_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon_plate.add_theme_stylebox_override("panel", _emblem_plate_style())
	_emblem_stack.add_child(_icon_plate)
	_icon = TextureRect.new()
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT,
		Control.PRESET_MODE_MINSIZE, 4)
	_icon_plate.add_child(_icon)

	_info = VBoxContainer.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.add_theme_constant_override("separation", 4)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_info)

	# The two slot classes are named directly. Their card silhouettes, rails,
	# typography and internal rhythm then reinforce the distinction visually.
	_head = HBoxContainer.new()
	_head.add_theme_constant_override("separation", 6)
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_child(_head)
	var title_block := VBoxContainer.new()
	title_block.name = "PolicyTitleBlock"
	title_block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_block.add_theme_constant_override("separation", -3)
	title_block.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_head.add_child(title_block)
	_slot_label = ArtScript.label("", 10, ArtScript.INK_MUTED,
		HORIZONTAL_ALIGNMENT_LEFT)
	_slot_label.name = "SlotClass"
	_slot_label.add_theme_font_override("font", BODY_FONT)
	title_block.add_child(_slot_label)
	_name = ArtScript.label("", 16, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_name.name = "PolicyName"
	_name.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.clip_text = true
	_name.max_lines_visible = 1
	title_block.add_child(_name)
	_badge = ArtScript.label("", 9, ArtScript.VERMILION,
		HORIZONTAL_ALIGNMENT_RIGHT)
	_badge.visible = false
	_badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_head.add_child(_badge)
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	_actions.alignment = BoxContainer.ALIGNMENT_END
	_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_info.add_child(_actions)
	_unequip = _action_button("撤回")
	_unequip.pressed.connect(func() -> void:
		command_requested.emit("unequip", occupied_id))
	_actions.add_child(_unequip)
	_promote = _action_button("晋")
	_promote.pressed.connect(func() -> void: promote_requested.emit(occupied_id))
	_actions.add_child(_promote)
	_effects = ArtScript.label("", 10, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_effects.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_effects.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_effects.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	_effects.max_lines_visible = -1
	_effects.custom_minimum_size.y = 44
	_info.add_child(_effects)
	_effects.resized.connect(_queue_effect_layout)
	_level_meter = LevelMeterScript.new()
	_level_meter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.add_child(_level_meter)
	_info.move_child(_actions, _info.get_child_count() - 1)

	_empty_stack = EmptySleeve.new()
	_empty_stack.custom_minimum_size = Vector2(52, 60)
	_empty_stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_empty_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_empty_stack)
	var empty_copy := VBoxContainer.new()
	_empty_copy = empty_copy
	empty_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	empty_copy.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	empty_copy.add_theme_constant_override("separation", 0)
	empty_copy.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(empty_copy)
	_empty_label = ArtScript.label("", 14, ArtScript.INK,
		HORIZONTAL_ALIGNMENT_LEFT)
	_empty_label.add_theme_font_override("font", TITLE_FONT)
	_empty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_empty_label.max_lines_visible = 1
	_empty_label.visible = false
	empty_copy.add_child(_empty_label)
	_empty_hint = ArtScript.label("", 9, ArtScript.INK_MUTED,
		HORIZONTAL_ALIGNMENT_LEFT)
	_empty_hint.add_theme_font_override("font", BODY_FONT)
	_empty_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_hint.max_lines_visible = -1
	_empty_hint.clip_text = false
	_empty_hint.visible = false
	empty_copy.add_child(_empty_hint)
	_apply_visibility()


func _ready() -> void:
	_apply_surface()
	mouse_entered.connect(_set_hover.bind(true))
	mouse_exited.connect(_set_hover.bind(false))


func _gui_input(event: InputEvent) -> void:
	if ArtScript.scroll_detail(event):
		accept_event()
		return
	var mouse := event as InputEventMouseButton
	if mouse == null or mouse.button_index != MOUSE_BUTTON_RIGHT or not mouse.pressed:
		return
	if empty or occupied_id < 0:
		return
	locate_requested.emit(occupied_id)
	accept_event()


func configure(niche_kind: int, is_empty: bool, compact: bool) -> void:
	kind = niche_kind
	empty = is_empty
	_compact = compact
	_apply_metrics()
	_queue_effect_layout()
	_apply_visibility()
	theme_type_variation = &"PKPaperNote" if empty else &"PKPaperCard"
	_apply_surface()


func set_empty_count(count: int, milestone := "") -> void:
	_empty_count = count
	if kind == 1:
		_empty_label.text = "国家理念"
		_empty_hint.text = "拖入理念，或从右侧收藏中推行"
	else:
		_empty_label.text = "民族精神"
		_empty_hint.text = "达到晋升条件后移入"
	if not milestone.is_empty():
		_empty_hint.tooltip_text = milestone
	else:
		_empty_hint.tooltip_text = ""
	tooltip_text = "%s\n%s" % [_empty_label.text, _empty_hint.text]
	_rail.accent = ArtScript.school_color("") if kind == 1 else ArtScript.VERMILION
	_rail.queue_redraw()
	_backdrop.kind = kind
	_backdrop.empty = true
	_backdrop.queue_redraw()
	_empty_stack.kind = kind
	_empty_stack.capacity = count
	_empty_stack.queue_redraw()


func set_row(data: Dictionary) -> void:
	_data = data
	empty = false
	occupied_id = int(data.get("ideology_id", -1))
	var school_id := String(data.get("school_id", ""))
	var accent := ArtScript.school_color(school_id)
	_icon.texture = ArtScript.emblem_for(school_id)
	_name.text = String(data.get("display_name", ""))
	var effects: PackedStringArray = data.get("effects", PackedStringArray())
	_effects.text = "\n".join(effects) if not effects.is_empty() else "尚待践行"
	var pending := bool(data.get("pending", false))
	var spirit := kind == 2
	_slot_label.text = "民族精神" if spirit else "国家理念"
	_slot_label.add_theme_color_override("font_color",
		ArtScript.GOLD_LEAF if spirit else ArtScript.INK_MUTED)
	# The section band and the ceremonial alcove already identify a spirit.
	# Keep the badge for temporary command state only, never as a repeated class.
	_badge.visible = pending
	_badge.text = "待生效"
	_actions.visible = not spirit
	_unequip.disabled = not bool(data.get("can_unequip", false)) or pending
	_unequip.tooltip_text = String(data.get("unequip_tooltip", "撤回这条道路"))
	_promote.disabled = not bool(data.get("can_promote", false)) or pending
	_promote.tooltip_text = String(data.get("promote_tooltip", "晋升为民族精神"))
	var meter_data: Dictionary = data.get("level_progress", {})
	meter_data["accent"] = accent
	# The meter copies its kind into the inner track during configure().
	# Assign it first so a refreshed spirit row never redraws an ordinary track.
	_level_meter.set("kind", kind)
	_level_meter.configure(meter_data, _compact)
	_rail.accent = accent
	_rail.queue_redraw()
	_backdrop.kind = kind
	_backdrop.empty = false
	_backdrop.queue_redraw()
	_icon_plate.add_theme_stylebox_override("panel", _emblem_plate_style(accent))
	tooltip_text = String(data.get("tooltip", ""))
	_apply_visibility()
	_apply_metrics()


func row_data() -> Dictionary:
	return _data


func _queue_effect_layout() -> void:
	call_deferred("_fit_effects")


func _fit_effects() -> void:
	var font := _effects.get_theme_font("font")
	var height := font.get_height(_effects.get_theme_font_size("font_size"))
	_effects.custom_minimum_size.y = ceilf(maxf(44.0, height * _effects.get_line_count()))


func is_empty_slot() -> bool:
	return empty


func level_meter() -> Control:
	return _level_meter


func _action_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.text = "晋升" if text == "晋" else text
	button.theme_type_variation = &"PKDossierRowButton"
	button.custom_minimum_size = Vector2(76, 34)
	button.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	button.add_theme_font_size_override("font_size", 17)
	button.focus_mode = Control.FOCUS_ALL
	return button


func _apply_metrics() -> void:
	custom_minimum_size.y = (84.0 if kind == 1 else 104.0) if empty else (
		132.0 if kind == 1 else 150.0)
	if empty and _compact:
		custom_minimum_size.y = 50.0 if kind == 1 else 58.0
	_content.add_theme_constant_override("margin_left", 17 if kind == 1 else 30)
	_content.add_theme_constant_override("margin_top", 7 if kind == 1 else 10)
	_content.add_theme_constant_override("margin_right", 8 if kind == 1 else 20)
	_content.add_theme_constant_override("margin_bottom", 7 if kind == 1 else 10)
	if _compact:
		_content.add_theme_constant_override("margin_left", 14)
		_content.add_theme_constant_override("margin_top", 3)
		_content.add_theme_constant_override("margin_right", 6)
		_content.add_theme_constant_override("margin_bottom", 3)
	_row.add_theme_constant_override("separation", 7 if _compact else 10)
	_emblem_stack.custom_minimum_size = Vector2(40, 40) if _compact \
		else Vector2(50, 50)
	_empty_stack.custom_minimum_size = Vector2(46, 54) if _compact \
		else Vector2(56, 66)
	if empty and _compact:
		_empty_stack.custom_minimum_size = Vector2(38, 38) \
			if kind == 1 else Vector2(42, 42)
	_name.add_theme_font_size_override("font_size",
		(18 if _compact else 20) if kind == 1 else (21 if _compact else 24))
	_slot_label.add_theme_font_size_override("font_size", 10 if kind == 1 else 11)
	_effects.add_theme_font_size_override("font_size", 17)
	_badge.add_theme_font_size_override("font_size", 15)
	_empty_label.add_theme_font_size_override("font_size",
		16 if _compact else 18)
	_empty_hint.add_theme_font_size_override("font_size",
		15 if _compact else 16)
	_icon_plate.add_theme_stylebox_override("panel", _emblem_plate_style(
		ArtScript.school_color(String(_data.get("school_id", "")))))
	_rail.kind = kind
	_rail.queue_redraw()
	_backdrop.kind = kind
	_backdrop.queue_redraw()
	_level_meter.set("kind", kind)


func _apply_visibility() -> void:
	_slot_label.visible = false
	_emblem_stack.visible = not empty
	_empty_copy.visible = empty
	_icon.visible = not empty
	_icon_plate.visible = not empty
	_info.visible = not empty
	_empty_stack.visible = empty
	_empty_label.visible = empty
	_empty_hint.visible = empty
	_actions.visible = not empty and kind != 2
	_rail.empty = empty
	_rail.queue_redraw()
	_backdrop.empty = empty
	_backdrop.queue_redraw()


func _emblem_plate_style(accent := ArtScript.INK_MUTED) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.92, 0.86, 0.71, 0.78)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 2
	style.border_color = Color(accent, 0.58)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.shadow_color = Color(0.08, 0.04, 0.02, 0.28)
	style.shadow_size = 4
	style.shadow_offset = Vector2(0, 2)
	return style


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not empty or not (data is Dictionary):
		return false
	var payload := data as Dictionary
	if not payload.has("ideology_card"):
		return false
	var ok := int(payload.get("location", 0)) != kind
	if ok != _drop_hover:
		_set_drop_hover(ok)
		drag_hovered.emit(int(payload.get("ideology_card")), kind, ok)
	return ok


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_set_drop_hover(false)
	var payload := data as Dictionary
	drag_hovered.emit(int(payload.get("ideology_card")), kind, false)
	card_dropped.emit(int(payload.get("ideology_card")),
		int(payload.get("location", 0)), kind)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drop_hover:
		_set_drop_hover(false)


func _set_drop_hover(on: bool) -> void:
	_drop_hover = on
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel(true)
	_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(self, "self_modulate",
		Color(1.10, 1.05, 0.86) if on else Color.WHITE, 0.12)
	if empty:
		_hover_tween.tween_property(_empty_stack, "position:y",
			-3.0 if on else 0.0, 0.12)


func _set_hover(on: bool) -> void:
	if _drop_hover or _hover_tween != null and _hover_tween.is_running():
		return
	if _hover_tween != null and _hover_tween.is_valid():
		_hover_tween.kill()
	_hover_tween = create_tween().set_parallel(true)
	_hover_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_hover_tween.tween_property(_rail, "glow", 1.0 if on else 0.0, 0.15)
	_hover_tween.tween_property(self, "self_modulate",
		Color(1.025, 1.015, 0.98) if on else Color.WHITE, 0.15)


func _apply_surface() -> void:
	add_theme_stylebox_override("panel", ArtScript.paper_style(0.0,
		(Color(0.96, 0.94, 0.87) if empty else Color.WHITE) if kind == 1
		else (Color(0.91, 0.93, 0.83) if empty else Color(1.0, 0.96, 0.85))))


func _make_custom_tooltip(for_text: String) -> Object:
	return ArtScript.detail_tooltip(for_text, _data.get("detail_model", {}))


## A folded dossier corner distinguishes ordinary ideas from the inset green
## ceremonial mat beneath a national spirit. Both forms are layered behind the
## paper rather than painted into one opaque rectangle.
class SlotBackdrop:
	extends Control
	var kind := 1
	var empty := false

	func _draw() -> void:
		if size.x < 24.0 or size.y < 24.0:
			return
		if kind == 1:
			var fold := 12.0
			var corner := PackedVector2Array([
				Vector2(size.x - fold, 1.0), Vector2(size.x - 1.0, fold),
				Vector2(size.x - fold, fold),
			])
			draw_colored_polygon(corner, Color(0.70, 0.58, 0.39, 0.15
				if empty else 0.24))
			draw_polyline(PackedVector2Array([
				Vector2(size.x - fold, 1.0), Vector2(size.x - 1.0, fold),
				Vector2(size.x - fold, fold), Vector2(size.x - fold, 1.0),
			]), Color(0.39, 0.24, 0.12, 0.28 if empty else 0.44), 1.0, true)
			return
		var mat := Rect2(Vector2(8.0, 5.0),
			Vector2(size.x - 16.0, size.y - 10.0))
		draw_rect(mat, Color(0.09, 0.20, 0.13, 0.08 if empty else 0.12))
		draw_rect(mat, Color(0.22, 0.34, 0.24, 0.50 if empty else 0.68),
			false, 1.5)
		draw_rect(mat.grow(-4.0), Color(0.72, 0.56, 0.27,
			0.37 if empty else 0.58), false, 1.0)
		var diamond_y := mat.position.y + 9.0
		var diamond := PackedVector2Array([
			Vector2(mat.position.x + 10.0, diamond_y),
			Vector2(mat.position.x + 15.0, diamond_y - 4.0),
			Vector2(mat.position.x + 20.0, diamond_y),
			Vector2(mat.position.x + 15.0, diamond_y + 4.0),
		])
		draw_colored_polygon(diamond, Color(0.74, 0.57, 0.27,
			0.56 if empty else 0.82))
		draw_line(Vector2(mat.end.x - 30.0, diamond_y),
			Vector2(mat.end.x - 10.0, diamond_y),
			Color(0.72, 0.56, 0.27, 0.42), 1.0)


## A sewn burgundy spine on every occupied slot and a dashed stitch on empty
## sleeves. This gives the cabinet a physical rhythm without adding a label.
class SlotRail:
	extends Control
	var accent := Color(0.66, 0.15, 0.09)
	var kind := 1
	var empty := false
	var glow := 0.0

	func _draw() -> void:
		if size.y < 20.0:
			return
		var x := 8.0 if kind == 1 else 12.0
		var rail := Rect2(x - (4.0 if kind == 1 else 7.0),
			7.0 if kind == 1 else 5.0, 8.0 if kind == 1 else 16.0,
			size.y - (14.0 if kind == 1 else 10.0))
		draw_rect(rail, Color(0.46, 0.13, 0.08, 0.42 if empty else 0.92)
			if kind == 1 else Color(0.23, 0.31, 0.24, 0.82))
		if kind == 2:
			draw_line(Vector2(x - 4.0, 9.0), Vector2(x - 4.0, size.y - 9.0),
				Color(0.10, 0.18, 0.12, 0.70), 1.0)
			draw_line(Vector2(x + 4.0, 9.0), Vector2(x + 4.0, size.y - 9.0),
				Color(0.10, 0.18, 0.12, 0.70), 1.0)
		draw_line(Vector2(x + 4.0, 9.0), Vector2(x + 4.0, size.y - 9.0),
			Color(0.84, 0.66, 0.35, 0.46), 1.0)
		var step := 18.0 if empty else 22.0
		var y := 15.0
		while y < size.y - 12.0:
			var color := Color(0.70, 0.48, 0.20, 0.32 if empty else 0.62)
			draw_line(Vector2(x - 3.0, y), Vector2(x + 3.0, y + 2.0),
				color, 1.0)
			if not empty:
				draw_circle(Vector2(x, y + 8.0), 1.4,
					Color(0.94, 0.79, 0.50, 0.60))
			y += step
		if kind == 1:
			draw_colored_polygon(PackedVector2Array([
				Vector2(x, 2.0), Vector2(x + 5.0, 7.0),
				Vector2(x, 12.0), Vector2(x - 5.0, 7.0),
			]), Color(accent, 0.80))
		else:
			var crown := PackedVector2Array([
				Vector2(x - 7.0, 9.0), Vector2(x - 5.0, 2.0),
				Vector2(x - 1.0, 6.0), Vector2(x, 1.0),
				Vector2(x + 2.0, 6.0), Vector2(x + 6.0, 2.0),
				Vector2(x + 7.0, 9.0),
			])
			draw_colored_polygon(crown, ArtScript.GOLD_LEAF.darkened(0.22))
			draw_polyline(crown, Color(0.51, 0.31, 0.10, 0.70), 1.0, true)
			draw_rect(Rect2(x + 12.0, 6.0, 2.0, size.y - 12.0),
				Color(0.52, 0.32, 0.10, 0.48))
		if glow > 0.01:
			draw_rect(Rect2(0.5, 0.5, size.x - 1.0, size.y - 1.0),
				Color(accent, 0.15 * glow), false, 1.5)


## Empty capacity is represented by a single cut-paper sleeve with stitching
## and a ghosted card behind it, not by a long blank form row.
class EmptySleeve:
	extends Control
	var kind := 1
	var capacity := 1

	func _draw() -> void:
		if size.x < 8.0 or size.y < 12.0:
			return
		var center := size * 0.5
		var back := Rect2(Vector2(size.x * (0.18 if kind == 1 else 0.11),
			size.y * 0.03 if kind == 2 else size.y * 0.06),
			Vector2(size.x * (0.70 if kind == 1 else 0.81),
				size.y * (0.82 if kind == 1 else 0.91)))
		draw_rect(back, Color(0.58, 0.40, 0.19, 0.10))
		back.position += Vector2(4, 3)
		draw_rect(back, Color(0.48, 0.31, 0.14, 0.10))
		var card := Rect2(Vector2(size.x * (0.12 if kind == 1 else 0.10),
			size.y * (0.12 if kind == 1 else 0.10)),
			Vector2(size.x * (0.76 if kind == 1 else 0.82),
				size.y * (0.82 if kind == 1 else 0.86)))
		var leaf_count := clampi(capacity, 1, 4)
		for leaf in range(leaf_count, 1, -1):
			var leaf_rect := card
			leaf_rect.position += Vector2(-float(leaf - 1) * 2.5,
				-float(leaf - 1) * 3.0)
			draw_rect(leaf_rect, Color(0.89, 0.82, 0.67, 0.36))
			draw_rect(leaf_rect, Color(0.45, 0.29, 0.14, 0.30) if kind == 1
				else Color(0.28, 0.39, 0.27, 0.36), false, 1.0)
		draw_rect(card, Color(0.94, 0.88, 0.74, 0.96))
		draw_rect(card, Color(0.46, 0.29, 0.14, 0.66) if kind == 1
			else Color(0.26, 0.36, 0.26, 0.78), false, 1.5)
		draw_rect(card.grow(-3.0), Color(0.62, 0.16, 0.10, 0.20) if kind == 1
			else Color(0.80, 0.62, 0.30, 0.55), false, 1.0)
		var seam := card.position.x + card.size.x * 0.50
		var y: float = card.position.y + 5.0
		while y < card.end.y - 5.0:
			draw_line(Vector2(seam - 4.0, y), Vector2(seam, y + 2.0),
				Color(0.48, 0.30, 0.14, 0.40), 1.0)
			y += 7.0
		if kind == 1:
			# A single stitched spine makes the ordinary sleeve read as a dossier
			# pocket. The central X used by the old empty state looked like a
			# selected/check mark, so the new form depends on fold geometry alone.
			var fold_x := card.end.x - 10.0
			draw_line(Vector2(fold_x, card.position.y + 1.0),
				Vector2(card.end.x - 1.0, card.position.y + 10.0),
				Color(0.48, 0.30, 0.14, 0.48), 1.0)
			draw_line(Vector2(fold_x, card.position.y + 10.0),
				Vector2(card.end.x - 1.0, card.position.y + 10.0),
				Color(0.48, 0.30, 0.14, 0.26), 1.0)
			draw_line(Vector2(seam, card.position.y + 5.0),
				Vector2(seam, card.end.y - 8.0),
				Color(0.56, 0.18, 0.11, 0.34), 1.0)
		else:
			# The spirit sleeve is a miniature ceremonial folio: clipped corners,
			# a double gold rule and a top pendant. No character is needed.
			var top := card.position.y + 5.0
			var crest := PackedVector2Array([
				Vector2(center.x, top), Vector2(center.x + 4.0, top + 4.0),
				Vector2(center.x, top + 8.0), Vector2(center.x - 4.0, top + 4.0),
			])
			draw_colored_polygon(crest, Color(0.72, 0.55, 0.25, 0.72))
			draw_line(Vector2(card.position.x + 4.0, top + 11.0),
				Vector2(card.end.x - 4.0, top + 11.0),
				Color(0.72, 0.55, 0.25, 0.46), 1.0)
			draw_line(Vector2(card.position.x + 7.0, card.end.y - 5.0),
				Vector2(card.end.x - 7.0, card.end.y - 5.0),
				Color(0.72, 0.55, 0.25, 0.38), 1.0)
