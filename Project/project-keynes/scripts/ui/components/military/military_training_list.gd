extends DossierChart

## 军事页的「本地训练」行：目标兵种、人数、手绘进度、剩余天数。
## 进度条与驻军条同一种纸面画法（MilitaryPaperStyle.paper_bar），首帧生长一次。

const TouchUI := preload("res://scripts/ui/touch_ui.gd")
const ROW_HEIGHT := 36.0
const NAME_SIZE := 13
const COUNT_SIZE := 13
const META_SIZE := 11
const BAR_HEIGHT := 6.0
const META_WIDTH := 62.0

var _rows: Array = []


func _init() -> void:
	super()
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func set_rows(rows: Array) -> void:
	_rows = rows
	custom_minimum_size = Vector2(0.0, _row_height() * float(_rows.size()))
	visible = not _rows.is_empty()
	_start_animation()


func row_count() -> int:
	return _rows.size()


func _row_height() -> float:
	return maxf(ROW_HEIGHT, TouchUI.dense_units())


func _draw() -> void:
	var w := size.x
	var row_height := _row_height()
	for index in range(_rows.size()):
		var row: Dictionary = _rows[index]
		var top := row_height * float(index)
		var baseline := top + 16.0
		var icon: StringName = StringName(row.get("icon", ""))
		if icon != &"":
			IconCatalog.draw_icon(self, icon, Rect2(Vector2(0.0, top + 3.0),
				Vector2(18.0, 18.0)))
		var text_x := 23.0
		# 来源职业不会改变玩家的下一步操作；只显示训练目标，给人数、进度和
		# 剩余时间留出空间，避免把一行变成解释性句子。
		var label := String(row.get("to", ""))
		_text(Vector2(text_x, baseline), _fit_text(label, NAME_SIZE, w - text_x - 96.0),
			NAME_SIZE, UITokens.DOSSIER_INK_SOFT, "sans_strong")
		if bool(row.get("foreign", false)):
			_text(Vector2(w - 160.0, baseline - 1.0), "外", META_SIZE,
				UITokens.DOSSIER_OXBLOOD, "sans_strong")
		var count := UITokens.format_compact_number_cn(float(row.get("count", 0)), 1)
		_text(Vector2(w - 74.0, baseline), count, COUNT_SIZE, UITokens.DOSSIER_INK,
			"numeral", HORIZONTAL_ALIGNMENT_RIGHT, 74.0)
		var bar_top := top + 22.0
		var track := Rect2(Vector2(text_x, bar_top),
			Vector2(maxf(24.0, w - text_x - META_WIDTH - 8.0), BAR_HEIGHT))
		MilitaryPaperStyle.paper_bar(self, track, UITokens.DOSSIER_TRACK, 3)
		var fill := clampf(float(row.get("progress", 0.0)), 0.0, 1.0) \
			* (_grow if _has_grown else 1.0)
		if fill > 0.0:
			MilitaryPaperStyle.paper_bar(self,
				Rect2(track.position, Vector2(track.size.x * fill, BAR_HEIGHT)),
				UITokens.DOSSIER_BRASS, 5)
		var remaining := int(row.get("remaining_days", 0))
		if remaining > 0:
			_text(Vector2(w - META_WIDTH, bar_top + BAR_HEIGHT + 1.0),
				"剩 %d 日" % remaining, META_SIZE, UITokens.DOSSIER_INK_MUTED, "sans",
				HORIZONTAL_ALIGNMENT_RIGHT, META_WIDTH)
