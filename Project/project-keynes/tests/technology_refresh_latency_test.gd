extends SceneTree

# Regression: the open technology workspace must track the committed research
# replica without the player clicking anything. Covers live play at several
# speeds, settling after a pause, and reopening after days passed while closed.

const MAX_RUNNING_LAG_MSEC := 600
const SETTLE_DEADLINE_MSEC := 600
const MIN_OBSERVED_CHANGES := 4
const MAX_MEASURE_MSEC := 12000

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1280, 720)
	var game := (load("res://scenes/player_game.tscn") as PackedScene).instantiate()
	var runtime: WorldRuntimeHost = game.get_node("RuntimeHost")
	root.add_child(game)
	await runtime.world_ready
	for _i in range(4):
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
	clock.pause(false)
	clock.set_speed(5.0)
	var enqueued := {}
	var deadline := Time.get_ticks_msec() + 15000
	while Time.get_ticks_msec() < deadline and enqueued.size() < 3:
		var research: Dictionary = facade.research_snapshot(handle)
		var states: PackedInt32Array = research.get("technology_states", PackedInt32Array())
		for index in range(states.size()):
			if states[index] == 2 and not enqueued.has(index):
				workspace.call("_enqueue", index)
				enqueued[index] = true
				break
		for _i in range(20):
			await process_frame
	_expect("research queue was seeded", not enqueued.is_empty())
	var optimistic_deadline := Time.get_ticks_msec() + 5000
	while not (workspace.get("_optimistic_queue") as Dictionary).is_empty() \
			and Time.get_ticks_msec() < optimistic_deadline:
		await process_frame

	var total_live_changes := 0
	# Opening days may procure nothing, so run fast first to reach live research.
	for speed in [20.0, 5.0, 1.0]:
		clock.set_speed(speed)
		var result := await _measure(workspace, facade, handle, 3500)
		total_live_changes += int(result.live_changes)
		_expect("open %sx: no stale stretch longer than %dms (max %d)" % [
			str(speed), MAX_RUNNING_LAG_MSEC, int(result.max_lag)],
			int(result.max_lag) < MAX_RUNNING_LAG_MSEC)
		# Above 5x several days land inside one coalescing window by design.
		if speed <= 5.0:
			_expect("open %sx: workspace follows every committed change (live %d, shown %d)" % [
				str(speed), int(result.live_changes), int(result.shown_changes)],
				int(result.shown_changes) >= int(result.live_changes) - 1)
		clock.pause(true)
		_expect("open %sx: settles to the committed replica after pausing" % str(speed),
			await _settles(workspace, facade, handle))
		_expect("open %sx: refresh throttle is never left armed without a timer" % str(speed),
			not bool(ui.get("_country_refresh_queued")) \
				or bool(ui.get("_country_refresh_timer_active")))
		clock.pause(false)
	_expect("research replica advanced during the measurement", total_live_changes >= 2)

	ui.close_country_panel()
	clock.set_speed(5.0)
	var shown_before: Dictionary = (workspace.get("_research") as Dictionary).duplicate()
	var reopen_day := clock.day_index() + 6
	var reopen_deadline := Time.get_ticks_msec() + 15000
	while clock.day_index() < reopen_day and Time.get_ticks_msec() < reopen_deadline:
		await process_frame
	clock.pause(true)
	for _i in range(10):
		await process_frame
	var live_before_reopen: Dictionary = facade.research_snapshot(handle)
	_expect("research replica moved while the panel was closed",
		_signature(live_before_reopen) != _signature(shown_before))
	var reopened_at := Time.get_ticks_msec()
	ui.open_country_section("technology")
	_expect("reopening while paused presents the committed replica",
		await _settles(workspace, facade, handle))
	print("[latency] reopen paused settled in %dms" % (Time.get_ticks_msec() - reopened_at))

	for failure in _failures:
		push_error(failure)
	print("technology refresh latency: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)


func _signature(research: Dictionary) -> String:
	return "%d|%d|%d|%s|%s" % [
		int(research.get("progress_total", 0)),
		int(research.get("consumed_total", 0)),
		int(research.get("technology_points_stock", 0)),
		str(research.get("queue_technology_indices", PackedInt32Array())),
		str(hash(research.get("technology_states", PackedInt32Array()))),
	]


func _settles(workspace: Control, facade, handle: int) -> bool:
	var deadline := Time.get_ticks_msec() + SETTLE_DEADLINE_MSEC
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if _signature(facade.research_snapshot(handle)) \
				== _signature(workspace.get("_research")):
			return true
	return false


func _measure(workspace: Control, facade, handle: int, duration_ms: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	var live_changes := 0
	var shown_changes := 0
	var last_live := ""
	var last_shown := ""
	var stale_since := -1
	var max_lag := 0
	# Slow speeds may not commit a research day inside the base window; keep
	# sampling until a few real changes were observed so the check has teeth.
	while Time.get_ticks_msec() - started < duration_ms \
			or (live_changes < MIN_OBSERVED_CHANGES
				and Time.get_ticks_msec() - started < MAX_MEASURE_MSEC):
		await process_frame
		var live_sig := _signature(facade.research_snapshot(handle))
		var shown_sig := _signature(workspace.get("_research"))
		if live_sig != last_live:
			live_changes += 1
			last_live = live_sig
		if shown_sig != last_shown:
			shown_changes += 1
			last_shown = shown_sig
		var now := Time.get_ticks_msec()
		if live_sig != shown_sig:
			if stale_since < 0:
				stale_since = now
		elif stale_since >= 0:
			max_lag = maxi(max_lag, now - stale_since)
			stale_since = -1
	print("[latency] live_changes=%d shown_changes=%d max_lag_ms=%d elapsed_ms=%d" % [
		live_changes, shown_changes, max_lag, Time.get_ticks_msec() - started])
	return {"live_changes": live_changes, "shown_changes": shown_changes, "max_lag": max_lag}


func _expect(label: String, condition: bool) -> void:
	if not condition:
		_failures.append(label)
		print("FAIL: %s" % label)
