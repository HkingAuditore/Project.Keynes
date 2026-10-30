extends DossierChart
class_name DossierLevelLadder

## 生活水平是 0..6 的有序台阶，不是连续量：画成楼梯格而不是进度条。
## 整数部分是满格，小数部分按比例填最后一格，右端给出档位名。
## 值越大越向右，读的是「处在第几档」，而不是「占了总量的百分之几」。

const HEIGHT := 56.0
const SEGMENT_HEIGHT := 14.0
const SEGMENT_GAP := 4.0

var _level := NAN
var _max_level := 6
var _name := ""


func _init() -> void:
	super()
	custom_minimum_size = Vector2(160.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## level 是人口加权后的连续读数（0..max_level）；name 是所在档位的中文名。
func set_level(level: float, max_level: int, name: String) -> void:
	_level = level
	_max_level = maxi(1, max_level)
	_name = name
	_start_animation()


func level() -> float:
	return _level


func _draw() -> void:
	var w := size.x
	if w <= 1.0:
		return
	var valid := not is_nan(_level)
	var shown := clampf(_level, 0.0, float(_max_level)) if valid else 0.0
	var text := "%.1f" % shown if valid else "—"
	_text(Vector2(0.0, 21.0), text, 21, UITokens.DOSSIER_INK if valid
		else UITokens.DOSSIER_INK_MUTED, "serif")
	var cursor := _text_width(text, 21, "serif") + 5.0
	_text(Vector2(cursor, 21.0), "／ %d" % _max_level, 11, UITokens.DOSSIER_INK_MUTED)
	cursor += _text_width("／ %d" % _max_level, 11) + 10.0
	if not _name.is_empty():
		_text(Vector2(cursor, 21.0), _name, 12, UITokens.DOSSIER_BRASS, "sans_strong")
	_draw_ladder(w, shown if valid else 0.0)


func _draw_ladder(w: float, level: float) -> void:
	var count := _max_level
	var seg_width := maxf(2.0, (w - SEGMENT_GAP * float(count - 1)) / float(count))
	var y := size.y - SEGMENT_HEIGHT
	for index in range(count):
		var x := (seg_width + SEGMENT_GAP) * float(index)
		_rounded_bar(Rect2(Vector2(x, y), Vector2(seg_width, SEGMENT_HEIGHT)),
			UITokens.DOSSIER_TRACK, 2.0)
		var filled := clampf(level - float(index), 0.0, 1.0) * _grow
		if filled <= 0.0:
			continue
		var color := UITokens.DOSSIER_BRASS.lerp(UITokens.DOSSIER_VERDIGRIS,
			float(index) / float(maxi(1, count - 1)))
		_rounded_bar(Rect2(Vector2(x, y), Vector2(seg_width * filled, SEGMENT_HEIGHT)),
			color, 2.0)
