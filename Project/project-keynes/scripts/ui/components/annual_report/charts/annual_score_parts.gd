extends AnnualChartBase
class_name AnnualScoreParts

## 发展考核的十项分解。
## 每一行把"得分"画成实心段、"权重满分"画成铜金竖刻度——两者的差就是丢分。
## 因为十项满分并不相同（20 到 3 分），所有长度都按最大权重归一，
## 这样行与行之间可以直接比大小，而不是每行各自撑满。

var _parts := PackedInt64Array()
var _labels := PackedStringArray()
var _weights := PackedFloat32Array()

const ROW_HEIGHT := 30.0


func set_data(parts: PackedInt64Array, labels: PackedStringArray, weights: PackedFloat32Array) -> bool:
	if parts.is_empty() or weights.is_empty():
		return false
	_parts = parts
	_labels = labels
	_weights = weights
	custom_minimum_size.y = ROW_HEIGHT * maxf(1.0, parts.size()) + 54.0
	_start_reveal()
	return true


func _draw() -> void:
	if _parts.is_empty():
		return
	var w: float = size.x
	var label_width: float = clampf(w * 0.24, 108.0, 168.0)
	var value_width: float = 96.0
	var track_left: float = label_width + 12.0
	var track_right: float = maxf(track_left + 40.0, w - value_width - 12.0)
	var track_len: float = track_right - track_left

	var max_weight: float = 1.0
	for weight in _weights:
		max_weight = maxf(max_weight, weight)

	var total: float = 0.0
	for i in _parts.size():
		var weight: float = _weights[i] if i < _weights.size() else 0.0
		var score: float = float(_parts[i]) / 100.0
		total += score
		var y: float = ROW_HEIGHT * i + 20.0
		var label: String = _labels[i] if i < _labels.size() else "第 %d 项" % (i + 1)
		_caption(Vector2(0.0, y), label)
		# 轨道只有一条极淡的底线，不是"进度条底槽"。
		draw_line(Vector2(track_left, y - 3.0), Vector2(track_right, y - 3.0), Color(_ink.r, _ink.g, _ink.b, 0.09), 1.0, true)
		var achieved: float = track_len * clampf(score / max_weight, 0.0, 1.0) * _grow
		if achieved > 0.6:
			draw_line(Vector2(track_left, y - 3.0), Vector2(track_left + achieved, y - 3.0), Color(_accent.r, _accent.g, _accent.b, 0.92), 4.0, true)
		var full: float = track_len * clampf(weight / max_weight, 0.0, 1.0)
		draw_line(Vector2(track_left + full, y - 8.0), Vector2(track_left + full, y + 2.0), Color(_brass.r, _brass.g, _brass.b, 0.85), 1.0, true)
		var text := "%.1f" % score
		_right_text(w, y, text, 19, _ink)
		_right_text(w - 52.0, y, "/ %.0f" % weight, 13, Color(_muted.r, _muted.g, _muted.b, 0.85), "label")

	_baseline(ROW_HEIGHT * _parts.size() + 30.0, 0.0, w)
	_caption(Vector2(0.0, ROW_HEIGHT * _parts.size() + 50.0), "综合得分")
	_right_text(w, ROW_HEIGHT * _parts.size() + 50.0, "%.2f / 100" % total, 24, _accent)
