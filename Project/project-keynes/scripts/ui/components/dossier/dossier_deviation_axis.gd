extends DossierChart
class_name DossierDeviationAxis

## CPI / PPI 是相对成本锚（=100）的偏离量，不是绝对数量：两根指针落在同一根
## 以 100 为中心的横轴上。指针之间的距离就是消费端与出厂端的价格裂口，
## 单个指数偏离多少、谁高谁低，一眼就能读出来。

const HEIGHT := 72.0
const EDGE_PAD := 8.0
const NEEDLE_RADIUS := 4.0
const NEEDLE_HEIGHT := 7.0

var _rows: Array = []
var _window := 0.10


func _init() -> void:
	super()
	custom_minimum_size = Vector2(180.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## rows: [{label, index (100 = 成本锚), text, valid}]。
## 半轴宽度按当前偏离自动取：常态是 ±10%，真出现 2 倍物价时轴会自己张开，
## 指针不会全部顶在端点上变成一根竖线。
func set_indices(rows: Array) -> void:
	_rows = rows.duplicate()
	var max_deviation := 0.0
	for row in _rows:
		if bool((row as Dictionary).get("valid", false)):
			max_deviation = maxf(max_deviation,
				absf(float(row.index) - 100.0) / 100.0)
	_window = maxf(0.10, max_deviation * 1.25)
	_start_animation()


func row_count() -> int:
	return _rows.size()


func _draw() -> void:
	var w := size.x
	if w <= 1.0 or _rows.is_empty():
		return
	var axis_y := size.y * 0.56
	var center := w * 0.5
	var half := maxf(1.0, center - EDGE_PAD)
	draw_line(Vector2(EDGE_PAD, axis_y), Vector2(w - EDGE_PAD, axis_y),
		UITokens.DOSSIER_RULE, 1.0)
	# 成本锚（100）是这根轴的零点，比两端的量程刻度更长、更深。
	draw_line(Vector2(center, axis_y - 6.0), Vector2(center, axis_y + 6.0),
		UITokens.DOSSIER_INK_MUTED, 1.0)
	for end in [EDGE_PAD + 2.0, w - EDGE_PAD - 2.0]:
		draw_line(Vector2(end, axis_y - 3.0), Vector2(end, axis_y + 3.0),
			UITokens.DOSSIER_RULE, 1.0)
	var positions := PackedFloat32Array()
	for index in range(_rows.size()):
		var row: Dictionary = _rows[index]
		var valid := bool(row.get("valid", false))
		var offset := 0.0
		if valid:
			offset = clampf((float(row.index) - 100.0) / 100.0 / _window, -1.0, 1.0)
		positions.append(center + half * offset if valid else NAN)
	# 两根指针之间的轴段加一道黄铜，量出来的就是价格裂口。
	if positions.size() >= 2 and not is_nan(positions[0]) and not is_nan(positions[1]):
		draw_line(Vector2(minf(positions[0], positions[1]), axis_y + NEEDLE_HEIGHT + 5.0),
			Vector2(maxf(positions[0], positions[1]), axis_y + NEEDLE_HEIGHT + 5.0),
			UITokens.DOSSIER_BRASS, 2.0)
	for index in range(_rows.size()):
		var row: Dictionary = _rows[index]
		var above := index == 0
		var color := UITokens.DOSSIER_OXBLOOD if above else UITokens.DOSSIER_SLATE
		var label := "%s %s" % [String(row.get("label", "")), String(row.get("text", "—"))]
		var label_width := _text_width(label, 12, "sans_strong")
		var label_x := EDGE_PAD
		if not is_nan(positions[index]):
			var needle_x := positions[index]
			var direction := 1.0 if above else -1.0
			draw_circle(Vector2(needle_x, axis_y), NEEDLE_RADIUS, color)
			draw_line(Vector2(needle_x, axis_y),
				Vector2(needle_x, axis_y + direction * NEEDLE_HEIGHT), color, 1.5)
			label_x = clampf(needle_x - label_width * 0.5, EDGE_PAD,
				maxf(EDGE_PAD, w - EDGE_PAD - label_width))
		var baseline := axis_y - 14.0 if above else axis_y + 26.0
		_text(Vector2(label_x, baseline), label, 12,
			color if not is_nan(positions[index]) else UITokens.DOSSIER_INK_MUTED,
			"sans_strong")
