extends RefCounted

## 预烘（prebake）实现：把 effect/economy/technology/research/display 五套目录编译结果
## 固化成 `res://data/loading_catalog_v1/*.res` 快照，新开游戏时直接反序列化命中，
## 不再每次重编译 4–5 秒。
##
## 关键约束：bake() 只能在“游戏/脚本模式”的进程里跑（`--headless --script`）。
## 编辑器进程（含 EditorExportPlugin._export_begin）里 `ScriptServer` 的 scripting
## 是关闭的，非 @tool 脚本挂到 Resource 上只会得到占位脚本实例
## （PlaceHolderScriptInstance）：`.tres` 里没有显式存储的属性（即脚本默认值）
## 一律读成 null。economy_catalog.gd:91 的 `need.use_tags as PackedStringArray`
## 会在 null 上抛 “Invalid cast” 并中断整个编译，bake() 于是返回
## ERR_INVALID_DATA —— 这就是导出 hook 里 “Loading catalog export bake failed:
## Invalid data” 的真实原因。更隐蔽的是：即使绕开这处 cast，占位实例也会让
## `satisfaction_weight_q16` 之类的脚本默认值静默变成 0，烘出错误快照。
##
## 因此导出插件不在此进程内编译，而是用 run_prebake_subprocess() 拉起一个独立的
## headless 子进程跑本文件的 CLI 入口 tools/prebake_loading_catalogs.gd。

const Snapshot = preload("res://scripts/game/loading_catalog_snapshot.gd")
const Economy = preload("res://scripts/economy/economy_catalog.gd")
const Effects = preload("res://scripts/effect/effect_domain_catalog.gd")
const Cache = preload("res://scripts/game/loading_catalog_cache.gd")
const Facade = preload("res://scripts/economy/economy_facade.gd")
const Technology = preload("res://scripts/economy/technology_catalog.gd")

const PREBAKE_SCRIPT := "res://tools/prebake_loading_catalogs.gd"
## 导出插件要打包的快照文件（顺序固定，报告里也用它列字节数）。
const SNAPSHOT_FILES := [
	"economy.res", "effect.res", "effect_extensions.res", "display.res",
	"technology.res", "research.res", "sources.json",
]

## 独立可跑的预烘命令，供日志/文档直接照抄。
static func prebake_command() -> String:
	return "%s --headless --path %s --script %s" % [
		OS.get_executable_path(),
		ProjectSettings.globalize_path("res://").trim_suffix("/"),
		PREBAKE_SCRIPT,
	]

## 编译并写出全部快照。返回 OK 才代表磁盘上的 7 个文件互相一致且可用。
static func bake() -> Error:
	var started := Time.get_ticks_msec()
	Cache.invalidate()
	var make_err := DirAccess.make_dir_recursive_absolute(Cache.DIRECTORY)
	if make_err != OK and make_err != ERR_ALREADY_EXISTS:
		push_error("[loading-catalog] 无法创建快照目录 %s: %s" % [Cache.DIRECTORY, error_string(make_err)])
		return make_err

	var step := Time.get_ticks_msec()
	var snapshot := Snapshot.new()
	snapshot.columns = Economy.compile_native_catalog()
	var economy_ms := Time.get_ticks_msec() - step
	if not bool(snapshot.columns.get("ok", false)):
		push_error("[loading-catalog] economy 目录编译失败: %s" % _reason_of(snapshot.columns))
		return ERR_INVALID_DATA
	print("[loading-catalog] economy   %6d ms  %d keys" % [economy_ms, snapshot.columns.size()])

	step = Time.get_ticks_msec()
	var effect: Resource = Effects.build()
	if effect == null:
		push_error("[loading-catalog] effect 目录编译失败: EffectDomainCatalog.build() 返回 null")
		return ERR_INVALID_DATA
	print("[loading-catalog] effect    %6d ms" % [Time.get_ticks_msec() - step])

	step = Time.get_ticks_msec()
	var visual := Facade.new()
	visual._profession_display_names = Facade._load_display_names(Economy.PROFESSION_DIR)
	visual._ethnicity_display_names = Facade._load_display_names(Economy.ETHNICITY_DIR)
	visual._building_display_names = Facade._load_display_names(Economy.BUILDING_DIR)
	visual._need_display_names = Economy.need_display_names()
	visual._good_display_names = Facade._load_display_names(Facade.GOOD_PROFILE_DIR)
	visual._load_family_effect_displays()
	var display := Snapshot.new()
	for field in ["_profession_display_names","_ethnicity_display_names","_building_display_names","_need_display_names","_good_display_names","_family_trait_descriptions","_family_trait_copy","_family_trait_effect_keys","_family_effect_displays","_family_modifier_displays","_family_trigger_displays"]:
		display.columns[field] = visual.get(field)
	print("[loading-catalog] display   %6d ms" % [Time.get_ticks_msec() - step])

	step = Time.get_ticks_msec()
	var technology := Snapshot.new()
	technology.columns = Technology.compile_native_catalog()
	if not bool(technology.columns.get("ok", true)):
		push_error("[loading-catalog] technology 目录编译失败: %s" % _reason_of(technology.columns))
		return ERR_INVALID_DATA
	var research := Snapshot.new()
	research.columns = ResearchSignalCatalog.compile_native_catalog()
	if not bool(research.columns.get("ok", false)):
		push_error("[loading-catalog] research 目录编译失败: %s" % _reason_of(research.columns))
		return ERR_INVALID_DATA
	print("[loading-catalog] technology+research %6d ms" % [Time.get_ticks_msec() - step])

	var extensions := Snapshot.new()
	extensions.columns = effect.get("native_extensions")
	var payload := {
		"economy.res": snapshot,
		"effect.res": effect,
		"effect_extensions.res": extensions,
		"display.res": display,
		"technology.res": technology,
		"research.res": research,
	}
	for filename: String in payload:
		step = Time.get_ticks_msec()
		var err := ResourceSaver.save(payload[filename], Cache.DIRECTORY + filename, ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			push_error("[loading-catalog] 写入 %s 失败: %s" % [filename, error_string(err)])
			return err
		print("[loading-catalog] saved     %-22s %8d bytes  %5d ms" % [
			filename, _file_size(Cache.DIRECTORY + filename), Time.get_ticks_msec() - step])

	step = Time.get_ticks_msec()
	var files: Dictionary = {}
	for dir in ["res://scripts/research", "res://data", "res://scripts/economy", "res://scripts/family", "res://scripts/effect", "res://scripts/ideology", "res://scripts/modifier", "res://scripts/trigger", "res://scripts/data", "res://scripts/country"]:
		_collect_sources(dir, files)
	var manifest_path := Cache.DIRECTORY + "sources.json"
	var file := FileAccess.open(manifest_path, FileAccess.WRITE)
	if file == null:
		var open_err := FileAccess.get_open_error()
		push_error("[loading-catalog] 写入 %s 失败: %s" % [manifest_path, error_string(open_err)])
		return open_err
	file.store_string(JSON.stringify(files,"\t",true))
	file = null
	print("[loading-catalog] saved     %-22s %8d bytes  %5d ms  %d entries" % [
		"sources.json", _file_size(manifest_path), Time.get_ticks_msec() - step, files.size()])

	# 自检：任何接口写错（例如路径打错）都要在这里暴露，而不是等到玩家进游戏 miss。
	var status := manifest_status()
	if not bool(status.get("fresh", false)):
		push_error("[loading-catalog] 快照清单自检失败: %s" % String(status.get("reason", "")))
		return ERR_FILE_CORRUPT
	var snapshots := snapshot_status()
	if not bool(snapshots.get("ok", false)):
		push_error("[loading-catalog] 快照文件缺失: %s" % ", ".join(snapshots.get("missing", [])))
		return ERR_FILE_MISSING_DEPENDENCIES
	print("[loading-catalog] bake OK, %d files, total %d ms" % [
		SNAPSHOT_FILES.size(), Time.get_ticks_msec() - started])
	return OK

## 比对 sources.json 里记录的 sha256 与磁盘现状。不依赖 native 侧，编辑器内也能跑。
static func manifest_status() -> Dictionary:
	var manifest_path := Cache.DIRECTORY + "sources.json"
	if not FileAccess.file_exists(manifest_path):
		return {"fresh": false, "entries": 0, "reason": "缺少快照清单 %s" % manifest_path}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	if not parsed is Dictionary or parsed.is_empty():
		return {"fresh": false, "entries": 0, "reason": "快照清单不是非空 JSON 对象: %s" % manifest_path}
	var files: Dictionary = parsed
	var changed := PackedStringArray()
	var missing := PackedStringArray()
	for path in files.keys():
		var actual := FileAccess.get_sha256(String(path))
		if actual.is_empty():
			missing.append(String(path))
		elif actual != String(files[path]):
			changed.append(String(path))
	if changed.is_empty() and missing.is_empty():
		return {"fresh": true, "entries": files.size(), "reason": ""}
	var first: String = changed[0] if not changed.is_empty() else missing[0]
	return {
		"fresh": false,
		"entries": files.size(),
		"changed": changed,
		"missing": missing,
		"reason": "源文件已变更 %d 个、缺失 %d 个（首个：%s）" % [
			changed.size(), missing.size(), first],
	}

## 检查 7 个快照文件是否都在、字节数多少。
static func snapshot_status() -> Dictionary:
	var sizes: Dictionary = {}
	var missing := PackedStringArray()
	for filename: String in SNAPSHOT_FILES:
		var path := Cache.DIRECTORY + filename
		if not FileAccess.file_exists(path):
			missing.append(filename)
			continue
		sizes[filename] = _file_size(path)
	return {"ok": missing.is_empty(), "sizes": sizes, "missing": missing}

## 在独立 headless 子进程里重烘（编辑器进程内不能编译，原因见文件头注释）。
## OS.execute 是同步阻塞的：_export_begin 不允许 await / 线程，这里也不需要。
static func run_prebake_subprocess() -> Dictionary:
	var args := PackedStringArray([
		"--headless",
		"--path", ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"--script", PREBAKE_SCRIPT,
	])
	var output: Array = []
	var started := Time.get_ticks_msec()
	var exit_code := OS.execute(OS.get_executable_path(), args, output, true)
	var joined := ""
	for line in output:
		joined += String(line)
	return {
		"ok": exit_code == 0,
		"exit_code": exit_code,
		"elapsed_ms": Time.get_ticks_msec() - started,
		"output": joined,
		"command": prebake_command(),
	}

## 预烘报告：每个 .res 的字节数、清单条目数、耗时，CLI 与导出日志共用。
static func describe_snapshots() -> String:
	var lines := PackedStringArray()
	var snapshots := snapshot_status()
	for filename: String in SNAPSHOT_FILES:
		var path := Cache.DIRECTORY + filename
		if not bool(snapshots.get("ok", false)) and not FileAccess.file_exists(path):
			lines.append("  %-22s MISSING" % filename)
			continue
		lines.append("  %-22s %8d bytes" % [filename, _file_size(path)])
	return "\n".join(lines)

static func _reason_of(columns: Dictionary) -> String:
	var reason := String(columns.get("reason", ""))
	return reason if not reason.is_empty() else "ok=false（未给出 reason）"

static func _file_size(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return -1
	return file.get_length()

static func _collect_sources(directory: String, files: Dictionary) -> void:
	if directory == Cache.DIRECTORY.trim_suffix("/"):
		return
	var dir := DirAccess.open(directory)
	if dir == null:
		return
	for name in dir.get_files():
		if name.get_extension() in ["gd","tres","json","csv"]:
			var path := directory+"/"+name
			files[path] = FileAccess.get_sha256(path)
	for name in dir.get_directories():
		_collect_sources(directory+"/"+name,files)
