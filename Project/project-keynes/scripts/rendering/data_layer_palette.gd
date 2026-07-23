# data_layer_palette.gd
# 数据图层的色阶函数 + LayerSpec 静态表。
#
# 只读 MapData / DCViewAdapter，不改任何模拟 schema。LUT 烘焙由 MapDataLayerOverlay
# 调用这里的 ramp 函数，把每格标量/类别/矢量映射成 RGBA 显示色。
#
# 图层 id 约定：
#   geo.elevation / geo.terrain / geo.vegetation
#   climate.temp / climate.moisture / climate.wind / climate.ocean_current
#   resource.<resource_id>（由 ResourceProfileRegistry 动态展开）

extends RefCounted
class_name DataLayerPalette

const KIND_SCALAR := 0      # 顺序色阶（海拔/温度/湿度/资源储量）
const KIND_CATEGORICAL := 1 # 离散调色板（地形/植被）
const KIND_VECTOR := 2       # 矢量：色相=方向，亮度=强度（风向/洋流）

const ResourceProfileRegistry = preload("res://scripts/data/resource_profile_registry.gd")

# ── 离散调色板（golden-angle HSV，按 enum id 直接索引；颜色稳定，支持任意 enum 数量）──
static var _cat_palette: PackedColorArray = []

static func _ensure_cat() -> void:
	if not _cat_palette.is_empty():
		return
	_cat_palette = _build_categorical(28)

static func _build_categorical(n: int) -> PackedColorArray:
	var out := PackedColorArray()
	var golden := 0.61803398875
	for i in range(n):
		var h := fmod(float(i) * golden, 1.0)
		out.append(Color.from_hsv(fposmod(h, 1.0), 0.65, 0.80))
	return out

static func _hsv(h: float, s: float, v: float) -> Color:
	return Color.from_hsv(fposmod(h, 1.0), s, v)

# ── 多段梯度（stops 等距）──
static func _gradient(t: float, stops: PackedColorArray) -> Color:
	var n := stops.size()
	if n == 0:
		return Color(0.0, 0.0, 0.0, 1.0)
	if n == 1:
		return stops[0]
	t = clampf(t, 0.0, 1.0)
	var f := t * float(n - 1)
	var i := int(floor(f))
	var frac := f - float(i)
	if i >= n - 1:
		return stops[n - 1]
	return (stops[i] as Color).lerp(stops[i + 1] as Color, frac)

# ── 各图层色阶 ──
static func ramp_elevation(v: float) -> Color:
	return _gradient(v, PackedColorArray([
		Color(0.02, 0.06, 0.22),   # 深海（更深）
		Color(0.06, 0.22, 0.52),   # 海洋
		Color(0.18, 0.50, 0.68),   # 浅海
		Color(0.82, 0.78, 0.50),   # 海岸/陆架（更亮）
		Color(0.35, 0.62, 0.28),   # 低地绿（更饱和）
		Color(0.58, 0.48, 0.22),   # 丘陵棕
		Color(0.68, 0.60, 0.42),   # 山地
		Color(0.97, 0.97, 1.00),   # 雪线白
	]))

static func ramp_temp(v: float) -> Color:
	return _gradient(v, PackedColorArray([
		Color(0.12, 0.28, 0.68),   # 冷蓝（更深）
		Color(0.35, 0.60, 0.78),
		Color(0.95, 0.95, 0.92),   # 中性白
		Color(0.94, 0.55, 0.24),
		Color(0.82, 0.18, 0.12),   # 暂红（更红）
	]))

static func ramp_humidity(v: float) -> Color:
	return _gradient(v, PackedColorArray([
		Color(0.88, 0.76, 0.22),   # 干黄（更金黄）
		Color(0.60, 0.68, 0.35),
		Color(0.28, 0.55, 0.58),
		Color(0.14, 0.35, 0.62),   # 湿蓝（更深）
	]))

static func ramp_resource(v: float) -> Color:
	return _gradient(v, PackedColorArray([
		Color(0.08, 0.10, 0.18),   # 极少（深蓝灰，明显"空"）
		Color(0.12, 0.28, 0.42),   # 少量（蓝）
		Color(0.18, 0.50, 0.48),   # 偏少（青）
		Color(0.38, 0.62, 0.28),   # 中等（绿）
		Color(0.68, 0.62, 0.16),   # 较多（金黄）
		Color(0.92, 0.72, 0.12),   # 丰富（亮金橙）
		Color(1.00, 0.88, 0.30),   # 极富（亮金）
	]))

static func ramp_categorical(id: int) -> Color:
	_ensure_cat()
	if _cat_palette.is_empty():
		return Color(0.5, 0.5, 0.5)
	return _cat_palette[id % _cat_palette.size()] as Color

static func ramp_vector(dir: Vector2, mag: float) -> Color:
	var len := dir.length()
	var h: float
	if len < 0.0001:
		h = 0.0
	else:
		h = fposmod(atan2(dir.y, dir.x) / TAU + 0.5, 1.0)
	var v := clampf(mag, 0.0, 1.0)
	return _hsv(h, 0.70, 0.42 + 0.52 * v)

# ── 通用分发（legend 复用）──
static func ramp_for_id(ramp_id: String, t: float, dir: Vector2 = Vector2.ZERO, mag: float = 1.0) -> Color:
	match ramp_id:
		"elevation":
			return ramp_elevation(t)
		"temp":
			return ramp_temp(t)
		"moisture":
			return ramp_humidity(t)
		"resource":
			return ramp_resource(t)
		"wind", "ocean_current":
			return ramp_vector(dir, mag)
		_:
			return ramp_categorical(int(t * 1000.0))

# ── 图层规格表 ──
static func spec_for(layer_id: String) -> Dictionary:
	match layer_id:
		"geo.elevation":
			return {"kind": KIND_SCALAR, "display": "海拔", "ramp": "elevation",
				"value": "elevation", "label_lo": "低", "label_hi": "高"}
		"geo.terrain":
			return {"kind": KIND_CATEGORICAL, "display": "地形", "ramp": "terrain",
				"value": "terrain", "label_lo": "类别", "label_hi": ""}
		"geo.vegetation":
			return {"kind": KIND_CATEGORICAL, "display": "植被", "ramp": "vegetation",
				"value": "vegetation", "label_lo": "类别", "label_hi": ""}
		"climate.temp":
			return {"kind": KIND_SCALAR, "display": "温度", "ramp": "temp",
				"value": "temp", "label_lo": "冷", "label_hi": "暖"}
		"climate.moisture":
			return {"kind": KIND_SCALAR, "display": "湿度", "ramp": "moisture",
				"value": "moisture", "label_lo": "干", "label_hi": "湿"}
		"climate.wind":
			return {"kind": KIND_VECTOR, "display": "风向", "ramp": "wind",
				"value": "wind", "label_lo": "方向", "label_hi": ""}
		"climate.ocean_current":
			return {"kind": KIND_VECTOR, "display": "洋流", "ramp": "ocean_current",
				"value": "ocean_current", "label_lo": "方向", "label_hi": ""}
	if layer_id.begins_with("resource."):
		var rid := layer_id.substr("resource.".length())
		var p = _resource_profile(rid)
		if p != null:
			return {"kind": KIND_SCALAR, "display": String(p.display_name), "ramp": "resource",
				"value": "resource", "res_id": rid, "label_lo": "少", "label_hi": "多"}
	return {}

static func _resource_profile(rid: String):
	var ordered := ResourceProfileRegistry.ordered()
	for p in ordered:
		if String(p.id) == ("&" + rid) or String(p.id) == rid:
			return p
	return null

static func is_resource(layer_id: String) -> bool:
	return layer_id.begins_with("resource.")

static func resource_field(layer_id: String) -> String:
	var rid := layer_id.substr("resource.".length())
	var p = _resource_profile(rid)
	if p == null:
		return ""
	return ResourceProfileRegistry.reserve_map_field(p)
