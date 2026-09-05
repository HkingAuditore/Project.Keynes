extends SceneTree

var _checks := 0
var _failures := 0

func _init() -> void:
	print("=== runtime protocol guard ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
	else:
		var ext := DCWorldExt.new()
		_expect("protocol guard binding is exported",
			ext.has_method("runtime_protocol_guard_self_test"))
		if ext.has_method("runtime_protocol_guard_self_test"):
			_expect("ABI v3, stage layout, queue and ACTIVE gate contract",
				bool(ext.runtime_protocol_guard_self_test()))
		_expect("domain POD ABI remains v3",
			ext.has_method("runtime_domain_pod_self_test"))
		if ext.has_method("runtime_domain_pod_self_test"):
			_expect("legacy POD contract still passes",
				bool(ext.runtime_domain_pod_self_test()))
		var start := ext.start_runtime_worker({
			"simulation_thread_mode": "SHADOW",
			"graph_coverage_complete": false,
			"day": 0,
			"speed_days_per_second": 0.0,
			"paused": true,
		})
		_expect("shadow worker starts for report-level gate checks",
			bool(start.get("ok", false)))
		var report: Dictionary = ext.get_runtime_thread_report()
		_expect("report exposes ABI v3 and all required domain mask",
			int(report.get("pod_domain_abi_version", 0)) == 3 \
			and int(report.get("required_domain_mask", 0)) == 0xFFF)
		_expect("COMMIT-only mask blocks authority",
			int(report.get("implemented_domain_mask", 0)) == 0x800 \
			and int(report.get("missing_domain_mask", 0)) == 0x7FF \
			and not bool(report.get("authority_ready", true)))
		_expect("main thread wait metric is zero",
			int(report.get("main_wait_on_sim_us", -1)) == 0)
		ext.request_runtime_stop()
		OS.delay_msec(20)
	print("=== runtime protocol guard: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
