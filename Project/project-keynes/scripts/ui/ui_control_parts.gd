extends RefCounted
class_name UIControlParts

## Shared scene-backed UI primitives. Callers configure data and arrange instances;
## the editor-readable scenes own the default node types and properties.

const BUTTON = preload("res://scenes/ui/parts/button.tscn")
const CENTER_CONTAINER = preload("res://scenes/ui/parts/center_container.tscn")
const CHECK_BUTTON = preload("res://scenes/ui/parts/check_button.tscn")
const CHECK_BOX = preload("res://scenes/ui/parts/check_box.tscn")
const COLOR_RECT = preload("res://scenes/ui/parts/color_rect.tscn")
const CONTROL = preload("res://scenes/ui/parts/control.tscn")
const GRID_CONTAINER = preload("res://scenes/ui/parts/grid_container.tscn")
const H_BOX_CONTAINER = preload("res://scenes/ui/parts/h_box_container.tscn")
const H_SLIDER = preload("res://scenes/ui/parts/h_slider.tscn")
const LABEL = preload("res://scenes/ui/parts/label.tscn")
const LINE_EDIT = preload("res://scenes/ui/parts/line_edit.tscn")
const MARGIN_CONTAINER = preload("res://scenes/ui/parts/margin_container.tscn")
const OPTION_BUTTON = preload("res://scenes/ui/parts/option_button.tscn")
const PANEL_CONTAINER = preload("res://scenes/ui/parts/panel_container.tscn")
const PROGRESS_BAR = preload("res://scenes/ui/parts/progress_bar.tscn")
const RICH_TEXT_LABEL = preload("res://scenes/ui/parts/rich_text_label.tscn")
const SCROLL_CONTAINER = preload("res://scenes/ui/parts/scroll_container.tscn")
const TEXTURE_RECT = preload("res://scenes/ui/parts/texture_rect.tscn")
const V_BOX_CONTAINER = preload("res://scenes/ui/parts/v_box_container.tscn")


static func button() -> Button:
	return BUTTON.instantiate() as Button


static func center_container() -> CenterContainer:
	return CENTER_CONTAINER.instantiate() as CenterContainer


static func check_box() -> CheckBox:
	return CHECK_BOX.instantiate() as CheckBox


static func color_rect() -> ColorRect:
	return COLOR_RECT.instantiate() as ColorRect


static func control() -> Control:
	return CONTROL.instantiate() as Control


static func grid_container() -> GridContainer:
	return GRID_CONTAINER.instantiate() as GridContainer


static func h_box_container() -> HBoxContainer:
	return H_BOX_CONTAINER.instantiate() as HBoxContainer


static func h_slider() -> HSlider:
	return H_SLIDER.instantiate() as HSlider


static func label() -> Label:
	return LABEL.instantiate() as Label


static func line_edit() -> LineEdit:
	return LINE_EDIT.instantiate() as LineEdit


static func margin_container() -> MarginContainer:
	return MARGIN_CONTAINER.instantiate() as MarginContainer


static func option_button() -> OptionButton:
	return OPTION_BUTTON.instantiate() as OptionButton


static func panel_container() -> PanelContainer:
	return PANEL_CONTAINER.instantiate() as PanelContainer


static func progress_bar() -> ProgressBar:
	return PROGRESS_BAR.instantiate() as ProgressBar


static func rich_text_label() -> RichTextLabel:
	return RICH_TEXT_LABEL.instantiate() as RichTextLabel


static func scroll_container() -> ScrollContainer:
	return SCROLL_CONTAINER.instantiate() as ScrollContainer


static func texture_rect() -> TextureRect:
	return TEXTURE_RECT.instantiate() as TextureRect


static func v_box_container() -> VBoxContainer:
	return V_BOX_CONTAINER.instantiate() as VBoxContainer


static func check_button() -> CheckButton:
	return CHECK_BUTTON.instantiate() as CheckButton
