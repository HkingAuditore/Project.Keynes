extends "res://tests/ideology/ideology_worker_authority_parity_test.gd"

# The production world keeps an Economy epoch open across a domain-mask flip.
# Reuse the real card/peer fixture, but require the restarted worker to stay healthy.
func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	await _phase_k3_k4_k2()
	_expect("restart scenario executed its card and authority checks", _checks >= 20)
	if _worlds.is_empty():
		_fail("restart scenario retains its production world")
		return 1
	var world: Dictionary = _worlds.back()
	var ext: Object = world["ext"]
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("Economy survives the production authority flip without a worker fault",
		String(report.get("simulation_host_state", "")) != "FAULTED"
		and int(report.get("worker_fault_count", -1)) == 0,
		String(report.get("fault_code", "")))
	_expect("the restarted worker retains the requested domain mask",
		int(report.get("authoritative_domain_mask", 0)) == MASK_SPLIT_IDEOLOGY_MAIN,
		str(report.get("authoritative_domain_mask", 0)))
	var before := int(report.get("simulation_committed_day", -1))
	_drive_days(world, 4)
	report = ext.get_runtime_thread_report()
	_expect("the restarted worker continues committing days",
		int(report.get("simulation_committed_day", -1)) > before,
		str(report))
	var economy: Dictionary = ext.get_economy_report()
	_expect("the surviving Economy epoch remains healthy",
		not bool(economy.get("fatal", true)), str(economy.get("fatal_reason", "")))
	_teardown_all()
	return 0

func _run_and_finish() -> void:
	var code := await _run()
	print("runtime economy worker restart: %d checks, %d failures" % [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))

const RestartBoundary = preload("res://tests/runtime/worker_restart_boundary.gd")

func _wait_worker_state(w: Dictionary, wanted: String, timeout_ms: int) -> bool:
	if wanted == "STOPPED":
		return RestartBoundary.stopped(w["ext"], timeout_ms)
	return super._wait_worker_state(w, wanted, timeout_ms)

func _wait_pod_day(w: Dictionary, _before: int, timeout_ms: int) -> void:
	var ext: Object = w["ext"]
	ext.set_runtime_clock(false, WORKER_SPEED)
	RestartBoundary.committed(w, timeout_ms, func() -> void: _service_peers(ext, 1))
	ext.set_runtime_clock(true, WORKER_SPEED)

func _drive_day(w: Dictionary) -> Dictionary:
	var result := super._drive_day(w)
	if bool(result.get("ok", false)) and not bool(w.get("last_suppressed", false)):
		_wait_pod_day(w, -1, POD_WAIT_MS)
	return result
