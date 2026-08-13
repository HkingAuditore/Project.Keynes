extends Control
class_name TechnologyWorkspace

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")
const ResearchConditionScript = preload("res://scripts/research/research_condition.gd")
const ResearchPredicateScript = preload("res://scripts/research/research_predicate.gd")

# Full-bleed research screen with a bounded domain workspace and a separate
# network overview. Research policy is a permanent working column; technology
# detail remains an on-demand drawer.

signal policy_submitted()

const TechnologyQueueRowScene := preload("res://scenes/ui/technology_queue_row.tscn")

const CASH_SCALE := 10000.0
const POINT_SCALE := 1000.0
const POLICY_WIDTH := 280.0
const DETAIL_WIDTH := 384.0
const DETAIL_ANCHOR_WIDTH := 360.0
const DRAWER_RAIL_WIDTH := 40.0
const PIN_BREAKPOINT := 1600.0
const DOMAIN_COUNT := 4
const MODE_FOCUS := 0
const MODE_OVERVIEW := 1

var _player_controller = null
var _definitions: Array = []
var _eras: Array = []
var _domains: Array = []
var _lanes: Array = []
var _visual_edges: Array = []
var _era_names: Dictionary = {}
var _technology_indices: Dictionary = {}
var _signal_indices: Dictionary = {}
var _signal_names: Dictionary = {}
var _research: Dictionary = {}
var _queue_signature := ""
var _detail_signature := ""
var _last_states := PackedInt32Array()
var _lane_visibility_signature := 0
var _mode := MODE_FOCUS
var _focus_domain := ""
var _focus_era := 0
var _manual_focus := false
var _initial_focus_pending := true
var _policy_open := true
var _detail_open := false
var _policy_pinned := false
var _detail_pinned := false
var _compact := false

var _status_chips: Dictionary = {}
var _policy_panel: PanelContainer
var _dial: Control
var _budget: Control
var _tree: Control
var _overview: Control
var _detail: Control
var _detail_host: PanelContainer
var _main: Control
var _focus_mode: Button
var _overview_mode: Button
var _prev_era: Button
var _next_era: Button
var _era_label: Label
var _lane_selector: OptionButton
var _search: LineEdit
var _policy_toggle: Button
var _detail_toggle: Button
var _policy_rail: Button
var _detail_rail: Button
var _policy_pin: Button
var _detail_pin: Button
var _queue_zones: Array = []
var _queue_headers: Array = []
var _queue_rows: Array = []


func _ready() -> void:
	if _tree != null:
		return
	var required_paths := {
		"policy_panel": "Root/Main/PolicyPanel",
		"dial": "Root/Main/PolicyPanel/Scroll/Body/Dial",
		"budget": "Root/Main/PolicyPanel/Scroll/Body/Budget",
		"tree": "Root/Main/Tree",
		"overview": "Root/Main/Overview",
		"detail_host": "Root/Main/DetailHost",
		"detail": "Root/Main/DetailHost/Body/Detail",
	}
	_policy_panel = get_node_or_null(required_paths.policy_panel) as PanelContainer
	_dial = get_node_or_null(required_paths.dial) as Control
	_budget = get_node_or_null(required_paths.budget) as Control
	_tree = get_node_or_null(required_paths.tree) as Control
	_overview = get_node_or_null(required_paths.overview) as Control
	_detail_host = get_node_or_null(required_paths.detail_host) as PanelContainer
	_detail = get_node_or_null(required_paths.detail) as Control
	_main = get_node_or_null("Root/Main") as Control
	_focus_mode = get_node_or_null("Root/Toolbar/Row/FocusMode") as Button
	_overview_mode = get_node_or_null("Root/Toolbar/Row/OverviewMode") as Button
	_prev_era = get_node_or_null("Root/Toolbar/Row/PrevEra") as Button
	_next_era = get_node_or_null("Root/Toolbar/Row/NextEra") as Button
	_era_label = get_node_or_null("Root/Toolbar/Row/EraLabel") as Label
	_lane_selector = get_node_or_null("Root/Toolbar/Row/Lane") as OptionButton
	_search = get_node_or_null("Root/Toolbar/Row/Search") as LineEdit
	_policy_toggle = get_node_or_null("Root/Toolbar/Row/PolicyToggle") as Button
	_detail_toggle = get_node_or_null("Root/Toolbar/Row/DetailToggle") as Button
	_policy_rail = get_node_or_null("Root/Main/PolicyRail") as Button
	_detail_rail = get_node_or_null("Root/Main/DetailRail") as Button
	_policy_pin = get_node_or_null("Root/Main/PolicyPanel/Scroll/Body/Header/Pin") as Button
	_detail_pin = get_node_or_null("Root/Main/DetailHost/Body/Header/Pin") as Button
	if _policy_panel == null or _dial == null or _budget == null \
			or _tree == null or _overview == null or _detail == null \
			or _detail_host == null or _main == null or _focus_mode == null \
			or _overview_mode == null or _prev_era == null or _next_era == null \
			or _era_label == null or _lane_selector == null or _search == null \
			or _policy_toggle == null or _detail_toggle == null \
			or _policy_rail == null or _detail_rail == null \
			or _policy_pin == null or _detail_pin == null:
		var missing := PackedStringArray()
		for key in required_paths:
			if get_node_or_null(required_paths[key]) == null:
				missing.append(String(required_paths[key]))
		push_error("TechnologyWorkspace 必须通过 technology_workspace.tscn 实例化；缺失节点：%s" \
			% ", ".join(missing))
		return
	var status_defs := [
		{"id": "era", "node": "Era", "icon": &"technology.milestone", "accent": UITokens.BRASS_HIGHLIGHT},
		{"id": "points", "node": "Points", "icon": IconCatalog.good_semantic("technology_points"), "accent": UITokens.CLIMATE},
		{"id": "treasury", "node": "Treasury", "icon": &"metric.treasury", "accent": UITokens.RESOURCE},
		{"id": "queued", "node": "Queued", "icon": &"technology.state.queued", "accent": UITokens.WATER},
		{"id": "completed", "node": "Completed", "icon": &"technology.state.completed", "accent": UITokens.GOOD},
		{"id": "purchased", "node": "Purchased", "icon": &"metric.technology", "accent": UITokens.ACCENT},
	]
	for item in status_defs:
		var chip := get_node("Root/StatusStrip/Row/%s" % String(item.node)) as HBoxContainer
		var icon := chip.get_node("Icon") as IconBadge
		var value := chip.get_node("Value") as Label
		icon.set_semantic(item.icon, item.accent)
		value.add_theme_color_override("font_color", (item.accent as Color).lerp(UITokens.TEXT_MAIN, 0.60))
		_status_chips[String(item.id)] = chip
		_status_chips["%s_value" % String(item.id)] = value
	for domain in range(DOMAIN_COUNT):
		var header := get_node("Root/Main/PolicyPanel/Scroll/Body/Domain%d" % domain) as HBoxContainer
		var zone := get_node("Root/Main/PolicyPanel/Scroll/Body/Zone%d" % domain)
		_queue_headers.append({"icon": header.get_node("Icon"), "name": header.get_node("Name"), "share": header.get_node("Share")})
		zone.configure(domain)
		zone.move_requested.connect(_move_in_queue)
		_queue_zones.append(zone)
		_queue_rows.append([])
	_dial.weights_previewed.connect(_on_weights_previewed)
	_dial.weights_committed.connect(_on_weights_committed)
	_budget.budget_committed.connect(_on_budget_committed)
	_tree.technology_selected.connect(_on_tree_selected)
	_tree.technology_activated.connect(_on_tree_activated)
	_tree.portal_requested.connect(_focus_technology)
	_overview.cell_activated.connect(_on_overview_cell_activated)
	_detail.enqueue_requested.connect(_enqueue)
	_detail.remove_requested.connect(_remove_from_queue)
	_focus_mode.pressed.connect(func() -> void: _set_mode(MODE_FOCUS))
	_overview_mode.pressed.connect(func() -> void: _set_mode(MODE_OVERVIEW))
	_prev_era.pressed.connect(func() -> void: _shift_era(-1))
	_next_era.pressed.connect(func() -> void: _shift_era(1))
	_lane_selector.item_selected.connect(_on_lane_selected)
	_search.text_submitted.connect(_on_search_submitted)
	_policy_toggle.pressed.connect(func() -> void: _set_policy_open(true))
	_detail_toggle.pressed.connect(func() -> void: _set_detail_open(not _detail_open))
	_policy_rail.pressed.connect(func() -> void: _set_policy_open(true))
	_detail_rail.pressed.connect(func() -> void: _set_detail_open(true))
	_policy_pin.toggled.connect(_on_policy_pin_toggled)
	_detail_pin.toggled.connect(_on_detail_pin_toggled)
	var policy_close := get_node("Root/Main/PolicyPanel/Scroll/Body/Header/Close") as Button
	var detail_close := get_node("Root/Main/DetailHost/Body/Header/Close") as Button
	IconButton.apply(policy_close, &"action.close", IconButton.SMALL, "关闭研究管理")
	IconButton.apply(detail_close, &"action.close", IconButton.SMALL, "关闭科技详情")
	IconButton.apply(_policy_pin, &"action.pin", IconButton.SMALL, "固定研究管理")
	IconButton.apply(_detail_pin, &"action.pin", IconButton.SMALL, "固定科技详情")
	IconButton.apply(_policy_rail, &"system.settings", IconButton.SMALL, "打开研究管理")
	IconButton.apply(_detail_rail, &"summary.overview", IconButton.SMALL, "打开科技详情")
	IconButton.apply(_prev_era, &"action.back", IconButton.SMALL, "上一个已知时代")
	IconButton.apply(_next_era, &"action.chevron_right", IconButton.SMALL, "下一个已知时代")
	var relocate := get_node("Root/Toolbar/Row/Relocate") as Button
	IconButton.apply(relocate, &"system.target", IconButton.SMALL, "重新定位研究前沿")
	relocate.pressed.connect(_apply_default_focus)
	policy_close.pressed.connect(func() -> void: _set_policy_open(true))
	detail_close.pressed.connect(func() -> void: _set_detail_open(false))
	_apply_drawer_layout()


func set_model(model: Dictionary) -> void:
	if _tree == null:
		_ready()
	_research = model.get("research", {})
	if _definitions.is_empty():
		_definitions = model.get("technology_definitions", [])
		_eras = model.get("technology_eras", [])
		_domains = model.get("technology_domains", [])
		_lanes = model.get("technology_lanes", [])
		_visual_edges = model.get("technology_visual_edges", [])
		for index in range(_definitions.size()):
			_technology_indices[String((_definitions[index] as Dictionary).get(
				"id", ""))] = index
		var signal_definitions: Array = model.get("research_signal_definitions", [])
		for index in range(signal_definitions.size()):
			var signal_definition: Dictionary = signal_definitions[index]
			_signal_indices[String(signal_definition.get("id", ""))] = index
			_signal_names[String(signal_definition.get("id", ""))] = String(
				signal_definition.get("display_name",
					signal_definition.get("id", "")))
		for era in _eras:
			_era_names[String((era as Dictionary).get("id", ""))] = \
				String((era as Dictionary).get("display_name", ""))
		if not _definitions.is_empty():
			_tree.set_catalog(_definitions, _eras, _domains, _visual_edges)
			_overview.set_catalog(_definitions, _eras, _domains)
			_configure_lane_selector(PackedInt32Array())
			_dial.configure(_domains)
			_configure_queues()
	_apply_research()


# Daily ticks reuse this path: only cached values and visible text change.
func refresh_research(model: Dictionary) -> void:
	if _tree == null:
		return
	_research = model.get("research", {})
	_apply_research()


func set_player_controller(controller) -> void:
	_player_controller = controller


func set_compact(compact: bool) -> void:
	if _policy_panel == null:
		return
	_compact = compact
	for key in ["purchased", "completed"]:
		var chip := _status_chips.get(key) as Control
		if chip != null:
			chip.visible = not compact
	_apply_drawer_layout()


func reset_navigation() -> void:
	_initial_focus_pending = true
	_manual_focus = false
	_set_mode(MODE_FOCUS)
	_set_policy_open(true)
	_set_detail_open(false)
	if not _definitions.is_empty():
		_apply_default_focus()


func _unhandled_key_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if _detail_open:
			_set_detail_open(false)


func tree_view() -> Control:
	return _tree


func overview_view() -> Control:
	return _overview


func navigation_report() -> Dictionary:
	return {
		"mode": _mode,
		"domain": _focus_domain,
		"lane": _focus_domain,
		"era": _focus_era,
		"policy_open": _policy_open,
		"detail_open": _detail_open,
		"policy_pinned": _policy_pinned,
		"detail_pinned": _detail_pinned,
	}


func _configure_lane_selector(states: PackedInt32Array) -> void:
	var previous := _focus_domain
	_lane_selector.clear()
	for domain in _domains:
		var data: Dictionary = domain
		var domain_id := String(data.get("id", ""))
		_lane_selector.add_item(String(data.get("display_name", domain_id)))
		_lane_selector.set_item_metadata(_lane_selector.item_count - 1, domain_id)
	if _lane_selector.item_count == 0:
		return
	var selected := 0
	for index in range(_lane_selector.item_count):
		if String(_lane_selector.get_item_metadata(index)) == previous:
			selected = index
			break
	_lane_selector.select(selected)
	_focus_domain = String(_lane_selector.get_item_metadata(selected))


func _set_mode(mode: int) -> void:
	_mode = MODE_OVERVIEW if mode == MODE_OVERVIEW else MODE_FOCUS
	_focus_mode.set_pressed_no_signal(_mode == MODE_FOCUS)
	_overview_mode.set_pressed_no_signal(_mode == MODE_OVERVIEW)
	_tree.visible = _mode == MODE_FOCUS
	_overview.visible = _mode == MODE_OVERVIEW
	_prev_era.disabled = _mode != MODE_FOCUS
	_next_era.disabled = _mode != MODE_FOCUS
	_lane_selector.disabled = _mode != MODE_FOCUS
	if _mode == MODE_OVERVIEW:
		_set_detail_open(false)
		_overview.patch_states(_research.get("technology_states", PackedInt32Array()))
	UIAnimation.crossfade(_tree if _mode == MODE_FOCUS else _overview, UITokens.ANIM_FAST)


func _shift_era(delta: int) -> void:
	var target := clampi(_focus_era + delta, 0, maxi(0, _deepest_visible_era()))
	if target == _focus_era:
		return
	_manual_focus = true
	_focus_era = target
	_apply_focus(-1)


func _on_lane_selected(index: int) -> void:
	if index < 0 or index >= _lane_selector.item_count:
		return
	_manual_focus = true
	_focus_domain = String(_lane_selector.get_item_metadata(index))
	_apply_focus(-1)


func _on_overview_cell_activated(domain_id: String, era_index: int,
		technology_index: int) -> void:
	_focus_domain = domain_id
	_focus_era = era_index
	_manual_focus = true
	_set_mode(MODE_FOCUS)
	_apply_focus(technology_index)


func _on_search_submitted(query: String) -> void:
	var normalized := query.strip_edges().to_lower()
	if normalized.is_empty():
		return
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	var best := -1
	for index in range(_definitions.size()):
		if index >= states.size() or states[index] <= 0:
			continue
		var name := String((_definitions[index] as Dictionary).get("display_name", ""))
		if name.to_lower() == normalized:
			best = index
			break
		if best < 0 and name.to_lower().contains(normalized):
			best = index
	if best >= 0:
		_focus_technology(best)
		_search.text = String((_definitions[best] as Dictionary).get("display_name", ""))
	else:
		_search.text = ""
		_search.placeholder_text = "未找到已揭示科技"


func _focus_technology(index: int) -> void:
	if index < 0 or index >= _definitions.size():
		return
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	if index >= states.size() or states[index] <= 0:
		return
	var definition: Dictionary = _definitions[index]
	_focus_domain = String(definition.get("domain_id", ""))
	_focus_era = _era_index(String(definition.get("era_id", "")))
	_manual_focus = true
	_set_mode(MODE_FOCUS)
	_apply_focus(index)
	_set_detail_open(true)


func _apply_focus(preferred_index: int) -> void:
	if _focus_domain.is_empty() or _eras.is_empty():
		return
	_focus_era = clampi(_focus_era, 0, maxi(0, _deepest_visible_era()))
	_tree.set_focus(_focus_domain, _focus_era, preferred_index)
	for index in range(_lane_selector.item_count):
		if String(_lane_selector.get_item_metadata(index)) == _focus_domain:
			_lane_selector.select(index)
			break
	_era_label.text = String((_eras[_focus_era] as Dictionary).get("display_name", "—"))
	_prev_era.disabled = _mode != MODE_FOCUS or _focus_era <= 0
	_next_era.disabled = _mode != MODE_FOCUS or _focus_era >= _deepest_visible_era()
	_refresh_detail()


func _apply_default_focus() -> void:
	if _definitions.is_empty():
		return
	var target := _queue_priority_target()
	if target < 0:
		target = _frontier_target()
	if target < 0:
		return
	var definition: Dictionary = _definitions[target]
	_focus_domain = String(definition.get("domain_id", ""))
	_focus_era = _era_index(String(definition.get("era_id", "")))
	_initial_focus_pending = false
	_manual_focus = false
	_set_mode(MODE_FOCUS)
	_apply_focus(target)


func _queue_priority_target() -> int:
	var offsets: PackedInt32Array = _research.get("queue_offsets",
		PackedInt32Array([0, 0, 0, 0, 0]))
	var technologies: PackedInt32Array = _research.get("queue_technology_indices",
		PackedInt32Array())
	var weights: PackedInt32Array = _research.get("domain_weights_bp",
		PackedInt32Array([2500, 2500, 2500, 2500]))
	var best_domain := -1
	var best_weight := -1
	for domain in range(DOMAIN_COUNT):
		if domain + 1 >= offsets.size() or offsets[domain] >= offsets[domain + 1]:
			continue
		var weight := int(weights[domain]) if domain < weights.size() else 0
		if weight > best_weight:
			best_weight = weight
			best_domain = domain
	if best_domain < 0:
		return -1
	var cursor := int(offsets[best_domain])
	return int(technologies[cursor]) if cursor >= 0 and cursor < technologies.size() else -1


func _frontier_target() -> int:
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	var best := -1
	var best_era := -1
	for index in range(mini(states.size(), _definitions.size())):
		if states[index] != 2:
			continue
		var era := _era_index(String((_definitions[index] as Dictionary).get("era_id", "")))
		if era > best_era:
			best = index
			best_era = era
	if best >= 0:
		return best
	for index in range(mini(states.size(), _definitions.size())):
		if states[index] <= 0:
			continue
		var era := _era_index(String((_definitions[index] as Dictionary).get("era_id", "")))
		if era > best_era:
			best = index
			best_era = era
	return best


func _era_index(era_id: String) -> int:
	for index in range(_eras.size()):
		if String((_eras[index] as Dictionary).get("id", "")) == era_id:
			return index
	return 0


func _deepest_visible_era() -> int:
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	var deepest := 0
	for index in range(mini(states.size(), _definitions.size())):
		if states[index] <= 0:
			continue
		deepest = maxi(deepest, _era_index(String(
			(_definitions[index] as Dictionary).get("era_id", ""))))
	return deepest


func _set_policy_open(open: bool) -> void:
	_policy_open = true
	_policy_panel.visible = true
	_policy_toggle.button_pressed = true
	_policy_rail.visible = false
	_apply_drawer_layout()


func _set_detail_open(open: bool) -> void:
	_detail_open = open
	_detail_host.visible = open
	_detail_toggle.button_pressed = open
	_detail_rail.visible = not open
	if open:
		UIAnimation.fade_slide_in(_detail_host, Vector2(24.0, 0.0), UITokens.ANIM_MED)
	_apply_drawer_layout()


func _on_policy_pin_toggled(pressed: bool) -> void:
	_policy_pinned = true
	_policy_pin.set_pressed_no_signal(_policy_pinned)
	_apply_drawer_layout()


func _on_detail_pin_toggled(pressed: bool) -> void:
	_detail_pinned = pressed and size.x >= PIN_BREAKPOINT
	_detail_pin.set_pressed_no_signal(_detail_pinned)
	_apply_drawer_layout()


func _apply_drawer_layout() -> void:
	if _main == null:
		return
	var wide := size.x >= PIN_BREAKPOINT and not _compact
	_policy_pin.visible = false
	_detail_pin.visible = wide
	_policy_open = true
	_policy_pinned = true
	_policy_panel.visible = true
	_policy_toggle.visible = false
	_policy_rail.visible = false
	var policy_close := get_node_or_null(
		"Root/Main/PolicyPanel/Scroll/Body/Header/Close") as Control
	if policy_close != null:
		policy_close.visible = false
	if not wide:
		_detail_pinned = false
		_detail_pin.set_pressed_no_signal(false)
	_policy_panel.offset_right = POLICY_WIDTH
	_detail_host.offset_left = -DETAIL_ANCHOR_WIDTH
	var left_inset := POLICY_WIDTH
	var right_inset := DETAIL_WIDTH if _detail_open and _detail_pinned else DRAWER_RAIL_WIDTH
	for canvas in [_tree, _overview]:
		canvas.offset_left = left_inset
		canvas.offset_right = -right_inset
	_policy_rail.visible = false
	_detail_rail.visible = not _detail_open


func _configure_queues() -> void:
	for domain in range(mini(DOMAIN_COUNT, _queue_headers.size())):
		var accent := _domain_accent(domain)
		var header: Dictionary = _queue_headers[domain]
		(header.icon as IconBadge).set_semantic(
			IconCatalog.technology_domain_semantic(_domain_id(domain)), accent)
		var name_label := header.name as Label
		name_label.text = _domain_name(domain)
		name_label.add_theme_color_override("font_color",
			accent.lerp(UITokens.TEXT_MAIN, 0.52))


func _apply_research() -> void:
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	var progress: PackedInt64Array = _research.get("technology_progress", PackedInt64Array())
	var relations_changed := states != _last_states
	_last_states = states
	var lane_signature := 17
	for index in range(mini(states.size(), _definitions.size())):
		if states[index] <= 0:
			continue
		lane_signature = int((lane_signature * 31 + String((_definitions[index] as Dictionary).get(
			"domain_id", "")).hash()) & 0x7fffffff)
	if lane_signature != _lane_visibility_signature:
		_lane_visibility_signature = lane_signature
		_configure_lane_selector(states)
	_tree.patch_states(states, progress)
	if _overview.visible:
		_overview.patch_states(states)
	var weights: PackedInt32Array = _research.get("domain_weights_bp",
		PackedInt32Array([2500, 2500, 2500, 2500]))
	_dial.set_weights(weights)
	_budget.set_state(bool(_research.get("auto_purchase_enabled", false)),
		int(_research.get("daily_procurement_budget", 0)),
		int(_research.get("country_cash", 0)))
	_patch_queues(states, progress, weights)
	_update_status(states)
	if _initial_focus_pending:
		_apply_default_focus()
	_refresh_detail(relations_changed)


func _update_status(states: PackedInt32Array) -> void:
	var completed := 0
	var queued := 0
	for state in states:
		if state >= 5:
			completed += 1
		elif state == 3 or state == 4:
			queued += 1
	_set_chip("era", _current_era_label(states), "当前时代")
	_set_chip("points", UITokens.format_compact_number_cn(
		float(_research.get("technology_points_stock", 0)) / POINT_SCALE, 2),
		"国库科技值存量")
	_set_chip("treasury", UITokens.format_compact_number_cn(
		float(_research.get("country_cash", 0)) / CASH_SCALE, 2), "国库现金")
	_set_chip("queued", "%d 项在研" % queued, "研究队列与待生效科技数量")
	_set_chip("completed", "%d 项已掌握" % completed, "已掌握科技数量")
	_set_chip("purchased", UITokens.format_compact_number_cn(
		float(_research.get("purchased_total", 0)) / POINT_SCALE, 2), "累计采购科技值")


func _set_chip(id: String, text: String, tooltip: String) -> void:
	var value := _status_chips.get("%s_value" % id) as Label
	if value == null:
		return
	value.text = text
	value.tooltip_text = tooltip


# The current era is the deepest era whose milestone the country already holds,
# which never leaks how many eras remain.
func _current_era_label(states: PackedInt32Array) -> String:
	var reached := ""
	var pending := ""
	for index in range(mini(states.size(), _definitions.size())):
		var definition: Dictionary = _definitions[index]
		var era_id := String(definition.get("era_id", ""))
		var era_name := String(_era_names.get(era_id, era_id))
		if states[index] >= 5:
			reached = era_name
		elif states[index] >= 1 and pending.is_empty():
			pending = era_name
	if reached.is_empty():
		return pending if not pending.is_empty() else "—"
	return reached


func _patch_queues(states: PackedInt32Array, progress: PackedInt64Array,
		weights: PackedInt32Array) -> void:
	var offsets: PackedInt32Array = _research.get(
		"queue_offsets", PackedInt32Array([0, 0, 0, 0, 0]))
	var technologies: PackedInt32Array = _research.get(
		"queue_technology_indices", PackedInt32Array())
	if offsets.size() < DOMAIN_COUNT + 1:
		return
	var signature := "%s|%s" % [offsets, technologies]
	if signature != _queue_signature:
		_queue_signature = signature
		_rebuild_queue_rows(offsets, technologies)
	var total_weight := 0
	for weight in weights:
		total_weight += int(weight)
	for domain in range(DOMAIN_COUNT):
		var header: Dictionary = _queue_headers[domain]
		var share := 0.0
		if total_weight > 0 and domain < weights.size():
			share = float(weights[domain]) * 100.0 / float(total_weight)
		(header.share as Label).text = "%d%%" % int(round(share))
		for row in _queue_rows[domain]:
			var index := int(row.technology_index)
			var state := int(states[index]) if index < states.size() else 0
			var cost := maxf(1.0, float((_definitions[index] as Dictionary).get(
				"cost_points", 1)))
			var earned := float(progress[index]) / POINT_SCALE \
				if index < progress.size() else 0.0
			row.update_dynamic(state, earned / cost)


func _rebuild_queue_rows(offsets: PackedInt32Array,
		technologies: PackedInt32Array) -> void:
	for domain in range(DOMAIN_COUNT):
		var zone = _queue_zones[domain]
		zone.clear_rows()
		_queue_rows[domain] = []
		zone.append_position = offsets[domain + 1] - offsets[domain]
		if offsets[domain + 1] <= offsets[domain]:
			zone.set_empty_hint(true)
			continue
		zone.set_empty_hint(false)
		for position in range(offsets[domain], offsets[domain + 1]):
			if position < 0 or position >= technologies.size():
				continue
			var technology := int(technologies[position])
			if technology < 0 or technology >= _definitions.size():
				continue
			var row = TechnologyQueueRowScene.instantiate()
			zone.add_child(row)
			row.setup(technology, domain, position - offsets[domain],
				String((_definitions[technology] as Dictionary).get("display_name", "")),
				_domain_accent(domain))
			row.move_requested.connect(_move_in_queue)
			row.remove_requested.connect(_remove_from_queue)
			row.selected_requested.connect(_focus_technology)
			_queue_rows[domain].append(row)


func _refresh_detail(refresh_relations: bool = true) -> void:
	var index := int(_tree.selected_technology())
	if index < 0 or index >= _definitions.size():
		_detail_signature = ""
		_detail.show_empty()
		return
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	var state := int(states[index]) if index < states.size() else 0
	if state <= 0:
		_detail_signature = ""
		_detail.show_unknown()
		return
	var definition: Dictionary = _definitions[index]
	var progress: PackedInt64Array = _research.get(
		"technology_progress", PackedInt64Array())
	var cost := maxf(1.0, float(definition.get("cost_points", 1)))
	var earned := float(progress[index]) / POINT_SCALE if index < progress.size() else 0.0
	if not refresh_relations and not _detail_signature.is_empty():
		_detail.update_progress(state, earned / cost, definition)
		return
	var relations := _relations_for(index, states)
	# Relation rows are the only part that allocates nodes, so they are rebuilt
	# only when the selection or any related state actually changed.
	var signature := "%d:%d:%s" % [index, state, _relation_signature(relations)]
	if signature == _detail_signature:
		_detail.update_progress(state, earned / cost, definition)
		return
	_detail_signature = signature
	var domain := _domain_index_of(definition)
	_detail.show_technology(index, definition, state, earned / cost,
		_domain_accent(domain),
		String(_era_names.get(String(definition.get("era_id", "")),
			String(definition.get("era_id", "")))),
		_domain_name(domain), relations)


func _relation_signature(relations: Dictionary) -> String:
	var parts := PackedStringArray()
	for group in ["prerequisites", "successors"]:
		for entry in relations.get(group, []) as Array:
			parts.append("%d" % int((entry as Dictionary).get("state", 0)))
		parts.append("/")
	for entry in relations.get("condition_items", []) as Array:
		parts.append(String((entry as Dictionary).get("text", "")))
		parts.append("|")
	return "".join(parts)


func _relations_for(index: int, states: PackedInt32Array) -> Dictionary:
	var layout: Dictionary = _tree.layout_report()
	var prerequisites: Array = []
	var successors: Array = []
	for edge_value in layout.get("edges", []):
		var edge: Dictionary = edge_value
		var from := int(edge.get("from", -1))
		var to := int(edge.get("to", -1))
		var kind := String(edge.get("kind", "hard"))
		if kind == "hard" and to == index:
			prerequisites.append(_relation_entry(from, states))
		elif from == index:
			successors.append(_relation_entry(to, states, _relation_prefix(kind, true)))
		elif to == index and kind != "hard":
			successors.append(_relation_entry(from, states, _relation_prefix(kind, false)))
	return {
		"prerequisites": prerequisites,
		"successors": successors,
		"condition_items": _condition_items(index, states),
	}


func _relation_entry(index: int, states: PackedInt32Array, prefix: String = "") -> Dictionary:
	var state := int(states[index]) if index < states.size() else 0
	if state <= 0:
		return {"name": "未知科技", "state": 0}
	var name := String((_definitions[index] as Dictionary).get("display_name", ""))
	return {
		"name": ("%s · %s" % [prefix, name]) if not prefix.is_empty() else name,
		"state": state,
	}


func _relation_prefix(kind: String, outgoing: bool) -> String:
	match kind:
		"hard": return "硬后继" if outgoing else "硬前置"
		"alternative": return "替代证据"
		"application": return "应用交汇"
		"milestone_candidate": return "里程碑候选"
	return "网络关系"


func _condition_items(index: int, states: PackedInt32Array) -> Array:
	if index < 0 or index >= _definitions.size():
		return []
	var spec: Dictionary = (_definitions[index] as Dictionary).get(
		"reveal_condition", {})
	if spec.is_empty():
		return []
	var result := _evaluate_condition(spec, states, _signal_evidence())
	var inspirations: Array = []
	for item_value in result.get("items", []) as Array:
		var item: Dictionary = item_value
		if String(item.get("source_kind", "")) != "signal" \
				or not bool(item.get("met", false)):
			continue
		var inspiration := item.duplicate()
		inspiration["text"] = "启发线索 · %s" % String(item.get("text", ""))
		inspirations.append(inspiration)
	return inspirations


func _signal_evidence() -> Dictionary:
	var snapshot: Dictionary = _research.get("research_signal_snapshot", {})
	var dense_ids: PackedInt32Array = snapshot.get("signal_ids", PackedInt32Array())
	var counts: PackedInt32Array = snapshot.get("counts", PackedInt32Array())
	var first_days: PackedInt64Array = snapshot.get("first_days", PackedInt64Array())
	var first_cells: PackedInt32Array = snapshot.get("first_cells", PackedInt32Array())
	var evidence := {}
	for cursor in range(dense_ids.size()):
		evidence[int(dense_ids[cursor])] = {
			"count": int(counts[cursor]) if cursor < counts.size() else 0,
			"first_day": int(first_days[cursor]) if cursor < first_days.size() else -1,
			"first_cell": int(first_cells[cursor]) if cursor < first_cells.size() else -1,
		}
	return evidence


func _evaluate_condition(spec: Dictionary, states: PackedInt32Array,
		evidence: Dictionary) -> Dictionary:
	if spec.has("kind"):
		return _evaluate_condition_atom(spec, states, evidence)
	var children: Array = spec.get("children", [])
	var operator := int(spec.get("operator", ResearchConditionScript.Operator.ATOM))
	if operator == ResearchConditionScript.Operator.ATOM:
		return _evaluate_condition_atom(spec.get("atom", {}), states, evidence)
	var child_results: Array = []
	var met_count := 0
	var items: Array = []
	for child in children:
		var result := _evaluate_condition(child as Dictionary, states, evidence)
		child_results.append(result)
		met_count += 1 if bool(result.get("met", false)) else 0
		items.append_array(result.get("items", []))
	var met := false
	match operator:
		ResearchConditionScript.Operator.ALL_OF:
			met = met_count == children.size()
		ResearchConditionScript.Operator.ANY_OF:
			met = met_count > 0
		ResearchConditionScript.Operator.AT_LEAST:
			met = met_count >= int(spec.get("required_count", 1))
		ResearchConditionScript.Operator.NOT:
			met = child_results.size() == 1 and not bool(
				(child_results[0] as Dictionary).get("met", false))
	return {"met": met, "items": items}


func _evaluate_condition_atom(atom: Dictionary, states: PackedInt32Array,
		evidence: Dictionary) -> Dictionary:
	var kind := int(atom.get("kind", -1))
	var stable_id := String(atom.get("id", atom.get("reference_id", "")))
	var required := maxi(1, int(atom.get("value", 1)))
	if kind == ResearchPredicateScript.Kind.TECH_COMPLETED:
		var technology_index := int(_technology_indices.get(stable_id, -1))
		var technology_state := int(states[technology_index]) \
			if technology_index >= 0 and technology_index < states.size() else 0
		var met := technology_state >= 4
		var technology_name := "未知科技"
		if technology_state > 0 and technology_index < _definitions.size():
			technology_name = String((_definitions[technology_index] as Dictionary).get(
				"display_name", technology_name))
		return {
			"met": met,
			"items": [{
				"text": "前置科技：%s（%s）" % [
					technology_name, "已完成" if met else "未完成"],
				"icon": &"technology.state.completed" if met else &"technology.state.locked",
				"accent": UITokens.GOOD if met else UITokens.WARN,
				"source_kind": "technology",
				"met": met,
			}],
		}
	if kind not in [ResearchPredicateScript.Kind.SIGNAL_PRESENT,
			ResearchPredicateScript.Kind.SIGNAL_COUNT]:
		return {"met": false, "items": []}
	var signal_index := int(_signal_indices.get(stable_id, -1))
	var row: Dictionary = evidence.get(signal_index, {})
	var count := int(row.get("count", 0))
	var target := required if kind == ResearchPredicateScript.Kind.SIGNAL_COUNT else 1
	var met := count >= target
	var name := String(_signal_names.get(stable_id, stable_id))
	var source := ""
	if count > 0:
		source = "，首次记录：第 %d 日 / 地块 %d" % [
			int(row.get("first_day", -1)), int(row.get("first_cell", -1))]
	return {
		"met": met,
		"items": [{
			"text": "%s：%s %d/%d%s" % [
				"证据" if met else "阻塞", name, count, target, source],
			"icon": &"technology.state.completed" if met else &"technology.state.locked",
			"accent": UITokens.GOOD if met else UITokens.WARN,
			"source_kind": "signal",
			"met": met,
		}],
	}


func _on_tree_selected(_index: int) -> void:
	_manual_focus = true
	_set_detail_open(true)
	_refresh_detail()


func _on_tree_activated(index: int) -> void:
	var states: PackedInt32Array = _research.get("technology_states", PackedInt32Array())
	var state := int(states[index]) if index < states.size() else 0
	if state == 3:
		_remove_from_queue(index)
		return
	if state == 2:
		_enqueue(index)


func _on_weights_previewed(weights_bp: PackedInt32Array) -> void:
	var total := 0
	for weight in weights_bp:
		total += int(weight)
	for domain in range(mini(DOMAIN_COUNT, _queue_headers.size())):
		var share := 0.0
		if total > 0 and domain < weights_bp.size():
			share = float(weights_bp[domain]) * 100.0 / float(total)
		((_queue_headers[domain] as Dictionary).share as Label).text = \
			"%d%%" % int(round(share))


func _on_weights_committed(weights_bp: PackedInt32Array) -> void:
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_SET_WEIGHTS, {"weights_bp": weights_bp})
	if bool(result.get("ok", false)):
		policy_submitted.emit()


func _on_budget_committed(enabled: bool, daily_cash_limit: int) -> void:
	if _player_controller == null:
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_SET_BUDGET,
		{"enabled": enabled, "daily_cash_limit": daily_cash_limit})
	if bool(result.get("ok", false)):
		policy_submitted.emit()


func _enqueue(index: int) -> void:
	if _player_controller == null or index < 0 or index >= _definitions.size():
		return
	var definition: Dictionary = _definitions[index]
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_ENQUEUE,
		{"technology_id": StringName(definition.get("id", "")),
		"domain": _domain_index_of(definition)})
	if bool(result.get("ok", false)):
		_detail.mark_submitted()
		policy_submitted.emit()


func _remove_from_queue(index: int) -> void:
	if _player_controller == null or index < 0 or index >= _definitions.size():
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_REMOVE,
		{"technology_id": StringName((_definitions[index] as Dictionary).get("id", ""))})
	if bool(result.get("ok", false)):
		_detail.mark_submitted()
		policy_submitted.emit()


func _move_in_queue(technology: int, domain: int, position: int) -> void:
	if _player_controller == null or technology < 0 or technology >= _definitions.size():
		return
	var result: Dictionary = _player_controller.request_command(
		PlayerControllerScript.COMMAND_RESEARCH_MOVE,
		{"technology_id": StringName((_definitions[technology] as Dictionary).get("id", "")),
		"domain": domain, "position": position})
	if bool(result.get("ok", false)):
		policy_submitted.emit()


func _domain_index_of(definition: Dictionary) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for domain in range(_domains.size()):
		if String((_domains[domain] as Dictionary).get("id", "")) == domain_id:
			return domain
	return maxi(0, ["agriculture", "engineering", "science", "society"].find(domain_id))


func _domain_id(domain: int) -> String:
	if domain < _domains.size():
		return String((_domains[domain] as Dictionary).get("id", ""))
	return ""


func _domain_name(domain: int) -> String:
	if domain < _domains.size():
		return String((_domains[domain] as Dictionary).get("display_name", ""))
	return ""


func _domain_accent(domain: int) -> Color:
	if domain < _domains.size():
		return (_domains[domain] as Dictionary).get("accent", UITokens.ACCENT)
	return UITokens.ACCENT
