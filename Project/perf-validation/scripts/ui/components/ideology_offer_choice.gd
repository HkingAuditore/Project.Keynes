extends PanelContainer
class_name IdeologyOfferChoice

signal chosen()

var _summary := ""

var _icon: IconBadge
var _name: Label
var _flavor: Label
var _effects: InsightList
var _badges: BadgeRow
var _choose: Button


func _ready() -> void:
	_bind_nodes()


func _bind_nodes() -> void:
	if _name != null:
		return
	_icon = %Icon
	_name = %Name
	_flavor = %Flavor
	_effects = %Effects
	_badges = %Badges
	_choose = %Choose


func set_card(data: Dictionary) -> void:
	_bind_nodes()
	if _name == null:
		return
	_name.text = String(data.get("display_name", "未命名道路"))
	_flavor.text = String(data.get("detail", ""))
	_flavor.visible = not _flavor.text.is_empty()
	_icon.set_semantic(StringName(data.get("icon_key", "country.politics")),
		UITokens.ACCENT)
	var effects: Array = data.get("effects", [])
	_effects.visible = not effects.is_empty()
	if not effects.is_empty():
		_effects.set_items(effects)
	var badges: Array = data.get("badges", [])
	_badges.visible = not badges.is_empty()
	if not badges.is_empty():
		_badges.set_badges(badges)
	_summary = "%s：%s" % [_name.text, String(data.get("summary", _flavor.text))]
	tooltip_text = _summary
	_choose.tooltip_text = "选定后进入国家收藏，装备后才会生效。"


func summary_text() -> String:
	return _summary


func _on_choose_pressed() -> void:
	chosen.emit()
