extends DossierChart
class_name DossierKpiCard

## 页头 KPI 单元：图标 + 标题、衬线大数字、与上一周期的差值箭头、迷你趋势线。
## 同一 KPI 条里的卡片用竖线分隔，不再各自套框。

const ICON_SIZE := 16.0
const HEIGHT := 66.0
const DENSE_HEIGHT := 32.0

var metric_id := ""
var title := ""
var caption := ""
var kind := "count"
var positive_good := true
var icon_key: StringName = &""
var show_divider := true
## 单行模式：只画“图标 标题 …… 数值”，说明与差值移到悬停提示里，用于矮视口。
var dense := false:
	set(value):
		if dense == value:
			return
		dense = value
		custom_minimum_size.y = DENSE_HEIGHT if dense else HEIGHT
		queue_redraw()

var text_value := ""
var _value := 0.0
var _from_value := 0.0
var _delta := NAN
var _spark := PackedFloat32Array()


func _init() -> void:
	super()
	custom_minimum_size = Vector2(150.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_metric(data: Dictionary) -> void:
	metric_id = String(data.get("id", metric_id))
	title = String(data.get("title", ""))
	caption = String(data.get("caption", ""))
	kind = String(data.get("kind", "count"))
	positive_good = bool(data.get("positive_good", true))
	icon_key = StringName(data.get("icon", &""))
	_from_value = _displayed_value()
	_value = float(data.get("value", 0.0))
	if is_nan(_from_value) or is_nan(_value):
		_from_value = _value
	_delta = float(data.get("delta", NAN))
	_spark = data.get("spark", PackedFloat32Array())
	text_value = String(data.get("text", ""))
	tooltip_text = String(data.get("tooltip", "%s：%s\n%s" % [title, value_text(), caption]))
	_start_animation()


func value_text() -> String:
	if kind == "text":
		return text_value
	return EconomyDossierViewModel.format_value(_value, kind)


func _displayed_value() -> float:
	if not _has_grown:
		return _value
	return lerpf(_from_value, _value, _blend)


func _draw() -> void:
	var w := size.x
	var h := size.y
	if show_divider:
		draw_line(Vector2(w - 0.5, 8.0), Vector2(w - 0.5, h - 8.0), UITokens.DOSSIER_RULE, 1.0)
	if dense:
		_draw_dense(w, h)
		return
	var x := 10.0
	if icon_key != &"":
		_icon(icon_key, Rect2(Vector2(x, 7.0), Vector2(ICON_SIZE, ICON_SIZE)),
			UITokens.DOSSIER_INK_SOFT)
		x += ICON_SIZE + 5.0
	_text(Vector2(x, 20.0), _fit_text(title, 12, w - x - 8.0), 12, UITokens.DOSSIER_INK_MUTED)
	var shown := lerpf(_from_value, _value, _blend) if _has_grown else _value
	var value_string := text_value if kind == "text" \
		else EconomyDossierViewModel.format_value(shown, kind)
	var spark_width := clampf(w * 0.34, 0.0, 86.0) if _spark.size() >= 2 else 0.0
	var value_size := 22 if w >= 170.0 else 19
	_text(Vector2(10.0, 46.0), _fit_text(value_string, value_size, w - spark_width - 18.0, "serif"),
		value_size, UITokens.DOSSIER_INK, "serif")
	var delta_line := caption
	var delta_color := UITokens.DOSSIER_INK_MUTED
	if not is_nan(_delta) and absf(_delta) > 1e-6:
		var up := _delta > 0.0
		var good := up == positive_good
		delta_color = UITokens.DOSSIER_VERDIGRIS if good else UITokens.DOSSIER_OXBLOOD
		var arrow_x := 10.0
		var arrow_y := h - 9.0
		var tri := PackedVector2Array([
			Vector2(arrow_x, arrow_y - (1.0 if up else 7.0)),
			Vector2(arrow_x + 8.0, arrow_y - (1.0 if up else 7.0)),
			Vector2(arrow_x + 4.0, arrow_y - (8.0 if up else 0.0))])
		draw_colored_polygon(tri, delta_color)
		var delta_text := EconomyDossierViewModel.format_value(absf(_delta), kind)
		if kind == "percent":
			delta_text = "%.1f 点" % (absf(_delta) * 100.0)
		_text(Vector2(arrow_x + 12.0, h - 8.0), _fit_text("%s · %s" % [delta_text, caption], 11,
			w - spark_width - 34.0), 11, delta_color)
	else:
		_text(Vector2(10.0, h - 8.0), _fit_text(delta_line, 11, w - spark_width - 18.0), 11,
			delta_color)
	if spark_width > 0.0:
		_draw_spark(Rect2(Vector2(w - spark_width - 10.0, 28.0), Vector2(spark_width, h - 40.0)))


func _draw_dense(w: float, h: float) -> void:
	var mid := h * 0.5
	var x := 10.0
	if icon_key != &"":
		_icon(icon_key, Rect2(Vector2(x, mid - ICON_SIZE * 0.5), Vector2(ICON_SIZE, ICON_SIZE)),
			UITokens.DOSSIER_INK_SOFT)
		x += ICON_SIZE + 5.0
	var shown := lerpf(_from_value, _value, _blend) if _has_grown else _value
	var value_string := text_value if kind == "text" \
		else EconomyDossierViewModel.format_value(shown, kind)
	var value_width := minf(_text_width(value_string, 16, "serif"), (w - x) * 0.62)
	_text(Vector2(x, mid + 5.0), _fit_text(title, 12, w - x - value_width - 18.0), 12,
		UITokens.DOSSIER_INK_MUTED)
	_text(Vector2(w - 10.0 - value_width, mid + 6.0), _fit_text(value_string, 16, value_width,
		"serif"), 16, UITokens.DOSSIER_INK, "serif")


func _draw_spark(rect: Rect2) -> void:
	var lo := INF
	var hi := -INF
	for v in _spark:
		if is_nan(v):
			continue
		lo = minf(lo, v)
		hi = maxf(hi, v)
	if lo == INF:
		return
	var span := maxf(hi - lo, absf(hi) * 0.02 + 1e-6)
	var points := PackedVector2Array()
	var count := _spark.size()
	var visible_count := maxi(2, int(ceil(float(count) * _grow)))
	for i in range(mini(count, visible_count)):
		if is_nan(_spark[i]):
			continue
		var x := rect.position.x + rect.size.x * float(i) / float(count - 1)
		var y := rect.end.y - rect.size.y * (_spark[i] - lo) / span
		points.append(Vector2(x, y))
	if points.size() < 2:
		return
	draw_line(Vector2(rect.position.x, rect.end.y + 0.5), Vector2(rect.end.x, rect.end.y + 0.5),
		UITokens.DOSSIER_RULE, 1.0)
	draw_polyline(points, Color(UITokens.DOSSIER_INK_SOFT, 0.85), 1.4, true)
	draw_circle(points[points.size() - 1], 2.4, UITokens.DOSSIER_OXBLOOD)
