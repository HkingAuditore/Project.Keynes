extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var flow := root.get_node("GameFlow")
	var begin: Dictionary = flow.begin_load_game("manual_1")
	if not begin.get("ok", false):
		print("[save-roundtrip] load rejected ", begin)
		quit(1)
		return
	var host: WorldRuntimeHost
	for _i in 4800:
		await process_frame
		if current_scene is PlayerGame:
			host = current_scene.get_node_or_null("RuntimeHost")
			if host != null and host.is_runtime_ready_for_ticks():
				break
	if host == null or not host.is_runtime_ready_for_ticks():
		print("[save-roundtrip] runtime not ready")
		quit(1)
		return
	var clock: WorldClock = current_scene.get_node("WorldClock")
	clock.pause(true)
	var saved: Dictionary = await root.get_node("GameSave").request_manual_save("manual_3")
	print("[save-roundtrip] saved ", saved)
	if not saved.get("ok", false):
		quit(1)
		return
	var source := OS.get_environment("PK_SAVE_DIR").path_join("manual_3.pksv")
	var output := "D:/Godot/ProjectKeynes/Project.Keynes/tmp/save_restore_roundtrip.pksv"
	var copied := DirAccess.copy_absolute(source, output)
	print("[save-roundtrip] copied=", copied, " output=", output)
	quit(0 if copied == OK else 1)
