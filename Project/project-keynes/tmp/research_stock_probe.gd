extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.get_node("GameSave").set("_autosave_enabled", false)
	print("[research-probe] load=", root.get_node("GameFlow").begin_load_game("autosave"))
	var host: WorldRuntimeHost
	for i in 10000:
		await process_frame
		if current_scene is PlayerGame:
			host = current_scene.get_node_or_null("RuntimeHost")
			if host != null and host.is_runtime_ready_for_ticks():
				break
	if host == null or not host.is_runtime_ready_for_ticks():
		quit(1)
		return
	var clock: WorldClock = current_scene.get_node("WorldClock")
	clock.set_speed(0.0)
	var gen = host.generator()
	var facade = gen.get_country_facade()
	var handle: int = host.get("_player_country_handle")
	var catalog: Dictionary = load("res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	var initial: Dictionary = facade.research_snapshot(handle)
	var counts := [0, 0, 0, 0]
	var sequence := 880000
	print("[research-probe] weights=", facade.set_research_weights(handle, PackedInt32Array([2500, 2500, 2500, 2500]), clock.day_index() + 1, sequence))
	for tech in initial.technology_states.size():
		if int(initial.technology_states[tech]) != 2:
			continue
		var domain: int = catalog.technology_domain_indices[tech]
		if counts[domain] >= 8:
			continue
		counts[domain] += 1
		sequence += 1
		print("[research-probe] enqueue=", catalog.technology_ids[tech], " ", facade.enqueue_research(handle, catalog.technology_ids[tech], domain, -1, clock.day_index() + 1, sequence))
	for step in 4:
		var s: Dictionary = facade.research_snapshot(handle)
		var compact := s.duplicate()
		for key in ["technology_states", "technology_progress", "technology_ids", "technology_names", "technology_progress_points"]:
			compact.erase(key)
		print("[research-probe] snapshot=", compact)
		print("[research-probe] country=", facade.report())
		print("[research-probe] thread=", gen.get_runtime_thread_report())
		if step == 3:
			break
		var start: int = clock.day_index()
		clock.set_speed(30.0)
		var timeout: int = Time.get_ticks_msec() + 20000
		while clock.day_index() < start + 5 and Time.get_ticks_msec() < timeout:
			await process_frame
		clock.set_speed(0.0)
		for i in 30:
			await process_frame
	quit(0)

