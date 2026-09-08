extends SceneTree

# Per-domain Climate ACTIVE authority (plan step P7).
#
# Three things have to hold together for Climate to be worker-owned, and each
# one fails in a way the other two cannot detect:
#
#   1. The gate opens. A per-domain ACTIVE request naming CLIMATE|COMMIT is
#      granted even though the other ten domains have no POD handler, while a
#      request for the whole graph is still refused.
#   2. The main thread stops computing Climate. dispatch_system_schedule must
#      suppress all fourteen nodes, which shows up as
#      breakdown.climate_authority_suppressed.
#   3. MapData keeps moving. Suppression without write-back would freeze the
#      world at the day authority was granted, and every check above would
#      still pass.
#
# Also asserts the runtime fallback: turning authority off and restarting the
# worker must hand Climate back to the main thread.
#
# Usage:
#   godot --headless --path Project/project-keynes -s tests/climate_authority_test.gd

const SEED := 20260906
const MAP_WIDTH := 60
const MAP_HEIGHT := 40
const AUTHORITY_WAIT_TIMEOUT_MSEC := 8000
const POLL_MSEC := 4
const CLIMATE_AUTHORITY_MASK := 0x802 # CLIMATE(0x2) | COMMIT(0x800)

var _checks := 0
var _failures := 0


func _init() -> void:
	var exit_code := await _run()
	quit(exit_code)


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  ok   %s" % label)
	else:
		_failures += 1
		printerr("  FAIL %s" % label)


func _run() -> int:
	print("=== climate per-domain authority ===")
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("[climate-authority] DCWorldExt unavailable; rebuild and restart Godot")
		return 3

	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host := WorldRuntimeHost.new()
	host.map_width = MAP_WIDTH
	host.map_height = MAP_HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 0
	host.runtime_climate_authority_enabled = true
	get_root().add_child(host)
	host.configure(null, null, clock)

	await host.generate_world(SEED)
	var map: MapData = host.get_current_map()
	var generator: MapGenerator = host.get_generator()
	if map == null or generator == null:
		push_error("[climate-authority] world generation failed")
		return 4
	var ext = generator.get_data_core_world_ext()
	if ext == null:
		push_error("[climate-authority] world ext unavailable")
		return 4

	# The ring is the only new lock-free structure here, so its contract is
	# checked before anything depends on it.
	if ext.has_method("runtime_climate_writeback_self_test"):
		_expect("writeback ring self test", bool(
			ext.runtime_climate_writeback_self_test()))
	else:
		_expect("writeback ring self test bound", false)

	# 1. The gate. A whole-graph ACTIVE request must still be refused; the fact
	#    that Climate was granted must not have opened the general promotion.
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("worker requested CLIMATE|COMMIT authority",
		int(report.get("requested_authority_mask", 0)) == CLIMATE_AUTHORITY_MASK)
	_expect("whole-graph gate still shut",
		int(report.get("implemented_domain_mask", 0)) != int(
			report.get("required_domain_mask", 0)) \
		and not bool(report.get("authority_ready", true)))

	# The grant lands on the worker's first completed day, and that day needs an
	# environment whose own day matches it. The main thread captures the *previous*
	# day's input each tick (see sus_tick_daily: trace_input_day = day - 1), so the
	# worker cannot commit day 1 until the main thread has ticked to day 2. That
	# one-day offset is the lag semantic, not a warm-up artefact: driving ticks is
	# therefore part of waiting for the grant, not something to do after it.
	if not ext.has_method("set_runtime_clock"):
		push_error("[climate-authority] set_runtime_clock missing; rebuild the extension")
		return 6
	ext.set_runtime_clock(false, 50.0)
	var granted := false
	var grant_tick := 0
	var deadline := Time.get_ticks_msec() + AUTHORITY_WAIT_TIMEOUT_MSEC
	var tick := 0
	while Time.get_ticks_msec() < deadline and tick < 8:
		tick += 1
		var grant_phase := clock.season_phase_for_day(tick)
		clock.current_day = float(tick)
		host.run_daily_tick(tick, grant_phase)
		host.finish_daily_tick(0.0, {})
		var inner := Time.get_ticks_msec() + 1000
		while Time.get_ticks_msec() < inner:
			report = ext.get_runtime_thread_report()
			if bool(report.get("climate_worker_authoritative", false)):
				granted = true
				grant_tick = tick
				break
			OS.delay_msec(POLL_MSEC)
		if granted:
			break
	if granted:
		print("  note: authority granted on main-thread tick %d" % grant_tick)
	if not granted:
		print("  diag: fallback=%s pod_ready=%s env_gen=%s env_day=%s committed_day=%s completed_days=%s state=%s fault=%s worker_stage_mask=0x%X" % [
			String(report.get("climate_pod_fallback_reason", "")),
			str(report.get("climate_pod_ready", false)),
			str(report.get("simulation_environment_generation",
				report.get("environment_generation", -1))),
			str(report.get("environment_day", -1)),
			str(report.get("simulation_committed_day", -1)),
			str(report.get("completed_days", -1)),
			String(report.get("simulation_host_state", "")),
			String(report.get("simulation_worker_blocker", "")),
			int(report.get("climate_worker_stage_mask", 0))])
	_expect("CLIMATE authority granted after a committed day", granted)
	_expect("authoritative mask names CLIMATE only",
		int(report.get("authoritative_domain_mask", 0)) == CLIMATE_AUTHORITY_MASK)
	_expect("effective mode is ACTIVE under partial promotion",
		String(report.get("simulation_thread_mode", "")) == "ACTIVE")
	if not granted:
		host.free()
		clock.free()
		return 7

	# 2. Suppression + 3. write-back. Both are observed over the same ticks:
	#    the production breakdown must report suppression while MapData's
	#    temperature array must still change.
	var before_temp: PackedFloat32Array = map.temp_arr.duplicate()
	var suppressed_ticks := 0
	var breakdown_ticks := 0
	for extra in range(1, 13):
		var next_tick := grant_tick + extra
		var phase := clock.season_phase_for_day(next_tick)
		clock.current_day = float(next_tick)
		host.run_daily_tick(next_tick, phase)
		host.finish_daily_tick(0.0, {})
		var breakdown: Dictionary = generator.sus_climate_breakdown() \
			if generator.has_method("sus_climate_breakdown") else {}
		if not breakdown.is_empty():
			breakdown_ticks += 1
			if bool(breakdown.get("climate_authority_suppressed", false)):
				suppressed_ticks += 1
		# The write-back boundary lives in _process; drive it directly rather
		# than waiting on frames the SceneTree is not pumping here.
		host._consume_runtime_commit_if_ready()
		OS.delay_msec(POLL_MSEC)

	var diagnostics: Dictionary = host.climate_authority_diagnostics()
	_expect("production Climate schedule suppressed on every tick with a breakdown",
		breakdown_ticks > 0 and suppressed_ticks == breakdown_ticks)

	# 2b. The signal path, which the direct run_daily_tick calls above bypass.
	#     _on_clock_day_changed owns a whole-graph early-out; if that gate reads
	#     the per-domain promotion it stops the tick outright and economy,
	#     country, triggers and perf recording all go silent while Climate looks
	#     perfectly healthy. Only a promoted *whole graph* may skip the tick.
	var ticks_before_signal := host.get_fast_tick_count()
	var signal_tick := grant_tick + 13
	clock.current_day = float(signal_tick)
	host._on_clock_day_changed(signal_tick)
	host.finish_daily_tick(0.0, {})
	_expect("per-domain promotion still runs the main-thread daily tick (%d -> %d)" % [
			ticks_before_signal, host.get_fast_tick_count()],
		host.get_fast_tick_count() > ticks_before_signal)
	_expect("write-back applied at least one worker day",
		int(diagnostics.get("writeback_days", 0)) > 0)
	_expect("write-back advanced its own cursor",
		int(diagnostics.get("writeback_generation", 0)) > 0)
	var after_temp: PackedFloat32Array = map.temp_arr
	var changed_cells := 0
	for i in range(mini(before_temp.size(), after_temp.size())):
		if before_temp[i] != after_temp[i]:
			changed_cells += 1
	_expect("MapData temperature moved under worker authority (%d cells)" % changed_cells,
		changed_cells > 0)

	# The fallback. Stopping the worker must revoke authority immediately, so
	# the main thread starts computing Climate again on the next tick.
	ext.request_runtime_stop()
	report = ext.get_runtime_thread_report()
	_expect("stop revokes CLIMATE authority at once",
		not bool(report.get("climate_worker_authoritative", true)))
	# The native daily contract runs on a stride (10 days by default), so a
	# single tick after revocation can land in the gap between rounds and leave
	# the diagnostics showing the last suppressed round. Tick until a round
	# actually happens.
	var stale_tick := int(generator.sus_climate_breakdown().get("_tick_idx", -1)) \
		if generator.has_method("sus_climate_breakdown") else -1
	var breakdown_after: Dictionary = {}
	var resume_tick := grant_tick + 12
	for _i in range(40):
		resume_tick += 1
		clock.current_day = float(resume_tick)
		host.run_daily_tick(resume_tick, clock.season_phase_for_day(resume_tick))
		host.finish_daily_tick(0.0, {})
		breakdown_after = generator.sus_climate_breakdown() \
			if generator.has_method("sus_climate_breakdown") else {}
		if int(breakdown_after.get("_tick_idx", stale_tick)) > stale_tick:
			break
	print("  note: main thread recomputed Climate at tick %d (was %d)" % [
		int(breakdown_after.get("_tick_idx", -1)), stale_tick])
	_expect("main thread resumes Climate after revocation",
		int(breakdown_after.get("_tick_idx", stale_tick)) > stale_tick \
		and not bool(breakdown_after.get("climate_authority_suppressed", false)))

	host.free()
	clock.free()
	await process_frame
	print("=== climate per-domain authority: %d checks, %d failures ===" % [
		_checks, _failures])
	return 0 if _failures == 0 else 1
