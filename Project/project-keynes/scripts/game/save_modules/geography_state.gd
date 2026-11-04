extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns world, environment persistence; receives only declared capabilities.

func _can_world_provider(context: Dictionary) -> Dictionary:
	var world = context.get("world")
	return _result(world != null and world.has_method("serialize") \
		and world.has_method("deserialize"), "ok" if world != null else "save_provider_missing",
		"" if world != null else "动态世界 provider 不可用。")

func _write_world_provider(context: Dictionary) -> Dictionary:
	return {"ok": true, "sections": {
		"new_game_config": context.session.get("new_game_config", {}),
		"dynamic_world": context.world.serialize(),
	}}

func _restore_world_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	context.world.deserialize(sections.dynamic_world)
	return _result(true, "ok", "")

func _can_environment_provider(context: Dictionary) -> Dictionary:
	var available: bool = context.capture_environment.is_valid() and context.restore_environment.is_valid()
	return _result(available, "ok" if available else "save_provider_missing",
		"" if available else "环境 provider 不可用。")

func _write_environment_provider(context: Dictionary) -> Dictionary:
	var environment: Dictionary = context.capture_environment.call()
	if String(environment.get("schema", "")) != "PKEnvironmentRuntime":
		return _result(false, "environment_provider_incomplete",
			"环境运行时未提供可持久化的完整状态。")
	return {"ok": true, "sections": {"environment": environment}}

func _restore_environment_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	return context.restore_environment.call(sections.environment)


func section_codecs(_id: StringName, sections: PackedStringArray) -> Dictionary:
	var codecs := {}
	for section in sections:
		codecs[section] = "bytes" if section == "preview" else "variant"
	return codecs
