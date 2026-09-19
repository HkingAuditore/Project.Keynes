extends ScrollContainer
class_name TechnologyAvailableView

# Compact research desk: only state==2 researchable tech.* rows, grouped by
# domain. Applications never appear here — they auto-enable outside the queue.

signal technology_selected(index: int)
signal technology_activated(index: int)
signal show_in_tree_requested(index: int)

const IconBadgeScene := preload("res://scenes/ui/icon_badge.tscn")
const POINT_SCALE := 1000.0

var _definitions: Array = []
var _domains: Array = []
var _era_names: Dictionary = {}
var _research_definition_count := 0
var _states := PackedInt32Array()
var _progress := PackedInt64Array()
var _selected := -1
var _list: VBoxContainer
var _empty: Label
var _row_nodes: Dictionary = {}
var _signature := ""


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	if _list != null:
		return
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	add_child(_list)
	_empty = Label.new()
	_empty.text = "当前没有可立即研究的科技。\n完成前置或等待揭示后再回来。"
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.theme_type_variation = &"PKMutedLabel"
	_empty.visible = false
	_list.add_child(_empty)


func set_catalog(definitions: Array, domains: Array,
		research_definition_count: int = -1, era_names: Dictionary = {}) -> void:
	if not _definitions.is_empty() or definitions.is_empty():
		return
	_definitions = definitions
	_domains = domains
	_era_names = era_names
	_research_definition_count = research_definition_count if research_definition_count >= 0 \
		else definitions.size()


func patch_states(states: PackedInt32Array, progress: PackedInt64Array) -> void:
	if _list == null:
		_ready()
	_states = states
	_progress = progress
	_rebuild_if_needed()
	_patch_row_dynamics()


func select_technology(index: int) -> void:
	_selected = index
	for technology in _row_nodes.keys():
		var row: Dictionary = _row_nodes[technology]
		var panel := row.panel as PanelContainer
		if panel == null:
			continue
		panel.modulate = Color(1.08, 1.04, 0.94, 1.0) if int(technology) == index \
			else Color.WHITE


func selected_technology() -> int:
	return _selected


func available_report() -> Dictionary:
	return {
		"count": _row_nodes.size(),
		"signature": _signature,
		"selected": _selected,
	}


func _rebuild_if_needed() -> void:
	var parts := PackedStringArray()
	var grouped: Array = []
	for domain in range(_domains.size()):
		grouped.append([])
	var limit := mini(_research_definition_count, mini(_states.size(), _definitions.size()))
	for index in range(limit):
		if int(_states[index]) != 2:
			continue
		var definition: Dictionary = _definitions[index]
		if _is_application(definition) or bool(definition.get("is_milestone", false)):
			continue
		var domain := _domain_index(definition)
		if domain < 0 or domain >= grouped.size():
			continue
		(grouped[domain] as Array).append(index)
		parts.append("%d" % index)
	var signature := ",".join(parts)
	if signature == _signature and not _row_nodes.is_empty():
		return
	_signature = signature
	_rebuild_rows(grouped)


func _rebuild_rows(grouped: Array) -> void:
	if _list == null:
		_ready()
	for child in _list.get_children():
		if child == _empty:
			continue
		child.queue_free()
	_row_nodes.clear()
	var total := 0
	for domain in range(grouped.size()):
		var members: Array = grouped[domain]
		if members.is_empty():
			continue
		total += members.size()
		var header := HBoxContainer.new()
		header.add_theme_constant_override("separation", 6)
		var icon := IconBadgeScene.instantiate() as Control
		icon.custom_minimum_size = Vector2(22, 22)
		var domain_id := String((_domains[domain] as Dictionary).get("id", ""))
		var accent: Color = (_domains[domain] as Dictionary).get("accent", UITokens.ACCENT)
		if icon.has_method("set_semantic"):
			icon.call("set_semantic", IconCatalog.technology_domain_semantic(domain_id), accent)
		header.add_child(icon)
		var title := Label.new()
		title.text = "%s · %d 项可研究" % [
			String((_domains[domain] as Dictionary).get("display_name", domain_id)),
			members.size()]
		title.theme_type_variation = &"PKSectionTitle"
		title.add_theme_color_override("font_color",
			accent.lerp(UITokens.ARCHIVE_INK, 0.52))
		header.add_child(title)
		_list.add_child(header)
		for technology in members:
			_list.add_child(_make_row(int(technology), accent))
	_empty.visible = total == 0
	if _empty.get_parent() != _list:
		_list.add_child(_empty)
	else:
		_list.move_child(_empty, _list.get_child_count() - 1)


func _make_row(index: int, accent: Color) -> PanelContainer:
	var definition: Dictionary = _definitions[index]
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PKInsetPanel"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.tooltip_text = "单击查看详情 · 双击加入研究队列"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	panel.add_child(row)
	var state := Label.new()
	state.custom_minimum_size = Vector2(16, 0)
	state.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	IconButton.apply_to_label(state, &"technology.state.available", 12)
	state.add_theme_color_override("font_color",
		accent.lerp(UITokens.ARCHIVE_INK, 0.40))
	row.add_child(state)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 2)
	row.add_child(body)
	var name_label := Label.new()
	name_label.text = String(definition.get("display_name", ""))
	name_label.theme_type_variation = &"PKWorkspaceLabel"
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	body.add_child(name_label)
	var meta := Label.new()
	meta.theme_type_variation = &"PKMutedLabel"
	body.add_child(meta)
	var progress := ProgressBar.new()
	progress.custom_minimum_size = Vector2(72, 6)
	progress.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	progress.show_percentage = false
	progress.max_value = 100.0
	row.add_child(progress)
	var tree_btn := Button.new()
	tree_btn.custom_minimum_size = Vector2(28, 24)
	tree_btn.focus_mode = Control.FOCUS_NONE
	tree_btn.theme_type_variation = &"PKIconButton"
	IconButton.apply(tree_btn, &"action.chevron_right", IconButton.SMALL, "在科技树中查看")
	tree_btn.pressed.connect(func() -> void: show_in_tree_requested.emit(index))
	row.add_child(tree_btn)
	panel.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var button := event as InputEventMouseButton
			if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
				return
			if button.double_click:
				technology_activated.emit(index)
			else:
				select_technology(index)
				technology_selected.emit(index)
			panel.accept_event()
	)
	_row_nodes[index] = {
		"panel": panel,
		"meta": meta,
		"progress": progress,
		"accent": accent,
	}
	_update_row_dynamic(index)
	if index == _selected:
		panel.modulate = Color(1.08, 1.04, 0.94, 1.0)
	return panel


func _patch_row_dynamics() -> void:
	for technology in _row_nodes.keys():
		_update_row_dynamic(int(technology))


func _update_row_dynamic(index: int) -> void:
	var row: Dictionary = _row_nodes.get(index, {})
	if row.is_empty():
		return
	var definition: Dictionary = _definitions[index]
	var cost := maxf(1.0, float(definition.get("cost_points", 1)))
	var earned := float(_progress[index]) / POINT_SCALE if index < _progress.size() else 0.0
	var fraction := clampf(earned / cost, 0.0, 1.0)
	(row.progress as ProgressBar).value = fraction * 100.0
	var era := String(_era_names.get(String(definition.get("era_id", "")), ""))
	if era.is_empty():
		era = String(definition.get("era_id", ""))
	var routes: PackedStringArray = definition.get("route_display_names", PackedStringArray())
	var route := String(routes[0]) if not routes.is_empty() else ""
	var meta := row.meta as Label
	if route.is_empty():
		meta.text = "成本 %s · %s" % [UITokens.format_compact_number_cn(cost, 0), era]
	else:
		meta.text = "成本 %s · %s · %s" % [
			UITokens.format_compact_number_cn(cost, 0), era, route]


func _domain_index(definition: Dictionary) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for index in range(_domains.size()):
		if String((_domains[index] as Dictionary).get("id", "")) == domain_id:
			return index
	return int(definition.get("domain_index", 0))


func _is_application(definition: Dictionary) -> bool:
	return bool(definition.get("is_application", false)) \
		or String(definition.get("anchor_kind", "")) == "application" \
		or String(definition.get("id", "")).begins_with("app.")
