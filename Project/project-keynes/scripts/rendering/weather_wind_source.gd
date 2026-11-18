extends RefCounted

# Weather publication owns wind textures independently of cloud-shadow drawing.
var world: WorldData
var map: MapData
var current: Texture2D
var previous: Texture2D
var has_previous := false
var _stamp := -1
var _dims := Vector2i.ZERO


func bind(next_world: WorldData, next_map: MapData) -> void:
	if world == next_world and map == next_map:
		return
	world = next_world
	map = next_map
	current = null
	previous = null
	has_previous = false
	_stamp = -1
	_dims = Vector2i.ZERO


func update() -> bool:
	if world == null or map == null:
		return false
	var stamp := int(world.weather_lut_update_usec)
	if stamp == _stamp and world.lut_dims == _dims:
		return false
	var image := build_image(map, world.lut_dims)
	previous = current
	current = ImageTexture.create_from_image(image) if image != null else null
	has_previous = current != null and previous != null and _dims == world.lut_dims
	if not has_previous:
		previous = current
	_stamp = stamp
	_dims = world.lut_dims
	return true


static func encode_wind(direction: Vector2, speed: float) -> Color:
	var dir := direction.normalized() if direction.length_squared() > 0.000001 else Vector2.ZERO
	return Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, clampf(speed / 20.0, 0.0, 1.0), 1.0)


static func build_image(map: MapData, dims: Vector2i) -> Image:
	if map == null or dims.x <= 0 or dims.y <= 0 \
			or map.wind_x_arr.size() == 0 or map.wind_y_arr.size() != map.wind_x_arr.size():
		return null
	var n := mini(map.wind_x_arr.size(), dims.x * dims.y)
	if n <= 0:
		return null
	var speed_arr := map.wind_speed_arr
	var image := Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	for i in range(dims.x * dims.y):
		var wind := Vector2.ZERO
		var speed := 0.0
		if i < n:
			wind = Vector2(map.wind_x_arr[i], map.wind_y_arr[i])
			if wind.length_squared() > 0.000001:
				wind = wind.normalized()
			if i < speed_arr.size():
				speed = float(speed_arr[i])
		image.set_pixel(i % dims.x, int(i / dims.x), encode_wind(wind, speed))
	return image


# [cell-field-overlays 2026-11-18] 与 build_image() **逐字节相同**的原始字节（index 空间，
# 长度 = dims.x * dims.y * 4，按 cell.index 排列）。
#
# 为什么需要它：cloud_shadow_field / weather_layer 只消费 `Texture2D`（set_wind_luts 拿到
# 的是纹理），拿不到像素字节；weather_table 的 layer2/3 必须在 CPU 侧重排到 offset 空间。
# 这里**不新写一份编码**：直接复用 build_image() 再 get_data()，所以量化口径（Color→RGBA8
# 的取整、speed/20 的归一、风向 normalize 的阈值）不可能与 wind_lut 分叉。
# 读取上游（map.wind_x_arr / wind_y_arr / wind_speed_arr）的时机与 update() 完全一致：
# 都是天气 LUT 换字节的那一次提交（weather_lut_update_usec 变化）。
static func build_bytes(map: MapData, dims: Vector2i) -> PackedByteArray:
	var image := build_image(map, dims)
	if image == null:
		return PackedByteArray()
	return image.get_data()
