class_name VisualTileSet
extends RefCounted

const VisualTileLayoutScript = preload("res://scripts/rendering/visual_tile_layout.gd")

# [terrain-gi 2026-07-31] gi_occluder 与 horizon 一样由 compute 异步产出（不是静态 bake
# bundle 的一部分），RG=主导遮挡源 cell id 低/高字节，BA=次遮挡源，0xFFFF=无有效遮挡源。
# 新增 4 bytes/texel，合计 22——visual_tile_layout.BYTES_PER_PHYSICAL_TEXEL 必须同步。
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
	"gi_occluder": Image.FORMAT_RGBA8,
}

# 由异步 compute 而非静态 bundle 填充的字段。upload_layer_bundle 必须跳过它们，
# 否则未就绪的中性层会被静态 bundle 覆盖成垃圾。
const COMPUTE_FIELDS := ["horizon", "gi_occluder"]

var layout
var ready: bool = false
var static_ready: bool = false
var horizon_ready: bool = false
var gi_occluder_ready: bool = false
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
var gi_occluder: Texture2DArray


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
		if field_name in COMPUTE_FIELDS or not bundle.has(field_name):
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
	return _upload_compute_layer("horizon", layer_id, data)


# [terrain-gi 2026-07-31] 遮挡源 cell id 层。与 horizon 同一次 compute 产出、同一 generation
# 校验；调用方只有在全部层上传成功后才置 gi_occluder_ready。
func upload_gi_occluder_layer(layer_id: int, data: PackedByteArray) -> bool:
	return _upload_compute_layer("gi_occluder", layer_id, data)


func _upload_compute_layer(field_name: String, layer_id: int, data: PackedByteArray) -> bool:
	var texture: Texture2DArray = get(field_name)
	if layout == null or texture == null or layer_id < 0 or layer_id >= layout.layer_count:
		return false
	var expected: int = layout.layer_size.x * layout.layer_size.y * 4
	if data.size() != expected:
		return false
	var image := Image.create_from_data(
		layout.layer_size.x, layout.layer_size.y, false, Image.FORMAT_RGBA8, data
	)
	texture.update_layer(image, layer_id)
	return true


func clear() -> void:
	ready = false
	static_ready = false
	horizon_ready = false
	gi_occluder_ready = false
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
