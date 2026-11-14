extends SceneTree
## [web-cloud-shadow 2026-11-11] Web 导出期把云影预烘纹理降一半，导出后还原。
##
## 为什么单独做一个工具：`assets/textures/cloud_shadow/*.res` 里存的是 **裸 Image**
## （ResourceSaver.save(image, ...)，1024^2 RGBA8 + mipmap ≈ 5.6 MB），不是导入纹理，
## 所以 web_tex_downgrade.py 那套 `.import` 参数对它完全无效 —— 它没有任何 import
## 设置可调，只能改内容本身。
##
## 云影是低频的东西（预烘脚本自己的注释：每个云团直径约 62 texel），1080p 下
## 512² 与 1024² 在屏幕上分辨不出，但字节数只有 1/4。
##
## 用法（必须在仓库根、且项目路径指向 project-keynes）：
##   godot --headless --path Project/project-keynes \
##     --script res://tools/web_cloud_shadow_shrink.gd -- shrink 512
##   ... -- restore
##
## `restore` 用同目录的 `<name>.<原宽>.bak` 还原；`shrink` 只在 .bak 不存在时备份，
## 所以重复调用是幂等的，中途被杀也不会把原图弄丢。

const TARGET_DIR := "res://assets/textures/cloud_shadow"
const DEFAULT_TARGET := 512


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := "shrink" if args.is_empty() else String(args[0]).strip_edges().to_lower()
	var target := DEFAULT_TARGET
	if args.size() >= 2:
		var n := int(String(args[1]).strip_edges())
		if n >= 64 and n <= 4096:
			target = n

	var dir := DirAccess.open(TARGET_DIR)
	if dir == null:
		printerr("[cloud-shadow] 打不开目录 ", TARGET_DIR)
		quit(2)
		return

	var names: Array[String] = []
	for f in dir.get_files():
		if f.ends_with(".res"):
			names.append(f)
	names.sort()
	if names.is_empty():
		printerr("[cloud-shadow] 目录里没有 .res")
		quit(3)
		return

	var failed := 0
	for name in names:
		var path := TARGET_DIR + "/" + name
		if mode == "restore":
			failed += _restore(path)
		elif mode == "shrink":
			failed += _shrink(path, target)
		else:
			printerr("[cloud-shadow] 未知模式: ", mode)
			quit(4)
			return

	if failed > 0:
		printerr("[cloud-shadow] %d 个文件处理失败" % failed)
		quit(1)
		return
	print("[cloud-shadow] %s 完成（%d 个文件）" % [mode, names.size()])
	quit(0)


func _backup_path(path: String, width: int) -> String:
	return "%s.%d.bak" % [path, width]


## 已经有任何一份 .bak 就说明处于降级态，别覆盖原始备份。
func _find_backup(path: String) -> String:
	for i in range(0, 8192, 64):
		var cand := "%s.%d.bak" % [path, i]
		if FileAccess.file_exists(cand):
			return cand
	return ""


func _shrink(path: String, target: int) -> int:
	var img := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if img == null:
		printerr("[cloud-shadow] 不是 Image: ", path)
		return 1
	var w := img.get_width()
	if w <= target:
		print("[cloud-shadow] 跳过（已是 %d）: %s" % [w, path.get_file()])
		return 0
	if _find_backup(path).is_empty():
		var err := DirAccess.copy_absolute(ProjectSettings.globalize_path(path),
			ProjectSettings.globalize_path(_backup_path(path, w)))
		if err != OK:
			printerr("[cloud-shadow] 备份失败 ", path, " err=", err)
			return 1
	var had_mips := img.has_mipmaps()
	var before := FileAccess.get_file_as_bytes(path).size()
	img.resize(target, target, Image.INTERPOLATE_CUBIC)
	if had_mips:
		img.generate_mipmaps()
	var save_err := ResourceSaver.save(img, path)
	if save_err != OK:
		printerr("[cloud-shadow] 保存失败 ", path, " err=", save_err)
		return 1
	var after := FileAccess.get_file_as_bytes(path).size()
	print("[cloud-shadow] %s  %d -> %d (%.2f MB -> %.2f MB)" % [
		path.get_file(), w, target, before / 1048576.0, after / 1048576.0])
	return 0


func _restore(path: String) -> int:
	var bak := _find_backup(path)
	if bak.is_empty():
		return 0
	var err := DirAccess.copy_absolute(ProjectSettings.globalize_path(bak),
		ProjectSettings.globalize_path(path))
	if err != OK:
		printerr("[cloud-shadow] 还原失败 ", path, " err=", err)
		return 1
	DirAccess.remove_absolute(ProjectSettings.globalize_path(bak))
	print("[cloud-shadow] 已还原 ", path.get_file())
	return 0
