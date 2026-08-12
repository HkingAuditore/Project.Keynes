extends Control
class_name TechnologyOverviewView

signal cell_activated(lane_id: String, era_index: int, technology_index: int)

const LABEL_WIDTH := 214.0
const HEADER_HEIGHT := 34.0
const ROW_HEIGHT := 28.0
const CELL_GAP := 4.0
const DOT_RADIUS := 3.0

var _definitions: Array = []
var _eras: Array = []
var _lanes: Array = []
var _states := PackedInt32Array()
var _cells: Array[Dictionary] = []
var _visible_eras: Array[int] = []
var _hovered := -1
var _label_font: Font = UITokens.font_with_weight(580)
var _reveal_signature := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func set_catalog(definitions: Array, eras: Array, lanes: Array) -> void:
	if not _definitions.is_empty():
		return
	_definitions = definitions
	_eras = eras
	_lanes = lanes
	queue_redraw()


func patch_states(states: PackedInt32Array) -> void:
	_states = states
	var signature := 17
	for state in states:
		signature = int((signature * 31 + (1 if int(state) > 0 else 0)) & 0x7fffffff)
	if signature != _reveal_signature:
		_reveal_signature = signature
		_rebuild_cells()
	queue_redraw()


func overview_report() -> Dictionary:
	var visible_lanes := {}
	var visible_eras := {}
	for cell in _cells:
		visible_lanes[String(cell.lane_id)] = true
		visible_eras[int(cell.era_index)] = true
	return {
		"cells": _cells.size(),
		"visible_lanes": visible_lanes.size(),
		"visible_eras": visible_eras.size(),
	}


func _rebuild_cells() -> void:
	_cells.clear()
	_visible_eras.clear()
	var era_lookup := {}
	for index in range(_eras.size()):
		era_lookup[String((_eras[index] as Dictionary).get("id", ""))] = index
	var lane_lookup := {}
	for index in range(_lanes.size()):
		lane_lookup[String((_lanes[index] as Dictionary).get("id", ""))] = index
	var visible_lane_lookup := {}
	for technology in range(_definitions.size()):
		if _state_of(technology) <= 0:
			continue
		var lane_id := String((_definitions[technology] as Dictionary).get(
			"main_lane", (_definitions[technology] as Dictionary).get("layout_lane", "")))
		if lane_lookup.has(lane_id):
			visible_lane_lookup[lane_id] = true
	var visible_lanes: Array[String] = []
	for lane in _lanes:
		var lane_id := String((lane as Dictionary).get("id", ""))
		if visible_lane_lookup.has(lane_id):
			visible_lanes.append(lane_id)
	for technology in range(_definitions.size()):
		if _state_of(technology) <= 0:
			continue
		var era_index := int(era_lookup.get(String((_definitions[technology] as Dictionary).get(
			"era_id", "")), -1))
		if era_index >= 0 and era_index not in _visible_eras:
			_visible_eras.append(era_index)
	_visible_eras.sort()
	var cell_width := _cell_width()
	for row in range(visible_lanes.size()):
		var lane_id := visible_lanes[row]
		for era_column in range(_visible_eras.size()):
			var era_index := _visible_eras[era_column]
			var candidates: Array[int] = []
			for technology in range(_definitions.size()):
				var definition: Dictionary = _definitions[technology]
				if String(definition.get("main_lane", definition.get("layout_lane", ""))) != lane_id:
					continue
				if int(era_lookup.get(String(definition.get("era_id", "")), -1)) != era_index:
					continue
				if _state_of(technology) > 0:
					candidates.append(technology)
			if candidates.is_empty():
				continue
			var chosen := _preferred(candidates)
			_cells.append({
				"lane_id": lane_id,
				"lane_row": row,
				"era_index": era_index,
				"era_column": era_column,
				"technologies": candidates,
				"technology": chosen,
				"rect": Rect2(Vector2(LABEL_WIDTH + era_column * cell_width,
					HEADER_HEIGHT + row * ROW_HEIGHT),
					Vector2(cell_width - CELL_GAP, ROW_HEIGHT - CELL_GAP)),
			})


func _preferred(candidates: Array[int]) -> int:
	var best := candidates[0]
	for technology in candidates:
		var state := _state_of(technology)
		var best_state := _state_of(best)
		if _priority(state) > _priority(best_state) \
				or (_priority(state) == _priority(best_state) and technology < best):
			best = technology
	return best


func _priority(state: int) -> int:
	match state:
		3, 4: return 4
		2: return 3
		1: return 2
		5: return 1
		_: return 0


func _state_of(index: int) -> int:
	return int(_states[index]) if index >= 0 and index < _states.size() else 0


func _cell_width() -> float:
	return maxf(54.0, (size.x - LABEL_WIDTH) / maxf(1.0, float(_visible_eras.size())))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _cell_at((event as InputEventMouseMotion).position)
		if hit != _hovered:
			_hovered = hit
			tooltip_text = _tooltip_for(hit)
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT or not button.pressed:
			return
		var hit := _cell_at(button.position)
		if hit < 0:
			return
		var cell: Dictionary = _cells[hit]
		cell_activated.emit(String(cell.lane_id), int(cell.era_index), int(cell.technology))
		accept_event()


func _cell_at(position: Vector2) -> int:
	for index in range(_cells.size() - 1, -1, -1):
		if (_cells[index].rect as Rect2).has_point(position):
			return index
	return -1


func _tooltip_for(index: int) -> String:
	if index < 0:
		return ""
	var cell: Dictionary = _cells[index]
	var technology := int(cell.technology)
	return "%s · %d 项已揭示" % [String((_definitions[technology] as Dictionary).get(
		"display_name", "")), (cell.technologies as Array).size()]


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_rebuild_cells()
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovered = -1
		queue_redraw()


func _draw() -> void:
	if _definitions.is_empty():
		return
	var cell_width := _cell_width()
	var visible_rows := {}
	for cell in _cells:
		visible_rows[int(cell.lane_row)] = String(cell.lane_id)
	for era_column in range(_visible_eras.size()):
		var era_index := _visible_eras[era_column]
		var x := LABEL_WIDTH + era_column * cell_width
		draw_string(_label_font, Vector2(x + 6.0, 22.0),
			String((_eras[era_index] as Dictionary).get("display_name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, cell_width - 8.0, 12, UITokens.TEXT_MUTED)
		draw_line(Vector2(x, HEADER_HEIGHT - 4.0),
			Vector2(x, size.y), UITokens.PANEL_BORDER_SOFT, 1.0)
	for row in visible_rows:
		var lane_id := String(visible_rows[row])
		var label := lane_id
		for lane in _lanes:
			if String((lane as Dictionary).get("id", "")) == lane_id:
				label = String((lane as Dictionary).get("display_name", lane_id))
				break
		var y := HEADER_HEIGHT + int(row) * ROW_HEIGHT
		draw_string(_label_font, Vector2(8.0, y + 18.0), label,
			HORIZONTAL_ALIGNMENT_LEFT, LABEL_WIDTH - 16.0, 12, UITokens.TEXT_MAIN)
		draw_line(Vector2(0.0, y + ROW_HEIGHT - 1.0), Vector2(size.x, y + ROW_HEIGHT - 1.0),
			Color(UITokens.PANEL_BORDER_SOFT, 0.35), 1.0)
	for index in range(_cells.size()):
		_draw_cell(index)


func _draw_cell(index: int) -> void:
	var cell: Dictionary = _cells[index]
	var rect: Rect2 = cell.rect
	var hover := index == _hovered
	draw_rect(rect, Color(0.075, 0.065, 0.052, 0.88 if hover else 0.56), true)
	draw_rect(rect, UITokens.BRASS_HIGHLIGHT if hover else UITokens.PANEL_BORDER_SOFT,
		false, 1.0)
	var technologies: Array = cell.technologies
	var count := technologies.size()
	var spacing := mini(12.0, (rect.size.x - 12.0) / maxf(1.0, float(count)))
	var start_x := rect.position.x + (rect.size.x - spacing * float(count - 1)) * 0.5
	for cursor in range(count):
		var technology := int(technologies[cursor])
		var colour := _state_colour(_state_of(technology))
		draw_circle(Vector2(start_x + cursor * spacing, rect.position.y + rect.size.y * 0.5),
			DOT_RADIUS + (1.0 if technology == int(cell.technology) else 0.0), colour)


func _state_colour(state: int) -> Color:
	match state:
		2: return UITokens.BRASS_HIGHLIGHT
		3: return UITokens.WATER.lerp(UITokens.TEXT_MAIN, 0.24)
		4: return UITokens.WARN
		5: return UITokens.GOOD
		_: return UITokens.TEXT_FAINT
