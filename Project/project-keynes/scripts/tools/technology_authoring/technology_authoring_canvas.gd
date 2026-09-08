extends Control

## Authoring canvas for the whole technology network.
##
## The previous prototype instantiated one GraphNode per technology and rebuilt
## all of them after every field edit. At 369 nodes and 1300+ edges that made
## the tool unusable, so this is a single Control that draws the baked layout
## with viewport culling and answers hit tests from a spatial hash. It also
## reuses `TechnologyTreeLayout`, which is the same layout the player-facing
## tree uses, so an author sees the arrangement players will see.

const LayoutScript = preload("res://scripts/ui/technology_tree_layout.gd")

const CELL_SIZE := 256.0
const ZOOM_MIN := 0.12
const ZOOM_MAX := 2.4
const ZOOM_STEP := 1.12
const DRAG_THRESHOLD := 6.0
## Below this the canvas has not been laid out yet and a fit would be meaningless.
const MIN_FIT_EXTENT := 40.0

const BAND_FILL := Color(0.128, 0.112, 0.088, 1.0)
const BAND_FILL_ALT := Color(0.152, 0.132, 0.102, 1.0)
const BAND_RULE := Color(0.40, 0.30, 0.18, 0.65)
const BAND_TEXT := Color(0.80, 0.71, 0.55, 1.0)
const CARD_FILL := Color(0.205, 0.180, 0.140, 1.0)
const CARD_FILL_DIM := Color(0.140, 0.126, 0.104, 1.0)
const CARD_BORDER := Color(0.42, 0.33, 0.21, 0.90)
const CARD_TEXT := Color(0.955, 0.918, 0.828, 1.0)
const CARD_TEXT_DIM := Color(0.52, 0.48, 0.41, 1.0)
const SELECTED_BORDER := Color(0.93, 0.74, 0.38, 1.0)
const PROBLEM_BORDER := Color(0.82, 0.31, 0.24, 1.0)
const MILESTONE_FILL := Color(0.255, 0.205, 0.130, 1.0)
const EDGE_HARD := Color(0.70, 0.58, 0.36, 0.85)
const EDGE_SOFT := Color(0.44, 0.52, 0.60, 0.60)
const EDGE_BRANCH := Color(0.46, 0.60, 0.42, 0.60)
const EDGE_CANDIDATE := Color(0.62, 0.46, 0.62, 0.50)
const EDGE_SELECTED := Color(0.96, 0.80, 0.42, 0.98)
const CONNECT_LINE := Color(0.96, 0.62, 0.30, 0.95)
const MARQUEE_FILL := Color(0.93, 0.74, 0.38, 0.12)
const MARQUEE_LINE := Color(0.93, 0.74, 0.38, 0.70)

## Hard prerequisites and the two small cross-cutting classes are legible at
## once. Route evidence and milestone candidacy are opt-in.
const DEFAULT_EDGE_KINDS := {
	"hard": true,
	"branch": true,
	"application": true,
	"alternative": false,
	"milestone_candidate": false,
}

const DOMAIN_FALLBACK := [
	Color(0.39, 0.62, 0.31), Color(0.72, 0.48, 0.24),
	Color(0.28, 0.58, 0.74), Color(0.67, 0.48, 0.68),
]

signal selection_changed(ids: PackedStringArray)
signal node_activated(id: String)
signal connect_requested(from_id: String, to_id: String)
signal context_requested(id: String, screen_position: Vector2)
signal reorder_requested(era_id: String, ordered_ids: PackedStringArray)
signal viewport_changed()

var _definitions: Array = []
var _eras: Array = []
var _domains: Array = []
var _edges_source: Array = []
var _layout: Dictionary = {}
var _index_by_id: Dictionary = {}
var _ids: PackedStringArray = PackedStringArray()
var _buckets: Dictionary = {}
var _domain_accents: Array[Color] = []
var _selected: Dictionary = {}
var _primary := ""
var _problem_severity: Dictionary = {}
var _match_ids: Dictionary = {}
var _filtered := false
var _edge_kinds: Dictionary = DEFAULT_EDGE_KINDS.duplicate()
var _selection_only_edges := false
var _last_size := Vector2.ZERO
var _fit_pending := false
var _offset := Vector2.ZERO
var _zoom := 0.5
var _pan_active := false
var _pan_origin := Vector2.ZERO
var _pan_offset := Vector2.ZERO
var _press_position := Vector2.ZERO
var _press_node := -1
var _drag_mode := ""
var _drag_current := Vector2.ZERO
var _hover_node := -1
var _title_font: FontVariation
var _label_font: FontVariation
var _draw_count := 0
var _bakes := 0
var _last_bake_msec := 0.0
var _last_visible_nodes := 0
var _last_visible_edges := 0
var _last_draw_usec := 0


func _ready() -> void:
	_title_font = UITokens.font_with_weight(640)
	_label_font = UITokens.font_with_weight(420)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_last_size = size
	resized.connect(_on_resized)


# --------------------------------------------------------------------------
# Catalog
# --------------------------------------------------------------------------

## Bakes the layout once. Field edits never call this; only structural changes
## (add, delete, rename, era or relation topology) need a rebake.
func set_catalog(definitions: Array, eras: Array, domains: Array,
		visual_edges: Array) -> Dictionary:
	var started := Time.get_ticks_usec()
	_definitions = definitions
	_eras = eras
	_domains = domains
	_edges_source = visual_edges
	_layout = LayoutScript.build(definitions, eras, domains, visual_edges)
	_index_by_id.clear()
	_ids = PackedStringArray()
	for index in range(definitions.size()):
		var id := String((definitions[index] as Dictionary).get("id", ""))
		_index_by_id[id] = index
		_ids.append(id)
	_domain_accents.clear()
	for index in range(domains.size()):
		var accent := String((domains[index] as Dictionary).get("accent", ""))
		if accent.is_empty():
			_domain_accents.append(DOMAIN_FALLBACK[index % DOMAIN_FALLBACK.size()])
		else:
			_domain_accents.append(Color(accent))
	if _domain_accents.is_empty():
		_domain_accents.assign(DOMAIN_FALLBACK)
	_rebuild_buckets()
	queue_redraw()
	_bakes += 1
	_last_bake_msec = float(Time.get_ticks_usec() - started) / 1000.0
	return {
		"ok": bool(_layout.get("ok", false)),
		"nodes": (_layout.get("nodes", []) as Array).size(),
		"edges": (_layout.get("edges", []) as Array).size(),
		"msec": _last_bake_msec,
	}


func _rebuild_buckets() -> void:
	_buckets.clear()
	for node_value in _layout.get("nodes", []):
		var node: Dictionary = node_value
		var rect: Rect2 = node.rect
		var index := int(node.index)
		var from_x := int(floor(rect.position.x / CELL_SIZE))
		var to_x := int(floor(rect.end.x / CELL_SIZE))
		var from_y := int(floor(rect.position.y / CELL_SIZE))
		var to_y := int(floor(rect.end.y / CELL_SIZE))
		for cell_x in range(from_x, to_x + 1):
			for cell_y in range(from_y, to_y + 1):
				var key := Vector2i(cell_x, cell_y)
				var bucket: PackedInt32Array = _buckets.get(key, PackedInt32Array())
				bucket.append(index)
				_buckets[key] = bucket


func report() -> Dictionary:
	return {
		"nodes": (_layout.get("nodes", []) as Array).size(),
		"edges": (_layout.get("edges", []) as Array).size(),
		"child_count": get_child_count(),
		"draw_count": _draw_count,
		"bakes": _bakes,
		"bake_msec": _last_bake_msec,
		"visible_nodes": _last_visible_nodes,
		"visible_edges": _last_visible_edges,
		"draw_usec": _last_draw_usec,
		"zoom": _zoom,
	}


# --------------------------------------------------------------------------
# State patches
# --------------------------------------------------------------------------

## Patch-only update: badges and dimming never rebake the layout.
func set_problems(severity_by_id: Dictionary) -> void:
	_problem_severity = severity_by_id
	queue_redraw()


func set_matches(match_ids: Dictionary, filtered: bool) -> void:
	_match_ids = match_ids
	_filtered = filtered
	queue_redraw()


## Edge-kind visibility. All 1331 edges at once is an unreadable hairball: 635
## `alternative` route-evidence edges and 143 milestone-candidate edges span
## thousands of units, so their endpoints sit off-screen and they read as
## stray diagonals. The author picks which relation classes to see.
func set_edge_kinds(visible_kinds: Dictionary) -> void:
	_edge_kinds = visible_kinds
	queue_redraw()


## Restricts edges to those touching the current selection, which is the only
## readable way to inspect one node's relations inside a dense band.
func set_selection_only_edges(enabled: bool) -> void:
	_selection_only_edges = enabled
	queue_redraw()


func select(ids: PackedStringArray, primary := "") -> void:
	_selected.clear()
	for id in ids:
		_selected[String(id)] = true
	_primary = primary if not primary.is_empty() else (
		String(ids[0]) if not ids.is_empty() else "")
	queue_redraw()


func primary_selection() -> String:
	return _primary


func selection() -> PackedStringArray:
	var out := PackedStringArray()
	for id in _selected:
		out.append(String(id))
	return out


func focus_technology(id: String) -> void:
	var index := int(_index_by_id.get(id, -1))
	if index < 0:
		return
	var rect := _node_rect(index)
	_offset = size * 0.5 - rect.get_center() * _zoom
	queue_redraw()
	viewport_changed.emit()


## A resize must not move the graph under the author's cursor. Keeping the world
## point at the canvas centre fixed is what makes that true; without it the view
## stays pinned to the top-left corner and every window change lands on a
## different part of the network.
func _on_resized() -> void:
	if _fit_pending and _apply_fit():
		return
	if _last_size.x > 0.0 and _last_size.y > 0.0:
		_offset += (size - _last_size) * 0.5
	_last_size = size
	queue_redraw()
	viewport_changed.emit()


## Called right after loading, when the shell has not been laid out yet and the
## canvas still measures zero. The fit is therefore deferred to the first resize
## that gives it a real rect, instead of being dropped on the floor.
func fit_to_content() -> void:
	if not _apply_fit():
		_fit_pending = true


func _apply_fit() -> bool:
	var content: Rect2 = _layout.get("content_rect", Rect2())
	if content.size.x <= 0.0 or content.size.y <= 0.0 \
			or size.x < MIN_FIT_EXTENT or size.y < MIN_FIT_EXTENT:
		return false
	_zoom = clampf(minf(size.x / (content.size.x + 80.0),
		size.y / (content.size.y + 80.0)), ZOOM_MIN, ZOOM_MAX)
	_offset = size * 0.5 - content.get_center() * _zoom
	_fit_pending = false
	_last_size = size
	queue_redraw()
	viewport_changed.emit()
	return true


func zoom_level() -> float:
	return _zoom


## Screen-space check that every drawn edge still terminates on the border of
## the nodes it claims to join. Kept as a diagnostic because a transform that
## drifts between the node pass and the edge pass is invisible in world space
## and only shows up as stray diagonals on screen.
func edge_alignment_report() -> Dictionary:
	var worst := 0.0
	var checked := 0
	var offenders := PackedStringArray()
	for edge_value in _layout.get("edges", []):
		var edge: Dictionary = edge_value
		if not bool(_edge_kinds.get(String(edge.kind), true)):
			continue
		var points: PackedVector2Array = edge.points
		if points.is_empty():
			continue
		var from_rect := _to_screen_rect(_node_rect(int(edge.from)))
		var to_rect := _to_screen_rect(_node_rect(int(edge.to)))
		var start_gap := _rect_gap(from_rect, _to_screen(points[0]))
		var end_gap := _rect_gap(to_rect, _to_screen(points[points.size() - 1]))
		var gap := maxf(start_gap, end_gap)
		checked += 1
		if gap > worst:
			worst = gap
		if gap > 1.5 and offenders.size() < 8:
			offenders.append("%s→%s %.2fpx" % [String(_ids[int(edge.from)]),
				String(_ids[int(edge.to)]), gap])
	return {
		"checked": checked,
		"worst_gap": worst,
		"offenders": offenders,
		"zoom": _zoom,
		"offset": _offset,
		"size": size,
	}


func _rect_gap(rect: Rect2, point: Vector2) -> float:
	var clamped := Vector2(
		clampf(point.x, rect.position.x, rect.end.x),
		clampf(point.y, rect.position.y, rect.end.y))
	return clamped.distance_to(point)


# --------------------------------------------------------------------------
# Drawing
# --------------------------------------------------------------------------

func _draw() -> void:
	var started := Time.get_ticks_usec()
	_draw_count += 1
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.075, 0.068, 0.056, 1.0))
	if not bool(_layout.get("ok", false)):
		draw_string(_label_font, Vector2(24.0, 32.0), "尚未载入科技网络",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, BAND_TEXT)
		return
	var view := Rect2(-_offset / _zoom, size / _zoom).grow(CELL_SIZE)
	_draw_bands(view)
	_last_visible_edges = _draw_edges(view)
	_last_visible_nodes = _draw_nodes(view)
	if _drag_mode == "connect" and _press_node >= 0:
		draw_line(_to_screen(_node_rect(_press_node).get_center()), _drag_current,
			CONNECT_LINE, 2.0)
	elif _drag_mode == "marquee":
		var marquee := Rect2(_press_position, _drag_current - _press_position).abs()
		draw_rect(marquee, MARQUEE_FILL, true)
		draw_rect(marquee, MARQUEE_LINE, false, 1.0)
	_draw_legend()
	_last_draw_usec = Time.get_ticks_usec() - started


func _draw_bands(view: Rect2) -> void:
	var bands: Array = _layout.get("bands", [])
	for index in range(bands.size()):
		var band: Dictionary = bands[index]
		var rect: Rect2 = band.get("rect", Rect2())
		if not view.intersects(rect):
			continue
		var screen := _to_screen_rect(rect)
		draw_rect(screen, BAND_FILL_ALT if index % 2 == 1 else BAND_FILL, true)
		draw_line(Vector2(screen.position.x, screen.position.y),
			Vector2(screen.end.x, screen.position.y), BAND_RULE, 1.0)
		if _zoom >= 0.2:
			draw_string(_title_font, Vector2(screen.position.x + 10.0,
				screen.position.y + 20.0),
				"%s（%s）" % [String(band.display_name), String(band.id)],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, BAND_TEXT)


func _draw_edges(view: Rect2) -> int:
	var drawn := 0
	var highlight_selection := not _selected.is_empty()
	for edge_value in _layout.get("edges", []):
		var edge: Dictionary = edge_value
		if not view.intersects(edge.bounds as Rect2):
			continue
		var kind := String(edge.kind)
		if not bool(_edge_kinds.get(kind, true)):
			continue
		var from_id := String(_ids[int(edge.from)])
		var to_id := String(_ids[int(edge.to)])
		var touches_selection := highlight_selection \
			and (_selected.has(from_id) or _selected.has(to_id))
		if _selection_only_edges and not touches_selection:
			continue
		if _filtered and not touches_selection \
				and not (_match_ids.has(from_id) and _match_ids.has(to_id)):
			continue
		var color := EDGE_HARD
		match kind:
			"hard": color = EDGE_HARD
			"alternative": color = EDGE_SOFT
			"branch": color = EDGE_BRANCH
			"application": color = EDGE_SOFT
			"milestone_candidate": color = EDGE_CANDIDATE
		if touches_selection:
			color = EDGE_SELECTED
		elif highlight_selection:
			color = Color(color.r, color.g, color.b, color.a * 0.35)
		var points: PackedVector2Array = edge.points
		var screen := PackedVector2Array()
		for point in points:
			screen.append(_to_screen(point))
		if kind == "hard":
			draw_polyline(screen, color, 2.0 if touches_selection else 1.4)
		else:
			_draw_dashed_polyline(screen, color, 1.2)
		drawn += 1
	return drawn


func _draw_dashed_polyline(points: PackedVector2Array, color: Color,
		width: float) -> void:
	for cursor in range(points.size() - 1):
		if cursor % 2 == 1:
			continue
		draw_line(points[cursor], points[cursor + 1], color, width)


func _draw_nodes(view: Rect2) -> int:
	var drawn := 0
	var show_text := _zoom >= 0.32
	for node_value in _layout.get("nodes", []):
		var node: Dictionary = node_value
		var rect: Rect2 = node.rect
		if not view.intersects(rect):
			continue
		var index := int(node.index)
		var id := String(_ids[index])
		var dimmed := _filtered and not _match_ids.has(id)
		var screen := _to_screen_rect(rect)
		var fill := CARD_FILL
		if dimmed:
			fill = CARD_FILL_DIM
		elif bool(node.is_milestone):
			fill = MILESTONE_FILL
		draw_rect(screen, fill, true)
		var accent := _domain_accents[int(node.domain) % _domain_accents.size()]
		if dimmed:
			accent = Color(accent.r, accent.g, accent.b, 0.25)
		draw_rect(Rect2(screen.position, Vector2(4.0, screen.size.y)), accent, true)
		var border := CARD_BORDER
		var thickness := 1.0
		var severity := String(_problem_severity.get(id, ""))
		if severity == "error":
			border = PROBLEM_BORDER
			thickness = 2.0
		elif severity == "warning":
			border = Color(0.80, 0.62, 0.26, 0.95)
			thickness = 2.0
		if _selected.has(id):
			border = SELECTED_BORDER
			thickness = 3.0
		elif index == _hover_node:
			border = Color(border.r, border.g, border.b, 1.0)
			thickness = maxf(thickness, 2.0)
		draw_rect(screen, border, false, thickness)
		if bool(node.is_milestone):
			draw_rect(Rect2(screen.position + Vector2(6.0, 4.0), Vector2(7.0, 7.0)),
				SELECTED_BORDER, true)
		if not show_text:
			drawn += 1
			continue
		var text_color := CARD_TEXT_DIM if dimmed else CARD_TEXT
		var definition: Dictionary = _definitions[index]
		draw_string(_title_font, screen.position + Vector2(12.0, 20.0),
			String(definition.get("display_name", id)),
			HORIZONTAL_ALIGNMENT_LEFT, screen.size.x - 18.0, 13, text_color)
		draw_string(_label_font, screen.position + Vector2(12.0, 36.0),
			id.trim_prefix("tech."), HORIZONTAL_ALIGNMENT_LEFT,
			screen.size.x - 18.0, 11, Color(text_color.r, text_color.g, text_color.b, 0.62))
		if _zoom >= 0.5:
			var terms: Array = definition.get("modifier_terms", [])
			var effects: Array = definition.get("content_effects", [])
			draw_string(_label_font, screen.position + Vector2(12.0, screen.size.y - 8.0),
				"%d 成本 · %d 效果 · %d 解锁" % [int(definition.get("cost_points", 0)),
					terms.size(), effects.size()],
				HORIZONTAL_ALIGNMENT_LEFT, screen.size.x - 18.0, 10,
				Color(text_color.r, text_color.g, text_color.b, 0.52))
		if not severity.is_empty():
			var badge := Rect2(Vector2(screen.end.x - 14.0, screen.position.y + 4.0),
				Vector2(10.0, 10.0))
			draw_rect(badge, PROBLEM_BORDER if severity == "error" else Color(
				0.80, 0.62, 0.26, 1.0), true)
		drawn += 1
	return drawn


func _draw_legend() -> void:
	var lines := PackedStringArray([
		"滚轮缩放 · 中键或 Ctrl+左键平移 · 左键框选",
		"左键从节点拖到另一节点 = 加硬前置（需填理由）",
		"Shift+左键拖动 = 在同一时代内改 layout_order 序位",
		"右键节点 = 菜单 · 双击 = 聚焦",
	])
	var origin := Vector2(12.0, size.y - 62.0)
	draw_rect(Rect2(origin - Vector2(6.0, 14.0), Vector2(430.0, 66.0)),
		Color(0.06, 0.055, 0.045, 0.80), true)
	for index in range(lines.size()):
		draw_string(_label_font, origin + Vector2(0.0, index * 15.0),
			String(lines[index]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
			Color(0.72, 0.66, 0.54, 0.92))


# --------------------------------------------------------------------------
# Transforms and hit testing
# --------------------------------------------------------------------------

func _to_screen(point: Vector2) -> Vector2:
	return point * _zoom + _offset


func _to_world(point: Vector2) -> Vector2:
	return (point - _offset) / _zoom


func _to_screen_rect(rect: Rect2) -> Rect2:
	return Rect2(_to_screen(rect.position), rect.size * _zoom)


func _node_rect(index: int) -> Rect2:
	var nodes: Array = _layout.get("nodes", [])
	if index < 0 or index >= nodes.size():
		return Rect2()
	return (nodes[index] as Dictionary).rect


func _node_at(screen_position: Vector2) -> int:
	var world := _to_world(screen_position)
	var key := Vector2i(int(floor(world.x / CELL_SIZE)), int(floor(world.y / CELL_SIZE)))
	var bucket: PackedInt32Array = _buckets.get(key, PackedInt32Array())
	for index in bucket:
		if _node_rect(int(index)).has_point(world):
			return int(index)
	return -1


func _nodes_in_rect(screen_rect: Rect2) -> PackedStringArray:
	var world := Rect2(_to_world(screen_rect.position), screen_rect.size / _zoom)
	var out := PackedStringArray()
	for node_value in _layout.get("nodes", []):
		var node: Dictionary = node_value
		if not world.intersects(node.rect as Rect2):
			continue
		out.append(String(_ids[int(node.index)]))
	return out


# --------------------------------------------------------------------------
# Input
# --------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_handle_motion(event as InputEventMouseMotion)


func _handle_button(event: InputEventMouseButton) -> void:
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		_apply_zoom(ZOOM_STEP, event.position)
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		_apply_zoom(1.0 / ZOOM_STEP, event.position)
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_pan_active = event.pressed
		_pan_origin = event.position
		_pan_offset = _offset
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var hit := _node_at(event.position)
		if hit >= 0:
			var id := String(_ids[hit])
			if not _selected.has(id):
				select(PackedStringArray([id]), id)
				selection_changed.emit(selection())
			context_requested.emit(id, get_screen_position() + event.position)
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		grab_focus()
		_press_position = event.position
		_drag_current = event.position
		_press_node = _node_at(event.position)
		if event.ctrl_pressed:
			_drag_mode = "pan"
			_pan_origin = event.position
			_pan_offset = _offset
		elif _press_node >= 0 and event.double_click:
			_drag_mode = ""
			node_activated.emit(String(_ids[_press_node]))
		elif _press_node >= 0:
			_drag_mode = "connect" if not event.shift_pressed else "reorder"
		else:
			_drag_mode = "marquee"
		accept_event()
		return
	var travelled := event.position.distance_to(_press_position)
	match _drag_mode:
		"connect":
			var target := _node_at(event.position)
			if travelled <= DRAG_THRESHOLD or target < 0 or target == _press_node:
				_commit_click_selection(event)
			else:
				connect_requested.emit(String(_ids[_press_node]), String(_ids[target]))
		"reorder":
			if travelled > DRAG_THRESHOLD:
				_commit_reorder(event.position)
			else:
				_commit_click_selection(event)
		"marquee":
			if travelled > DRAG_THRESHOLD:
				var picked := _nodes_in_rect(Rect2(_press_position,
					event.position - _press_position).abs())
				select(picked, String(picked[0]) if not picked.is_empty() else "")
				selection_changed.emit(picked)
			else:
				select(PackedStringArray(), "")
				selection_changed.emit(PackedStringArray())
	_drag_mode = ""
	_press_node = -1
	queue_redraw()
	accept_event()


func _commit_click_selection(event: InputEventMouseButton) -> void:
	if _press_node < 0:
		return
	var id := String(_ids[_press_node])
	if event.shift_pressed or event.alt_pressed:
		if _selected.has(id):
			_selected.erase(id)
		else:
			_selected[id] = true
		_primary = id
		queue_redraw()
	else:
		select(PackedStringArray([id]), id)
	selection_changed.emit(selection())


## Reorders `layout_order` among the dragged node's era peers by the drop
## position. Free coordinates are deliberately not authored: the player tree
## computes positions from the same layout pass, so only ordering can matter.
func _commit_reorder(drop_position: Vector2) -> void:
	if _press_node < 0:
		return
	var definition: Dictionary = _definitions[_press_node]
	var era_id := String(definition.get("era_id", ""))
	var dragged_id := String(_ids[_press_node])
	var peers: Array[Dictionary] = []
	for index in range(_definitions.size()):
		var row: Dictionary = _definitions[index]
		if String(row.get("era_id", "")) != era_id:
			continue
		var id := String(_ids[index])
		if id == dragged_id:
			continue
		peers.append({"id": id, "x": _node_rect(index).get_center().x})
	peers.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return float(left.x) < float(right.x))
	var drop_x := _to_world(drop_position).x
	var ordered := PackedStringArray()
	var inserted := false
	for peer in peers:
		if not inserted and drop_x < float(peer.x):
			ordered.append(dragged_id)
			inserted = true
		ordered.append(String(peer.id))
	if not inserted:
		ordered.append(dragged_id)
	reorder_requested.emit(era_id, ordered)


func _handle_motion(event: InputEventMouseMotion) -> void:
	if _pan_active or _drag_mode == "pan":
		_offset = _pan_offset + (event.position - _pan_origin)
		queue_redraw()
		viewport_changed.emit()
		return
	if not _drag_mode.is_empty():
		_drag_current = event.position
		queue_redraw()
		return
	var hit := _node_at(event.position)
	if hit != _hover_node:
		_hover_node = hit
		tooltip_text = _tooltip_for(hit)
		queue_redraw()


func _tooltip_for(index: int) -> String:
	if index < 0:
		return ""
	var definition: Dictionary = _definitions[index]
	var id := String(definition.get("id", ""))
	var lines := PackedStringArray([
		"%s（%s）" % [String(definition.get("display_name", id)), id],
		"时代 %s · 领域 %s · 分支族 %s" % [String(definition.get("era_id", "")),
			String(definition.get("domain_id", "")),
			String(definition.get("branch_family_id", ""))],
		"成本 %d · 效果 %d 条 · 解锁 %d 条" % [int(definition.get("cost_points", 0)),
			(definition.get("modifier_terms", []) as Array).size(),
			(definition.get("content_effects", []) as Array).size()],
	])
	var summary := String(definition.get("effect_summary", ""))
	if not summary.is_empty():
		lines.append(summary)
	return "\n".join(lines)


func _apply_zoom(factor: float, anchor: Vector2) -> void:
	var next := clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if is_equal_approx(next, _zoom):
		return
	var world := _to_world(anchor)
	_zoom = next
	_offset = anchor - world * _zoom
	queue_redraw()
	viewport_changed.emit()
