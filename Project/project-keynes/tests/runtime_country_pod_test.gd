extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
var failures := 0
var checks := 0

func _init() -> void:
	_run()
	print("runtime country POD: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var ext := DCWorldExt.new()
	_expect("worker country authority self-test", ext.has_method("runtime_country_pod_authority_self_test")
		and bool(ext.runtime_country_pod_authority_self_test()))
	_expect("snapshot facade exported", ext.has_method("capture_country_runtime_snapshot"))
	_expect("country catalog capture facade exported", ext.has_method("capture_country_pod_catalog"))
	var missing: Dictionary = ext.capture_country_runtime_snapshot()
	_expect("unconfigured capture reports explicit error", not bool(missing.get("ok", true))
		and str(missing.get("code", "")) == "country_runtime_unavailable")
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	_expect("country configures", bool(ext.configure_country(catalog, profile, 2, 17).get("ok", false)))
	_expect("country bootstraps", bool(ext.bootstrap_country({}, PackedByteArray([0, 0])).get("ok", false)))
	var captured: Dictionary = ext.capture_country_runtime_snapshot()
	_expect("bootstrapped snapshot accepted", bool(captured.get("ok", false)))
	_expect("snapshot exposes bounded metadata", int(captured.get("country_count", 0)) > 0
		and int(captured.get("cell_count", 0)) == 2
		and int(captured.get("generation", 0)) > 0)
	var pod_catalog: Dictionary = ext.capture_country_pod_catalog()
	_expect("numeric country catalog capture is explicit", bool(pod_catalog.get("ok", false))
		and int(pod_catalog.get("catalog_hash", 0)) != 0
		and bool(pod_catalog.get("research_conditions_complete", false)))
	var shadow: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 5.0,
		"paused": false,
	})
	_expect("shadow worker starts", bool(shadow.get("ok", false)))
	OS.delay_msec(40)
	var report: Dictionary = ext.get_runtime_thread_report()
	_expect("country probe diagnostics are exported", report.has("country_pod_snapshot_generation")
		and report.has("country_pod_blocker"))
	_expect("active research index diagnostics are exported",
		report.has("country_pod_active_index_count")
		and int(report.get("country_pod_active_index_count", -1)) >= 0)
	_expect("active authority remains blocked", not bool(report.get("simulation_worker_ready", true))
		and int(report.get("missing_domain_mask", 0)) != 0)
	ext.request_runtime_stop()
	OS.delay_msec(30)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		_fail(label)

func _fail(label: String) -> void:
	failures += 1
	push_error("[FAIL] " + label)
