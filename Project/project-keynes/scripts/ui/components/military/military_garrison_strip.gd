extends DossierChart

## 军事页顶部的驻军数据带：一条手绘容量条 + 两行读数。
##
##   在驻            12 / 50
##   [========--------------------------]
##   空额 38   征召 4   配额 5   训练 ×1
##
## 一律照实显示（含 0）：开局没有兵营时也要看得到"兵额 0 / 空额 0 / 训练 ×1"，
## 玩家据此知道自己缺的是容量、还是兵员、还是军校。这里不写任何引导句。

const HEIGHT := 64.0
const LABEL_SIZE := 12
const READOUT_SIZE := 16
const CHIP_SIZE := 11
const CELL_LABEL_SIZE := 11
const CELL_VALUE_SIZE := 13
const BAR_HEIGHT := 8.0
const READOUT_WIDTH := 96.0

var _garrison: Dictionary = {}
var _from_ratio := 0.0


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_data(garrison: Dictionary) -> void:
	_from_ratio = _shown_ratio()
	_garrison = garrison
	visible = true
	_start_animation()


func garrison() -> Dictionary:
	return _garrison


func _shown_ratio() -> float:
	var target := clampf(float(_garrison.get("ratio", 0.0)), 0.0, 1.0)
	if _from_ratio <= 0.0:
		return target
	return lerpf(_from_ratio, target, _blend)


func _draw() -> void:
	if _garrison.is_empty():
		return
	var posts := int(_garrison.get("posts", 0))
	var present := int(_garrison.get("present", 0))
	var w := size.x
	var readout := "%s / %s" % [_count(present), _count(posts)]
	_text(Vector2(0.0, 17.0), "在驻", LABEL_SIZE, UITokens.DOSSIER_INK_MUTED)
	_text(Vector2(w - READOUT_WIDTH, 18.0), readout, READOUT_SIZE,
		UITokens.DOSSIER_INK, "numeral", HORIZONTAL_ALIGNMENT_RIGHT, READOUT_WIDTH)
	_draw_chips(w - READOUT_WIDTH - 10.0, 17.0)
	var track := Rect2(Vector2(0.0, 27.0), Vector2(w, BAR_HEIGHT))
	MilitaryPaperStyle.paper_bar(self, track, UITokens.DOSSIER_TRACK, 3)
	if posts > 0:
		var fill := clampf(_shown_ratio() * (_grow if _has_grown else 1.0), 0.0, 1.0)
		if fill > 0.0:
			var color := UITokens.DOSSIER_VERDIGRIS
			if fill < 0.35:
				color = UITokens.DOSSIER_OXBLOOD
			elif fill < 0.7:
				color = UITokens.DOSSIER_BRASS
			MilitaryPaperStyle.paper_bar(self,
				Rect2(track.position, Vector2(w * fill, BAR_HEIGHT)), color, 5)
	_draw_cells(56.0)


## 第二行四格读数：空额 / 征召 / 军营 / 训练。标签与数值贴在一起，
## 四格按等宽排开，读起来像账簿的一行，而不是四段漂浮的数字。
## 「军营」给的是座数：它直接解释上面那条容量条为什么是这么多。
func _draw_cells(baseline: float) -> void:
	var cells := [
		{"label": "空额", "value": _count(int(_garrison.get("open", 0)))},
		{"label": "征召", "value": _count(int(_garrison.get("pending", 0)))},
		{"label": "军营", "value": _count(int(_garrison.get("barracks_count", 0)))},
		{"label": "训练", "value": "×%s" % _one_decimal(
			float(_garrison.get("training_speed", 1.0)))},
	]
	var cell_width := size.x / float(cells.size())
	for index in range(cells.size()):
		var cell: Dictionary = cells[index]
		var left := cell_width * float(index)
		var label := String(cell.label)
		_text(Vector2(left, baseline), label, CELL_LABEL_SIZE,
			UITokens.DOSSIER_INK_MUTED)
		var value_x := left + _text_width(label, CELL_LABEL_SIZE) + 6.0
		_text(Vector2(value_x, baseline), String(cell.value), CELL_VALUE_SIZE,
			UITokens.DOSSIER_INK, "numeral", HORIZONTAL_ALIGNMENT_LEFT,
			maxf(0.0, left + cell_width - value_x - 8.0))


## 状态签从右往左排：暂停 / 失修 / 被占领。征召与配额已经进第二行的读数格。
func _draw_chips(right_x: float, baseline: float) -> void:
	var chips: Array = []
	if bool(_garrison.get("paused", false)):
		chips.append({"text": "暂停", "color": UITokens.DOSSIER_BRASS,
			"icon": &"action.pause"})
	if bool(_garrison.get("disrepair", false)):
		chips.append({"text": "失修", "color": UITokens.DOSSIER_OXBLOOD,
			"icon": &"status.warning"})
	if bool(_garrison.get("occupied", false)):
		chips.append({"text": "占领", "color": UITokens.DOSSIER_OXBLOOD, "icon": &""})
	var x := right_x
	for index in range(chips.size() - 1, -1, -1):
		var chip: Dictionary = chips[index]
		var label := String(chip.text)
		var width := _text_width(label, CHIP_SIZE, "sans_strong")
		x -= width
		_text(Vector2(x, baseline), label, CHIP_SIZE, chip.color, "sans_strong")
		x -= 7.0
		var icon: StringName = chip.icon
		if icon != &"":
			IconCatalog.draw_icon(self, icon, Rect2(Vector2(x - 12.0, baseline - 11.0),
				Vector2(11.0, 11.0)), 0.85)
			x -= 12.0
		x -= 10.0


static func _count(value: int) -> String:
	return UITokens.format_compact_number_cn(float(value), 1)


static func _one_decimal(value: float) -> String:
	return ("%.1f" % value).trim_suffix(".0")
