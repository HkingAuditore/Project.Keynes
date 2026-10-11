extends DossierChart
class_name TechnologyObjectiveRow

## 国家发展目标的一行：名称、当前/目标与持续天数、细进度线。

const ROW_HEIGHT := 34.0

var signal_id := ""
var definition: Dictionary = {}
var _title := ""
var _value := ""
var _ratio := 0.0
var _completed := false


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func setup(p_signal_id: String, p_definition: Dictionary, title: String) -> void:
	signal_id = p_signal_id
	definition = p_definition
	_title = title
	tooltip_text = title
	queue_redraw()


func set_progress(value_text: String, ratio: float, completed: bool) -> void:
	var clamped := clampf(ratio, 0.0, 1.0)
	if value_text == _value and is_equal_approx(clamped, _ratio) and completed == _completed:
		return
	_value = value_text
	_ratio = clamped
	_completed = completed
	tooltip_text = "%s\n%s" % [_title, value_text]
	queue_redraw()


func value_text() -> String:
	return _value


func _draw() -> void:
	var w := size.x
	var value_width := _text_width(_value, 11)
	var mark := &"technology.state.completed" if _completed else &"technology.state.locked"
	_icon(mark, Rect2(Vector2(0.0, 5.0), Vector2(12.0, 12.0)),
		UITokens.DOSSIER_VERDIGRIS if _completed else UITokens.DOSSIER_INK_MUTED)
	_text(Vector2(18.0, 16.0), _fit_text(_title, 13, w - value_width - 26.0), 13,
		UITokens.DOSSIER_INK)
	_text(Vector2(w - value_width, 16.0), _value, 11,
		UITokens.DOSSIER_VERDIGRIS if _completed else UITokens.DOSSIER_INK_MUTED)
	var track := Rect2(18.0, 23.0, maxf(8.0, w - 18.0), 4.0)
	_rounded_bar(track, UITokens.DOSSIER_TRACK, 2.0)
	if _ratio > 0.0:
		_rounded_bar(Rect2(track.position, Vector2(track.size.x * _ratio, track.size.y)),
			UITokens.DOSSIER_VERDIGRIS if _completed else UITokens.DOSSIER_BRASS, 2.0)
