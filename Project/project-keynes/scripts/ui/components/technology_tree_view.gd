extends Control
class_name TechnologyTreeView

# A single self-drawn canvas for the whole technology tree. Geometry is baked once
# by TechnologyTreeLayout; daily ticks only patch the state arrays and request a
# redraw, so no node tree is ever rebuilt while the player is clicking.

signal technology_selected(index: int)
signal technology_activated(index: int)

const LayoutScript = preload("res://scripts/ui/technology_tree_layout.gd")

# The tree is always drawn 1:1. Nothing scales, so node text stays crisp and the
# wheel is free to do the obvious thing: scroll.
const PAN_STEP := 108.0
const VIEW_PADDING := 56.0
const NAME_FONT_SIZE := 13
const ERA_FONT_SIZE := 13
const STATE_NAMES := ["未知", "已揭示", "可研究", "研究队列", "待生效", "已掌握"]

var _accents: Array[Color] = []
var _definitions: Array = []
var _layout: Dictionary = {}
var _nodes: Array = []
var _edges: Array = []
var _bands: Array = []
var _parents: Array = []
var _children: Array = []
var _states := PackedInt32Array()
var _progress := PackedInt64Array()
var _visible_nodes := PackedByteArray()
var _known_nodes := PackedByteArray()
var _visible_bands := PackedByteArray()
var _visible_bounds := Rect2()
var _frontier_band := -1
var _selected := -1
var _hovered := -1
var _chain_up := {}
var _chain_down := {}
var _offset := Vector2.ZERO
var _panning := false
var _framed := false
var _card_styles: Dictionary = {}
var _name_font: Font = UITokens.font_with_weight(640)


func _ready() -> void:
	name = "TechnologyTreeView"
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func set_catalog(definitions: Array, eras: Array, domains: Array) -> void:
	if not _nodes.is_empty() or definitions.is_empty():
		return
	_definitions = definitions
	_accents.clear()
	for domain in domains:
		_accents.append((domain as Dictionary).get("accent", UITokens.ACCENT))
	_layout = LayoutScript.build(definitions, eras, domains)
	_nodes = _layout.get("nodes", [])
	_edges = _layout.get("edges", [])
	_bands = _layout.get("bands", [])
	_parents = _layout.get("parents", [])
	_children = _layout.get("children", [])
	_visible_nodes.resize(_nodes.size())
	_known_nodes.resize(_nodes.size())
	_visible_bands.resize(_bands.size())
	queue_redraw()


func patch_states(states: PackedInt32Array, progress: PackedInt64Array) -> void:
	_states = states
	_progress = progress
	_recompute_visibility()
	if not _framed and _visible_bounds.size.x > 0.0:
		frame_frontier()
	if _selected >= 0 and not _is_visible(_selected):
		_selected = -1
		_chain_up.clear()
		_chain_down.clear()
	queue_redraw()


func selected_technology() -> int:
	return _selected


func select_technology(index: int) -> void:
	if index < 0 or index >= _nodes.size() or not _is_visible(index):
		return
	_selected = index
	_rebuild_chains(index)
	queue_redraw()


# Centres the view on the deepest era the player has actually reached, so the
# opening frame shows the research frontier instead of prehistory.
func frame_frontier() -> void:
	if _visible_bounds.size.x <= 0.0 or size.x <= 0.0:
		return
	_framed = true
	var anchor := Vector2(_visible_bounds.position.x + _visible_bounds.size.x * 0.5,
		_visible_bounds.position.y + _visible_bounds.size.y)
	if _frontier_band >= 0:
		var band: Dictionary = _bands[_frontier_band]
		anchor.y = float(band.get("top", anchor.y))
	_offset = Vector2(size.x * 0.5, size.y * 0.42) - anchor
	_clamp_offset()
	queue_redraw()


func visibility_report() -> Dictionary:
	var visible_count := 0
	var known_count := 0
	for i in range(_visible_nodes.size()):
		if _visible_nodes[i] != 0:
			visible_count += 1
		if _known_nodes[i] != 0:
			known_count += 1
	var band_count := 0
	for i in range(_visible_bands.size()):
		if _visible_bands[i] != 0:
			band_count += 1
	return {
		"total": _nodes.size(),
		"visible": visible_count,
		"known": known_count,
		"visible_bands": band_count,
		"total_bands": _bands.size(),
		"bounds": _visible_bounds,
	}


func layout_report() -> Dictionary:
	return _layout


func _recompute_visibility() -> void:
	_frontier_band = -1
	_visible_bounds = Rect2()
	var found := false
	for i in range(_nodes.size()):
		var state := _state_of(i)
		var known := state >= 1
		_known_nodes[i] = 1 if known else 0
		var reachable := known
		if not reachable:
			for parent in _parents[i]:
				if _state_of(parent) >= 1:
					reachable = true
					break
		_visible_nodes[i] = 1 if reachable else 0
	for i in range(_visible_bands.size()):
		_visible_bands[i] = 0
	for i in range(_nodes.size()):
		if _visible_nodes[i] == 0:
			continue
		var node: Dictionary = _nodes[i]
		var rect: Rect2 = node.rect
		_visible_bounds = rect if not found else _visible_bounds.merge(rect)
		found = true
		var band_index := int(node.era_index)
		_visible_bands[band_index] = 1
		if _known_nodes[i] != 0 and band_index > _frontier_band:
			_frontier_band = band_index
	if not found:
		return
	for band_index in range(_bands.size()):
		if _visible_bands[band_index] == 0:
			continue
		var band: Dictionary = _bands[band_index]
		_visible_bounds = _visible_bounds.merge(Rect2(
			_visible_bounds.position.x, float(band.get("top", 0.0)),
			1.0, 1.0))
	_visible_bounds = _visible_bounds.grow(VIEW_PADDING)


func _state_of(index: int) -> int:
	return int(_states[index]) if index < _states.size() else 0


func _accent_for(domain: int) -> Color:
	if domain >= 0 and domain < _accents.size():
		return _accents[domain]
	return UITokens.ACCENT


func _is_visible(index: int) -> bool:
	return index >= 0 and index < _visible_nodes.size() and _visible_nodes[index] != 0


func _is_known(index: int) -> bool:
	return index >= 0 and index < _known_nodes.size() and _known_nodes[index] != 0


func _rebuild_chains(index: int) -> void:
	_chain_up.clear()
	_chain_down.clear()
	if index < 0 or index >= _nodes.size():
		return
	var frontier: Array[int] = [index]
	while not frontier.is_empty():
		var current: int = frontier.pop_back()
		for parent in _parents[current]:
			if _chain_up.has(parent):
				continue
			_chain_up[parent] = true
			frontier.append(parent)
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
	var wheel := _wheel_delta(event)
	if wheel != Vector2.ZERO:
		_offset += wheel
		_clamp_offset()
		queue_redraw()
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if not event.pressed:
		_panning = false
		return
	var hit := _node_at(event.position)
	if hit < 0:
		_panning = true
		accept_event()
		return
	if event.double_click and _is_known(hit):
		technology_activated.emit(hit)
		accept_event()
		return
	select_technology(hit)
	technology_selected.emit(hit)
	accept_event()


# Vertical wheel walks the era stack; shift or a tilt wheel slides sideways when
# a band is wider than the screen.
func _wheel_delta(event: InputEventMouseButton) -> Vector2:
	if not event.pressed:
		return Vector2.ZERO
	var step := PAN_STEP * maxf(0.25, event.factor)
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			return Vector2(step, 0.0) if event.shift_pressed else Vector2(0.0, step)
		MOUSE_BUTTON_WHEEL_DOWN:
			return Vector2(-step, 0.0) if event.shift_pressed else Vector2(0.0, -step)
		MOUSE_BUTTON_WHEEL_LEFT:
			return Vector2(step, 0.0)
		MOUSE_BUTTON_WHEEL_RIGHT:
			return Vector2(-step, 0.0)
		_:
			return Vector2.ZERO


func _update_hover(position: Vector2) -> void:
	var hit := _node_at(position)
	if hit == _hovered:
		return
	_hovered = hit
	tooltip_text = _tooltip_for(hit)
	queue_redraw()


func _tooltip_for(index: int) -> String:
	if index < 0:
		return ""
	if not _is_known(index):
		return "未知科技\n完成一项直接前置后揭示"
	var definition: Dictionary = _definitions[index]
	var state := _state_of(index)
	var parts := PackedStringArray()
	parts.append("%s · %s" % [String(definition.get("display_name", "")),
		STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]])
	var known_parents := 0
	var done_parents := 0
	for parent in _parents[index]:
		known_parents += 1
		if _state_of(parent) >= 4:
			done_parents += 1
	if known_parents > 0:
		var required := int(definition.get("milestone_required_count", 0))
		if bool(definition.get("is_milestone", false)) and required > 0:
			parts.append("里程碑前置 %d / %d（共 %d 项候选）" % [
				done_parents, required, known_parents])
		else:
			parts.append("前置 %d / %d 已完成" % [done_parents, known_parents])
	if not _children[index].is_empty():
		parts.append("解锁 %d 项后续科技" % _children[index].size())
	return "\n".join(parts)


func _node_at(position: Vector2) -> int:
	var content := position - _offset
	for i in range(_nodes.size() - 1, -1, -1):
		if _visible_nodes[i] == 0:
			continue
		if (_nodes[i] as Dictionary).rect.has_point(content):
			return i
	return -1


# Panning is bounded by the discovered bounding box: an axis that already fits is
# pinned to centre, so the player can never scroll the tree off screen.
func _clamp_offset() -> void:
	if _visible_bounds.size.x <= 0.0:
		return
	var extent := _visible_bounds.size
	var origin := _visible_bounds.position
	if extent.x <= size.x:
		_offset.x = (size.x - extent.x) * 0.5 - origin.x
	else:
		_offset.x = clampf(_offset.x, size.x - origin.x - extent.x, -origin.x)
	if extent.y <= size.y:
		_offset.y = (size.y - extent.y) * 0.5 - origin.y
	else:
		_offset.y = clampf(_offset.y, size.y - origin.y - extent.y, -origin.y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if not _framed:
			frame_frontier()
		else:
			_clamp_offset()
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT and _hovered != -1:
		_hovered = -1
		queue_redraw()


func _draw() -> void:
	if _nodes.is_empty():
		return
	draw_set_transform(_offset, 0.0, Vector2.ONE)
	_draw_bands()
	_draw_edges()
	for i in range(_nodes.size()):
		if _visible_nodes[i] != 0:
			_draw_node(i)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_bands() -> void:
	var left := _visible_bounds.position.x
	var right := _visible_bounds.position.x + _visible_bounds.size.x
	var font := get_theme_default_font()
	var last_visible := -1
	for band_index in range(_bands.size()):
		if _visible_bands[band_index] == 0:
			continue
		last_visible = band_index
		var band: Dictionary = _bands[band_index]
		var top := float(band.get("top", 0.0))
		var bottom := float(band.get("bottom", 0.0))
		var reached := band_index <= _frontier_band
		var tint := UITokens.BRASS_HIGHLIGHT if reached else UITokens.TEXT_FAINT
		var band_fill := (0.42 if band_index % 2 == 0 else 0.24)
		draw_rect(Rect2(left, top, right - left, bottom - top),
			Color(0.030, 0.026, 0.021, band_fill), true)
		draw_line(Vector2(left, top), Vector2(right, top),
			Color(tint.r, tint.g, tint.b, 0.34), 1.0, true)
		var label := String(band.get("display_name", ""))
		var extent := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ERA_FONT_SIZE)
		var centre := (left + right) * 0.5
		var label_alpha := (0.92 if reached else 0.60)
		draw_string(font, Vector2(centre - extent.x * 0.5, top + 20.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, ERA_FONT_SIZE,
			Color(tint.r, tint.g, tint.b, label_alpha))
	if last_visible < 0 or last_visible + 1 >= _bands.size():
		return
	# The horizon sits inside the pannable bounds so the closing hint is always
	# reachable, and it never hints at how many eras remain.
	var horizon := _visible_bounds.position.y + _visible_bounds.size.y - VIEW_PADDING * 0.62
	var dash := left
	while dash < right:
		draw_line(Vector2(dash, horizon), Vector2(minf(dash + 14.0, right), horizon),
			Color(UITokens.TEXT_FAINT.r, UITokens.TEXT_FAINT.g, UITokens.TEXT_FAINT.b, 0.34),
			1.0, true)
		dash += 26.0
	var hint := "未知时代"
	var hint_extent := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ERA_FONT_SIZE)
	draw_string(font, Vector2((left + right) * 0.5 - hint_extent.x * 0.5, horizon + 20.0),
		hint, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ERA_FONT_SIZE,
		Color(UITokens.TEXT_FAINT.r, UITokens.TEXT_FAINT.g, UITokens.TEXT_FAINT.b, 0.62))


func _draw_edges() -> void:
	var focus := _selected if _selected >= 0 else _hovered
	for edge in _edges:
		var data: Dictionary = edge
		var from := int(data.from)
		var to := int(data.to)
		if _visible_nodes[from] == 0 or _visible_nodes[to] == 0:
			continue
		if not _is_known(from) and not _is_known(to):
			continue
		var satisfied := _state_of(from) >= 4
		var colour := UITokens.GOOD if satisfied else UITokens.WARN
		var alpha := 0.42 if satisfied else 0.30
		var width := 1.6
		if focus >= 0:
			var related := from == focus or to == focus \
				or (_chain_up.has(from) and _chain_up.has(to)) \
				or (_chain_up.has(from) and to == focus)
			if related:
				alpha = 0.95
				width = 2.4
			else:
				alpha = 0.10
		draw_polyline(data.points, Color(colour.r, colour.g, colour.b, alpha), width, true)
		if focus >= 0 and alpha > 0.5:
			var points: PackedVector2Array = data.points
			var tip: Vector2 = points[points.size() - 1]
			draw_circle(tip, 3.0, Color(colour.r, colour.g, colour.b, 0.95))


func _draw_node(index: int) -> void:
	var node: Dictionary = _nodes[index]
	var rect: Rect2 = node.rect
	var state := _state_of(index)
	var known := _is_known(index)
	var domain := int(node.domain)
	var accent := _accent_for(domain)
	var emphasis := _emphasis_for(index)
	draw_style_box(_card_style(domain, state, known, bool(node.is_milestone), emphasis), rect)
	if not known:
		_draw_unknown_body(rect, accent, emphasis)
		return
	var definition: Dictionary = _definitions[index]
	var dim := emphasis == 0
	var text_colour := UITokens.TEXT_MAIN if not dim else Color(
		UITokens.TEXT_MUTED.r, UITokens.TEXT_MUTED.g, UITokens.TEXT_MUTED.b, 0.55)
	var icon_colour := accent.lerp(UITokens.TEXT_MAIN, 0.34)
	if dim:
		icon_colour.a = 0.45
	_draw_glyph(IconCatalog.technology_domain_semantic(
		String(definition.get("domain_id", ""))),
		rect.position + Vector2(13.0, rect.size.y * 0.5 + 5.0), 13, icon_colour)
	var badge_key := IconCatalog.technology_state_semantic(state)
	var badge_colour := _state_colour(state)
	if dim:
		badge_colour.a = 0.45
	_draw_glyph(badge_key,
		rect.position + Vector2(rect.size.x - 21.0, rect.size.y * 0.5 + 5.0),
		12, badge_colour)
	if bool(node.is_milestone):
		var crown := UITokens.BRASS_HIGHLIGHT
		if dim:
			crown.a = 0.45
		_draw_glyph(&"technology.milestone",
			rect.position + Vector2(rect.size.x * 0.5 - 6.0, 14.0), 12, crown)
	var name_top := rect.size.y * 0.5 + (11.0 if bool(node.is_milestone) else 5.0)
	var label := String(definition.get("display_name", ""))
	var name_left := 33.0
	draw_string(_name_font, rect.position + Vector2(name_left, name_top), label,
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - name_left - 24.0, NAME_FONT_SIZE,
		text_colour)
	_draw_progress(index, rect, accent, dim)


func _draw_unknown_body(rect: Rect2, accent: Color, emphasis: int) -> void:
	var tint := accent.lerp(UITokens.TEXT_FAINT, 0.72)
	tint.a = 0.34 if emphasis == 0 else 0.62
	_draw_glyph(&"technology.state.unknown",
		rect.position + Vector2(rect.size.x * 0.5 - 5.0, rect.size.y * 0.5 + 6.0), 15, tint)


func _draw_progress(index: int, rect: Rect2, accent: Color, dim: bool) -> void:
	var state := _state_of(index)
	if state < 2 or state >= 5:
		return
	var cost := maxf(1.0, float((_definitions[index] as Dictionary).get("cost_points", 1)))
	var earned := float(_progress[index]) / 1000.0 if index < _progress.size() else 0.0
	var fraction := clampf(earned / cost, 0.0, 1.0)
	var track := Rect2(rect.position + Vector2(12.0, rect.size.y - 11.0),
		Vector2(rect.size.x - 24.0, 4.0))
	draw_rect(track, Color(0.020, 0.018, 0.015, (0.40 if dim else 0.86)), true)
	if fraction <= 0.0:
		return
	var fill := Rect2(track.position, Vector2(track.size.x * fraction, track.size.y))
	var colour := accent.lerp(UITokens.BRASS_HIGHLIGHT, 0.42)
	colour.a = 1.0 if not dim else 0.45
	draw_rect(fill, colour, true)


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


func _card_style(domain: int, state: int, known: bool, milestone: bool,
		emphasis: int) -> StyleBoxFlat:
	var key := "%d:%d:%d:%d:%d" % [domain, state, (1 if known else 0),
		(1 if milestone else 0), emphasis]
	if _card_styles.has(key):
		return _card_styles[key]
	var accent := _accent_for(domain)
	var style := StyleBoxFlat.new()
	var radius := UITokens.RADIUS_MD if milestone else UITokens.RADIUS_SM
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.anti_aliasing = true
	style.border_width_left = 3
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	if not known:
		var faded := emphasis > 0
		style.bg_color = Color(0.036, 0.032, 0.027, (0.72 if faded else 0.52))
		style.border_width_left = 1
		style.border_color = Color(accent.r, accent.g, accent.b,
			(0.30 if faded else 0.16))
		_card_styles[key] = style
		return style
	var border := accent
	match state:
		5:
			border = UITokens.GOOD
		4:
			border = UITokens.WARN
		3:
			border = UITokens.WATER.lerp(UITokens.TEXT_MAIN, 0.24)
		2:
			border = UITokens.BRASS_HIGHLIGHT
		_:
			border = accent.lerp(UITokens.TEXT_FAINT, 0.5)
	if milestone:
		border = border.lerp(UITokens.BRASS_HIGHLIGHT, 0.55)
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
	var body := UITokens.CARD_BG if state >= 2 else Color(0.072, 0.062, 0.049, 0.94)
	match emphasis:
		2:
			style.bg_color = UITokens.CARD_BG_HOVER
			style.border_color = border.lerp(UITokens.TEXT_MAIN, 0.30)
			style.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
			style.shadow_size = 8
			style.shadow_offset = Vector2(0.0, 3.0)
		1:
			style.bg_color = body
			style.border_color = Color(border.r, border.g, border.b, 0.82)
			style.shadow_color = Color(0.0, 0.0, 0.0, 0.34)
			style.shadow_size = 4
			style.shadow_offset = Vector2(0.0, 2.0)
		_:
			style.bg_color = Color(body.r, body.g, body.b, 0.55)
			style.border_color = Color(border.r, border.g, border.b, 0.24)
	_card_styles[key] = style
	return style
