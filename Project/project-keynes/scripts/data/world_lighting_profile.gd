@tool
class_name WorldLightingProfile
extends Resource

const RGBM_RANGE := 16.0
const SPECULAR_LEVELS := 8

@export var day_background: Texture2D
@export var night_background: Texture2D
@export var irradiance_images: Array[Image] = []
@export var specular_images: Array[Image] = []
@export var day_sh_l1 := PackedVector3Array([
	Vector3(0.0, 0.0, 0.0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
@export var night_sh_l1 := PackedVector3Array([
	Vector3(0.0, 0.0, 0.0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
@export_range(0.0, 4.0, 0.01) var ambient_strength := 1.0
@export_range(0.0, 4.0, 0.01) var reflection_strength := 1.0

var _irradiance_array_cache: Texture2DArray
var _specular_array_cache: Texture2DArray


func get_irradiance_array() -> Texture2DArray:
	if _irradiance_array_cache == null:
		if irradiance_images.size() == 2:
			_irradiance_array_cache = _create_texture_array(irradiance_images)
	return _irradiance_array_cache


func get_specular_array() -> Texture2DArray:
	if _specular_array_cache == null:
		if specular_images.size() == SPECULAR_LEVELS * 2:
			_specular_array_cache = _create_texture_array(specular_images)
	return _specular_array_cache


func _create_texture_array(images: Array[Image]) -> Texture2DArray:
	if images.is_empty() or images[0] == null or images[0].is_empty():
		return null
	var size := images[0].get_size()
	for image in images:
		if image == null or image.is_empty() or image.get_size() != size:
			return null
	var texture := Texture2DArray.new()
	if texture.create_from_images(images) != OK:
		return null
	return texture
