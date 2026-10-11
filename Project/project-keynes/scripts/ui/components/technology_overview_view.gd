extends DossierChart
class_name TechnologyOverviewView

## 科技总览：领域 × 时代的掌握度账表。每格只统计已呈现（state ≥ 2）的科技，
## 用堆叠条区分已掌握 / 研究中 / 可研究，未发现的科技不计入、不泄露数量。

signal cell_activated(domain_id: String, era_index: int, technology_index: int)

const HEADER_HEIGHT := 30.0
const MIN_ROW_HEIGHT := 44.0
const MAX_ROW_HEIGHT := 64.0
const MIN_LABEL_WIDTH := 112.0
const MAX_LABEL_WIDTH := 180.0
const MIN_CELL_WIDTH := 64.0
const CELL_GAP := 4.0
const BAR_HEIGHT := 6.0

var _definitions: Array = []
var _eras: Array = []
var _domains: Array = []
var _states := PackedInt32Array()
var _cells: Array[Dictionary] = []
var _visible_eras: Array[int] = []
var _row_totals: Array = []
var _hovered := -1
var _reveal_signature := 0
var _state_signature := 0
var _cell_style: StyleBoxFlat


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_CLICK
	clip_contents = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func set_catalog(definitions: Array, eras: Array, domains: Array) -> void:
	if not _definitions.is_empty():
		return
	_definitions = definitions
	_eras = eras
	_domains = domains
	queue_redraw()


func patch_states(states: PackedInt32Array) -> void:
	var state_signature := hash(states)
	if state_signature == _state_signature and not _cells.is_empty():
		return
	_state_signature = state_signature
	_states = states
	var signature := 17
	for state in states:
		signature = int((signature * 31 + (1 if TechnologyTreeView.presents_state(int(state)) else 0)) & 0x7fffffff)
	if signature != _reveal_signature:
		_reveal_signature = signature
		_rebuild_cells()
	else:
		_recount()
	queue_redraw()


func overview_report() -> Dictionary:
	var visible_domains := {}
	var visible_eras := {}
	for cell in _cells:
		visible_domains[String(cell.domain_id)] = true
		visible_eras[int(cell.era_index)] = true
	return {
		"cells": _cells.size(),
		"visible_domains": visible_domains.size(),
		"visible_lanes": visible_domains.size(),
		"visible_eras": visible_eras.size(),
	}


## 测试用：某格的统计 {owned, active, available, total}。
func cell_counts(domain_id: String, era_index: int) -> Dictionary:
	for cell in _cells:
		if String(cell.domain_id) == domain_id and int(cell.era_index) == era_index:
			return (cell.counts as Dictionary).duplicate()
	return {}


func _label_width() -> float:
	return clampf(size.x * 0.16, MIN_LABEL_WIDTH, MAX_LABEL_WIDTH)


func _row_height() -> float:
	var rows := maxf(1.0, float(_domains.size()))
	return clampf((size.y - HEADER_HEIGHT - 4.0) / rows, MIN_ROW_HEIGHT, MAX_ROW_HEIGHT)


func _cell_width() -> float:
	return maxf(MIN_CELL_WIDTH,
		(size.x - _label_width()) / maxf(1.0, float(_visible_eras.size())))


func _rebuild_cells() -> void:
	_cells.clear()
	_visible_eras.clear()
	var era_lookup := {}
	for index in range(_eras.size()):
		era_lookup[String((_eras[index] as Dictionary).get("id", ""))] = index
	var buckets := {}
	for technology in range(_definitions.size()):
		if not TechnologyTreeView.presents_state(_state_of(technology)):
			continue
		var definition: Dictionary = _definitions[technology]
		var era_index := int(era_lookup.get(String(definition.get("era_id", "")), -1))
		if era_index < 0:
			continue
		if era_index not in _visible_eras:
			_visible_eras.append(era_index)
		var key := "%s|%d" % [String(definition.get("domain_id", "")), era_index]
		if not buckets.has(key):
			var bucket: Array[int] = []
			buckets[key] = bucket
		(buckets[key] as Array[int]).append(technology)
	_visible_eras.sort()
	var label_width := _label_width()
	var row_height := _row_height()
	var cell_width := _cell_width()
	for row in range(_domains.size()):
		var domain_id := String((_domains[row] as Dictionary).get("id", ""))
		for era_column in range(_visible_eras.size()):
			var era_index := _visible_eras[era_column]
			var key := "%s|%d" % [domain_id, era_index]
			if not buckets.has(key):
				continue
			var candidates: Array[int] = buckets[key]
			_cells.append({
				"domain_id": domain_id,
				"domain_row": row,
				"era_index": era_index,
				"era_column": era_column,
				"technologies": candidates,
				"technology": candidates[0],
				"counts": {},
				"rect": Rect2(Vector2(label_width + era_column * cell_width,
					HEADER_HEIGHT + row * row_height),
					Vector2(cell_width - CELL_GAP, row_height - CELL_GAP)),
			})
	_recount()


func _recount() -> void:
	_row_totals.clear()
	for _row in range(_domains.size()):
		_row_totals.append({"owned": 0, "total": 0})
	for cell in _cells:
		var counts := {"owned": 0, "active": 0, "available": 0, "total": 0}
		for technology in cell.technologies:
			match _state_of(int(technology)):
				5: counts.owned += 1
				3, 4: counts.active += 1
				2: counts.available += 1
			counts.total += 1
		cell.counts = counts
		cell.technology = _preferred(cell.technologies)
		var totals: Dictionary = _row_totals[int(cell.domain_row)]
		totals.owned += int(counts.owned)
		totals.total += int(counts.total)


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


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var hit := _cell_at((event as InputEventMouseMotion).position)
		if hit != _hovered:
			_hovered = hit
			tooltip_text = _tooltip_for(hit)
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hit >= 0 \
				else Control.CURSOR_ARROW
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
		cell_activated.emit(String(cell.domain_id), int(cell.era_index), int(cell.technology))
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
	var counts: Dictionary = cell.counts
	var domain: Dictionary = _domains[int(cell.domain_row)]
	var era: Dictionary = _eras[int(cell.era_index)]
	var lines := PackedStringArray([
		"%s · %s" % [String(domain.get("display_name", "")), String(era.get("display_name", ""))],
		"已掌握 %d · 研究中 %d · 可研究 %d" % [int(counts.owned), int(counts.active),
			int(counts.available)],
		"点击在科技树中查看「%s」" % String((_definitions[int(cell.technology)] as Dictionary).get(
			"display_name", "")),
	])
	return "\n".join(lines)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_rebuild_cells()
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		if _hovered >= 0:
			_hovered = -1
			queue_redraw()


func _draw() -> void:
	if _definitions.is_empty():
		return
	var label_width := _label_width()
	var row_height := _row_height()
	var cell_width := _cell_width()
	var grid_bottom := HEADER_HEIGHT + row_height * float(_domains.size())
	for era_column in range(_visible_eras.size()):
		var era_index := _visible_eras[era_column]
		var x := label_width + era_column * cell_width
		_text(Vector2(x + 6.0, 20.0), _fit_text(String((_eras[era_index] as Dictionary).get(
			"display_name", "")), 13, cell_width - 12.0, "sans_strong"), 13,
			UITokens.DOSSIER_INK_SOFT, "sans_strong")
		if era_column > 0:
			draw_line(Vector2(x - CELL_GAP * 0.5, HEADER_HEIGHT - 6.0),
				Vector2(x - CELL_GAP * 0.5, grid_bottom), UITokens.DOSSIER_RULE, 1.0)
	draw_line(Vector2(0.0, HEADER_HEIGHT - 4.0), Vector2(size.x, HEADER_HEIGHT - 4.0),
		UITokens.DOSSIER_RULE_STRONG, 1.0)
	for row in range(_domains.size()):
		var domain: Dictionary = _domains[row]
		var accent: Color = domain.get("accent", UITokens.DOSSIER_INK_SOFT)
		var y := HEADER_HEIGHT + float(row) * row_height
		var icon_rect := Rect2(Vector2(6.0, y + row_height * 0.5 - 17.0), Vector2(16.0, 16.0))
		_icon(IconCatalog.technology_domain_semantic(String(domain.get("id", ""))), icon_rect,
			accent.lerp(UITokens.DOSSIER_INK, 0.35))
		_text(Vector2(28.0, y + row_height * 0.5 - 4.0), _fit_text(String(domain.get(
			"display_name", domain.get("id", ""))), 15, label_width - 36.0, "sans_strong"), 15,
			accent.lerp(UITokens.DOSSIER_INK, 0.6), "sans_strong")
		if row < _row_totals.size():
			var totals: Dictionary = _row_totals[row]
			_text(Vector2(28.0, y + row_height * 0.5 + 14.0), _fit_text("已掌握 %d / %d" % [
				int(totals.owned), int(totals.total)], 11, label_width - 36.0), 11,
				UITokens.DOSSIER_INK_MUTED)
		draw_line(Vector2(0.0, y + row_height - CELL_GAP * 0.5),
			Vector2(size.x, y + row_height - CELL_GAP * 0.5), UITokens.DOSSIER_RULE, 1.0)
	for index in range(_cells.size()):
		_draw_cell(index)


func _draw_cell(index: int) -> void:
	var cell: Dictionary = _cells[index]
	var rect: Rect2 = cell.rect
	var counts: Dictionary = cell.counts
	var hover := index == _hovered
	var domain: Dictionary = _domains[int(cell.domain_row)]
	var accent: Color = domain.get("accent", UITokens.DOSSIER_INK_SOFT)
	if _cell_style == null:
		_cell_style = StyleBoxFlat.new()
		_cell_style.anti_aliasing = true
		_cell_style.set_corner_radius_all(3)
		_cell_style.set_border_width_all(1)
	var total := maxi(1, int(counts.total))
	var mastered := int(counts.owned) == int(counts.total)
	_cell_style.bg_color = UITokens.DOSSIER_HOVER if hover \
		else (Color(UITokens.DOSSIER_PAPER_DEEP, 0.55) if mastered else UITokens.DOSSIER_PAPER)
	_cell_style.border_color = UITokens.DOSSIER_BRASS if hover else UITokens.DOSSIER_RULE
	draw_style_box(_cell_style, rect)
	draw_rect(Rect2(rect.position + Vector2(1.0, 1.0), Vector2(3.0, rect.size.y - 2.0)),
		Color(accent, 0.85 if int(counts.active) > 0 else 0.45))
	var inner_x := rect.position.x + 10.0
	var inner_w := rect.size.x - 18.0
	var compact := rect.size.x < 96.0
	var head := ("%d/%d" if compact else "已掌握 %d / %d") % [int(counts.owned), int(counts.total)]
	_text(Vector2(inner_x, rect.position.y + 18.0), _fit_text(head, 12, inner_w, "sans_strong"),
		12, UITokens.DOSSIER_INK if not mastered else UITokens.DOSSIER_INK_SOFT, "sans_strong")
	if mastered and not compact:
		_icon(&"technology.state.completed", Rect2(Vector2(rect.end.x - 22.0,
			rect.position.y + 6.0), Vector2(14.0, 14.0)), UITokens.DOSSIER_VERDIGRIS)
	var bar := Rect2(Vector2(inner_x, rect.end.y - BAR_HEIGHT - 8.0), Vector2(inner_w, BAR_HEIGHT))
	_rounded_bar(bar, UITokens.DOSSIER_TRACK, 3.0)
	var x := bar.position.x
	for part in [[int(counts.owned), UITokens.DOSSIER_VERDIGRIS],
			[int(counts.active), UITokens.DOSSIER_SLATE],
			[int(counts.available), UITokens.DOSSIER_BRASS]]:
		var width := bar.size.x * float(part[0]) / float(total)
		if width > 0.5:
			draw_rect(Rect2(Vector2(x, bar.position.y), Vector2(width, bar.size.y)), part[1])
		x += width
	if int(counts.active) > 0 and rect.size.y >= 48.0 and not compact:
		_text(Vector2(inner_x, rect.position.y + 33.0), _fit_text("研究中 %d" % int(counts.active),
			11, inner_w), 11, UITokens.DOSSIER_SLATE)
	elif int(counts.available) > 0 and rect.size.y >= 48.0 and not compact:
		_text(Vector2(inner_x, rect.position.y + 33.0), _fit_text("可研究 %d" % int(counts.available),
			11, inner_w), 11, UITokens.DOSSIER_BRASS.lerp(UITokens.DOSSIER_INK, 0.3))
