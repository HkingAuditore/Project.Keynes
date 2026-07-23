# map_layer_legend.gd
# 数据图层的紧凑图例（2026-07-23）。左下角，与该图层同色阶自绘。
#
# 连续量（海拔/温度/湿度/资源）：横向渐变条 + 端点标签（低/高、冷/暖、干/湿、少/多）。
# 矢量（风向/洋流）：色相环条（红→…→红 表方向）+ 端点标注。
# 离散量（地形/植被）：按 present 类别平铺色块（v1 不标类别名，后续补）。
#
# 数据来自 renderer.get_active_data_layer_legend()（overlay 烘焙 LUT 时一并算好）。

extends Control
class_name MapLayerLegend

const DataLayerPalette = preload("res://scripts/rendering/data_layer_palette.gd")
const UITokens = preload("res://scripts/ui/ui_tokens.gd")

var _layer_id: String = ""
var _source: Node = null
var _info: Dictionary = {}

func set_layer(layer_id: String, source: Node) -> void:
	_layer_id = layer_id
	_source = source
	_refresh_info()
	queue_redraw()

func clear() -> void:
	_layer_id = ""
	_info = {}
	queue_redraw()

# 由 GameUIManager 在拿到 renderer 后调用（图层已激活时同步刷新）。
func refresh_source(source: Node) -> void:
	_source = source
	if _layer_id != "":
		_refresh_info()
		queue_redraw()

func _refresh_info() -> void:
	if _source != null and _source.has_method("get_active_data_layer_legend"):
		_info = _source.get_active_data_layer_legend()
	else:
		_info = {}

func _draw() -> void:
	if _layer_id == "" or _info.is_empty():
		return
	var disp: String = _info.get("display_name", _layer_id)
	var kind: int = int(_info.get("kind", 0))
	var ramp: String = _info.get("ramp", "")
	var label_lo: String = _info.get("label_lo", "")
	var label_hi: String = _info.get("label_hi", "")

	var pad := 10.0
	var bar_x := pad
	var bar_y := 34.0
	var bar_w := size.x - pad * 2.0
	var bar_h := 14.0

	# 背景面板 + 边框
	draw_rect(Rect2(0.0, 0.0, size.x, size.y), UITokens.PANEL_BG, true, 8.0)
	draw_rect(Rect2(0.0, 0.0, size.x, size.y), UITokens.PANEL_BORDER, false, 8.0)
	# 标题
	draw_string(UITokens.UI_FONT, Vector2(pad, 22.0), disp,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SECTION, UITokens.TEXT_MAIN)

	match kind:
		DataLayerPalette.KIND_VECTOR:
			_draw_hue_bar(bar_x, bar_y, bar_w, bar_h, ramp)
			_draw_edge_labels(bar_x, bar_y + bar_h + 4.0, bar_w, label_lo, label_hi)
		DataLayerPalette.KIND_CATEGORICAL:
			_draw_categorical(bar_x, bar_y, bar_w, bar_h)
		_:
			_draw_gradient(bar_x, bar_y, bar_w, bar_h, ramp)
			_draw_edge_labels(bar_x, bar_y + bar_h + 4.0, bar_w, label_lo, label_hi)

func _draw_gradient(x: float, y: float, w: float, h: float, ramp: String) -> void:
	var steps := int(w)
	if steps < 2: steps = 2
	var dx := w / float(steps)
	for i in range(steps):
		var t := float(i) / float(steps - 1)
		var c := DataLayerPalette.ramp_for_id(ramp, t)
		draw_rect(Rect2(x + float(i) * dx, y, dx + 1.0, h), c, true)

func _draw_hue_bar(x: float, y: float, w: float, h: float, ramp: String) -> void:
	var steps := int(w)
	if steps < 2: steps = 2
	var dx := w / float(steps)
	for i in range(steps):
		var t := float(i) / float(steps - 1)
		var ang := TAU * t - PI
		var dir := Vector2(cos(ang), sin(ang))
		var c := DataLayerPalette.ramp_for_id(ramp, 0.0, dir, 1.0)
		draw_rect(Rect2(x + float(i) * dx, y, dx + 1.0, h), c, true)

func _draw_categorical(x: float, y: float, w: float, h: float) -> void:
	var cats: PackedColorArray = _info.get("categories", [])
	var names: PackedStringArray = _info.get("category_names", [])
	if cats.is_empty():
		return
	var n := cats.size()
	if n <= 0:
		return

	# 决定布局：≤6 类用横排色块+下方竖排标签；>6 类用两列紧凑网格
	var use_grid := n > 6
	var gap := 3.0
	var label_font_size := UITokens.FONT_SMALL

	if use_grid:
		var cols := 2
		var rows: int = int(ceil(float(n) / float(cols)))
		var sw := (w - gap * float(cols - 1)) / float(cols)
		sw = clampf(sw, 14.0, 28.0)
		var row_h := maxf(h + label_font_size + 4.0, 18.0)
		for i in range(n):
			var ci := i % cols
			var ri := i / cols
			var cx := x + float(ci) * (sw + gap)
			var cy := y + float(ri) * row_h
			var c := cats[i] as Color
			draw_rect(Rect2(cx, cy, sw, h), c, true)
			if i < names.size():
				draw_string(UITokens.UI_FONT, Vector2(cx, cy + h + label_font_size + 1.0),
					names[i], HORIZONTAL_ALIGNMENT_LEFT, sw, label_font_size, UITokens.TEXT_MUTED)
	else:
		var sw := (w - gap * float(n - 1)) / float(n)
		sw = clampf(sw, 14.0, 28.0)
		for i in range(n):
			var c := cats[i] as Color
			draw_rect(Rect2(x + float(i) * (sw + gap), y, sw, h), c, true)
		# 标签行：在色块下方横排（截断过长名称）
		if not names.is_empty():
			var lx := x
			for i in range(n):
				if i >= names.size():
					break
				var txt := names[i]
				var tw := UITokens.UI_FONT.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_font_size).x
				var avail := sw
				if tw > avail + 2.0:
					txt = txt.left(int(avail / label_font_size * 2.0)) + "…"
					tw = avail
				draw_string(UITokens.UI_FONT, Vector2(lx + (sw - tw) * 0.5, y + h + label_font_size + 1.0),
					txt, HORIZONTAL_ALIGNMENT_LEFT, -1.0, label_font_size, UITokens.TEXT_MUTED)
				lx += sw + gap

func _draw_edge_labels(x: float, y: float, w: float, lo: String, hi: String) -> void:
	if lo != "":
		draw_string(UITokens.UI_FONT, Vector2(x, y + 12.0), lo,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL, UITokens.TEXT_MUTED)
	if hi != "":
		var fs := UITokens.UI_FONT.get_string_size(hi, HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL)
		draw_string(UITokens.UI_FONT, Vector2(x + w - fs.x, y + 12.0), hi,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, UITokens.FONT_SMALL, UITokens.TEXT_MUTED)
