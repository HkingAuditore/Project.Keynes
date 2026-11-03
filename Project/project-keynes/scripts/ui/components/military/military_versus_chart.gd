extends DossierChart
class_name MilitaryVersusChart

## 战线对阵表：同一指标左右并排，以中缝为界向两侧生长。
## 每一行都归一化到「双方较大值」，所以读的是"谁更多"，而不是绝对值大小。
## 这是战线页唯一的数据可视化：兵力 / 攻击 / 防御 / 士气 / 补给逐行对比，
## 数值直接标在两侧，不额外解释。

const LABEL_WIDTH := 46.0
const VALUE_WIDTH := 66.0
const ROW_HEIGHT := 30.0
const HEADER_HEIGHT := 20.0
const BAR_HEIGHT := 10.0

var _rows: Array = []
var _own_color := UITokens.DOSSIER_VERDIGRIS
var _enemy_color := UITokens.DOSSIER_OXBLOOD
var _own_label := "我方"
var _enemy_label := "敌方"


func _init() -> void:
	super()
	custom_minimum_size = Vector2(240.0, 120.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_rows(rows: Array, own_color: Color, enemy_color: Color,
		own_label: String = "我方", enemy_label: String = "敌方") -> void:
	_rows = rows
	_own_color = own_color
	_enemy_color = enemy_color
	_own_label = own_label
	_enemy_label = enemy_label
	custom_minimum_size.y = HEADER_HEIGHT + ROW_HEIGHT * float(maxi(rows.size(), 1))
	_start_animation()


func row_count() -> int:
	return _rows.size()


func _draw() -> void:
	if size.x <= 1.0:
		return
	var label_w := LABEL_WIDTH
	var value_w := minf(VALUE_WIDTH, size.x * 0.22)
	var bar_left := label_w + value_w
	var bar_right := maxf(bar_left + 24.0, size.x - value_w)
	var mid := (bar_left + bar_right) * 0.5
	# 表头：两侧标签在数值列上方。
	_text(Vector2(label_w, 14.0), _own_label, 12, _own_color, "sans_strong",
		HORIZONTAL_ALIGNMENT_RIGHT, value_w - 8.0)
	_text(Vector2(bar_right + 8.0, 14.0), _enemy_label, 12, _enemy_color, "sans_strong")
	for i in _rows.size():
		var row: Dictionary = _rows[i]
		var top := HEADER_HEIGHT + ROW_HEIGHT * float(i)
		var baseline := top + ROW_HEIGHT - 11.0
		var local := clampf((_grow - float(i) * 0.10) / 0.65, 0.0, 1.0)
		_text(Vector2(0.0, baseline), String(row.get("label", "")), 13,
			UITokens.DOSSIER_INK_MUTED)
		var own_text := String(row.get("own_text", "—"))
		var enemy_text := String(row.get("enemy_text", "—"))
		_text(Vector2(label_w, baseline), _fit_text(own_text, 15, value_w - 8.0),
			15, _own_color, "numeral", HORIZONTAL_ALIGNMENT_RIGHT, value_w - 8.0)
		_text(Vector2(bar_right + 8.0, baseline),
			_fit_text(enemy_text, 15, value_w - 8.0), 15, _enemy_color, "numeral")
		var own := maxf(0.0, float(row.get("own_value", 0.0)))
		var enemy := maxf(0.0, float(row.get("enemy_value", 0.0)))
		var peak := maxf(maxf(own, enemy), 1e-9)
		var half := (mid - bar_left) - 2.0
		var bar_y := top + ROW_HEIGHT * 0.5 - BAR_HEIGHT * 0.5 + 3.0
		# 轨道：两半各一条，读作"这一行还剩多少"。
		MilitaryPaperStyle.paper_bar(self, Rect2(Vector2(bar_left, bar_y),
			Vector2(mid - bar_left - 1.0, BAR_HEIGHT)),
			Color(UITokens.DOSSIER_TRACK, 0.55), 100 + i, 1.0)
		MilitaryPaperStyle.paper_bar(self, Rect2(Vector2(mid + 1.0, bar_y),
			Vector2(bar_right - mid - 1.0, BAR_HEIGHT)),
			Color(UITokens.DOSSIER_TRACK, 0.55), 200 + i, 1.0)
		var own_len := half * own / peak * local
		if own_len > 0.5:
			MilitaryPaperStyle.paper_bar(self, Rect2(Vector2(mid - 1.0 - own_len, bar_y),
				Vector2(own_len, BAR_HEIGHT)),
				Color(_own_color.r, _own_color.g, _own_color.b, 0.82), 300 + i, 1.0)
		var enemy_len := half * enemy / peak * local
		if enemy_len > 0.5:
			MilitaryPaperStyle.paper_bar(self, Rect2(Vector2(mid + 1.0, bar_y),
				Vector2(enemy_len, BAR_HEIGHT)),
				Color(_enemy_color.r, _enemy_color.g, _enemy_color.b, 0.82), 400 + i, 1.0)
		if i < _rows.size() - 1:
			MilitaryPaperStyle.wobble_line(self,
				Vector2(0.0, top + ROW_HEIGHT - 0.5),
				Vector2(size.x, top + ROW_HEIGHT - 0.5),
				Color(UITokens.DOSSIER_RULE, 0.18), 1.0, 500 + i, 0.4)
	# 中缝：双方的分界，画得比其它线重一档。
	MilitaryPaperStyle.wobble_line(self, Vector2(mid, 4.0),
		Vector2(mid, HEADER_HEIGHT + ROW_HEIGHT * float(_rows.size())),
		UITokens.DOSSIER_RULE_STRONG, 1.6, 9, 0.35, 6)
