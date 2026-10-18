extends Control

## 独立特效画布：文字、纸卡与布局保持缓存；只有这一层以 30Hz 重绘。
## items 只接收视图已经允许呈现的几何与状态，不查询目录或模拟。
const Art := preload("res://scripts/ui/components/technology_tree_art.gd")
const MAX_BURSTS := 12
const MAX_STREAMS := 18

var content_offset := Vector2.ZERO
var view_rect := Rect2()
var _items: Dictionary = {}
var _states := PackedInt32Array()
var _streams: Array[Curve2D] = []
var _bursts: Array[Dictionary] = []
var _selected := -1
var _hovered := -1
var _focus_age := 99.0
var _hover_blend := 0.0
var _clock := 0.0
var _frame_accumulator := 0.0
var _glow: GradientTexture2D
var _reduced := false
var _settings: Node


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.18, 0.5, 1.0])
	gradient.colors = PackedColorArray([Color.WHITE, Color(1, 1, 1, 0.65),
		Color(1, 1, 1, 0.16), Color(1, 1, 1, 0)])
	_glow = GradientTexture2D.new()
	_glow.width = 64
	_glow.height = 64
	_glow.gradient = gradient
	_glow.fill = GradientTexture2D.FILL_RADIAL
	_glow.fill_from = Vector2(0.5, 0.5)
	_glow.fill_to = Vector2(0.5, 0.0)
	_reduced = UIAnimation.reduced_motion()
	_settings = get_node_or_null("/root/GameSettings")
	if _settings != null and _settings.has_signal("settings_changed"):
		_settings.connect("settings_changed", _on_settings_changed)
	visibility_changed.connect(_visibility_changed)
	set_process(false)


func _on_settings_changed(_values: Dictionary) -> void:
	_reduced = UIAnimation.reduced_motion()
	if _reduced:
		_bursts.clear()
		_focus_age = 99.0
	_refresh_processing()
	queue_redraw()


func set_items(items: Array) -> void:
	_items.clear()
	for value in items:
		var item: Dictionary = value
		_items[int(item.index)] = item
	# List cards may move or disappear as research completes; effects follow the
	# current geometry, never the card that later occupies the old slot.
	for cursor in range(_bursts.size() - 1, -1, -1):
		var index := int(_bursts[cursor].index)
		if not _items.has(index):
			_bursts.remove_at(cursor)
		else:
			_bursts[cursor].rect = _items[index].rect
	_refresh_processing()
	queue_redraw()


## First snapshot is hydration, never a completion celebration.
func patch_states(states: PackedInt32Array) -> void:
	if not _states.is_empty() and is_visible_in_tree() and not _reduced:
		for key in _items:
			var index := int(key)
			if index >= states.size() or index >= _states.size():
				continue
			var before := int(_states[index])
			var after := int(states[index])
			if after >= 4 and before >= 2 and before < 4:
				_burst(index, "complete")
			elif after == 3 and before == 2:
				_burst(index, "queued")
			elif after >= 2 and before < 2:
				_burst(index, "discover")
	_states = states.duplicate()
	_refresh_processing()


func set_interaction(selected: int, hovered: int) -> void:
	if selected != _selected:
		_focus_age = 0.0
	if hovered != _hovered:
		_hover_blend = 0.0
	_selected = selected
	_hovered = hovered
	_refresh_processing()
	queue_redraw()


## Curves are baked once per geometry/selection change, never per frame.
func set_routes(edges: Array) -> void:
	_streams.clear()
	for value in edges:
		if _streams.size() >= MAX_STREAMS:
			break
		var points: PackedVector2Array = (value as Dictionary).get("points", PackedVector2Array())
		if points.size() < 2:
			continue
		var curve := Curve2D.new()
		for point in points:
			curve.add_point(point)
		curve.bake_interval = 6.0
		curve.get_baked_length()
		_streams.append(curve)
	_refresh_processing()


func _burst(index: int, kind: String) -> void:
	if not _items.has(index):
		return
	if _bursts.size() >= MAX_BURSTS:
		_bursts.pop_front()
	var item: Dictionary = _items[index]
	_bursts.append({"index": index, "rect": item.rect, "kind": kind,
		"accent": item.accent, "age": 0.0})


func _visibility_changed() -> void:
	# Do not replay events that happened while another chapter was open.
	_bursts.clear()
	_states = PackedInt32Array()
	_focus_age = 99.0
	_hovered = -1
	_refresh_processing()
	queue_redraw()


func _refresh_processing() -> void:
	var active := not _streams.is_empty() or not _bursts.is_empty() \
		or _focus_age < UITokens.TECH_FOCUS_SECONDS or (_hovered >= 0 and _hover_blend < 1.0)
	if not active:
		for key in _items:
			var item: Dictionary = _items[key]
			if bool(item.get("active", false)) and _on_screen(item.rect):
				active = true
				break
	set_process(is_visible_in_tree() and not _reduced and active)


func _process(delta: float) -> void:
	_clock += delta
	_focus_age += delta
	_hover_blend = minf(1.0, _hover_blend + delta / UITokens.ANIM_FAST)
	for cursor in range(_bursts.size() - 1, -1, -1):
		_bursts[cursor].age = float(_bursts[cursor].age) + delta
		if float(_bursts[cursor].age) >= UITokens.TECH_BREAKTHROUGH_SECONDS:
			_bursts.remove_at(cursor)
	_frame_accumulator += delta
	if _frame_accumulator >= 1.0 / UITokens.TECH_EFFECT_FPS:
		_frame_accumulator = fmod(_frame_accumulator, 1.0 / UITokens.TECH_EFFECT_FPS)
		queue_redraw()
	_refresh_processing()
	if not is_processing():
		queue_redraw()


func _on_screen(rect: Rect2) -> bool:
	return view_rect.grow(42.0).intersects(rect)


func _draw() -> void:
	draw_set_transform(content_offset)
	if _items.has(_hovered) and _hovered != _selected:
		var hover: Rect2 = _items[_hovered].rect
		if _on_screen(hover):
			_corners(hover.grow(2.0), UITokens.ARCHIVE_BRASS,
				1.0 if _reduced else _hover_blend, 9.0)
	if _items.has(_selected):
		var rect: Rect2 = _items[_selected].rect
		if _on_screen(rect):
			var t := 1.0 if _reduced else clampf(_focus_age / UITokens.TECH_FOCUS_SECONDS, 0, 1)
			var spread := 7.0 * pow(1.0 - t, 3.0)
			_corners(rect.grow(3.0 + spread), UITokens.TECH_EFFECT_BRASS, 1.0, 13.0)
			if t < 1.0:
				_outline(rect.grow(3.0 + 14.0 * t), UITokens.TECH_EFFECT_BRASS, (1.0 - t) * 0.65)
	if _reduced:
		return
	for cursor in range(_streams.size()):
		var curve := _streams[cursor]
		var phase := fmod(_clock / UITokens.TECH_FLOW_SECONDS + float(cursor) * 0.19, 1.0)
		var previous := curve.sample_baked(phase * curve.get_baked_length())
		for tail in range(12):
			var t := phase - float(tail) * 0.009
			if t < 0.0:
				break
			var point := curve.sample_baked(t * curve.get_baked_length())
			if view_rect.grow(16.0).has_point(point):
				var fade := (1.0 - float(tail) / 12.0) * 0.85
				draw_line(previous, point, Color(UITokens.TECH_EFFECT_BRASS, fade), 2.8, true)
				_spark(point, 5.5 - float(tail) * 0.3, UITokens.TECH_EFFECT_LIGHT, fade * 0.65)
			previous = point
	var active_count := 0
	for key in _items:
		var item: Dictionary = _items[key]
		if not bool(item.get("active", false)) or not _on_screen(item.rect):
			continue
		_draw_research(item, int(key))
		active_count += 1
		if active_count >= MAX_STREAMS:
			break
	for burst in _bursts:
		if _on_screen(burst.rect):
			_draw_burst(burst)
	draw_set_transform(Vector2.ZERO)


func _draw_research(item: Dictionary, index: int) -> void:
	var rect: Rect2 = item.rect
	var accent: Color = item.accent
	var track: Rect2 = item.track
	var fraction := clampf(float(item.get("fraction", 0.0)), 0.0, 1.0)
	var phase := fposmod(_clock / UITokens.TECH_FLOW_SECONDS + float(index) * 0.137, 1.0)
	# Sweep sits below the labels and does not imply unearned progress.
	var sweep := Vector2(lerpf(rect.position.x + 10.0, rect.end.x - 10.0, phase), rect.end.y - 2.0)
	_spark(sweep, 8.0, accent, 0.48 * sin(phase * PI))
	var head := track.position + Vector2(track.size.x * fraction, track.size.y * 0.5)
	if fraction > 0.0:
		_spark(head, 9.0, UITokens.TECH_EFFECT_BRASS, 0.65)
		var radius := 1.0 + (0.5 + 0.5 * sin(_clock * 2.3)) * 0.6
		draw_circle(head, radius, UITokens.TECH_EFFECT_LIGHT)
	# A travelling point on the rim makes zero-progress queued work visible too.
	var rim := rect.grow(-1.0)
	var distance := phase * (rim.size.x + rim.size.y) * 2.0
	var point := rim.position
	if distance < rim.size.x:
		point.x += distance
	elif distance < rim.size.x + rim.size.y:
		point += Vector2(rim.size.x, distance - rim.size.x)
	elif distance < rim.size.x * 2.0 + rim.size.y:
		point += Vector2(rim.size.x * 2.0 + rim.size.y - distance, rim.size.y)
	else:
		point.y += (rim.size.x + rim.size.y) * 2.0 - distance
	_spark(point, 6.0, UITokens.TECH_EFFECT_BRASS, 0.65)


func _draw_burst(burst: Dictionary) -> void:
	var complete := String(burst.kind) == "complete"
	var duration := UITokens.TECH_BREAKTHROUGH_SECONDS if complete else UITokens.TECH_DISCOVERY_SECONDS
	var t := clampf(float(burst.age) / duration, 0.0, 1.0)
	if t >= 1.0:
		return
	var rect: Rect2 = burst.rect
	var alpha := pow(1.0 - t, 1.5)
	var color := UITokens.TECH_EFFECT_BRASS if complete else (burst.accent as Color)
	_outline(rect.grow(2.0 + 18.0 * t), color, alpha * 0.8)
	_corners(rect.grow(4.0 + 5.0 * t), color, alpha, 14.0)
	var origin := Vector2(rect.end.x - 17.0, rect.position.y + 15.0)
	if complete:
		draw_arc(origin, 12.0 + 30.0 * t, 0.0, TAU, 48, Color(color, alpha * 0.6), 1.0, true)
		# Existing generated seal, briefly enlarged as it lands; text stays clear.
		var stamp_t := clampf(t / 0.22, 0.0, 1.0)
		var diameter := lerpf(42.0, 23.0, 1.0 - pow(1.0 - stamp_t, 3.0))
		Art.draw_icon(self, Art.state_seal(5), origin, diameter, Color(1, 1, 1, minf(1.0, t * 18.0) * alpha))
	var count := 14 if complete else 7
	for particle in range(count):
		var angle := float(particle) * 2.39996
		var direction := Vector2(cos(angle), sin(angle))
		var travel := (15.0 + float(particle % 5) * 6.0) * (1.0 - pow(1.0 - t, 2.0))
		var point := origin + direction * travel + Vector2(0.0, t * t * 16.0)
		_spark(point, 3.5, color, alpha * 0.8)
		draw_line(point, point + direction * 2.5, Color(color, alpha), 1.0, true)


func _spark(point: Vector2, radius: float, color: Color, alpha: float) -> void:
	if _glow != null:
		draw_texture_rect(_glow, Rect2(point - Vector2.ONE * radius, Vector2.ONE * radius * 2.0),
			false, Color(color, alpha))


func _outline(rect: Rect2, color: Color, alpha: float) -> void:
	draw_rect(rect, Color(color, alpha), false, 1.0)


func _corners(rect: Rect2, color: Color, alpha: float, length: float) -> void:
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y),
		rect.end, Vector2(rect.position.x, rect.end.y)]
	var signs := [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	for i in range(4):
		var corner: Vector2 = corners[i]
		var direction: Vector2 = signs[i]
		draw_line(corner + Vector2(direction.x * length, 0), corner, Color(color, alpha), 1.5, true)
		draw_line(corner, corner + Vector2(0, direction.y * length), Color(color, alpha), 1.5, true)
