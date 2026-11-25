extends "res://tests/runtime/background_daily_self_sufficiency_test.gd"


func _run() -> void:
	await _run_world(false, true)
	_finish()


func _sample_military_world(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.get_generator()
	var economy: EconomyFacade = generator.get_economy_facade()
	var ext: DCWorldExt = economy.world_ext()
	clock.set_speed(SPEED)
	for day in [1, 2]:
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("Economy commits day %d before restarting" % day, settled)
		if not settled:
			return {}

	clock.pause(true)
	host._sync_runtime_worker_clock()
	var before := ext.runtime_committed_day()
	var stopped := await host._stop_previous_runtime_worker()
	_expect("the production worker exits", bool(stopped.get("ok", false))
		and bool(ext.get_runtime_control_state().get("simulation_executor_exited", false)))
	if not bool(stopped.get("ok", false)):
		return {}
	host._start_runtime_executor()
	var restarted := ext.get_runtime_thread_report()
	_expect("restart keeps the committed day and full authority",
		host._web_worker_start_ok and ext.runtime_committed_day() == before
		and int(restarted.get("authoritative_domain_mask", 0)) == 0xfff)
	_expect("manual pause survives the restart", clock.paused)
	clock.pause(false)
	host._sync_runtime_worker_clock()
	for day in range(before + 1, before + 5):
		_publish_day(host, clock, day)
		var settled := await _wait_golden_read_boundary(host, economy, day)
		_expect("the same Economy continues with day %d" % day, settled)
		if not settled:
			break
	var report := economy.report()
	_expect("the resumed economy settles without a fault",
		not bool(report.get("fatal", true))
		and int(report.get("last_committed_day", -1)) >= before + 4)
	return {}
