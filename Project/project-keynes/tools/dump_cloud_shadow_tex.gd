extends SceneTree

## 临时诊断：把云影预烘纹理导出成 PNG，供 CPU 侧做接缝 / 直方图分析。
##
##   godot --headless --path Project/project-keynes \
##     --script res://tools/dump_cloud_shadow_tex.gd

const SRC := [
	"res://assets/textures/cloud_shadow/cloud_noise_rgba.res",
	"res://assets/textures/cloud_shadow/cloud_shadow_base_rgba.res",
]
const OUT_DIR := "res://tmp/cloud_tex_dump"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for path in SRC:
		var image := load(path) as Image
		if image == null:
			printerr("[dump] load failed: ", path)
			continue
		var name := String(path).get_file().get_basename()
		var w := image.get_width()
		var h := image.get_height()
		print("[dump] %s %dx%d fmt=%d mips=%d data=%d" % [
			name, w, h, image.get_format(), image.get_mipmap_count(),
			image.get_data().size()])
		# get_data() 含 mip 链：只取第 0 层重建一张干净图再存 PNG。
		var flat := Image.create_empty(w, h, false, image.get_format())
		flat.blit_rect(image, Rect2i(0, 0, w, h), Vector2i.ZERO)
		var err := flat.save_png("%s/%s.png" % [OUT_DIR, name])
		print("[dump] -> %s/%s.png err=%d" % [OUT_DIR, name, err])
	quit(0)
