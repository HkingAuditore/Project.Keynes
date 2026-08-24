extends PanelContainer
class_name IdeologyIdeaRow

signal equip_requested(ideology_id: int)
signal unequip_requested(ideology_id: int)
signal promote_requested(ideology_id: int)

var _ideology_id := -1

var _name: Label
var _slots: BadgeRow
var _gauge: GaugeBar
var _effects: InsightList
var _notes: BadgeRow
var _detail: Label
var _equip: Button
var _unequip: Button
var _promote: Button


func _ready() -> void:
	_bind_nodes()


func _bind_nodes() -> void:
	if _name != null:
		return
	_name = %Name
	_slots = %Slots
	_gauge = %Gauge
	_effects = %Effects
	_notes = %Notes
	_detail = %Detail
	_equip = %Equip
	_unequip = %Unequip
	_promote = %Promote


func set_row(data: Dictionary) -> void:
	_bind_nodes()
	if _name == null:
		return
	_ideology_id = int(data.get("ideology_id", -1))
	_name.text = String(data.get("display_name", "未命名道路"))
	_slots.set_badges(data.get("slot_badges", []))
	_gauge.set_data(
		String(data.get("gauge_title", "理解度")),
		float(data.get("gauge_ratio", 0.0)),
		"",
		"",
		data.get("gauge_accent", UITokens.ACCENT),
		-1.0,
		String(data.get("gauge_subtitle", "")),
		String(data.get("gauge_value", "")))
	var effect_items: Array = data.get("effects", [])
	_effects.visible = not effect_items.is_empty()
	if not effect_items.is_empty():
		_effects.set_items(effect_items)
	var extra_badges: Array = data.get("notes", [])
	_notes.visible = not extra_badges.is_empty()
	if not extra_badges.is_empty():
		_notes.set_badges(extra_badges)
	_detail.text = String(data.get("detail", ""))
	_detail.tooltip_text = String(data.get("tooltip", ""))
	_equip.visible = bool(data.get("equip_visible", false))
	_equip.disabled = bool(data.get("equip_disabled", true))
	_unequip.visible = bool(data.get("unequip_visible", false))
	_unequip.disabled = bool(data.get("unequip_disabled", true))
	_promote.visible = bool(data.get("promote_visible", false))
	_promote.disabled = bool(data.get("promote_disabled", true))


func _on_equip_pressed() -> void:
	equip_requested.emit(_ideology_id)


func _on_unequip_pressed() -> void:
	unequip_requested.emit(_ideology_id)


func _on_promote_pressed() -> void:
	promote_requested.emit(_ideology_id)
