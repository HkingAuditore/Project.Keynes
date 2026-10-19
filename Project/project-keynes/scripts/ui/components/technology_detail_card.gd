extends PanelContainer
class_name TechnologyDetailCard

const RelationRowScene := preload("res://scenes/ui/technology_relation_row.tscn")
const TechnologyEffectTextScript := preload(
	"res://scripts/ui/components/technology_effect_text.gd")

signal enqueue_requested(index: int)
signal remove_requested(index: int)

const STATE_NAMES := ["未知", "已知但未就绪", "可研究", "研究队列中", "待生效", "已掌握"]

var _index := -1
var _state := 0
var _submitted := false
var _accent: Color = UITokens.ACCENT
var _header_icon: IconBadge
var _name: Label
var _state_label: Label
var _summary: Label
var _chips: TechnologyFactSheet
var _gauge: TechnologyProgressBlock
var _condition_title: Label
var _conditions: InsightList
var _effect_title: Label
var _effects: InsightList
var _body: VBoxContainer
var _detail_block: VBoxContainer
var _prerequisite_title: Label
var _prerequisites: VBoxContainer
var _hard_successor_title: Label
var _hard_successors: VBoxContainer
var _branch_successor_title: Label
var _branch_successors: VBoxContainer
var _application_title: Label
var _applications: VBoxContainer
var _action: Button
var _placeholder: Label
var _scroll: ScrollContainer


func _ready() -> void:
	if _body != null:
		return
	_body = get_node_or_null("%Body") as VBoxContainer
	_header_icon = get_node_or_null("%HeaderIcon") as IconBadge
	_name = get_node_or_null("%NameLabel") as Label
	_state_label = get_node_or_null("%StateLabel") as Label
	_placeholder = get_node_or_null("%Placeholder") as Label
	_detail_block = get_node_or_null("%DetailBlock") as VBoxContainer
	_summary = get_node_or_null("%Summary") as Label
	_chips = get_node_or_null("%Chips") as TechnologyFactSheet
	_gauge = get_node_or_null("%Gauge") as TechnologyProgressBlock
	_condition_title = get_node_or_null("%ConditionTitle") as Label
	_conditions = get_node_or_null("%Conditions") as InsightList
	_effect_title = get_node_or_null("%EffectTitle") as Label
	_effects = get_node_or_null("%Effects") as InsightList
	_prerequisite_title = get_node_or_null("%PrerequisiteTitle") as Label
	_prerequisites = get_node_or_null("%Prerequisites") as VBoxContainer
	_hard_successor_title = get_node_or_null("%HardSuccessorTitle") as Label
	_hard_successors = get_node_or_null("%HardSuccessors") as VBoxContainer
	_branch_successor_title = get_node_or_null("%BranchSuccessorTitle") as Label
	_branch_successors = get_node_or_null("%BranchSuccessors") as VBoxContainer
	_application_title = get_node_or_null("%ApplicationTitle") as Label
	_applications = get_node_or_null("%Applications") as VBoxContainer
	_action = get_node_or_null("%Action") as Button
	_scroll = get_node_or_null("Column/Scroll") as ScrollContainer
	if _body == null or _header_icon == null or _name == null \
			or _state_label == null or _placeholder == null \
			or _detail_block == null or _chips == null or _gauge == null \
			or _summary == null or _conditions == null or _condition_title == null \
			or _effect_title == null \
			or _effects == null or _prerequisite_title == null \
			or _prerequisites == null or _hard_successor_title == null \
			or _hard_successors == null or _branch_successor_title == null \
			or _branch_successors == null or _application_title == null \
			or _applications == null or _action == null:
		push_error("TechnologyDetailCard 必须通过 technology_detail_card.tscn 实例化。")
		return
	_header_icon.set_semantic(&"country.technology", UITokens.DOSSIER_UMBER)
	_action.pressed.connect(_on_action_pressed)
	show_empty()


func show_empty() -> void:
	if _body == null:
		_ready()
	_index = -1
	_state = 0
	_submitted = false
	_header_icon.set_semantic(&"country.technology", UITokens.DOSSIER_INK_MUTED)
	_name.text = "科技详情"
	_state_label.text = "尚未选择"
	_state_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_placeholder.visible = true
	_placeholder.text = "在可研究清单或科技树中选择一项科技，查看成本、效果与前置。"
	_detail_block.visible = false
	_action.visible = false


func show_unknown(condition_items: Array = [], state: int = 0) -> void:
	if _body == null:
		_ready()
	_index = -1
	_state = 0
	_submitted = false
	_header_icon.set_semantic(&"technology.state.unknown", UITokens.DOSSIER_INK_MUTED)
	_header_icon.tooltip_text = ""
	_name.text = "未知科技"
	_state_label.text = STATE_NAMES[clampi(state, 0, 1)]
	_state_label.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	_placeholder.visible = true
	_placeholder.text = "按以下条件发现并解锁研究。名称、成本与效果将在可研究时显示。"
	_detail_block.visible = true
	for child in _detail_block.get_children():
		child.visible = child == _condition_title or child == _conditions
	_condition_title.text = "发现与研究条件"
	_conditions.set_items(condition_items)
	_action.visible = false


func show_milestone_locked(era_name: String, completed: int, required: int,
		condition_items: Array = []) -> void:
	show_unknown(condition_items)
	_header_icon.set_semantic(&"technology.milestone", UITokens.DOSSIER_BRASS)
	_name.text = "时代里程碑"
	_state_label.text = era_name
	_state_label.add_theme_color_override("font_color", UITokens.DOSSIER_BRASS)
	_placeholder.visible = true
	_placeholder.text = "完成本时代 %d / %d 项后可研究此关隘。可研究后显示名称与效果。" \
		% [completed, maxi(1, required)]
	_action.visible = false


func show_technology(index: int, definition: Dictionary, state: int, fraction: float,
		accent: Color, era_name: String, domain_name: String,
		relations: Dictionary) -> void:
	if _body == null:
		_ready()
	var saved_scroll := Vector2i.ZERO
	if _scroll != null:
		saved_scroll = Vector2i(_scroll.scroll_horizontal, _scroll.scroll_vertical)
	var selection_changed := _index != index
	_index = index
	_state = state
	_accent = accent
	_placeholder.visible = false
	_detail_block.visible = true
	_chips.visible = true
	for host in [_prerequisites, _hard_successors, _branch_successors, _applications]:
		host.visible = true
	_submitted = false
	_header_icon.set_semantic(IconCatalog.technology_domain_semantic(
		String(definition.get("domain_id", ""))), accent)
	_header_icon.tooltip_text = "%s · %s" % [domain_name, era_name]
	_name.text = String(definition.get("display_name", ""))
	var is_application := _is_application(definition)
	_state_label.text = _application_state_name(state) if is_application \
		else STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]
	_state_label.add_theme_color_override("font_color", _state_colour(state))
	var summary := String(definition.get("effect_summary", "")).strip_edges()
	_summary.text = summary
	_chips.set_facts(_facts_for(definition, era_name, domain_name, is_application))
	_gauge.visible = not is_application
	if not is_application:
		_gauge.set_progress(fraction, _progress_caption(definition, fraction, state),
			accent, state)
	var condition_items: Array = relations.get("condition_items", [])
	_condition_title.text = "应用条件" if is_application else "研究条件"
	_condition_title.visible = not condition_items.is_empty()
	_conditions.visible = not condition_items.is_empty()
	_conditions.set_items(condition_items)
	var effect_items := _effect_items(definition)
	# Without structured effects the bullet list is the summary split apart;
	# showing both would print every effect twice.
	var structured := not (definition.get("content_effects", []) as Array).is_empty() \
		or not (definition.get("modifier_terms", []) as Array).is_empty()
	_summary.visible = not summary.is_empty() and structured
	_effect_title.text = "启用后效果" if is_application else "掌握后效果"
	_effect_title.visible = not effect_items.is_empty()
	_effects.visible = not effect_items.is_empty()
	_effects.set_items(effect_items)
	var required := int(definition.get("milestone_required_count", 0))
	var prerequisites: Array = relations.get("prerequisites", [])
	if is_application:
		_prerequisite_title.text = "应用所需科技"
	elif required > 0:
		_prerequisite_title.text = "里程碑候选（任选 %d 项）" % required
	else:
		_prerequisite_title.text = "需要先完成"
	_prerequisite_title.visible = not prerequisites.is_empty()
	_fill_relation_rows(_prerequisites, prerequisites)
	var hard_successors: Array = relations.get("hard_successors", [])
	_hard_successor_title.text = "完成后可解锁"
	_hard_successor_title.visible = not hard_successors.is_empty()
	_fill_relation_rows(_hard_successors, hard_successors)
	var branch_successors: Array = relations.get("branch_successors", [])
	_branch_successor_title.visible = not branch_successors.is_empty()
	_fill_relation_rows(_branch_successors, branch_successors)
	var applications: Array = relations.get("applications", [])
	_application_title.visible = not applications.is_empty()
	_fill_relation_rows(_applications, applications)
	if is_application:
		_action.visible = false
	else:
		_apply_action(state)
	_restore_scroll.call_deferred(saved_scroll)
	if selection_changed and not UIAnimation.reduced_motion():
		UIAnimation.crossfade(_detail_block, UITokens.ANIM_MED)


# Daily ticks take this path: gauge value, state text and the action button only.
func update_progress(state: int, fraction: float, definition: Dictionary) -> void:
	if _index < 0 or _detail_block == null or not _detail_block.visible:
		return
	var previous_state := _state
	_state = state
	var is_application := _is_application(definition)
	if state != previous_state:
		# Theme overrides re-run theme propagation and layout; daily ticks only
		# move the gauge, so restyle on real state changes.
		_state_label.text = _application_state_name(state) if is_application \
			else STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]
		_state_label.add_theme_color_override("font_color", _state_colour(state))
	_gauge.visible = not is_application
	if not is_application:
		_gauge.set_progress(fraction, _progress_caption(definition, fraction, state),
			_accent, state)
	# Clear optimistic "次日生效" once the authoritative state actually moves,
	# or once the node is observably queued (state 3) / finished (state >= 4).
	if _submitted and (state != previous_state or state == 3 or state >= 4):
		_submitted = false
	if not _submitted and not is_application:
		_apply_action(state)
	elif is_application:
		_action.visible = false


## Daily schedule line beside the progress bar (ETA or queue position).
func set_schedule(text: String) -> void:
	if _gauge != null:
		_gauge.set_schedule(text)


func schedule_text() -> String:
	return _gauge.schedule_text() if _gauge != null else ""


func _facts_for(definition: Dictionary, era_name: String, domain_name: String,
		is_application: bool) -> Array:
	var facts: Array = [
		{"key": "时代", "value": era_name},
		{"key": "领域", "value": domain_name},
	]
	if is_application:
		facts.append({"key": "类型", "value": "静态应用 · 前置齐备后自动启用"})
		var chain_name := String(definition.get("industry_chain_display_name", ""))
		if not chain_name.is_empty():
			facts.append({"key": "产业链", "value": chain_name})
		var step := int(definition.get("progression_step", 0))
		if step > 0:
			facts.append({"key": "产业步骤", "value": "第 %d 步" % step})
		var traits := PackedStringArray()
		for maturity_name in definition.get("maturity_display_names", PackedStringArray()):
			traits.append(String(maturity_name))
		for role in definition.get("progression_roles", PackedStringArray()):
			traits.append(_progression_role_name(String(role)))
		if not traits.is_empty():
			facts.append({"key": "定位", "value": "、".join(traits)})
	else:
		facts.append({"key": "研究成本", "value": "%s 科技值" % _cost_text(definition)})
	if bool(definition.get("is_milestone", false)):
		facts.append({"key": "类型", "value": "时代里程碑", "accent": UITokens.DOSSIER_OXBLOOD})
	elif bool(definition.get("is_era_key", false)):
		facts.append({"key": "类型", "value": "时代关键科技", "accent": UITokens.DOSSIER_OXBLOOD})
	var route_tags: PackedStringArray = definition.get("route_tags", PackedStringArray())
	var route_names: PackedStringArray = definition.get(
		"route_display_names", PackedStringArray())
	var routes := PackedStringArray()
	for route_index in range(route_tags.size()):
		routes.append(String(route_names[route_index]) \
			if route_index < route_names.size() else String(route_tags[route_index]))
	if not routes.is_empty():
		facts.append({"key": "研究路线", "value": "、".join(routes)})
	return facts


func _cost_text(definition: Dictionary) -> String:
	var cost_scaled := maxf(1.0, float(definition.get("cost_points_scaled",
		float(definition.get("cost_points", 0)) * 1000.0)))
	var points := cost_scaled / 1000.0
	if points < 0.1:
		return "<0.1"
	return UITokens.format_compact_number_cn(points, 1)


func _progress_caption(definition: Dictionary, fraction: float, state: int) -> String:
	if state >= 5:
		return "已掌握"
	if state == 4:
		return "研究完成 · 次日生效"
	if state <= 1:
		return "尚未开始"
	# Derive from the scaled cost: cost_points is an integer point count and
	# reads 0 for anything cheaper than one point, so a node that still owed
	# research points advertised 「还需 0」.
	var cost_scaled := maxf(1.0, float(definition.get("cost_points_scaled",
		float(definition.get("cost_points", 0)) * 1000.0)))
	var remaining_scaled := maxf(
		0.0, cost_scaled * (1.0 - clampf(fraction, 0.0, 1.0)))
	var remaining := remaining_scaled / 1000.0
	if remaining > 0.0 and remaining < 0.1:
		return "还需 <0.1 科技值"
	return "还需 %s 科技值" % UITokens.format_compact_number_cn(remaining, 1)


func _is_application(definition: Dictionary) -> bool:
	return bool(definition.get("is_application", false)) \
		or String(definition.get("anchor_kind", "")) == "application" \
		or String(definition.get("id", "")).begins_with("app.")


func _application_state_name(state: int) -> String:
	return "应用能力已启用" if state >= 5 else "应用条件未满足"


func _progression_role_name(role: String) -> String:
	match role:
		"mainline": return "主线产业"
		"geographic_specialization": return "地理专门化"
		"institutional_variant": return "制度变体"
		"terminal": return "产业终点"
	return role


## 效果行的唯一实现在 TechnologyEffectText：可研究清单的悬停提示共用同一份，
## 否则两边会各自漏掉不同的效果类别。
func _effect_items(definition: Dictionary) -> Array:
	return TechnologyEffectTextScript.effect_items(definition)


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
			UITokens.DOSSIER_INK_SOFT if TechnologyTreeView.presents_state(state) \
			else UITokens.DOSSIER_INK_MUTED)
		host.add_child(row)


func _restore_scroll(saved_scroll: Vector2i) -> void:
	if _scroll == null:
		return
	_scroll.set_deferred("scroll_horizontal", saved_scroll.x)
	_scroll.set_deferred("scroll_vertical", saved_scroll.y)


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


func mark_rejected(message: String) -> void:
	if _action == null:
		return
	_submitted = false
	_action.disabled = _state != 2 and _state != 3
	_action.visible = true
	var trimmed := message.strip_edges()
	_action.text = trimmed if not trimmed.is_empty() else "提交失败"
	_action.tooltip_text = trimmed


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
			return UITokens.DOSSIER_OXBLOOD
		3:
			return UITokens.DOSSIER_SLATE
		4:
			return UITokens.DOSSIER_BRASS.lerp(UITokens.DOSSIER_INK, 0.25)
		5:
			return UITokens.DOSSIER_VERDIGRIS
		_:
			return UITokens.DOSSIER_INK_MUTED
