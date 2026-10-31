@tool
extends EditorPlugin

## 导出时把预烘快照打进包。
##
## 关键背景：_export_begin 跑在编辑器进程里，此时 ScriptServer 的 scripting 是关闭的，
## 非 @tool 脚本挂到 Resource 上只会得到占位实例，.tres 里未显式存储的属性（脚本默认
## 值）一律读成 null。所以**不能**在这里调用 baker.bake()：economy_catalog.gd:91 的
## `need.use_tags as PackedStringArray` 会直接抛 “Invalid cast” 让 bake 返回
## ERR_INVALID_DATA（历史现象），而且即使绕过也会烘出默认值变成 0 的错误快照。
##
## 现在的策略：
##   1) 先校验 sources.json 与当前源文件的 sha256 是否一致（编辑器内可做，不加载资源）；
##   2) 不一致就拉起独立的 headless 子进程跑 tools/prebake_loading_catalogs.gd 重烘
##      （OS.execute 同步阻塞，符合 _export_begin 不能 await / 不能用线程的约束）；
##   3) 仍然不一致时 push_error 给出可直接照抄的命令，并且**不写 {}**——继续打包磁盘上
##      已有的快照，至少让导出包能启动，错误在导出日志里一眼可见；
##   4) 校验通过后用 add_file() 把 7 个快照打进 pck。
##
## 正常流程里预烘已经在 Build-Web.cmd 里先跑过，这里只会走第 1、4 步。

const BAKE_SCRIPT := "res://tools/loading_catalog_bake.gd"

class CatalogExport extends EditorExportPlugin:
	func _get_name() -> String:
		return "LoadingCatalogPrebake"

	func _export_begin(_features: PackedStringArray,_debug: bool,_path: String,_flags: int) -> void:
		var baker = load(BAKE_SCRIPT)
		if baker == null:
			push_error("[loading-catalog] 无法加载 %s，导出将没有预烘快照。请检查脚本是否被改名/删除。" % BAKE_SCRIPT)
			return
		var status: Dictionary = baker.manifest_status()
		if not bool(status.get("fresh", false)):
			push_warning("[loading-catalog] 导出前快照过期：%s；尝试拉起独立进程重烘……" % String(status.get("reason", "")))
			var run: Dictionary = baker.run_prebake_subprocess()
			for line in String(run.get("output", "")).split("\n"):
				if line.contains("[loading-catalog]"):
					print(line)
			if not bool(run.get("ok", false)):
				push_error("[loading-catalog] 导出内预烘失败（exit=%d，%d ms）：\n%s" % [
					int(run.get("exit_code", -1)), int(run.get("elapsed_ms", 0)),
					String(run.get("output", ""))])
			status = baker.manifest_status()
		if not bool(status.get("fresh", false)):
			push_error("[loading-catalog] 预烘失败，导出继续使用磁盘上的旧快照（新开游戏会回退到源编译器，多花 4–5 秒）。请先手动运行：\n%s\n失败原因：%s" % [
				String(baker.prebake_command()), String(status.get("reason", ""))])
		else:
			print("[loading-catalog] 快照校验通过：%d 条源指纹，打包 7 个快照文件。" % int(status.get("entries", 0)))
		var snapshots: Dictionary = baker.snapshot_status()
		if not bool(snapshots.get("ok", false)):
			push_error("[loading-catalog] 快照文件缺失：%s。请先运行：\n%s" % [
				", ".join(snapshots.get("missing", [])), String(baker.prebake_command())])
			return
		for filename in baker.SNAPSHOT_FILES:
			var path: String = "res://data/loading_catalog_v1/"+str(filename)
			add_file(path,FileAccess.get_file_as_bytes(path),false)

var _catalog_export: CatalogExport

func _enter_tree() -> void:
	_catalog_export=CatalogExport.new()
	add_export_plugin(_catalog_export)

func _exit_tree() -> void:
	remove_export_plugin(_catalog_export)
