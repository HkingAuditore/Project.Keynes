extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns world, environment persistence; receives only declared capabilities.

func _can_world_provider(context: Dictionary) -> Dictionary:
	var world = context.get("world")
	return _result(world != null and world.has_method("serialize") \
		and world.has_method("deserialize"), "ok" if world != null else "save_provider_missing",
		"" if world != null else "动态世界 provider 不可用。")

func _write_world_provider(context: Dictionary) -> Dictionary:
	var state: Dictionary = context.world.serialize()
	# DCWorld is a compatibility mirror. Capture the actual climate input slot
	# without mutating any live copy or changing the next uninterrupted tick.
	var capture: Callable = context.get("base_moisture", Callable())
	if capture.is_valid():
		var base: PackedFloat32Array = capture.call()
		if base.size() == int(state.n_cells):
			state.cells["cell_base_moisture"] = base
	return {"ok": true, "sections": {
		"new_game_config": context.session.get("new_game_config", {}),
		"dynamic_world": state,
	}}

func _restore_world_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	context.world.deserialize(sections.dynamic_world)
	var restore_base: Callable = context.get("restore_base_moisture", Callable())
	if restore_base.is_valid(): restore_base.call()
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
	# This cached result gates WEATHER_OBSERVED on days when the native job skips.
	environment["adapter_version"] = 3
	environment["native_daily_weather_rc"] = context.weather_result.call()
	return {"ok": true, "sections": {"environment": environment}}

func _restore_environment_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var state: Dictionary = sections.environment
	if int(state.get("adapter_version", -1)) != 3 or not state.get("native_daily_weather_rc") is int:
		return _result(false, "environment_adapter_version_mismatch", "环境保存适配版本不匹配，需要版本 3。")
	var restored: Dictionary = context.restore_environment.call(state)
	if bool(restored.get("ok", false)):
		context.restore_weather_result.call(int(state.native_daily_weather_rc))
	return restored


func section_codecs(_id: StringName, sections: PackedStringArray) -> Dictionary:
	var codecs := {}
	for section in sections:
		codecs[section] = "bytes" if section == "preview" else "variant"
	return codecs
