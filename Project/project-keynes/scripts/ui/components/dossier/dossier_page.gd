extends VBoxContainer
class_name DossierPage

## 卷宗章节页基类。章节节点全部来自 .tscn，refresh() 只改数据不建节点；
## 选中项保存在页面上，每日刷新后保持不变。

signal navigate_requested(chapter_id: String, payload: Dictionary)
signal scope_requested(cell: int)
signal locate_requested(cell: int)

@export var chapter_id := ""

var _narrow := false
var _layout_width := 0.0


func refresh(_vm: EconomyDossierViewModel, _filter = null) -> void:
	pass


## 由卷宗按视口宽度下发：narrow 为紧凑布局，width 供需要多档断点的章节使用。
func set_narrow(narrow: bool, width: float = 0.0) -> void:
	if narrow == _narrow and absf(width - _layout_width) < 1.0:
		return
	_narrow = narrow
	_layout_width = width
	_apply_narrow()


func focus_item(_item) -> void:
	pass


func _apply_narrow() -> void:
	pass


func _show_empty(label: Label, content: Control, text: String) -> void:
	label.text = text
	label.visible = not text.is_empty()
	if content != null:
		content.visible = text.is_empty()


static func money(value: float) -> String:
	return EconomyDossierViewModel.format_value(value, "money")


static func percent(value: float) -> String:
	return EconomyDossierViewModel.format_value(value, "percent")


static func count(value: float) -> String:
	return EconomyDossierViewModel.format_value(value, "count")


static func satisfaction_color(value: float) -> Color:
	if value >= 0.7:
		return UITokens.DOSSIER_VERDIGRIS
	if value >= 0.45:
		return UITokens.DOSSIER_BRASS
	return UITokens.DOSSIER_OXBLOOD
