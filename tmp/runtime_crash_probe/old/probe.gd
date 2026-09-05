extends SceneTree

func _init() -> void:
	print("probe class_exists=", ClassDB.class_exists("DCWorldExt"))
	if ClassDB.class_exists("DCWorldExt"):
		var ext = ClassDB.instantiate("DCWorldExt")
		print("probe instance=", ext)
	quit(0)
