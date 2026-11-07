class_name WorldLightingMath
extends RefCounted

const TAU := 6.283185307179586
const RGBM_RANGE := 16.0


static func validate_stacked_panorama(image: Image) -> String:
	if image == null or image.is_empty():
		return "input image is empty"
	if image.get_width() < 32 or image.get_width() != image.get_height():
		return "expected a square image containing two stacked 2:1 panoramas"
	if image.get_height() % 2 != 0:
		return "stacked panorama height must be even"
	return ""


static func validate_radiance_image(image: Image) -> String:
	if image == null or image.is_empty():
		return "input image is empty"
	for y in range(image.get_height()):
		for x in range(image.get_width()):
			var color := image.get_pixel(x, y)
			if not is_finite(color.r) or not is_finite(color.g) or not is_finite(color.b):
				return "input image contains non-finite radiance at (%d, %d)" % [x, y]
			if color.r < 0.0 or color.g < 0.0 or color.b < 0.0:
				return "input image contains negative radiance at (%d, %d)" % [x, y]
	return ""


static func oct_encode(direction: Vector3) -> Vector2:
	var n := direction.normalized()
	var denom := absf(n.x) + absf(n.y) + absf(n.z)
	if denom <= 0.000001:
		return Vector2(0.5, 0.5)
	var p := Vector2(n.x, n.y) / denom
	if n.z < 0.0:
		p = Vector2(
			(1.0 - absf(p.y)) * signf(p.x),
			(1.0 - absf(p.x)) * signf(p.y))
	return p * 0.5 + Vector2(0.5, 0.5)


static func oct_decode(uv: Vector2) -> Vector3:
	var p := uv * 2.0 - Vector2.ONE
	var n := Vector3(p.x, p.y, 1.0 - absf(p.x) - absf(p.y))
	if n.z < 0.0:
		var old_x := n.x
		n.x = (1.0 - absf(n.y)) * signf(old_x)
		n.y = (1.0 - absf(old_x)) * signf(n.y)
	return n.normalized()


static func eval_l1(coefficients: PackedVector3Array, normal: Vector3) -> Color:
	if coefficients.size() < 4:
		return Color.BLACK
	var n := normal.normalized()
	var directional := coefficients[1] * n.x + coefficients[2] * n.y + coefficients[3] * n.z
	var c := coefficients[0] + directional * (2.0 / 3.0)
	return Color(maxf(c.x, 0.0), maxf(c.y, 0.0), maxf(c.z, 0.0), 1.0)


static func blend_l1(day: PackedVector3Array, night: PackedVector3Array,
		day_weight: float) -> PackedVector3Array:
	var count := mini(day.size(), night.size())
	var result := PackedVector3Array()
	result.resize(count)
	var weight := clampf(day_weight, 0.0, 1.0)
	for i in range(count):
		result[i] = night[i].lerp(day[i], weight)
	return result


static func srgb_to_linear(color: Color) -> Color:
	return Color(
		_srgb_channel_to_linear(color.r),
		_srgb_channel_to_linear(color.g),
		_srgb_channel_to_linear(color.b),
		color.a)


static func linear_to_srgb(color: Color) -> Color:
	return Color(
		_linear_channel_to_srgb(color.r),
		_linear_channel_to_srgb(color.g),
		_linear_channel_to_srgb(color.b),
		color.a)


static func rgbm_encode(color: Color, range: float = RGBM_RANGE) -> Color:
	var rgb := Vector3(maxf(color.r, 0.0), maxf(color.g, 0.0), maxf(color.b, 0.0))
	var multiplier := clampf(ceilf(maxf(rgb.x, maxf(rgb.y, rgb.z)) / range * 255.0) / 255.0,
		1.0 / 255.0, 1.0)
	var encoded := rgb / (multiplier * range)
	return Color(clampf(encoded.x, 0.0, 1.0), clampf(encoded.y, 0.0, 1.0),
		clampf(encoded.z, 0.0, 1.0), multiplier)


static func rgbm_decode(color: Color, range: float = RGBM_RANGE) -> Color:
	return Color(color.r * color.a * range, color.g * color.a * range,
		color.b * color.a * range, 1.0)


static func _srgb_channel_to_linear(value: float) -> float:
	return value / 12.92 if value <= 0.04045 else pow((value + 0.055) / 1.055, 2.4)


static func _linear_channel_to_srgb(value: float) -> float:
	var v := maxf(value, 0.0)
	return v * 12.92 if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055
