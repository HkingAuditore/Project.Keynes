extends Control
class_name RegimeWorkspace

## 体制页：每种体制一张章程卡并排比较（现行体制排第一）。工作区只发出玩家意图；
## Country runtime 是权威，提交结果经政治视图模型回报。
signal regime_change_requested(regime_id: StringName)

const CardScene := preload("res://scenes/ui/regime_charter_card.tscn")
## 低于此宽度改为单列。
const TWO_COLUMN_WIDTH := 720.0

var _model: Dictionary = {}
var _player_controller = null
var _compact := false
var _cards: Dictionary = {}
var _card_order := PackedStringArray()
var _pending_id := ""
var _pending_day := -1
var _status_text := ""
var _status_error := false

@onready var _grid: GridContainer = $Scroll/Column/Cards
@onready var _empty: Label = $Scroll/Column/Empty
@onready var _status: Label = $Scroll/Column/Status


func _ready() -> void:
	resized.connect(_update_columns)
	if not _model.is_empty():
		_apply_model()
	call_deferred("_focus_initial_action")


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_model(model: Dictionary) -> void:
	_model = model
	if is_node_ready():
		_apply_model()


func refresh_model(model: Dictionary) -> void:
	set_model(model)


func set_compact(compact: bool) -> void:
	_compact = compact
	if is_node_ready():
		_update_columns()


func focus_initial_action() -> void:
	_focus_initial_action()


func _regime_model() -> Dictionary:
	var political: Dictionary = _model.get("politics", _model)
	if political.has("regime") and political.get("regime") is Dictionary:
		return political.get("regime", {})
	return political


func _apply_model() -> void:
	var regime := _regime_model()
	var rows: Array = regime.get("options", regime.get("definitions", []))
	var current_id := String(regime.get("current_id", regime.get("regime_id", "")))
	var day := int(_model.get("current_day", -1))
	if not _pending_id.is_empty():
		if _pending_id == current_id:
			_pending_id = ""
			_set_status("", false)
		elif day >= 0 and _pending_day >= 0 and day > _pending_day + 1:
			_pending_id = ""
			_set_status("体制改行未能生效，请重试。", true)
	if not String(regime.get("pending_id", "")).is_empty():
		_pending_id = String(regime.get("pending_id", ""))
	var available := bool(regime.get("available", not rows.is_empty()))
	_empty.visible = not available or rows.is_empty()
	_empty.text = String(regime.get("reason", "体制目录尚未就绪。"))
	_grid.visible = not _empty.visible
	if _empty.visible:
		return
	# 现行体制排第一，其余保持目录顺序。
	var ordered: Array = []
	var current_row: Dictionary = {}
	for raw in rows:
		var row: Dictionary = raw
		if String(row.get("id", "")) == current_id:
			current_row = row
			ordered.push_front(row)
		else:
			ordered.append(row)
	var order := PackedStringArray()
	for row in ordered:
		order.append(String((row as Dictionary).get("id", "")))
	if order != _card_order:
		_rebuild_cards(order)
	for raw in ordered:
		var row: Dictionary = raw
		var id := String(row.get("id", ""))
		var state := "current" if id == current_id else (
			"pending" if id == _pending_id else (
			"locked" if not _pending_id.is_empty() or not bool(row.get("selectable", true))
			else "available"))
		(_cards[id] as RegimeCharterCard).set_data(row, state,
			_switch_summary(current_row, row))
	_update_columns()


func _rebuild_cards(order: PackedStringArray) -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_cards.clear()
	for id in order:
		var card := CardScene.instantiate() as RegimeCharterCard
		_grid.add_child(card)
		card.change_requested.connect(_on_change_requested)
		card.armed.connect(_on_card_armed)
		_cards[id] = card
	_card_order = order


## 卡脚「确认改行」时写出的代价：失去 / 获得的权能与会不满的阶层。
func _switch_summary(current: Dictionary, target: Dictionary) -> String:
	var lost := PackedStringArray()
	var gained := PackedStringArray()
	var now := {}
	for raw in current.get("powers", []):
		now[String((raw as Dictionary).get("key", ""))] = bool((raw as Dictionary).get("granted", false))
	for raw in target.get("powers", []):
		var power: Dictionary = raw
		var had := bool(now.get(String(power.get("key", "")), false))
		if had and not bool(power.get("granted", false)):
			lost.append(String(power.get("label", "")))
		elif not had and bool(power.get("granted", false)):
			gained.append(String(power.get("label", "")))
	var parts := PackedStringArray()
	if not lost.is_empty():
		parts.append("失去%s" % "、".join(lost))
	if not gained.is_empty():
		parts.append("获得%s" % "、".join(gained))
	var unhappy := PackedStringArray()
	for raw in target.get("opponents", []):
		unhappy.append(String((raw as Dictionary).get("name", "")))
	if not unhappy.is_empty():
		parts.append("%s不满" % "、".join(unhappy))
	var head := "；".join(parts)
	return "%s。下次国家结算后生效。" % head if not head.is_empty() \
		else "下次国家结算后生效。"


func _on_card_armed(regime_id: StringName) -> void:
	for id in _cards.keys():
		if String(id) != String(regime_id):
			(_cards[id] as RegimeCharterCard).disarm()


func _on_change_requested(regime_id: StringName) -> void:
	regime_change_requested.emit(regime_id)
	if _player_controller == null or not _player_controller.has_method("request_command"):
		return
	var result: Dictionary = _player_controller.request_command(&"politics.regime.set", {
		"regime_id": regime_id,
	})
	if bool(result.get("ok", false)):
		_pending_id = String(regime_id)
		_pending_day = int(_model.get("current_day", -1))
		_set_status("", false)
	else:
		_set_status(String(result.get("message", "体制改行未被接受。")), true)
	_apply_model()


func _set_status(text: String, is_error: bool) -> void:
	_status_text = text
	_status_error = is_error
	if _status == null:
		return
	_status.text = text
	_status.visible = not text.is_empty()
	_status.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if is_error else UITokens.DOSSIER_INK_MUTED)


func _update_columns() -> void:
	if _grid == null:
		return
	# 只按实际宽度切列：紧凑档（矮视口）往往正是最需要并排比较的时候。
	var columns := 1 if size.x < TWO_COLUMN_WIDTH else 2
	columns = mini(columns, maxi(1, _cards.size()))
	if _grid.columns != columns:
		_grid.columns = columns


func _focus_initial_action() -> void:
	if not is_visible_in_tree():
		return
	var owner := get_viewport().gui_get_focus_owner()
	if owner != null and is_ancestor_of(owner):
		return
	for id in _card_order:
		var button := (_cards[id] as RegimeCharterCard).action_button()
		if button.visible and not button.disabled:
			button.grab_focus()
			return
