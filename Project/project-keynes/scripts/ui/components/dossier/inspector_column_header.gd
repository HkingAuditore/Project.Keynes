extends DossierChart
class_name InspectorColumnHeader

## 卷宗名录列头：左侧名目，右侧若干固定宽列，与行场景右侧固定宽列对齐，
## 让行里的裸数字（人口、人均财富、利润……）有名可查。

const HEIGHT := 22.0

var lead := ""
## [{"text": String, "width": float}]，从左到右排列，右对齐贴在行尾。
var columns: Array = []
var lead_indent := 41.0
var right_inset := 7.0
var column_gap := 8.0


func _init() -> void:
	super()
	custom_minimum_size = Vector2(0.0, HEIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_columns(p_lead: String, p_columns: Array) -> void:
	lead = p_lead
	columns = p_columns.duplicate()
	queue_redraw()


func _draw() -> void:
	var baseline := HEIGHT - 7.0
	var color := UITokens.DOSSIER_INK_MUTED
	var right := size.x - right_inset
	for i in range(columns.size() - 1, -1, -1):
		var column: Dictionary = columns[i]
		var width := float(column.get("width", 60.0))
		_text(Vector2(right - width, baseline), _fit_text(String(column.get("text", "")), 11, width),
			11, color, "sans", HORIZONTAL_ALIGNMENT_RIGHT, width)
		right -= width + column_gap
	_text(Vector2(lead_indent, baseline), _fit_text(lead, 11, maxf(0.0, right - lead_indent)),
		11, color)
	draw_line(Vector2(0.0, HEIGHT - 0.5), Vector2(size.x, HEIGHT - 0.5),
		UITokens.DOSSIER_RULE_STRONG, 1.0)
