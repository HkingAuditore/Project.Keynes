extends SceneTree

## [web-texture-downgrade] 构建期用的临时重烘焙：把 loading_prebaked_v1 的
## 1024² 材质图缩成 256²，只为把 Web pck 里这 4 个 `.res` 从 21.3 MB 压到 ~1.3 MB。
##
## 为什么可以这么做：
##   `MapBaker.prepare_shared_materials_async()` / 第 1215 行都按
##   `TERRAIN_MATERIAL_SIZE_MOBILE(512) if OS.has_feature("mobile") or OS.has_feature("web")
##   else TERRAIN_MATERIAL_SIZE_DESKTOP(1024)` 取尺寸 —— Web 运行时**只读 512 那套**，
##   1024 那套进包纯粹是 `export_filter=all_resources` 把 assets 全打进去的结果。
##   这里不删文件（避免导出器报 missing），只把它换成 256²：万一哪天 web 真有代码路径
##   摸到 1024 路径，也不会崩，只是偏糊。
##
## 安全：
##   * 必须显式设环境变量 PK_WEB_DG_STUB=1 才会动手（防手滑）；
##   * 原文件由 tools/web_tex_downgrade.py 备份并在导出后还原，本脚本不负责备份；
##   * 只动这 4 个文件，其它一概不碰。

const DIR := "res://assets/textures/loading_prebaked_v1/"
const COUNT := 4
const STUB_SIZE := 256


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_environment("PK_WEB_DG_STUB") != "1":
		print("[web-stub] PK_WEB_DG_STUB!=1，什么都不做")
		quit(0)
		return
	var changed := 0
	for i in COUNT:
		var path := "%smaterial_1024_%d.res" % [DIR, i]
		if not FileAccess.file_exists(path):
			printerr("[web-stub] missing: ", path)
			quit(1)
			return
		var image := load(path) as Image
		if image == null or image.is_empty():
			printerr("[web-stub] not an Image: ", path)
			quit(1)
			return
		var before := image.get_size()
		# 保比例缩到 STUB_SIZE（源图是正方形，但代码按最长边约束更稳）
		var longest: int = max(before.x, before.y)
		if longest <= STUB_SIZE:
			print("[web-stub] already small, skip: ", path, " ", before)
			continue
		var factor := float(STUB_SIZE) / float(longest)
		var target := Vector2i(maxi(1, int(round(before.x * factor))),
				maxi(1, int(round(before.y * factor))))
		image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
		image.generate_mipmaps()
		var err := ResourceSaver.save(image, path)
		if err != OK:
			printerr("[web-stub] save failed (%d): %s" % [err, path])
			quit(1)
			return
		changed += 1
		print("[web-stub] %s : %s -> %s" % [path.get_file(), before, target])
	print("[web-stub] done, %d file(s) stubbed to %dpx" % [changed, STUB_SIZE])
	quit(0)
