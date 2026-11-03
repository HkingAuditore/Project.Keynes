extends DossierChart
class_name MilitaryPeerStats

## 平级读数三联（攻 / 防 / 速）：同一字号、同一基线、同一墨色。
## 这三个是平级战力数据，所以谁都不许被画成"主数据"。
## 下方短横线随首帧生长，数值用 numeral 字面（等宽数字感）。

const LABEL_SIZE := 13
const VALUE_SIZE := 26
const HEIGHT := 60.0

var _stats: Array = []


func _init() -> void:
	super()
	custom_minimum_size = Vector2(180.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_stats(stats: Array) -> void:
	_stats = stats
	_start_animation()


func stat_count() -> int:
	return _stats.size()


func _draw() -> void:
	var count := _stats.size()
	if count <= 0 or size.x <= 1.0:
		return
	var cell := size.x / float(count)
	for i in count:
		var stat: Dictionary = _stats[i]
		var x := float(i) * cell
		_text(Vector2(x + 2.0, 15.0), String(stat.get("label", "")), LABEL_SIZE,
			UITokens.DOSSIER_INK_MUTED)
		var color: Color = stat.get("color", UITokens.DOSSIER_INK)
		_text(Vector2(x + 2.0, size.y - 10.0), String(stat.get("text", "—")),
			VALUE_SIZE, color, "numeral")
		var width := (cell - 12.0) * maxf(_grow, 0.02)
		if width > 1.0:
			MilitaryPaperStyle.wobble_line(self, Vector2(x + 2.0, size.y - 4.0),
				Vector2(x + 2.0 + width, size.y - 4.0),
				Color(UITokens.DOSSIER_RULE, 0.9), 1.0, 31 + i, 0.5)
		if i > 0:
			MilitaryPaperStyle.wobble_line(self, Vector2(x, 6.0),
				Vector2(x, size.y - 4.0), Color(UITokens.DOSSIER_RULE, 0.65), 1.0,
				71 + i, 0.45)
