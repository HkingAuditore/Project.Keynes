extends Button

## 触摸命中带：**视觉尺寸不变**，只把可点矩形向外扩。
##
## 为什么需要它：44dp 的命中区在 440dpi/1.375 缩放下是 88 设计像素，而设计稿里的
## 纸签只有 34 像素高。直接把纸签拔到 88 会把整条页签栏变成一根粗棍子；用这个脚本
## 让页签保持 56 像素的可视高度，上下各外扩 16 像素 —— 手指落在纸签外侧的空白上
## 也算点中，且相邻页签的扩展区（横向不做扩展）互不重叠。
##
## 只对「一排里横向本来就够宽、纵向偏矮」的控件有意义（页签、整行按钮）。
## 密集并排的小控件不要用它：扩展区会互相盖住，反而更容易点错。
##
## 由 CategoryTabs / TouchUI 在触摸档下设置 pad；桌面档恒为 0，_has_point 退化成
## 默认的「点在本体矩形内」——与改动前完全一致。

## 向上/下扩展多少设计像素。
var touch_pad_vertical := 0.0
## 向左/右扩展多少设计像素（默认 0：并排控件不扩横向，避免互相盖住）。
var touch_pad_horizontal := 0.0


func set_touch_padding(pad: Vector2) -> void:
	touch_pad_vertical = maxf(pad.y, 0.0)
	touch_pad_horizontal = maxf(pad.x, 0.0)


## TouchUI.hit_rect() / QA 报告读取的当前扩展量。
func touch_hit_padding() -> Vector2:
	return Vector2(touch_pad_horizontal, touch_pad_vertical)


func _has_point(point: Vector2) -> bool:
	if touch_pad_vertical <= 0.0 and touch_pad_horizontal <= 0.0:
		return Rect2(Vector2.ZERO, size).has_point(point)
	var pad := Vector2(touch_pad_horizontal, touch_pad_vertical)
	return Rect2(-pad, size + pad * 2.0).has_point(point)
