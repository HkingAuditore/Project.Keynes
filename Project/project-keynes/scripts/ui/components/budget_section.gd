extends VBoxContainer
class_name BudgetSection

## 财政预算板块：一张摊开的羊皮纸。底边是撕过的毛边，左侧压一道语义色细条，
## 顶部装订线把标题和读数收在一起，正文挂到 Body 里。
##
## 自绘只做装饰，位置和高度完全交给 VBoxContainer/MarginContainer 决定，
## 所以任何分辨率下都不会因为画纸而把内容挤出容器。

const TouchUI = preload("res://scripts/ui/touch_ui.gd")

## 纸面四周留白（左、上、右、下）。撕边不占布局空间，画在纸面内侧。
const PAD_LEFT := 16.0
const PAD_TOP := 12.0
const PAD_RIGHT := 16.0
const PAD_BOTTOM := 15.0
## 撕边的锯齿深度与抖动幅度：太深像锯齿线，太浅看不出纸。
const TORN_DEPTH := 3.5
const EDGE_JITTER := 1.8
const EDGE_MIN_STEP := 26.0
const ACCENT_STRIP := 3.0

var _icon: IconBadge = null
var _title: Label = null
var _note: Label = null
var _value: Label = null
var _body: VBoxContainer = null
var _tone: Color = UITokens.DOSSIER_OXBLOOD
var _paper := UITokens.DOSSIER_PAPER
var _condensed := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("separation", 8)
	_build()


func _build() -> void:
	var pad := MarginContainer.new()
	pad.name = "Pad"
	pad.mouse_filter = Control.MOUSE_FILTER_PASS
	pad.add_theme_constant_override("margin_left", int(PAD_LEFT))
	pad.add_theme_constant_override("margin_top", int(PAD_TOP))
	pad.add_theme_constant_override("margin_right", int(PAD_RIGHT))
	pad.add_theme_constant_override("margin_bottom", int(PAD_BOTTOM))
	add_child(pad)
	var column := VBoxContainer.new()
	column.name = "Content"
	column.mouse_filter = Control.MOUSE_FILTER_PASS
	column.add_theme_constant_override("separation", 9)
	pad.add_child(column)
	var head := HBoxContainer.new()
	head.name = "Head"
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	head.add_theme_constant_override("separation", 8)
	column.add_child(head)
	var badge_host := Control.new()
	badge_host.name = "IconHost"
	badge_host.custom_minimum_size = Vector2(24.0, 24.0)
	badge_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(badge_host)
	_icon = IconBadge.new()
	_icon.name = "Icon"
	_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_host.add_child(_icon)
	_title = Label.new()
	_title.name = "Title"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title.add_theme_font_override("font", UITokens.dossier_font("sans_strong"))
	_title.add_theme_font_size_override("font_size", 17)
	_title.add_theme_color_override("font_color", UITokens.DOSSIER_INK)
	head.add_child(_title)
	_note = Label.new()
	_note.name = "Note"
	_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_note.add_theme_font_override("font", UITokens.dossier_font("sans"))
	_note.add_theme_font_size_override("font_size", 13)
	_note.add_theme_color_override("font_color", UITokens.DOSSIER_INK_MUTED)
	head.add_child(_note)
	var spacer := Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)
	_value = Label.new()
	_value.name = "Value"
	_value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_value.add_theme_font_override("font", UITokens.dossier_font("numeral"))
	_value.add_theme_font_size_override("font_size", 18)
	_value.add_theme_color_override("font_color", UITokens.DOSSIER_OXBLOOD)
	head.add_child(_value)
	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.mouse_filter = Control.MOUSE_FILTER_PASS
	_body.add_theme_constant_override("separation", 8)
	column.add_child(_body)


## semantic_key 走 IconCatalog；tone 只作用于图标与左侧细条，不铺满纸面。
func configure(title: String, semantic_key: StringName, tone: Color,
		note: String = "") -> void:
	_title.text = title
	_icon.set_semantic(semantic_key, tone)
	_tone = tone
	_note.text = note
	_note.visible = not note.is_empty()
	queue_redraw()


## 右上角读数：金额 / 份额 / 状态短句。空串即隐藏。
func set_value_text(text: String, warn: bool = false) -> void:
	_value.text = text
	_value.visible = not text.is_empty()
	_value.add_theme_color_override("font_color",
		UITokens.DOSSIER_OXBLOOD if warn else UITokens.DOSSIER_INK_SOFT)


func set_note_text(text: String) -> void:
	_note.text = text
	_note.visible = not text.is_empty()


## 折叠态：窄屏下收掉标题右侧的说明，把宽度让给读数。
func set_condensed(condensed: bool) -> void:
	_condensed = condensed
	_note.visible = not condensed and not _note.text.is_empty()


func body() -> VBoxContainer:
	return _body


func title_label() -> Label:
	return _title


func value_label() -> Label:
	return _value


func add_body_control(control: Control) -> void:
	_body.add_child(control)


func clear_body() -> void:
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()


func _draw() -> void:
	if size.x < 2.0 or size.y < 2.0:
		return
	var paper := _torn_polygon()
	# 纸张投影：撕过的纸边会翘起来，所以影子偏右下。
	var shadow := PackedVector2Array()
	for point in paper:
		shadow.append(point + Vector2(1.5, 2.0))
	draw_colored_polygon(shadow, Color(UITokens.DOSSIER_INK, 0.13))
	draw_colored_polygon(paper, _paper)
	# 左侧语义细条：只到撕边上方，避免盖住毛边。
	draw_rect(Rect2(0.0, 0.0, ACCENT_STRIP, maxf(0.0, size.y - TORN_DEPTH)),
		Color(_tone, 0.72))
	# 装订线：标题下方一道极淡的横向折痕。
	var rule_y := PAD_TOP + 24.0
	if rule_y < size.y - TORN_DEPTH - 6.0:
		draw_line(Vector2(ACCENT_STRIP + 6.0, rule_y), Vector2(size.x - 8.0, rule_y),
			UITokens.DOSSIER_RULE, 1.0)
	draw_polyline(_outline(paper), Color(UITokens.DOSSIER_OXBLOOD, 0.20), 1.0, true)


## 纸面轮廓：上、右两边是裁切直边，底边撕开，左边缘被色条压住。
func _torn_polygon() -> PackedVector2Array:
	var width := size.x
	var height := size.y
	var bottom := height - TORN_DEPTH
	var points := PackedVector2Array()
	points.append(Vector2(0.0, 0.0))
	points.append(Vector2(width, 0.0))
	points.append(Vector2(width, bottom))
	var steps := maxi(6, int(width / EDGE_MIN_STEP))
	var rng := RandomNumberGenerator.new()
	# 固定种子：同一块纸每次重绘都是同一条毛边，高速模拟下不抖。
	rng.seed = 0x9F31 + steps
	for index in range(steps):
		var t := 1.0 - float(index + 1) / float(steps + 1)
		var torn := TORN_DEPTH * rng.randf_range(0.35, 1.0)
		var jitter := rng.randf_range(-EDGE_JITTER, EDGE_JITTER)
		points.append(Vector2(width * t + jitter, bottom + torn))
	points.append(Vector2(0.0, bottom + TORN_DEPTH * 0.5))
	points.append(Vector2(0.0, 0.0))
	return points


func _outline(paper: PackedVector2Array) -> PackedVector2Array:
	var outline := PackedVector2Array()
	for point in paper:
		outline.append(point)
	return outline
