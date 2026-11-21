extends RefCounted
class_name LoadingCatalogCache

## 预烘快照的运行时读取端。快照由 `tools/prebake_loading_catalogs.gd` 在独立进程里
## 生成（`--headless --script`），产物固定为 `res://data/loading_catalog_v1/` 下的
## 7 个文件。源目录与编译器 API 仍是权威数据源，这里只加速冷启动。
##
## 缓存不命中的代价：新开游戏要现场编译 effect/economy 目录，实测多花 4–5 秒。
## 不命中的原因一定会在下面的 push_warning 里写明（清单缺失 / 指纹不一致 /
## 快照文件缺失 / 加载失败 / economy 快照 ok=false），照着提示重烘即可。
const ResourceRequest = preload("res://scripts/game/loading_resource_request.gd")
const DIRECTORY := "res://data/loading_catalog_v1/"
const PREBAKE_SCRIPT := "res://tools/prebake_loading_catalogs.gd"
const SNAPSHOT_FILES := [
	"economy.res", "effect.res", "display.res",
	"technology.res", "effect_extensions.res", "research.res",
]
static var _ready := false
static var _economy: Dictionary = {}
static var _effect: Resource
static var _effect_columns: Dictionary = {}
static var _display: Dictionary = {}
static var _technology: Dictionary = {}
static var _research: Dictionary = {}

static func economy_catalog() -> Dictionary:
	return _economy.duplicate(true) if _ready else {}

static func effect_catalog() -> Resource:
	if not _ready or _effect == null:
		return null
	# 共享只读实例：命中后不再 duplicate(true) 整份 ~110KB IR。
	# 大容器（definitions/instructions/...）按引用共享，调用方只读；
	# native_extensions 是运行时会单独下发的一份，只复制它。
	var result := _effect.duplicate(false)
	result.set("native_extensions",(_effect.get("native_extensions") as Dictionary).duplicate(true))
	return result

static func effect_native_columns() -> Dictionary:
	return _effect_columns.duplicate(true) if _ready else {}

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
	_effect_columns = {}
	_display.clear()
	_technology.clear()
	_research.clear()

static func prepare(ext: Object, frame_gate = null, directory: String = DIRECTORY) -> void:
	if _ready:
		return
	var manifest_path := directory.path_join("sources.json")
	if not FileAccess.file_exists(manifest_path):
		_miss("缺少快照清单 %s" % manifest_path)
		return
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary or (manifest as Dictionary).is_empty():
		_miss("快照清单为空或 JSON 解析失败（%s）" % manifest_path)
		return
	if OS.has_feature("editor"):
		var validated: Dictionary = await NativeLoadingTasks.compute(ext,"catalog_manifest", {"files":manifest}, frame_gate)
		if frame_gate != null and frame_gate.canceled:
			return
		if not bool(validated.get("valid",false)):
			_miss("快照清单与当前源文件指纹不一致（%d 条指纹，可能改过 scripts/ 或 data/）" % (manifest as Dictionary).size())
			return
	var missing := PackedStringArray()
	for filename: String in SNAPSHOT_FILES:
		if not ResourceLoader.exists(directory.path_join(filename)):
			missing.append(filename)
	if not missing.is_empty():
		_miss("快照文件缺失：%s" % ", ".join(missing))
		return
	var paths := PackedStringArray()
	for filename: String in SNAPSHOT_FILES:
		paths.append(directory.path_join(filename))
	var resources: Array[Resource] = await _load_snapshots(paths, frame_gate)
	if resources.size() != SNAPSHOT_FILES.size():
		return
	_economy = resources[0].get("columns")
	_effect = resources[1]
	_display = resources[2].get("columns")
	_technology = resources[3].get("columns")
	_research = resources[5].get("columns")
	var effect_data: Dictionary = resources[4].get("columns")
	# Earlier prebakes store only the extension keys in this file. They still
	# provide the Resource; its columns will be compiled on the loading path.
	_effect.set("native_extensions", effect_data.get("native_extensions", effect_data))
	var compiled = effect_data.get("compiled_catalog", {})
	if compiled is Dictionary and bool(compiled.get("ok", false)):
		_effect_columns = compiled
	_ready = bool(_economy.get("ok",false)) and _effect != null
	if not _ready:
		_miss("economy 快照无效（ok=false），快照可能来自不完整的 bake")

## All requests own their completion independently. Failure or cancellation can
## return immediately without synchronously waiting for the remaining files.
static func _load_snapshots(paths: PackedStringArray, frame_gate = null) -> Array[Resource]:
	if frame_gate != null and frame_gate.canceled:
		return []
	var requests: Array = []
	for path in paths:
		requests.append(ResourceRequest.new(path))
	var resources: Array[Resource] = []
	var tree := Engine.get_main_loop() as SceneTree
	for index in range(requests.size()):
		var request = requests[index]
		while not request.finished:
			await (frame_gate.next_frame() if frame_gate != null else tree.process_frame)
			if frame_gate != null and frame_gate.canceled:
				return []
		if request.result == null:
			_miss("快照加载失败：%s" % paths[index])
			return []
		resources.append(request.result)
	return resources

## 命中失败的唯一出口：写清原因，并给出可直接照抄的重烘命令。
static func _miss(reason: String) -> void:
	push_warning("[loading-catalog] 预烘快照未命中：%s。本次新游戏将回退到源编译器（多花 4–5 秒）。重烘：%s" % [
		reason, _rebuild_command()])

static func _rebuild_command() -> String:
	return "%s --headless --path %s --script %s" % [
		OS.get_executable_path(),
		ProjectSettings.globalize_path("res://").trim_suffix("/"),
		PREBAKE_SCRIPT,
	]
