extends SceneTree
const Current = preload("res://scripts/game/world_state_modules.gd")
const Reference = preload("res://tests/game/world_state_contracts_reference.gd")
var checks := 0
var failures := 0
func _init(): call_deferred("run")
func run():
	var expected: Array = Reference.builtins(57, 1)
	var actual: Array = Current.builtins(57, 1)
	check(expected.size() == actual.size(), "provider count")
	for i in expected.size():
		var a: Dictionary = expected[i]
		var b: Dictionary = actual[i]
		check(a.id == b.id and a.after == b.after and a.owns == b.owns, "ordered dependency contract")
		check(a.module.schema_version() == b.module.schema_version(), "version")
		if b.id in ["pkcn", "ecp2"]:
			var old_manifest: Dictionary = a.module.manifest_entry({}, false)
			var manifest: Dictionary = b.module.manifest_entry({}, false)
			check(var_to_bytes(old_manifest) == var_to_bytes(manifest), "manifest bytes")
			check(b.module.accepts_manifest(manifest), "current version")
			manifest.schema_version -= 1
			check(not b.module.accepts_manifest(manifest), "old version rejected")
	print("save contracts: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
func check(ok: bool, label: String):
	checks += 1
	if not ok:
		failures += 1
		push_error(label)
