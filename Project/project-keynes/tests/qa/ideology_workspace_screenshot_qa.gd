extends SceneTree

## 理念工作区截图 QA：真实开局，用 GM 补点后走一次正式抽卡流程（暂停+单步），
## 在 1280×720 / 1920×1080 下截取空馆、三选一与选定后的排卡台。需要带渲染运行（不加 --headless）。

const OUTPUT_DIR := "res://tmp/ideology_workspace_qa"
const SIZES := [Vector2i(1280, 720), Vector2i(1920, 1080)]
const Q16 := 65536

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
	var controller = game.get_node("PlayerController")
	var facade = runtime.generator().get_ideology_facade()
	clock.pause(true)
	var handle := int(controller.get_player_country_handle())
	for viewport_size in SIZES:
		_resize(viewport_size)
		ui.open_country_section("ideology")
		await _capture("empty", viewport_size)
	if facade == null or handle == 0:
		_failures.append("ideology facade or player country missing")
		_finish()
		return
	# Let the worker take Ideology authority first; grants before the handoff
	# land on the synchronous runtime that the worker does not inherit.
	await _advance_days(clock, 3)
	# QA-only producer so the grant never collides with PlayerController's
	# producer-1 sequence high-water mark.
	var catalog: Dictionary = facade.catalog_view()
	var first_draw_cost := int(catalog.get("offer_cost_q16", 120 * Q16))
	var grant_rows: Array[Dictionary] = [{"opcode": 2, "producer_id": 77,
		"country_handle": handle, "value_q16": first_draw_cost * 2,
		"effective_day": clock.day_index() + 1, "sequence": 1}]
	var granted: Dictionary = facade.submit(grant_rows)
	if not bool(granted.get("ok", false)):
		_failures.append("grant rejected: %s" % str(granted))
	# Worker snapshots write back asynchronously; wait until the grant is visible.
	clock.set_speed(1.0)
	clock.pause(false)
	var grant_deadline := Time.get_ticks_msec() + 30000
	while int(facade.snapshot(handle).get("ideology_points_q16", 0)) < 2 * Q16 \
			and Time.get_ticks_msec() < grant_deadline:
		await process_frame
	clock.pause(true)
	var thread_report: Dictionary = facade.world_ext().get_runtime_thread_report()
	print("[ideology-screenshot] day=%d points_q16=%d worker_generation=%d fallback=%s" % [
		clock.day_index(), int(facade.snapshot(handle).get("ideology_points_q16", 0)),
		int(thread_report.get("ideology_pod_snapshot_generation", 0)),
		String(thread_report.get("ideology_pod_fallback_reason", ""))])
	var drawn: Dictionary = controller.request_command(&"ideology.offer", {})
	if not bool(drawn.get("ok", false)):
		_failures.append("draw rejected: %s" % str(drawn))
		_finish()
		return
	var deadline := Time.get_ticks_msec() + 30000
	while String(controller.ideology_draw_phase()) != "presenting" \
			and Time.get_ticks_msec() < deadline:
		await process_frame
	if String(controller.ideology_draw_phase()) != "presenting":
		_failures.append("offer never presented (phase=%s)" % controller.ideology_draw_phase())
	for viewport_size in SIZES:
		_resize(viewport_size)
		ui.open_country_section("ideology")
		await create_timer(1.6).timeout
		await _capture("offer", viewport_size)
	var snap: Dictionary = facade.snapshot(handle)
	var chosen: Dictionary = controller.request_command(&"ideology.choose", {
		"offer_generation": int(snap.get("offer_generation", 0)), "choice_index": 0})
	if not bool(chosen.get("ok", false)):
		_failures.append("choose rejected: %s" % str(chosen))
	deadline = Time.get_ticks_msec() + 30000
	while controller.ideology_draw_locked() and Time.get_ticks_msec() < deadline:
		await process_frame
	for viewport_size in SIZES:
		_resize(viewport_size)
		ui.open_country_section("ideology")
		await create_timer(1.2).timeout
		await _capture("collection", viewport_size)
	_finish()


func _resize(viewport_size: Vector2i) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(viewport_size)
	root.size = viewport_size


func _advance_days(clock: WorldClock, days: int) -> void:
	var target := clock.day_index() + days
	clock.set_speed(1.0)
	clock.pause(false)
	var deadline := Time.get_ticks_msec() + 30000
	while clock.day_index() < target and Time.get_ticks_msec() < deadline:
		await process_frame
	clock.pause(true)


func _capture(label: String, viewport_size: Vector2i) -> void:
	await create_timer(UITokens.ANIM_MED + 0.15).timeout
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var path := "%s/%s_%dx%d.png" % [OUTPUT_DIR, label, viewport_size.x, viewport_size.y]
	if image == null or image.is_empty() or image.save_png(path) != OK:
		_failures.append("failed to capture %s" % path)
		return
	print("[ideology-screenshot] %s" % ProjectSettings.globalize_path(path))


func _finish() -> void:
	for failure in _failures:
		push_error(failure)
	print("=== ideology workspace screenshot QA: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
