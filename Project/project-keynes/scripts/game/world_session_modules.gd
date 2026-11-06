extends RefCounted

## Composition of the existing world adapters. Business formulas stay in their
## owners; extensions prepare before execution starts and release after it stops.
const Module = preload("res://scripts/game/runtime_session_module.gd")


static func entries(owner: Object, extensions: Array = []) -> Array:
	var result: Array = [
		_make(owner, "world", [], ["world.data"], "_prepare_world_data",
			"_cancel_world_preparation", "_release_world_data"),
		_make(owner, "presentation", ["world"], ["world.presentation"],
			"_prepare_world_presentation", "_cancel_session_presentation", "_release_session_presentation"),
		_make(owner, "restore", ["presentation"], [], "_prepare_world_restore",
			"_session_noop", "_session_ok"),
	]
	var simulation_after := PackedStringArray(["restore"])
	for module in extensions:
		var entry: Dictionary = module.descriptor()
		# Extension defaults must be explicit: it can depend on world, presentation,
		# restore or another extension. Execution always starts after ALL of them.
		result.append(entry)
		simulation_after.append(String(entry.get("id", "")))
	result.append(_make(owner, "simulation", simulation_after, ["world.executor"],
		"_prepare_world_simulation", "_cancel_session_simulation", "_release_session_simulation"))
	return result


static func _make(owner: Object, id: String, after: PackedStringArray,
		owns: PackedStringArray, prepare: StringName, cancel: StringName,
		release: StringName) -> Dictionary:
	return Module.new().configure(id, after, owns, Callable(owner, prepare),
		Callable(owner, cancel), Callable(owner, release)).descriptor()
