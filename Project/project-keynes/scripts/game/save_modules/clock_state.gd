extends "res://scripts/game/save_modules/state_adapter.gd"

## Owns clock persistence; receives only declared capabilities.

func _can_clock_provider(context: Dictionary) -> Dictionary:
	return _result(context.clock != null, "ok" if context.clock != null else "save_provider_missing",
		"" if context.clock != null else "WorldClock provider 不可用。")

func _write_clock_provider(context: Dictionary) -> Dictionary:
	var state: Dictionary = context.clock.export_state()
	state.paused = bool(context.saved_paused)
	state.speed_multiplier = float(context.saved_speed)
	return {"ok": true, "sections": {"world_clock": state}}

func _restore_clock_provider(sections: Dictionary, context: Dictionary) -> Dictionary:
	var state: Dictionary = sections.world_clock.duplicate(true)
	if OS.get_environment("PK_SAVE_MIGRATE") == "1":
		# Offline migration may not advance business state while loading.
		state["paused"] = true
	var result: Dictionary = context.clock.restore_state(state)
	if bool(result.get("ok", false)):
		context.clock_restored.call(context.clock.year_index())
	return result


func section_codecs(_id: StringName, sections: PackedStringArray) -> Dictionary:
	var codecs := {}
	for section in sections:
		codecs[section] = "bytes" if section == "preview" else "variant"
	return codecs
