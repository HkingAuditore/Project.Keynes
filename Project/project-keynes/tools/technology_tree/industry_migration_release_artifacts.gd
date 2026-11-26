extends RefCounted

## Capture the legacy inventory and write the release manifests for the migration.

const MigrationFiles = preload("res://tools/technology_tree/industry_migration_files.gd")

const MIGRATION_MANIFEST_PATH := \
	"res://tools/technology_tree/technology_industry_v2_migration_manifest.json"
const STABLE_ID_MANIFEST_PATH := \
	"res://tools/technology_tree/technology_industry_v2_stable_id_manifest.json"
const LEGACY_NETWORK_GIT_PATH := \
	"Project/project-keynes/data/technology/technology_network.json"
const LEGACY_DIRECTORY_GIT_PATHS := {
	"buildings": "Project/project-keynes/data/economy/buildings",
	"goods": "Project/project-keynes/data/goods",
	"resources": "Project/project-keynes/data/resources",
}
const RETIRED_APPLICATION_TARGETS := {
	"tech.application.wild_tuber_patch": ["tech.wild_tuber_collection"],
	"tech.application.glassware_factory_steam": ["app.glassware_factory_electrical"],
	"tech.application.metal_housewares_factory_steam": ["app.metal_housewares_factory_electrical"],
	"tech.application.leather_goods_factory_steam": ["app.leather_goods_factory_electrical"],
}


static func _write_release_artifacts(payload: Dictionary) -> bool:
	var legacy := _load_legacy_inventory()
	if legacy.is_empty():
		return MigrationFiles._fail_bool("cannot load technology-industry v1 inventory")
	var migration := _build_migration_manifest(payload, legacy)
	if migration.is_empty():
		return false
	MigrationFiles._write_json(MIGRATION_MANIFEST_PATH, migration)
	var stable_manifest := _build_stable_id_manifest(payload)
	if stable_manifest.is_empty():
		return false
	MigrationFiles._write_json(STABLE_ID_MANIFEST_PATH, stable_manifest)
	return true


static func _load_legacy_inventory() -> Dictionary:
	if FileAccess.file_exists(MIGRATION_MANIFEST_PATH):
		var existing := MigrationFiles._read_json(MIGRATION_MANIFEST_PATH)
		var stored: Variant = existing.get("legacy_inventory", {})
		if stored is Dictionary and not (stored as Dictionary).is_empty():
			return (stored as Dictionary).duplicate(true)
	var archive_path := ProjectSettings.globalize_path(
		"user://technology_industry_v1_inventory.zip")
	var root_output := []
	var root_exit_code := OS.execute(
		"git", PackedStringArray(["rev-parse", "--show-toplevel"]), root_output, true)
	if root_exit_code != 0:
		MigrationFiles._fail("cannot resolve git repository root (%d): %s" % [
			root_exit_code, "".join(root_output)])
		return {}
	var repository_root := "".join(root_output).strip_edges()
	if repository_root.is_empty():
		MigrationFiles._fail("git repository root is empty")
		return {}
	var archive_arguments := PackedStringArray([
		"-C", repository_root, "archive", "--format=zip",
		"--output=%s" % archive_path, "HEAD", LEGACY_NETWORK_GIT_PATH,
	])
	for git_path in LEGACY_DIRECTORY_GIT_PATHS.values():
		archive_arguments.append(String(git_path))
	var output := []
	var exit_code := OS.execute("git", archive_arguments, output, true)
	if exit_code != 0:
		MigrationFiles._fail("git archive failed (%d): %s" % [exit_code, "".join(output)])
		return {}
	var archive := ZIPReader.new()
	if archive.open(archive_path) != OK:
		MigrationFiles._fail("cannot open legacy inventory archive: %s" % archive_path)
		return {}
	var parsed: Variant = JSON.parse_string(
		archive.read_file(LEGACY_NETWORK_GIT_PATH).get_string_from_utf8())
	if not parsed is Dictionary or int((parsed as Dictionary).get("schema_version", 0)) != 3:
		MigrationFiles._fail("legacy archive has no schema-v3 network: %s" % LEGACY_NETWORK_GIT_PATH)
		archive.close()
		DirAccess.remove_absolute(archive_path)
		return {}
	var inventory := {
		"source_schema_version": 3,
		"nodes": [],
		"buildings": [],
		"goods": [],
		"resources": [],
	}
	for value in (parsed as Dictionary).get("nodes", []):
		var node: Dictionary = value
		inventory.nodes.append({
			"id": String(node.get("id", "")),
			"display_name": String(node.get("display_name", "")),
			"anchor_kind": String(node.get("anchor_kind", "")),
		})
	for kind in LEGACY_DIRECTORY_GIT_PATHS:
		var prefix := "%s/" % String(LEGACY_DIRECTORY_GIT_PATHS[kind])
		for file_path in archive.get_files():
			if file_path.begins_with(prefix) and file_path.ends_with(".tres"):
				inventory[kind].append(file_path.get_file().trim_suffix(".tres"))
		inventory[kind].sort()
	archive.close()
	DirAccess.remove_absolute(archive_path)
	return inventory


static func _build_migration_manifest(payload: Dictionary, legacy: Dictionary) -> Dictionary:
	var technology_ids := _ids_from_dictionaries(payload.get("nodes", []))
	var application_ids := _ids_from_dictionaries(payload.get("application_intersections", []))
	var current_ids := {
		"buildings": _resource_ids(MigrationFiles.BUILDING_DIR),
		"goods": _resource_ids(MigrationFiles.GOOD_DIR),
		"resources": _resource_ids(MigrationFiles.RESOURCE_DIR),
	}
	var technology_set := _id_set(technology_ids)
	var application_set := _id_set(application_ids)
	var classifications := {
		"nodes": [], "buildings": [], "goods": [], "resources": [],
	}
	var seen_nodes := {}
	for value in legacy.get("nodes", []):
		var old: Dictionary = value
		var id := String(old.get("id", ""))
		if id.is_empty() or seen_nodes.has(id):
			MigrationFiles._fail("duplicate or empty legacy technology id: %s" % id)
			return {}
		seen_nodes[id] = true
		var classification := ""
		var targets := []
		if technology_set.has(id):
			classification = "retained_technology"
			targets = [id]
		elif MigrationFiles.SUBSTANTIVE_RENAMES.has(id):
			classification = "renamed_substantive_technology"
			targets = [String(MigrationFiles.SUBSTANTIVE_RENAMES[id])]
		elif RETIRED_APPLICATION_TARGETS.has(id):
			targets = (RETIRED_APPLICATION_TARGETS[id] as Array).duplicate()
			classification = ("direct_technology_rebind" if id == \
				"tech.application.wild_tuber_patch" else "merged_duplicate_application")
		else:
			var application_id := "app.%s" % id.trim_prefix("tech.application.")
			if String(old.get("anchor_kind", "")) == "application" \
					and application_set.has(application_id):
				classification = "automatic_application"
				targets = [application_id]
		if classification.is_empty():
			MigrationFiles._fail("unclassified legacy technology: %s" % id)
			return {}
		classifications.nodes.append({
			"id": id,
			"display_name": String(old.get("display_name", "")),
			"classification": classification,
			"target_ids": targets,
		})
	for kind in ["buildings", "goods", "resources"]:
		var current_set := _id_set(current_ids[kind])
		var seen := {}
		for id_value in legacy.get(kind, []):
			var id := String(id_value)
			if id.is_empty() or seen.has(id):
				MigrationFiles._fail("duplicate or empty legacy %s id: %s" % [kind, id])
				return {}
			seen[id] = true
			classifications[kind].append({
				"id": id,
				"classification": "retained" if current_set.has(id) else "retired",
				"target_ids": [id] if current_set.has(id) else [],
			})
	var added := {
		"technologies": _added_ids(technology_ids, _legacy_node_ids(legacy)),
		"applications": _added_application_ids(application_ids, legacy),
		"buildings": _added_ids(current_ids.buildings, legacy.get("buildings", [])),
		"goods": _added_ids(current_ids.goods, legacy.get("goods", [])),
		"resources": _added_ids(current_ids.resources, legacy.get("resources", [])),
	}
	return {
		"schema_version": 1,
		"technology_industry_revision": 2,
		"source_schema_version": int(legacy.get("source_schema_version", 3)),
		"target_schema_version": int(payload.get("schema_version", 0)),
		"legacy_inventory": legacy,
		"classifications": classifications,
		"added_ids": added,
		"legacy_counts": {
			"nodes": (legacy.get("nodes", []) as Array).size(),
			"buildings": (legacy.get("buildings", []) as Array).size(),
			"goods": (legacy.get("goods", []) as Array).size(),
			"resources": (legacy.get("resources", []) as Array).size(),
		},
		"classification_policy": \
			"Every legacy ID appears exactly once; added v2 IDs are listed separately.",
	}


static func _build_stable_id_manifest(payload: Dictionary) -> Dictionary:
	var technology_ids := _ids_from_dictionaries(payload.get("nodes", []))
	var application_ids := _ids_from_dictionaries(payload.get("application_intersections", []))
	var building_paths := MigrationFiles._resource_paths(MigrationFiles.BUILDING_DIR)
	var good_paths := MigrationFiles._resource_paths(MigrationFiles.GOOD_DIR)
	var resource_paths := MigrationFiles._resource_paths(MigrationFiles.RESOURCE_DIR)
	var building_ids := _resource_ids(MigrationFiles.BUILDING_DIR)
	var good_ids := _resource_ids(MigrationFiles.GOOD_DIR)
	var resource_ids := _resource_ids(MigrationFiles.RESOURCE_DIR)
	var hashes := {
		"technology_sha256": _sha256_files(PackedStringArray([MigrationFiles.NETWORK_PATH])),
		"buildings_sha256": _sha256_files(building_paths),
		"goods_sha256": _sha256_files(good_paths),
		"resources_sha256": _sha256_files(resource_paths),
	}
	for key in hashes:
		if String(hashes[key]).is_empty():
			return {}
	var combined_source := "technology:%s\nbuildings:%s\ngoods:%s\nresources:%s\n" % [
		hashes.technology_sha256, hashes.buildings_sha256,
		hashes.goods_sha256, hashes.resources_sha256]
	hashes["combined_sha256"] = _sha256_bytes(combined_source.to_utf8_buffer())
	return {
		"schema_version": 1,
		"technology_industry_revision": 2,
		"technology_network_schema_version": int(payload.get("schema_version", 0)),
		"technology_ids": technology_ids,
		"application_ids": application_ids,
		"building_ids": building_ids,
		"good_ids": good_ids,
		"resource_ids": resource_ids,
		"counts": {
			"technologies": technology_ids.size(),
			"applications": application_ids.size(),
			"buildings": building_ids.size(),
			"goods": good_ids.size(),
			"resources": resource_ids.size(),
		},
		"id_sha256": {
			"technologies": _sha256_id_list(technology_ids),
			"applications": _sha256_id_list(application_ids),
			"buildings": _sha256_id_list(building_ids),
			"goods": _sha256_id_list(good_ids),
			"resources": _sha256_id_list(resource_ids),
		},
		"content_sha256": hashes,
	}


static func _resource_ids(directory_path: String) -> Array:
	var ids := []
	for path in MigrationFiles._resource_paths(directory_path):
		var profile: Resource = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if profile == null or String(profile.get("id")).strip_edges().is_empty():
			MigrationFiles._fail("cannot load stable ID from resource: %s" % path)
			return []
		ids.append(String(profile.get("id")))
	ids.sort()
	if _id_set(ids).size() != ids.size():
		MigrationFiles._fail("duplicate stable resource ID in %s" % directory_path)
		return []
	return ids


static func _ids_from_dictionaries(values: Variant) -> Array:
	var ids := []
	for value in values:
		ids.append(String((value as Dictionary).get("id", "")))
	ids.sort()
	return ids


static func _legacy_node_ids(legacy: Dictionary) -> Array:
	var ids := []
	for value in legacy.get("nodes", []):
		ids.append(String((value as Dictionary).get("id", "")))
	return ids


static func _added_ids(current_ids: Variant, legacy_ids: Variant) -> Array:
	var legacy_set := _id_set(legacy_ids)
	var added := []
	for id_value in current_ids:
		if not legacy_set.has(String(id_value)):
			added.append(String(id_value))
	added.sort()
	return added


static func _added_application_ids(application_ids: Array, legacy: Dictionary) -> Array:
	var migrated := {}
	for value in legacy.get("nodes", []):
		var node: Dictionary = value
		if String(node.get("anchor_kind", "")) == "application":
			migrated["app.%s" % String(node.get("id", "")).trim_prefix("tech.application.")] = true
	var added := []
	for id in application_ids:
		if not migrated.has(String(id)):
			added.append(String(id))
	return added


static func _id_set(ids: Variant) -> Dictionary:
	var result := {}
	for id in ids:
		result[String(id)] = true
	return result


static func _sha256_id_list(ids: Array) -> String:
	return _sha256_bytes(("\n".join(ids) + "\n").to_utf8_buffer())


static func _sha256_files(paths: PackedStringArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	for path in paths:
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty() and FileAccess.get_file_as_string(path).is_empty():
			MigrationFiles._fail("cannot hash file: %s" % path)
			return ""
		context.update(String(path).replace("\\", "/").to_utf8_buffer())
		context.update(PackedByteArray([0]))
		context.update(bytes)
		context.update(PackedByteArray([0]))
	return context.finish().hex_encode()


static func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	context.update(bytes)
	return context.finish().hex_encode()
