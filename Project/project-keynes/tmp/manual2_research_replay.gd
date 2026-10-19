extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	root.get_node("GameSave").set("_autosave_enabled", false)
	var slot := OS.get_environment("PK_TECH_REPLAY_SLOT") if OS.has_environment("PK_TECH_REPLAY_SLOT") else "autosave"
	var result: Dictionary = root.get_node("GameFlow").begin_load_game(slot)
	print("[delivery] begin=", result)
	var host: WorldRuntimeHost
	var deadline := Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
		if current_scene is PlayerGame:
			host = current_scene.get_node("RuntimeHost")
			if host.is_runtime_ready_for_ticks():
				break
	if host == null or not host.is_runtime_ready_for_ticks():
		quit(1)
		return
	var clock: WorldClock = current_scene.get_node("WorldClock")
	var ext = host.generator().get_data_core_world_ext()
	var handle := int(ext.get_country_cell_summary(4886).get("country_handle", 0))
	var start := clock.day_index()
	var days := int(OS.get_environment("PK_TECH_REPLAY_DAYS")) if OS.has_environment("PK_TECH_REPLAY_DAYS") else 120
	var report := {"before": _snapshot(ext, handle), "start": start}
	var worker_start := int(report.before.thread.get("simulation_committed_day", start - 1))
	report["worker_start"] = worker_start
	var research_index := -1
	if OS.get_environment("PK_TECH_REPLAY_ENQUEUE") == "1":
		var facade = host.generator().get_country_facade()
		var catalog: Dictionary = facade.get("_catalog")
		var states: PackedInt32Array = report.before.research.technology_states
		for i in states.size():
			if states[i] == 2:
				research_index = i
				break
		if research_index >= 0:
			var technology := StringName(catalog.technology_ids[research_index])
			report["research_check"] = {"id": technology, "before_state": states[research_index],
				"submitted": facade.enqueue_research(handle, technology,
					int(catalog.technology_domain_indices[research_index]), 0,
					clock.day_index() + 1, 1000000000)}
	clock.set_speed(20.0)
	clock.pause(false)
	deadline = Time.get_ticks_msec() + 120000
	while (int(ext.get_runtime_thread_report().get("simulation_committed_day", -1)) < worker_start + days \
			or host.get("_trigger_country_delivery_id") > 0 \
			or host.get("_trigger_country_delivery_waiting")) and Time.get_ticks_msec() < deadline:
		await create_timer(0.05).timeout
	clock.pause(true)
	await create_timer(0.5).timeout
	report["after"] = _snapshot(ext, handle)
	var final_economy: Dictionary = host.generator().get_economy_report()
	deadline = Time.get_ticks_msec() + 5000
	while bool(final_economy.get("report_boundary_pending", false)) and Time.get_ticks_msec() < deadline:
		await create_timer(0.02).timeout
		final_economy = host.generator().get_economy_report()
	report.after["economy"] = final_economy
	report["committed_audit"] = ext.get_economy_committed_audit_report()
	report["worker_end"] = int(ext.get_runtime_thread_report().get("simulation_committed_day", -1))
	report["ok"] = report.worker_end >= worker_start + days \
		and not bool(final_economy.get("fatal", true)) \
		and int(report.after.thread.get("worker_fault_count", 1)) == 0 \
		and bool(report.committed_audit.get("available", false))
	if research_index >= 0:
		report.research_check["after_state"] = report.after.research.technology_states[research_index]
		report.research_check["progress"] = report.after.research.technology_progress[research_index]
	report["end"] = clock.day_index()
	report["delivery_id"] = host.get("_trigger_country_delivery_id")
	report["adapter"] = ext.get_effect_native_adapter_report()
	report["head"] = ext.poll_trigger_effects(0, 8)
	if OS.get_environment("PK_TECH_REPLAY_SAVE") == "1":
		report["save"] = await root.get_node("GameSave").request_manual_save("manual_1")
	FileAccess.open("res://tmp/manual2_research_replay.json", FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	print("[delivery] before=", report.before.totals, " after=", report.after.totals,
		" signals=", report.after.signals.signal_ids.size(), " cursor=", report.delivery_id,
		" pending=", report.after.trigger.pending_effects)
	print("[delivery] worker_days=", report.worker_start, " -> ", report.worker_end, " ok=", report.ok,
		" committed_audit=", report.committed_audit)
	quit(0 if report.ok else 1)

func _snapshot(ext: Object, handle: int) -> Dictionary:
	var research: Dictionary = ext.get_country_research_snapshot(handle)
	var totals := [0, 0, 0, 0, 0, 0]
	for state in research.get("technology_states", PackedInt32Array()):
		totals[state] += 1
	return {"totals": totals, "research": research,
		"signals": ext.get_country_research_signal_snapshot(handle),
		"trigger": ext.get_trigger_report(), "effect": ext.get_effect_report(),
		"thread": ext.get_runtime_thread_report(), "economy": ext.get_economy_report()}

