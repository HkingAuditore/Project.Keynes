extends DossierChart
class_name InspectorMeterList

## 地块卷宗指标条：一行一条“标签 —— 进度条 —— 读数”，取代旧的深色量表。
## 数据形状沿用视图模型的 gauges（id/label/value/marker/status_label/value_text/accent）。
## 首次出现时条从零生长，之后数值变化只做补间。

const ROW_HEIGHT := 30.0
const LABEL_WIDTH := 66.0
const READOUT_WIDTH := 118.0
const BAR_HEIGHT := 6.0

var _meters: Array = []
var _from: Dictionary = {}


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, ROW_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_meters(meters: Array) -> void:
	_from.clear()
	for raw in _meters:
		var old: Dictionary = raw
		_from[String(old.get("id", ""))] = _shown_value(old)
	_meters = meters.duplicate()
	custom_minimum_size.y = maxf(1.0, float(_meters.size())) * ROW_HEIGHT
	_start_animation()


func meter_count() -> int:
	return _meters.size()


func _shown_value(meter: Dictionary) -> float:
	var target := clampf(float(meter.get("value", 0.0)), 0.0, 1.0)
	var meter_id := String(meter.get("id", ""))
	if not _from.has(meter_id):
		return target
	return lerpf(float(_from[meter_id]), target, _blend)


static func fill_color(accent: Color) -> Color:
	if accent.is_equal_approx(UITokens.RISK):
		return UITokens.DOSSIER_OXBLOOD
	if accent.is_equal_approx(UITokens.GOOD) or accent.is_equal_approx(UITokens.ECO):
		return UITokens.DOSSIER_VERDIGRIS
	if accent.is_equal_approx(UITokens.WARN) or accent.is_equal_approx(UITokens.CLIMATE):
		return UITokens.DOSSIER_BRASS
	if accent.is_equal_approx(UITokens.WATER):
		return UITokens.DOSSIER_SLATE
	return UITokens.DOSSIER_UMBER


func _readout(meter: Dictionary) -> String:
	var value_text := String(meter.get("value_text", ""))
	var status := String(meter.get("status_label", ""))
	if value_text == "":
		value_text = "%d%%" % int(round(clampf(float(meter.get("value", 0.0)), 0.0, 1.0) * 100.0))
	if status == "" or status == value_text:
		return value_text
	return "%s · %s" % [value_text, status]


func _get_tooltip(at_position: Vector2) -> String:
	var row := int(at_position.y / ROW_HEIGHT)
	if row < 0 or row >= _meters.size():
		return ""
	var meter: Dictionary = _meters[row]
	var tip := "%s：%s" % [String(meter.get("label", "")), _readout(meter)]
	var note := String(meter.get("tooltip", ""))
	return tip if note.is_empty() else "%s\n%s" % [tip, note]


func _draw() -> void:
	var w := size.x
	var readout_width := minf(READOUT_WIDTH, w * 0.36)
	var bar_x := LABEL_WIDTH + 8.0
	var bar_w := maxf(24.0, w - bar_x - readout_width - 12.0)
	for i in range(_meters.size()):
		var meter: Dictionary = _meters[i]
		var top := ROW_HEIGHT * float(i)
		var mid := top + ROW_HEIGHT * 0.5
		_text(Vector2(4.0, mid + 4.5), _fit_text(String(meter.get("label", "")), 12, LABEL_WIDTH),
			12, UITokens.DOSSIER_INK_SOFT)
		var track := Rect2(Vector2(bar_x, mid - BAR_HEIGHT * 0.5), Vector2(bar_w, BAR_HEIGHT))
		_rounded_bar(track, UITokens.DOSSIER_TRACK, 3.0)
		var value := _shown_value(meter) * (_grow if _has_grown else 1.0)
		var color := fill_color(meter.get("accent", UITokens.ACCENT))
		_rounded_bar(Rect2(track.position, Vector2(track.size.x * value, track.size.y)), color, 3.0)
		var marker := float(meter.get("marker", -1.0))
		if marker >= 0.0:
			var mx := track.position.x + track.size.x * clampf(marker, 0.0, 1.0)
			draw_line(Vector2(mx, track.position.y - 4.0), Vector2(mx, track.end.y + 4.0),
				UITokens.DOSSIER_INK, 1.5)
		var readout := _fit_text(_readout(meter), 12, readout_width, "sans_strong")
		_text(Vector2(w - readout_width - 2.0, mid + 4.5), readout, 12, UITokens.DOSSIER_INK,
			"sans_strong", HORIZONTAL_ALIGNMENT_RIGHT, readout_width)
