extends DossierChart

## 阶层生活水平 7 档阶梯尺：直观展示「赤贫 → 奢华」当前所处档位与人均存款缓冲。

const TIER_NAMES: Array[String] = [
	"赤贫", "挣扎", "贫困", "温饱", "小康", "富裕", "奢华"
]
const HEIGHT := 52.0

var _level := -1
var _wealth_text := "—"
var _sat_text := "—"


func _init() -> void:
	super()
	custom_minimum_size = Vector2(200.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_living_state(level: int, wealth_text: String, sat_text: String = "") -> void:
	_level = clampi(level, -1, 6)
	_wealth_text = wealth_text
	_sat_text = sat_text
	var tier_label := TIER_NAMES[_level] if _level >= 0 and _level < TIER_NAMES.size() else "待评估"
	tooltip_text = "实际消费生活水平：%s（第 %d / 7 档）\n人均存款：%s\n生活档位按生存、基本、舒适和奢侈消费判定；存款不直接提升档位。" % [
		tier_label, maxi(0, _level + 1), _wealth_text
	]
	_start_animation()


static func _tier_color(index: int) -> Color:
	if index <= 1:
		return UITokens.DOSSIER_OXBLOOD
	if index == 2:
		return UITokens.DOSSIER_BRASS
	if index <= 4:
		return UITokens.DOSSIER_VERDIGRIS
	return UITokens.DOSSIER_BRASS


func _draw() -> void:
	var w := size.x
	var tier_label := TIER_NAMES[_level] if _level >= 0 and _level < TIER_NAMES.size() else "待评估"
	_text(Vector2(0.0, 13.0), "生活水平阶梯 · %s" % tier_label, 12,
		UITokens.DOSSIER_INK_SOFT, "sans_strong")
	_text(Vector2(0.0, 13.0), "人均存款 %s" % _wealth_text, 12,
		UITokens.DOSSIER_INK, "sans_strong", HORIZONTAL_ALIGNMENT_RIGHT, w)

	var count := TIER_NAMES.size()
	var gap := 3.0
	var seg_w := maxf(18.0, (w - gap * float(count - 1)) / float(count))
	var top := 20.0
	var seg_h := 26.0
	for i in range(count):
		var x := float(i) * (seg_w + gap)
		var rect := Rect2(Vector2(x, top), Vector2(seg_w, seg_h))
		var is_active := i == _level
		var is_passed := _level >= 0 and i < _level
		var accent := _tier_color(i)
		if is_active:
			_rounded_bar(rect, accent, 3.0)
			draw_line(Vector2(rect.position.x + 2.0, rect.position.y + 1.0),
				Vector2(rect.end.x - 2.0, rect.position.y + 1.0),
				UITokens.DOSSIER_PAPER, 1.5)
		elif is_passed:
			_rounded_bar(rect, Color(accent, 0.20 * _grow), 3.0)
			draw_rect(rect, Color(accent, 0.45), false, 1.0)
		else:
			_rounded_bar(rect, UITokens.DOSSIER_TRACK, 3.0)
			draw_rect(rect, UITokens.DOSSIER_RULE, false, 1.0)
		var text_color := UITokens.DOSSIER_PAPER if is_active \
			else (UITokens.DOSSIER_INK if is_passed else UITokens.DOSSIER_INK_MUTED)
		var font_kind := "sans_strong" if is_active else "sans"
		var label := TIER_NAMES[i]
		var tw := _text_width(label, 11, font_kind)
		_text(Vector2(x + maxf(1.0, (seg_w - tw) * 0.5), top + 17.0),
			label, 11, text_color, font_kind)
