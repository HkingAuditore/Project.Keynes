extends Control
class_name ResearchWeightDial

# Four research domains on a diamond. Dragging an axis renormalises the other
# three, so the weights always sum to 100% and no submit button is needed:
# releasing is the commit.
#
# The grab target is the whole axis arm, not the handle dot: at balanced weights
# the four handles sit close together near the centre, and hunting for the right
# one is a coin flip. Dragging is also relative to where the press landed, so a
# stray click can never jolt a weight, and a press that never moves commits
# nothing at all.

signal weights_previewed(weights_bp: PackedInt32Array)
signal weights_committed(weights_bp: PackedInt32Array)

const TOTAL_BP := 10000
const AXIS_DIRECTIONS := [
	Vector2(0.0, -1.0), Vector2(1.0, 0.0), Vector2(0.0, 1.0), Vector2(-1.0, 0.0),
]
const RING_STEPS := [0.25, 0.5, 0.75, 1.0]
# Distance encodes the square root of the share, the usual convention for radial
# encodings: a linear radius would park all four handles on top of each other at
# the 25% baseline, which is exactly where the dial spends most of its life.
# The balance ring sits at half the radius instead, and the drawn area still
# grows in step with the share.
const DISPLAY_GAMMA := 0.5
const BALANCE_STEP := 0.25
const MARGIN_X := 30.0
const MARGIN_Y := 30.0
const HANDLE_RADIUS := 7.0
const CENTRE_RADIUS := 18.0
const AXIS_BAND := 26.0
const AXIS_OVERSHOOT := 24.0
const ICON_GAP := 13.0
const ICON_FONT_SIZE := 15
const VALUE_FONT_SIZE := 11

var _domain_names: Array[String] = ["农业", "工程", "科学", "社会"]
var _domain_ids: Array[String] = ["agriculture", "engineering", "science", "society"]
var _accents: Array[Color] = []
var _weights: Array[float] = [0.25, 0.25, 0.25, 0.25]
var _dragging := -1
var _hovered := -1
var _drag_origin_projection := 0.0
var _drag_origin_display := 0.0
var _drag_snapshot := PackedInt32Array()
var _label_font: Font = UITokens.font_with_weight(620)


func _ready() -> void:
	custom_minimum_size = Vector2(190.0, 226.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = "沿任一方向拖动即可调整该领域权重，其余三项按原比例让位；\n松手生效，双击中心恢复均衡。刻度圈自内向外为 25%/50%/75%/100%"
	if _accents.is_empty():
		_accents.assign([
			Color(0.39, 0.62, 0.31), Color(0.72, 0.48, 0.24),
			Color(0.28, 0.58, 0.74), Color(0.67, 0.48, 0.68),
		])


func configure(domains: Array) -> void:
	if domains.size() != AXIS_DIRECTIONS.size():
		return
	_domain_names.clear()
	_domain_ids.clear()
	_accents.clear()
	for domain in domains:
		var data: Dictionary = domain
		_domain_names.append(String(data.get("display_name", "")))
		_domain_ids.append(String(data.get("id", "")))
		_accents.append(data.get("accent", UITokens.ACCENT))
	queue_redraw()


func set_weights(weights_bp: PackedInt32Array) -> void:
	if _dragging >= 0 or weights_bp.size() < AXIS_DIRECTIONS.size():
		return
	var total := 0
	for value in weights_bp:
		total += int(value)
	if total <= 0:
		return
	for i in range(AXIS_DIRECTIONS.size()):
		_weights[i] = float(weights_bp[i]) / float(total)
	queue_redraw()


func weights_bp() -> PackedInt32Array:
	return _to_basis_points(_weights)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if button.double_click and (button.position - _centre()).length() <= CENTRE_RADIUS:
				_weights.fill(1.0 / float(AXIS_DIRECTIONS.size()))
				queue_redraw()
				weights_previewed.emit(weights_bp())
				weights_committed.emit(weights_bp())
				accept_event()
				return
			_begin_drag(_axis_at(button.position), button.position)
			if _dragging >= 0:
				accept_event()
			return
		if _dragging >= 0:
			var moved := weights_bp() != _drag_snapshot
			_dragging = -1
			if moved:
				weights_committed.emit(weights_bp())
			queue_redraw()
			accept_event()
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging >= 0:
			_apply_drag(_dragging, motion.position)
			accept_event()
			return
		var hit := _axis_at(motion.position)
		if hit != _hovered:
			_hovered = hit
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if hit >= 0 \
				else Control.CURSOR_ARROW
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hovered != -1:
		_hovered = -1
		queue_redraw()


func _begin_drag(domain: int, position: Vector2) -> void:
	_dragging = domain
	if domain < 0:
		return
	_drag_origin_projection = _projection(domain, position)
	_drag_origin_display = _display_of(_weights[domain])
	_drag_snapshot = weights_bp()
	_hovered = domain
	queue_redraw()


# Dragging works in drawn space, so the handle tracks the pointer pixel for pixel
# and the warp stays invisible to the hand.
func _apply_drag(domain: int, position: Vector2) -> void:
	var target := _weight_of(_drag_origin_display
		+ _projection(domain, position) - _drag_origin_projection)
	if is_equal_approx(target, _weights[domain]):
		return
	var others := 0.0
	for i in range(_weights.size()):
		if i != domain:
			others += _weights[i]
	var remaining := 1.0 - target
	for i in range(_weights.size()):
		if i == domain:
			_weights[i] = target
		elif others > 0.0001:
			_weights[i] = _weights[i] * remaining / others
		else:
			_weights[i] = remaining / float(_weights.size() - 1)
	queue_redraw()
	weights_previewed.emit(weights_bp())


func _projection(domain: int, position: Vector2) -> float:
	return (position - _centre()).dot(AXIS_DIRECTIONS[domain]) / maxf(1.0, _radius())


func _display_of(weight: float) -> float:
	return pow(clampf(weight, 0.0, 1.0), DISPLAY_GAMMA)


func _weight_of(display: float) -> float:
	return pow(clampf(display, 0.0, 1.0), 1.0 / DISPLAY_GAMMA)


# An axis owns the band running along its arm. The centre disc belongs to nobody
# so the four arms never fight over it, and the diagonal gaps stay inert.
func _axis_at(position: Vector2) -> int:
	var offset := position - _centre()
	var distance := offset.length()
	if distance <= CENTRE_RADIUS or distance > _radius() + AXIS_OVERSHOOT:
		return -1
	var best := -1
	var best_lateral := AXIS_BAND
	for i in range(AXIS_DIRECTIONS.size()):
		var direction: Vector2 = AXIS_DIRECTIONS[i]
		if offset.dot(direction) <= 0.0:
			continue
		var lateral: float = absf(offset.dot(Vector2(direction.y, -direction.x)))
		if lateral <= best_lateral:
			best_lateral = lateral
			best = i
	return best


func _centre() -> Vector2:
	return Vector2(size.x * 0.5, size.y * 0.5)


func _radius() -> float:
	return maxf(12.0, minf(size.x * 0.5 - MARGIN_X, size.y * 0.5 - MARGIN_Y))


func _handle_position(domain: int) -> Vector2:
	return _centre() + AXIS_DIRECTIONS[domain] * _radius() \
		* _display_of(_weights[domain])


func _draw() -> void:
	var centre := _centre()
	var radius := _radius()
	for step in RING_STEPS:
		var ring := PackedVector2Array()
		var extent := radius * _display_of(float(step))
		for i in range(AXIS_DIRECTIONS.size()):
			ring.append(centre + AXIS_DIRECTIONS[i] * extent)
		ring.append(ring[0])
		var strong := is_equal_approx(float(step), 1.0)
		var balance := is_equal_approx(float(step), BALANCE_STEP)
		var tint := Color(UITokens.PANEL_BORDER.r, UITokens.PANEL_BORDER.g,
			UITokens.PANEL_BORDER.b, 0.62 if strong else 0.24)
		if balance:
			tint = Color(UITokens.BRASS_HIGHLIGHT.r, UITokens.BRASS_HIGHLIGHT.g,
				UITokens.BRASS_HIGHLIGHT.b, 0.34)
		draw_polyline(ring, tint, 1.4 if strong or balance else 1.0, true)
	for i in range(AXIS_DIRECTIONS.size()):
		var live := i == _dragging or i == _hovered
		var arm: Color = _accent(i).lerp(UITokens.TEXT_MAIN, 0.30) if live \
			else Color(UITokens.PANEL_BORDER_SOFT.r, UITokens.PANEL_BORDER_SOFT.g,
				UITokens.PANEL_BORDER_SOFT.b, 0.66)
		draw_line(centre, centre + AXIS_DIRECTIONS[i] * radius, arm,
			2.4 if live else 1.0, true)
	var polygon := PackedVector2Array()
	for i in range(AXIS_DIRECTIONS.size()):
		polygon.append(_handle_position(i))
	draw_colored_polygon(polygon, Color(UITokens.ACCENT.r, UITokens.ACCENT.g,
		UITokens.ACCENT.b, 0.20))
	var outline := polygon.duplicate()
	outline.append(polygon[0])
	draw_polyline(outline, Color(UITokens.BRASS_HIGHLIGHT.r, UITokens.BRASS_HIGHLIGHT.g,
		UITokens.BRASS_HIGHLIGHT.b, 0.80), 1.8, true)
	for i in range(AXIS_DIRECTIONS.size()):
		_draw_axis_icon(i, centre, radius)
		_draw_handle(i)
	draw_circle(centre, CENTRE_RADIUS, Color(UITokens.WALNUT_SOFT.r,
		UITokens.WALNUT_SOFT.g, UITokens.WALNUT_SOFT.b, 0.30))
	draw_arc(centre, CENTRE_RADIUS, 0.0, TAU, 28,
		Color(UITokens.PANEL_BORDER.r, UITokens.PANEL_BORDER.g,
			UITokens.PANEL_BORDER.b, 0.55), 1.0, true)
	draw_circle(centre, 2.8, Color(UITokens.TEXT_FAINT.r, UITokens.TEXT_FAINT.g,
		UITokens.TEXT_FAINT.b, 0.80))
	var active := _dragging if _dragging >= 0 else _hovered
	if active >= 0:
		_draw_active_chip(active)


func _draw_handle(domain: int) -> void:
	var accent := _accent(domain)
	var position := _handle_position(domain)
	var active := domain == _dragging or domain == _hovered
	var handle_radius := HANDLE_RADIUS + (2.0 if active else 0.0)
	draw_circle(position + Vector2(0.0, 1.0), handle_radius + 1.2, Color(0.0, 0.0, 0.0, 0.42))
	draw_circle(position, handle_radius, accent.lerp(UITokens.TEXT_MAIN, 0.42 if active else 0.16))
	draw_arc(position, handle_radius - 1.0, 0.0, TAU, 16,
		Color(1.0, 0.93, 0.72, 0.55 if active else 0.28), 1.0, true)


func _accent(domain: int) -> Color:
	return _accents[domain] if domain < _accents.size() else UITokens.ACCENT


# Only the domain icon sits at the tip. Names and standing shares are printed by
# the research queue directly below, and spelling them out here both duplicated
# that list and stole the width the ring needs to stay grabbable.
func _draw_axis_icon(domain: int, centre: Vector2, radius: float) -> void:
	var direction: Vector2 = AXIS_DIRECTIONS[domain]
	var glyph := IconCatalog.glyph_for_key(
		IconCatalog.technology_domain_semantic(_domain_ids[domain]))
	var extent := IconCatalog.FONT_AWESOME.get_string_size(
		glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0, ICON_FONT_SIZE)
	var anchor := centre + direction * (radius + ICON_GAP)
	var origin := anchor - Vector2(extent.x * 0.5, 0.0)
	if direction.y < 0.0:
		origin.y -= 1.0
	elif direction.y > 0.0:
		origin.y += extent.y * 0.72
	else:
		origin.y += extent.y * 0.34
	var active := domain == _dragging or domain == _hovered
	draw_string(IconCatalog.FONT_AWESOME, origin, glyph, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, ICON_FONT_SIZE,
		_accent(domain).lerp(UITokens.TEXT_MAIN, 0.55 if active else 0.20))


# The share is spelled out only for the arm under the cursor, right where the
# player is dragging, so the reading never turns into four overlapping numbers.
func _draw_active_chip(domain: int) -> void:
	var accent := _accent(domain)
	var name_text := _domain_names[domain] if domain < _domain_names.size() else ""
	var text := "%s %d%%" % [name_text, int(round(_weights[domain] * 100.0))]
	var extent := _label_font.get_string_size(
		text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, VALUE_FONT_SIZE)
	var handle := _handle_position(domain)
	var origin := Vector2.ZERO
	if absf((AXIS_DIRECTIONS[domain] as Vector2).y) > 0.5:
		origin = handle + Vector2(HANDLE_RADIUS + 9.0, extent.y * 0.34)
	else:
		origin = handle + Vector2(-extent.x * 0.5, -HANDLE_RADIUS - 9.0)
	origin.x = clampf(origin.x, 6.0, maxf(6.0, size.x - extent.x - 6.0))
	origin.y = clampf(origin.y, extent.y, maxf(extent.y, size.y - 4.0))
	var box := Rect2(origin - Vector2(5.0, extent.y - 2.0),
		extent + Vector2(10.0, 4.0))
	draw_rect(box, Color(0.048, 0.041, 0.033, 0.92))
	draw_rect(box, Color(accent.r, accent.g, accent.b, 0.58), false, 1.0)
	draw_string(_label_font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		VALUE_FONT_SIZE, accent.lerp(UITokens.TEXT_MAIN, 0.78))


# Largest-remainder rounding keeps the committed basis points at exactly 10000,
# which NativeCountryRuntime validates atomically.
func _to_basis_points(weights: Array[float]) -> PackedInt32Array:
	var out := PackedInt32Array()
	var ranked: Array = []
	var assigned := 0
	for i in range(weights.size()):
		var scaled: float = clampf(weights[i], 0.0, 1.0) * float(TOTAL_BP)
		var floored := int(floor(scaled))
		out.append(floored)
		assigned += floored
		ranked.append({"index": i, "fraction": scaled - float(floored)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a.fraction), float(b.fraction)):
			return float(a.fraction) > float(b.fraction)
		return int(a.index) < int(b.index)
	)
	var remainder := TOTAL_BP - assigned
	var cursor := 0
	while remainder > 0 and not ranked.is_empty():
		out[int((ranked[cursor % ranked.size()] as Dictionary).index)] += 1
		remainder -= 1
		cursor += 1
	return out
