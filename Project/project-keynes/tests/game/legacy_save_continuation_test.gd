extends Node

## Loads a save written by an earlier build into a running session and continues it.
##
## Why this exists: `Invoke-SaveReplay` stages a save and loads it on a cold
## start, but on a cold start the pending load is not consumed by the main menu
## and the game boots a fresh world instead (day restarts at ~0, `eco_day = -1`).
## Its readiness probe then reports `runtime_never_became_ready` for every save,
## including one this build just wrote, so it cannot answer "does an old save
## still load". This fixture starts a world first — the same context the
## round-trip test loads in — and then swaps in the staged file, which is exactly
## the provider-restore path a player's "continue" runs.
##
## Stage the file as <PK_SAVE_DIR>/<slot>.pksv and run with
## PK_LEGACY_SAVE_CONTINUITY=1; PK_LEGACY_SAVE_SLOT selects the slot
## (default `autosave`). The expected day is read from the staged file's header,
## never from the caller.

var _failures := PackedStringArray()
var _game_flow: Node
var _game_save: Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_game_flow = get_tree().root.get_node_or_null("GameFlow")
	_game_save = get_tree().root.get_node_or_null("GameSave")
	_expect("game flow autoload is available", _game_flow != null)
	_expect("game save autoload is available", _game_save != null)
	if _game_flow == null or _game_save == null:
		await _finish()
		return
	var slot := OS.get_environment("PK_LEGACY_SAVE_SLOT").strip_edges()
	if slot.is_empty():
		slot = "autosave"
	var repository = _game_save.get("_repository")
	var save_dir := String(repository.get("_save_dir")) if repository != null else ""
	_expect("PK_SAVE_DIR points away from the player's saves",
		save_dir != SaveRepository.SAVE_DIR)
	if save_dir == SaveRepository.SAVE_DIR:
		await _finish()
		return

	var expected_day := -1
	var staged_found := false
	for entry in repository.list_slots():
		if String(entry.get("slot_id", "")) != slot:
			continue
		staged_found = bool(entry.get("exists", false))
		expected_day = int(entry.get("day", -1))
		_expect("staged save is listed as loadable (day %d)" % expected_day,
			staged_found and bool(entry.get("loadable", false)))
	_expect("staged slot exists", staged_found)
	if not staged_found:
		await _finish()
		return

	# Bootstrap a world first; the staged save then replaces it in-session.
	var config := NewGameConfig.new()
	config.country.name = "Legacy Continuation"
	config.country.foreign_count = 0
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var previous_scene := get_tree().current_scene
	var begin: Dictionary = _game_flow.call("begin_new_game", config)
	_expect("bootstrap new game accepted", bool(begin.get("ok", false)))
	var host: WorldRuntimeHost = await _wait_for_runtime(previous_scene)
	_expect("bootstrap world reached a ready runtime", host != null)
	if host == null:
		await _finish()
		return
	var bootstrap_scene := host.get_parent() as PlayerGame
	var clock: WorldClock = bootstrap_scene.get_node("WorldClock")
	# Let the bootstrap world reach a committed day boundary before handing it to
	# the load. A world paused before its first settlement has no idle boundary to
	# hand over, and the load request then never starts.
	clock.speed_multiplier = 20.0
	clock.pause(false)
	var bootstrap_start := clock.day_index()
	for _frame in range(1200):
		await get_tree().process_frame
		if clock.day_index() > bootstrap_start + 1:
			break
	_expect("bootstrap world reached a committed boundary (day %d)" % clock.day_index(),
		clock.day_index() > bootstrap_start)
	# Do not stop the clock here: the close path drains an in-flight day at the
	# next boundary, and a world frozen mid-day never closes, which leaves the
	# load request pending forever.
	#
	# Save once before loading, exactly like the round-trip fixture: the save
	# waits for the safe boundary (country idle + economy committed) and that is
	# the state the world-close path can actually drain.
	var prime_slot := "manual_2" if slot == "manual_1" else "manual_1"
	var primed: Dictionary = await _game_save.call("request_manual_save", prime_slot)
	_expect("bootstrap world reaches a save boundary", bool(primed.get("ok", false)))

	var load_result: Array[Dictionary] = []
	_game_save.load_completed.connect(
		func(loaded_slot: String, result: Dictionary) -> void:
			if loaded_slot == slot:
				load_result.append(result),
		CONNECT_ONE_SHOT)
	_game_flow.player_start_failed.connect(
		func(result: Dictionary) -> void: load_result.append(result),
		CONNECT_ONE_SHOT)
	var load_begin: Dictionary = _game_flow.call("begin_load_game", slot)
	_expect("staged save load request accepted", bool(load_begin.get("ok", false)))
	if not bool(load_begin.get("ok", false)):
		await _finish()
		return
	# The bootstrap can already have advanced beyond the saved day. Require
	# the provider's completion for this slot before looking at the calendar.
	var restored := await _wait_for_day(bootstrap_scene, expected_day, load_result)
	_expect("staged save actually restored (day %d, result %s, error %s)"
		% [expected_day, JSON.stringify(load_result), restored.get("error", "")],
		restored.get("ok", false))
	if not bool(restored.get("ok", false)):
		await _finish()
		return
	var loaded_host: WorldRuntimeHost = restored.host
	var loaded_scene := loaded_host.get_parent() as PlayerGame
	var loaded_clock: WorldClock = loaded_scene.get_node("WorldClock")
	_expect("restored runtime is not faulted",
		String(loaded_host.generator().get_runtime_thread_report().get(
			"simulation_host_state", "")) != "FAULTED")
	_expect("restored economy is the staged one, not the bootstrap world",
		int(loaded_host.generator().get_economy_report().get("last_committed_day", -1)) >= 0)

	# The 365-day history lane is no longer persisted; a legacy save must still
	# restore and keep simulating day by day. The restore finalize re-applies the
	# save's own pause state after the world goes live, so the test clock is
	# asserted every frame instead of once.
	var start_day := loaded_clock.day_index()
	for _frame in range(6000):
		await get_tree().process_frame
		if loaded_clock.paused:
			loaded_clock.pause(false)
		loaded_clock.speed_multiplier = 20.0
		if loaded_clock.day_index() > start_day:
			break
	_expect("restored legacy world advances (day %d -> %d)"
		% [start_day, loaded_clock.day_index()],
		loaded_clock.day_index() > start_day)
	await _finish()


## Waits until a PlayerGame scene reports the staged day with a tickable runtime.
## Reports what it saw on timeout so a stall is diagnosable from the log alone.
func _wait_for_day(previous_scene: PlayerGame, expected_day: int,
		load_result: Array[Dictionary]) -> Dictionary:
	var last := {}
	# The transition runs the catalog cache and drains the previous world, which
	# can take seconds; and a restored world keeps ticking the moment it is live,
	# so the day may already be past the saved one when the loop looks.
	for _frame in range(12000):
		await get_tree().process_frame
		if not load_result.is_empty() and not bool(load_result[0].get("ok", false)):
			return {"ok": false, "error": JSON.stringify(load_result[0])}
		var scene_ref := get_tree().current_scene
		if scene_ref == null or scene_ref == previous_scene or not scene_ref is PlayerGame:
			continue
		var host := scene_ref.get_node_or_null("RuntimeHost") as WorldRuntimeHost
		if host == null:
			continue
		if not host.last_world_generation_error.is_empty():
			return {"ok": false, "error": JSON.stringify(host.last_world_generation_error)}
		if host.generator() == null:
			continue
		var clock := (scene_ref as PlayerGame).get_node_or_null("WorldClock") as WorldClock
		if clock == null:
			continue
		last = {
			"day": clock.day_index(),
			"ready": host.is_runtime_ready_for_ticks(),
			"state": String(host.generator().get_runtime_thread_report().get(
				"simulation_host_state", "")),
			"eco_day": int(host.generator().get_economy_report().get(
				"last_committed_day", -1)),
		}
		if _frame % 600 == 0:
			print("[legacy-continuation] waiting: %s flow=%s" % [
				JSON.stringify(last),
				JSON.stringify({
					"pending": _game_flow.get("_pending_request"),
					"transition": _game_flow.get("_transition_active"),
					"busy": _game_save.get("_busy"),
					"pending_load": _game_save.get("_pending_load"),
				})])
		if not load_result.is_empty() and bool(load_result[0].get("ok", false)) \
				and int(last.day) >= expected_day and bool(last.ready):
			return {"ok": true, "host": host}
	print("[legacy-continuation] timeout: %s" % JSON.stringify(last))
	return {"ok": false}


func _wait_for_runtime(previous_scene) -> WorldRuntimeHost:
	for _frame in range(2400):
		await get_tree().process_frame
		var scene_ref := get_tree().current_scene
		if scene_ref == null or scene_ref == previous_scene or not scene_ref is PlayerGame:
			continue
		var host := scene_ref.get_node_or_null("RuntimeHost") as WorldRuntimeHost
		if host != null and not host.last_world_generation_error.is_empty():
			print("[legacy-continuation] world failed: %s"
				% JSON.stringify(host.last_world_generation_error))
			return null
		if host != null and host.is_runtime_ready_for_ticks() \
				and host.current_map() != null and host.generator() != null \
				and bool(host.generator().gameplay_start_report().get("ok", false)):
			await get_tree().process_frame
			return host
	return null


func _expect(label: String, condition: bool) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		_failures.append(label)
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	for host in get_tree().get_nodes_in_group(&"world_sessions"):
		var closed: Dictionary = await host.close_world()
		_expect("world closes cleanly", bool(closed.get("ok", false)))
	await get_tree().process_frame
	print("legacy save continuation: %d failures" % _failures.size())
	get_tree().quit(1 if _failures.size() > 0 else 0)
