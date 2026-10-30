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


## ── 货币读数 ────────────────────────────────────────────────────────────
## 金额一律画成「金币图标 + 数字」，不再拼 ¥ 之类的单位记号（见 MoneyDisplay）。
## 三件套：_money_text 从基线左端往右画，_money_text_right 让整段右边缘对齐，
## _money_width 先量宽度用来排版（对齐、截断、算留白都靠它）。

## 从 position_value（文字基线左端）开始画「金币 + 数值」，返回总宽度。
func _money_text(position_value: Vector2, text: String, size_px: int, color: Color,
		kind: String = "sans") -> float:
	var shown := MoneyDisplay.strip_unit(text)
	var offset := MoneyDisplay.draw_on_baseline(self, position_value, size_px, _font(kind))
	draw_string(_font(kind), Vector2(position_value.x + offset, position_value.y), shown,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, color)
	return offset + _text_width(shown, size_px, kind)


## 右对齐：整段（图标 + 数字）的右边缘落在 right_x 上。
func _money_text_right(right_x: float, baseline_y: float, text: String, size_px: int,
		color: Color, kind: String = "sans") -> float:
	var width := _money_width(text, size_px, kind)
	_money_text(Vector2(right_x - width, baseline_y), text, size_px, color, kind)
	return width


## 整段（图标 + 数字）的宽度，用来在排版前预留位置。
func _money_width(text: String, size_px: int, kind: String = "sans") -> float:
	return MoneyDisplay.slot_width(size_px) \
		+ _text_width(MoneyDisplay.strip_unit(text), size_px, kind)


## 一行混排：runs 里 String 是普通文字，MoneyDisplay.MONEY 标记处插一枚金币。
## 「人均累计 [金币]12.3万 · 日均 [金币]4.5万」这种整句靠它拼，不用把单位写成字。
func _mixed_line(position_value: Vector2, runs: Array, size_px: int, color: Color,
		kind: String = "sans") -> float:
	var x := position_value.x
	for run in runs:
		if typeof(run) == TYPE_STRING_NAME and String(run) == String(MoneyDisplay.MONEY):
			x += MoneyDisplay.draw_on_baseline(self, Vector2(x, position_value.y),
				size_px, _font(kind))
			continue
		var piece := String(run)
		if piece.is_empty():
			continue
		draw_string(_font(kind), Vector2(x, position_value.y), piece,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, size_px, color)
		x += _text_width(piece, size_px, kind)
	return x - position_value.x


## 混排整行的宽度：排版前先量，决定要不要换行或降字号。
func _mixed_width(runs: Array, size_px: int, kind: String = "sans") -> float:
	var width := 0.0
	for run in runs:
		if typeof(run) == TYPE_STRING_NAME and String(run) == String(MoneyDisplay.MONEY):
			width += MoneyDisplay.slot_width(size_px)
		else:
			width += _text_width(String(run), size_px, kind)
	return width


## 把超宽文字截成“……”，用于固定列宽的账簿单元格。
func _fit_text(text: String, size_px: int, max_width: float, kind: String = "sans") -> String:
	if max_width <= 0.0 or _text_width(text, size_px, kind) <= max_width:
		return text
	var out := text
	while out.length() > 1 and _text_width(out + "…", size_px, kind) > max_width:
		out = out.substr(0, out.length() - 1)
	return out + "…"


## 在统一入口等比绘制彩铅纸贴，保留原色与状态透明度。
func _icon(key: StringName, rect: Rect2, color: Color) -> void:
	IconCatalog.draw_icon(self, key, rect, color.a)


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
