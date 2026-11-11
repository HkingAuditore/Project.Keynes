extends RefCounted
class_name NativeWorld

## Single creation point for the script-facing DCWorldExt object.
##
## The manifest is generated from the checked-in C++ bindings.  It is read at
## most once per process, and every world creation checks that the loaded
## extension still exposes that complete surface.

const CLASS_NAME := "DCWorldExt"
const MANIFEST_PATH := "res://data/native_binding_manifest.json"

static var _handshake_done := false
static var _handshake_result: Dictionary = {}
static var _last_error: Dictionary = {}


static func verify_methods(manifest_methods: PackedStringArray) -> Dictionary:
	if not ClassDB.class_exists(CLASS_NAME):
		return {"ok": false, "missing": PackedStringArray(), "class_exists": false}

	var available := {}
	for info in ClassDB.class_get_method_list(CLASS_NAME, true):
		if info is Dictionary:
			available[String(info.get("name", ""))] = true

	var missing := PackedStringArray()
	for method_name in manifest_methods:
		if not available.has(String(method_name)):
			missing.append(String(method_name))
	return {"ok": missing.is_empty(), "missing": missing, "class_exists": true}


static func handshake() -> Dictionary:
	if _handshake_done:
		return _handshake_result.duplicate(true)
	_handshake_done = true

	var result := {"ok": false, "missing": PackedStringArray(), "class_exists": ClassDB.class_exists(CLASS_NAME)}
	if not FileAccess.file_exists(MANIFEST_PATH):
		result["reason"] = "native_binding_manifest_missing"
		_handshake_result = result
		_last_error = result.duplicate(true)
		return result.duplicate(true)

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not parsed is Dictionary:
		result["reason"] = "native_binding_manifest_invalid"
		_handshake_result = result
		_last_error = result.duplicate(true)
		return result.duplicate(true)
	var manifest: Dictionary = parsed
	if String(manifest.get("class", "")) != CLASS_NAME:
		result["reason"] = "native_binding_manifest_class_invalid"
		_handshake_result = result
		_last_error = result.duplicate(true)
		return result.duplicate(true)
	var raw_methods: Variant = manifest.get("methods", [])
	if not raw_methods is Array:
		result["reason"] = "native_binding_manifest_methods_invalid"
		_handshake_result = result
		_last_error = result.duplicate(true)
		return result.duplicate(true)
	var methods := PackedStringArray()
	for method_name in raw_methods:
		methods.append(String(method_name))
	result = verify_methods(methods)
	result["manifest_count"] = methods.size()
	_handshake_result = result
	_last_error = result.duplicate(true)
	return result.duplicate(true)


static func _report_handshake_failure(result: Dictionary) -> void:
	var missing: PackedStringArray = result.get("missing", PackedStringArray())
	var preview := PackedStringArray()
	for i in mini(missing.size(), 20):
		preview.append(String(missing[i]))
	var suffix := ""
	if missing.size() > preview.size():
		suffix = ", …"
	var reason := String(result.get("reason", ""))
	if not reason.is_empty():
		push_error("[native-world] DCWorldExt handshake failed (%s); missing %d methods (%s%s)" % [
			reason, missing.size(), ", ".join(preview), suffix])
	else:
		push_error("[native-world] DCWorldExt handshake failed; missing %d methods (%s%s)" % [
			missing.size(), ", ".join(preview), suffix])


static func create() -> DCWorldExt:
	if not ClassDB.class_exists(CLASS_NAME):
		_last_error = {"ok": false, "missing": PackedStringArray(), "class_exists": false}
		return null
	var check := handshake()
	if not bool(check.get("ok", false)):
		_last_error = check.duplicate(true)
		_report_handshake_failure(check)
		return null
	var instance: Object = ClassDB.instantiate(CLASS_NAME)
	if instance == null:
		_last_error = {"ok": false, "missing": PackedStringArray(), "class_exists": true,
			"reason": "native_world_instantiate_failed"}
		push_error("[native-world] DCWorldExt is registered but could not be instantiated")
		return null
	var world := instance as DCWorldExt
	if world == null:
		_last_error = {"ok": false, "missing": PackedStringArray(), "class_exists": true,
			"reason": "native_world_wrong_type"}
		push_error("[native-world] DCWorldExt instance has an unexpected type")
		return null
	_last_error = check.duplicate(true)
	return world


static func last_error() -> Dictionary:
	return _last_error.duplicate(true)
