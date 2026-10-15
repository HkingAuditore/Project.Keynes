extends SceneTree

const Bake = preload("res://tools/loading_catalog_bake.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var err := Bake.bake()
	if err != OK:
		push_error("[loading-catalog] bake failed: %s" % error_string(err))
	quit(0 if err==OK else 1)
