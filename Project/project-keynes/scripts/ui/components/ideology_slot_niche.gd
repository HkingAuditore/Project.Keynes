class_name IdeologySlotNiche
extends PanelContainer

## One compact deck row: either an equipped ideology / national spirit, or the
## single drop target that stands in for all of that kind's empty slots.
##
## Rows replaced card-sized alcoves on purpose. The old board spent a whole
## 172x228 card per slot and reserved one alcove per future technology
## milestone, so a two-slot country saw six empty arches and the owned ideas
## were pushed below the fold. A row costs about 60px, shows the same effect
## lines, and keeps the collection beside the board instead of under it.

signal card_dropped(ideology_id: int, from_location: int, kind: int)
signal drag_hovered(ideology_id: int, kind: int, entered: bool)
signal command_requested(op: String, ideology_id: int)
signal promote_requested(ideology_id: int)

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")

var kind := 1
var empty := true
var occupied_id := -1
var _compact := false
var _data: Dictionary = {}
var _drop_hover := false
var _empty_count := 0

var _row: HBoxContainer
var _icon: TextureRect
var _info: VBoxContainer
var _head: HBoxContainer
var _name: Label
var _level: Label
var _badge: Label
var _support_chip: Label
var _effects: Label
var _actions: HBoxContainer
var _unequip: Button
var _promote: Button
var _empty_label: Label
var _paper_style: StyleBox
var _note_style: StyleBox


func _ready() -> void:
	# The theme's surfaces carry their own padding; the row already owns a tight
	# MarginContainer, so strip it to keep each slot under 50px tall. Occupied
	# rows sit on the clean paper card; empty slots are a pasted torn note, which
	# reads as "stick an idea here" instead of another rigid frame.
	for variation in [&"PKPaperCard", &"PKPaperNote"]:
		var source := get_theme_stylebox("panel", variation)
		if source == null:
			continue
		var style := source.duplicate() as StyleBox
		if style == null:
			continue
		style.content_margin_top = 0.0
		style.content_margin_bottom = 0.0
		style.content_margin_left = 0.0
		style.content_margin_right = 0.0
		if String(variation) == "PKPaperCard":
			_paper_style = style
		else:
			_note_style = style
	_apply_surface()


func _init() -> void:
	theme_type_variation = &"PKPaperCard"
	mouse_filter = Control.MOUSE_FILTER_PASS
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 9)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_right", 7)
	margin.add_theme_constant_override("margin_bottom", 4)
	add_child(margin)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 8)
	margin.add_child(_row)
	_icon = TextureRect.new()
	_icon.custom_minimum_size = Vector2(30, 30)
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_row.add_child(_icon)
	_info = VBoxContainer.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.add_theme_constant_override("separation", 1)
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.add_child(_info)
	_head = HBoxContainer.new()
	_head.add_theme_constant_override("separation", 6)
	_head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_child(_head)
	_name = ArtScript.label("", 14, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name.clip_text = true
	_head.add_child(_name)
	_level = ArtScript.label("", 10, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	_head.add_child(_level)
	_support_chip = ArtScript.label("", 10, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_RIGHT)
	_support_chip.visible = false
	_head.add_child(_support_chip)
	_badge = ArtScript.label("", 10, ArtScript.VERMILION, HORIZONTAL_ALIGNMENT_RIGHT)
	_badge.visible = false
	_head.add_child(_badge)
	# Actions ride the name line so the effect line can use the full row width.
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 4)
	_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_actions.visible = false
	_head.add_child(_actions)
	_unequip = _action_button("撤回")
	_unequip.pressed.connect(func() -> void: command_requested.emit("unequip", occupied_id))
	_actions.add_child(_unequip)
	_promote = _action_button("晋升")
	_promote.pressed.connect(func() -> void: promote_requested.emit(occupied_id))
	_actions.add_child(_promote)
	_effects = ArtScript.label("", 11, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_effects.autowrap_mode = TextServer.AUTOWRAP_OFF
	_effects.clip_text = true
	_effects.max_lines_visible = 1
	_info.add_child(_effects)
	_empty_label = ArtScript.label("", 12, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_LEFT)
	_empty_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.visible = false
	_row.add_child(_empty_label)


func _action_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(50, 20)
	button.add_theme_font_size_override("font_size", 10)
	button.focus_mode = Control.FOCUS_NONE
	return button


func configure(niche_kind: int, is_empty: bool, compact: bool) -> void:
	kind = niche_kind
	empty = is_empty
	_compact = compact
	_icon.visible = not empty
	_info.visible = not empty
	_empty_label.visible = empty
	theme_type_variation = &"PKPaperNote" if empty else &"PKPaperCard"
	_apply_surface()
	_icon.modulate = Color(1, 1, 1, 0.6) if empty else Color.WHITE
	_name.add_theme_font_size_override("font_size", 13 if compact else 14)
	var effect_font := 10 if compact else 11
	_effects.add_theme_font_size_override("font_size", effect_font)
	_support_chip.add_theme_font_size_override("font_size", 9 if compact else 10)
	_level.add_theme_font_size_override("font_size", 9 if compact else 10)
	_badge.add_theme_font_size_override("font_size", 9 if compact else 10)
	_icon.custom_minimum_size = Vector2(26, 26) if compact else Vector2(30, 30)


## Empty slots are collapsed into one row so a fresh country never stares at a
## wall of vacant frames.
func set_empty_count(count: int, milestone := "") -> void:
	_empty_count = count
	var slot_text := "＋ %d 个空槽" % count if count > 1 else "＋ 空槽"
	# A spirit slot is filled by promotion, not by dropping a fresh idea.
	var hint := "拖入或从收藏推行" if kind == 1 else "晋升已推行的道路"
	_empty_label.text = "%s · %s" % [slot_text, hint] if milestone.is_empty() \
		else "%s · %s · %s" % [slot_text, hint, milestone]
	tooltip_text = _empty_label.text


func set_row(data: Dictionary) -> void:
	_data = data
	empty = false
	occupied_id = int(data.get("ideology_id", -1))
	var school_id := String(data.get("school_id", ""))
	_icon.texture = ArtScript.emblem_for(school_id)
	_name.text = String(data.get("display_name", ""))
	var level := clampi(int(data.get("level", 0)), 0, 64)
	var level_label := String(data.get("level_label", ""))
	_level.text = level_label if not level_label.is_empty() else "Lv %d" % level
	_level.add_theme_color_override("font_color", ArtScript.school_color(school_id))
	var effects: PackedStringArray = data.get("effects", PackedStringArray())
	_effects.text = " · ".join(effects)
	var chip := String(data.get("support_chip", ""))
	_support_chip.text = chip
	_support_chip.visible = not chip.is_empty()
	_support_chip.add_theme_color_override("font_color",
		data.get("support_color", ArtScript.INK_MUTED))
	_badge.visible = false
	_badge.text = ""
	var pending := bool(data.get("pending", false))
	var spirit := kind == 2
	if pending:
		_badge.visible = true
		_badge.text = "待生效"
	elif spirit:
		_badge.visible = true
		_badge.text = "精神"
	_actions.visible = not spirit
	var can_unequip := bool(data.get("can_unequip", false)) and not pending
	var can_promote := bool(data.get("can_promote", false)) and not pending
	_unequip.disabled = not can_unequip
	_unequip.tooltip_text = String(data.get("unequip_tooltip", "撤回这条道路"))
	_promote.disabled = not can_promote
	_promote.tooltip_text = String(data.get("promote_tooltip", "晋升为民族精神"))
	tooltip_text = String(data.get("tooltip", ""))


func row_data() -> Dictionary:
	return _data


func is_empty_slot() -> bool:
	return empty


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not empty or not (data is Dictionary):
		return false
	var payload := data as Dictionary
	if not payload.has("ideology_card"):
		return false
	var ok := int(payload.get("location", 0)) != kind
	if ok != _drop_hover:
		_set_drop_hover(ok)
		drag_hovered.emit(int(payload.ideology_card), kind, ok)
	return ok


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_set_drop_hover(false)
	var payload := data as Dictionary
	drag_hovered.emit(int(payload.ideology_card), kind, false)
	card_dropped.emit(int(payload.ideology_card), int(payload.get("location", 0)), kind)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drop_hover:
		_set_drop_hover(false)


func _set_drop_hover(on: bool) -> void:
	_drop_hover = on
	self_modulate = Color(1.08, 1.03, 0.86) if on else Color.WHITE


func _apply_surface() -> void:
	var style := _note_style if empty else _paper_style
	if style != null:
		add_theme_stylebox_override("panel", style)
