class_name IdeologyPointScroll
extends Control

## Unrolled scroll that fills with ink toward the next draw cost, plus a
## ledger popup showing the last settlement breakdown and a 32-slip history.

signal ledger_requested()

const ArtScript = preload("res://scripts/ui/components/ideology_art.gd")
# Source pixels: keep the wooden ends proportional to the bar height and only
# stretch the paper. The last 13 rows contain a fragment of a neighbouring decal.
const SCROLL_SOURCE_HEIGHT := 118.0
const SCROLL_CAP_WIDTH := 90.0
const PAPER_TOP := 34.0
const PAPER_BOTTOM := 92.0

var _ratio := 0.0
var _shown_ratio := 0.0
var _scroll_tex: Texture2D
var _points_label: Label
var _cost_label: Label
var _gain_label: Label
var _tween: Tween
var _row: HBoxContainer
var _last_points_q16 := -1


func _init() -> void:
	custom_minimum_size = Vector2(420, 64)
	mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll_tex = ArtScript.texture(ArtScript.SCROLL_BAR)
	var row := HBoxContainer.new()
	_row = row
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 46
	row.offset_right = -46
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	_points_label = ArtScript.label("0.00", 20, ArtScript.INK, HORIZONTAL_ALIGNMENT_LEFT)
	_points_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_points_label)
	_cost_label = ArtScript.label("", 12, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_LEFT)
	_cost_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cost_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_cost_label)
	_gain_label = ArtScript.label("", 12, ArtScript.VERMILION, HORIZONTAL_ALIGNMENT_RIGHT)
	_gain_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_gain_label)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _row != null:
		var inset := _cap_width() + 12.0
		_row.offset_left = inset
		_row.offset_right = -inset
		queue_redraw()
		var narrow := size.x < 520.0
		_points_label.add_theme_font_size_override("font_size", 22 if narrow else 26)
		_gain_label.add_theme_font_size_override("font_size", 15 if narrow else 17)
		_cost_label.add_theme_font_size_override("font_size", 15 if narrow else 17)


func set_points(points_q16: int, cost_q16: int, last_gain_q16: int, baseline_ready: bool,
		reduce_motion: bool) -> void:
	_points_label.text = ArtScript.q16(points_q16)
	_cost_label.text = "/ %s" % ArtScript.q16(cost_q16)
	_gain_label.text = "+%s" % ArtScript.q16(last_gain_q16) \
		if baseline_ready and last_gain_q16 > 0 else ""
	# A paid draw or reroll lowers the balance; float the spent amount.
	if _last_points_q16 > points_q16 and not reduce_motion and is_inside_tree():
		_flash_spent(_last_points_q16 - points_q16)
	_last_points_q16 = points_q16
	_ratio = clampf(float(points_q16) / float(maxi(1, cost_q16)), 0.0, 1.0)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if reduce_motion or not is_inside_tree():
		_shown_ratio = _ratio
		queue_redraw()
		return
	_tween = create_tween()
	_tween.tween_method(_set_shown_ratio, _shown_ratio, _ratio, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func fill_ratio() -> float:
	return _ratio


func _flash_spent(spent_q16: int) -> void:
	var label := ArtScript.label("-%s" % ArtScript.q16(spent_q16), 18, ArtScript.VERMILION,
		HORIZONTAL_ALIGNMENT_LEFT)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	label.position = Vector2(_row.offset_left + _points_label.size.x + 8.0, size.y * 0.18)
	var tween := label.create_tween().set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y - 22.0, 0.9) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, 0.9).set_delay(0.3)
	tween.chain().tween_callback(label.queue_free)


func points_text() -> String:
	return _points_label.text


func _set_shown_ratio(value: float) -> void:
	_shown_ratio = value
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var cap := _cap_width()
	if _scroll_tex != null:
		var source_width := float(_scroll_tex.get_width())
		draw_texture_rect_region(_scroll_tex, Rect2(0, 0, cap, size.y),
			Rect2(0, 0, SCROLL_CAP_WIDTH, SCROLL_SOURCE_HEIGHT))
		draw_texture_rect_region(_scroll_tex, Rect2(cap, 0, size.x - cap * 2.0, size.y),
			Rect2(SCROLL_CAP_WIDTH, 0, source_width - SCROLL_CAP_WIDTH * 2.0,
				SCROLL_SOURCE_HEIGHT))
		draw_texture_rect_region(_scroll_tex, Rect2(size.x - cap, 0, cap, size.y),
			Rect2(source_width - SCROLL_CAP_WIDTH, 0, SCROLL_CAP_WIDTH,
				SCROLL_SOURCE_HEIGHT))
	else:
		draw_rect(rect, ArtScript.PAPER)
	# Ink wash fills the paper body between the wooden rods.
	var body := Rect2(Vector2(cap, size.y * PAPER_TOP / SCROLL_SOURCE_HEIGHT),
		Vector2(maxf(0.0, size.x - cap * 2.0),
			size.y * (PAPER_BOTTOM - PAPER_TOP) / SCROLL_SOURCE_HEIGHT))
	var filled := Rect2(body.position, Vector2(body.size.x * _shown_ratio, body.size.y))
	var ink := Color(0.62, 0.16, 0.10, 0.22) if _shown_ratio < 1.0 \
		else Color(0.70, 0.18, 0.10, 0.34)
	draw_rect(filled, ink)
	if _shown_ratio > 0.0 and _shown_ratio < 1.0:
		# Feathered brush tip at the leading edge.
		var tip_x := filled.position.x + filled.size.x
		for i in 4:
			var tip_width := minf(2.0, body.end.x - tip_x - i * 2.0)
			if tip_width > 0.0:
				draw_rect(Rect2(Vector2(tip_x + i * 2.0, body.position.y + i),
					Vector2(tip_width, body.size.y - i * 2.0)),
					Color(ink, ink.a * (0.7 - i * 0.16)))


func _cap_width() -> float:
	return minf(size.x * 0.5, size.y * SCROLL_CAP_WIDTH / SCROLL_SOURCE_HEIGHT)


static func build_ledger(snapshot: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"PKPaperCard"
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 14)
	panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)
	column.add_child(ArtScript.label("理念点", 18, ArtScript.INK))
	var rows := [
		["人口", int(snapshot.get("point_ledger_population_q16", 0))],
		["建筑", int(snapshot.get("point_ledger_building_q16", 0))],
		["贸易", int(snapshot.get("point_ledger_trade_q16", 0))],
	]
	for row in rows:
		var line := HBoxContainer.new()
		line.add_child(ArtScript.label(String(row[0]), 13, ArtScript.INK_MUTED,
			HORIZONTAL_ALIGNMENT_LEFT))
		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(spacer)
		line.add_child(ArtScript.label("+%s" % ArtScript.q16(int(row[1])), 13, ArtScript.INK,
			HORIZONTAL_ALIGNMENT_RIGHT))
		column.add_child(line)
	var factors := "满意度系数 ×%s    理念加成 ×%s" % [
		ArtScript.q16(int(snapshot.get("point_ledger_opinion_factor_q16", 65536))),
		ArtScript.q16(int(snapshot.get("point_ledger_gain_factor_q16", 65536)))]
	column.add_child(ArtScript.label(factors, 12, ArtScript.INK_MUTED))
	var explanation := ArtScript.label(
		"满意度按各阶层影响力加权，影响本期理念点收益。",
		14, ArtScript.INK_MUTED, HORIZONTAL_ALIGNMENT_LEFT)
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.custom_minimum_size.x = 340
	column.add_child(explanation)
	column.add_child(ArtScript.label("本期 +%s    累计 %s" % [
		ArtScript.q16(int(snapshot.get("point_ledger_gain_q16", 0))),
		ArtScript.q16(int(snapshot.get("lifetime_points_q16", 0)))], 14, ArtScript.VERMILION))
	var chart := LedgerChart.new()
	chart.history = snapshot.get("point_history_q16", PackedInt64Array())
	chart.custom_minimum_size = Vector2(360, 96)
	chart.tooltip_text = "最近 32 次收益"
	column.add_child(chart)
	return panel


class LedgerChart:
	extends Control
	var history := PackedInt64Array()

	func _draw() -> void:
		var count := 32
		var slot := size.x / float(count)
		var peak := 1
		for value in history:
			peak = maxi(peak, int(value))
		draw_line(Vector2(0, size.y - 1), Vector2(size.x, size.y - 1),
			Color(0.40, 0.28, 0.16, 0.55), 1.0)
		var offset := count - history.size()
		for index in history.size():
			var h := maxf(2.0, (size.y - 6.0) * float(history[index]) / float(peak))
			var x := (offset + index) * slot + slot * 0.18
			var rect := Rect2(Vector2(x, size.y - 1 - h), Vector2(slot * 0.64, h))
			draw_rect(rect, Color(0.95, 0.89, 0.74))
			draw_rect(rect, Color(0.62, 0.16, 0.10, 0.75), false, 1.0)
			# Torn top edge of the paper slip.
			draw_line(rect.position, rect.position + Vector2(rect.size.x, -1.5),
				Color(0.62, 0.16, 0.10, 0.9), 1.5)
