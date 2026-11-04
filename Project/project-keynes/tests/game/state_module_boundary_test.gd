extends SceneTree

const Provider = preload("res://scripts/game/runtime_state_provider.gd")
const Builtins = preload("res://scripts/game/world_state_modules.gd")
class Adapter extends RefCounted:
	var seen: Array = []
	func can_save(context: Dictionary) -> Dictionary:
		seen.append(context)
		return {"ok": true}
	func write(_context: Dictionary) -> Dictionary:
		return {"ok": true, "sections": {"mine": PackedByteArray([1])}}
	func restore(sections: Dictionary, context: Dictionary) -> Dictionary:
		seen.append([sections.keys(), context])
		return {"ok": true}
	func hash_state(_context: Dictionary) -> String:
		return "test"

var checks := 0
var failures := 0

func _init() -> void:
	var provider = Provider.new()
	var adapter := Adapter.new()
	provider.configure(&"mine", 1, PackedStringArray(["mine"]), adapter.can_save,
		adapter.write, adapter.restore, adapter.hash_state).retain_adapter(adapter)
	provider.configure_context_binding(func(source: Dictionary): return {"selected": source.selected})
	provider.configure_restore_reads(PackedStringArray(["peer"]))
	var source := {"selected": 1, "host": "must not escape assembly"}
	provider.can_save(source)
	source.selected = 2
	provider.can_save(source)
	_expect("capabilities resolve at invocation and exclude whole host", adapter.seen == [{"selected": 1}, {"selected": 2}])
	provider.restore_sections({"mine": 1, "peer": 2, "unrelated": 3}, source)
	_expect("restore sees owned and declared dependency sections only",
		adapter.seen[-1][0] == ["mine", "peer"])
	_expect("missing peer is rejected before mutation",
		provider.restore_sections({"mine": 1}, source).code == "save_provider_missing" and adapter.seen.size() == 3)
	provider.configure_decoder(func(_archive: Dictionary): return {"ok": true, "sections": {"mine": 1, "other": 2}})
	_expect("decoder cannot overwrite another module's section", provider.decode_sections({"mine": PackedByteArray()}).code == "save_provider_undeclared_section")
	var ref: WeakRef = weakref(adapter)
	adapter = null
	_expect("provider retains implementation for its lifetime", ref.get_ref() != null and provider.registration_valid())
	provider = null
	_expect("releasing provider releases implementation", ref.get_ref() == null)
	var modules := {}
	for entry in Builtins.builtins(53, 1):
		modules[entry.id] = entry.module
	_expect("all legacy module adapters remain alive", modules.size() == 18)
	_expect("clock codec rejects non-dictionary payload", modules.world_clock.decode_sections({"world_clock": var_to_bytes(17)}).code == "save_section_decode_failed")
	_expect("required clock section cannot disappear", modules.world_clock.decode_sections({}).code == "save_provider_missing")
	_expect("old narrative omission has explicit empty-state migration", modules.pknr.decode_sections({}).sections.pknr == {})
	_expect("old native omission stays opaque bytes", modules.pkmi.decode_sections({}).sections.pkmi == PackedByteArray())
	_expect("legacy runtime variant remains readable", modules.simulation_runtime.decode_sections({"simulation_runtime": var_to_bytes({"schema": "PKSR", "version": 2})}).sections.simulation_runtime.version == 2)
	_expect("invalid runtime variant fails before restore", modules.simulation_runtime.decode_sections({"simulation_runtime": var_to_bytes(17)}).code == "save_section_decode_failed")
	print("state module boundaries: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)
