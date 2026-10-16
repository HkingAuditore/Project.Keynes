extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var begin: Dictionary = root.get_node("GameFlow").begin_load_game("autosave")
	print("[colon-probe] load=", begin)
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
	root.get_node("GameSave").set("_autosave_enabled", false)
	var gen = host.generator()
	var ext = gen.get_data_core_world_ext()
	var country: int = host.get("_player_country_handle")
	print("[colon-probe] country=", country, " day=", clock.day_index())
	var facade = gen.get_economy_facade()
	var market: Dictionary = facade.market_cell_snapshot(1756)
	var goods: PackedStringArray = market.get("good_ids", PackedStringArray())
	var stocks: PackedInt64Array = market.get("stock", market.get("stocks", PackedInt64Array()))
	var tool := goods.find("chipped_stone_tools")
	print("[colon-probe] source tools=", stocks[tool] if tool >= 0 and tool < stocks.size() else -1)
	for step in 5:
		print("[colon-probe] page=", ext.get_family_expeditions(country, 0, 64))
		var page: Dictionary = ext.get_family_expeditions(country, 0, 64)
		for handle in page.get("handles", page.get("expedition_handles", PackedInt64Array())):
			print("[colon-probe] detail=", ext.get_family_expedition_snapshot(country, handle))
		if step == 4:
			break
		var start: int = clock.day_index()
		clock.set_speed(100.0)
		var timeout: int = Time.get_ticks_msec() + 60000
		while clock.day_index() < start + 20 and Time.get_ticks_msec() < timeout:
			await process_frame
		print("[colon-probe] day=", clock.day_index(), " report=", gen.get_economy_perf_report())
	clock.set_speed(0.0)
	var destination := {}
	var final_page := {}
	for i in 2400:
		await process_frame
		destination = ext.get_family_cell_snapshot(1857, 0, 64)
		final_page = ext.get_family_expeditions(country, 0, 64)
		if bool(destination.get("ok", false)) and bool(final_page.get("ok", false)):
			break
	var families: PackedInt64Array = destination.get("family_handles", PackedInt64Array())
	var report: Dictionary = ext.get_economy_report()
	var thread_report: Dictionary = gen.get_runtime_thread_report()
	var ok := families.has(4294967306) and int(final_page.get("total", -1)) == 0 \
		and not bool(report.get("fatal", false)) and int(thread_report.get("worker_fault_count", 0)) == 0
	print("[colon-probe] result=", {"ok": ok, "destination": destination,
		"population_error": report.get("population_error"), "money_error": report.get("money_error"),
		"goods_error": report.get("goods_error"), "worker_faults": thread_report.get("worker_fault_count", 0)})
	quit(0 if ok else 1)
