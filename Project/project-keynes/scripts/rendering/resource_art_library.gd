class_name ResourceArtLibrary
extends RefCounted

# Generated bitmap art for the resource world view (built by tools/resource_art/build.py,
# manifest v3). Generated arrays:
#   cover_albedo / cover_normal  16 seamless 512px ground-cover layers: 13 wild plant
#                                communities, then grazing traces (pasture, mud, sand).
#                                Normal strip: RG = tangent normal, B = height, A = AO.
#   fauna                        9 layers of 4x2 top-down sprites (128px cells, heads up).
#   crown / crown_normal         7 layers of 4x2 sprites (256px cells, alpha) for all
#                                vegetation and hardscape forms, plus leafless broadleaf.
#   material                     2 layers sharing one 8x4, 128px-cell atlas:
#                                layer 0 = albedo, layer 1 = RG normal/B height/A AO.
#                                Used by resource props, ground decals and lens badges.
# The imported CompressedTexture2DArray (VRAM, mipmapped) is preferred; when the import is
# missing (fresh checkout before the editor ran) the PNG strip is sliced at runtime.

const ROOT := "res://assets/textures/resource_art/"
const MANIFEST := ROOT + "manifest.json"
const CROWN_LAYERS := 7
const FAUNA_COLS := 4
const FAUNA_ROWS := 2

var version := 0
var cover_albedo: TextureLayered
var cover_normal: TextureLayered
var fauna: TextureLayered
var fauna_count := 0
var crown: TextureLayered
var crown_normal: TextureLayered
var material: TextureLayered
var _cover_layer: Dictionary = {}  # id -> layer
var _fauna_layer: Dictionary = {}  # id -> layer
var _trace_for: Dictionary = {}    # fauna id -> trace id
var _material_cell: Dictionary = {} # resource id -> atlas cell

static var _shared: ResourceArtLibrary

static func shared() -> ResourceArtLibrary:
	if _shared == null:
		_shared = ResourceArtLibrary.new()
		_shared._load()
	return _shared

func available() -> bool:
	return cover_albedo != null or fauna != null or crown != null or material != null

func cover_layer(id: String) -> int:
	return int(_cover_layer.get(id, -1))

func fauna_layer(id: String) -> int:
	return int(_fauna_layer.get(id, -1))

## Cover layer of the ground trace drawn under a herd (-1 = none, e.g. fish).
func trace_layer_for(id: String) -> int:
	return cover_layer(String(_trace_for.get(id, "")))

func material_cell(id: String) -> int:
	return int(_material_cell.get(id, -1))

func cover_layer_count() -> int:
	return _cover_layer.size()

func _load() -> void:
	# Decoration rendering only needs the two imported arrays. Its layer order is
	# fixed, so it can load even when a package omits the resource manifest JSON.
	crown = _array(ROOT + "crown_atlas.png", CROWN_LAYERS)
	crown_normal = _array(ROOT + "crown_normal.png", CROWN_LAYERS)
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
	var ma: Dictionary = parsed.get("material", {})
	var mids: Array = ma.get("ids", [])
	for i in mids.size():
		if String(mids[i]).is_empty():
			continue
		_material_cell[String(mids[i])] = i
	if not mids.is_empty():
		material = _array(ROOT + String(ma.file), 2)
	# [resource-art-diagnostics 2026-11-17] 一行可 grep 的到货清单。
	#
	# 起因：真机上"地面点缀全部变成纯色方块"，而 _array() 失败只 push_warning ——
	# 导出版里 push_warning 没有任何出口（无控制台、不进 user://logs），于是"图集
	# 没进包"与"图集在但画质档被压到 0"这两种完全不同的故障在玩家侧长得一模一样。
	# 这条 print 走 stdout，`adb logcat | grep resource_art` 就能一眼分开：
	#   cover=16 fauna=9 crown=7 material=2  → 图集正常，问题在渲染档位
	#   FAILED=...                          → 图集缺失或格式不符
	print("[resource_art] v%d cover=%d fauna=%d crown=%d material=%d%s" % [
		version, _layer_count(cover_albedo), _layer_count(fauna),
		_layer_count(crown), _layer_count(material),
		"" if _array_failures.is_empty() else " FAILED=" + ", ".join(PackedStringArray(_array_failures))])


static func _layer_count(tex: TextureLayered) -> int:
	return (tex.get_layers() if tex != null else -1)


## 本次进程内加载失败的图集路径（只用于上面那行诊断输出）。
static var _array_failures: Array[String] = []

func _array(path: String, slices: int) -> TextureLayered:
	if ResourceLoader.exists(path):
		var imported = load(path)
		if imported is TextureLayered and (imported as TextureLayered).get_layers() == slices:
			return imported
	# Fallback: slice the vertical strip ourselves.
	# 注意：APK/IPA 里资源在包内，globalize_path 得到的不是可读文件，这条路只对
	# 编辑器与源码目录有效。导出包走到这里就是要失败 —— 记进 _array_failures，
	# 由 _load() 的收尾 print 暴露出来，不要指望 push_warning 有人看得到。
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty() or image.get_height() % slices != 0:
		push_warning("resource art missing or malformed: " + path)
		_array_failures.append(path.get_file())
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
