extends Control


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func _draw() -> void:
	var canvas := Rect2(Vector2.ZERO, size)
	draw_rect(canvas, Color(0.020, 0.027, 0.028, 1.0))
	var grid_color := Color(0.32, 0.43, 0.42, 0.13)
	var major_color := Color(0.52, 0.43, 0.27, 0.18)
	for column in range(1, 12):
		var x := size.x * float(column) / 12.0
		draw_line(Vector2(x, 0.0), Vector2(x, size.y),
			major_color if column == 6 else grid_color, 1.0)
	for row in range(1, 8):
		var y := size.y * float(row) / 8.0
		draw_line(Vector2(0.0, y), Vector2(size.x, y),
			major_color if row == 4 else grid_color, 1.0)
	var contour_color := Color(0.34, 0.50, 0.46, 0.16)
	for band in range(5):
		var points := PackedVector2Array()
		for sample in range(33):
			var t := float(sample) / 32.0
			var wave := sin(t * TAU * (1.15 + band * 0.17) + band * 1.7)
			var secondary := sin(t * TAU * 3.1 - band * 0.8) * 0.32
			points.append(Vector2(t * size.x,
				size.y * (0.18 + band * 0.155) + (wave + secondary) * size.y * 0.026))
		draw_polyline(points, contour_color, 1.25, true)
	var center := Vector2(size.x * 0.84, size.y * 0.76)
	var radius := minf(size.x, size.y) * 0.085
	draw_arc(center, radius, 0.0, TAU, 64, major_color, 1.5, true)
	draw_arc(center, radius * 0.72, 0.0, TAU, 48, grid_color, 1.0, true)
	draw_line(center - Vector2(radius, 0.0), center + Vector2(radius, 0.0), major_color, 1.0)
	draw_line(center - Vector2(0.0, radius), center + Vector2(0.0, radius), major_color, 1.0)
