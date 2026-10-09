extends SceneTree

# Deterministic schema-v4 normalizer and validator. The network JSON is the
# sole authoring source: this tool never invents prerequisites, branches,
# milestone candidates, application links, or Modifier effects.
#
# All schema rules live in TechnologyNetworkValidator so this gate and the
# in-editor authoring workbench report identical diagnostic codes.

const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")

const NETWORK_PATH := "res://data/technology/technology_network.json"
const REPORT_PATH := "res://tools/technology_tree/technology_network_v4_audit.md"


func _init() -> void:
	var payload := _read_payload()
	if payload.is_empty():
		quit(1)
		return
	var check_only := OS.get_cmdline_user_args().has("--check")
	var summaries_changed := ValidatorScript.normalize_effect_summaries(payload)
	if check_only and summaries_changed:
		push_error("technology_effect_summaries_not_normalized")
		quit(1)
		return
	var validation := ValidatorScript.validate(payload)
	if not bool(validation.get("ok", false)):
		var findings: Array = validation.get("findings", [])
		push_error(ValidatorScript.first_error_code(findings))
		for value in findings:
			var row: Dictionary = value
			if String(row.get("severity", "error")) != "error":
				continue
			print("  [%s] %s" % [String(row.get("code", "")), String(row.get("message", ""))])
		quit(1)
		return
	var stats: Dictionary = validation.get("stats", {})
	var rebuilt_edges := ValidatorScript.build_visual_edges(payload)
	var authored_edges: Array = payload.get("visual_edges", [])
	if check_only and JSON.stringify(authored_edges) != JSON.stringify(rebuilt_edges):
		push_error("technology_visual_edges_not_normalized")
		quit(1)
		return
	payload["visual_edges"] = rebuilt_edges
	var report := ValidatorScript.audit_report(payload, stats)
	if not check_only:
		_write_json(payload)
		_write_text(REPORT_PATH, report)
	print("[PASS] technology schema v4: %d research nodes / %d application intersections / %d hard / %d research-route / %d milestone candidates" % [
		(payload.nodes as Array).size(), (payload.get("application_intersections", []) as Array).size(), int(stats.hard_edges),
		int(stats.alternative_edges), int(stats.milestone_candidate_edges)])
	quit(0)


func _read_payload() -> Dictionary:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	if file == null:
		push_error("technology_network_missing")
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		push_error("technology_network_json_invalid")
		return {}
	return parsed as Dictionary


func _write_json(payload: Dictionary) -> void:
	_write_text(NETWORK_PATH, ValidatorScript.serialize_network(payload))


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("technology_authoring_write_failed:%s" % path)
		return
	file.store_string(content)
	file.close()
