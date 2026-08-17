extends SceneTree
func _init() -> void:
	var packed := load("res://scenes/ui/ideology_workspace.tscn") as PackedScene
	var scene := packed.instantiate()
	root.add_child(scene)
	print("ideology class=", scene.get_class(), " script=", scene.get_script())
	print("has set_compact=", scene.has_method("set_compact"))
	print("has set_model=", scene.has_method("set_model"))
	quit(0 if scene.has_method("set_model") else 1)
