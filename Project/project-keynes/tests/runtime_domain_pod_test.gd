extends SceneTree

var _checks := 0
var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
	else:
		var ext := DCWorldExt.new()
		_expect("POD domain self-test exported", ext.has_method("runtime_domain_pod_self_test"))
		if ext.has_method("runtime_domain_pod_self_test"):
			_expect("POD domain pipeline contract", bool(ext.runtime_domain_pod_self_test()))
		_expect("authoritative POD stores self-test exported", ext.has_method("runtime_authoritative_domains_self_test"))
		if ext.has_method("runtime_authoritative_domains_self_test"):
			_expect("authoritative POD stores contract", bool(ext.runtime_authoritative_domains_self_test()))
		var started: Dictionary = ext.start_runtime_worker({
			"simulation_thread_mode": "SHADOW",
			"graph_coverage_complete": false,
			"day": 0,
			"speed_days_per_second": 0.0,
			"paused": true,
		}) if ext.has_method("start_runtime_worker") else {}
		_expect("POD diagnostic host starts", bool(started.get("ok", false)))
		var report: Dictionary = ext.get_runtime_thread_report() if ext.has_method("get_runtime_thread_report") else {}
		_expect("POD diagnostics are present", report.has("pod_completed_domain_mask") \
			and report.has("pod_work_units") and report.has("pod_fallback_count") \
			and report.has("climate_pod_plan_ms") and report.has("climate_pod_state_hash"))
		_expect("POD ABI version is exposed", int(report.get("pod_domain_abi_version", 0)) == 3)
		var inputs: Dictionary = ext.capture_runtime_inputs({
			"generation": 1,
			"day": 0,
			"terrain": PackedByteArray([1, 1]),
			"neighbor_offsets": PackedInt32Array([0, 1, 2]),
			"neighbor_indices": PackedInt32Array([1, 0]),
			"cell_temp": PackedFloat32Array([15.0, -5.0]),
			"cell_moisture": PackedFloat32Array([0.5, 0.25]),
			"cell_plant_available_water": PackedFloat32Array([0.8, 0.2]),
		}) if ext.has_method("capture_runtime_inputs") else {}
		_expect("CSR environment capture is accepted", bool(inputs.get("ok", false)))
		# A captured frame is deliberately not consumable until the synchronous
		# OFF reference publishes its hash.  The SHADOW worker must wait at this
		# barrier and must not advance the committed day or claim readiness.
		ext.set_runtime_clock(false, 10.0)
		var climate_deadline := Time.get_ticks_msec() + 300
		report = ext.get_runtime_thread_report()
		while Time.get_ticks_msec() < climate_deadline:
			OS.delay_msec(5)
			report = ext.get_runtime_thread_report()
		var climate_diagnostics_ok := not bool(report.get("climate_pod_ready", false)) \
			and int(report.get("climate_trace_depth", 0)) >= 1 \
			and int(report.get("climate_trace_consumable", 0)) == 0 \
			and str(report.get("climate_pod_fallback_reason", "")) in [
				"climate_trace_reference_pending", "climate_trace_missing"] \
			and int(report.get("simulation_committed_day", 0)) == 0 \
			and not bool(report.get("simulation_worker_ready", true))
		ext.set_runtime_clock(true, 10.0)
		if not climate_diagnostics_ok:
			print("[runtime-domain-pod] climate barrier report: %s" % report)
		_expect("Climate SHADOW waits for OFF reference barrier",
			climate_diagnostics_ok)
		var non_finite: Dictionary = ext.capture_runtime_inputs({
			"generation": 2,
			"day": 1,
			"terrain": PackedByteArray([1]),
			"cell_temp": PackedFloat32Array([NAN]),
		})
		_expect("non-finite environment input is rejected before publication",
			str(non_finite.get("code", "")) == "invalid_runtime_input_type_or_value")
		var bad_csr: Dictionary = ext.capture_runtime_inputs({
			"generation": 2,
			"day": 1,
			"terrain": PackedByteArray([1, 1]),
			"neighbor_offsets": PackedInt32Array([0, 2, 1]),
			"neighbor_indices": PackedInt32Array([1]),
			})
		_expect("invalid CSR input is rejected", str(bad_csr.get("code", "")) == "runtime_input_csr_invalid")
		if ext.has_method("request_runtime_stop"):
			ext.request_runtime_stop()
	print("=== runtime domain POD: %d checks, %d failures ===" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
