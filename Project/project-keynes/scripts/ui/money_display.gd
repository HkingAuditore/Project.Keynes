class_name MoneyDisplay
extends RefCounted

## 货币单位的唯一图形来源。
##
## 玩家界面上不再出现「¥ / ￥ / $ / 货币 / 元」这类单位记号：数值只写数字本体，
## 单位一律用 assets/ui/country_status/Gold.png 这张纸贴金币画在数字左边。
## 顶栏国库纸签（player_top_bar.tscn 的 Row/Icon + TreasuryValue）就是这套排法的
## 原型，这里把它抽成公共入口，其余面板照着用。
##
## 三种联排方式（对应项目里已有的三种渲染层）：
## 1. 容器行：make_icon() 造一个 TextureRect，塞进 HBoxContainer 数值的左边；
##    用 apply_icon() 让图标高度跟着字号走（HUD 纸签、税率编辑器走这条）。
## 2. 自绘图表：draw_on_baseline() 按文字基线画图标并返回占位宽度；
##    DossierChart 已封装成 _money_text() / _money_text_right() / _mixed_line()。
## 3. 富文本：bbcode() 给 RichTextLabel 的 [img] 用，可内联进整句说明文字。
##
## 图标本身是手绘纸贴，带一圈纸边，所以永远保持原色（modulate = 白），
## 不要按语义色染色——染过的金币会变成污点。

const ICON_PATH := "res://assets/ui/country_status/Gold.png"
const ICON: Texture2D = preload("res://assets/ui/country_status/Gold.png")

## 下拉项 / 菜单用的 24px 变体（由 Gold.png 用 LANCZOS 缩出）。
## 必须用小图：OptionButton 的 item 图标按**原生像素**参与最小尺寸计算，
## 直接塞 1024×1024 的 Gold.png 会让下拉按钮的最小尺寸变成 1100×1032，
## 整张税额卡片被撑成一张巨型纸，界面直接废掉。
const MENU_ICON: Texture2D = \
	preload("res://assets/ui/country_status/Gold_Menu24.png")

## 图标边长相对字号的倍率：字 12 → 图标 13，字 24 → 图标 25。
## 图标的可见金币只占画布约七成（外圈是纸边），所以取 1.05 倍时
## 金币直径正好贴着数字的cap height；再大就会压过数字本身。
const ICON_TO_FONT := 1.05
## 图标与数字之间的间距（相对字号）。
const GAP_TO_FONT := 0.24
## 图例里 11px 的字也要看清那枚金币，所以下限比 10px 抬高一点。
## Gold.png 已开 mipmap，缩到 12px 也不会抖。
const MIN_ICON_SIZE := 12.0

## _mixed_line() 的混排标记：runs 里出现这个值就画一枚金币。
const MONEY := &"money"

## UI 文本里出现过的货币单位记号。strip_unit() 把它们从数值串上摘掉；
## 只对「数值 + 单位」的串用，别拿它去处理「商品货币与集市」这类概念词。
const UNIT_TOKENS: Array[String] = ["货币单位", "货币", "¥", "￥", "$", "元"]
const SIGN_TOKENS: Array[String] = ["+", "-", "−"]


## 字号 → 图标边长。取整保证同一字号下所有金币像素级对齐。
static func icon_size(font_size: int) -> float:
	return maxf(MIN_ICON_SIZE, roundf(float(maxi(1, font_size)) * ICON_TO_FONT))


## 字号 → 图标与数字之间的间距。
static func gap(font_size: int) -> float:
	return maxf(1.0, roundf(float(maxi(1, font_size)) * GAP_TO_FONT))


## 字号 → 图标 + 间距占掉的横向宽度（排版时从可用宽度里先扣掉这一份）。
static func slot_width(font_size: int) -> float:
	return icon_size(font_size) + gap(font_size)


## 摘掉数值串上的货币单位记号，保留符号位： "+¥61" → "+61"，"12 货币" → "12"。
## 返回值永远是「能直接排版、不含单位」的数值文本。
static func strip_unit(text: String) -> String:
	var out := text.strip_edges()
	if out.is_empty():
		return out
	var sign := ""
	if not out.is_empty() and SIGN_TOKENS.has(out.substr(0, 1)):
		sign = out.substr(0, 1)
		out = out.substr(1).strip_edges()
	var stripped := true
	while stripped:
		stripped = false
		for token: String in UNIT_TOKENS:
			if out.begins_with(token):
				out = out.substr(token.length()).strip_edges()
				stripped = true
			if out.ends_with(token):
				out = out.substr(0, out.length() - token.length()).strip_edges()
				stripped = true
	return sign + out


## 这段文本里还留着货币单位记号吗？（迁移期自检用，UI 里不该再有 true）
static func has_unit(text: String) -> bool:
	return strip_unit(text) != String(text).strip_edges()


## 按文字基线画一枚金币，返回它连同间距占掉的宽度。
## 竖直方向按字号 ascent 居中，所以不同字号的图标都能和数字腰线对齐。
static func draw_on_baseline(canvas: CanvasItem, baseline_left: Vector2, font_size: int,
		font: Font, modulate: Color = Color.WHITE) -> float:
	if canvas == null:
		return 0.0
	var side := icon_size(font_size)
	var ascent := float(font_size) * 0.75
	if font != null:
		ascent = font.get_ascent(font_size)
	var top := baseline_left.y - ascent * 0.5 - side * 0.5
	canvas.draw_texture_rect(ICON, Rect2(Vector2(baseline_left.x, top), Vector2(side, side)),
		false, modulate)
	return side + gap(font_size)


## RichTextLabel 版本：把金币内联进整句说明。size 用字号推，和旁边文字同高。
static func bbcode(font_size: int) -> String:
	var side := int(icon_size(font_size))
	return "[img=%dx%d]%s[/img]" % [side, side, ICON_PATH]


## 富文本「金币 + 数值」：单位在前、数字在后，与自绘图表同一套读法。
static func bbcode_value(text: String, font_size: int) -> String:
	return "%s %s" % [bbcode(font_size), strip_unit(text)]


## 容器行版本：场景化的货币图标（`scenes/ui/money_icon.tscn`）。
## 玩家界面不允许脚本运行时 new 出 Control（见 tests/ui/ui_scene_structure_test.gd），
## 所以「图标 + 数值」这类行一律实例化这个场景，再用 apply_icon() 对字号。
const ICON_SCENE := "res://scenes/ui/money_icon.tscn"


## 把场景里预置的 TextureRect 配成货币图标：贴图、尺寸、竖直居中。
static func apply_icon(icon: TextureRect, font_size: int) -> void:
	if icon == null:
		return
	icon.texture = ICON
	icon.modulate = Color.WHITE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var side := icon_size(font_size)
	icon.custom_minimum_size = Vector2(side, side)
