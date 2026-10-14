extends DossierChart
class_name DossierRadarChart

## 满意度 8 维雷达：实线多边形为选中对象，虚线为全国参照。

var axes: PackedStringArray = PackedStringArray()
var accent := UITokens.DOSSIER_OXBLOOD
var _values := PackedFloat32Array()
var _from := PackedFloat32Array()
var _reference := PackedFloat32Array()


func _init() -> void:
	super()
	custom_minimum_size = Vector2(168.0, 164.0)


func set_values(p_axes: PackedStringArray, values: PackedFloat32Array,
		reference: PackedFloat32Array = PackedFloat32Array(), p_accent: Color = UITokens.DOSSIER_OXBLOOD) -> void:
	_from = _blend_arrays(_from, _values, _blend)
	if _from.size() != values.size():
		_from = values
	axes = p_axes
	_values = values
	_reference = reference
	accent = p_accent
	var tips := PackedStringArray()
	for i in range(mini(axes.size(), values.size())):
		var line := "%s %.0f%%" % [axes[i], values[i] * 100.0]
		if i < reference.size():
			line += "（全国 %.0f%%）" % (reference[i] * 100.0)
		tips.append(line)
	tooltip_text = "\n".join(tips)
	_start_animation()


func _draw() -> void:
	var count := axes.size()
	if count < 3:
		return
	var center := size * 0.5 + Vector2(0.0, 4.0)
	var compact := size.x < 195.0
	var font_sz := 11 if compact else 12
	var pad_x := 42.0 if compact else 52.0
	var pad_y := 18.0 if compact else 24.0
	var radius := maxf(20.0, minf(size.x * 0.5 - pad_x, size.y * 0.5 - pad_y))
	for ring in range(1, 5):
		var points := _polygon(center, radius * float(ring) / 4.0, PackedFloat32Array(), count, 1.0)
		points.append(points[0])
		draw_polyline(points, UITokens.DOSSIER_RULE if ring == 4 else Color(UITokens.DOSSIER_RULE, 0.22),
			1.0, true)
	for i in range(count):
		var angle := _angle(i, count)
		var tip := center + Vector2(cos(angle), sin(angle)) * radius
		draw_line(center, tip, Color(UITokens.DOSSIER_RULE, 0.30), 1.0, true)
		var label_pos := center + Vector2(cos(angle), sin(angle)) * (radius + (11.0 if compact else 14.0))
		var label := axes[i]
		var width := _text_width(label, font_sz)
		var align_x := label_pos.x - width * 0.5
		if cos(angle) > 0.3:
			align_x = label_pos.x - 2.0
		elif cos(angle) < -0.3:
			align_x = label_pos.x - width + 2.0
		_text(Vector2(align_x, label_pos.y + 4.0), label, font_sz, UITokens.DOSSIER_INK_SOFT)
	if _reference.size() == count:
		var ref := _polygon(center, radius, _reference, count, 1.0)
		ref.append(ref[0])
		for i in range(ref.size() - 1):
			_dashed(ref[i], ref[i + 1], UITokens.DOSSIER_INK_MUTED)
	var values := _blend_arrays(_from, _values, _blend)
	if values.size() == count:
		var poly := _polygon(center, radius, values, count, _grow)
		draw_colored_polygon(poly, Color(accent, 0.20))
		var outline := poly.duplicate()
		outline.append(poly[0])
		draw_polyline(outline, accent, 2.0, true)
		for point in poly:
			draw_circle(point, 2.6, accent)


func _polygon(center: Vector2, radius: float, values: PackedFloat32Array, count: int,
		scale_factor: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in range(count):
		var value := clampf(values[i], 0.0, 1.0) if i < values.size() else 1.0
		var angle := _angle(i, count)
		points.append(center + Vector2(cos(angle), sin(angle)) * radius * value * scale_factor)
	return points


func _angle(index: int, count: int) -> float:
	return -PI * 0.5 + TAU * float(index) / float(count)


func _dashed(a: Vector2, b: Vector2, color: Color) -> void:
	var length := a.distance_to(b)
	var steps := int(length / 6.0)
	for s in range(0, steps, 2):
		var t0 := float(s) / float(maxi(1, steps))
		var t1 := float(s + 1) / float(maxi(1, steps))
		draw_line(a.lerp(b, t0), a.lerp(b, t1), color, 1.2, true)
