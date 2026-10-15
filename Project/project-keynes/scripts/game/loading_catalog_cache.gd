extends RefCounted
class_name LoadingCatalogCache

## Build products only. Source catalogs and compiler APIs remain authoritative.
## Editor runs validate all catalog sources on the native loading coordinator;
## export regenerates the snapshots before packing them.
const DIRECTORY := "res://data/loading_catalog_v1/"
static var _ready := false
static var _economy: Dictionary = {}
static var _effect: Resource
static var _display: Dictionary = {}
static var _technology: Dictionary = {}
static var _research: Dictionary = {}

static func economy_catalog() -> Dictionary:
	return _economy.duplicate(true) if _ready else {}

static func effect_catalog() -> Resource:
	if not _ready or _effect == null:
		return null
	var result := _effect.duplicate(true)
	# This is runtime IR, deliberately not an exported authoring property.
	result.set("native_extensions",(_effect.get("native_extensions") as Dictionary).duplicate(true))
	return result

static func economy_display() -> Dictionary:
	return _display.duplicate(true) if _ready else {}

static func technology_catalog() -> Dictionary:
	return _technology.duplicate(true) if _ready else {}

static func research_catalog() -> Dictionary:
	return _research.duplicate(true) if _ready else {}

static func invalidate() -> void:
	_ready = false
	_economy.clear()
	_effect = null
	_display.clear()
	_technology.clear()
	_research.clear()

static func prepare(ext: Object) -> void:
	if _ready:
		return
	var manifest_path := DIRECTORY+"sources.json"
	if not FileAccess.file_exists(manifest_path):
		return
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary or manifest.is_empty():
		return
	if OS.has_feature("editor"):
		var validated: Dictionary = await NativeLoadingTasks.compute(ext,"catalog_manifest", {"files":manifest})
		if not bool(validated.get("valid",false)):
			push_warning("[loading-catalog] source changed: rebuild tools/prebake_loading_catalogs.gd; using source compiler")
			return
	var paths := [DIRECTORY+"economy.res",DIRECTORY+"effect.res",DIRECTORY+"display.res",DIRECTORY+"technology.res",DIRECTORY+"effect_extensions.res",DIRECTORY+"research.res"]
	for path: String in paths:
		if not ResourceLoader.exists(path):
			return
		ResourceLoader.load_threaded_request(path)
	var tree := Engine.get_main_loop() as SceneTree
	var resources: Array[Resource] = []
	for path: String in paths:
		while tree != null and ResourceLoader.load_threaded_get_status(path)==ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await tree.process_frame
		if ResourceLoader.load_threaded_get_status(path)!=ResourceLoader.THREAD_LOAD_LOADED:
			return
		resources.append(ResourceLoader.load_threaded_get(path))
	_economy = resources[0].get("columns")
	_effect = resources[1]
	_display = resources[2].get("columns")
	_technology = resources[3].get("columns")
	_research = resources[5].get("columns")
	_effect.set("native_extensions",resources[4].get("columns"))
	_ready = bool(_economy.get("ok",false)) and _effect != null
