class_name ResourceArtLibrary
extends RefCounted

# Generated bitmap art for the resource world view (built by tools/resource_art/build.py,
# manifest v2). Three Texture2DArrays:
#   cover_albedo / cover_normal  16 seamless 512px ground-cover layers: 13 wild plant
#                                communities, then grazing traces (pasture, mud, sand).
#                                Normal strip: RG = tangent normal, B = height, A = AO.
#   fauna                        9 layers of 4x2 top-down sprites (128px cells, heads up).
#   crown / crown_normal         4 layers (broadleaf, conifer, palm, shrub) of 4x2 single-tree
#                                crowns (256px cells, alpha), sampled by vegetation_forms.
# The imported CompressedTexture2DArray (VRAM, mipmapped) is preferred; when the import is
# missing (fresh checkout before the editor ran) the PNG strip is sliced at runtime.

const ROOT := "res://assets/textures/resource_art/"
const MANIFEST := ROOT + "manifest.json"
const FAUNA_COLS := 4
const FAUNA_ROWS := 2

var version := 0
var cover_albedo: TextureLayered
var cover_normal: TextureLayered
var fauna: TextureLayered
var fauna_count := 0
var crown: TextureLayered
var crown_normal: TextureLayered
var _cover_layer: Dictionary = {}  # id -> layer
var _fauna_layer: Dictionary = {}  # id -> layer
var _trace_for: Dictionary = {}    # fauna id -> trace id

static var _shared: ResourceArtLibrary

static func shared() -> ResourceArtLibrary:
	if _shared == null:
		_shared = ResourceArtLibrary.new()
		_shared._load()
	return _shared

func available() -> bool:
	return cover_albedo != null or fauna != null

func cover_layer(id: String) -> int:
	return int(_cover_layer.get(id, -1))

func fauna_layer(id: String) -> int:
	return int(_fauna_layer.get(id, -1))

## Cover layer of the ground trace drawn under a herd (-1 = none, e.g. fish).
func trace_layer_for(id: String) -> int:
	return cover_layer(String(_trace_for.get(id, "")))

func cover_layer_count() -> int:
	return _cover_layer.size()

func _load() -> void:
	if not FileAccess.file_exists(MANIFEST):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("version", 0)) < 2:
		push_warning("resource art manifest missing or older than v2")
		return
	version = int(parsed.version)
	var cover: Dictionary = parsed.get("cover", {})
	var layers: Array = cover.get("layers", [])
	for i in layers.size():
		_cover_layer[String(layers[i].id)] = i
	if not layers.is_empty():
		cover_albedo = _array(ROOT + String(cover.albedo), layers.size())
		cover_normal = _array(ROOT + String(cover.normal), layers.size())
	var fa: Dictionary = parsed.get("fauna", {})
	var fl: Array = fa.get("layers", [])
	fauna_count = clampi(int(fa.get("count", FAUNA_COLS * FAUNA_ROWS)), 1, FAUNA_COLS * FAUNA_ROWS)
	for i in fl.size():
		_fauna_layer[String(fl[i].id)] = i
		_trace_for[String(fl[i].id)] = String(fl[i].get("trace", ""))
	if not fl.is_empty():
		fauna = _array(ROOT + String(fa.file), fl.size())
	var cr: Dictionary = parsed.get("crown", {})
	var cl: Array = cr.get("layers", [])
	if not cl.is_empty():
		crown = _array(ROOT + String(cr.file), cl.size())
		crown_normal = _array(ROOT + String(cr.normal), cl.size())

func _array(path: String, slices: int) -> TextureLayered:
	if ResourceLoader.exists(path):
		var imported = load(path)
		if imported is TextureLayered and (imported as TextureLayered).get_layers() == slices:
			return imported
	# Fallback: slice the vertical strip ourselves.
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty() or image.get_height() % slices != 0:
		push_warning("resource art missing or malformed: " + path)
		return null
	if image.get_format() != Image.FORMAT_RGBA8:
		image.convert(Image.FORMAT_RGBA8)
	var h := image.get_height() / slices
	var images: Array[Image] = []
	for i in slices:
		var layer := image.get_region(Rect2i(0, i * h, image.get_width(), h))
		layer.generate_mipmaps()
		images.append(layer)
	var tex := Texture2DArray.new()
	tex.create_from_images(images)
	return tex
