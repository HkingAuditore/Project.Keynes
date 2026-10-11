extends SceneTree

## 国民经济卷宗截图 QA：真实开局跑若干天积累趋势后，在 1280×720 / 1366×768 /
## 1920×1080 下逐章截图，并截取科技、理念页验证外壳换皮。需要带渲染运行（不加 --headless）。

const OUTPUT_DIR := "res://tmp/economy_dossier_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1366, 768), Vector2i(1920, 1080)]
const WARMUP_DAYS := 12

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
	ui.open_country_section("economy")
	var start_day := clock.day_index()
	clock.pause(false)
	clock.set_speed(50.0)
	var deadline := Time.get_ticks_msec() + 60000
	while clock.day_index() < start_day + WARMUP_DAYS and Time.get_ticks_msec() < deadline:
		await process_frame
	clock.pause(true)
	var dossier := panel.get("_economy_dossier") as EconomyDossier
	if dossier == null:
		_failures.append("economy dossier missing")
		_finish()
		return
	for viewport_size in SIZES:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(viewport_size)
		root.size = viewport_size
		ui.open_country_section("economy")
		await process_frame
		await process_frame
		for chapter in EconomyDossierViewModel.CHAPTERS:
			dossier.select_chapter(String(chapter.id))
			dossier.set_scroll_for_test(0)
			await _capture("economy_%s" % chapter.id, viewport_size)
		dossier.select_chapter("overview")
		for section_id in ["technology", "ideology"]:
			ui.open_country_section(section_id)
			await _capture(section_id, viewport_size)
	_finish()


func _capture(label: String, viewport_size: Vector2i) -> void:
	await create_timer(UITokens.ANIM_MED + 0.15).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s_%dx%d.png" % [OUTPUT_DIR, label, viewport_size.x, viewport_size.y]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		_failures.append("failed to capture %s" % path)
		return
	print("[economy-dossier-screenshot] %s" % ProjectSettings.globalize_path(path))


func _finish() -> void:
	for failure in _failures:
		push_error(failure)
	print("=== economy dossier screenshot QA: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
