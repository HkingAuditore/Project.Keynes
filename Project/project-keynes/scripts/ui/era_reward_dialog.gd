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
@onready var _alert_icons: GridContainer = %AlertIcons

var _offer_generation := 0
var _choices: Array[EraRewardChoice] = []
var _alert_key_to_node := {
	"unemployment": "Unemployment",
	"survival": "Survival",
	"consumer_shortage": "ConsumerShortage",
	"industrial_shortage": "IndustrialShortage",
	"vacancies": "Vacancies",
}
var _last_alert_keys: Dictionary = {}
var _alert_keys_ready := false
var _alert_reveal: Tween
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
	for metric: MetricCard in [%GDP, %PerCapitaGDP, %CPI, %PPI, %Territory,
			%Satisfaction, %LivingStandard]:
		metric.set_compact(true)
		metric.set_compact_icon_label_presentation(true)
		var metric_margin := metric.get_node("Margin") as MarginContainer
		metric_margin.add_theme_constant_override("margin_top", 2)
		metric_margin.add_theme_constant_override("margin_bottom", 2)
		(metric.get_node("Margin/Row/IconBadge") as Control).custom_minimum_size = Vector2(22, 24)
		metric.get_node("%TitleLabel").add_theme_font_size_override("font_size", 13)
		metric.get_node("%ValueLabel").add_theme_font_size_override("font_size", 22)
	# 指标与问题之间只留一条压淡的笺线，不再单独包一层卡片。
	(%ProblemRule as ColorRect).color = Color(UITokens.DOSSIER_RULE, 0.30)
	# 问题条目沿用指标卡的字阶：纸贴图标配一行墨字，纸贴保持原色不叠色。
	for key in _alert_key_to_node:
		var chip := _alert_icons.get_node(String(_alert_key_to_node[key])) as Control
		(chip.get_node("Text") as Label).add_theme_color_override(
			"font_color", UITokens.DOSSIER_OXBLOOD)
	(%Clear.get_node("Text") as Label).add_theme_color_override(
		"font_color", UITokens.DOSSIER_INK_MUTED)
	get_viewport().size_changed.connect(_layout_popup)


func open_overview(model: Dictionary) -> void:
	refresh_overview(model)
	_show_popup()

func refresh_overview(model: Dictionary) -> void:
	%CountryName.text = String(model.get("country_name", "国家概况"))
	%GDP.set_data("年度 GDP", String(model.get("gdp", "—")),
		String(model.get("gdp_tooltip", "本年累计产值")), UITokens.HUD_INK, "", "hud.country.economy")
	%PerCapitaGDP.set_data("人均 GDP", String(model.get("per_capita_gdp", "—")),
		String(model.get("per_capita_gdp_tooltip", "年度 GDP ÷ 全国人口")),
		UITokens.HUD_INK, "", "hud.country.economy")
	%Territory.set_data("地块", String(model.get("territory", "—")),
		String(model.get("territory_tooltip", "当前国家持有的有效地块数")),
		UITokens.ARCHIVE_INK_MUTED, "", "country.world")
	%CPI.set_data("CPI", String(model.get("cpi", "—")),
		String(model.get("cpi_tooltip", "居民需求加权的消费价格指数")),
		UITokens.ACCENT, "", "metric.goods")
	%PPI.set_data("PPI", String(model.get("ppi", "—")),
		String(model.get("ppi_tooltip", "生产供给加权的生产者价格指数")),
		UITokens.ARCHIVE_INK_MUTED, "", "economy.building.factory")
	%Satisfaction.set_data("人民平均满意度", String(model.get("satisfaction", "—")),
		String(model.get("satisfaction_tooltip", "全国人口加权的满意度均值")),
		UITokens.ECO, "", "population.heart")
	%LivingStandard.set_data("人民生活水平", String(model.get("living_standard", "—")),
		String(model.get("living_standard_tooltip", "按人口加权的生活水平等级均值")),
		UITokens.ECO, "", "population.living.comfortable")
	_update_alerts(model.get("alerts", []))
	_layout_popup.call_deferred()


func _update_alerts(alerts: Array) -> void:
	if _alert_reveal != null and _alert_reveal.is_valid():
		_alert_reveal.kill()
	var visible_alerts: Dictionary = {}
	var added: Array[String] = []
	for alert: Dictionary in alerts:
		var key := String(alert.get("key", ""))
		if not _alert_key_to_node.has(key):
			continue
		visible_alerts[key] = true
		var chip := _alert_icons.get_node(String(_alert_key_to_node[key])) as Control
		var label_text := String(alert.get("label", key))
		var icon := chip.get_node("Icon") as IconBadge
		var icon_key := StringName(alert.get("icon", "situation.food_shortage"))
		if icon.icon_key != icon_key:
			icon.set_semantic(icon_key)
		var text := chip.get_node("Text") as Label
		if text.text != label_text:
			text.text = label_text
		chip.tooltip_text = String(alert.get("tooltip", label_text))
		chip.modulate.a = 1.0
		chip.visible = true
		if _alert_keys_ready and visible and not _last_alert_keys.has(key):
			added.append(key)
	for key in _alert_key_to_node:
		if visible_alerts.has(key):
			continue
		var chip := _alert_icons.get_node(String(_alert_key_to_node[key])) as Control
		chip.visible = false
		chip.tooltip_text = ""
		chip.modulate.a = 1.0
	var clear_chip := %Clear as Control
	var clear_icon := clear_chip.get_node("Icon") as IconBadge
	if clear_icon.icon_key != &"control.checkbox_checked":
		clear_icon.set_semantic(&"control.checkbox_checked")
	clear_chip.tooltip_text = "目前没有达到提示阈值的突出问题。"
	clear_chip.visible = visible_alerts.is_empty()
	clear_chip.modulate.a = 1.0
	if not added.is_empty():
		_reveal_alerts(added)
	_last_alert_keys = visible_alerts
	_alert_keys_ready = true


## 新问题只用逐条淡入提示，不再给整块加边框，避免和卡片其余内容割裂。
func _reveal_alerts(keys: Array[String]) -> void:
	if UIAnimation.reduced_motion():
		return
	_alert_reveal = create_tween().set_parallel(true).set_trans(Tween.TRANS_SINE) \
		.set_ease(Tween.EASE_OUT)
	var index := 0
	for key in keys:
		var chip := _alert_icons.get_node_or_null(String(_alert_key_to_node[key])) as Control
		if chip == null:
			continue
		chip.modulate.a = 0.0
		_alert_reveal.tween_property(chip, "modulate:a", 1.0, 0.16).set_delay(0.04 * index)
		index += 1

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
	_metrics.columns = 3 if width >= 480.0 else 2
	_alert_icons.columns = _metrics.columns
	# 指标与问题共用同一套等分列宽：问题行才会和上面的三列严格对齐。
	# 扣掉纸面与内边距的固定开销，等分后列宽合起来正好等于弹窗宽度，不再把弹窗顶宽。
	var inset := float(_metrics.get_theme_constant("h_separation")) \
		* float(_metrics.columns - 1)
	var surface := _popup.get_node("Overview") as Control
	var style := surface.get_theme_stylebox("panel")
	if style != null:
		inset += style.get_content_margin(SIDE_LEFT) + style.get_content_margin(SIDE_RIGHT)
	var sheet := _popup.get_node("Overview/Margin") as MarginContainer
	inset += float(sheet.get_theme_constant("margin_left") + sheet.get_theme_constant("margin_right"))
	var cell_width := (width - inset) / float(_metrics.columns)
	for metric in _metrics.get_children():
		(metric as Control).custom_minimum_size.x = cell_width
	for key in _alert_key_to_node:
		var chip := _alert_icons.get_node(String(_alert_key_to_node[key])) as Control
		chip.custom_minimum_size.x = cell_width
	(%Clear as Control).custom_minimum_size.x = cell_width
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
