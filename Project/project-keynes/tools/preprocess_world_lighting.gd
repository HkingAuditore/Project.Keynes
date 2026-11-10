extends SceneTree

const ProfileScript = preload("res://scripts/data/world_lighting_profile.gd")
const MathScript = preload("res://scripts/rendering/world_lighting_math.gd")
const BACKGROUND_SIZE := Vector2i(512, 256)
const IRRADIANCE_SIZE := 64
const SPECULAR_SIZE := 128
const SPECULAR_LEVELS := ProfileScript.SPECULAR_LEVELS
const DIFFUSE_SAMPLES := 64
const SPECULAR_SAMPLES := 32

var _source: Image
var _source_is_linear := false
var _day_exposure := 1.0
var _night_exposure := 1.0
var _input_height := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		printerr("Usage: godot --headless --path <project> --script res://tools/preprocess_world_lighting.gd -- <stacked-panorama> <profile.tres> [day-exposure] [night-exposure]")
		quit(2)
		return
	_day_exposure = float(args[2]) if args.size() > 2 else 1.0
	_night_exposure = float(args[3]) if args.size() > 3 else 1.0
	if not is_finite(_day_exposure) or not is_finite(_night_exposure) \
			or _day_exposure < 0.0 or _night_exposure < 0.0:
		printerr("Exposure values must be finite and non-negative")
		quit(2)
		return
	_source_is_linear = args[0].get_extension().to_lower() == "exr"
	_source = Image.new()
	var error := _source.load(args[0])
	if error != OK:
		printerr("Could not load environment image: %s" % error_string(error))
		quit(3)
		return
	var validation := MathScript.validate_stacked_panorama(_source)
	if not validation.is_empty():
		printerr(validation)
		quit(4)
		return
	validation = MathScript.validate_radiance_image(_source)
	if not validation.is_empty():
		printerr(validation)
		quit(4)
		return
	_input_height = _source.get_height() / 2
	var profile = ProfileScript.new()
	profile.day_background = ImageTexture.create_from_image(_make_background(0))
	profile.night_background = ImageTexture.create_from_image(_make_background(1))
	profile.day_sh_l1 = _integrate_l1(0, _day_exposure)
	profile.night_sh_l1 = _integrate_l1(1, _night_exposure)
	var irradiance_layers: Array[Image] = [
		_make_irradiance(0, _day_exposure),
		_make_irradiance(1, _night_exposure),
	]
	profile.irradiance_images = irradiance_layers
	var specular_layers := _make_specular_levels(0, _day_exposure)
	specular_layers.append_array(_make_specular_levels(1, _night_exposure))
	profile.specular_images = specular_layers
	if profile.get_irradiance_array() == null or profile.get_specular_array() == null:
		printerr("Could not create precomputed environment texture layers")
		quit(5)
		return
	var save_error := ResourceSaver.save(profile, args[1])
	if save_error != OK:
		printerr("Could not save WorldLightingProfile: %s" % error_string(save_error))
		quit(5)
		return
	print("WorldLightingProfile saved: %s" % args[1])
	quit(0)


func _integrate_l1(half: int, exposure: float) -> PackedVector3Array:
	var sum := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
	var total_weight := 0.0
	var width := _source.get_width()
	for y in range(_input_height):
		var v := (float(y) + 0.5) / float(_input_height)
		var latitude := (0.5 - v) * PI
		var cos_lat := cos(latitude)
		var solid_weight := cos_lat
		for x in range(width):
			var u := (float(x) + 0.5) / float(width)
			var direction := _equirect_direction(u, v)
			var radiance := _read_radiance(half, u, v, exposure)
			sum[0] += radiance * solid_weight
			sum[1] += radiance * direction.x * solid_weight
			sum[2] += radiance * direction.y * solid_weight
			sum[3] += radiance * direction.z * solid_weight
			total_weight += solid_weight
	var normalization := maxf(total_weight, 0.000001)
	sum[0] /= normalization
	# Convolve the projected L1 signal with the cosine lobe, normalized by PI.
	for i in range(1, 4):
		sum[i] *= 2.0 / normalization
	return sum


func _make_irradiance(half: int, exposure: float) -> Image:
	var output := Image.create(IRRADIANCE_SIZE, IRRADIANCE_SIZE, false, Image.FORMAT_RGBA8)
	for y in range(IRRADIANCE_SIZE):
		for x in range(IRRADIANCE_SIZE):
			var normal := MathScript.oct_decode(Vector2(
				(float(x) + 0.5) / IRRADIANCE_SIZE,
				(float(y) + 0.5) / IRRADIANCE_SIZE))
			var radiance := _convolve_diffuse(half, exposure, normal)
			output.set_pixel(x, y, MathScript.rgbm_encode(Color(
				radiance.x, radiance.y, radiance.z)))
	return output


func _make_specular_levels(half: int, exposure: float) -> Array[Image]:
	var output: Array[Image] = []
	for level in range(SPECULAR_LEVELS):
		var roughness := float(level) / float(SPECULAR_LEVELS - 1)
		var image := Image.create(SPECULAR_SIZE, SPECULAR_SIZE, false, Image.FORMAT_RGBA8)
		for y in range(SPECULAR_SIZE):
			for x in range(SPECULAR_SIZE):
				var reflection := MathScript.oct_decode(Vector2(
					(float(x) + 0.5) / SPECULAR_SIZE,
					(float(y) + 0.5) / SPECULAR_SIZE))
				var radiance := _prefilter_specular(half, exposure, reflection, roughness)
				image.set_pixel(x, y, MathScript.rgbm_encode(Color(
					radiance.x, radiance.y, radiance.z)))
		output.append(image)
		print("specular %s roughness %d/%d" % ["day" if half == 0 else "night", level + 1, SPECULAR_LEVELS])
	return output


func _convolve_diffuse(half: int, exposure: float, normal: Vector3) -> Vector3:
	var tangent := _tangent(normal)
	var bitangent := normal.cross(tangent).normalized()
	var total := Vector3.ZERO
	for i in range(DIFFUSE_SAMPLES):
		var xi := Vector2(float(i) / DIFFUSE_SAMPLES, _radical_inverse(i))
		var phi := MathScript.TAU * xi.y
		var radius := sqrt(xi.x)
		var local := Vector3(radius * cos(phi), radius * sin(phi), sqrt(maxf(1.0 - xi.x, 0.0)))
		var direction := (tangent * local.x + bitangent * local.y + normal * local.z).normalized()
		total += _sample_environment(half, exposure, direction)
	return total / float(DIFFUSE_SAMPLES)


func _prefilter_specular(half: int, exposure: float, normal: Vector3,
		roughness: float) -> Vector3:
	if roughness <= 0.001:
		return _sample_environment(half, exposure, normal)
	var tangent := _tangent(normal)
	var bitangent := normal.cross(tangent).normalized()
	var alpha := roughness * roughness
	var alpha2 := alpha * alpha
	var total := Vector3.ZERO
	var weight := 0.0
	for i in range(SPECULAR_SAMPLES):
		var xi := Vector2(float(i) / SPECULAR_SAMPLES, _radical_inverse(i))
		var phi := MathScript.TAU * xi.x
		var cos_theta := sqrt((1.0 - xi.y) / maxf(1.0 + (alpha2 - 1.0) * xi.y, 0.0001))
		var sin_theta := sqrt(maxf(1.0 - cos_theta * cos_theta, 0.0))
		var half_local := Vector3(sin_theta * cos(phi), sin_theta * sin(phi), cos_theta)
		var half_vector := (tangent * half_local.x + bitangent * half_local.y
			+ normal * half_local.z).normalized()
		var direction := (2.0 * normal.dot(half_vector) * half_vector - normal).normalized()
		var n_dot_l := maxf(normal.dot(direction), 0.0)
		if n_dot_l > 0.0:
			total += _sample_environment(half, exposure, direction) * n_dot_l
			weight += n_dot_l
	return total / maxf(weight, 0.0001)


func _sample_environment(half: int, exposure: float, direction: Vector3) -> Vector3:
	var latitude := asin(clampf(direction.z, -1.0, 1.0))
	var longitude := atan2(direction.x, direction.y)
	var u := fposmod(longitude / MathScript.TAU, 1.0)
	var v := clampf(0.5 - latitude / PI, 0.0, 1.0)
	var color := _sample_equirect(half, u, v)
	if not _source_is_linear:
		color = MathScript.srgb_to_linear(color)
	return Vector3(color.r, color.g, color.b) * exposure


func _sample_equirect(half: int, u: float, v: float) -> Color:
	var width := _source.get_width()
	var x := fposmod(u, 1.0) * width - 0.5
	var y := clampf(v, 0.0, 1.0) * (_input_height - 1)
	var x0 := int(floor(x))
	var y0 := int(floor(y))
	var fx: float = x - floor(x)
	var fy: float = y - float(y0)
	var x1 := posmod(x0 + 1, width)
	x0 = posmod(x0, width)
	var y1 := mini(y0 + 1, _input_height - 1)
	var offset := half * _input_height
	var a := _source.get_pixel(x0, offset + y0).lerp(_source.get_pixel(x1, offset + y0), fx)
	var b := _source.get_pixel(x0, offset + y1).lerp(_source.get_pixel(x1, offset + y1), fx)
	return a.lerp(b, fy)


func _read_radiance(half: int, u: float, v: float, exposure: float) -> Vector3:
	var color := _sample_equirect(half, u, v)
	if not _source_is_linear:
		color = MathScript.srgb_to_linear(color)
	return Vector3(color.r, color.g, color.b) * exposure


func _make_background(half: int) -> Image:
	var output := Image.create(BACKGROUND_SIZE.x, BACKGROUND_SIZE.y, false, Image.FORMAT_RGBA8)
	var width := _source.get_width()
	var exposure := _day_exposure if half == 0 else _night_exposure
	for y in range(BACKGROUND_SIZE.y):
		for x in range(BACKGROUND_SIZE.x):
			var sx := mini(int(float(x) / BACKGROUND_SIZE.x * width), width - 1)
			var sy := half * _input_height + mini(int(float(y) / BACKGROUND_SIZE.y * _input_height), _input_height - 1)
			var color := _source.get_pixel(sx, sy)
			if _source_is_linear:
				color = MathScript.linear_to_srgb(color * exposure)
			else:
				color = MathScript.linear_to_srgb(MathScript.srgb_to_linear(color) * exposure)
			output.set_pixel(x, y, Color(
				clampf(color.r, 0.0, 1.0), clampf(color.g, 0.0, 1.0),
				clampf(color.b, 0.0, 1.0), 1.0))
	return output


func _equirect_direction(u: float, v: float) -> Vector3:
	var latitude := (0.5 - v) * PI
	var longitude := u * MathScript.TAU
	var cos_lat := cos(latitude)
	return Vector3(cos_lat * sin(longitude), cos_lat * cos(longitude), sin(latitude))


func _tangent(normal: Vector3) -> Vector3:
	var helper := Vector3.UP if absf(normal.z) > 0.9 else Vector3(0.0, 0.0, 1.0)
	return helper.cross(normal).normalized()


func _radical_inverse(value: int) -> float:
	var bits := value
	bits = (bits << 16) | (bits >> 16)
	bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1)
	bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2)
	bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4)
	bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8)
	return float(bits & 0xFFFFFFFF) * 2.3283064365386963e-10
