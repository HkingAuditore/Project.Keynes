extends SceneTree

## 独立可跑的预烘入口（唯一受支持的 bake 运行方式）：
##   <godot> --headless --path <project> --script res://tools/prebake_loading_catalogs.gd
##
## 为什么必须是独立进程：编辑器进程（含导出 hook）里脚本占位实例会让 .tres 的
## 脚本默认值读成 null，bake 必然失败（详见 tools/loading_catalog_bake.gd 文件头）。
## 成功 exit 0 并打印每个快照的字节数；任何一步失败 exit 1。Build-Web.cmd 与
## 导出插件都依赖这个退出码，绝不静默降级。

const Bake = preload("res://tools/loading_catalog_bake.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	print("[loading-catalog] prebake start: %s" % Bake.prebake_command())
	var started := Time.get_ticks_msec()
	var err := Bake.bake()
	var elapsed := (Time.get_ticks_msec() - started) / 1000.0
	print("[loading-catalog] snapshots:\n%s" % Bake.describe_snapshots())
	var manifest := Bake.manifest_status()
	if err != OK:
		printerr("[loading-catalog] PREBAKE FAILED: %s (%.1fs)" % [error_string(err), elapsed])
		quit(1)
		return
	if not bool(manifest.get("fresh", false)):
		printerr("[loading-catalog] PREBAKE FAILED: 清单自检不通过（%s）" % String(manifest.get("reason", "")))
		quit(1)
		return
	print("[loading-catalog] PREBAKE OK: %d entries, %.1fs" % [int(manifest.get("entries", 0)), elapsed])
	quit(0)
