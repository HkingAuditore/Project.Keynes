extends SceneTree

const MapBakerScript = preload("res://scripts/rendering/map_baker.gd")

const MATERIAL_PATHS := [
	"res://assets/textures/terrain_materials/organic.png",
	"res://assets/textures/terrain_materials/dry_sand.png",
	"res://assets/textures/terrain_materials/rock.png",
	"res://assets/textures/terrain_materials/snow_wet.png",
]

var _checks := 0
var _failures := 0


func _init() -> void:
	var desktop_images: Array[Image] = []
	for path in MATERIAL_PATHS:
		var image := Image.new()
		var error := image.load(path)
		_expect(error == OK and not image.is_empty(), "%s loads" % path)
		if error != OK or image.is_empty():
			continue
		_expect(image.get_size() == Vector2i(1024, 1024), "%s is 1024^2" % path)
		_expect(image.get_format() == Image.FORMAT_RGBA8, "%s is RGBA8" % path)
		_expect(_edge_metrics(image, 2, 4), "%s has periodic edges" % path)
		image.generate_mipmaps()
		desktop_images.append(image)

	var desktop_array := _make_array(desktop_images)
	_expect(desktop_array != null, "desktop material array creates")
	if desktop_array != null:
		_expect(desktop_array.get_layers() == 4, "desktop array has four layers")
	var runtime_desktop := MapBakerScript.get_or_build_shared_terrain_material_tex(1024)
	_expect(runtime_desktop != null, "MapBaker desktop array loader succeeds")
	if runtime_desktop != null:
		_expect(runtime_desktop.get_layers() == 4, "MapBaker desktop loader has four layers")

	var mobile_images: Array[Image] = []
	for path in MATERIAL_PATHS:
		var image := Image.new()
		if image.load(path) != OK:
			continue
		image.resize(512, 512, Image.INTERPOLATE_LANCZOS)
		_expect(_edge_metrics(image, 2, 4), "%s remains periodic at 512^2" % path)
		image.generate_mipmaps()
		mobile_images.append(image)
	var mobile_array := _make_array(mobile_images)
	_expect(mobile_array != null, "mobile material array creates")
	if mobile_array != null:
		_expect(mobile_array.get_layers() == 4, "mobile array has four layers")
	var runtime_mobile := MapBakerScript.get_or_build_shared_terrain_material_tex(512)
	_expect(runtime_mobile != null, "MapBaker mobile array loader succeeds")
	if runtime_mobile != null:
		_expect(runtime_mobile.get_layers() == 4, "MapBaker mobile loader has four layers")

	var failed_result: Dictionary = MapBakerScript._build_terrain_material_tex(0)
	_expect(failed_result.get("texture", null) == null,
		"invalid array target returns a fallback result")
	_expect(not String(failed_result.get("reason", "")).is_empty(),
		"array failure records a reason")
	_expect(not MapBakerScript._terrain_materials_supported_for_renderer("gl_compatibility"),
		"Compatibility renderer disables terrain material arrays")
	_expect(MapBakerScript._terrain_materials_supported_for_renderer("mobile"),
		"native renderer allows terrain material arrays")

	print("=== terrain material tiles: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _make_array(images: Array[Image]) -> Texture2DArray:
	if images.size() != 4:
		return null
	var array := Texture2DArray.new()
	if array.create_from_images(images) != OK:
		return null
	return array


func _edge_metrics(image: Image, max_edge_error: int, max_gradient_error: int) -> bool:
	var width := image.get_width()
	var height := image.get_height()
	for y in range(height):
		var left := _pixel_bytes(image.get_pixel(0, y))
		var right := _pixel_bytes(image.get_pixel(width - 1, y))
		var left_next := _pixel_bytes(image.get_pixel(1, y))
		var right_prev := _pixel_bytes(image.get_pixel(width - 2, y))
		for c in range(4):
			if absi(left[c] - right[c]) > max_edge_error:
				return false
			if absi((left_next[c] - left[c]) - (right[c] - right_prev[c])) > max_gradient_error:
				return false
	for x in range(width):
		var top := _pixel_bytes(image.get_pixel(x, 0))
		var bottom := _pixel_bytes(image.get_pixel(x, height - 1))
		var top_next := _pixel_bytes(image.get_pixel(x, 1))
		var bottom_prev := _pixel_bytes(image.get_pixel(x, height - 2))
		for c in range(4):
			if absi(top[c] - bottom[c]) > max_edge_error:
				return false
			if absi((top_next[c] - top[c]) - (bottom[c] - bottom_prev[c])) > max_gradient_error:
				return false
	return true


func _pixel_bytes(color: Color) -> PackedInt32Array:
	return PackedInt32Array([
		int(round(color.r * 255.0)),
		int(round(color.g * 255.0)),
		int(round(color.b * 255.0)),
		int(round(color.a * 255.0)),
	])


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
