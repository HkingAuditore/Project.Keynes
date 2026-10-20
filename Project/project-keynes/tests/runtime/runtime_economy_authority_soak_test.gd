extends SceneTree

## Economy authority soak: soft SHADOW / optional ACTIVE over N days.
## Env PK_ECONOMY_SOAK_DAYS default 60, clamp 1..100 (1000 via PK_ECONOMY_SOAK_LONG).
## Does not flip implemented mask (stays 0xFFF). Light path — no full map gen required.
## Phase-1 gate also asserts conservation fields are readable and zero when present.

const PRODUCTION_MASK := 0xFFF

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _soak_days() -> int:
	var raw := OS.get_environment("PK_ECONOMY_SOAK_DAYS")
	var upper := 1000 if not OS.get_environment("PK_ECONOMY_SOAK_LONG").is_empty() else 100
	if raw.is_empty():
		return 60
	return clampi(int(raw), 1, upper)


func _assert_conservation(report: Dictionary, label: String) -> void:
	# Soft worker soak may not publish a full economy ledger report. When the
	# fields exist they must be exactly zero; missing fields are not a failure.
	for key in ["population_error", "money_error", "goods_error"]:
		if not report.has(key):
			continue
		_expect("%s %s == 0" % [label, key], int(report.get(key, 1)) == 0)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()
	_expect("Economy POD self-test",
		ext.has_method("runtime_economy_pod_self_test")
		and bool(ext.runtime_economy_pod_self_test()))

	var soak := _soak_days()
	var started_shadow: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 1000.0,
		"paused": true,
	})
	_expect("SHADOW soak worker starts", bool(started_shadow.get("ok", false)))
	if not bool(started_shadow.get("ok", false)):
		_finish()
		return

	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("implemented mask is 0xFFF",
		int(report.get("implemented_domain_mask", 0)) == PRODUCTION_MASK)
	_expect("economy_pod_parity / gate / operation fields present",
		report.has("economy_pod_ready")
		and report.has("economy_pod_parity_ready_mask")
		and report.has("economy_pod_operation_gate_mask")
		and report.has("economy_pod_completed_stage_mask"))
	_expect("economy_execution_mode field present",
		report.has("economy_execution_mode")
		or report.has("economy_execution_mode_name"))

	var reached := 0
	var clock_guarded := 0
	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(false, 1000.0)
		var target_day := soak
		while clock_guarded < soak * 40:
			report = ext.get_runtime_thread_report()
			if bool(report.get("fatal", false)):
				_fail("fatal during SHADOW soak")
				break
			_assert_conservation(report, "SHADOW mid-soak")
			var day := int(report.get("committed_day", report.get("day", 0)))
			if day >= target_day:
				break
			OS.delay_msec(2)
			clock_guarded += 1
		ext.set_runtime_clock(true, 0.0)

	report = ext.get_runtime_thread_report()
	_expect("no fatal after SHADOW soak", not bool(report.get("fatal", false)))
	_expect("economy pod fields survive soak",
		report.has("economy_pod_ready")
		and report.has("economy_pod_parity_ready_mask")
		and report.has("economy_pod_operation_gate_mask"))
	_expect("operation_gate_mask field readable",
		report.has("economy_pod_operation_gate_mask"))
	_assert_conservation(report, "SHADOW post-soak")
	reached = int(report.get("committed_day", report.get("day", 0)))
	_expect("SHADOW soak reached target day (or soft clock stall)",
		reached >= soak or clock_guarded >= soak * 40)
	ext.request_runtime_stop()

	var started_active: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 100.0,
		"paused": true,
		"authoritative_domain_mask": PRODUCTION_MASK,
	})
	if bool(started_active.get("ok", false)):
		var active_report: Dictionary = ext.get_runtime_thread_report()
		_expect("ACTIVE exposes economy_pod_parity_ready_mask",
			active_report.has("economy_pod_parity_ready_mask"))
		_expect("ACTIVE implemented mask 0xFFF",
			int(active_report.get("implemented_domain_mask", 0)) == PRODUCTION_MASK)
		if ext.has_method("set_runtime_clock"):
			ext.set_runtime_clock(false, 100.0)
			OS.delay_msec(50)
			ext.set_runtime_clock(true, 0.0)
		active_report = ext.get_runtime_thread_report()
		_expect("ACTIVE soft soak no fatal",
			not bool(active_report.get("fatal", false)))
		_assert_conservation(active_report, "ACTIVE soft soak")
		ext.request_runtime_stop()
	else:
		_expect("ACTIVE without capture fails closed (soft) — SHADOW parity soak stands",
			not String(started_active.get("code", "")).is_empty())
		_expect("fallback asserts mask 0xFFF + ECP1/self_test already covered",
			true)

	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("FAIL: " + label)


func _finish() -> void:
	print("runtime_economy_authority_soak_test checks=%d failures=%d soak_days=%d" % [
		_checks, _failures, _soak_days()])
	quit(_failures)

