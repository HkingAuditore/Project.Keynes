extends PanelContainer
class_name RegimeCharterCard

## 一张体制章程卡：名称、宗旨、国家权能、国策、拥护与反对的阶层、改行按钮。
## 改行是有后果的操作：第一次按下只「备选」并在卡脚写出代价，再按两次才提交。

signal change_requested(regime_id: StringName)
signal armed(regime_id: StringName)

const IconBadgeScene := preload("res://scenes/ui/icon_badge.tscn")
const PERSON_ICON := Vector2(24, 24)

var regime_id := ""
var _state := "available"
var _armed := false
var _switch_summary := ""
var _signature := ""

@onready var _icon: IconBadge = $Margin/Column/Head/Icon
@onready var _status: Label = $Margin/Column/Head/Titles/Status
@onready var _name: Label = $Margin/Column/Head/Titles/Name
@onready var _detail: Label = $Margin/Column/Detail
@onready var _powers_row: Control = $Margin/Column/PowersRow
@onready var _powers: HFlowContainer = $Margin/Column/PowersRow/Powers
@onready var _charter_row: Control = $Margin/Column/CharterRow
@onready var _charter: HFlowContainer = $Margin/Column/CharterRow/Charter
@onready var _support_row: Control = $Margin/Column/SupportRow
@onready var _supporters: HFlowContainer = $Margin/Column/SupportRow/People
@onready var _oppose_row: Control = $Margin/Column/OpposeRow
@onready var _opponents: HFlowContainer = $Margin/Column/OpposeRow/People
@onready var _hint: Label = $Margin/Column/Footer/Hint
@onready var _action: Button = $Margin/Column/Footer/Action


func _ready() -> void:
	_action.pressed.connect(_on_action_pressed)
	_action.focus_exited.connect(disarm)
	for label in [_status, _name]:
		(label as Label).autowrap_mode = TextServer.AUTOWRAP_OFF


func action_button() -> Button:
	return _action


## state: current（现行）/ pending（已排队待生效）/ available（可改行）/ locked（另一项改行待生效）
func set_data(row: Dictionary, state: String, switch_summary: String) -> void:
	regime_id = String(row.get("id", ""))
	_state = state
	_switch_summary = switch_summary
	if state != "available":
		_armed = false
	_icon.set_semantic(StringName(row.get("icon_key", &"country.politics")),
		UITokens.DOSSIER_OXBLOOD if state == "current" else UITokens.DOSSIER_INK_SOFT)
	_name.text = String(row.get("display_name", regime_id))
	_detail.text = String(row.get("detail", ""))
	_detail.visible = not _detail.text.is_empty()
	var signature := str([row.get("powers", []), row.get("charter", []),
		row.get("supporters", []), row.get("opponents", [])])
	if signature != _signature:
		_signature = signature
		_fill_powers(row.get("powers", []))
		_fill_charter(row.get("charter", []))
		_fill_people(_supporters, row.get("supporters", []), UITokens.DOSSIER_VERDIGRIS)
		_fill_people(_opponents, row.get("opponents", []), UITokens.DOSSIER_OXBLOOD)
	_powers_row.visible = _powers.get_child_count() > 0
	_charter_row.visible = _charter.get_child_count() > 0
	_support_row.visible = _supporters.get_child_count() > 0
	_oppose_row.visible = _opponents.get_child_count() > 0
	_apply_state()


func disarm() -> void:
	if not _armed:
		return
	_armed = false
	_apply_state()


func _apply_state() -> void:
	match _state:
		"current":
			_status.text = "现行体制"
			_status.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
		"pending":
			_status.text = "改行待生效"
			_status.add_theme_color_override("font_color", UITokens.DOSSIER_BRASS)
		_:
			_status.text = "可改行"
			_status.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_action.visible = _state != "current"
	_action.disabled = _state != "available"
	_action.text = "确认改行" if _armed else (
		"待生效" if _state == "pending" else "改行此制")
	_action.tooltip_text = "" if _state == "available" else (
		"已排队，将在下一次国家结算后生效。" if _state == "pending"
		else "另一项体制改行尚未生效。")
	($Margin/Column/Footer as Control).visible = _state != "current"
	if _state == "pending":
		_hint.text = "将在下一次国家结算后生效。"
	elif _armed:
		_hint.text = _switch_summary
	else:
		_hint.text = ""
	_hint.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if _armed else UITokens.DOSSIER_INK_MUTED)
	self_modulate = Color(1, 1, 1, 1) if _state != "locked" else Color(1, 1, 1, 0.82)


func _on_action_pressed() -> void:
	if _state != "available":
		return
	if not _armed:
		_armed = true
		_apply_state()
		armed.emit(StringName(regime_id))
		return
	_armed = false
	change_requested.emit(StringName(regime_id))


func _fill_powers(powers: Array) -> void:
	_clear(_powers)
	for raw in powers:
		var power: Dictionary = raw
		# 只列本体制拥有的权能；「没有某项」由改行代价提示说明，不占卡面。
		if not bool(power.get("granted", false)):
			continue
		var chip := UIControlParts.label()
		chip.theme_type_variation = &"PKDossierChip"
		chip.text = String(power.get("label", ""))
		chip.autowrap_mode = TextServer.AUTOWRAP_OFF
		chip.mouse_filter = Control.MOUSE_FILTER_PASS
		chip.tooltip_text = String(power.get("tooltip", ""))
		chip.add_theme_color_override("font_color", UITokens.DOSSIER_VERDIGRIS)
		_powers.add_child(chip)


func _fill_charter(charter: Array) -> void:
	_clear(_charter)
	for raw in charter:
		var entry: Dictionary = raw
		var chip := UIControlParts.label()
		chip.theme_type_variation = &"PKDossierChip"
		chip.text = "%s %s" % [String(entry.get("label", "")),
			String(entry.get("value_text", ""))]
		chip.autowrap_mode = TextServer.AUTOWRAP_OFF
		chip.mouse_filter = Control.MOUSE_FILTER_PASS
		chip.tooltip_text = String(entry.get("tooltip", ""))
		chip.add_theme_color_override("font_color",
			UITokens.DOSSIER_VERDIGRIS if bool(entry.get("beneficial", true))
			else UITokens.DOSSIER_OXBLOOD)
		_charter.add_child(chip)


func _fill_people(host: HFlowContainer, people: Array, ink: Color) -> void:
	_clear(host)
	for raw in people:
		var person: Dictionary = raw
		var item := UIControlParts.h_box_container()
		item.add_theme_constant_override("separation", 3)
		item.mouse_filter = Control.MOUSE_FILTER_PASS
		item.tooltip_text = String(person.get("tooltip", ""))
		var icon := IconBadgeScene.instantiate() as IconBadge
		icon.custom_minimum_size = PERSON_ICON
		icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		item.add_child(icon)
		icon.set_semantic(StringName(person.get("icon", &"population.crowd")),
			UITokens.DOSSIER_INK_SOFT)
		var name := UIControlParts.label()
		name.theme_type_variation = &"PKDossierRowText"
		name.text = String(person.get("name", ""))
		name.autowrap_mode = TextServer.AUTOWRAP_OFF
		item.add_child(name)
		var value := UIControlParts.label()
		value.theme_type_variation = &"PKDossierValue"
		value.text = String(person.get("value_text", ""))
		value.autowrap_mode = TextServer.AUTOWRAP_OFF
		value.add_theme_color_override("font_color", ink)
		item.add_child(value)
		host.add_child(item)


func _clear(host: Node) -> void:
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
