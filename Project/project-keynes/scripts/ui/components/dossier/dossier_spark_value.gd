extends DossierChart
class_name DossierSparkValue

## 人均产值这类「逐日波动、看趋势比看绝对值更重要」的指标：
## 左侧是当日读数与日变化，右侧是最近若干日的走势。
## 不画坐标轴也不画柱——单日的量已经被数字说完了，能补充信息的只有时间方向。

const HEIGHT := 70.0
const SPARK_RATIO := 0.52
const SPARK_MAX_WIDTH := 220.0

var kind := "money"
var caption := ""

var _value := 0.0
var _from_value := 0.0
var _delta := NAN
var _spark := PackedFloat32Array()


func _init() -> void:
	super()
	custom_minimum_size = Vector2(160.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## data: {value, delta, spark, kind, caption}
## caption 用来交代口径——同一个「人均」有累计和当日两种，不写清楚就会被读成矛盾。
func set_value(data: Dictionary) -> void:
	kind = String(data.get("kind", kind))
	caption = String(data.get("caption", ""))
	_from_value = _displayed_value()
	_value = float(data.get("value", 0.0))
	if is_nan(_from_value) or is_nan(_value):
		_from_value = _value
	_delta = float(data.get("delta", NAN))
	_spark = data.get("spark", PackedFloat32Array())
	_start_animation()


func value_text() -> String:
	return EconomyDossierViewModel.format_value(_displayed_value(), kind)


func _displayed_value() -> float:
	if not _has_grown:
		return _value
	return lerpf(_from_value, _value, _blend)


func _draw() -> void:
	var w := size.x
	if w <= 1.0:
		return
	var spark_width := 0.0
	if _spark.size() >= 2:
		spark_width = clampf(w * SPARK_RATIO, 24.0, SPARK_MAX_WIDTH)
	var text_width := maxf(24.0, w - spark_width - (10.0 if spark_width > 0.0 else 0.0))
	var shown := _displayed_value()
	# 货币口径（人均产值这类）读数前配金币图标，其它口径只画数字。
	var reading := EconomyDossierViewModel.format_value(shown, kind)
	if kind == "money":
		_money_text(Vector2(0.0, 22.0), _fit_text(reading, 22,
			text_width - MoneyDisplay.slot_width(22), "numeral"), 22,
			UITokens.DOSSIER_INK, "numeral")
	else:
		_text(Vector2(0.0, 22.0), _fit_text(reading, 22, text_width, "numeral"), 22,
			UITokens.DOSSIER_INK, "numeral")
	if not is_nan(_delta) and absf(_delta) > 1e-6:
		var up := _delta > 0.0
		var color := UITokens.DOSSIER_VERDIGRIS if up else UITokens.DOSSIER_OXBLOOD
		var arrow := PackedVector2Array([
			Vector2(0.0, 39.0 - (1.0 if up else 7.0)),
			Vector2(8.0, 39.0 - (1.0 if up else 7.0)),
			Vector2(4.0, 39.0 - (8.0 if up else 0.0))])
		draw_colored_polygon(arrow, color)
		var delta_text := EconomyDossierViewModel.format_value(absf(_delta), kind)
		if kind == "money":
			_money_text(Vector2(12.0, 42.0), _fit_text(delta_text, 13,
				text_width - 12.0 - MoneyDisplay.slot_width(13)), 13, color)
		else:
			_text(Vector2(12.0, 42.0), _fit_text(delta_text, 13, text_width - 12.0), 13, color)
	if not caption.is_empty():
		_text(Vector2(0.0, size.y - 3.0), _fit_text(caption, 11, w), 11,
			UITokens.DOSSIER_INK_MUTED)
	if spark_width > 0.0:
		_draw_spark(Rect2(Vector2(w - spark_width, 8.0),
			Vector2(spark_width, size.y - 30.0)))


## 迷你趋势线：只画折线，不画填充，避免和正上方的 KPI 条抢注意力。
func _draw_spark(rect: Rect2) -> void:
	var points := PackedVector2Array()
	var low := INF
	var high := -INF
	for value in _spark:
		if is_nan(value):
			continue
		low = minf(low, value)
		high = maxf(high, value)
	if not is_finite(low) or not is_finite(high):
		return
	var span := maxf(high - low, 1e-6)
	var count := _spark.size()
	for index in range(count):
		var value := _spark[index]
		if is_nan(value):
			continue
		points.append(Vector2(rect.position.x + rect.size.x * float(index) / float(maxi(1, count - 1)),
			rect.end.y - rect.size.y * (value - low) / span))
	if points.size() < 2:
		return
	draw_polyline(points, UITokens.DOSSIER_VERDIGRIS, 1.5, true)
	draw_circle(points[points.size() - 1], 2.0, UITokens.DOSSIER_VERDIGRIS)
