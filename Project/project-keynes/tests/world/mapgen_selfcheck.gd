extends SceneTree
## `--mapgen-selfcheck` 的独立入口（桌面 / headless / CI）。
##
## 打印一份 JSON：GDExtension 是否加载、native_generation_mode 是否 ACTIVE、
## DCWorldExt 是否可实例化、生成必需的原生方法是否齐全，并额外用 16x12 小图
## 真跑一次 run_native_world_generate_base_pass（"方法存在"不等于"内核能跑"）。
##
## 跑法：
##   Godot_v4.6.2-stable_win64_console.exe --headless --path <project> \
##       --script res://tests/world/mapgen_selfcheck.gd
##
## 安卓等价机制：进游戏场景后 world_runtime_host 会在每次生成前自动跑同一份
## preflight 并打印 `[mapgen][preflight]` / `[mapgen][selfcheck]`，用
##   adb logcat -s godot:* | findstr "mapgen"
## 即可取到同一份 JSON。

var _report: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var generator := MapGenerator.new()
	_report = generator.run_mapgen_selfcheck(true)
	print("[mapgen-selfcheck] --- pretty ---")
	print(JSON.stringify(_report, "  ", true))
	var ok := bool(_report.get("ok", false))
	print("[mapgen-selfcheck] RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
