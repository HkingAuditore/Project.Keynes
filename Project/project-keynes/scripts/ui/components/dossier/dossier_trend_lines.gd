extends DossierChart
class_name DossierTrendLines

## 国库收支的日趋势。收入和支出两条线共用一根纵轴，两线之间的带子按
## 当日净额方向着色：收入在上是绿带，支出在上是红带。
##
## 这样读的是「差额怎么变」，而不是两根各自起伏的曲线——
## 折线本身只负责方向，占比由旁边的堆叠条负责。

const HEIGHT := 116.0
const TOP_PAD := 26.0
const BOTTOM_PAD := 14.0
const DOT_RADIUS := 2.5
const BAND_ALPHA := 0.16
const BAND_AREA_EPSILON := 0.001

var _income := PackedFloat32Array()
var _expense := PackedFloat32Array()
var _from_income := PackedFloat32Array()
var _from_expense := PackedFloat32Array()
var _net_text := "0"
var _net_positive := true


func _init() -> void:
	super()
	custom_minimum_size = Vector2(200.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## income / expense 是逐日合计（货币单位），末尾是最近一天；
## net_text 是当日净额，压在折线右端——那里正好是「今天」。
## 净额只留数字，单位由右上角那枚金币图标负责（见 MoneyDisplay）。
func set_series(income: PackedFloat32Array, expense: PackedFloat32Array,
		net_text: String = "0", net_positive: bool = true) -> void:
	_from_income = _blend_arrays(_from_income, _income, _blend)
	_from_expense = _blend_arrays(_from_expense, _expense, _blend)
	_income = income
	_expense = expense
	_net_text = MoneyDisplay.strip_unit(net_text)
	_net_positive = net_positive
	_start_animation()


func day_count() -> int:
	return _income.size()


func _draw() -> void:
	var w := size.x
	if w <= 1.0:
		return
	_draw_net(w)
	var top := TOP_PAD
	var bottom := size.y - BOTTOM_PAD
	if bottom <= top:
		return
	var income := _blend_arrays(_from_income, _income, _blend)
	var expense := _blend_arrays(_from_expense, _expense, _blend)
	var days := maxi(income.size(), expense.size())
	draw_line(Vector2(0.0, bottom), Vector2(w, bottom), UITokens.DOSSIER_RULE, 1.0)
	if days < 1:
		return
	var peak := 0.0
	for index in range(days):
		peak = maxf(peak, _point(income, index))
		peak = maxf(peak, _point(expense, index))
	if peak <= 0.0:
		return
	var unit := (bottom - top) / peak
	var slot := w / float(maxi(1, days - 1)) if days > 1 else w
	var income_points := _points(income, days, slot, bottom, unit)
	var expense_points := _points(expense, days, slot, bottom, unit)
	_draw_band(income, expense, days, slot, bottom, unit)
	if income_points.size() >= 2:
		draw_polyline(income_points, UITokens.DOSSIER_VERDIGRIS, 1.5, true)
	if expense_points.size() >= 2:
		draw_polyline(expense_points, UITokens.DOSSIER_OXBLOOD, 1.5, true)
	if not income_points.is_empty():
		draw_circle(income_points[income_points.size() - 1], DOT_RADIUS,
			UITokens.DOSSIER_VERDIGRIS)
	if not expense_points.is_empty():
		draw_circle(expense_points[expense_points.size() - 1], DOT_RADIUS,
			UITokens.DOSSIER_OXBLOOD)


## 当日净额压在右端：折线的最右一点就是今天，数字放在这里不用再指一次。
## 净额带一枚金币图标当单位，所以宽度按「图标 + 数字」整段量。
func _draw_net(w: float) -> void:
	var label := "净入" if _net_positive else "净出"
	var label_width := _text_width(label, 11, "sans_strong")
	var value_width := _money_width(_net_text, 17, "serif")
	var color := UITokens.DOSSIER_VERDIGRIS if _net_positive else UITokens.DOSSIER_OXBLOOD
	_text(Vector2(w - label_width - 8.0 - value_width, 13.0), label, 11,
		UITokens.DOSSIER_INK_MUTED, "sans_strong")
	_money_text(Vector2(w - value_width, 17.0), _net_text, 17, color, "serif")


## 两线之间按日填充，用当日净额的正负决定这一段的颜色；交叉段拆开绘制，避免自交多边形。
func _draw_band(income: PackedFloat32Array, expense: PackedFloat32Array,		days: int, slot: float, bottom: float, unit: float) -> void:
	for index in range(days - 1):
		var x0 := slot * float(index)
		var x1 := slot * float(index + 1)
		var in0 := _point(income, index)
		var in1 := _point(income, index + 1)
		var out0 := _point(expense, index)
		var out1 := _point(expense, index + 1)
		var income0 := Vector2(x0, bottom - in0 * unit)
		var income1 := Vector2(x1, bottom - in1 * unit)
		var expense0 := Vector2(x0, bottom - out0 * unit)
		var expense1 := Vector2(x1, bottom - out1 * unit)
		if not _finite_point(income0) or not _finite_point(income1) \
				or not _finite_point(expense0) or not _finite_point(expense1):
			continue
		var delta0 := in0 - out0
		var delta1 := in1 - out1
		if is_zero_approx(delta0) and is_zero_approx(delta1):
			continue
		var crosses := (delta0 < 0.0 and delta1 > 0.0) \
			or (delta0 > 0.0 and delta1 < 0.0)
		if crosses and is_finite(delta0) and is_finite(delta1):
			# 收支在这一段内交换上下关系。原四边形会自交，按交点拆成两块三角形。
			var crossing_t := delta0 / (delta0 - delta1)
			var crossing_value := lerpf(in0, in1, crossing_t)
			var crossing := Vector2(lerpf(x0, x1, crossing_t), bottom - crossing_value * unit)
			_draw_band_triangle(PackedVector2Array([income0, expense0, crossing]),
				_band_color(delta0))
			_draw_band_triangle(PackedVector2Array([crossing, income1, expense1]),
				_band_color(delta1))
			continue
		var color := _band_color(delta1)
		_draw_band_triangle(PackedVector2Array([income0, income1, expense1]), color)
		_draw_band_triangle(PackedVector2Array([income0, expense1, expense0]), color)


func _draw_band_triangle(points: PackedVector2Array, color: Color) -> void:
	if points.size() != 3:
		return
	var area := (points[1] - points[0]).cross(points[2] - points[0])
	if not is_finite(area) or absf(area) <= BAND_AREA_EPSILON:
		return
	draw_colored_polygon(points, color)


static func _band_color(delta: float) -> Color:
	return Color(UITokens.DOSSIER_VERDIGRIS, BAND_ALPHA) if delta >= 0.0 \
		else Color(UITokens.DOSSIER_OXBLOOD, BAND_ALPHA)


static func _finite_point(point: Vector2) -> bool:
	return is_finite(point.x) and is_finite(point.y)


static func _points(series: PackedFloat32Array, days: int, slot: float, bottom: float,
		unit: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(days):
		points.append(Vector2(slot * float(index), bottom - _point(series, index) * unit))
	return points


## 这一天没有读数（财政快照未发布）时按 0 画，不参与峰值统计。
static func _point(series: PackedFloat32Array, index: int) -> float:
	if index < 0 or index >= series.size():
		return 0.0
	var value := series[index]
	return 0.0 if not is_finite(value) else value
