extends Control
class_name AnnualRunningHead

## 页眉运行头。
## 不是一条横栏，而是一片从纸色到透明的竖直渐变——内容滚到它下面时被纸"吃掉"，
## 看不到任何分割线。左边是本年纪事，右边是当前章节，切章时交叉淡入。
##
## 渐变本身在 _veil（子节点 + annual_paper_veil.gdshader）里画，因为要让它的
## 左右两端跟着撕口轮廓收边；父节点的 _draw() 只负责文字，落在版心里。

const VEIL_SHADER := preload("res://shaders/ui/annual_paper_veil.gdshader")

var _paper: Color = UITokens.CHRONICLE_SHEET_LIGHT
var _ink: Color = UITokens.CHRONICLE_MUTED
var _left := ""
var _right := ""
var _flip := false
var _inset := 0.0
var _veil: ColorRect
var _veil_material: ShaderMaterial


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size.y = AnnualReportTokens.RUNNING_HEAD_HEIGHT
	# show_behind_parent：孩子先画，父节点 _draw() 的文字后画，文字才不会被渐变糊住。
	_veil = ColorRect.new()
	_veil.name = "Veil"
	_veil.show_behind_parent = true
	_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_veil.color = Color(1.0, 1.0, 1.0, 1.0)
	_veil_material = ShaderMaterial.new()
	_veil_material.shader = VEIL_SHADER
	_veil_material.set_shader_parameter("paper_color", _paper)
	_veil.material = _veil_material
	add_child(_veil)
	_veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_texts(left: String, right: String) -> void:
	_left = left
	_right = right
	queue_redraw()


## 文字要落进纸的版心，渐变仍然是整纸宽 —— 否则纸缘会出现一条竖直切口。
func set_inset(value: float) -> void:
	_inset = value
	queue_redraw()


func set_ink(color: Color) -> void:
	_ink = color
	queue_redraw()


## 翻过来当页脚遮罩用：渐变自下而上，文字不画。
func set_flipped(value: bool) -> void:
	_flip = value
	if _veil_material != null:
		_veil_material.set_shader_parameter("flip", 1.0 if _flip else 0.0)
	queue_redraw()


## 挂上撕口蒙版，渐变的左右两端就会跟着纸缘收边。
func set_paper_mask(texture: Texture2D) -> void:
	if _veil_material == null:
		return
	_veil_material.set_shader_parameter("paper_mask_tex", texture)
	_veil_material.set_shader_parameter("has_mask", 1.0 if texture != null else 0.0)


## mapping: xy = 本节点在蒙版里的原点比例，zw = 缩放比例。
func set_mask(mapping: Vector4) -> void:
	if _veil_material == null:
		return
	_veil_material.set_shader_parameter("mask_uv_rect", mapping)


func veil_material() -> ShaderMaterial:
	return _veil_material


func _draw() -> void:
	if _flip:
		return
	var h: float = size.y
	var w: float = size.x
	var font := UITokens.annual_font("label")
	var muted := Color(_ink.r, _ink.g, _ink.b, 0.92)
	var left_edge: float = _inset
	var right_edge: float = w - _inset
	if not _left.is_empty():
		draw_string(font, Vector2(left_edge, h - 14.0), _left, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, muted)
	if not _right.is_empty():
		var width: float = font.get_string_size(_right, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13).x
		draw_string(font, Vector2(right_edge - width, h - 14.0), _right, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13,
			UITokens.CHRONICLE_PENCIL_RED)
	# A doubled graphite mark echoes the visible pencil pressure in the icon set.
	draw_line(Vector2(left_edge, h - 5.0), Vector2(left_edge + minf(44.0, w - _inset * 2.0), h - 5.0),
		Color(_ink.r, _ink.g, _ink.b, 0.42), 2.0, true)
