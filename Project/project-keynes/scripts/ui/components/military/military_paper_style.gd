extends RefCounted
class_name MilitaryPaperStyle

## 军务档案的手绘/剪纸绘制工具。只画，不持有节点、不读写模拟状态。
##
## 规律：所有线条都带一点**确定性抖动**（同一帧重绘结果一致，不会闪），
## 两端收敛到锚点，读起来像铅笔起笔—行笔—收笔，而不是矢量直线。
## 抖动幅度按像素给，调用方决定强弱。

## 确定性抖动：-1..1。seed 相同、index 相同 → 值相同。
static func jitter(seed_value: int, index: int) -> float:
	var h: int = (seed_value * 1103515245 + index * 12345 + 0x9E3779B9) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h % 2001) / 1000.0 - 1.0


## 手绘线：中间抖动、两端收敛。
static func wobble_line(canvas: CanvasItem, from: Vector2, to: Vector2,
		color: Color, width: float = 1.0, seed_value: int = 0,
		amplitude: float = 0.8, steps: int = 0) -> void:
	var length := from.distance_to(to)
	if length < 0.5:
		return
	var count := steps if steps > 0 else clampi(int(length / 16.0), 2, 24)
	var direction := (to - from) / length
	var normal := Vector2(-direction.y, direction.x)
	var points := PackedVector2Array()
	points.resize(count + 1)
	for i in count + 1:
		var t := float(i) / float(count)
		var offset := jitter(seed_value, i) * amplitude * sin(t * PI)
		points[i] = from.lerp(to, t) + normal * offset
	canvas.draw_polyline(points, color, width, true)


## 一条纸边：底色块 + 上沿一道深一点的墨线，像剪纸贴上去的厚度。
## StyleBoxFlat 在 draw 时立即生成几何，复用同一实例是安全的（也免掉每帧分配）。
static var _bar_style: StyleBoxFlat

static func paper_bar(canvas: CanvasItem, rect: Rect2, color: Color,
		seed_value: int = 0, radius: float = 1.5) -> void:
	if rect.size.x <= 0.5 or rect.size.y <= 0.5:
		return
	if _bar_style == null:
		_bar_style = StyleBoxFlat.new()
		_bar_style.anti_aliasing = true
	_bar_style.bg_color = color
	_bar_style.set_corner_radius_all(int(minf(radius, rect.size.y * 0.5)))
	canvas.draw_style_box(_bar_style, rect)
	wobble_line(canvas, Vector2(rect.position.x, rect.position.y + 0.5),
		Vector2(rect.end.x, rect.position.y + 0.5),
		Color(0.20, 0.12, 0.06, color.a * 0.35), 1.0, seed_value, 0.35, 3)
