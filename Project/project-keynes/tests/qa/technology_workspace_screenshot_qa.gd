extends SceneTree

## 科技工作区截图 QA：真实开局排入研究、跑若干天积累产出曲线与预计天数后，
## 在 1280×720 / 1366×768 / 1920×1080 下截取可研究清单、科技树、总览三种视图。
## 需要带渲染运行（不加 --headless）。

const OUTPUT_DIR := "res://tmp/technology_workspace_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080)]
const WARMUP_DAYS := 24
const MODES := ["available", "focus", "overview"]

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	root.size = SIZES[0]
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	await process_frame
	var ui := game.get_node("UI") as GameUIManager
	var clock := game.get_node("WorldClock") as WorldClock
	var panel := game.get_node("UI/UIRoot/PanelLayer/CountryPanel") as CountryPanel
	ui.open_country_section("technology")
	for _i in range(6):
		await process_frame
	var workspace := panel.get("_technology_workspace") as Control
	var controller = ui.get("_player_controller")
	var facade = controller.get_country_facade()
	var handle := int(controller.get_player_country_handle())
	var research: Dictionary = facade.research_snapshot(handle)
	var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
	var queued := 0
	for index in range(states.size()):
		if states[index] == 2 and queued < 3:
			workspace.call("_enqueue", index)
			queued += 1
			for _i in range(10):
				await process_frame
	var start_day := clock.day_index()
	clock.pause(false)
	clock.set_speed(50.0)
	var deadline := Time.get_ticks_msec() + 60000
	while clock.day_index() < start_day + WARMUP_DAYS and Time.get_ticks_msec() < deadline:
		await process_frame
	# Cheap opening technologies finish during warmup; queue fresh work so the
	# captures show live research with ETAs.
	clock.set_speed(5.0)
	research = facade.research_snapshot(handle)
	states = research.get("technology_states", PackedInt32Array())
	queued = 0
	for index in range(states.size()):
		if states[index] == 2 and queued < 5:
			workspace.call("_enqueue", index)
			queued += 1
			for _i in range(6):
				await process_frame
	var settle_day := clock.day_index() + 4
	while clock.day_index() < settle_day and Time.get_ticks_msec() < deadline + 20000:
		await process_frame
	clock.pause(true)
	for viewport_size in SIZES:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(viewport_size)
		root.size = viewport_size
		ui.open_country_section("technology")
		await process_frame
		await process_frame
		for mode in MODES:
			var nav := workspace.get("_mode_nav") as DossierChapterNav
			nav.chapter_selected.emit(mode)
			await _capture("technology_%s" % mode, viewport_size)
			var indicator: Rect2 = nav.call("_indicator_rect")
			var selected: Rect2 = (nav.get("_rects") as Array)[MODES.find(mode)]
			if not indicator.is_equal_approx(selected):
				_failures.append("%s %s: nav indicator %s does not sit on its tab %s" % [
					mode, str(viewport_size), str(indicator), str(selected)])
			if nav.icon_only:
				_failures.append("%s %s: nav fell back to icons only" % [mode, str(viewport_size)])
			print("[technology-screenshot] nav=%s main=%s queue=%s" % [str(nav.size),
				str((workspace.get("_main") as Control).size),
				str((workspace.get("_research") as Dictionary).get("queue_technology_indices"))])
	_finish()


func _capture(label: String, viewport_size: Vector2i) -> void:
	await create_timer(UITokens.ANIM_MED + 0.2).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s_%dx%d.png" % [OUTPUT_DIR, label, viewport_size.x, viewport_size.y]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		_failures.append("failed to capture %s" % path)
		return
	print("[technology-screenshot] %s" % ProjectSettings.globalize_path(path))


func _finish() -> void:
	for failure in _failures:
		push_error(failure)
	print("=== technology workspace screenshot QA: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
