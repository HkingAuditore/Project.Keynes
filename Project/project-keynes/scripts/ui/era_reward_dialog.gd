extends Control
class_name EraRewardDialog

signal choice_requested(offer_generation: int, choice_index: int)
signal dismiss_requested()

const ICON_MAP := {
	"wheat": "economy.crop",
	"industry": "economy.building",
	"flask": "economy.building.science",
	"route": "economy.building.transport",
	"landmark": "technology.milestone",
	"people": "family.house",
	"shield": "country.politics",
	"book": "country.technology",
	"gear": "economy.building.factory",
}
const CATEGORY_MAP := {
	"wheat": "粮食方案", "industry": "产业方案", "flask": "科研方案",
	"route": "交通方案", "landmark": "国家方案", "people": "社会方案",
	"shield": "组织方案", "book": "知识方案", "gear": "动员方案",
}

@onready var _grid: GridContainer = %CardGrid
@onready var _status: Label = %Status
@onready var _popup: VBoxContainer = %Popup
@onready var _rewards: PanelContainer = %Rewards
@onready var _close: Button = %Close
@onready var _metrics: GridContainer = %Metrics

var _offer_generation := 0
var _choices: Array[EraRewardChoice] = []
var _offer_open := false
var _pending := false
var _opening: Tween
var _closing := false

func _ready() -> void:
	for child in _grid.get_children():
		if child is EraRewardChoice:
			_choices.append(child as EraRewardChoice)
	for index in _choices.size():
		_choices[index].selected.connect(_on_choice_pressed.bind(index))
	_close.pressed.connect(func() -> void: dismiss_requested.emit())
	for metric: MetricCard in [%GDP, %Treasury, %Population, %Territory]:
		metric.set_compact(true)
		metric.get_node("%TitleLabel").add_theme_font_size_override("font_size", 14)
		metric.get_node("%ValueLabel").add_theme_font_size_override("font_size", 24)
	refresh_overview({})
	get_viewport().size_changed.connect(_layout_popup)

func open_overview(model: Dictionary) -> void:
	refresh_overview(model)
	_show_popup()

func refresh_overview(model: Dictionary) -> void:
	%CountryName.text = String(model.get("country_name", "国家概况"))
	%GDP.set_data("GDP · 本年", String(model.get("gdp", "—")), "本年累计产值", UITokens.HUD_INK)
	%Treasury.set_data("国库货币", String(model.get("cash", "—")), "", UITokens.HUD_INK)
	%Population.set_data("人口", String(model.get("population", "—")), "", UITokens.HUD_INK)
	%Territory.set_data("地块", String(model.get("territory", "—")), "", UITokens.HUD_INK)
	_layout_popup.call_deferred()

func _show_popup() -> void:
	var was_open := visible and not _closing
	_closing = false
	visible = true
	_layout_popup.call_deferred()
	if not was_open:
		if _opening != null and _opening.is_valid():
			_opening.kill()
		_popup.modulate.a = 1.0
		var sheet := _popup.get_node("Overview") as Control
		sheet.pivot_offset = Vector2(_popup.size.x * 0.5, 0.0)
		sheet.modulate.a = 1.0
		sheet.scale = Vector2.ONE
		sheet.rotation = 0.0
		if not UIAnimation.reduced_motion():
			sheet.modulate.a = 0.0
			sheet.scale = Vector2(0.985, 0.94)
			sheet.rotation = deg_to_rad(-0.6)
			_opening = create_tween().set_parallel(true)
			_opening.tween_property(sheet, "modulate:a", 1.0, 0.10)
			_opening.tween_property(sheet, "scale", Vector2.ONE, 0.20).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
			_opening.tween_property(sheet, "rotation", 0.0, 0.20).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func present_offer(offer: Dictionary) -> void:
	_offer_generation = int(offer.get("offer_generation", 0))
	_offer_open = true
	_pending = false
	_close.disabled = false
	_status.text = ""
	_status.visible = false
	_status.modulate = UITokens.ARCHIVE_INK_MUTED
	var alternatives: Array = offer.get("alternatives", [])
	for index in _choices.size():
		var option: Dictionary = alternatives[index] if index < alternatives.size() else {}
		_choices[index].set_option(_presentation_option(option))
	_rewards.visible = true
	_show_popup()
	for index in _choices.size():
		_choices[index].play_reveal(0.035 * index)
	_setup_focus_neighbors()
	for choice in _choices:
		if not choice.option_empty():
			choice.choose_button().grab_focus()
			break

func _presentation_option(option: Dictionary) -> Dictionary:
	if option.is_empty():
		return {}
	var raw_icon := String(option.get("icon_id", "system.unknown"))
	var presented := option.duplicate(true)
	presented["icon_key"] = String(ICON_MAP.get(raw_icon, raw_icon))
	presented["category"] = String(CATEGORY_MAP.get(raw_icon, "时代方案"))
	return presented

func _on_choice_pressed(index: int) -> void:
	if _pending or index < 0 or index >= _choices.size() or _choices[index].option_empty():
		return
	show_pending()
	for choice in _choices.size():
		_choices[choice].mark_selected(choice == index)
	choice_requested.emit(_offer_generation, index)

func _setup_focus_neighbors() -> void:
	for index in _choices.size():
		var button := _choices[index].choose_button()
		button.focus_neighbor_top = button.get_path_to(_close if index == 0 else _choices[index - 1].choose_button())
		button.focus_neighbor_bottom = button.get_path_to(_close if index == _choices.size() - 1 else _choices[index + 1].choose_button())
	_close.focus_neighbor_bottom = _close.get_path_to(_choices[0].choose_button())

func _layout_popup() -> void:
	if not is_node_ready():
		return
	var viewport_size := get_viewport_rect().size
	var width := minf(UITokens.ERA_POPUP_WIDTH, maxf(280.0, viewport_size.x - 32.0))
	_metrics.columns = 4 if width >= 520.0 else 2
	var top := UITokens.ERA_BADGE_OPEN_Y + UITokens.ERA_BADGE_SIZE + UITokens.ERA_POPUP_GAP
	var available := maxf(150.0, viewport_size.y - top - 16.0)
	var overview_height := (_popup.get_node("Overview") as Control).get_combined_minimum_size().y
	var height := overview_height
	if _offer_open:
		var reward_height := _grid.get_combined_minimum_size().y + 44.0
		if _status.visible:
			reward_height += _status.get_combined_minimum_size().y + 6.0
		height = minf(available, overview_height + 12.0 + reward_height)
	_popup.position = Vector2((viewport_size.x - width) * 0.5, top)
	_popup.size = Vector2(width, height)

func show_error(message: String) -> void:
	_pending = false
	_close.disabled = false
	for choice in _choices:
		choice.set_pending(true)
	_status.text = "奖励提交未完成：%s" % message
	_status.modulate = UITokens.RISK
	_status.visible = true
	_layout_popup.call_deferred()

func show_pending() -> void:
	_pending = true
	_close.disabled = true
	for choice in _choices:
		choice.set_pending(true)
	_status.text = "正在确认奖励……"
	_status.modulate = UITokens.ARCHIVE_INK_MUTED
	_status.visible = true
	_layout_popup.call_deferred()

func close_offer() -> void:
	_offer_open = false
	_pending = false
	_offer_generation = 0
	_rewards.visible = false
	_status.visible = false
	_close.disabled = false
	_layout_popup.call_deferred()

func close_overview(immediate: bool = false) -> void:
	if _pending:
		return
	close_offer()
	if immediate:
		if _opening != null and _opening.is_valid():
			_opening.kill()
		visible = false
		_closing = false
		return
	if _closing:
		return
	if UIAnimation.reduced_motion() or not visible:
		visible = false
		return
	_closing = true
	if _opening != null and _opening.is_valid():
		_opening.kill()
	_opening = create_tween()
	_opening.tween_property(_popup, "modulate:a", 0.0, 0.10)
	_opening.tween_callback(func() -> void:
		visible = false
		_closing = false)

func is_offer_open() -> bool:
	return visible and _offer_open

func _input(event: InputEvent) -> void:
	if not visible or _closing:
		return
	if event.is_action_pressed("player_cancel") or event.is_action_pressed("ui_cancel"):
		if not _pending:
			dismiss_requested.emit()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# 纸徽本身保留点击开关；其余空白点击收起并消费，避免误选地图。
		var badge_rect := Rect2(Vector2(get_viewport_rect().size.x * 0.5 - UITokens.ERA_BADGE_SIZE * 0.5, 0), Vector2(UITokens.ERA_BADGE_SIZE, UITokens.ERA_BADGE_SIZE + UITokens.ERA_BADGE_OPEN_Y))
		if not _popup.get_global_rect().has_point(event.position) and not badge_rect.has_point(event.position):
			if not _pending:
				dismiss_requested.emit()
			get_viewport().set_input_as_handled()
