extends Control
class_name HudShareBar

## 悬浮卡里的「构成条」：一条定高横条按占比分段，颜色沿用行里的阶层色签。
##
## 只画条本身，不画图例——图例就在下面的阶层行里，同一份颜色一一对应，
## 避免同一份占比在卡里出现两次。

const BAR_HEIGHT := 10.0

var _segments: Array = []


func _init() -> void:
	custom_minimum_size = Vector2(0.0, BAR_HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_segments(segments: Array) -> void:
	_segments = segments
	var tips := PackedStringArray()
	for segment in segments:
		tips.append("%s %s" % [String(segment.get("label", "")),
			String(segment.get("text", ""))])
	tooltip_text = "\n".join(tips)
	queue_redraw()


func _draw() -> void:
	var bar := Rect2(Vector2.ZERO, Vector2(size.x, BAR_HEIGHT))
	draw_rect(bar, UITokens.DOSSIER_TRACK, true)
	var total := 0.0
	for segment in _segments:
		total += maxf(0.0, float((segment as Dictionary).get("value", 0.0)))
	if total > 0.0:
		var x := 0.0
		for index in range(_segments.size()):
			var segment: Dictionary = _segments[index]
			var width := size.x * maxf(0.0, float(segment.get("value", 0.0))) / total
			if width <= 0.0:
				continue
			draw_rect(Rect2(Vector2(x, 0.0), Vector2(width, BAR_HEIGHT)),
				segment.get("color", UITokens.DOSSIER_BRASS), true)
			if x > 0.0:
				draw_line(Vector2(x, 0.0), Vector2(x, BAR_HEIGHT),
					UITokens.DOSSIER_PAPER, 1.0)
			x += width
	draw_rect(bar, UITokens.DOSSIER_RULE, false, 1.0)
