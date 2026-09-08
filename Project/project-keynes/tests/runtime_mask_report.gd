extends SceneTree

# Prints the runtime domain coverage baseline required by the migration
# evidence spec: which domains the worker actually implements, which are still
# missing, and where each global completion criterion currently stands.
#
# This is a reporter, not a test. It always exits 0 so it can be archived as a
# baseline snapshot even while every criterion is still unmet.

# Bit layout mirrors runtime_domain_mask() in gdext/src/runtime_pod_protocol.h:
# domain ids start at 1 and occupy bit (id - 1).
const DOMAIN_NAMES := {
	1: "INPUT_CAPTURE",
	2: "CLIMATE",
	3: "COUNTRY",
	4: "TRIGGER_INPUT",
	5: "IDEOLOGY",
	6: "EFFECT",
	7: "MODIFIER",
	8: "GAMEPLAY_EFFECT",
	9: "ECONOMY",
	10: "EVENTS",
	11: "VISUAL",
	12: "COMMIT",
}
const ALL_DOMAIN_MASK := 0xFFF


func _init() -> void:
	_run()
	quit(0)


func _decode_mask(mask: int) -> Array:
	var names: Array = []
	for domain_id in range(1, 13):
		if (mask & (1 << (domain_id - 1))) != 0:
			names.append(DOMAIN_NAMES[domain_id])
	return names


func _run() -> void:
	print("=== runtime domain coverage baseline ===")
	if not ClassDB.class_exists("DCWorldExt"):
		print("DCWorldExt unavailable; GDExtension not loaded")
		return

	var ext := DCWorldExt.new()
	# SHADOW is the only mode that starts without a complete domain mask, and
	# starting is required before the report carries coverage fields.
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "SHADOW",
		"graph_coverage_complete": true,
		"day": 0,
		"speed_days_per_second": 50.0,
		"paused": true,
	})
	print("start_runtime_worker(SHADOW) ok=%s pending=%s code=%s" % [
		str(started.get("ok", false)),
		str(started.get("pending", false)),
		str(started.get("code", "")),
	])
	OS.delay_msec(200)

	var report: Dictionary = ext.get_runtime_thread_report()
	var implemented := int(report.get("implemented_domain_mask", 0))
	var missing := int(report.get("missing_domain_mask", 0))

	print("")
	print("implemented_domain_mask = 0x%03X  %s" % [implemented, str(_decode_mask(implemented))])
	print("missing_domain_mask     = 0x%03X  %s" % [missing, str(_decode_mask(missing))])
	print("required (ALL)          = 0x%03X" % ALL_DOMAIN_MASK)
	print("implemented / 12        = %d" % _decode_mask(implemented).size())

	print("")
	print("--- global completion criteria ---")
	var criteria := [
		["implemented_domain_mask == 0xFFF", implemented == ALL_DOMAIN_MASK,
			"0x%03X" % implemented],
		["graph_coverage_state == complete",
			str(report.get("graph_coverage_state", "")) == "complete",
			str(report.get("graph_coverage_state", ""))],
		["save_codec_complete == true", bool(report.get("save_codec_complete", false)),
			str(report.get("save_codec_complete", false))],
		["shadow_parity_passed == true", bool(report.get("shadow_parity_passed", false)),
			str(report.get("shadow_parity_passed", false))],
		["fatal == false", not bool(report.get("fatal", true)),
			str(report.get("fatal", true))],
		["ledger_failures == 0", int(report.get("ledger_failures", -1)) == 0,
			str(report.get("ledger_failures", "n/a"))],
		["main_wait_on_sim_us == 0", int(report.get("main_wait_on_sim_us", -1)) == 0,
			str(report.get("main_wait_on_sim_us", "n/a"))],
	]
	var met := 0
	for entry in criteria:
		var ok := bool(entry[1])
		if ok:
			met += 1
		print("  [%s] %-38s actual=%s" % ["x" if ok else " ", entry[0], entry[2]])
	print("criteria met: %d/%d" % [met, criteria.size()])

	print("")
	print("--- climate parity counters ---")
	for key in [
		"climate_pod_parity_compared_count",
		"climate_pod_parity_mismatch_count",
		"climate_pod_parity_matched",
		"climate_pod_parity_compared",
		"climate_pod_state_hash",
		"climate_pod_reference_state_hash",
		"climate_pod_fallback_reason",
		"climate_trace_consumable",
		"simulation_committed_day",
		"simulation_worker_blocker",
	]:
		if report.has(key):
			print("  %-38s = %s" % [key, str(report[key])])
		else:
			print("  %-38s = <absent from report>" % key)

	print("")
	print("--- abi ---")
	print("  runtime_domain_abi_version = %s" % str(report.get("runtime_domain_abi_version", "n/a")))
	print("  runtime_domain_pod_abi_version = %s" % str(report.get("runtime_domain_pod_abi_version", "n/a")))

	ext.request_runtime_stop()
	print("=== end ===")
