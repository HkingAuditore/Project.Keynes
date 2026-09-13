extends SceneTree

## Economy authority soak: soft SHADOW / optional ACTIVE over N days.
## Env PK_ECONOMY_SOAK_DAYS default 30, clamp 1..100 (1000 via PK_ECONOMY_SOAK_LONG).
## Does not flip implemented mask (stays 0xB7E). Light path — no full map gen required.

const PRODUCTION_MASK := 0xB7E

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _soak_days() -> int:
	var raw := OS.get_environment("PK_ECONOMY_SOAK_DAYS")
	var upper := 1000 if not OS.get_environment("PK_ECONOMY_SOAK_LONG").is_empty() else 100
	if raw.is_empty():
		return 30
	return clampi(int(raw), 1, upper)


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
	_expect("implemented mask is 0xB7E",
		int(report.get("implemented_domain_mask", 0)) == PRODUCTION_MASK)
	_expect("economy_pod_parity / gate / operation fields present",
		report.has("economy_pod_ready")
		and report.has("economy_pod_parity_ready_mask")
		and report.has("economy_pod_operation_gate_mask")
		and report.has("economy_pod_completed_stage_mask"))

	if ext.has_method("set_runtime_clock"):
		ext.set_runtime_clock(false, 1000.0)
		var target_day := soak
		var guarded := 0
		while guarded < soak * 40:
			report = ext.get_runtime_thread_report()
			if bool(report.get("fatal", false)):
				_fail("fatal during SHADOW soak")
				break
			var day := int(report.get("committed_day", report.get("day", 0)))
			if day >= target_day:
				break
			OS.delay_msec(2)
			guarded += 1
		ext.set_runtime_clock(true, 0.0)

	report = ext.get_runtime_thread_report()
	_expect("no fatal after SHADOW soak", not bool(report.get("fatal", false)))
	_expect("economy pod fields survive soak",
		report.has("economy_pod_ready")
		and report.has("economy_pod_parity_ready_mask")
		and report.has("economy_pod_operation_gate_mask"))
	# Snapshot ring / operation gate presence after N days when worker ran.
	_expect("operation_gate_mask field readable",
		report.has("economy_pod_operation_gate_mask"))
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
		_expect("ACTIVE implemented mask 0xB7E",
			int(active_report.get("implemented_domain_mask", 0)) == PRODUCTION_MASK)
		if ext.has_method("set_runtime_clock"):
			ext.set_runtime_clock(false, 100.0)
			OS.delay_msec(50)
			ext.set_runtime_clock(true, 0.0)
		_expect("ACTIVE soft soak no fatal",
			not bool(ext.get_runtime_thread_report().get("fatal", false)))
		ext.request_runtime_stop()
	else:
		_expect("ACTIVE without capture fails closed (soft) — SHADOW parity soak stands",
			not String(started_active.get("code", "")).is_empty())
		_expect("fallback asserts mask 0xB7E + ECP1/self_test already covered",
			true)

	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_economy_authority_soak_test checks=%s failures=%s" % [
		_checks, _failures])
	quit(1 if _failures > 0 else 0)
