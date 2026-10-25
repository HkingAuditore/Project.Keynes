extends SceneTree

## 生成图原样保留；这里只做 UI 导入所需的矩形切片和分辨率缩放。
func _init() -> void:
	var source := Image.load_from_file("res://assets/ui/paper_hud/skin_source.png")
	var pieces := {
		"panel_horizontal": [Rect2i(54, 211, 650, 272), Vector2i(256, 96)],
		"panel_vertical": [Rect2i(767, 43, 243, 493), Vector2i(96, 256)],
		"button_normal": [Rect2i(1118, 190, 349, 330), Vector2i(64, 64)],
		"button_hover": [Rect2i(95, 603, 359, 346), Vector2i(64, 64)],
		"button_pressed": [Rect2i(589, 605, 359, 345), Vector2i(64, 64)],
		"button_disabled": [Rect2i(1091, 602, 367, 346), Vector2i(64, 64)],
	}
	for key in pieces:
		var image := source.get_region(pieces[key][0])
		var target: Vector2i = pieces[key][1]
		image.resize(target.x, target.y, Image.INTERPOLATE_LANCZOS)
		var error := image.save_png("res://assets/ui/paper_hud/%s.png" % key)
		if error != OK:
			push_error("Cannot bake paper HUD skin: %s" % key)
			quit(1)
			return
	print("[paper-hud-skin] six UI textures sliced and resized")
	quit()
