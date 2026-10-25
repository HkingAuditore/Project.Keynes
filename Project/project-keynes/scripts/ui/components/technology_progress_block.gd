extends DossierChart
class_name TechnologyProgressBlock

## 研究进度块：百分比、进度条、剩余科技值与预计完成时间。
## 每日只改数值并补间，不重建节点。

const HEIGHT := 92.0

var _fraction := 0.0
var _from_fraction := 0.0
var _accent: Color = UITokens.DOSSIER_UMBER
var _remaining := ""
var _schedule := ""
var _state := 0


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_progress(fraction: float, remaining_text: String, accent: Color, state: int) -> void:
	var clamped := clampf(fraction, 0.0, 1.0)
	if is_equal_approx(clamped, _fraction) and remaining_text == _remaining \
			and accent == _accent and state == _state:
		return
	_from_fraction = _shown_fraction()
	_fraction = clamped
	_remaining = remaining_text
	_accent = accent
	_state = state
	_start_animation()


func set_schedule(text: String) -> void:
	if text == _schedule:
		return
	_schedule = text
	queue_redraw()


func schedule_text() -> String:
	return _schedule


func remaining_text() -> String:
	return _remaining


func _shown_fraction() -> float:
	if not _has_grown:
		return _fraction
	return lerpf(_from_fraction, _fraction, _blend)


func _draw() -> void:
	var w := size.x
	var shown := _fraction * _grow if _blend >= 1.0 else lerpf(_from_fraction, _fraction, _blend)
	_text(Vector2(0.0, 22.0), "研究进度", 17, UITokens.DOSSIER_INK_MUTED)
	var percent := "已掌握" if _state >= 5 else ("%d%%" % int(floor(shown * 100.0)))
	_text(Vector2(0.0, 26.0), percent, 28, UITokens.DOSSIER_INK, "numeral",
		HORIZONTAL_ALIGNMENT_RIGHT, w)
	var track := Rect2(0.0, 38.0, w, 8.0)
	_rounded_bar(track, UITokens.DOSSIER_TRACK, 4.0)
	var fill_color := UITokens.DOSSIER_VERDIGRIS if _state >= 4 \
		else _accent.lerp(UITokens.DOSSIER_INK, 0.2)
	var fill := 1.0 if _state >= 4 else shown
	if fill > 0.0:
		_rounded_bar(Rect2(track.position, Vector2(track.size.x * fill, track.size.y)),
			fill_color, 4.0)
	_text(Vector2(0.0, 68.0), _fit_text(_remaining, 15, w), 15, UITokens.DOSSIER_INK_SOFT)
	if not _schedule.is_empty():
		_text(Vector2(0.0, 88.0), _fit_text(_schedule, 15, w), 15,
			UITokens.DOSSIER_OXBLOOD, "sans_strong", HORIZONTAL_ALIGNMENT_RIGHT, w)
