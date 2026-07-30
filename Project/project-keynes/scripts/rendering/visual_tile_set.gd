class_name VisualTileSet
extends RefCounted

const VisualTileLayoutScript = preload("res://scripts/rendering/visual_tile_layout.gd")

const FIELD_FORMATS := {
	"height": Image.FORMAT_RG8,
	"terrain_normal": Image.FORMAT_RG8,
	"map_index": Image.FORMAT_RGBA8,
	"flow": Image.FORMAT_L8,
	"water_depth": Image.FORMAT_L8,
	"terrain_detail": Image.FORMAT_L8,
	"edge_neighbor": Image.FORMAT_RG8,
	"edge_distance": Image.FORMAT_L8,
	"horizon": Image.FORMAT_RGBA8,
}

var layout
var ready: bool = false
var static_ready: bool = false
var horizon_ready: bool = false
var fallback_reason: String = ""
var bake_report: Dictionary = {}

var height: Texture2DArray
var terrain_normal: Texture2DArray
var map_index: Texture2DArray
var flow: Texture2DArray
var water_depth: Texture2DArray
var terrain_detail: Texture2DArray
var edge_neighbor: Texture2DArray
var edge_distance: Texture2DArray
var horizon: Texture2DArray


func initialize_empty(resolved_layout) -> bool:
	layout = resolved_layout
	if layout == null or layout.mode == VisualTileLayoutScript.MODE_LEGACY or layout.layer_count <= 0:
		fallback_reason = "invalid_layout"
		return false
	for field_name in FIELD_FORMATS:
		var texture := _create_empty_array(int(FIELD_FORMATS[field_name]))
		if texture == null:
			fallback_reason = "array_create_failed:%s" % field_name
			clear()
			return false
		set(field_name, texture)
	return true


func upload_layer_bundle(layer_id: int, bundle: Dictionary) -> bool:
	if layout == null or layer_id < 0 or layer_id >= layout.layer_count:
		fallback_reason = "invalid_layer"
		return false
	for field_name in FIELD_FORMATS:
		if field_name == "horizon" or not bundle.has(field_name):
			continue
		var data: PackedByteArray = bundle[field_name]
		var format: int = int(FIELD_FORMATS[field_name])
		var expected: int = layout.layer_size.x * layout.layer_size.y * _format_stride(format)
		if data.size() != expected:
			fallback_reason = "invalid_payload:%s:%d/%d" % [field_name, data.size(), expected]
			return false
		var image := Image.create_from_data(
			layout.layer_size.x, layout.layer_size.y, false, format, data
		)
		var texture: Texture2DArray = get(field_name)
		texture.update_layer(image, layer_id)
	return true


func upload_horizon_layer(layer_id: int, data: PackedByteArray) -> bool:
	if layout == null or horizon == null or layer_id < 0 or layer_id >= layout.layer_count:
		return false
	var expected: int = layout.layer_size.x * layout.layer_size.y * 4
	if data.size() != expected:
		return false
	var image := Image.create_from_data(
		layout.layer_size.x, layout.layer_size.y, false, Image.FORMAT_RGBA8, data
	)
	horizon.update_layer(image, layer_id)
	return true


func clear() -> void:
	ready = false
	static_ready = false
	horizon_ready = false
	for field_name in FIELD_FORMATS:
		set(field_name, null)


func _create_empty_array(format: int) -> Texture2DArray:
	var images: Array[Image] = []
	images.resize(layout.layer_count)
	for layer_id in range(layout.layer_count):
		var image := Image.create_empty(
			layout.layer_size.x, layout.layer_size.y, false, format
		)
		image.fill(Color(0.0, 0.0, 0.0, 0.0))
		images[layer_id] = image
	var texture := Texture2DArray.new()
	if texture.create_from_images(images) != OK:
		return null
	return texture


static func _format_stride(format: int) -> int:
	match format:
		Image.FORMAT_L8:
			return 1
		Image.FORMAT_RG8:
			return 2
		Image.FORMAT_RGBA8:
			return 4
		_:
			return 0
