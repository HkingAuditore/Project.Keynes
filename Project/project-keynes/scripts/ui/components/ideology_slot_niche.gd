class_name IdeologySlotNiche
extends Control

## Papercut alcove that hosts one equipped ideology (kind 1) or national
## spirit (kind 2). Locked niches show the technology that opens them.
## Dropping a card emits `card_dropped`; the workspace decides the command.

signal card_dropped(ideology_id: int, from_location: int, kind: int)
signal drag_hovered(ideology_id: int, kind: int, entered: bool)

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
const CardScript = preload("res://scripts/ui/components/ideology_card.gd")

var kind := 1
var locked := false
var occupied_id := -1
var _niche: TextureRect
var _caption: Label
var _card: Control
var _glow: ColorRect
var _drop_hover := false


func _init() -> void:
	custom_minimum_size = Vector2(150, 206)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_niche = TextureRect.new()
	_niche.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_niche.stretch_mode = TextureRect.STRETCH_SCALE
	_niche.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_niche.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_niche)
	_glow = ColorRect.new()
	_glow.color = Color(1.0, 0.85, 0.45, 0.0)
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_glow)
	_caption = ArtScript.label("", 11, ArtScript.INK_MUTED)
	_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_caption.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_caption.offset_left = 18
	_caption.offset_right = -18
	_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_caption)


func configure(niche_kind: int, is_locked: bool, caption: String, compact: bool) -> void:
	kind = niche_kind
	locked = is_locked
	custom_minimum_size = CardScript.CARD_SIZE_COMPACT if compact else CardScript.CARD_SIZE
	_niche.texture = ArtScript.texture(
		ArtScript.SPIRIT_NICHE if kind == 2 else ArtScript.SLOT_NICHE)
	_niche.modulate = Color(0.55, 0.52, 0.48, 0.75) if locked else Color.WHITE
	_caption.text = caption
	_caption.add_theme_color_override("font_color",
		Color(0.96, 0.88, 0.74) if kind == 2 else ArtScript.INK_MUTED)
	tooltip_text = caption


func host_card(card: Control) -> void:
	clear_card()
	if card == null:
		return
	_card = card
	occupied_id = int(card.get("ideology_id"))
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card.offset_left = 8
	card.offset_right = -8
	card.offset_top = 10
	card.offset_bottom = -6
	_caption.visible = false


func clear_card() -> void:
	if _card != null and is_instance_valid(_card):
		remove_child(_card)
		_card.queue_free()
	_card = null
	occupied_id = -1
	_caption.visible = true


func hosted_card() -> Control:
	return _card


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	var ok := not locked and data is Dictionary and (data as Dictionary).has("ideology_card") \
		and int((data as Dictionary).get("location", 0)) != kind
	if ok != _drop_hover:
		_drop_hover = ok
		_glow.color.a = 0.22 if ok else 0.0
		if data is Dictionary and (data as Dictionary).has("ideology_card"):
			drag_hovered.emit(int((data as Dictionary).ideology_card), kind, ok)
	return ok


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_drop_hover = false
	_glow.color.a = 0.0
	var payload := data as Dictionary
	drag_hovered.emit(int(payload.ideology_card), kind, false)
	card_dropped.emit(int(payload.ideology_card), int(payload.get("location", 0)), kind)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and _drop_hover:
		_drop_hover = false
		_glow.color.a = 0.0
