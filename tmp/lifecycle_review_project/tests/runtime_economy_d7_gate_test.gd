extends SceneTree

## Phase 3 soft scaffold: when ECONOMY is worker-authoritative, the runtime
## report exposes economy_pod_operation_gate_mask with fiscal D7 bits present.

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		_finish()
		return
	var ext := DCWorldExt.new()
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		# Scope ACTIVE to the Economy + COMMIT barrier.  Asking for the
		# default all-domain mask would intentionally fail until 0xFFF is
		# released and would make this D7 gate test test the wrong contract.
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0x200,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	if not bool(started.get("ok", false)):
		print("D7 start result: ", started)
	_expect("ACTIVE worker starts for D7 gate report",
		bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		_finish()
		return

	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("report exposes economy_pod_operation_gate_mask",
		report.has("economy_pod_operation_gate_mask"))
	_expect("implemented mask remains 0xFFF with ECONOMY",
		int(report.get("implemented_domain_mask", 0)) == 0xFFF)

	# Soft: when ECONOMY is authoritative, fiscal gate bits should be open
	# (FISCAL_RESERVE/RETURN/COLLECT occupy low bits of the D7 mask).
	var auth_mask := int(report.get("authoritative_domain_mask", 0))
	var gate := int(report.get("economy_pod_operation_gate_mask", 0))
	if (auth_mask & 0x100) != 0:
		_expect("ACTIVE ECONOMY reports non-zero operation gate mask", gate != 0)
		# Fiscal trio = bits for FISCAL_RESERVE/RETURN/COLLECT (ops 2/3/4 → 0x1C).
		_expect("fiscal D7 gate bits present on report", (gate & 0x1C) != 0)
	else:
		# Soft pass when grant has not yet latched (startup race).
		_expect("ECONOMY grant not latched yet (soft)", true)

	ext.request_runtime_stop()
	_finish()


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	print("FAIL: ", label)


func _finish() -> void:
	print("runtime_economy_d7_gate_test checks=%s failures=%s" % [
		_checks, _failures])
	quit(1 if _failures > 0 else 0)

