extends DossierChart
class_name DossierKpiCard

## 页头 KPI 单元：纸贴图标 + 标题、Swei 大数字、差值箭头、迷你趋势线。
## 同一 KPI 条里的卡片用竖线分隔，不再各自套框。

const ICON_SIZE := 24.0
const HEIGHT := 86.0
const DENSE_HEIGHT := 54.0
const STACKED_DENSE_MAX_WIDTH := 150.0

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
## "risk" 让数值与说明转为朱砂色，"warn" 转为黄铜色；空串为常规墨色。
var tone := ""
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
	tone = String(data.get("tone", ""))
	tooltip_text = String(data.get("tooltip",
		("%s：%s\n%s" % [title, value_text(), caption]).strip_edges()))
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
	var has_footer := not caption.is_empty() or (not is_nan(_delta) and absf(_delta) > 1e-6)
	var dy := 0.0 if has_footer else 7.0
	if icon_key != &"":
		_icon(icon_key, Rect2(Vector2(x, 7.0 + dy), Vector2(ICON_SIZE, ICON_SIZE)),
			UITokens.DOSSIER_INK_SOFT)
		x += ICON_SIZE + 5.0
	if w >= 135.0 or icon_key == &"":
		_text(Vector2(x, 25.0 + dy), _fit_text(title, 15, w - x - 8.0), 15,
			UITokens.DOSSIER_INK_MUTED)
	var shown := lerpf(_from_value, _value, _blend) if _has_grown else _value
	var value_string := text_value if kind == "text" \
		else EconomyDossierViewModel.format_value(shown, kind)
	var compact_card := w < 135.0
	var spark_width := (clampf(w * 0.28, 0.0, 28.0) if compact_card else clampf(w * 0.34, 0.0, 86.0)) \
		if _spark.size() >= 2 else 0.0
	var value_size := 26 if w >= 170.0 else (22 if w >= 135.0 else 20)
	var avail_value_w := w - spark_width - (14.0 if compact_card else 18.0)
	if value_size > 20 and _text_width(value_string, value_size, "numeral") > avail_value_w:
		value_size = 20
	_text(Vector2(10.0, 57.0 + dy), _fit_text(value_string, value_size,
		avail_value_w, "numeral"), value_size, _value_color(), "numeral")
	var delta_line := caption
	var delta_color := UITokens.DOSSIER_INK_MUTED if tone.is_empty() else _value_color()
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
		_text(Vector2(arrow_x + 12.0, h - 8.0), _fit_text("%s · %s" % [delta_text, caption], 15,
			w - spark_width - 34.0), 15, delta_color)
	else:
		_text(Vector2(10.0, h - 8.0), _fit_text(delta_line, 15, w - spark_width - 18.0), 15,
			delta_color)
	if spark_width > 0.0:
		_draw_spark(Rect2(Vector2(w - spark_width - 10.0, 28.0), Vector2(spark_width, h - 40.0)))


func _draw_dense(w: float, h: float) -> void:
	if w < STACKED_DENSE_MAX_WIDTH:
		_draw_dense_stacked(w)
		return
	var mid := h * 0.5
	var x := 10.0
	if icon_key != &"":
		_icon(icon_key, Rect2(Vector2(x, mid - ICON_SIZE * 0.5), Vector2(ICON_SIZE, ICON_SIZE)),
			UITokens.DOSSIER_INK_SOFT)
		x += ICON_SIZE + 5.0
	var shown := lerpf(_from_value, _value, _blend) if _has_grown else _value
	var value_string := text_value if kind == "text" \
		else EconomyDossierViewModel.format_value(shown, kind)
	var value_width := minf(_text_width(value_string, 22, "numeral"), (w - x) * 0.62)
	_text(Vector2(x, mid + 6.0), _fit_text(title, 15, w - x - value_width - 18.0), 15,
		UITokens.DOSSIER_INK_MUTED)
	_text(Vector2(w - 10.0 - value_width, mid + 8.0), _fit_text(value_string, 22, value_width,
		"numeral"), 22, _value_color(), "numeral")


## 窄卡（地块档案四格并排约 100px）单行放不下“标题……数值”，改成上标题、下数值。
func _draw_dense_stacked(w: float) -> void:
	var x := 8.0
	if icon_key != &"":
		_icon(icon_key, Rect2(Vector2(x, 3.0), Vector2(24.0, 24.0)), UITokens.DOSSIER_INK_SOFT)
	else:
		_text(Vector2(x, 20.0), _fit_text(title, 15, w - x - 6.0), 15, UITokens.DOSSIER_INK_MUTED)
	var shown := lerpf(_from_value, _value, _blend) if _has_grown else _value
	var value_string := text_value if kind == "text" \
		else EconomyDossierViewModel.format_value(shown, kind)
	_text(Vector2(8.0, 48.0), _fit_text(value_string, 20, w - 14.0, "numeral"), 20,
		_value_color(), "numeral")


func _value_color() -> Color:
	match tone:
		"risk":
			return UITokens.DOSSIER_OXBLOOD
		"warn":
			return UITokens.DOSSIER_BRASS
	return UITokens.DOSSIER_INK


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
