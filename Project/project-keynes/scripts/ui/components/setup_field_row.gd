extends BoxContainer
class_name SetupFieldRow

## 并排排版时标签列的固定宽度（与 setup_field_row.tscn 里 LabelBox 的
## custom_minimum_size 保持一致）。world_setup.gd 用它推算双栏的最小视口宽度。
const LABEL_COLUMN_WIDTH := 320.0
## 并排时标签列与控件区的间隔（与 setup_field_row.tscn 的 separation 一致）。
const INLINE_SEPARATION := 14.0


## [param stacked] 把标签与控件改成上下排。只在视口放不下「标签列 + 控件」
## 并排时传 true（见 world_setup.gd 的 _rows_need_stacking）；
## [param mobile_layout] 只管字号/命中区尺度，与排版方向无关。
func configure(label_text: String, hint_text: String, control: Control,
		mobile_layout: bool, stacked: bool = false) -> void:
	add_to_group("world_setup_field_rows")
	set_mobile_layout(mobile_layout, stacked)
	var label_box := get_node("LabelBox") as VBoxContainer
	var title_label := get_node("LabelBox/Title") as Label
	var hint_label := get_node("LabelBox/Hint") as Label
	var control_host := get_node("ControlHost") as MarginContainer
	title_label.text = label_text
	title_label.add_theme_font_size_override("font_size", 18 if mobile_layout else 16)
	hint_label.text = hint_text
	hint_label.visible = not hint_text.is_empty()
	hint_label.add_theme_font_size_override("font_size", 14 if mobile_layout else 12)
	label_box.tooltip_text = hint_text
	control.tooltip_text = hint_text
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	control_host.add_child(control)


func set_mobile_layout(mobile_layout: bool, stacked: bool = false) -> void:
	vertical = stacked
	add_theme_constant_override("separation", 6 if stacked else INLINE_SEPARATION)
	var label_box := get_node("LabelBox") as VBoxContainer
	# 标签列在桌面是定宽 320（hint 一起对齐），但并排时这 320 就是整列的最小宽度：
	# 视口不够宽时它会把父级撑到比屏幕还宽，标签被推到左边界之外。上下排时归零。
	label_box.custom_minimum_size.x = 0.0 if stacked else LABEL_COLUMN_WIDTH
	(get_node("LabelBox/Title") as Label).add_theme_font_size_override(
		"font_size", 18 if mobile_layout else 16)
	(get_node("LabelBox/Hint") as Label).add_theme_font_size_override(
		"font_size", 14 if mobile_layout else 12)
