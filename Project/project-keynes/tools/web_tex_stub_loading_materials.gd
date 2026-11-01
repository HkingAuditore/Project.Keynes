extends SceneTree

## [web-texture-downgrade] 构建期用的临时重烘焙：把 loading_prebaked_v1 的
## 地形材质图缩到 web 用的小尺寸，只为把 Web pck 里这些 `.res` 从 26.6 MB 压到
## ~1.6 MB。
##
## 为什么可以这么做：
##   `MapBaker._terrain_material_size()` 在 Web 上按画质档取 512 / 1024，而
##   `export_filter=all_resources` 会把两套都打进包。运行时真正需要的只是
##   **能凑成一张 Texture2DArray 的 RGBA8 图**，尺寸由材质图本身决定
##   （`_build_terrain_material_tex` 以第一层的实际宽度作层尺寸，micro 层按同一
##   尺寸 resize），所以把内容缩小、文件名不变是安全的：万一还有代码路径摸到
##   更大的档位，也只会偏糊，不会崩。
##
## 体积账（RGBA8 + mipmap 链 = 4/3 * w * h * 4）：
##   512² -> 1.33 MB/张  1024² -> 5.33 MB/张
##   256² -> 0.33 MB/张  ⇒ 4 张 512 从 5.33 MB 降到 1.33 MB
##
## 安全：
##   * 必须显式设环境变量 PK_WEB_DG_STUB=1 才会动手（防手滑）；
##   * 原文件由 tools/web_tex_downgrade.py 备份并在导出后还原，本脚本不负责备份；
##   * 只动 loading_prebaked_v1 下的 material_<size>_*.res，其它一概不碰。

const DIR := "res://assets/textures/loading_prebaked_v1/"
const COUNT := 4
## 要处理哪几套材质（Web 只处理 512 那套，1024 由 export_presets 排除）。
## 由 PK_WEB_DG_STUB_SIZES（逗号分隔）覆盖；这里只是默认值。
const DEFAULT_SIZES := [512, 1024]
const DEFAULT_STUB_SIZE := 256


func _initialize() -> void:
	call_deferred("_run")


func _sizes() -> Array:
	var raw := OS.get_environment("PK_WEB_DG_STUB_SIZES").strip_edges()
	if raw.is_empty():
		return DEFAULT_SIZES
	var out: Array = []
	for part in raw.split(",", false):
		var token := part.strip_edges()
		if token.is_valid_int():
			out.append(token.to_int())
	if out.is_empty():
		printerr("[web-stub] PK_WEB_DG_STUB_SIZES 解析不出尺寸: %s，用默认" % raw)
		return DEFAULT_SIZES
	return out


func _stub_size() -> int:
	var raw := OS.get_environment("PK_WEB_DG_STUB_SIZE").strip_edges()
	if raw.is_empty():
		return DEFAULT_STUB_SIZE
	if not raw.is_valid_int():
		printerr("[web-stub] PK_WEB_DG_STUB_SIZE 不是整数: %s" % raw)
		return DEFAULT_STUB_SIZE
	return clampi(raw.to_int(), 64, 1024)


func _run() -> void:
	if OS.get_environment("PK_WEB_DG_STUB") != "1":
		print("[web-stub] PK_WEB_DG_STUB!=1，什么都不做")
		quit(0)
		return
	var stub_size := _stub_size()
	var changed := 0
	for size in _sizes():
		for i in COUNT:
			var path := "%smaterial_%d_%d.res" % [DIR, size, i]
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
			# 源图是正方形；按最长边约束更稳（万一哪天换成非正方形）。
			var longest: int = max(before.x, before.y)
			if longest <= stub_size:
				print("[web-stub] already small, skip: ", path, " ", before)
				continue
			var factor := float(stub_size) / float(longest)
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
	print("[web-stub] done, %d file(s) stubbed to %dpx" % [changed, stub_size])
	quit(0)
