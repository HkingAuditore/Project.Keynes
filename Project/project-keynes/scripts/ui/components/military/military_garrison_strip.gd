extends DossierChart

## 军事页顶部的驻军条：一条手绘进度条（在驻 / 兵额）+ 两端读数。
## 右侧只在确有状态时贴一枚小签（征召 / 暂停 / 失修 / 占领），不写句子。
## 数据形状见 CellInspectorViewModel 的 `military_cell.garrison`。

const HEIGHT := 44.0
const LABEL_SIZE := 12
const READOUT_SIZE := 16
const CHIP_SIZE := 11
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
	visible = int(_garrison.get("posts", 0)) > 0 or int(_garrison.get("present", 0)) > 0
	_start_animation()


func garrison() -> Dictionary:
	return _garrison


func _shown_ratio() -> float:
	var target := clampf(float(_garrison.get("ratio", 0.0)), 0.0, 1.0)
	if _from_ratio <= 0.0:
		return target
	return lerpf(_from_ratio, target, _blend)


func _draw() -> void:
	if not visible:
		return
	var posts := int(_garrison.get("posts", 0))
	var present := int(_garrison.get("present", 0))
	var w := size.x
	var readout := "%s / %s" % [_count(present), _count(posts)] if posts > 0 \
		else _count(present)
	_text(Vector2(0.0, 16.0), "在驻", LABEL_SIZE, UITokens.DOSSIER_INK_MUTED)
	_text(Vector2(w - READOUT_WIDTH, 17.0), readout, READOUT_SIZE,
		UITokens.DOSSIER_INK, "numeral", HORIZONTAL_ALIGNMENT_RIGHT, READOUT_WIDTH)
	_draw_chips(w - READOUT_WIDTH - 10.0, 16.0)
	var track := Rect2(Vector2(0.0, 30.0), Vector2(w, BAR_HEIGHT))
	MilitaryPaperStyle.paper_bar(self, track, UITokens.DOSSIER_TRACK, 3)
	if posts > 0:
		var fill := clampf(_shown_ratio() * (_grow if _has_grown else 1.0), 0.0, 1.0)
		var fill_width := w * fill
		if fill_width > 1.0:
			var color := UITokens.DOSSIER_VERDIGRIS
			if fill < 0.35:
				color = UITokens.DOSSIER_OXBLOOD
			elif fill < 0.7:
				color = UITokens.DOSSIER_BRASS
			MilitaryPaperStyle.paper_bar(self,
				Rect2(track.position, Vector2(fill_width, BAR_HEIGHT)), color, 5)


## 状态签从右往左排：征召中 → 暂停 → 失修 → 被占领。只画真的成立的那几个。
func _draw_chips(right_x: float, baseline: float) -> void:
	var chips: Array = []
	var pending := int(_garrison.get("pending", 0))
	if pending > 0:
		chips.append({"text": "征召 %s" % _count(pending), "color": UITokens.DOSSIER_BRASS,
			"icon": &"action.add"})
	if bool(_garrison.get("paused", false)):
		chips.append({"text": "暂停", "color": UITokens.DOSSIER_BRASS,
			"icon": &"action.pause"})
	if bool(_garrison.get("disrepair", false)):
		chips.append({"text": "失修", "color": UITokens.DOSSIER_OXBLOOD,
			"icon": &"status.warning"})
	if bool(_garrison.get("occupied", false)):
		chips.append({"text": "占领", "color": UITokens.DOSSIER_OXBLOOD,
			"icon": &""})
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
