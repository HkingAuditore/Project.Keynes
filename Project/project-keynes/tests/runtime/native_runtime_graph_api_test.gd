extends SceneTree

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[runtime-graph-api] SKIP DCWorldExt unavailable")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var required := [
		"configure_runtime_graph", "advance_runtime_pulse",
		"flush_runtime_visuals", "set_runtime_qos", "get_runtime_thread_report",
		"get_runtime_perf_snapshot",
		"sync_country_territory_to_map",
		"economy_deadline_critical",
	]
	for method_name in required:
		if not ext.has_method(method_name):
			push_error("[runtime-graph-api] missing %s" % method_name)
			quit(1)
			return
	if int(ext.configure_runtime_graph({"enabled": false})) != 0:
		push_error("[runtime-graph-api] configure failed")
		quit(1)
		return
	var token := int(ext.advance_runtime_pulse(0, 0.0, 1.0, 1000, 0))
	if int((token >> 56) & 0xff) != 0:
		push_error("[runtime-graph-api] disabled pulse status mismatch")
		quit(1)
		return
	var snapshot: Dictionary = ext.get_runtime_perf_snapshot(1)
	if not snapshot.has("pulse_count") or not snapshot.has("abi_calls"):
		push_error("[runtime-graph-api] snapshot fields missing")
		quit(1)
		return
	ext.set_runtime_qos(true)
	var thread_report: Dictionary = ext.get_runtime_thread_report()
	if String(thread_report.get("executor_backend", "")) != "native_fixed_pool" \
			or bool(thread_report.get("simulation_worker_ready", true)) \
			or not bool(thread_report.get("interactive", false)):
		push_error("[runtime-graph-api] unsafe worker gate mismatch")
		quit(1)
		return
	ext.set_runtime_qos(false)
	print("[runtime-graph-api] PASS")
	quit(0)
