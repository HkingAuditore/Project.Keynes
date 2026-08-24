extends Control
class_name TechnologyTreeView

signal technology_selected(index: int)
signal technology_activated(index: int)
signal portal_requested(index: int)

const LayoutScript = preload("res://scripts/ui/technology_tree_layout.gd")
const VIEW_PADDING := 34.0
const NAME_FONT_SIZE := 18
const NAME_FONT_MIN_SIZE := 14
const ERA_FONT_SIZE := 16
const PORTAL_SIZE := Vector2(26.0, 24.0)
const BAND_PAPER_FOCUS := Color(0.975, 0.94, 0.84, 1.0)
const BAND_PAPER_ADJACENT := Color(0.91, 0.845, 0.70, 1.0)
const CARD_PAPER := Color(0.965, 0.925, 0.82, 0.98)
const CARD_PAPER_DIM := Color(0.89, 0.83, 0.70, 0.96)
const CARD_PAPER_UNKNOWN := Color(0.80, 0.75, 0.65, 0.96)
const SELECTED_WALNUT := Color(0.20, 0.105, 0.052, 0.985)
const STATE_NAMES := ["未知", "已揭示", "可研究", "研究队列", "待生效", "已掌握"]
# Names and effects are shown only when the node is researchable or later.
# State 1 (revealed, hard prerequisites incomplete) stays fogged like unknown.
const PRESENTED_MIN_STATE := 2


static func presents_state(state: int) -> bool:
	return state >= PRESENTED_MIN_STATE


var _accents: Array[Color] = []
var _definitions: Array = []
var _eras: Array = []
var _domains: Array = []
var _visual_edges: Array = []
var _layout: Dictionary = {}
var _focus_layout: Dictionary = {}
var _parents: Array = []
var _children: Array = []
var _states := PackedInt32Array()
var _progress := PackedInt64Array()
var _visible_nodes := PackedByteArray()
var _known_nodes := PackedByteArray()
var _selected := -1
var _hovered := -1
var _hovered_portal := -1
var _chain_up := {}
var _chain_down := {}
var _domain_id := ""
var _focus_era := 0
var _offset := Vector2.ZERO
var _panning := false
var _card_styles: Dictionary = {}
var _name_font: Font = UITokens.font_with_weight(640)
var _visibility_signature := 0
var _portal_slots: Dictionary = {}
var _canvas_key := Vector2i.ZERO


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func set_catalog(definitions: Array, eras: Array, domains: Array,
		visual_edges: Array = []) -> void:
	if not _definitions.is_empty() or definitions.is_empty():
		return
	_definitions = definitions
	_eras = eras
	_domains = domains
	_visual_edges = visual_edges
	_accents.clear()
	for domain in domains:
		_accents.append((domain as Dictionary).get("accent", UITokens.ACCENT))
	_layout = LayoutScript.build(definitions, eras, domains, visual_edges)
	_parents = _layout.get("parents", [])
	_children = _layout.get("children", [])
	_visible_nodes.resize(definitions.size())
	_known_nodes.resize(definitions.size())
	if not definitions.is_empty():
		_domain_id = String((definitions[0] as Dictionary).get("domain_id", ""))
	_rebuild_focus()


func patch_states(states: PackedInt32Array, progress: PackedInt64Array) -> void:
	var state_changed := states != _states
	_states = states
	_progress = progress
	if state_changed:
		var signature := _recompute_visibility()
		if signature != _visibility_signature:
			_visibility_signature = signature
			_rebuild_focus(false)
	if _selected >= 0 and not _is_visible(_selected) and not _focus_contains(_selected):
		_selected = -1
		_chain_up.clear()
		_chain_down.clear()
	queue_redraw()


func set_focus(domain_id: String, era_index: int, preferred_index: int = -1) -> void:
	if not domain_id.is_empty():
		_domain_id = domain_id
	_focus_era = clampi(era_index, 0, maxi(0, _eras.size() - 1))
	_rebuild_focus()
	if preferred_index >= 0 and _focus_contains(preferred_index):
		select_technology(preferred_index)
	_center_content()
	queue_redraw()


func focus_domain() -> String:
	return _domain_id


func focus_lane() -> String:
	return _domain_id


func focus_era() -> int:
	return _focus_era


func focus_report() -> Dictionary:
	return _focus_layout


func selected_technology() -> int:
	return _selected


func select_technology(index: int) -> void:
	if index < 0 or index >= _definitions.size():
		return
	if not _is_visible(index) and not _focus_contains(index):
		return
	_selected = index
	_rebuild_chains(index)
	queue_redraw()


func frame_frontier() -> void:
	_center_content()


func visibility_report() -> Dictionary:
	var visible_count := 0
	var known_count := 0
	var visible_eras := {}
	for index in range(_visible_nodes.size()):
		if _visible_nodes[index] != 0:
			visible_count += 1
			visible_eras[String((_definitions[index] as Dictionary).get("era_id", ""))] = true
		if _known_nodes[index] != 0:
			known_count += 1
	return {
		"total": _definitions.size(),
		"visible": visible_count,
		"known": known_count,
		"visible_bands": visible_eras.size(),
		"total_bands": _eras.size(),
		"bounds": _focus_layout.get("content_rect", Rect2()),
	}


# Full graph data remains available to the detail card and tests. The focused
# geometry is intentionally exposed separately through focus_report().
func layout_report() -> Dictionary:
	return _layout


func _recompute_visibility() -> int:
	var signature := 17
	for index in range(_definitions.size()):
		var presented := presents_state(_state_of(index))
		_known_nodes[index] = 1 if presented else 0
		var reachable := presented
		if not reachable and index < _parents.size():
			for parent in _parents[index]:
				if presents_state(_state_of(parent)):
					reachable = true
					break
		_visible_nodes[index] = 1 if reachable else 0
		signature = int((signature * 31 + int(_visible_nodes[index])) & 0x7fffffff)
	return signature


func _rebuild_focus(recenter: bool = true) -> void:
	if _definitions.is_empty() or _layout.is_empty():
		return
	var previous_offset := _offset
	var had_focus := not _focus_layout.is_empty()
	var canvas := size if size.x >= 1.0 else Vector2(720.0, 480.0)
	_canvas_key = Vector2i(int(canvas.x), int(canvas.y))
	_focus_layout = LayoutScript.build_focus(_definitions, _eras, _domains,
		_visual_edges, _domain_id, _focus_era, _visible_nodes, _layout, canvas)
	_portal_slots.clear()
	var side_counts := {}
	for cursor in range((_focus_layout.get("portals", []) as Array).size()):
		var portal: Dictionary = (_focus_layout.get("portals", []) as Array)[cursor]
		var owner := int(portal.owner)
		var owner_era := String((_definitions[owner] as Dictionary).get("era_id", "")) \
			if owner >= 0 and owner < _definitions.size() else ""
		var group := "%s:%s" % [String(portal.direction), owner_era]
		_portal_slots[cursor] = int(side_counts.get(group, 0))
		side_counts[group] = int(side_counts.get(group, 0)) + 1
	if recenter or not had_focus:
		_center_content()
	else:
		# State patches can arrive several times per second at high simulation
		# speed. Keep the player's atlas viewport stable while only the node
		# visibility and edge geometry change underneath it.
		_offset = previous_offset
		_clamp_offset()
	queue_redraw()


func _center_content() -> void:
	var bounds: Rect2 = _focus_layout.get("content_rect", Rect2())
	if bounds.size.x <= 0.0 or size.x <= 0.0:
		return
	_offset.x = size.x * 0.5 - (bounds.position.x + bounds.size.x * 0.5)
	_offset.y = VIEW_PADDING - bounds.position.y
	_clamp_offset()


func _state_of(index: int) -> int:
	return int(_states[index]) if index >= 0 and index < _states.size() else 0


func _is_visible(index: int) -> bool:
	return index >= 0 and index < _visible_nodes.size() and _visible_nodes[index] != 0


func _is_known(index: int) -> bool:
	return index >= 0 and index < _known_nodes.size() and _known_nodes[index] != 0


func _focus_contains(index: int) -> bool:
	for node_value in _focus_layout.get("nodes", []) as Array:
		if int((node_value as Dictionary).get("index", -1)) == index:
			return true
	return false


func _rebuild_chains(index: int) -> void:
	_chain_up.clear()
	_chain_down.clear()
	var frontier: Array[int] = [index]
	while not frontier.is_empty():
		var current: int = frontier.pop_back()
		if current < 0 or current >= _parents.size():
			continue
		for parent in _parents[current]:
			if _chain_up.has(parent):
				continue
			_chain_up[parent] = true
			frontier.append(parent)
	if index >= 0 and index < _children.size():
		for child in _children[index]:
			_chain_down[child] = true


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _panning:
			_offset += motion.relative
			_clamp_offset()
			queue_redraw()
			accept_event()
			return
		_update_hover(motion.position)


func _handle_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		_panning = false
		return
	var portal := _portal_at(event.position)
	if portal >= 0:
		portal_requested.emit(int((_focus_layout.get("portals", []) as Array)[portal].target))
		accept_event()
		return
	var hit := _node_at(event.position)
	if hit < 0:
		_panning = true
		accept_event()
		return
	if event.double_click and _is_known(hit):
		technology_activated.emit(hit)
	else:
		select_technology(hit)
		technology_selected.emit(hit)
	accept_event()


func _update_hover(position: Vector2) -> void:
	var portal := _portal_at(position)
	var hit := -1 if portal >= 0 else _node_at(position)
	if hit == _hovered and portal == _hovered_portal:
		return
	_hovered = hit
	_hovered_portal = portal
	if portal >= 0:
		var target := int((_focus_layout.get("portals", []) as Array)[portal].target)
		tooltip_text = _portal_tooltip(target)
	else:
		tooltip_text = _tooltip_for(hit)
	queue_redraw()


func _tooltip_for(index: int) -> String:
	if index < 0:
		return ""
	var definition: Dictionary = _definitions[index]
	if bool(definition.get("is_milestone", false)) and not _is_known(index):
		return "时代里程碑\n完成本时代候选后开启下一时代"
	if not _is_known(index):
		return "未知科技\n可研究后才会显示名称与效果"
	return "%s · %s" % [String(definition.get("display_name", "")),
		STATE_NAMES[clampi(_state_of(index), 0, STATE_NAMES.size() - 1)]]


func _portal_tooltip(index: int) -> String:
	if not _is_known(index):
		return "相邻时代的关联科技"
	return "跳转至相邻时代 · %s" % String((_definitions[index] as Dictionary).get(
		"display_name", ""))


func _node_at(position: Vector2) -> int:
	var content := position - _offset
	var nodes: Array = _focus_layout.get("nodes", [])
	for cursor in range(nodes.size() - 1, -1, -1):
		var node: Dictionary = nodes[cursor]
		if (node.rect as Rect2).has_point(content):
			return int(node.index)
	return -1


func _portal_rect(portal: Dictionary, cursor: int = -1) -> Rect2:
	var owner_rect := Rect2()
	for node_value in _focus_layout.get("nodes", []) as Array:
		var node: Dictionary = node_value
		if int(node.index) == int(portal.owner):
			owner_rect = node.rect
			break
	var incoming := String(portal.direction) == "incoming"
	var slot := int(_portal_slots.get(cursor, 0))
	var x := owner_rect.position.x + owner_rect.size.x * 0.5 - PORTAL_SIZE.x * 0.5 \
		+ float(slot % 3 - 1) * (PORTAL_SIZE.x + 3.0)
	var y := owner_rect.position.y - PORTAL_SIZE.y - 4.0 if incoming \
		else owner_rect.end.y + 4.0
	return Rect2(Vector2(x, y), PORTAL_SIZE)


func _portal_at(position: Vector2) -> int:
	var content := position - _offset
	var portals: Array = _focus_layout.get("portals", [])
	for cursor in range(portals.size() - 1, -1, -1):
		if not _portal_relevant(portals[cursor] as Dictionary):
			continue
		if _portal_rect(portals[cursor], cursor).has_point(content):
			return cursor
	return -1


func _portal_relevant(portal: Dictionary) -> bool:
	return _selected >= 0 and int(portal.get("owner", -1)) == _selected


func _clamp_offset() -> void:
	var bounds: Rect2 = _focus_layout.get("content_rect", Rect2())
	if bounds.size.x <= 0.0:
		return
	var pad_x := 0.0 if bool(_focus_layout.get("fits_canvas", false)) else VIEW_PADDING
	var padded := Rect2(bounds.position - Vector2(pad_x, VIEW_PADDING),
		bounds.size + Vector2(pad_x, VIEW_PADDING) * 2.0)
	if padded.size.x <= size.x:
		_offset.x = (size.x - padded.size.x) * 0.5 - padded.position.x
	else:
		_offset.x = clampf(_offset.x, size.x - padded.end.x, -padded.position.x)
	if padded.size.y <= size.y:
		_offset.y = -padded.position.y
	else:
		_offset.y = clampf(_offset.y, size.y - padded.end.y, -padded.position.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		var key := Vector2i(int(size.x), int(size.y))
		if key != _canvas_key and size.x >= 1.0 and size.y >= 1.0:
			_rebuild_focus()
		else:
			_center_content()
			queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovered = -1
		_hovered_portal = -1
		queue_redraw()


func _draw() -> void:
	if _focus_layout.is_empty():
		return
	draw_set_transform(_offset, 0.0, Vector2.ONE)
	_draw_bands()
	_draw_edges()
	for cursor in range((_focus_layout.get("portals", []) as Array).size()):
		var portal: Dictionary = (_focus_layout.get("portals", []) as Array)[cursor]
		if _portal_relevant(portal):
			_draw_portal(cursor)
	for node_value in _focus_layout.get("nodes", []) as Array:
		_draw_node(node_value as Dictionary)
	_draw_milestone_progress()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_bands() -> void:
	var font := get_theme_default_font()
	for band_value in _focus_layout.get("bands", []) as Array:
		var band: Dictionary = band_value
		var rect: Rect2 = band.rect
		var focus := bool(band.get("is_focus", false))
		draw_rect(rect, BAND_PAPER_FOCUS if focus else BAND_PAPER_ADJACENT, true)
		draw_line(Vector2(rect.position.x, rect.position.y),
			Vector2(rect.end.x, rect.position.y),
			UITokens.ARCHIVE_BRASS if focus else UITokens.ARCHIVE_RULE,
			2.0 if focus else 1.0)
		if focus:
			draw_line(Vector2(rect.position.x, rect.end.y), Vector2(rect.end.x, rect.end.y),
				Color(UITokens.ARCHIVE_RULE, 0.45), 1.0)
		var label := String(band.get("display_name", ""))
		var colour := UITokens.ARCHIVE_INK if focus else UITokens.ARCHIVE_INK_MUTED
		draw_string(font, rect.position + Vector2(12.0, 21.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ERA_FONT_SIZE, colour)
		var lanes: Array = band.get("lanes", [])
		for lane_value in lanes:
			var lane: Dictionary = lane_value
			var lane_rect: Rect2 = lane.rect
			var domain := int(lane.get("domain", 0))
			var accent := _accent_for(domain)
			if focus and String(lane.get("id", "")) == _domain_id:
				var wash := accent
				wash.a = 0.07
				draw_rect(lane_rect, wash, true)
			if domain > 0:
				var rule := Color(UITokens.ARCHIVE_RULE, 0.34 if focus else 0.18)
				var rule_x := lane_rect.position.x - 7.0
				draw_line(Vector2(rule_x, lane_rect.position.y + 2.0),
					Vector2(rule_x, rect.end.y - 8.0), rule, 1.0)
			var header := String(lane.get("display_name", ""))
			var header_colour := accent.lerp(UITokens.ARCHIVE_INK, 0.35) if focus \
				else UITokens.ARCHIVE_INK_MUTED
			_draw_glyph(IconCatalog.technology_domain_semantic(String(lane.get("id", ""))),
				Vector2(lane_rect.position.x + 8.0, rect.position.y + 42.0), 10, header_colour)
			draw_string(font, Vector2(lane_rect.position.x + 24.0, rect.position.y + 42.0),
				header, HORIZONTAL_ALIGNMENT_LEFT, maxf(24.0, lane_rect.size.x - 32.0),
				13, header_colour)


func _draw_edges() -> void:
	for edge_value in _focus_layout.get("edges", []) as Array:
		var edge: Dictionary = edge_value
		var from := int(edge.from)
		var to := int(edge.to)
		var kind := String(edge.get("kind", "hard"))
		if kind in ["application", "branch"] and _selected not in [from, to]:
			continue
		var emphasis := _selected < 0 or from == _selected or to == _selected \
			or _chain_up.has(from) or _chain_down.has(to)
		var colour := _accent_for(int((_definitions[to] as Dictionary).get(
			"domain_index", _domain_index_of(_definitions[to])))).lerp(
				UITokens.ARCHIVE_INK, 0.24)
		colour.a = 0.76 if emphasis else 0.24
		if kind == "application":
			_draw_dashed_polyline(edge.points, colour, 1.0, 4.0, 5.0)
		elif kind == "branch":
			_draw_dashed_polyline(edge.points, colour, 1.5, 2.0, 3.0)
		else:
			draw_polyline(edge.points, colour, 2.0 if emphasis else 1.0, true)


func _draw_dashed_polyline(points: PackedVector2Array, colour: Color, width: float,
		dash_length: float, gap_length: float) -> void:
	for segment in range(points.size() - 1):
		var cursor := points[segment]
		var target := points[segment + 1]
		var vector := target - cursor
		var length := vector.length()
		if length <= 0.001:
			continue
		var direction := vector / length
		var consumed := 0.0
		var drawing := true
		while consumed < length:
			var step := minf(dash_length if drawing else gap_length, length - consumed)
			if drawing:
				draw_line(cursor + direction * consumed,
					cursor + direction * (consumed + step), colour, width, true)
			consumed += step
			drawing = not drawing


func _draw_milestone_progress() -> void:
	for node_value in _focus_layout.get("nodes", []) as Array:
		var node: Dictionary = node_value
		if not bool(node.get("is_milestone", false)):
			continue
		var index := int(node.index)
		if index < 0 or index >= _definitions.size():
			continue
		var definition: Dictionary = _definitions[index]
		var candidates: PackedStringArray = definition.get(
			"milestone_candidate_ids", PackedStringArray())
		var completed := 0
		for id in candidates:
			for cursor in range(_definitions.size()):
				if String((_definitions[cursor] as Dictionary).get("id", "")) == String(id) \
						and _state_of(cursor) >= 5:
					completed += 1
					break
		var required := maxi(1, int(definition.get("milestone_required_count", 5)))
		var node_rect: Rect2 = node.rect
		var rect := Rect2(node_rect.position + Vector2(12.0, node_rect.size.y - 9.0),
			Vector2(node_rect.size.x - 24.0, 4.0))
		draw_rect(rect, Color(UITokens.ARCHIVE_INK, 0.18), true)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(
			float(completed) / float(required), 0.0, 1.0), rect.size.y)),
			Color(UITokens.ARCHIVE_BRASS, 0.90 if bool(node.get("is_focus_era", false)) \
				else 0.52), true)
		draw_rect(rect, UITokens.ARCHIVE_BRASS if bool(node.get("is_focus_era", false)) \
			else UITokens.ARCHIVE_RULE, false, 1.0)


func _draw_portal(cursor: int) -> void:
	var portals: Array = _focus_layout.get("portals", [])
	var portal: Dictionary = portals[cursor]
	var rect := _portal_rect(portal, cursor)
	var target := int(portal.target)
	var hover := cursor == _hovered_portal
	var colour := UITokens.ARCHIVE_BRASS if hover else UITokens.ARCHIVE_RULE
	draw_rect(rect, UITokens.ARCHIVE_PAPER_LIGHT if hover else CARD_PAPER_DIM, true)
	draw_rect(rect, colour, false, 1.0)
	var incoming := String(portal.direction) == "incoming"
	var owner := int(portal.owner)
	_draw_glyph(&"action.back" if incoming else &"action.chevron_right",
		rect.position + Vector2(8.0, 17.0), 11,
		UITokens.ARCHIVE_INK if hover else UITokens.ARCHIVE_INK_MUTED)


func _draw_node(node: Dictionary) -> void:
	var index := int(node.index)
	var rect: Rect2 = node.rect
	var definition: Dictionary = _definitions[index]
	var state := _state_of(index)
	var known := _is_known(index)
	var domain := int(node.domain)
	var is_milestone := bool(node.get("is_milestone", false)) \
		or bool(definition.get("is_milestone", false))
	var accent := UITokens.ARCHIVE_BRASS if is_milestone else _accent_for(domain)
	var emphasis := _emphasis_for(index)
	var text_colour := _node_text_colour(emphasis)
	var muted_text_colour := _node_text_colour(emphasis, true)
	draw_style_box(_card_style(domain, state, known, emphasis, is_milestone), rect)
	if is_milestone and not known:
		_draw_glyph(&"technology.milestone", rect.position + Vector2(16.0, 28.0), 14,
			text_colour if emphasis == 2 else Color(accent.r, accent.g, accent.b, 0.92))
		draw_string(_name_font, rect.position + Vector2(40.0, 28.0), "时代里程碑",
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 52.0, NAME_FONT_SIZE,
			text_colour)
		var era_name := _era_name(int(node.get("era_index", 0)))
		draw_string(get_theme_default_font(), rect.position + Vector2(40.0, 49.0),
			era_name, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 52.0, 12,
			muted_text_colour)
		return
	if not known:
		_draw_glyph(&"technology.state.unknown", rect.position + Vector2(14.0, 36.0), 13,
			Color(accent.r, accent.g, accent.b, 0.72))
		draw_string(_name_font, rect.position + Vector2(38.0, 36.0), "未知科技",
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 46.0, NAME_FONT_SIZE,
			muted_text_colour)
		return
	_draw_glyph(&"technology.milestone" if is_milestone \
		else IconCatalog.technology_domain_semantic(String(definition.get("domain_id", ""))),
		rect.position + Vector2(14.0, 28.0 if is_milestone else 36.0), 13,
		text_colour if emphasis == 2 else accent)
	var label := String(definition.get("display_name", ""))
	var label_font_size := _fitted_name_size(label, rect.size.x - 60.0)
	draw_string(_name_font, rect.position + Vector2(38.0, 28.0 if is_milestone else 35.0),
		label, HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 60.0, label_font_size,
		text_colour)
	if is_milestone:
		draw_string(get_theme_default_font(), rect.position + Vector2(38.0, 49.0),
			"时代里程碑", HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 60.0, 12,
			muted_text_colour)
	else:
		_draw_glyph(IconCatalog.technology_state_semantic(state),
			rect.position + Vector2(rect.size.x - 24.0, 35.0), 12,
			text_colour if emphasis == 2 else _state_colour(state))
		_draw_progress(index, rect, accent, emphasis == 0)


func _draw_progress(index: int, rect: Rect2, accent: Color, dim: bool) -> void:
	var state := _state_of(index)
	if state < 2 or state >= 5:
		return
	var cost := maxf(1.0, float((_definitions[index] as Dictionary).get("cost_points", 1)))
	var earned := float(_progress[index]) / 1000.0 if index < _progress.size() else 0.0
	var fraction := clampf(earned / cost, 0.0, 1.0)
	var track := Rect2(rect.position + Vector2(12.0, rect.size.y - 9.0),
		Vector2(rect.size.x - 24.0, 3.0))
	draw_rect(track, Color(UITokens.ARCHIVE_INK, 0.18), true)
	if fraction > 0.0:
		var colour := accent.lerp(UITokens.BRASS_HIGHLIGHT, 0.42)
		colour.a = 0.45 if dim else 1.0
		draw_rect(Rect2(track.position, Vector2(track.size.x * fraction, track.size.y)),
			colour, true)


func _draw_glyph(semantic: StringName, baseline: Vector2, glyph_size: int,
		colour: Color) -> void:
	var glyph := IconCatalog.glyph_for_key(semantic)
	if glyph.is_empty():
		return
	draw_string(IconCatalog.FONT_AWESOME, baseline, glyph,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, glyph_size, colour)


func _emphasis_for(index: int) -> int:
	var focus := _selected if _selected >= 0 else _hovered
	if focus < 0:
		return 1
	if index == focus:
		return 2
	if _chain_up.has(index) or _chain_down.has(index):
		return 1
	return 0


func _node_text_colour(emphasis: int, muted: bool = false) -> Color:
	if emphasis == 2:
		return Color(UITokens.ARCHIVE_PAPER, 0.82) if muted else UITokens.ARCHIVE_PAPER_LIGHT
	return UITokens.ARCHIVE_INK_MUTED if muted or emphasis == 0 else UITokens.ARCHIVE_INK


func _fitted_name_size(label: String, available_width: float) -> int:
	var font_size := NAME_FONT_SIZE
	while font_size > NAME_FONT_MIN_SIZE and _name_font.get_string_size(
			label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x > available_width:
		font_size -= 1
	return font_size


func _state_colour(state: int) -> Color:
	match state:
		2: return UITokens.ARCHIVE_BRASS
		3: return UITokens.WATER.lerp(UITokens.ARCHIVE_INK, 0.30)
		4: return UITokens.WARN.lerp(UITokens.ARCHIVE_INK, 0.18)
		5: return UITokens.GOOD.lerp(UITokens.ARCHIVE_INK, 0.18)
		_: return UITokens.ARCHIVE_INK_MUTED


func _accent_for(domain: int) -> Color:
	return _accents[domain] if domain >= 0 and domain < _accents.size() else UITokens.ACCENT


func _domain_index_of(definition: Dictionary) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for index in range(_domains.size()):
		if String((_domains[index] as Dictionary).get("id", "")) == domain_id:
			return index
	return 0


func _card_style(domain: int, state: int, known: bool, emphasis: int,
		is_milestone: bool = false) -> StyleBoxFlat:
	var key := "%d:%d:%d:%d:%d" % [domain, state, 1 if known else 0, emphasis,
		1 if is_milestone else 0]
	if _card_styles.has(key):
		return _card_styles[key]
	var accent := UITokens.BRASS_HIGHLIGHT if is_milestone else _accent_for(domain)
	var style := StyleBoxFlat.new()
	style.corner_radius_top_left = UITokens.RADIUS_SM
	style.corner_radius_top_right = UITokens.RADIUS_SM
	style.corner_radius_bottom_left = UITokens.RADIUS_SM
	style.corner_radius_bottom_right = UITokens.RADIUS_SM
	style.border_width_left = 4 if known or is_milestone else 1
	style.border_width_top = 2 if emphasis == 2 else 1
	style.border_width_right = 2 if emphasis == 2 else 1
	style.border_width_bottom = 2 if emphasis == 2 else 1
	var paper := CARD_PAPER.lerp(accent, 0.06 if not is_milestone else 0.10)
	style.bg_color = SELECTED_WALNUT if emphasis == 2 else (
		CARD_PAPER_DIM if emphasis == 0 else paper)
	style.border_color = Color(accent.r, accent.g, accent.b,
		1.0 if emphasis == 2 else (0.88 if is_milestone else (0.68 if emphasis == 1 else 0.34)))
	if not known and not is_milestone:
		style.bg_color = SELECTED_WALNUT if emphasis == 2 else CARD_PAPER_UNKNOWN
		style.border_color = Color(UITokens.ARCHIVE_RULE, 0.92 if emphasis == 2 else 0.48)
	_card_styles[key] = style
	return style


func _era_name(era_index: int) -> String:
	if era_index < 0 or era_index >= _eras.size():
		return ""
	return String((_eras[era_index] as Dictionary).get("display_name", ""))
