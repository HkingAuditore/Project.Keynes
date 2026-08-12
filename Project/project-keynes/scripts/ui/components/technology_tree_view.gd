extends Control
class_name TechnologyTreeView

signal technology_selected(index: int)
signal technology_activated(index: int)
signal portal_requested(index: int)

const LayoutScript = preload("res://scripts/ui/technology_tree_layout.gd")
const VIEW_PADDING := 34.0
const NAME_FONT_SIZE := 13
const ERA_FONT_SIZE := 13
const PORTAL_HEIGHT := 24.0
const STATE_NAMES := ["未知", "已揭示", "可研究", "研究队列", "待生效", "已掌握"]

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
var _lane_id := ""
var _focus_era := 0
var _offset := Vector2.ZERO
var _panning := false
var _card_styles: Dictionary = {}
var _name_font: Font = UITokens.font_with_weight(640)
var _visibility_signature := 0
var _portal_slots: Dictionary = {}


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
		_lane_id = String((definitions[0] as Dictionary).get(
			"main_lane", (definitions[0] as Dictionary).get("layout_lane", "")))
	_rebuild_focus()


func patch_states(states: PackedInt32Array, progress: PackedInt64Array) -> void:
	var state_changed := states != _states
	_states = states
	_progress = progress
	if state_changed:
		var signature := _recompute_visibility()
		if signature != _visibility_signature:
			_visibility_signature = signature
			_rebuild_focus()
	if _selected >= 0 and not _is_visible(_selected):
		_selected = -1
		_chain_up.clear()
		_chain_down.clear()
	queue_redraw()


func set_focus(lane_id: String, era_index: int, preferred_index: int = -1) -> void:
	if not lane_id.is_empty():
		_lane_id = lane_id
	_focus_era = clampi(era_index, 0, maxi(0, _eras.size() - 1))
	_rebuild_focus()
	if preferred_index >= 0 and _focus_contains(preferred_index):
		select_technology(preferred_index)
	_center_content()
	queue_redraw()


func focus_lane() -> String:
	return _lane_id


func focus_era() -> int:
	return _focus_era


func focus_report() -> Dictionary:
	return _focus_layout


func selected_technology() -> int:
	return _selected


func select_technology(index: int) -> void:
	if index < 0 or index >= _definitions.size() or not _is_visible(index):
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
		var state := _state_of(index)
		_known_nodes[index] = 1 if state >= 1 else 0
		var reachable := state >= 1
		if not reachable and index < _parents.size():
			for parent in _parents[index]:
				if _state_of(parent) >= 1:
					reachable = true
					break
		_visible_nodes[index] = 1 if reachable else 0
		signature = int((signature * 31 + int(_visible_nodes[index])) & 0x7fffffff)
	return signature


func _rebuild_focus() -> void:
	if _definitions.is_empty() or _layout.is_empty():
		return
	_focus_layout = LayoutScript.build_focus(_definitions, _eras, _domains,
		_visual_edges, _lane_id, _focus_era, _visible_nodes, _layout)
	_portal_slots.clear()
	var side_counts := {"incoming": 0, "outgoing": 0}
	for cursor in range((_focus_layout.get("portals", []) as Array).size()):
		var portal: Dictionary = (_focus_layout.get("portals", []) as Array)[cursor]
		var side := String(portal.direction)
		_portal_slots[cursor] = int(side_counts.get(side, 0))
		side_counts[side] = int(side_counts.get(side, 0)) + 1
	_center_content()
	queue_redraw()


func _center_content() -> void:
	var bounds: Rect2 = _focus_layout.get("content_rect", Rect2())
	if bounds.size.x <= 0.0 or size.x <= 0.0:
		return
	_offset = size * 0.5 - (bounds.position + bounds.size * 0.5)
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
	if not _is_known(index):
		return "未知科技\n取得当地证据、真实贸易样本或实践突破后揭示"
	var definition: Dictionary = _definitions[index]
	return "%s · %s" % [String(definition.get("display_name", "")),
		STATE_NAMES[clampi(_state_of(index), 0, STATE_NAMES.size() - 1)]]


func _portal_tooltip(index: int) -> String:
	if not _is_known(index):
		return "跨分支前沿"
	return "跳转至分支 · %s" % String((_definitions[index] as Dictionary).get(
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
	var bounds: Rect2 = _focus_layout.get("content_rect", Rect2())
	var x := bounds.position.x + 4.0 if incoming else bounds.end.x - 104.0
	var slot := int(_portal_slots.get(cursor, 0))
	var y := owner_rect.position.y + owner_rect.size.y * 0.5 - PORTAL_HEIGHT * 0.5 \
		+ float(slot % 3 - 1) * (PORTAL_HEIGHT + 3.0)
	return Rect2(Vector2(x, y),
		Vector2(100.0, PORTAL_HEIGHT))


func _portal_at(position: Vector2) -> int:
	var content := position - _offset
	var portals: Array = _focus_layout.get("portals", [])
	for cursor in range(portals.size() - 1, -1, -1):
		if _portal_rect(portals[cursor], cursor).has_point(content):
			return cursor
	return -1


func _clamp_offset() -> void:
	var bounds: Rect2 = _focus_layout.get("content_rect", Rect2())
	if bounds.size.x <= 0.0:
		return
	var padded := bounds.grow(VIEW_PADDING)
	if padded.size.x <= size.x:
		_offset.x = (size.x - padded.size.x) * 0.5 - padded.position.x
	else:
		_offset.x = clampf(_offset.x, size.x - padded.end.x, -padded.position.x)
	if padded.size.y <= size.y:
		_offset.y = (size.y - padded.size.y) * 0.5 - padded.position.y
	else:
		_offset.y = clampf(_offset.y, size.y - padded.end.y, -padded.position.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
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
	_draw_milestone_progress()
	for cursor in range((_focus_layout.get("portals", []) as Array).size()):
		_draw_portal(cursor)
	for node_value in _focus_layout.get("nodes", []) as Array:
		_draw_node(node_value as Dictionary)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_bands() -> void:
	var font := get_theme_default_font()
	for band_value in _focus_layout.get("bands", []) as Array:
		var band: Dictionary = band_value
		var rect: Rect2 = band.rect
		var focus := bool(band.get("is_focus", false))
		draw_rect(rect, Color(0.052, 0.046, 0.037, 0.52 if focus else 0.25), true)
		draw_line(Vector2(rect.position.x, rect.position.y),
			Vector2(rect.end.x, rect.position.y),
			UITokens.BRASS_HIGHLIGHT if focus else UITokens.PANEL_BORDER_SOFT,
			2.0 if focus else 1.0)
		var label := String(band.get("display_name", ""))
		var colour := UITokens.TEXT_MAIN if focus else UITokens.TEXT_MUTED
		draw_string(font, rect.position + Vector2(12.0, 21.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ERA_FONT_SIZE, colour)


func _draw_edges() -> void:
	for edge_value in _focus_layout.get("edges", []) as Array:
		var edge: Dictionary = edge_value
		var from := int(edge.from)
		var to := int(edge.to)
		var kind := String(edge.get("kind", "hard"))
		if kind == "application" and _selected not in [from, to]:
			continue
		var emphasis := _selected < 0 or from == _selected or to == _selected \
			or _chain_up.has(from) or _chain_down.has(to)
		var colour := _accent_for(int((_definitions[to] as Dictionary).get(
			"domain_index", _domain_index_of(_definitions[to]))))
		colour.a = 0.78 if emphasis else 0.18
		if kind == "application":
			_draw_dashed_polyline(edge.points, colour, 1.0, 4.0, 5.0)
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
	var band_index := -1
	for band_value in _focus_layout.get("bands", []) as Array:
		var band: Dictionary = band_value
		if bool(band.get("is_focus", false)):
			band_index = int(band.get("era_index", -1))
			break
	if band_index < 0 or band_index >= _eras.size():
		return
	var milestone_id := String((_eras[band_index] as Dictionary).get("milestone_id", ""))
	var milestone_index := -1
	for index in range(_definitions.size()):
		if String((_definitions[index] as Dictionary).get("id", "")) == milestone_id:
			milestone_index = index
			break
	if milestone_index < 0 or not _is_visible(milestone_index):
		return
	var candidates: PackedStringArray = (_definitions[milestone_index] as Dictionary).get(
		"milestone_candidate_ids", PackedStringArray())
	var completed := 0
	for id in candidates:
		for index in range(_definitions.size()):
			if String((_definitions[index] as Dictionary).get("id", "")) == String(id) \
					and _state_of(index) >= 5:
				completed += 1
				break
	var required := maxi(1, int((_definitions[milestone_index] as Dictionary).get(
		"milestone_required_count", 5)))
	var bounds: Rect2 = _focus_layout.get("content_rect", Rect2())
	var rect := Rect2(Vector2(bounds.position.x + 18.0, bounds.end.y - 30.0),
		Vector2(bounds.size.x - 36.0, 20.0))
	draw_rect(rect, Color(0.025, 0.022, 0.018, 0.90), true)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x * clampf(
		float(completed) / float(required), 0.0, 1.0), rect.size.y)),
		Color(UITokens.BRASS_HIGHLIGHT, 0.22), true)
	draw_rect(rect, UITokens.PANEL_BORDER_SOFT, false, 1.0)
	var label := "时代里程碑  %d / %d" % [completed, required]
	draw_string(get_theme_default_font(), rect.position + Vector2(8.0, 15.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, 12, UITokens.TEXT_MUTED)


func _draw_portal(cursor: int) -> void:
	var portals: Array = _focus_layout.get("portals", [])
	var portal: Dictionary = portals[cursor]
	var rect := _portal_rect(portal, cursor)
	var target := int(portal.target)
	var hover := cursor == _hovered_portal
	var colour := UITokens.BRASS_HIGHLIGHT if hover else UITokens.PANEL_BORDER_SOFT
	draw_rect(rect, Color(0.066, 0.058, 0.047, 0.92), true)
	draw_rect(rect, colour, false, 1.0)
	var incoming := String(portal.direction) == "incoming"
	var text := "前置分支" if incoming else "后续分支"
	if _is_known(target):
		text = String((_definitions[target] as Dictionary).get("display_name", text))
	draw_string(get_theme_default_font(), rect.position + Vector2(8.0, 16.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 16.0, 11,
		UITokens.TEXT_MAIN if hover else UITokens.TEXT_MUTED)


func _draw_node(node: Dictionary) -> void:
	var index := int(node.index)
	var rect: Rect2 = node.rect
	var definition: Dictionary = _definitions[index]
	var state := _state_of(index)
	var known := _is_known(index)
	var domain := int(node.domain)
	var accent := _accent_for(domain)
	var emphasis := _emphasis_for(index)
	draw_style_box(_card_style(domain, state, known, emphasis), rect)
	if not known:
		_draw_glyph(&"technology.state.unknown", rect.position + Vector2(13.0, 31.0), 12,
			Color(accent.r, accent.g, accent.b, 0.45))
		draw_string(_name_font, rect.position + Vector2(35.0, 31.0), "未知科技",
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 46.0, NAME_FONT_SIZE,
			UITokens.TEXT_FAINT)
		return
	_draw_glyph(IconCatalog.technology_domain_semantic(String(definition.get(
		"domain_id", ""))), rect.position + Vector2(13.0, 30.0), 12, accent)
	var label := String(definition.get("display_name", ""))
	draw_string(_name_font, rect.position + Vector2(35.0, 29.0), label,
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 60.0, NAME_FONT_SIZE,
		UITokens.TEXT_MAIN if emphasis > 0 else UITokens.TEXT_MUTED)
	_draw_glyph(IconCatalog.technology_state_semantic(state),
		rect.position + Vector2(rect.size.x - 22.0, 29.0), 11, _state_colour(state))
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
	draw_rect(track, Color(0.020, 0.018, 0.015, 0.82), true)
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


func _state_colour(state: int) -> Color:
	match state:
		2: return UITokens.BRASS_HIGHLIGHT
		3: return UITokens.WATER.lerp(UITokens.TEXT_MAIN, 0.30)
		4: return UITokens.WARN
		5: return UITokens.GOOD
		_: return UITokens.TEXT_FAINT


func _accent_for(domain: int) -> Color:
	return _accents[domain] if domain >= 0 and domain < _accents.size() else UITokens.ACCENT


func _domain_index_of(definition: Dictionary) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for index in range(_domains.size()):
		if String((_domains[index] as Dictionary).get("id", "")) == domain_id:
			return index
	return 0


func _card_style(domain: int, state: int, known: bool, emphasis: int) -> StyleBoxFlat:
	var key := "%d:%d:%d:%d" % [domain, state, 1 if known else 0, emphasis]
	if _card_styles.has(key):
		return _card_styles[key]
	var accent := _accent_for(domain)
	var style := StyleBoxFlat.new()
	style.corner_radius_top_left = UITokens.RADIUS_SM
	style.corner_radius_top_right = UITokens.RADIUS_SM
	style.corner_radius_bottom_left = UITokens.RADIUS_SM
	style.corner_radius_bottom_right = UITokens.RADIUS_SM
	style.border_width_left = 3 if known else 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.bg_color = UITokens.CARD_BG_HOVER if emphasis == 2 else UITokens.CARD_BG
	if emphasis == 0:
		style.bg_color.a = 0.55
	style.border_color = Color(accent.r, accent.g, accent.b,
		0.90 if emphasis == 2 else (0.58 if emphasis == 1 else 0.20))
	if not known:
		style.bg_color = Color(0.036, 0.032, 0.027, 0.58)
		style.border_color.a = 0.20
	_card_styles[key] = style
	return style
