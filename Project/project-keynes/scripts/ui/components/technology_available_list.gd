extends DossierChart
class_name TechnologyAvailableList

## 可研究清单的自绘画布：研究中 / 可立即研究（按领域）/ 待生效 三段卡片。
## 只有可见集合变化时重排卡片几何；每日进度只重绘可视区域，不创建节点。
## 只呈现状态 ≥ 2 的科技，不泄露未知科技。

signal technology_selected(index: int)
signal technology_activated(index: int)
signal show_in_tree_requested(index: int)
signal enqueue_requested(index: int)
signal remove_requested(index: int)

const POINT_SCALE := 1000.0
const Art := preload("res://scripts/ui/components/technology_tree_art.gd")
const EffectsLayer := preload("res://scripts/ui/components/technology_effects_layer.gd")
const TechnologyEffectTextScript := preload(
	"res://scripts/ui/components/technology_effect_text.gd")
const CARD_HEIGHT := 60.0
const CARD_GAP := 8.0
const MIN_CARD_WIDTH := 300.0
const MAX_COLUMNS := 3
const SECTION_HEIGHT := 34.0
const GROUP_HEIGHT := 28.0
const PAD := 14.0
const ACTION_WIDTH := 56.0
const ACTION_HEIGHT := 24.0
const TREE_BUTTON := 22.0

var _definitions: Array = []
var _domains: Array = []
var _era_names: Dictionary = {}
var _research_definition_count := 0
var _states := PackedInt32Array()
var _progress := PackedInt64Array()
var _queue_order: Dictionary = {}
var _eta: Dictionary = {}
var _selected := -1
var _signature := ""
var _researchable_count := 0
var _queued_count := 0
var _pending_count := 0
var _sections: Array = []
var _items: Array = []
var _layout_width := -1.0
var _content_height := 0.0
var _hover_item := -1
var _hover_part := ""
var _card_style := StyleBoxFlat.new()
var _button_style := StyleBoxFlat.new()
var _effects: Control


func _ready() -> void:
	_effects = EffectsLayer.new()
	_effects.name = "ResearchEffects"
	add_child(_effects)


func _init() -> void:
	super()
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_style.set_corner_radius_all(3)
	_card_style.set_border_width_all(1)
	_card_style.anti_aliasing = true
	_button_style.set_corner_radius_all(3)
	_button_style.set_border_width_all(1)
	_button_style.anti_aliasing = true


func set_catalog(definitions: Array, domains: Array, research_definition_count: int,
		era_names: Dictionary) -> void:
	_definitions = definitions
	_domains = domains
	_era_names = era_names
	_research_definition_count = research_definition_count


func patch_states(states: PackedInt32Array, progress: PackedInt64Array) -> void:
	_states = states
	_progress = progress
	_rebuild_if_needed()
	queue_redraw()


func set_queue_info(order: Dictionary, eta: Dictionary) -> void:
	var order_changed := order != _queue_order
	_queue_order = order
	_eta = eta
	if order_changed:
		_signature = ""
		_rebuild_if_needed()
	queue_redraw()


func select_technology(index: int) -> void:
	if index == _selected:
		return
	_selected = index
	queue_redraw()


func selected_technology() -> int:
	return _selected


func report() -> Dictionary:
	return {
		"count": _researchable_count,
		"queued_count": _queued_count,
		"pending_count": _pending_count,
		"signature": _signature,
		"selected": _selected,
		"card_count": _items.size(),
		"content_height": _content_height,
	}


func item_rect(index: int) -> Rect2:
	for item in _items:
		if int((item as Dictionary).index) == index:
			return (item as Dictionary).rect
	return Rect2()


func action_rect(card: Rect2) -> Rect2:
	return Rect2(card.end.x - ACTION_WIDTH - TREE_BUTTON - 16.0,
		card.position.y + 10.0, ACTION_WIDTH, ACTION_HEIGHT)


func tree_rect(card: Rect2) -> Rect2:
	return Rect2(card.end.x - TREE_BUTTON - 8.0, card.position.y + 11.0,
		TREE_BUTTON, TREE_BUTTON)


func _rebuild_if_needed() -> void:
	var researchable: Array = []
	var queued: Array = []
	var pending: Array = []
	for domain in range(_domains.size()):
		researchable.append([])
	var limit := mini(_research_definition_count, mini(_states.size(), _definitions.size()))
	var parts := PackedStringArray()
	for index in range(limit):
		var state := int(_states[index])
		if state < 2 or state > 4:
			continue
		var definition: Dictionary = _definitions[index]
		if _is_application(definition) or bool(definition.get("is_milestone", false)):
			continue
		match state:
			2:
				var domain := _domain_index(definition)
				if domain >= 0 and domain < researchable.size():
					(researchable[domain] as Array).append(index)
			3:
				queued.append(index)
			4:
				pending.append(index)
		parts.append("%d:%d" % [index, state])
	queued.sort_custom(func(a: int, b: int) -> bool:
		var da := _domain_index(_definitions[a])
		var db := _domain_index(_definitions[b])
		if da != db:
			return da < db
		return int(_queue_order.get(a, 99)) < int(_queue_order.get(b, 99)))
	var signature := ",".join(parts)
	if signature == _signature and _layout_width == size.x:
		return
	_signature = signature
	_researchable_count = 0
	for group in researchable:
		_researchable_count += (group as Array).size()
	_queued_count = queued.size()
	_pending_count = pending.size()
	_sections = []
	if not queued.is_empty():
		_sections.append({"title": "研究中", "caption": "按领域队列顺序推进",
			"groups": [{"domain": -1, "members": queued}]})
	if _researchable_count > 0:
		var groups: Array = []
		for domain in range(researchable.size()):
			if not (researchable[domain] as Array).is_empty():
				groups.append({"domain": domain, "members": researchable[domain]})
		_sections.append({"title": "可立即研究", "caption": "加入队列后按研究投入比例推进",
			"groups": groups})
	if not pending.is_empty():
		_sections.append({"title": "待生效", "caption": "已完成研究，次日起生效",
			"groups": [{"domain": -1, "members": pending}]})
	_relayout()


func _relayout() -> void:
	_layout_width = size.x
	_items.clear()
	var width := maxf(1.0, size.x - PAD * 2.0)
	var columns := clampi(int((width + CARD_GAP) / (MIN_CARD_WIDTH + CARD_GAP)), 1, MAX_COLUMNS)
	var card_width := (width - CARD_GAP * float(columns - 1)) / float(columns)
	var y := PAD
	for section_value in _sections:
		var section: Dictionary = section_value
		section["y"] = y
		y += SECTION_HEIGHT
		for group_value in section.groups:
			var group: Dictionary = group_value
			if int(group.domain) >= 0:
				group["y"] = y
				y += GROUP_HEIGHT
			var members: Array = group.members
			for cursor in range(members.size()):
				var column := cursor % columns
				var row := cursor / columns
				var rect := Rect2(PAD + float(column) * (card_width + CARD_GAP),
					y + float(row) * (CARD_HEIGHT + CARD_GAP), card_width, CARD_HEIGHT)
				_items.append({"index": int(members[cursor]), "rect": rect})
			var rows := int(ceil(float(members.size()) / float(columns)))
			y += float(rows) * (CARD_HEIGHT + CARD_GAP)
		y += 6.0
	_content_height = maxf(y + PAD, 120.0)
	if not is_equal_approx(custom_minimum_size.y, _content_height):
		custom_minimum_size = Vector2(0.0, _content_height)


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_RESIZED:
			if not is_equal_approx(_layout_width, size.x):
				_relayout()
				queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if _hover_item >= 0:
				_hover_item = -1
				_hover_part = ""
				queue_redraw()


func _hit(point: Vector2) -> Array:
	for item_index in range(_items.size()):
		var rect: Rect2 = (_items[item_index] as Dictionary).rect
		if not rect.has_point(point):
			continue
		var technology := int((_items[item_index] as Dictionary).index)
		var state := int(_states[technology]) if technology < _states.size() else 0
		if state in [2, 3] and action_rect(rect).grow(2.0).has_point(point):
			return [item_index, "action"]
		if tree_rect(rect).grow(2.0).has_point(point):
			return [item_index, "tree"]
		return [item_index, "card"]
	return [-1, ""]


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _hit((event as InputEventMouseMotion).position)
		if int(hit[0]) != _hover_item or String(hit[1]) != _hover_part:
			_hover_item = int(hit[0])
			_hover_part = String(hit[1])
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND \
				if _hover_item >= 0 else Control.CURSOR_ARROW
			tooltip_text = _tooltip_for(_hover_item, _hover_part)
			queue_redraw()
		return
	if not event is InputEventMouseButton:
		return
	var button := event as InputEventMouseButton
	if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
		return
	var hit := _hit(button.position)
	var item_index := int(hit[0])
	if item_index < 0:
		return
	var technology := int((_items[item_index] as Dictionary).index)
	var state := int(_states[technology]) if technology < _states.size() else 0
	match String(hit[1]):
		"action":
			if state == 2:
				enqueue_requested.emit(technology)
			elif state == 3:
				remove_requested.emit(technology)
		"tree":
			show_in_tree_requested.emit(technology)
		_:
			if button.double_click:
				technology_activated.emit(technology)
			else:
				select_technology(technology)
				technology_selected.emit(technology)
	accept_event()


func _tooltip_for(item_index: int, part: String) -> String:
	if item_index < 0:
		return ""
	var technology := int((_items[item_index] as Dictionary).index)
	var state := int(_states[technology]) if technology < _states.size() else 0
	match part:
		"action":
			return "加入对应领域的研究队列" if state == 2 else "移出研究队列（已投入进度保留）"
		"tree":
			return "在科技树中定位"
	var definition: Dictionary = _definitions[technology]
	# 摘要走共用模块：effect_summary 为空时由结构化效果拼出来，否则
	# 「天文导航」这类只靠运行时航道的科技在列表里悬停时是一片空白。
	var summary := TechnologyEffectTextScript.summary_text(definition)
	var hint := "单击查看详情 · 双击%s" % ("加入队列" if state == 2 else "移出队列") \
		if state in [2, 3] else "单击查看详情"
	return "%s\n%s\n%s" % [String(definition.get("display_name", "")), summary, hint] \
		if not summary.is_empty() else "%s\n%s" % [String(definition.get("display_name", "")), hint]


func _visible_rect() -> Rect2:
	var scroll := get_parent() as ScrollContainer
	if scroll == null:
		return Rect2(Vector2.ZERO, size)
	return Rect2(Vector2(0.0, float(scroll.scroll_vertical)), scroll.size)


func _draw() -> void:
	_sync_effects()
	if _sections.is_empty():
		_draw_empty()
		return
	var view := _visible_rect().grow(CARD_HEIGHT)
	for section_value in _sections:
		var section: Dictionary = section_value
		var y := float(section.get("y", 0.0))
		if y + SECTION_HEIGHT >= view.position.y and y <= view.end.y:
			_text(Vector2(PAD, y + 20.0), String(section.title), 16, UITokens.DOSSIER_INK, "serif")
			var title_width := _text_width(String(section.title), 16, "serif")
			var count := 0
			for group in section.groups:
				count += ((group as Dictionary).members as Array).size()
			_text(Vector2(PAD + title_width + 10.0, y + 20.0),
				_fit_text("%d 项 · %s" % [count, String(section.caption)], 12,
					size.x - PAD * 2.0 - title_width - 10.0), 12, UITokens.DOSSIER_INK_MUTED)
			draw_line(Vector2(PAD, y + SECTION_HEIGHT - 6.0),
				Vector2(size.x - PAD, y + SECTION_HEIGHT - 6.0), UITokens.DOSSIER_RULE_STRONG, 1.0)
		for group_value in section.groups:
			var group: Dictionary = group_value
			var domain := int(group.domain)
			if domain < 0 or not group.has("y"):
				continue
			var gy := float(group.y)
			if gy + GROUP_HEIGHT < view.position.y or gy > view.end.y:
				continue
			var accent := _domain_accent(domain)
			var ink := accent.lerp(UITokens.DOSSIER_INK, 0.5)
			_icon(_domain_icon(domain), Rect2(Vector2(PAD, gy + 6.0), Vector2(14.0, 14.0)), ink)
			var label := "%s · %d" % [_domain_name(domain), (group.members as Array).size()]
			_text(Vector2(PAD + 20.0, gy + 18.0), label, 13, ink, "sans_strong")
	for item_index in range(_items.size()):
		var item: Dictionary = _items[item_index]
		var rect: Rect2 = item.rect
		if rect.end.y < view.position.y or rect.position.y > view.end.y:
			continue
		_draw_card(item_index, int(item.index), rect)


func _sync_effects() -> void:
	if _effects == null:
		return
	var items: Array = []
	var view := _visible_rect()
	for value in _items:
		var item: Dictionary = value
		var rect: Rect2 = item.rect
		if not view.grow(CARD_HEIGHT).intersects(rect):
			continue
		var index := int(item.index)
		var definition: Dictionary = _definitions[index]
		var state := int(_states[index]) if index < _states.size() else 0
		items.append({"index": index, "rect": rect,
			"accent": _domain_accent(_domain_index(definition)),
			"fraction": _fraction(index, definition),
			"active": state == 3 and int(_queue_order.get(index, 0)) == 0,
			"track": Rect2(rect.position.x + 14.0, rect.end.y - 6.5,
				rect.size.x - 26.0, 3.0)})
	_effects.view_rect = view
	_effects.set_items(items)
	_effects.patch_states(_states)
	var hover := int((_items[_hover_item] as Dictionary).index) \
		if _hover_item >= 0 and _hover_item < _items.size() else -1
	_effects.set_interaction(_selected, hover)


func _draw_card(item_index: int, technology: int, rect: Rect2) -> void:
	var definition: Dictionary = _definitions[technology]
	var state := int(_states[technology]) if technology < _states.size() else 0
	var domain := _domain_index(definition)
	var accent := _domain_accent(domain)
	var selected := technology == _selected
	var hovered := item_index == _hover_item
	_card_style.bg_color = Color(1.0, 0.985, 0.94, 0.62) if not selected \
		else Color(1.0, 0.97, 0.9, 0.9)
	if hovered and not selected:
		_card_style.bg_color = Color(1.0, 0.985, 0.94, 0.85)
	_card_style.border_color = UITokens.DOSSIER_OXBLOOD if selected \
		else (UITokens.DOSSIER_BRASS if hovered else UITokens.DOSSIER_RULE)
	# Reuse the generated paper plates from the atlas for tactile list cards too.
	if not Art.draw_plate(self, Art.CARD_KNOWN, rect,
			Color(1.0, 0.99, 0.94) if hovered or selected else Color.WHITE):
		draw_style_box(_card_style, rect)
	if selected or hovered:
		draw_rect(rect.grow(-1.0), _card_style.border_color, false, 1.0)
	draw_rect(Rect2(rect.position + Vector2(1.0, 1.0), Vector2(3.0, rect.size.y - 2.0)),
		accent.lerp(UITokens.DOSSIER_INK, 0.15))
	var text_left := rect.position.x + 14.0
	var right_limit := action_rect(rect).position.x - 10.0 if state in [2, 3] \
		else tree_rect(rect).position.x - 10.0
	var name := String(definition.get("display_name", ""))
	_text(Vector2(text_left, rect.position.y + 24.0),
		_fit_text(name, 15, right_limit - text_left, "serif"), 15, UITokens.DOSSIER_INK, "serif")
	var fraction := _fraction(technology, definition)
	var meta := _meta_text(technology, definition, state, fraction)
	_text(Vector2(text_left, rect.position.y + 44.0),
		_fit_text(meta, 12, rect.end.x - 12.0 - text_left), 12,
		UITokens.DOSSIER_OXBLOOD if state == 3 and int(_queue_order.get(technology, -1)) == 0 \
			else UITokens.DOSSIER_INK_MUTED)
	if state == 3 or (state == 2 and fraction > 0.0) or state == 4:
		var track := Rect2(text_left, rect.end.y - 8.0, rect.end.x - 12.0 - text_left, 3.0)
		_rounded_bar(track, UITokens.DOSSIER_TRACK, 1.5)
		var fill := 1.0 if state == 4 else fraction
		if fill > 0.0:
			_rounded_bar(Rect2(track.position, Vector2(track.size.x * fill, track.size.y)),
				UITokens.DOSSIER_VERDIGRIS if state == 4 else accent.lerp(UITokens.DOSSIER_INK, 0.2),
				1.5)
	if state in [2, 3]:
		_draw_action(rect, state, hovered and _hover_part == "action")
	var tree := tree_rect(rect)
	if hovered and _hover_part == "tree":
		draw_rect(tree, UITokens.DOSSIER_HOVER)
	_icon(&"action.chevron_right", tree.grow(-5.0),
		UITokens.DOSSIER_INK_SOFT if hovered else Color(UITokens.DOSSIER_INK_MUTED, 0.6))


func _draw_action(card: Rect2, state: int, hovered: bool) -> void:
	var rect := action_rect(card)
	var enqueue := state == 2
	if enqueue:
		_button_style.bg_color = UITokens.DOSSIER_OXBLOOD if hovered \
			else Color(UITokens.DOSSIER_OXBLOOD, 0.08)
		_button_style.border_color = UITokens.DOSSIER_OXBLOOD
	else:
		_button_style.bg_color = Color(UITokens.DOSSIER_INK, 0.1) if hovered \
			else Color(0.0, 0.0, 0.0, 0.0)
		_button_style.border_color = UITokens.DOSSIER_RULE
	draw_style_box(_button_style, rect)
	var label := "加入" if enqueue else "移出"
	var ink := UITokens.DOSSIER_PAPER if enqueue and hovered \
		else (UITokens.DOSSIER_OXBLOOD if enqueue else UITokens.DOSSIER_INK_SOFT)
	_icon(&"action.add" if enqueue else &"action.close",
		Rect2(Vector2(rect.position.x + 8.0, rect.position.y + 6.0), Vector2(11.0, 11.0)), ink)
	_text(Vector2(rect.position.x + 22.0, rect.position.y + 17.0), label, 12, ink, "sans_strong")


func _draw_empty() -> void:
	var center := Vector2(size.x * 0.5, minf(size.y * 0.42, 180.0))
	_icon(&"technology.state.locked", Rect2(center - Vector2(14.0, 46.0), Vector2(28.0, 28.0)),
		UITokens.DOSSIER_INK_MUTED)
	var title := "当前没有可立即研究的科技"
	_text(Vector2(PAD, center.y), title, 16, UITokens.DOSSIER_INK, "serif",
		HORIZONTAL_ALIGNMENT_CENTER, size.x - PAD * 2.0)
	_text(Vector2(PAD, center.y + 24.0), "满足研究条件或有了新的发现后，新的科技会出现在这里。", 12,
		UITokens.DOSSIER_INK_MUTED, "sans", HORIZONTAL_ALIGNMENT_CENTER, size.x - PAD * 2.0)
	_text(Vector2(PAD, center.y + 44.0), "可切换到“科技树”查看各项科技的研究条件。", 12,
		UITokens.DOSSIER_INK_MUTED, "sans", HORIZONTAL_ALIGNMENT_CENTER, size.x - PAD * 2.0)


func _fraction(technology: int, definition: Dictionary) -> float:
	var cost := maxf(1.0, float(definition.get("cost_points_scaled",
		int(definition.get("cost_points", 1)) * POINT_SCALE)))
	var earned := float(_progress[technology]) if technology < _progress.size() else 0.0
	return clampf(earned / cost, 0.0, 1.0)


func _meta_text(technology: int, definition: Dictionary, state: int, fraction: float) -> String:
	var cost_scaled := maxf(1.0, float(definition.get("cost_points_scaled",
		int(definition.get("cost_points", 1)) * POINT_SCALE)))
	var cost_text := UITokens.format_compact_number_cn(cost_scaled / POINT_SCALE, 1)
	match state:
		3:
			var position := int(_queue_order.get(technology, -1))
			var eta := String(_eta.get(technology, ""))
			var head := "%s · 第 %d 位" % [_domain_name(_domain_index(definition)), position + 1] \
				if position >= 0 else _domain_name(_domain_index(definition))
			var parts := PackedStringArray([head, "%d%%" % int(floor(fraction * 100.0))])
			if not eta.is_empty():
				parts.append(eta)
			return " · ".join(parts)
		4:
			return "研究完成 · 次日生效"
	var era := String(_era_names.get(String(definition.get("era_id", "")),
		String(definition.get("era_id", ""))))
	var routes: PackedStringArray = definition.get("route_display_names", PackedStringArray())
	var parts := PackedStringArray([era, "需 %s 科技值" % cost_text])
	if fraction > 0.0:
		parts.append("已投入 %d%%" % int(floor(fraction * 100.0)))
	if not routes.is_empty():
		parts.append(String(routes[0]))
	return " · ".join(parts)


func _domain_index(definition: Dictionary) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for index in range(_domains.size()):
		if String((_domains[index] as Dictionary).get("id", "")) == domain_id:
			return index
	return int(definition.get("domain_index", 0))


func _domain_name(domain: int) -> String:
	if domain >= 0 and domain < _domains.size():
		return String((_domains[domain] as Dictionary).get("display_name", ""))
	return ""


func _domain_accent(domain: int) -> Color:
	if domain >= 0 and domain < _domains.size():
		return (_domains[domain] as Dictionary).get("accent", UITokens.DOSSIER_UMBER)
	return UITokens.DOSSIER_UMBER


func _domain_icon(domain: int) -> StringName:
	if domain >= 0 and domain < _domains.size():
		return IconCatalog.technology_domain_semantic(
			String((_domains[domain] as Dictionary).get("id", "")))
	return &""


func _is_application(definition: Dictionary) -> bool:
	return bool(definition.get("is_application", false)) \
		or String(definition.get("anchor_kind", "")) == "application" \
		or String(definition.get("id", "")).begins_with("app.")
