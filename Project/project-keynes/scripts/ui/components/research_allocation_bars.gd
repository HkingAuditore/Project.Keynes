extends DossierChart
class_name ResearchAllocationBars

## 研究投入分配：四个领域各一条横向份额条。
## 拖动以按下点为基准做相对调整，其余领域按原比例让出或吸收份额；
## 预览只改显示，松手才提交一次。空队列领域的份额由运行时并入其他领域，
## 这里只把它标出来，不替运行时重算。

signal weights_previewed(weights_bp: PackedInt32Array)
signal weights_committed(weights_bp: PackedInt32Array)

const DOMAIN_COUNT := 4
const TOTAL_BP := 10000
const ROW_HEIGHT := 36.0
const FOOTER_HEIGHT := 24.0
const NAME_WIDTH := 92.0
const VALUE_WIDTH := 44.0
const BAR_HEIGHT := 10.0
const DRAG_THRESHOLD := 2.0

var _domains: Array = []
var _shares := PackedFloat32Array([0.25, 0.25, 0.25, 0.25])
var _queue_counts := PackedInt32Array([0, 0, 0, 0])
var _queue_capacity := 8
var _dragging := -1
var _drag_origin_x := 0.0
var _drag_start := PackedFloat32Array()
var _drag_moved := false
var _hover := -1
var _reset_hover := false


func _init() -> void:
	super()
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT * DOMAIN_COUNT + FOOTER_HEIGHT)


func configure(domains: Array) -> void:
	_domains = domains
	queue_redraw()


func set_queue_counts(counts: PackedInt32Array, capacity: int = 8) -> void:
	if counts == _queue_counts and capacity == _queue_capacity:
		return
	_queue_counts = counts
	_queue_capacity = capacity
	queue_redraw()


func set_weights(weights_bp: PackedInt32Array) -> void:
	if _dragging >= 0:
		return
	var next := _normalized(weights_bp)
	if next == _shares:
		return
	_shares = next
	queue_redraw()


func weights_bp() -> PackedInt32Array:
	return _to_basis_points(_shares)


func row_rect(domain: int) -> Rect2:
	return Rect2(0.0, ROW_HEIGHT * domain, size.x, ROW_HEIGHT)


func bar_rect(domain: int) -> Rect2:
	var row := row_rect(domain)
	var left := NAME_WIDTH
	var width := maxf(24.0, size.x - NAME_WIDTH - VALUE_WIDTH - 6.0)
	return Rect2(left, row.position.y + (ROW_HEIGHT - BAR_HEIGHT) * 0.5, width, BAR_HEIGHT)


func reset_rect() -> Rect2:
	var label_width := _text_width("均衡分配", 12, "sans_strong") + 22.0
	return Rect2(size.x - label_width, ROW_HEIGHT * DOMAIN_COUNT + 2.0, label_width,
		FOOTER_HEIGHT - 4.0)


static func _normalized(weights_bp: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	var total := 0
	for domain in range(mini(DOMAIN_COUNT, weights_bp.size())):
		total += maxi(0, weights_bp[domain])
	if total <= 0:
		return PackedFloat32Array([0.25, 0.25, 0.25, 0.25])
	for domain in range(mini(DOMAIN_COUNT, weights_bp.size())):
		out[domain] = float(maxi(0, weights_bp[domain])) / float(total)
	return out


# Largest-remainder rounding keeps the committed vector summing to exactly 10000.
static func _to_basis_points(shares: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array([0, 0, 0, 0])
	var remainders: Array = []
	var assigned := 0
	for domain in range(DOMAIN_COUNT):
		var exact := float(shares[domain]) * float(TOTAL_BP) if domain < shares.size() else 0.0
		var floor_value := int(floor(exact))
		out[domain] = floor_value
		assigned += floor_value
		remainders.append([exact - float(floor_value), domain])
	remainders.sort_custom(func(a: Array, b: Array) -> bool:
		return a[0] > b[0] if not is_equal_approx(a[0], b[0]) else a[1] < b[1])
	var cursor := 0
	while assigned < TOTAL_BP and cursor < remainders.size():
		out[int(remainders[cursor][1])] += 1
		assigned += 1
		cursor += 1
	return out


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if reset_rect().has_point(button.position):
				_reset()
				accept_event()
				return
			var row := _row_at(button.position)
			if row < 0:
				return
			_dragging = row
			_drag_origin_x = button.position.x
			_drag_start = _shares.duplicate()
			_drag_moved = false
			accept_event()
			queue_redraw()
			return
		if _dragging >= 0:
			var moved := _drag_moved
			_dragging = -1
			_drag_moved = false
			queue_redraw()
			accept_event()
			if moved:
				weights_committed.emit(weights_bp())
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _dragging >= 0:
			var dx := motion.position.x - _drag_origin_x
			if not _drag_moved and absf(dx) < DRAG_THRESHOLD:
				return
			_drag_moved = true
			_apply_drag(dx)
			accept_event()
			return
		var hover := _row_at(motion.position)
		var reset_hover := reset_rect().has_point(motion.position)
		if hover != _hover or reset_hover != _reset_hover:
			_hover = hover
			_reset_hover = reset_hover
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if reset_hover \
				else (Control.CURSOR_HSIZE if hover >= 0 else Control.CURSOR_ARROW)
			queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and (_hover >= 0 or _reset_hover):
		_hover = -1
		_reset_hover = false
		queue_redraw()


func _row_at(point: Vector2) -> int:
	if point.y < 0.0 or point.y >= ROW_HEIGHT * DOMAIN_COUNT:
		return -1
	return clampi(int(point.y / ROW_HEIGHT), 0, DOMAIN_COUNT - 1)


func _apply_drag(dx: float) -> void:
	var track := bar_rect(_dragging).size.x
	var target := clampf(float(_drag_start[_dragging]) + dx / maxf(1.0, track), 0.0, 1.0)
	var others_before := 1.0 - float(_drag_start[_dragging])
	var remaining := 1.0 - target
	var next := PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	for domain in range(DOMAIN_COUNT):
		if domain == _dragging:
			next[domain] = target
		elif others_before > 1e-5:
			next[domain] = float(_drag_start[domain]) / others_before * remaining
		else:
			next[domain] = remaining / float(DOMAIN_COUNT - 1)
	_shares = next
	queue_redraw()
	weights_previewed.emit(weights_bp())


func _reset() -> void:
	var balanced := PackedFloat32Array([0.25, 0.25, 0.25, 0.25])
	if _to_basis_points(_shares) == _to_basis_points(balanced):
		return
	_shares = balanced
	queue_redraw()
	weights_previewed.emit(weights_bp())
	weights_committed.emit(weights_bp())


func _domain_name(domain: int) -> String:
	if domain < _domains.size():
		return String((_domains[domain] as Dictionary).get("display_name", ""))
	return ""


func _domain_accent(domain: int) -> Color:
	if domain < _domains.size():
		return (_domains[domain] as Dictionary).get("accent", UITokens.DOSSIER_UMBER)
	return UITokens.DOSSIER_UMBER


func _domain_icon(domain: int) -> StringName:
	if domain < _domains.size():
		return IconCatalog.technology_domain_semantic(
			String((_domains[domain] as Dictionary).get("id", "")))
	return &""


func _draw() -> void:
	for domain in range(DOMAIN_COUNT):
		var row := row_rect(domain)
		var accent := _domain_accent(domain)
		var ink := accent.lerp(UITokens.DOSSIER_INK, 0.55)
		var queued := int(_queue_counts[domain]) if domain < _queue_counts.size() else 0
		var empty := queued <= 0
		if domain == _dragging:
			draw_rect(row, UITokens.DOSSIER_SELECTED)
		elif domain == _hover:
			draw_rect(row, UITokens.DOSSIER_HOVER)
		if domain > 0:
			draw_line(Vector2(0.0, row.position.y + 0.5), Vector2(size.x, row.position.y + 0.5),
				UITokens.DOSSIER_RULE, 1.0)
		_icon(_domain_icon(domain), Rect2(Vector2(2.0, row.position.y + 5.0),
			Vector2(14.0, 14.0)), ink)
		_text(Vector2(21.0, row.position.y + 17.0),
			_fit_text(_domain_name(domain), 13, NAME_WIDTH - 24.0, "sans_strong"),
			13, UITokens.DOSSIER_INK, "sans_strong")
		var queue_text := "空队列" if empty else "队列 %d/%d" % [queued, _queue_capacity]
		_text(Vector2(21.0, row.position.y + 31.0), queue_text, 11,
			UITokens.DOSSIER_OXBLOOD if empty else UITokens.DOSSIER_INK_MUTED)
		var bar := bar_rect(domain)
		_rounded_bar(bar, UITokens.DOSSIER_TRACK, BAR_HEIGHT * 0.5)
		var share := float(_shares[domain])
		var fill_color := accent.lerp(UITokens.DOSSIER_INK, 0.18)
		if empty:
			fill_color = Color(fill_color, 0.38)
		var fill := Rect2(bar.position, Vector2(bar.size.x * share, bar.size.y))
		_rounded_bar(fill, fill_color, BAR_HEIGHT * 0.5)
		var knob := Vector2(bar.position.x + bar.size.x * share, bar.get_center().y)
		var knob_radius := 6.5 if domain == _dragging or domain == _hover else 5.5
		draw_circle(knob, knob_radius + 1.0, Color(UITokens.DOSSIER_INK, 0.35))
		draw_circle(knob, knob_radius, UITokens.DOSSIER_PAPER)
		draw_circle(knob, knob_radius - 2.5, fill_color)
		var value_text := "%d%%" % int(round(share * 100.0))
		_text(Vector2(size.x - VALUE_WIDTH, row.position.y + 23.0), value_text, 15,
			UITokens.DOSSIER_INK if not empty else UITokens.DOSSIER_INK_MUTED, "serif",
			HORIZONTAL_ALIGNMENT_RIGHT, VALUE_WIDTH)
	var footer_y := ROW_HEIGHT * DOMAIN_COUNT
	draw_line(Vector2(0.0, footer_y + 0.5), Vector2(size.x, footer_y + 0.5),
		UITokens.DOSSIER_RULE, 1.0)
	var reset := reset_rect()
	var hint := "空队列的份额并入其他领域" if _has_empty_weighted_domain() \
		else "拖动横条调整投入比例"
	_text(Vector2(2.0, footer_y + 16.0), _fit_text(hint, 11, reset.position.x - 8.0), 11,
		UITokens.DOSSIER_INK_MUTED)
	if _reset_hover:
		draw_rect(reset, UITokens.DOSSIER_HOVER)
	_icon(&"action.reset", Rect2(Vector2(reset.position.x + 3.0, reset.position.y + 3.0),
		Vector2(13.0, 13.0)), UITokens.DOSSIER_OXBLOOD)
	_text(Vector2(reset.position.x + 19.0, footer_y + 16.0), "均衡分配", 12,
		UITokens.DOSSIER_OXBLOOD, "sans_strong")


func _has_empty_weighted_domain() -> bool:
	for domain in range(DOMAIN_COUNT):
		var queued := int(_queue_counts[domain]) if domain < _queue_counts.size() else 0
		if queued <= 0 and float(_shares[domain]) > 0.005:
			return true
	return false
