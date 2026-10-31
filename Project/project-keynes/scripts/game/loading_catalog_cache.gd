extends RefCounted
class_name LoadingCatalogCache

## 预烘快照的运行时读取端。快照由 `tools/prebake_loading_catalogs.gd` 在独立进程里
## 生成（`--headless --script`），产物固定为 `res://data/loading_catalog_v1/` 下的
## 7 个文件。源目录与编译器 API 仍是权威数据源，这里只加速冷启动。
##
## 缓存不命中的代价：新开游戏要现场编译 effect/economy 目录，实测多花 4–5 秒。
## 不命中的原因一定会在下面的 push_warning 里写明（清单缺失 / 指纹不一致 /
## 快照文件缺失 / 加载失败 / economy 快照 ok=false），照着提示重烘即可。
const DIRECTORY := "res://data/loading_catalog_v1/"
const PREBAKE_SCRIPT := "res://tools/prebake_loading_catalogs.gd"
const SNAPSHOT_FILES := [
	"economy.res", "effect.res", "display.res",
	"technology.res", "effect_extensions.res", "research.res",
]
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
	# 共享只读实例：命中后不再 duplicate(true) 整份 ~110KB IR。
	# 大容器（definitions/instructions/...）按引用共享，调用方只读；
	# native_extensions 是运行时会单独下发的一份，只复制它。
	var result := _effect.duplicate(false)
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
		_miss("缺少快照清单 %s" % manifest_path)
		return
	var manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not manifest is Dictionary or (manifest as Dictionary).is_empty():
		_miss("快照清单为空或 JSON 解析失败（%s）" % manifest_path)
		return
	if OS.has_feature("editor"):
		var validated: Dictionary = await NativeLoadingTasks.compute(ext,"catalog_manifest", {"files":manifest})
		if not bool(validated.get("valid",false)):
			_miss("快照清单与当前源文件指纹不一致（%d 条指纹，可能改过 scripts/ 或 data/）" % (manifest as Dictionary).size())
			return
	var missing := PackedStringArray()
	for filename: String in SNAPSHOT_FILES:
		if not ResourceLoader.exists(DIRECTORY+filename):
			missing.append(filename)
	if not missing.is_empty():
		_miss("快照文件缺失：%s" % ", ".join(missing))
		return
	var tree := Engine.get_main_loop() as SceneTree
	for filename: String in SNAPSHOT_FILES:
		ResourceLoader.load_threaded_request(DIRECTORY+filename)
	var resources: Array[Resource] = []
	for filename: String in SNAPSHOT_FILES:
		var path := DIRECTORY+filename
		while tree != null and ResourceLoader.load_threaded_get_status(path)==ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await tree.process_frame
		if ResourceLoader.load_threaded_get_status(path)!=ResourceLoader.THREAD_LOAD_LOADED:
			_miss("快照加载失败：%s" % path)
			return
		var loaded := ResourceLoader.load_threaded_get(path)
		if loaded == null:
			_miss("快照加载结果为 null：%s" % path)
			return
		resources.append(loaded)
	_economy = resources[0].get("columns")
	_effect = resources[1]
	_display = resources[2].get("columns")
	_technology = resources[3].get("columns")
	_research = resources[5].get("columns")
	var extensions = resources[4].get("columns")
	if extensions is Dictionary:
		_effect.set("native_extensions",extensions)
	_ready = bool(_economy.get("ok",false)) and _effect != null
	if not _ready:
		_miss("economy 快照无效（ok=false），快照可能来自不完整的 bake")

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
