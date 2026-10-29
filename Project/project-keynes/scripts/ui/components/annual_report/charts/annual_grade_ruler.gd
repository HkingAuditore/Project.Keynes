extends AnnualChartBase
class_name AnnualGradeRuler

## 评级标尺：0–100 的轴、七段等级、一个朱红游标。
## 这是封面与考核章"评级仪式感"的落点——比一个 84px 的印章更能说清
## "你在哪、离下一级差多少"。生存率封顶时，被截断的区段用斜线划掉。

var _score := 0.0
var _grade := "—"
var _cap := -1
var _complete := true
## 七段等级的分界。评分口径写在存档里（scoring_version），旧报告仍按 V1 阈值读，
## 新报告按 V2，所以刻度不能焊在图上：默认用当前口径，真正的分段由调用方
## 从模型的 `grade_bands` 传进来。
var _bands: Array = AnnualReportViewModel.GRADE_BANDS_V2


func set_data(score: float, grade: String, cap: int = -1, complete: bool = true, bands: Array = []) -> bool:
	_score = clampf(score, 0.0, 100.0)
	_grade = grade
	_cap = cap
	_complete = complete
	if not bands.is_empty():
		_bands = bands
	custom_minimum_size.y = 56.0
	_start_reveal()
	return true


func _draw() -> void:
	var w: float = size.x
	var axis_y: float = 32.0
	var bands: Array = _bands
	var alpha: float = 1.0 if _complete else 0.34
	var ink := Color(_ink.r, _ink.g, _ink.b, 0.55 * alpha)

	draw_line(Vector2(0.0, axis_y), Vector2(w, axis_y), ink, 2.8, true)
	for band in bands:
		var left: float = w * float(band.min) / 100.0
		var right: float = w * float(band.max) / 100.0
		# 段端刻度
		draw_line(Vector2(left, axis_y - 6.0), Vector2(left, axis_y + 6.0), ink, 2.0, true)
		# 段名居中在段内；E 段太窄就把字放到右侧。
		var label: String = String(band.grade)
		var label_size := 13
		var width: float = _text_width(label, label_size, "label")
		var center: float = (left + right) * 0.5 - width * 0.5
		_text(Vector2(clampf(center, left + 2.0, right - width - 2.0), axis_y + 20.0), label, label_size, Color(_muted.r, _muted.g, _muted.b, alpha), "label")
		# 被封顶的区段打斜线
		if _cap >= 0 and float(band.min) >= _cap_threshold():
			var x: float = left
			while x < right:
				draw_line(Vector2(x, axis_y - 8.0), Vector2(minf(x + 6.0, right), axis_y), Color(_accent.r, _accent.g, _accent.b, 0.26 * alpha), 1.0, true)
				x += 7.0
	draw_line(Vector2(w, axis_y - 6.0), Vector2(w, axis_y + 6.0), ink, 2.0, true)

	if not _complete:
		_caption(Vector2(0.0, axis_y - 14.0), "统计未满一年，不评级")
		return

	var cursor: float = w * _score / 100.0 * _grow
	draw_line(Vector2(cursor, axis_y - 18.0), Vector2(cursor, axis_y + 7.0),
		UITokens.CHRONICLE_PENCIL_RED, 4.0, true)
	draw_colored_polygon(PackedVector2Array([
		Vector2(cursor - 4.0, axis_y + 6.0), Vector2(cursor + 4.0, axis_y + 6.0), Vector2(cursor, axis_y + 11.0),
	]), _accent)
	var text := "%.2f" % _score
	var width: float = _text_width(text, 19, "numeral")
	_text(Vector2(clampf(cursor - width * 0.5, 0.0, w - width), axis_y - 20.0), text, 19, _accent, "numeral")
	if _cap >= 0:
		_right_text(w, axis_y - 20.0, "评级上限 " + ("D" if _cap == 5 else "B"), 13, Color(_muted.r, _muted.g, _muted.b, 0.9), "label")


## 封顶后不可达的那一段从哪儿开始：封顶档之上那一段的顶点。
## V1 口径下 D 封顶 = 60（C 段上限）、B 封顶 = 86（A 段上限），与旧写死的两个数一致；
## V2 分段更严，同一档位自动收紧，不用再改代码。
func _cap_threshold() -> float:
	var index: int = _cap - 1
	if index < 0 or index >= _bands.size():
		return 100.0
	return float(_bands[index].max)
