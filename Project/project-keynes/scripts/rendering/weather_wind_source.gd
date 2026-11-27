extends RefCounted

# Weather publication owns wind textures independently of cloud-shadow drawing.
var world: WorldData
var map: MapData
var current: Texture2D
var previous: Texture2D
var has_previous := false
var _stamp := -1
var _dims := Vector2i.ZERO
var _current_wind_bytes := PackedByteArray()


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
	_current_wind_bytes = PackedByteArray()


func update() -> bool:
	if world == null or map == null:
		return false
	var stamp := int(world.weather_lut_update_usec)
	var dims := world.lut_dims
	if stamp == _stamp and dims == _dims:
		return false
	var published_bytes = world.published_weather_wind_bytes(map)
	var bytes: PackedByteArray
	var image: Image
	if published_bytes == null:
		# A standalone preview can supply wind without publishing weather LUTs.
		image = build_image(map, dims)
		bytes = image.get_data() if image != null else PackedByteArray()
	else:
		bytes = published_bytes
	previous = current
	# Keep both interpolation endpoints. Identical encoded pixels can use the
	# current texture for both without another graphics upload.
	if dims != _dims or bytes != _current_wind_bytes:
		if image == null and not bytes.is_empty():
			image = Image.create_from_data(dims.x, dims.y, false, Image.FORMAT_RGBA8, bytes)
		current = ImageTexture.create_from_image(image) if image != null else null
		_current_wind_bytes = bytes
	has_previous = current != null and previous != null and _dims == dims
	if not has_previous:
		previous = current
	_stamp = stamp
	_dims = dims
	return true


static func encode_wind(direction: Vector2, speed: float) -> Color:
	var dir := direction.normalized() if direction.length_squared() > 0.000001 else Vector2.ZERO
	return Color(dir.x * 0.5 + 0.5, dir.y * 0.5 + 0.5, clampf(speed / 20.0, 0.0, 1.0), 1.0)


static func build_image(map: MapData, dims: Vector2i) -> Image:
	if map == null or dims.x <= 0 or dims.y <= 0 \
			or map.wind_x_arr.size() == 0 or map.wind_y_arr.size() != map.wind_x_arr.size():
		return null
	var slots := dims.x * dims.y
	var n := mini(map.wind_x_arr.size(), slots)
	if n <= 0:
		return null
	var speed_arr := map.wind_speed_arr
	var image := Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	if n < slots:
		image.fill(encode_wind(Vector2.ZERO, 0.0))
	for i in n:
		var wind := Vector2(map.wind_x_arr[i], map.wind_y_arr[i])
		if wind.length_squared() > 0.000001:
			wind = wind.normalized()
		var speed := float(speed_arr[i]) if i < speed_arr.size() else 0.0
		image.set_pixel(i % dims.x, int(i / dims.x), encode_wind(wind, speed))
	return image


# Index-ordered RGBA8 for a weather publication. Use the same pixel
# quantization as the standalone wind preview.
static func build_bytes(map: MapData, dims: Vector2i) -> PackedByteArray:
	var image := build_image(map, dims)
	if image == null:
		return PackedByteArray()
	return image.get_data()
