extends Control
class_name DossierChart

## 卷宗自绘图表的公共基类：统一字体、墨色与两段动效。
## - 首次拿到数据时整体“生长”一次（GROW_SECONDS）；
## - 之后数值变化只做 ANIM_MED 的补间，不重建节点、不重新生长。

const GROW_SECONDS := 0.32

var _grow := 0.0
var _blend := 1.0
var _has_grown := false
var _grow_tween: Tween
var _blend_tween: Tween
var _bar_style: StyleBoxFlat


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	focus_mode = Control.FOCUS_NONE


## 子类在 set_data 末尾调用：首帧生长，之后只补间。
func _start_animation() -> void:
	if not _has_grown:
		_has_grown = true
		_grow = 0.0
		_blend = 1.0
		if not is_inside_tree():
			_grow = 1.0
			queue_redraw()
			return
		if _grow_tween != null and _grow_tween.is_valid():
			_grow_tween.kill()
		_grow_tween = create_tween()
		_grow_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_grow_tween.tween_method(_set_grow, 0.0, 1.0, GROW_SECONDS)
		return
	_blend = 0.0
	if not is_inside_tree():
		_blend = 1.0
		queue_redraw()
		return
	if _blend_tween != null and _blend_tween.is_valid():
		_blend_tween.kill()
	_blend_tween = create_tween()
	_blend_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_blend_tween.tween_method(_set_blend, 0.0, 1.0, UITokens.ANIM_MED)


## 让下一次 set_data 重新播放生长动画（章节首次进入时由外壳调用）。
func replay_growth() -> void:
	_has_grown = false


func _set_grow(value: float) -> void:
	_grow = value
	queue_redraw()


func _set_blend(value: float) -> void:
	_blend = value
	queue_redraw()


static func _blend_arrays(from: PackedFloat32Array, to: PackedFloat32Array,
		t: float) -> PackedFloat32Array:
	if from.size() != to.size() or t >= 1.0:
		return to
	var out := PackedFloat32Array()
	out.resize(to.size())
	for i in range(to.size()):
		out[i] = lerpf(from[i], to[i], t)
	return out


func _font(kind: String = "sans") -> Font:
	return UITokens.dossier_font(kind)


func _text(position_value: Vector2, text: String, size_px: int, color: Color,
		kind: String = "sans", align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT,
		width: float = -1.0) -> void:
	draw_string(_font(kind), position_value, text, align, width, size_px, color)


func _text_width(text: String, size_px: int, kind: String = "sans") -> float:
	return _font(kind).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px).x


## 把超宽文字截成“……”，用于固定列宽的账簿单元格。
func _fit_text(text: String, size_px: int, max_width: float, kind: String = "sans") -> String:
	if max_width <= 0.0 or _text_width(text, size_px, kind) <= max_width:
		return text
	var out := text
	while out.length() > 1 and _text_width(out + "…", size_px, kind) > max_width:
		out = out.substr(0, out.length() - 1)
	return out + "…"


## 语义图标画进 rect：有位图用位图，否则用 Font Awesome 字形居中。
func _icon(key: StringName, rect: Rect2, color: Color) -> void:
	if key == &"":
		return
	var texture := IconCatalog.texture_for_key(key)
	if texture != null:
		draw_texture_rect(texture, rect, false, color)
		return
	var glyph := IconCatalog.glyph_for_key(key)
	if glyph.is_empty():
		return
	var glyph_size := int(round(minf(rect.size.x, rect.size.y) * 0.86))
	var extent := IconCatalog.FONT_AWESOME.get_string_size(glyph, HORIZONTAL_ALIGNMENT_LEFT,
		-1.0, glyph_size)
	var ascent := IconCatalog.FONT_AWESOME.get_ascent(glyph_size)
	var descent := IconCatalog.FONT_AWESOME.get_descent(glyph_size)
	var baseline := Vector2(rect.get_center().x - extent.x * 0.5,
		rect.get_center().y + (ascent - descent) * 0.5)
	draw_string(IconCatalog.FONT_AWESOME, baseline, glyph, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
		glyph_size, color)


## StyleBoxFlat 在 draw 时立即生成几何，所以复用同一实例是安全的。
func _rounded_bar(rect: Rect2, color: Color, radius: float = 2.0) -> void:
	if rect.size.x <= 0.5 or rect.size.y <= 0.5:
		return
	if _bar_style == null:
		_bar_style = StyleBoxFlat.new()
		_bar_style.anti_aliasing = true
	_bar_style.bg_color = color
	_bar_style.set_corner_radius_all(int(minf(radius, rect.size.y * 0.5)))
	draw_style_box(_bar_style, rect)
