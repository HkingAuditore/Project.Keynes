extends SceneTree

# Probe: real player session → click the era badge (EraAdvancementPanel with the
# live PlayerController snapshot) → emit PlayerController.era_advanced to play the
# EraAscensionCeremony over the live map, with the technology dossier open behind it.
# Captures PNGs to <repo>/tmp/era_advancement_qa/.
#
#   godot --path . --script res://tests/probes/_probe_era_ceremony.gd


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1600, 960)
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	for _i in range(6):
		await process_frame
	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	var controller = ui.get("_player_controller")
	var badge: EraIndicator = ui.get("_era_indicator")
	var ok := true
	# 1) 纸徽点击 → 合并速览（国家概况 + 时代晋升，真实快照）。
	badge.get_node("Hit").emit_signal("pressed")
	await create_timer(0.6).timeout
	var panel_open := bool(ui.call("is_era_panel_open"))
	var snapshot: Dictionary = controller.get_era_advancement_snapshot() \
		if controller.has_method("get_era_advancement_snapshot") else {}
	print("[probe] panel_open=%s status=%s conditions=%d costs=%d" % [str(panel_open),
		String(snapshot.get("status", "?")), (snapshot.get("conditions", []) as Array).size(),
		(snapshot.get("costs", []) as Array).size()])
	ok = ok and panel_open
	await _capture("merged_live")
	ui.call("_close_era_panel")
	await create_timer(0.3).timeout
	# 2) 科技卷宗打开 + 时钟运行时晋升：大典压过卷宗，并暂停时钟。
	ui.open_country_section("technology")
	clock.pause(false)
	for _i in range(10):
		await process_frame
	if not controller.has_signal("era_advanced"):
		print("[probe] controller has no era_advanced signal")
		quit(1)
		return
	controller.era_advanced.emit(0, 1, PackedStringArray(
		["粮食产出 +10%", "定居点人口上限 +15%", "解锁时代奖励三选一"]))
	await process_frame
	var playing := bool(ui.call("is_era_ceremony_playing"))
	print("[probe] ceremony playing=%s clock_paused=%s" % [str(playing), str(clock.paused)])
	ok = ok and playing and clock.paused
	await create_timer(1.6).timeout
	await _capture("live_ceremony_burn")
	await create_timer(0.8).timeout
	await _capture("live_ceremony_burst")
	await create_timer(2.6).timeout
	await _capture("live_ceremony_title")
	await create_timer(1.8).timeout
	await _capture("live_ceremony_flight")
	var deadline := Time.get_ticks_msec() + 6000
	while bool(ui.call("is_era_ceremony_playing")) and Time.get_ticks_msec() < deadline:
		await process_frame
	await create_timer(0.4).timeout
	await _capture("live_ceremony_landed")
	var finished := not bool(ui.call("is_era_ceremony_playing"))
	print("[probe] finished=%s clock_paused_after=%s" % [str(finished), str(clock.paused)])
	ok = ok and finished and not clock.paused
	# 3) 同一时代再次通知不重播。
	controller.era_advanced.emit(0, 1, PackedStringArray())
	await process_frame
	var replay := bool(ui.call("is_era_ceremony_playing"))
	print("[probe] duplicate notification replays=%s" % str(replay))
	ok = ok and not replay
	print("_probe_era_ceremony: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://").path_join("../../tmp/era_advancement_qa").simplify_path()
	DirAccess.make_dir_recursive_absolute(out)
	root.get_texture().get_image().save_png(out.path_join("%s.png" % label))
	print("[capture] %s" % label)
