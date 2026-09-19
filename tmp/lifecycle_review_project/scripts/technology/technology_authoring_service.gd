class_name TechnologyAuthoringService
extends RefCounted

## File-level authority for technology authoring: loading, normalization,
## validation, atomic saves and the cross-file `tech.*` unlock round-trip.
##
## Validation lives in TechnologyNetworkValidator so the workbench and the
## headless gate report identical codes. Saving always normalizes effect
## summaries and rebuilds visual edges first, so a saved file is already in the
## shape the gate expects instead of failing its `--check` pass afterwards.

const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")
const ModelScript = preload("res://scripts/technology/technology_authoring_model.gd")
const IndexScript = preload("res://scripts/technology/technology_authoring_catalog_index.gd")

const NETWORK_PATH := "res://data/technology/technology_network.json"
const BACKUP_PATH := "res://data/technology/technology_network.json.bak"
const VALIDATOR := "res://tools/build_technology_network_authoring.gd"
const REPORT_TOOL := "res://tools/export_technology_tree.gd"

const SAVE_WARNING := "内容改动会改变 technology_catalog_identity_hash，既有 PKCN 存档将以 catalog_hash_mismatch 被拒绝。"

var model: TechnologyAuthoringModel = ModelScript.new()
var index: TechnologyAuthoringCatalogIndex = IndexScript.new()


func load_network() -> Dictionary:
	var file := FileAccess.open(NETWORK_PATH, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "technology_network_missing"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return {"ok": false, "reason": "technology_network_json_invalid"}
	model.load_payload((parsed as Dictionary).duplicate(true))
	return {
		"ok": true,
		"schema_version": int(model.payload().get("schema_version", 0)),
		"nodes": model.node_count(),
		"application_intersections": model.meta_array("application_intersections").size(),
	}


func load_content_index(force_rescan := false) -> Dictionary:
	index.build(force_rescan)
	return {
		"ok": index.stat_registry_reason.is_empty(),
		"reason": index.stat_registry_reason,
		"buildings": index.buildings.size(),
		"goods": index.goods.size(),
		"resources": index.resources.size(),
		"modifier_stats": index.modifier_stat_keys.size(),
		"msec": index.load_msec,
		"signature_msec": index.signature_msec,
		"cached": index.served_from_cache,
	}


# --------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------

## Full in-process validation. Returns {ok, findings, stats, msec}.
func validate() -> Dictionary:
	var payload := model.payload()
	if payload.is_empty():
		return {
			"ok": false,
			"findings": [ValidatorScript.finding("technology_network_not_loaded",
				"尚未载入 technology_network.json。")],
			"stats": {},
			"msec": 0.0,
		}
	var started := Time.get_ticks_usec()
	var result := ValidatorScript.validate(payload)
	var findings: Array = result.findings
	findings.append_array(ValidatorScript.validate_modifier_stats(
		payload, index.modifier_stats))
	result["ok"] = ValidatorScript.error_count(findings) == 0
	result["findings"] = findings
	result["msec"] = float(Time.get_ticks_usec() - started) / 1000.0
	return result


## Groups findings by technology so the graph and table views can badge nodes.
static func group_findings(findings: Array) -> Dictionary:
	var out := {}
	for value in findings:
		var row: Dictionary = value
		var id := String(row.get("node_id", ""))
		if id.is_empty():
			continue
		var bucket: Array = out.get(id, [])
		bucket.append(row)
		out[id] = bucket
	return out


# --------------------------------------------------------------------------
# Saving
# --------------------------------------------------------------------------

## Normalizes, validates and atomically writes the network.
## Errors block the write; warnings do not.
func save() -> Dictionary:
	var payload := model.payload()
	if payload.is_empty():
		return {"ok": false, "reason": "technology_network_not_loaded"}
	ValidatorScript.normalize_effect_summaries(payload)
	payload["visual_edges"] = ValidatorScript.build_visual_edges(payload)
	var validation := validate()
	if not bool(validation.ok):
		return {
			"ok": false,
			"reason": ValidatorScript.first_error_code(validation.findings),
			"findings": validation.findings,
		}
	var write := _write_payload(payload)
	if not bool(write.ok):
		return write
	model.mark_saved()
	return {
		"ok": true,
		"path": NETWORK_PATH,
		"warning": SAVE_WARNING,
		"findings": validation.findings,
	}


## Writes the file even though errors remain, so a long authoring session is
## never lost. The caller must have confirmed this explicitly.
func save_draft() -> Dictionary:
	var payload := model.payload()
	if payload.is_empty():
		return {"ok": false, "reason": "technology_network_not_loaded"}
	ValidatorScript.normalize_effect_summaries(payload)
	payload["visual_edges"] = ValidatorScript.build_visual_edges(payload)
	var write := _write_payload(payload)
	if bool(write.ok):
		model.mark_saved()
	return write


func _write_payload(payload: Dictionary) -> Dictionary:
	var current := FileAccess.get_file_as_string(NETWORK_PATH)
	if not current.is_empty():
		var backup_file := FileAccess.open(BACKUP_PATH, FileAccess.WRITE)
		if backup_file != null:
			backup_file.store_string(current)
			backup_file.close()
	var serialized := ValidatorScript.serialize_network(payload)
	var temp_path := NETWORK_PATH + ".tmp"
	var temp := FileAccess.open(temp_path, FileAccess.WRITE)
	if temp == null:
		return {"ok": false, "reason": "technology_authoring_write_failed"}
	temp.store_string(serialized)
	temp.close()
	var renamed := DirAccess.rename_absolute(ProjectSettings.globalize_path(temp_path),
		ProjectSettings.globalize_path(NETWORK_PATH))
	if renamed != OK:
		# Some filesystems refuse to replace an existing target. The backup is
		# already on disk at this point, so a direct rewrite stays recoverable.
		var direct := FileAccess.open(NETWORK_PATH, FileAccess.WRITE)
		if direct == null:
			return {"ok": false, "reason": "technology_authoring_replace_failed"}
		direct.store_string(serialized)
		direct.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
	return {"ok": true, "path": NETWORK_PATH, "bytes": serialized.length()}


# --------------------------------------------------------------------------
# External gates
# --------------------------------------------------------------------------

func run_gate(check_only := true) -> Dictionary:
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
		"--script", REPORT_TOOL], output, true)
	return {"ok": code == 0, "code": code, "output": "\n".join(output)}


# --------------------------------------------------------------------------
# Cross-file `tech.*` unlock round-trip
# --------------------------------------------------------------------------

## Compares the node's authored unlock effects against the actual `.tres`
## technology tags. Returns {matched, missing_in_tres, missing_in_node}.
func reconcile_unlocks(technology_id: String) -> Dictionary:
	var row := model.node(technology_id)
	var authored := {}
	for effect_value in row.get("content_effects", []):
		var effect: Dictionary = effect_value
		if String(effect.get("operation", "")) != "unlock":
			continue
		var kind := String(effect.get("kind", ""))
		var id := String(effect.get("id", ""))
		if kind.is_empty() or id.is_empty():
			continue
		authored["%s|%s" % [kind, id]] = {"kind": kind, "id": id}
	var actual := {}
	for entry_value in index.unlocks_for(technology_id):
		var entry: Dictionary = entry_value
		if String(entry.get("field", "")) == "required_technology_tags":
			continue
		actual["%s|%s" % [String(entry.kind), String(entry.id)]] = entry
	var matched: Array[Dictionary] = []
	var missing_in_tres: Array[Dictionary] = []
	var missing_in_node: Array[Dictionary] = []
	for key in authored:
		if actual.has(key):
			matched.append(authored[key])
		else:
			missing_in_tres.append(authored[key])
	for key in actual:
		if not authored.has(key):
			missing_in_node.append(actual[key])
	return {
		"matched": matched,
		"missing_in_tres": missing_in_tres,
		"missing_in_node": missing_in_node,
	}


## Points a building's single primary `tech.*` unlock at `technology_id`.
## EconomyCatalog requires exactly one such tag, so the previous one is
## replaced rather than appended.
func set_building_primary_technology(building_id: String,
		technology_id: String) -> Dictionary:
	var row: Dictionary = index.buildings.get(building_id, {})
	if row.is_empty():
		return {"ok": false, "reason": "building_unknown:%s" % building_id}
	var profile := ResourceLoader.load(String(row.path), "Resource")
	if profile == null:
		return {"ok": false, "reason": "building_profile_load_failed:%s" % building_id}
	var tags := PackedStringArray()
	var replaced := ""
	for tag in profile.technology_tags:
		var text := String(tag)
		if text.begins_with("tech."):
			replaced = text
			continue
		tags.append(text)
	tags.append(technology_id)
	profile.technology_tags = tags
	var saved := ResourceSaver.save(profile, String(row.path))
	if saved != OK:
		return {"ok": false, "reason": "building_profile_save_failed:%s" % building_id}
	row["tags"] = tags
	index.refresh_unlock_map()
	return {"ok": true, "replaced": replaced, "path": String(row.path)}


## Adds or removes a `tech.*` tag on a good or resource, keeping the "at least
## one technology binding" rule the economy catalog enforces.
func set_content_technology(kind: String, content_id: String,
		technology_id: String, present: bool) -> Dictionary:
	if kind == "building":
		if not present:
			return {"ok": false,
				"reason": "building_requires_replacement_technology:%s" % content_id}
		return set_building_primary_technology(content_id, technology_id)
	var row: Dictionary = index.entries(kind).get(content_id, {})
	if row.is_empty():
		return {"ok": false, "reason": "%s_unknown:%s" % [kind, content_id]}
	var field := String(row.get("tag_field", ""))
	var profile := ResourceLoader.load(String(row.path), "Resource")
	if profile == null:
		return {"ok": false, "reason": "%s_profile_load_failed:%s" % [kind, content_id]}
	var tags := PackedStringArray()
	var technology_tag_count := 0
	for tag in profile.get(field):
		var text := String(tag)
		if text == technology_id and not present:
			continue
		if text.begins_with("tech."):
			technology_tag_count += 1
		tags.append(text)
	if present and not tags.has(technology_id):
		tags.append(technology_id)
		technology_tag_count += 1
	if technology_tag_count <= 0:
		return {"ok": false,
			"reason": "%s_requires_one_technology_tag:%s" % [kind, content_id]}
	profile.set(field, tags)
	var saved := ResourceSaver.save(profile, String(row.path))
	if saved != OK:
		return {"ok": false, "reason": "%s_profile_save_failed:%s" % [kind, content_id]}
	row["tags"] = tags
	index.refresh_unlock_map()
	return {"ok": true, "path": String(row.path)}


## Blocking check used before deleting a technology: a building whose only
## primary `tech.*` tag is this technology would become unbuildable.
func deletion_blockers(technology_id: String) -> Array[Dictionary]:
	var blockers: Array[Dictionary] = []
	for entry_value in index.unlocks_for(technology_id):
		var entry: Dictionary = entry_value
		if String(entry.kind) != "building" or String(entry.field) != "technology_tags":
			continue
		var row: Dictionary = index.buildings.get(String(entry.id), {})
		var remaining := 0
		for tag in row.get("tags", PackedStringArray()):
			var text := String(tag)
			if text.begins_with("tech.") and text != technology_id:
				remaining += 1
		if remaining == 0:
			blockers.append({
				"kind": "building",
				"id": String(entry.id),
				"display_name": String(entry.display_name),
				"message": "建筑 %s（%s）以该科技为唯一解锁，删除前需指定替代科技。" % [
					String(entry.display_name), String(entry.id)],
			})
	return blockers
