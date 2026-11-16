extends DossierChart
class_name CohortUnrestStrip

## 阶层行下沿的民情条：「阶段名 + 四级阶梯 + 组织度」，画在行按钮内部，
## 与阶层名同属一个点击热区。
## 阶梯固定四格（不满 / 抗议 / 示威 / 叛乱），点亮格数即当前阶段，
## 量程自带、不需要另写分母。数据为空时整条隐藏。

## 行按钮为它让出的额外高度（CohortList 据此加高按钮、上移表头）。
const STRIP_HEIGHT := 20.0
## 与阶层行名称列对齐：行内边距 7 + 职业图标 26 + 间距 8。
const LEAD_INDENT := 41.0
const RIGHT_INSET := 7.0
const STEP_WIDTH := 16.0
const STEP_HEIGHT := 6.0
const STEP_GAP := 3.0
const FONT_PX := 14

var _data: Dictionary = {}


func set_unrest(data: Dictionary) -> void:
	_data = data.duplicate()
	visible = not _data.is_empty()
	tooltip_text = String(_data.get("tooltip", ""))
	if visible:
		_start_animation()
	else:
		queue_redraw()


func _draw() -> void:
	if _data.is_empty():
		return
	var stage := clampi(int(_data.get("stage", 0)), 0, MobilizationCategoryModel.LADDER_STEPS)
	var ink := InspectorMeterList.fill_color(_data.get("accent", UITokens.ACCENT))
	var mid := size.y * 0.5
	var baseline := mid + 5.0
	var x := LEAD_INDENT
	var label := String(_data.get("stage_label", ""))
	_text(Vector2(x, baseline), label, FONT_PX, ink, "sans_strong")
	x += maxf(_text_width("示威", FONT_PX, "sans_strong"),
		_text_width(label, FONT_PX, "sans_strong")) + 8.0
	var grow := _grow if _has_grown else 1.0
	for i in range(MobilizationCategoryModel.LADDER_STEPS):
		var rect := Rect2(Vector2(x, mid - STEP_HEIGHT * 0.5), Vector2(STEP_WIDTH, STEP_HEIGHT))
		_rounded_bar(rect, UITokens.DOSSIER_TRACK, 2.0)
		if i < stage:
			var fill := clampf(grow * float(stage) - float(i), 0.0, 1.0)
			_rounded_bar(Rect2(rect.position, Vector2(rect.size.x * fill, rect.size.y)), ink, 2.0)
		x += STEP_WIDTH + STEP_GAP
	var readout := "组织度 %s" % String(_data.get("organization_text", ""))
	var right := size.x - RIGHT_INSET
	_text(Vector2(right - _text_width(readout, FONT_PX), baseline), readout,
		FONT_PX, UITokens.DOSSIER_INK_MUTED)
