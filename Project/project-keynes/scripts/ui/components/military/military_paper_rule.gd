extends Control
class_name MilitaryPaperRule

## 一条手绘分隔线：起笔处一枚墨点，线身带确定性抖动。
## 用来替代 ColorRect 矢量线——军务档案里的横线应当是画上去的。

@export var seed_value := 7
@export var amplitude := 0.75
@export var ink_dot := true

var color := UITokens.DOSSIER_RULE


func _init() -> void:
	custom_minimum_size = Vector2(0.0, 7.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var y := size.y * 0.5
	var start := Vector2(0.0, y)
	if ink_dot:
		draw_circle(Vector2(1.5, y), 1.6, UITokens.DOSSIER_INK_SOFT)
		start = Vector2(5.0, y)
	MilitaryPaperStyle.wobble_line(self, start, Vector2(size.x, y), color, 1.0,
		seed_value, amplitude)
