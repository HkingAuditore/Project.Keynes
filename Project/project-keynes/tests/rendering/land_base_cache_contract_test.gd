extends SceneTree

const LandBaseCache := preload("res://scripts/rendering/land_base_cache.gd")


func _initialize() -> void:
	var missing := LandBaseCache._variant_failure_message("PK_BAKE_LAND_NORMAL", [])
	var usable := LandBaseCache._variant_failure_message("PK_READ_LAND_BASE", [{"name": "x"}])
	var ok := missing.contains("PK_BAKE_LAND_NORMAL") and usable.is_empty()
	print("land base cache variant diagnostics: ", ok)
	quit(0 if ok else 1)
