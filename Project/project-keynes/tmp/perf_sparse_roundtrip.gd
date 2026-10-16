extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	if OS.get_environment("PK_SAVE_DIR").is_empty():
		quit(1)
		return
	var begin: Dictionary = root.get_node("GameFlow").begin_load_game("manual_1")
	if not begin.get("ok", false):
		print("[sparse-roundtrip] load rejected ", begin)
		quit(1)
		return
	var host: WorldRuntimeHost
	for _frame in range(12000):
		await process_frame
		if current_scene is PlayerGame:
			host = current_scene.get_node_or_null("RuntimeHost")
			if host != null and host.is_runtime_ready_for_ticks(): break
	if host == null or not host.is_runtime_ready_for_ticks():
		quit(1)
		return
	var generator := host.generator()
	var clock: WorldClock = current_scene.get_node("WorldClock")
	var start: Dictionary = generator.get_runtime_thread_report()
	var target := int(start.get("simulation_committed_day", -1)) + 30
	clock.set_speed(50.0)
	clock.pause(false)
	var report := {}
	var timeout := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < timeout:
		await process_frame
		report = generator.get_runtime_perf_snapshot(0)
		if int(report.get("worker_fault_count", 0)) != 0:
			print("[sparse-roundtrip] worker fault ", report)
			quit(1)
			return
		if int(report.get("simulation_committed_day", -1)) >= target: break
	if OS.get_environment("PK_TEST_SAVE_WHILE_RUNNING") != "1":
		clock.pause(true)
	var saved: Dictionary = await root.get_node("GameSave").request_manual_save("manual_3")
	report = generator.get_runtime_thread_report()
	print("[sparse-roundtrip] save=", saved, " backing=", report.get("economy_formula_backing", ""),
		" pending=", report.get("economy_pending_command_count", -1))
	print("[sparse-roundtrip] saved_day=", saved.get("header", {}).get("day", -1),
		" current_day=", report.get("simulation_committed_day", -1))
	if not saved.get("ok", false) or int(report.get("simulation_committed_day", -1)) < target \
			or report.get("economy_formula_backing", "") != "owned_state" \
			or int(report.get("economy_pending_command_count", -1)) != 0:
		quit(1)
		return
	var source := OS.get_environment("PK_SAVE_DIR").path_join("manual_3.pksv")
	var output := "D:/Godot/ProjectKeynes/Project.Keynes/tmp/perf_sparse_20261015/sparse_roundtrip.pksv"
	var copied := DirAccess.copy_absolute(source, output)
	print("[sparse-roundtrip] copied=", copied)
	quit(0 if copied == OK else 1)
