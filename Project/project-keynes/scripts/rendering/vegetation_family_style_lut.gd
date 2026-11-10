extends RefCounted

## Encodes the family style texture from source-layer profiles; owns no batch or LOD state.

const STYLE_LUT_WIDTH := 16

const STYLE_LUT_HEIGHT := 32

static func _build_style_lut(_sources: Array) -> ImageTexture:
	var image := Image.create(STYLE_LUT_WIDTH, STYLE_LUT_HEIGHT, false, Image.FORMAT_RGBAF)
	image.fill(Color(0.0, 1.0, 1.0, 0.0))
	for layer in _sources:
		if layer == null or not is_instance_valid(layer):
			continue
		var profile = layer.profile
		var style_id := clampi(int(layer.family_style_id()), 0, STYLE_LUT_HEIGHT - 1)
		var wind := float(profile.get("wind_strength")) if profile != null else 1.0
		var shape := _style_shape_scale(int(profile.get("detail_kind")) if profile != null else 0)
		image.set_pixel(0, style_id, Color(wind, shape.x, shape.y,
			float(layer.detail_render_family()) / 5.0))
		var base := Color.WHITE
		if profile != null and bool(profile.get("base_color_override_enabled")):
			base = profile.get("base_color_override")
		image.set_pixel(1, style_id, base)
		var casts_shadow: bool = layer.has_method("detail_family_casts_shadow") \
			and bool(layer.detail_family_casts_shadow())
		var shading: Dictionary = layer.detail_style_shading() \
			if layer.has_method("detail_style_shading") else {}
		image.set_pixel(2, style_id, Color(1.0 if casts_shadow else 0.0,
			float(shading.get("shadow_foot_radius", 0.42)),
			float(shading.get("shadow_length_scale", 1.0)),
			float(shading.get("shadow_strength", 1.0))))
		image.set_pixel(3, style_id, Color(float(shading.get("detail_form", 3)),
			float(shading.get("phenology_response", 1.0)),
			float(shading.get("phenology_color_dominance", 0.5)),
			float(shading.get("veg_response", 1.0))))
		image.set_pixel(4, style_id, Color(float(shading.get("bloom_strength", 0.0)),
			float(shading.get("snow_body_color_retention", 0.5)),
			float(shading.get("albedo_light_floor", 0.5)),
			float(shading.get("snow_burial", 0.5))))
		image.set_pixel(5, style_id, Color(float(shading.get("aquatic_response", 0.0)),
			float(shading.get("snow_size_floor", 0.6)),
			float(shading.get("color_saturation_gain", 1.0)),
			float(shading.get("color_value_gain", 1.0))))
	return ImageTexture.create_from_image(image)


static func _style_shape_scale(detail_kind: int) -> Vector2:
	match detail_kind:
		1, 3, 4, 10:
			return Vector2(0.92, 1.08)
		2, 7:
			return Vector2(1.08, 0.82)
		5, 6:
			return Vector2(0.82, 1.12)
		8, 9:
			return Vector2(1.10, 0.76)
	return Vector2.ONE
