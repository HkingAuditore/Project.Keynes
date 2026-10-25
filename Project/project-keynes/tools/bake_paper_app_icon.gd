extends SceneTree

func _init() -> void:
	var texture := IconCatalog.texture_for_key(&"family.workspace.crest")
	var icon := texture.get_image()
	icon.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	var error := icon.save_png("res://assets/ui/paper_hud/app_icon.png")
	print("[paper-app-icon] %s" % error)
	quit(0 if error == OK else 1)
