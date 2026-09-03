class_name TechnologyAuthoringService
extends RefCounted

const NETWORK_PATH := "res://data/technology/technology_network.json"
const BACKUP_PATH := "res://data/technology/technology_network.json.bak"
const VALIDATOR := "res://tools/build_technology_network_authoring.gd"
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")

var payload: Dictionary = {}
var dirty := false

func load_network() -> Dictionary:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "technology_network_missing"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return {"ok": false, "reason": "technology_network_json_invalid"}
	payload = (parsed as Dictionary).duplicate(true)
	dirty = false
	return {"ok": true, "schema_version": int(payload.get("schema_version", 0)),
		"nodes": (payload.get("nodes", []) as Array).size(),
		"application_intersections": application_intersections().size()}

func nodes() -> Array:
	return payload.get("nodes", []) as Array

func node_by_id(id: String) -> Dictionary:
	for row_value in nodes():
		var row: Dictionary = row_value
		if String(row.get("id", "")) == id:
			return row
	return {}

func update_node(id: String, changes: Dictionary) -> bool:
	var row := node_by_id(id)
	if row.is_empty():
		return false
	for key in changes:
		if key == "id":
			continue
		row[key] = changes[key]
	dirty = true
	return true

func application_intersections() -> Array:
	return payload.get("application_intersections", []) as Array

func application_intersection_by_id(id: String) -> Dictionary:
	for row_value in application_intersections():
		var row: Dictionary = row_value
		if String(row.get("id", "")) == id:
			return row
	return {}

func update_application_intersection(id: String, changes: Dictionary) -> bool:
	var row := application_intersection_by_id(id)
	if row.is_empty():
		return false
	for key in changes:
		if key == "id":
			continue
		row[key] = changes[key]
	dirty = true
	return true

func set_relation(id: String, field: String, values: Array, rationale_field := "") -> bool:
	var row := node_by_id(id)
	if row.is_empty():
		return false
	row[field] = values.duplicate()
	if not rationale_field.is_empty():
		var rationales: Array = []
		for _value in values:
			rationales.append("")
		row[rationale_field] = rationales
	dirty = true
	return true

func validate() -> Dictionary:
	if payload.is_empty():
		return {"ok": false, "reason": "technology_network_not_loaded"}
	var schema_version := int(payload.get("schema_version", 0))
	if schema_version not in [3, 4]:
		return {"ok": false, "reason": "technology_network_schema_version_invalid"}
	var ids := {}
	for row_value in nodes():
		var row: Dictionary = row_value
		var id := String(row.get("id", ""))
		if not id.begins_with("tech.") or ids.has(id):
			return {"ok": false, "reason": "technology_id_invalid_or_duplicate:%s" % id}
		ids[id] = true
	for row_value in nodes():
		var row: Dictionary = row_value
		for key in ["hard_prerequisite_ids", "branch_successor_ids", "application_target_ids"]:
			for ref in row.get(key, []):
				if not ids.has(String(ref)):
					return {"ok": false, "reason": "technology_reference_unknown:%s:%s" % [row.id, ref]}
	var application_check := TechnologyCatalogScript.validate_application_intersections(payload, nodes())
	if not bool(application_check.get("ok", false)):
		return application_check
	return {"ok": true, "schema_version": schema_version, "nodes": nodes().size(),
		"application_intersections": application_intersections().size()}

func save() -> Dictionary:
	var check := validate()
	if not bool(check.get("ok", false)):
		return check
	var current := FileAccess.get_file_as_string(NETWORK_PATH)
	if not current.is_empty():
		var backup_file := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
		if backup_file != null:
			backup_file.store_string(current)
			backup_file.close()
	var temp_path := NETWORK_PATH + ".tmp"
	var temp := FileAccess.open(temp_path, FileAccess.WRITE)
	if temp == null:
		return {"ok": false, "reason": "technology_authoring_write_failed"}
	temp.store_string(JSON.stringify(payload, "\t", false, true) + "\n")
	temp.close()
	if not DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path),
			ProjectSettings.globalize_path(NETWORK_PATH)) == OK:
		return {"ok": false, "reason": "technology_authoring_replace_failed"}
	dirty = false
	return {"ok": true, "path": NETWORK_PATH}

func run_validator(check_only := true) -> Dictionary:
	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var output: Array = []
	var args := ["--headless", "--path", project, "--script", VALIDATOR]
	if check_only:
		args.append_array(["--", "--check"])
	var code := OS.execute(godot, args, output, true)
	return {"ok": code == 0, "code": code, "output": "\n".join(output)}

func export_report() -> Dictionary:
	var godot := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var output: Array = []
	var code := OS.execute(godot, ["--headless", "--path", project,
		"--script", "res://tools/export_technology_tree.gd"], output, true)
	return {"ok": code == 0, "code": code, "output": "\n".join(output)}
