extends SceneTree

const MANIFEST_PATH := "res://data/native_binding_manifest.json"
const NativeWorld = preload("res://scripts/data_core/native_world.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== native world handshake test ===")
	var handshake := NativeWorld.handshake()
	_expect("manifest handshake succeeds", bool(handshake.get("ok", false)))
	_expect("manifest handshake sees DCWorldExt", bool(handshake.get("class_exists", false)))
	var world: DCWorldExt = NativeWorld.create()
	_expect("NativeWorld.create returns DCWorldExt", world != null)

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	var methods := PackedStringArray()
	if parsed is Dictionary:
		for method_name in parsed.get("methods", []):
			methods.append(String(method_name))
	var with_missing := methods.duplicate()
	with_missing.append("__pk_missing_probe__")
	var missing_result := NativeWorld.verify_methods(with_missing)
	var missing: PackedStringArray = missing_result.get("missing", PackedStringArray())
	_expect("missing probe rejects handshake", not bool(missing_result.get("ok", true)))
	_expect("missing probe is the only missing method",
			missing.size() == 1 and String(missing[0]) == "__pk_missing_probe__")

	var shortened := methods.duplicate()
	if not shortened.is_empty():
		shortened.remove_at(0)
	var shortened_result := NativeWorld.verify_methods(shortened)
	_expect("a shorter requirement list still succeeds", bool(shortened_result.get("ok", false)))
	print("checks=%d failures=%d" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
