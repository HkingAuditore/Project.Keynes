extends Control
class_name EraTransitionFlight

signal landed()
var _source: Control
var _target: Control
var _active := false
var _landed := false
var _tween: Tween
var _travel := 0.0:
	set(value):
		_travel = value
		if _active and not _landed and value >= 0.85:
			_landed = true
			landed.emit()
		queue_redraw()

func cancel() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_active = false
	_landed = false
	queue_redraw()

func play(source: Control, target: Control) -> void:
	cancel()
	_source = source
	_target = target
	_active = true
	_travel = 0.0
	_tween = create_tween()
	_tween.tween_interval(0.3)
	_tween.tween_property(self, "_travel", 1.0, 1.65)
	_tween.tween_callback(func() -> void: _active = false; queue_redraw())

func _point(t: float) -> Vector2:
	var start := _source.get_global_rect().get_center() - global_position
	var finish := _target.get_global_rect().get_center() - global_position
	var bend := (start + finish) * 0.5 + Vector2(0, 70)
	return (1.0 - t) * (1.0 - t) * start + 2.0 * (1.0 - t) * t * bend + t * t * finish

func _draw() -> void:
	if not _active or not is_instance_valid(_source) or not is_instance_valid(_target):
		return
	var gold := UITokens.ERA_BADGE_GOLD
	for i in range(22):
		var t := clampf(_travel / 0.85 - float(i) * 0.012, 0.0, 1.0)
		var opacity := sin(PI * clampf((_travel - i * 0.006) * 1.1, 0.0, 1.0))
		var pos := _point(t) + Vector2(0, sin(t * TAU * 2.0 + float(i)) * 9.0 * sin(PI * t))
		draw_circle(pos, 6.0, Color(gold, opacity * 0.08))
		draw_circle(pos, 2.0 if i % 4 else 3.0, Color(gold, opacity * (1.0 - i * 0.025)))
	if _travel > 0.80:
		var spread := (_travel - 0.80) * 5.0
		var end := _point(1.0)
		for i in range(12):
			var direction := Vector2.from_angle(TAU * i / 12.0)
			draw_line(end + direction * (10 + spread * 13), end + direction * (15 + spread * 25), Color(gold, 1.0 - spread), 2, true)
