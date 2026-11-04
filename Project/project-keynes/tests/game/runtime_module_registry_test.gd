extends SceneTree

const Registry = preload("res://scripts/game/runtime_module_registry.gd")
const Builtins = preload("res://scripts/game/world_state_modules.gd")
const Extension = preload("res://tests/game/fixtures/extension_state_module.gd")
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var owner := root.get_node("GameSave")
	var entries: Array = Builtins.builtins(53, 1)
	var expected := PackedStringArray()
	for entry in entries:
		expected.append(entry.id)
	var result := Registry.resolve(entries)
	_expect("all existing state modules register", bool(result.ok) and result.modules.size() == 18)
	_expect("existing restore order is preserved", result.ids == expected)
	entries.reverse()
	result = Registry.resolve(entries)
	_expect("registration order does not define dependencies", bool(result.ok))
	for edge in [["pkcn", "pkmi"], ["pkmi", "pkef"], ["pkef", "ecp2"],
			["ecp2", "pkai"], ["pkcn", "pkfg"], ["pkid", "pkar"]]:
		_expect("restore %s precedes %s" % [edge[0], edge[1]],
			result.ids.find(edge[0]) < result.ids.find(edge[1]))
	_expect("player view follows all restored state", result.ids[-1] == "player_session")
	var instance := RefCounted.new()
	var a := {"id": "a", "module": instance, "owns": ["a_state"], "after": []}
	var b := {"id": "b", "module": instance, "owns": ["b_state"], "after": ["a"]}
	_expect("duplicate identity rejected", Registry.resolve([a, a]).code == "module_id_duplicate")
	var bad := b.duplicate(true)
	bad.owns = ["a_state"]
	_expect("duplicate state owner rejected", Registry.resolve([a, bad]).code == "module_owner_duplicate")
	bad = b.duplicate(true)
	bad.after = ["missing"]
	_expect("missing dependency rejected", Registry.resolve([a, bad]).code == "module_dependency_missing")
	bad = a.duplicate(true)
	bad.after = ["b"]
	_expect("dependency cycle rejected", Registry.resolve([bad, b]).code == "module_dependency_cycle")
	bad = a.duplicate(true)
	bad.after = 10
	_expect("invalid descriptor rejected", Registry.resolve([bad]).code == "module_descriptor_invalid")
	bad = a.duplicate(true)
	bad.module = 42
	_expect("non-object module rejected before lifecycle dispatch", Registry.resolve([bad]).code == "module_descriptor_invalid")
	bad = b.duplicate(true)
	bad.after = [42]
	_expect("dependency names have a stable string identity", Registry.resolve([a, bad]).code == "module_descriptor_invalid")
	var module := Extension.new()
	var added: Dictionary = root.get_node("GameSave").register_state_module(
		module.provider(), PackedStringArray(["ecp2"]))
	_expect("new module joins through the composition API", bool(added.ok))
	_expect("player view restores after newly registered business state",
		root.get_node("GameSave").get("_providers")[-1].provider_id() == &"player_session")
	var duplicate: Dictionary = root.get_node("GameSave").register_state_module(
		module.provider(), PackedStringArray(["ecp2"]))
	_expect("failed registration keeps the existing composition", duplicate.code == "module_id_duplicate"
		and root.get_node("GameSave").get("_providers").size() == 19)
	var save_service = root.get_node("GameSave")
	var manifest: Array = [{"provider_id": "technology_industry", "schema_version": 2}]
	for provider in save_service.get("_providers"):
		manifest.append({"provider_id": String(provider.provider_id()),
			"schema_version": provider.schema_version(), "sections": Array(provider.section_ids())})
	_expect("registered module formats are accepted", save_service._manifest_compatible(manifest))
	manifest.append({"provider_id": "uninstalled_system", "schema_version": 1, "sections": ["uninstalled_system"]})
	_expect("uninstalled system state cannot be silently discarded", not save_service._manifest_compatible(manifest))
	var extension_provider = module.provider()
	var old_entry := {"schema_version": 0, "sections": ["test_extension"]}
	_expect("new modules reject undeclared old formats", not extension_provider.accepts_manifest(old_entry))
	extension_provider.configure_compatibility(PackedInt32Array([0, 1]))
	_expect("module owns its supported format versions", extension_provider.accepts_manifest(old_entry))
	var invalid = load("res://scripts/game/runtime_state_provider.gd").new()
	invalid.configure(&"invalid", 1, PackedStringArray(["invalid"]),
		Callable(), Callable(), Callable(), Callable())
	_expect("missing implementation rejected before installing modules",
		Registry.resolve([Registry.state_entry(invalid)]).code == "module_descriptor_invalid")
	print("runtime module registry: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)
