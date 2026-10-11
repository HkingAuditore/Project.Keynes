extends DossierChart
class_name DossierDivergingBar

## 以中线为零点的双向条：左侧为流出（暗红），右侧为流入（铜绿）。
## 用于进口/出口、收入/支出这类“两股力量对冲”的读数。

var left_label := ""
var right_label := ""
var _left := 0.0
var _right := 0.0
var _from_left := 0.0
var _from_right := 0.0
var left_text := ""
var right_text := ""


func _init() -> void:
	super()
	custom_minimum_size = Vector2(220.0, 40.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_values(p_left_label: String, left_value: float, p_left_text: String,
		p_right_label: String, right_value: float, p_right_text: String) -> void:
	_from_left = lerpf(_from_left, _left, _blend)
	_from_right = lerpf(_from_right, _right, _blend)
	left_label = p_left_label
	right_label = p_right_label
	_left = maxf(0.0, left_value)
	_right = maxf(0.0, right_value)
	left_text = p_left_text
	right_text = p_right_text
	tooltip_text = "%s %s\n%s %s" % [left_label, left_text, right_label, right_text]
	_start_animation()


func _draw() -> void:
	var w := size.x
	var mid := w * 0.5
	var left := lerpf(_from_left, _left, _blend)
	var right := lerpf(_from_right, _right, _blend)
	var peak := maxf(maxf(left, right), 1e-9)
	_text(Vector2(0.0, 12.0), "%s  %s" % [left_label, left_text], 12, UITokens.DOSSIER_OXBLOOD,
		"sans_strong")
	_text(Vector2(0.0, 12.0), "%s  %s" % [right_text, right_label], 12, UITokens.DOSSIER_VERDIGRIS,
		"sans_strong", HORIZONTAL_ALIGNMENT_RIGHT, w)
	var y := 20.0
	_rounded_bar(Rect2(Vector2(0.0, y), Vector2(w, 12.0)), UITokens.DOSSIER_TRACK, 3.0)
	var lw := mid * left / peak * _grow
	var rw := mid * right / peak * _grow
	_rounded_bar(Rect2(Vector2(mid - lw, y), Vector2(lw, 12.0)), UITokens.DOSSIER_OXBLOOD, 2.0)
	_rounded_bar(Rect2(Vector2(mid, y), Vector2(rw, 12.0)), UITokens.DOSSIER_VERDIGRIS, 2.0)
	draw_line(Vector2(mid, y - 4.0), Vector2(mid, y + 16.0), UITokens.DOSSIER_INK, 1.5)
