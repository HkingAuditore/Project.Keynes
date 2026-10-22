extends SceneTree

## PROBE: does the IDEOLOGY worker loop run end to end in a host fixture?
##
## The stress test drives `run_ideology_daily`, which is the *main-thread* path and
## is suppressed whenever IDEOLOGY is worker-authoritative -- i.e. in the shipped
## game. Before any worker benchmark is meaningful, the three calls have to be
## proven to work against a real host: publish inputs, poll the worker's intent,
## acknowledge it.
##
## This prints raw results on purpose. The ack shape is only knowable from the
## implementation, and a wrong guess there fails silently as `code != "ok"`.

## 30x20 matches runtime_climate_save_roundtrip_test's known-good fixture.
## A square 32x32 failed generation in 5 s, so the generator is picky about size.
const MAP_WIDTH := 30
const MAP_HEIGHT := 20
const SEED := 20260807
const DAYS := 3

var _checks := 0
var _failures := 0


## `_init` runs before the SceneTree root exists; `generate_world` then fails with
## no generator and no error. Deferring to an idle frame is what the climate
## fixture does and it is not optional here.
func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	await _run()
	_finish()


func _run() -> void:
	var clock: WorldClock = WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)

	var host: WorldRuntimeHost = WorldRuntimeHost.new()
	host.map_width = MAP_WIDTH
	host.map_height = MAP_HEIGHT
	host.initial_seed = SEED
	# Must be true: the class-opinion snapshot only has countries if the economy
	# was bootstrapped with settlements. The climate fixture leaves this false on
	# purpose (it only needs a valid empty economy), which is why it can never
	# produce a non-zero opinion snapshot.
	host.generate_test_economy_data = true
	host.runtime_parity_forcing = true
	host.runtime_climate_authority_enabled = false
	get_root().add_child(host)
	host.configure(null, null, clock)

	# Countries are only built when a new-game config is present: generate_world
	# forwards `_new_game_config` to the generator, which it never has unless the
	# session was configured. Without this the world is pure terrain and the
	# economy stays at country_count = 0 forever.
	var config: NewGameConfig = NewGameConfig.create_default()
	config.base.initial_seed = SEED
	var configured: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	_expect("session configures a new game", bool(configured.get("ok", false)),
		str(configured))

	await host.generate_world(SEED)
	var generator: Object = host.get_generator()
	if not _require("world generation succeeded", generator != null):
		return
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("world ext is available", ext != null):
		return

	# The opinion snapshot only becomes valid after the economy commits a day, so
	# the loop has to be warmed up first. Driving the host tick is what the real
	# game does; calling economy directly is not exported.
	print("    map: cell0=", ext.get_country_cell_summary(0))
	var econ_boot: Dictionary = ext.get_economy_report()
	print("    econ: bootstrapped=%s country_generation=%s cells=%s" % [
		str(econ_boot.get("bootstrapped", false)),
		str(econ_boot.get("country_generation", -1)),
		str(econ_boot.get("cohort_count", -1))])
	print("    map: econ_report=", ext.get_economy_report())
	# The worker only advances when the runtime clock is running; a paused clock
	# leaves `last_committed_day` at -1 no matter how many ticks are pumped.
	print("    worker before: ", ext.get_runtime_thread_report())
	var started_worker: Dictionary = ext.start_runtime_worker() \
		if ext.has_method("start_runtime_worker") else {}
	print("    start_runtime_worker: ", started_worker)
	var clocked: Dictionary = ext.set_runtime_clock(true, 400.0)
	print("    clock: ", clocked)
	var warmed := await _warm_up_days(ext, host, clock, 5)
	_expect("economy committed at least one day", warmed,
		str(ext.get_country_class_opinion_snapshot()))

	var started := Time.get_ticks_usec()
	var published: Dictionary = ext.publish_ideology_worker_inputs()
	print("    publish: ", published)
	_expect("publish inputs accepts the opinion snapshot",
		bool(published.get("ok", false)), str(published))

	var intent: Dictionary = ext.poll_ideology_worker_intent()
	print("    poll(first): ", intent)
	_expect("poll reports a well-formed answer",
		bool(intent.get("ok", false)), str(intent))

	# With no worker thread running, `available` is expected to be false. That is
	# the honest outcome of this probe: it proves the two calls are reachable and
	# shaped as documented, not that a worker produced an intent.
	if not bool(intent.get("available", false)):
		print("    note: no worker thread in this fixture -> available=false")
	else:
		var ack: Dictionary = ext.submit_ideology_worker_ack({
			"request_id": int(intent.get("request_id", 0)),
			"transaction_id": int(intent.get("transaction_id", 0)),
			"target_handle": int(intent.get("target_handle", 0)),
			"target_generation": int(intent.get("target_generation", 0)),
			"code": 0,
			"effective_day": int(intent.get("effective_day", 0)),
		})
		print("    ack: ", ack)
		_expect("ack is accepted", bool(ack.get("ok", false)), str(ack))

	var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("    worker-loop wall: %.2f ms over %d days" % [elapsed_ms, DAYS])


## Advance whole days until the class-opinion snapshot carries a revision. The
## snapshot is produced by the economy's COMMIT stage, so "publish rejected,
## revision 0" simply means the world has not lived a day yet.
## Advance whole days until the economy commits one.
##
## The important detail, copied from runtime_climate_save_roundtrip_test: the worker
## runs on its own thread, so pumping frames is not enough -- the loop has to stop
## the runtime clock and *sleep* while polling, which is what gives the worker wall
## time to finish an epoch.
func _warm_up_days(ext: Object, host: WorldRuntimeHost, clock: WorldClock,
		days: int) -> bool:
	var committed_before := int(ext.get_economy_report().get(
		"last_committed_day", -1))
	for day in range(1, days + 1):
		var phase: Variant = clock.season_phase_for_day(day)
		clock.current_day = float(day)
		host.run_daily_tick(day, phase)
		host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier(clock) and pulses < 512:
			clock.simulation_backpressure_pulse.emit(day)
			pulses += 1
		# Stop the clock and give the worker real time; frames alone starve it.
		ext.set_runtime_clock(false, 400.0)
		var deadline := Time.get_ticks_msec() + 1500
		while Time.get_ticks_msec() < deadline:
			var snapshot: Dictionary = ext.get_country_class_opinion_snapshot()
			if int(snapshot.get("revision", 0)) > 0:
				print("    warm-up: opinion revision=%d at day %d" % [
					int(snapshot.get("revision", 0)), day])
				return true
			OS.delay_msec(20)
		ext.set_runtime_clock(true, 400.0)
		var econ: Dictionary = ext.get_economy_report()
		print("    warm-up day %d: pulses=%d stage=%s committed=%d" % [
			day, pulses, str(econ.get("stage", "?")),
			int(econ.get("last_committed_day", -1))])
	print("    warm-up: still not committed (was %d)" % committed_before)
	return false


func _has_hard_barrier(clock: WorldClock) -> bool:
	return clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or clock._simulation_backpressure_sources.has(&"economy_day_barrier")


func _require(label: String, condition: bool) -> bool:
	_expect(label, condition)
	return condition


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		print("  [FAIL] %s %s" % [label, detail])


func _finish() -> void:
	print("=== ideology worker loop: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
