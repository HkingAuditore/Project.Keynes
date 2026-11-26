extends RefCounted

## Read and write technology migration inputs and locate resource files.

const NETWORK_PATH := "res://data/technology/technology_network.json"
const BUILDING_DIR := "res://data/economy/buildings"
const GOOD_DIR := "res://data/goods"
const RESOURCE_DIR := "res://data/resources"
const SUBSTANTIVE_RENAMES := {
	"tech.application.solar_salt_pan": "tech.solar_evaporation",
	"tech.copper_mining_application": "tech.copper_mine_engineering",
	"tech.application.method_highland_precision_agriculture": "tech.highland_precision_agriculture",
	"tech.application.method_autonomous_forestry": "tech.autonomous_forestry_operations",
}


static func _resource_paths(directory_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var directory := DirAccess.open(directory_path)
	if directory == null: return out
	for file_name in directory.get_files():
		if file_name.ends_with(".tres"): out.append("%s/%s" % [directory_path, file_name])
	out.sort()
	return out


static func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed is Dictionary: return parsed
	_fail("invalid JSON: %s" % path)
	return {}


static func _write_json(path: String, payload: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(payload, "\t", false, true) + "\n")
	file.close()


static func _fail(message: String) -> void:
	push_error(message)


static func _fail_bool(message: String) -> bool:
	_fail(message)
	return false
