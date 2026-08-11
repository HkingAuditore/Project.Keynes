extends PanelContainer
class_name TechnologyDetailCard

const RelationRowScene := preload("res://scenes/ui/technology_relation_row.tscn")

signal enqueue_requested(index: int)
signal remove_requested(index: int)

const STATE_NAMES := ["未知", "已揭示 · 前置未完成", "可研究", "研究队列中", "待生效", "已掌握"]

var _index := -1
var _state := 0
var _submitted := false
var _accent: Color = UITokens.ACCENT
var _header_icon: IconBadge
var _name: Label
var _state_label: Label
var _chips: BadgeRow
var _gauge: RadialGauge
var _effects: InsightList
var _body: VBoxContainer
var _detail_block: VBoxContainer
var _prerequisite_title: Label
var _prerequisites: VBoxContainer
var _successor_title: Label
var _successors: VBoxContainer
var _action: Button
var _placeholder: Label


func _ready() -> void:
	if _body != null:
		return
	_body = get_node_or_null("Scroll/Body") as VBoxContainer
	_header_icon = get_node_or_null("Scroll/Body/Header/HeaderIcon") as IconBadge
	_name = get_node_or_null("Scroll/Body/Header/Titles/NameLabel") as Label
	_state_label = get_node_or_null("Scroll/Body/Header/Titles/StateLabel") as Label
	_placeholder = get_node_or_null("Scroll/Body/Placeholder") as Label
	_detail_block = get_node_or_null("Scroll/Body/DetailBlock") as VBoxContainer
	_chips = get_node_or_null("Scroll/Body/DetailBlock/Chips") as BadgeRow
	_gauge = get_node_or_null("Scroll/Body/DetailBlock/Gauge") as RadialGauge
	_effects = get_node_or_null("Scroll/Body/DetailBlock/Effects") as InsightList
	_prerequisite_title = get_node_or_null("Scroll/Body/DetailBlock/PrerequisiteTitle") as Label
	_prerequisites = get_node_or_null("Scroll/Body/DetailBlock/Prerequisites") as VBoxContainer
	_successor_title = get_node_or_null("Scroll/Body/DetailBlock/SuccessorTitle") as Label
	_successors = get_node_or_null("Scroll/Body/DetailBlock/Successors") as VBoxContainer
	_action = get_node_or_null("Scroll/Body/DetailBlock/Action") as Button
	if _body == null or _header_icon == null or _name == null \
			or _state_label == null or _placeholder == null \
			or _detail_block == null or _chips == null or _gauge == null \
			or _effects == null or _prerequisite_title == null \
			or _prerequisites == null or _successor_title == null \
			or _successors == null or _action == null:
		push_error("TechnologyDetailCard 必须通过 technology_detail_card.tscn 实例化。")
		return
	_header_icon.set_semantic(&"country.technology", UITokens.CLIMATE)
	_action.pressed.connect(_on_action_pressed)
	show_empty()


func show_empty() -> void:
	if _body == null:
		_ready()
	_index = -1
	_state = 0
	_submitted = false
	_header_icon.set_semantic(&"country.technology", UITokens.TEXT_MUTED)
	_name.text = "研究档案"
	_state_label.text = ""
	_placeholder.visible = true
	_placeholder.text = "在科技树中选择一个节点查看它的成本、效果与前后置链条。"
	_detail_block.visible = false


func show_unknown() -> void:
	if _body == null:
		_ready()
	_index = -1
	_state = 0
	_submitted = false
	_header_icon.set_semantic(&"technology.state.unknown", UITokens.TEXT_MUTED)
	_name.text = "未知科技"
	_state_label.text = STATE_NAMES[0]
	_placeholder.visible = true
	_placeholder.text = "完成任意一项直接前置后，这个节点的名称、成本与效果才会揭示。"
	_detail_block.visible = false


func show_technology(index: int, definition: Dictionary, state: int, fraction: float,
		accent: Color, era_name: String, domain_name: String,
		relations: Dictionary) -> void:
	if _body == null:
		_ready()
	_index = index
	_state = state
	_accent = accent
	_placeholder.visible = false
	_detail_block.visible = true
	_submitted = false
	_header_icon.set_semantic(IconCatalog.technology_domain_semantic(
		String(definition.get("domain_id", ""))), accent)
	_header_icon.tooltip_text = "%s · %s" % [domain_name, era_name]
	_name.text = String(definition.get("display_name", ""))
	_state_label.text = STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]
	_state_label.add_theme_color_override("font_color", _state_colour(state))
	var chips: Array = [
		{"text": era_name, "accent": UITokens.BRASS_HIGHLIGHT},
		{"text": "成本 %s" % UITokens.format_compact_number_cn(
			float(definition.get("cost_points", 0)), 1), "accent": UITokens.CLIMATE},
	]
	if bool(definition.get("is_milestone", false)):
		chips.append({"text": "时代里程碑", "accent": UITokens.WARN})
	elif bool(definition.get("is_era_key", false)):
		chips.append({"text": "时代关键", "accent": UITokens.RESOURCE})
	var route_tags: PackedStringArray = definition.get("route_tags", PackedStringArray())
	var route_names: PackedStringArray = definition.get(
		"route_display_names", PackedStringArray())
	for route_index in range(route_tags.size()):
		var route_name := String(route_names[route_index]) \
			if route_index < route_names.size() else String(route_tags[route_index])
		chips.append({
			"text": "路线 · %s" % route_name,
			"accent": UITokens.RESOURCE,
		})
	_chips.set_badges(chips)
	_gauge.set_data("研究进度", clampf(fraction, 0.0, 1.0),
		_progress_caption(definition, fraction, state), accent)
	var insight_items: Array = relations.get("condition_items", [])
	insight_items.append_array(_effect_items(definition))
	_effects.set_items(insight_items)
	var required := int(definition.get("milestone_required_count", 0))
	var prerequisites: Array = relations.get("prerequisites", [])
	if required > 0:
		_prerequisite_title.text = "里程碑候选（任选 %d 项）" % required
	else:
		_prerequisite_title.text = "硬前置"
	_prerequisite_title.visible = not prerequisites.is_empty()
	_fill_relation_rows(_prerequisites, prerequisites)
	var successors: Array = relations.get("successors", [])
	_successor_title.text = "网络关系"
	_successor_title.visible = not successors.is_empty()
	_fill_relation_rows(_successors, successors)
	_apply_action(state)


# Daily ticks take this path: gauge value, state text and the action button only.
func update_progress(state: int, fraction: float, definition: Dictionary) -> void:
	if _index < 0 or _detail_block == null or not _detail_block.visible:
		return
	_state = state
	_state_label.text = STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]
	_state_label.add_theme_color_override("font_color", _state_colour(state))
	_gauge.set_data("研究进度", clampf(fraction, 0.0, 1.0),
		_progress_caption(definition, fraction, state), _accent)
	if not _submitted:
		_apply_action(state)


func _progress_caption(definition: Dictionary, fraction: float, state: int) -> String:
	if state >= 5:
		return "已掌握"
	if state <= 1:
		return "尚未开始"
	var cost := float(definition.get("cost_points", 0))
	var remaining := maxf(0.0, cost * (1.0 - clampf(fraction, 0.0, 1.0)))
	return "还需 %s" % UITokens.format_compact_number_cn(remaining, 1)


func _effect_items(definition: Dictionary) -> Array:
	var items: Array = []
	for effect_value in definition.get("content_effects", []):
		var effect: Dictionary = effect_value
		var kind := String(effect.get("kind", ""))
		var id := String(effect.get("id", ""))
		var display_name := String(effect.get("display_name", id))
		var attribute := String(effect.get("attribute", ""))
		var text := ""
		match kind:
			"building": text = "解锁建筑 · %s" % display_name
			"good":
				text = ("解锁物资 · %s" if attribute == "production_access" \
					else "生产配方关联 · %s") % display_name
			"resource": text = "可利用资源 · %s" % display_name
			"class": text = "阶层岗位 · %s" % display_name
			"terrain": text = "地形专长 · %s" % display_name
			"landform": text = "地貌专长 · %s" % display_name
			"climate": text = "气候专长 · %s" % display_name
			"tile": text = "地块条件 · %s" % display_name
		if not text.is_empty():
			items.append({
				"text": text,
				"icon": &"economy.building" if kind == "building" else &"metric.technology",
				"accent": UITokens.RESOURCE,
			})
	for term_value in definition.get("modifier_terms", []):
		var term: Dictionary = term_value
		var stat := String(term.get("stat", ""))
		var value := int(round(float(term.get("value", 0.0)) * 100.0))
		var text := ""
		if stat.begins_with("country.output.building."):
			text = "%s产出 +%d%%" % [String(term.get(
				"subject_display_name", "指定建筑")), value]
		elif stat.begins_with("country.output.family."):
			text = "%s产出 +%d%%" % [String(term.get(
				"subject_display_name", "相关建筑工艺")), value]
		elif stat.begins_with("country.climate."):
			text = "针对性气候损失调整 %d%%" % value
		elif not stat.is_empty():
			text = "定向国家能力 +%d%%" % value
		if not text.is_empty():
			items.append({"text": text, "icon": &"metric.technology", "accent": UITokens.CLIMATE})
	if not items.is_empty():
		return items
	var summary := String(definition.get("effect_summary", ""))
	for chunk in summary.replace("，", "、").split("、", false):
		var text := String(chunk).strip_edges()
		if text.is_empty():
			continue
		var unlocks := text.begins_with("解锁") or text.begins_with("开启") \
			or text.begins_with("完成")
		items.append({
			"text": text,
			"icon": &"economy.building" if unlocks else &"metric.technology",
			"accent": UITokens.RESOURCE if unlocks else UITokens.CLIMATE,
		})
	return items


func _fill_relation_rows(host: VBoxContainer, entries: Array) -> void:
	for child in host.get_children():
		host.remove_child(child)
		child.queue_free()
	for entry in entries:
		var data: Dictionary = entry
		var row := RelationRowScene.instantiate() as HBoxContainer
		var marker := row.get_node("Marker") as Label
		var state := int(data.get("state", 0))
		IconButton.apply_to_label(marker, IconCatalog.technology_state_semantic(state), 11)
		marker.add_theme_color_override("font_color", _state_colour(state))
		var label := row.get_node("Label") as Label
		label.text = String(data.get("name", "未知科技"))
		label.add_theme_color_override("font_color",
			UITokens.TEXT_MAIN if state >= 1 else UITokens.TEXT_FAINT)
		host.add_child(row)


func _apply_action(state: int) -> void:
	match state:
		2:
			_action.visible = true
			_action.disabled = false
			_action.text = "加入研究队列"
		3:
			_action.visible = true
			_action.disabled = false
			_action.text = "移出研究队列"
		1:
			_action.visible = true
			_action.disabled = true
			_action.text = "前置尚未完成"
		_:
			_action.visible = state < 4
			_action.disabled = true
			_action.text = "无可用操作"


# Research commands land on the next country day, so the button states the delay
# instead of pretending the queue already changed.
func mark_submitted() -> void:
	if _action == null:
		return
	_submitted = true
	_action.disabled = true
	_action.text = "已提交 · 次日生效"


func _on_action_pressed() -> void:
	if _index < 0:
		return
	if _state == 3:
		remove_requested.emit(_index)
		return
	if _state == 2:
		enqueue_requested.emit(_index)




func _state_colour(state: int) -> Color:
	match state:
		2:
			return UITokens.BRASS_HIGHLIGHT
		3:
			return UITokens.WATER.lerp(UITokens.TEXT_MAIN, 0.30)
		4:
			return UITokens.WARN
		5:
			return UITokens.GOOD
		_:
			return UITokens.TEXT_FAINT
