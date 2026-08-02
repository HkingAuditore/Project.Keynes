# overlay_legend.gd
# 可复用的 overlay 图例面板；具体屏幕位置由父 UI 决定，并与
# data_overlay.gdshader 共用同一套色带定义。
# 当 overlay_mode != NONE 时显示：
#   - 连续通道 (TEMPERATURE/PRECIPITATION/HUMIDITY/VEGETATION_VITALITY)：
#       通道名 + 横向 color ramp TextureRect + 两端数值标签 + 可选的选中指针
#   - 离散通道 (CLIMATE_ZONE/WEATHER)：
#       通道名 + 每档 色块 + 中文标签 的竖直列表
#
# 与 DebugConsole 解耦：legend 不直接监听控制台信号，而是由 main.gd 在
# `_apply_overlay_mode` 与 `_select_cell` 末尾主动调用 update_for_mode / update_pointer。
class_name OverlayLegend
extends PanelContainer

const LegendRowScene := preload("res://scenes/ui/overlay_legend_row.tscn")

# Ramp 纹理宽度；高度固定 12px
const RAMP_WIDTH: int = 168
const RAMP_HEIGHT: int = 12
const VECTOR_WHEEL_SIZE: int = 72

# 色带定义（与 data_overlay.gdshader 保持同步；新增色带时两边都改）
const DISCRETE_CLIMATE_COLORS: Array = [
	Color(0.95, 0.42, 0.28),
	Color(0.96, 0.75, 0.30),
	Color(0.40, 0.78, 0.45),
	Color(0.45, 0.72, 0.92),
	Color(0.92, 0.95, 1.00),
]
const DISCRETE_WEATHER_COLORS: Array = [
	Color(0.60, 0.60, 0.60),  # CLEAR 在图例里也展示为中性灰，与真实渲染（透明）区分
	Color(0.25, 0.55, 0.95),
	Color(0.55, 0.25, 0.85),
	Color(0.95, 0.97, 1.00),
	Color(0.82, 0.55, 0.28),
	Color(0.72, 0.78, 0.82),
	Color(0.98, 0.45, 0.20),
	Color(0.30, 0.35, 0.85),
]

# BIOME_GROUP 调色板（与 shader 的 BIOME_GROUP_COLORS 严格同步）
const DISCRETE_BIOME_GROUP_COLORS: Array = [
	Color(0.05, 0.18, 0.45),  # 0 深海/远海
	Color(0.85, 0.92, 0.98),  # 1 海冰
	Color(0.30, 0.65, 0.85),  # 2 海岸礁滩
	Color(0.20, 0.55, 0.70),  # 3 内陆水
	Color(0.65, 0.85, 0.45),  # 4 开阔陆面
	Color(0.20, 0.55, 0.25),  # 5 林地
	Color(0.50, 0.45, 0.38),  # 6 高地/山岭
	Color(0.92, 0.85, 0.45),  # 7 干旱荒漠
	Color(0.95, 0.97, 1.00),  # 8 寒带/冰雪
	Color(0.55, 0.55, 0.55),  # 9 未分类 fallback
]

# LANDFORM 调色板（与 shader 的 LANDFORM_COLORS 严格同步）
const DISCRETE_LANDFORM_COLORS: Array = [
	Color(0.05, 0.18, 0.45),  # 0 深海
	Color(0.30, 0.65, 0.85),  # 1 沿海/浅水
	Color(0.65, 0.85, 0.45),  # 2 平原
	Color(0.78, 0.62, 0.32),  # 3 丘陵
	Color(0.55, 0.40, 0.30),  # 4 山地
	Color(0.95, 0.97, 1.00),  # 5 冰雪
]

var _title_label: Label
var _icon_label: Label
var _hint_label: Label
var _ramp_rect: TextureRect

var _low_label: Label
var _high_label: Label
var _pointer: ColorRect         # 当前选中数值对应的色带位置指针（连续通道）
var _discrete_list: VBoxContainer   # 离散通道的色块列表
var _discrete_scroll: ScrollContainer
var _continuous_box: VBoxContainer  # 连续通道的整体容器（便于整体显隐）
# 方向型通道（WIND_DIR / OCEAN_CURRENT_DIR）专用容器：
#   ┌────────────┐  色环（hue wheel）：东=0°/红、南=90°/绿、西=180°/青、北=270°/紫
#   │  ●         │  + 当前选中 cell 的方向小箭头
#   └────────────┘
#   弱 ──── 强    亮度图例（同时强度也会编码到色环内圈）
var _vector_box: VBoxContainer
var _vector_wheel: TextureRect
var _vector_arrow: ColorRect
var _vector_intensity_ramp: TextureRect
var _vector_low_label: Label
var _vector_high_label: Label
var _current_mode: int = 0
var _last_pointer_value: float = -1.0   # NaN/未选中时隐藏指针

func _ready() -> void:
	_icon_label = get_node_or_null("Margin/Root/TitleRow/Icon") as Label
	_title_label = get_node_or_null("Margin/Root/TitleRow/Title") as Label
	_hint_label = get_node_or_null("Margin/Root/Hint") as Label
	_continuous_box = get_node_or_null("Margin/Root/Continuous") as VBoxContainer
	_ramp_rect = get_node_or_null("Margin/Root/Continuous/Ramp") as TextureRect
	_pointer = get_node_or_null("Margin/Root/Continuous/Ramp/Pointer") as ColorRect
	_low_label = get_node_or_null("Margin/Root/Continuous/Range/Low") as Label
	_high_label = get_node_or_null("Margin/Root/Continuous/Range/High") as Label
	_discrete_scroll = get_node_or_null("Margin/Root/DiscreteScroll") as ScrollContainer
	_discrete_list = get_node_or_null("Margin/Root/DiscreteScroll/DiscreteList") as VBoxContainer
	_vector_box = get_node_or_null("Margin/Root/Vector") as VBoxContainer
	_vector_wheel = get_node_or_null("Margin/Root/Vector/Wheel") as TextureRect
	_vector_arrow = get_node_or_null("Margin/Root/Vector/Wheel/Arrow") as ColorRect
	_vector_intensity_ramp = get_node_or_null("Margin/Root/Vector/IntensityRamp") as TextureRect
	_vector_low_label = get_node_or_null("Margin/Root/Vector/Range/Low") as Label
	_vector_high_label = get_node_or_null("Margin/Root/Vector/Range/High") as Label
	if _icon_label == null or _title_label == null or _hint_label == null \
			or _continuous_box == null or _ramp_rect == null or _pointer == null \
			or _low_label == null or _high_label == null or _discrete_scroll == null \
			or _discrete_list == null or _vector_box == null or _vector_wheel == null \
			or _vector_arrow == null or _vector_intensity_ramp == null \
			or _vector_low_label == null or _vector_high_label == null:
		push_error("OverlayLegend 必须通过 map_overlay_legend.tscn 实例化。")
		return
	_icon_label.add_theme_font_override("font", IconBadge.FA_SOLID_FONT)
	_icon_label.add_theme_font_size_override("font_size", 15)
	_icon_label.add_theme_color_override("font_color", UITokens.ACCENT)

# 主入口：切换通道（含 NONE 隐藏）。
func update_for_mode(
	mode: int,
	title_override: String = "",
	hint_override: String = "",
	icon_override: String = ""
) -> void:
	_current_mode = mode
	if mode == OverlayMode.MODE.NONE:
		visible = false
		return
	visible = true
	_title_label.text = title_override if title_override != "" else OverlayMode.display_name(mode)
	var icon_key := icon_override if icon_override != "" else _icon_for_mode(mode)
	IconButton.apply_to_label(_icon_label, StringName(icon_key), 14)
	var hint := hint_override if hint_override != "" else OverlayMode.domain_hint(mode)
	_hint_label.text = hint
	_hint_label.visible = hint != ""
	_pointer.visible = false

	_last_pointer_value = -1.0
	if OverlayMode.is_vector(mode):
		_continuous_box.visible = false
		_discrete_scroll.visible = false
		_vector_box.visible = true
		_vector_arrow.visible = false
		if _vector_wheel.texture == null:
			_vector_wheel.texture = _build_hue_wheel_texture(VECTOR_WHEEL_SIZE)
		_vector_intensity_ramp.texture = _build_intensity_ramp_texture()
		var labels_v: Array = OverlayMode.RANGE_LABEL.get(mode, ["弱", "强"])
		_vector_low_label.text = str(labels_v[0])
		_vector_high_label.text = str(labels_v[1])
	elif OverlayMode.is_discrete(mode):
		_continuous_box.visible = false
		_discrete_scroll.visible = true
		_vector_box.visible = false
		_rebuild_discrete_list(mode)
	else:
		_continuous_box.visible = true
		_discrete_scroll.visible = false
		_vector_box.visible = false
		_ramp_rect.texture = _build_ramp_texture(mode)
		var labels: Array = OverlayMode.RANGE_LABEL.get(mode, ["0.00", "1.00"])
		_low_label.text = str(labels[0])
		_high_label.text = str(labels[1])


func _icon_for_mode(mode: int) -> String:
	match mode:
		OverlayMode.MODE.ELEVATION: return "elevation"
		OverlayMode.MODE.LANDFORM: return "surface"
		OverlayMode.MODE.VEGETATION_TYPE: return "vegetation"
		OverlayMode.MODE.TEMPERATURE: return "temperature"
		OverlayMode.MODE.HUMIDITY: return "humidity"
		OverlayMode.MODE.WIND_DIR: return "wind"
		OverlayMode.MODE.OCEAN_CURRENT_DIR: return "ocean_current"
		OverlayMode.MODE.RESOURCE_RESERVE: return "resource"
		_: return "overview"

# 选中 cell 时更新指针位置；未选中或数值不适用（离散通道）时隐藏。
# 值应为 [0, 1]（和 baker 归一化后的相同语义）。
func update_pointer(value: float) -> void:
	if not visible or OverlayMode.is_discrete(_current_mode):
		_pointer.visible = false
		return
	if OverlayMode.is_vector(_current_mode):
		_pointer.visible = false
		return
	if is_nan(value) or is_inf(value):
		_pointer.visible = false
		return
	_last_pointer_value = clampf(value, 0.0, 1.0)
	# 指针在 ramp_rect 内定位（父坐标系）
	var x: float = _last_pointer_value * float(RAMP_WIDTH) - 1.5
	_pointer.position = Vector2(x, -2)
	_pointer.visible = true

# 方向型通道专用：把当前选中 cell 的"方向 hue + 强度"映射成色环上的小亮点。
# hue ∈ [0, 1)，对应角度 0..2π；intensity ∈ [0, 1]，决定亮点距色环中心的半径。
func update_pointer_vector(hue: float, intensity: float) -> void:
	if not visible or not OverlayMode.is_vector(_current_mode):
		_vector_arrow.visible = false
		return
	if is_nan(hue) or is_inf(hue) or is_nan(intensity):
		_vector_arrow.visible = false
		return
	var wheel_size: Vector2 = _vector_wheel.size
	if wheel_size.x <= 0.0 or wheel_size.y <= 0.0:
		wheel_size = _vector_wheel.custom_minimum_size
	var center: Vector2 = wheel_size * 0.5
	var radius: float = minf(wheel_size.x, wheel_size.y) * 0.5 - 6.0
	# hue → angle：与 shader hsv2rgb_dir 同源（hue 0 = 角度 0 = 屏幕 +x 方向）
	var ang: float = fposmod(hue, 1.0) * TAU
	var rr: float = clampf(intensity, 0.0, 1.0) * radius
	var px: float = center.x + cos(ang) * rr - 3.0
	var py: float = center.y + sin(ang) * rr - 3.0
	_vector_arrow.position = Vector2(px, py)
	_vector_arrow.visible = true

# 清空指针（调用方：选中被清掉 / overlay 切到离散通道）
func clear_pointer() -> void:
	_pointer.visible = false
	_last_pointer_value = -1.0
	if _vector_arrow != null:
		_vector_arrow.visible = false

# --- 内部 ------------------------------------------------------------

# 构造 RAMP_WIDTH × RAMP_HEIGHT 的 ramp 纹理，色带与 shader 保持一致。
func _build_ramp_texture(mode: int) -> ImageTexture:
	var img := Image.create(RAMP_WIDTH, RAMP_HEIGHT, false, Image.FORMAT_RGBA8)
	for x in range(RAMP_WIDTH):
		var v: float = float(x) / float(RAMP_WIDTH - 1)
		var c: Color = _sample_ramp_color(mode, v)
		for y in range(RAMP_HEIGHT):
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

# 与 data_overlay.gdshader 中的 ramp_* 函数语义一致（GDScript 侧复刻）。
func _sample_ramp_color(mode: int, v: float) -> Color:
	v = clampf(v, 0.0, 1.0)
	match mode:
		OverlayMode.MODE.TEMPERATURE:
			return _ramp_cold_to_hot(v)
		OverlayMode.MODE.PRECIPITATION:
			return _ramp_dry_wet(v)
		OverlayMode.MODE.HUMIDITY:
			return _ramp_humidity(v)
		OverlayMode.MODE.VEGETATION_VITALITY:
			return _ramp_vitality(v)
		OverlayMode.MODE.OCEAN_CURRENT:
			return _ramp_current(v)
		OverlayMode.MODE.OCEAN_HEAT_TRANSPORT, OverlayMode.MODE.UPWELLING:
			return _ramp_diverging(v)
		OverlayMode.MODE.WIND_SPEED:
			return _ramp_wind(v)
		OverlayMode.MODE.DEMO_THERMAL_GRADIENT:
			# Reference-impl Pass #2 复用 cold→hot 色带，与 shader 端保持一致。
			return _ramp_cold_to_hot(v)
		OverlayMode.MODE.ELEVATION:
			return _ramp_elevation(v)
		OverlayMode.MODE.RESOURCE_RESERVE:
			return _ramp_resource(v)
		_:
			return Color(0.45, 0.45, 0.45)

func _ramp_cold_to_hot(v: float) -> Color:
	var c0 := Color(0.10, 0.30, 0.80)
	var c1 := Color(0.20, 0.75, 0.85)
	var c2 := Color(0.95, 0.90, 0.35)
	var c3 := Color(0.92, 0.25, 0.18)
	if v < 0.333:
		return c0.lerp(c1, v / 0.333)
	if v < 0.666:
		return c1.lerp(c2, (v - 0.333) / 0.333)
	return c2.lerp(c3, (v - 0.666) / 0.334)

func _ramp_dry_wet(v: float) -> Color:
	var c0 := Color(0.78, 0.48, 0.18)
	var c1 := Color(0.95, 0.95, 0.95)
	var c2 := Color(0.15, 0.40, 0.85)
	if v < 0.5:
		return c0.lerp(c1, v / 0.5)
	return c1.lerp(c2, (v - 0.5) / 0.5)

func _ramp_humidity(v: float) -> Color:
	var c0 := Color(0.90, 0.82, 0.32)
	var c1 := Color(0.35, 0.78, 0.45)
	var c2 := Color(0.18, 0.45, 0.85)
	if v < 0.5:
		return c0.lerp(c1, v / 0.5)
	return c1.lerp(c2, (v - 0.5) / 0.5)

func _ramp_vitality(v: float) -> Color:
	var c0 := Color(0.85, 0.22, 0.18)
	var c1 := Color(0.95, 0.88, 0.30)
	var c2 := Color(0.25, 0.70, 0.35)
	if v < 0.5:
		return c0.lerp(c1, v / 0.5)
	return c1.lerp(c2, (v - 0.5) / 0.5)

func _ramp_current(v: float) -> Color:
	var c0 := Color(0.04, 0.08, 0.18)
	var c1 := Color(0.12, 0.45, 0.85)
	var c2 := Color(0.30, 0.85, 0.85)
	var c3 := Color(0.98, 0.95, 0.65)
	if v < 0.333:
		return c0.lerp(c1, v / 0.333)
	if v < 0.666:
		return c1.lerp(c2, (v - 0.333) / 0.333)
	return c2.lerp(c3, (v - 0.666) / 0.334)

func _ramp_diverging(v: float) -> Color:
	var cN := Color(0.10, 0.30, 0.80)
	var c0 := Color(0.85, 0.85, 0.85)
	var cP := Color(0.92, 0.25, 0.18)
	if v < 0.5:
		return cN.lerp(c0, v / 0.5)
	return c0.lerp(cP, (v - 0.5) / 0.5)

func _ramp_wind(v: float) -> Color:
	var c0 := Color(0.80, 0.85, 0.90)
	var c1 := Color(0.90, 0.85, 0.40)
	var c2 := Color(0.95, 0.55, 0.20)
	var c3 := Color(0.55, 0.20, 0.65)
	if v < 0.333:
		return c0.lerp(c1, v / 0.333)
	if v < 0.666:
		return c1.lerp(c2, (v - 0.333) / 0.333)
	return c2.lerp(c3, (v - 0.666) / 0.334)

func _ramp_elevation(v: float) -> Color:
	var c0 := Color(0.07, 0.09, 0.34)
	var c1 := Color(0.00, 0.58, 0.88)
	var c2 := Color(0.12, 0.72, 0.42)
	var c3 := Color(0.96, 0.82, 0.16)
	var c4 := Color(0.82, 0.27, 0.16)
	var c5 := Color(0.98, 0.97, 0.94)
	if v < 0.28:
		return c0.lerp(c1, v / 0.28)
	if v < 0.46:
		return c1.lerp(c2, (v - 0.28) / 0.18)
	if v < 0.66:
		return c2.lerp(c3, (v - 0.46) / 0.20)
	if v < 0.84:
		return c3.lerp(c4, (v - 0.66) / 0.18)
	return c4.lerp(c5, (v - 0.84) / 0.16)

func _ramp_resource(v: float) -> Color:
	# Perceptually separated from the tan/green/blue base map. The fixed curve
	# expands the low and middle reserve ranges without depending on world max.
	v = pow(clampf(v, 0.0, 1.0), 0.42)
	var c0 := Color(0.10, 0.05, 0.32)
	var c1 := Color(0.00, 0.48, 0.92)
	var c2 := Color(0.76, 0.08, 0.68)
	var c3 := Color(1.00, 0.34, 0.08)
	var c4 := Color(1.00, 0.94, 0.20)
	if v < 0.25:
		return c0.lerp(c1, v * 4.0)
	if v < 0.50:
		return c1.lerp(c2, (v - 0.25) * 4.0)
	if v < 0.75:
		return c2.lerp(c3, (v - 0.50) * 4.0)
	return c3.lerp(c4, (v - 0.75) * 4.0)

# 方向型通道专用色环：与 data_overlay.gdshader 的 hsv2rgb_dir 同源。
# 半径 r = wheel_radius 的圆环代表 intensity=1.0；中心 intensity=0。
# 圆外像素透明。
func _build_hue_wheel_texture(side: int) -> ImageTexture:
	var img := Image.create(side, side, false, Image.FORMAT_RGBA8)
	var center: float = float(side) * 0.5
	var radius: float = center - 3.0
	for y in range(side):
		for x in range(side):
			var dx: float = float(x) - center
			var dy: float = float(y) - center
			var rr: float = sqrt(dx * dx + dy * dy)
			if rr > radius:
				img.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var ang: float = atan2(dy, dx)
			var hue: float = fposmod(ang / TAU, 1.0)
			var intensity: float = clampf(rr / radius, 0.0, 1.0)
			img.set_pixel(x, y, _hsv_dir_color(hue, intensity))
	return ImageTexture.create_from_image(img)

# 强度 ramp：左暗右亮，hue 固定在 60°（黄），仅展示亮度变化。
func _build_intensity_ramp_texture() -> ImageTexture:
	var img := Image.create(RAMP_WIDTH, RAMP_HEIGHT, false, Image.FORMAT_RGBA8)
	for x in range(RAMP_WIDTH):
		var v: float = float(x) / float(RAMP_WIDTH - 1)
		var c: Color = _hsv_dir_color(0.166, v)  # hue=0.166 ≈ 黄
		for y in range(RAMP_HEIGHT):
			img.set_pixel(x, y, c)
	return ImageTexture.create_from_image(img)

# GDScript 复刻 shader 端 hsv2rgb_dir：固定 s=0.85，v 从 0.45 起步避免全黑。
func _hsv_dir_color(h: float, v: float) -> Color:
	var s: float = 0.85
	var vv: float = lerpf(0.45, 1.0, clampf(v, 0.0, 1.0))
	var c: Color = Color.from_hsv(fposmod(h, 1.0), s, vv, 1.0)
	return c

func _rebuild_discrete_list(mode: int) -> void:
	for child in _discrete_list.get_children():
		child.queue_free()
	var colors: Array = []
	var names: Array = []
	if mode == OverlayMode.MODE.CLIMATE_ZONE:
		colors = DISCRETE_CLIMATE_COLORS
		names = OverlayMode.CLIMATE_ZONE_NAMES
	elif mode == OverlayMode.MODE.WEATHER:
		colors = DISCRETE_WEATHER_COLORS
		names = OverlayMode.WEATHER_NAMES
	elif mode == OverlayMode.MODE.BIOME_GROUP:
		colors = DISCRETE_BIOME_GROUP_COLORS
		names = OverlayMode.BIOME_GROUP_NAMES
	elif mode == OverlayMode.MODE.LANDFORM:
		for i in range(LandformType.LF.size()):
			names.append(LandformType.name_cn(i))
			colors.append(_categorical_color(i, 0.42))
	elif mode == OverlayMode.MODE.VEGETATION_TYPE:
		for i in range(VegetationType.VEG.size()):
			names.append(VegetationType.name_cn(i))
			colors.append(_categorical_color(i, 0.12))
	_discrete_scroll.custom_minimum_size.y = minf(220.0, float(names.size()) * 22.0)
	for i in range(names.size()):
		var row := LegendRowScene.instantiate() as HBoxContainer
		var swatch := row.get_node("Swatch") as ColorRect
		swatch.color = colors[i] if i < colors.size() else Color(0.5, 0.5, 0.5)
		var lb := row.get_node("Label") as Label
		lb.text = str(names[i])
		_discrete_list.add_child(row)


func _categorical_color(bucket: int, offset: float) -> Color:
	var hue := fposmod(float(bucket) * 0.61803398875 + offset, 1.0)
	return Color.from_hsv(hue, 0.85, lerpf(0.45, 1.0, 0.72), 1.0)
