extends SceneTree

# Regression: the native day barrier must keep committing days through an era
# milestone and must not latch the runtime-stop fault.
#
# Reported symptom: after an era upgrade the calendar froze, every country
# command was rejected with `runtime_worker_faulted`, and the era badge never
# moved again — the native peer watchdog had fired
# `day_wait_peer_stall_timeout` (`[day-stall-fault] stall=0x16 peer_ms≈5.1s`).
# A wall-clock peer deadline is only meaningful while the main thread is
# servicing the peer pump, so this walks the three shapes that starve it:
# plain play, a pause longer than the 5000ms protocol deadline, and an era
# milestone grant (which adds the Effect/Modifier ACK chain to the barrier).
#
#   godot --headless --path . --script res://tests/runtime/runtime_day_barrier_era_test.gd

const WARMUP_DAYS := 5
const PAUSE_SECONDS := 6.0
const POST_GRANT_DAYS := 4
const MAX_WAIT_MSEC := 240000

var _failures := 0


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
	var clock := game.get_node("WorldClock") as WorldClock
	var ui := game.get_node("UI") as GameUIManager
	var controller = ui.get("_player_controller")
	var facade = controller.get_country_facade()
	var handle := int(controller.get_player_country_handle())
	var badge: EraIndicator = ui.get("_era_indicator")
	clock.pause(false)
	clock.set_speed(50.0)

	var start_day := int(clock.day_index())
	_expect("plain play commits days", await _advance(clock, runtime, start_day + WARMUP_DAYS),
		"day=%d want>=%d" % [int(clock.day_index()), start_day + WARMUP_DAYS])

	# A pause longer than the peer deadline must park the worker, not fault it.
	clock.pause(true)
	await create_timer(PAUSE_SECONDS).timeout
	_expect("long pause with a day in flight does not fault the runtime",
		_fault_code(runtime).is_empty(), _fault_detail(runtime))
	clock.pause(false)
	var resume_day := int(clock.day_index())
	_expect("the barrier resumes after the pause",
		await _advance(clock, runtime, resume_day + 1), _fault_detail(runtime))

	var milestones: PackedInt32Array = facade.era_milestone_indices()
	var ids: PackedStringArray = facade.get("_catalog").get("technology_ids", PackedStringArray())
	var milestone_id := String(ids[int(milestones[1])])
	# The live HUD plays the era ceremony by pausing the clock. This headless
	# barrier check only needs the committed era and ACK path, so use the
	# existing popup suppression before the grant is observed by the UI.
	if controller != null and controller.has_method("set_popups_suppressed"):
		controller.set_popups_suppressed(true)
	ui.set("_gm_popups_suppressed", true)
	var granted: Dictionary = facade.grant_technology(handle, StringName(milestone_id),
		int(clock.day_index()), 4242)
	_expect("milestone grant is accepted", bool(granted.get("ok", false)), str(granted))
	var grant_day := int(clock.day_index())
	_expect("days keep committing after the milestone grant",
		await _advance(clock, runtime, grant_day + POST_GRANT_DAYS), _fault_detail(runtime))
	# The HUD refresh is deliberately debounced by GameUIManager; pull the same
	# existing refresh synchronously so this headless check observes the committed
	# era without waiting on an animation timer.
	ui.call("_refresh_era_indicator")
	_expect("the era advanced", int(facade.current_era_index(handle)) >= 1,
		"era_index=%d" % int(facade.current_era_index(handle)))
	_expect("the era badge followed the new era",
		String(badge.get("_model").get("era_id", "")) == "agrarian",
		String(badge.get("_model").get("era_id", "")))
	_expect("the runtime never latched a fault", _fault_code(runtime).is_empty(),
		_fault_detail(runtime))

	for failure in _failures:
		push_error(failure)
	print("runtime_day_barrier_era_test: %s (%d failures)" % [
		"PASS" if _failures == 0 else "FAIL", _failures])
	quit(0 if _failures == 0 else 1)


func _advance(clock: WorldClock, runtime: WorldRuntimeHost, target_day: int) -> bool:
	var deadline := Time.get_ticks_msec() + MAX_WAIT_MSEC
	while int(clock.day_index()) < target_day and Time.get_ticks_msec() < deadline:
		await process_frame
		if not _fault_code(runtime).is_empty():
			return false
	return int(clock.day_index()) >= target_day


func _fault_code(runtime: WorldRuntimeHost) -> String:
	return String(_report(runtime).get("fault_code", ""))


func _fault_detail(runtime: WorldRuntimeHost) -> String:
	var report := _report(runtime)
	return "fault=%s state=%s day_stall=%s committed_day=%s" % [
		str(report.get("fault_code", "")),
		str(report.get("state", report.get("simulation_host_state", ""))),
		str(report.get("day_stall_reason_mask", 0)),
		str(report.get("simulation_committed_day", report.get("committed_day", -1)))]


func _report(runtime: WorldRuntimeHost) -> Dictionary:
	if runtime == null or not runtime.has_method("get_runtime_thread_report"):
		return {}
	return runtime.get_runtime_thread_report()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	print("  [FAIL] %s (%s)" % [label, detail])
