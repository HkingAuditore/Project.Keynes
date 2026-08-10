extends Control
class_name TechnologyWorkspace

const PlayerControllerScript = preload("res://scripts/game/player_controller.gd")

# Full-bleed research screen: an icon-led status strip, a policy column driven by
# direct manipulation, the self-drawn technology tree, and a detail card. Every
# control commits on release, so there is no submit button anywhere.

signal policy_submitted()

const TechnologyQueueRowScene := preload("res://scenes/ui/technology_queue_row.tscn")

const CASH_SCALE := 10000.0
const POINT_SCALE := 1000.0
const POLICY_WIDTH := 234.0
const POLICY_WIDTH_COMPACT := 206.0
const DETAIL_WIDTH := 292.0
const DETAIL_WIDTH_COMPACT := 238.0
const DOMAIN_COUNT := 4

var _player_controller = null
var _definitions: Array = []
var _eras: Array = []
var _domains: Array = []
var _era_names: Dictionary = {}
var _research: Dictionary = {}
var _queue_signature := ""
var _detail_signature := ""

var _status_chips: Dictionary = {}
var _policy_panel: PanelContainer
var _dial: Control
var _budget: Control
var _tree: Control
var _detail: Control
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
		"detail": "Root/Main/Detail",
	}
	_policy_panel = get_node_or_null(required_paths.policy_panel) as PanelContainer
	_dial = get_node_or_null(required_paths.dial) as Control
	_budget = get_node_or_null(required_paths.budget) as Control
	_tree = get_node_or_null(required_paths.tree) as Control
	_detail = get_node_or_null(required_paths.detail) as Control
	if _policy_panel == null or _dial == null or _budget == null \
			or _tree == null or _detail == null:
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
	_detail.enqueue_requested.connect(_enqueue)
	_detail.remove_requested.connect(_remove_from_queue)


func set_model(model: Dictionary) -> void:
	if _tree == null:
		_ready()
	_research = model.get("research", {})
	if _definitions.is_empty():
		_definitions = model.get("technology_definitions", [])
		_eras = model.get("technology_eras", [])
		_domains = model.get("technology_domains", [])
		for era in _eras:
			_era_names[String((era as Dictionary).get("id", ""))] = \
				String((era as Dictionary).get("display_name", ""))
		if not _definitions.is_empty():
			_tree.set_catalog(_definitions, _eras, _domains)
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
	_policy_panel.custom_minimum_size.x = POLICY_WIDTH_COMPACT if compact else POLICY_WIDTH
	_detail.custom_minimum_size.x = DETAIL_WIDTH_COMPACT if compact else DETAIL_WIDTH
	for key in ["purchased", "completed"]:
		var chip := _status_chips.get(key) as Control
		if chip != null:
			chip.visible = not compact


func tree_view() -> Control:
	return _tree


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
	_tree.patch_states(states, progress)
	var weights: PackedInt32Array = _research.get("domain_weights_bp",
		PackedInt32Array([2500, 2500, 2500, 2500]))
	_dial.set_weights(weights)
	_budget.set_state(bool(_research.get("auto_purchase_enabled", false)),
		int(_research.get("daily_procurement_budget", 0)),
		int(_research.get("country_cash", 0)))
	_patch_queues(states, progress, weights)
	_update_status(states)
	_refresh_detail()


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
			_queue_rows[domain].append(row)


func _refresh_detail() -> void:
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
	return "".join(parts)


func _relations_for(index: int, states: PackedInt32Array) -> Dictionary:
	var layout: Dictionary = _tree.layout_report()
	var parents: Array = layout.get("parents", [])
	var children: Array = layout.get("children", [])
	var prerequisites: Array = []
	var successors: Array = []
	if index < parents.size():
		for parent in parents[index]:
			prerequisites.append(_relation_entry(int(parent), states))
	if index < children.size():
		for child in children[index]:
			successors.append(_relation_entry(int(child), states))
	return {"prerequisites": prerequisites, "successors": successors}


func _relation_entry(index: int, states: PackedInt32Array) -> Dictionary:
	var state := int(states[index]) if index < states.size() else 0
	if state <= 0:
		return {"name": "未知科技", "state": 0}
	return {
		"name": String((_definitions[index] as Dictionary).get("display_name", "")),
		"state": state,
	}


func _on_tree_selected(_index: int) -> void:
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
