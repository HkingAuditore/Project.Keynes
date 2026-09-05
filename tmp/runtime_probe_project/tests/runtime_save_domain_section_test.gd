extends SceneTree

var _checks := 0
var _failures := 0

func _init() -> void:
	var ext := DCWorldExt.new()
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("shadow host starts", bool(started.get("ok", false)))
	_expect("save request is accepted", bool(ext.request_runtime_save(9001).get("pending", false)))
	OS.delay_msec(30)
	var saved: Dictionary = ext.poll_runtime_save(9001)
	_expect("domain section save is ready", bool(saved.get("ready", false)))
	_expect("domain section bit is present", (int(saved.get("section_mask", 0)) & 2) != 0)
	_expect("domain section has bytes", int(saved.get("domain_pod_bytes", 0)) > 0)
	var bytes: PackedByteArray = saved.get("bytes", PackedByteArray())
	ext.request_runtime_stop()
	OS.delay_msec(30)
	var restored: Dictionary = ext.restore_runtime_bundle(bytes)
	_expect("domain section restores", bool(restored.get("restored", false)))
	var restarted: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": false,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": true,
	})
	_expect("restored host restarts", bool(restarted.get("ok", false)))
	_expect("restored host keeps state", int(ext.get_runtime_thread_report().get("simulation_committed_day", -1)) == int(saved.get("committed_day", -2)))
	ext.request_runtime_stop()
	print("=== runtime save domain section: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[FAIL] %s" % label)

