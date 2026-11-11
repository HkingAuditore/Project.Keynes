extends Node

## Smooths presentation-only music parameters. PlayerController remains event driven.
var situation: RefCounted


func _process(delta: float) -> void:
	if situation == null:
		return
	var update: Dictionary = situation.process_audio_update(delta)
	if not bool(update.get("tension_write_due", false)):
		return
	var audio := get_node_or_null("/root/GameAudio")
	if audio != null and audio.has_method("set_active_suite_emotion") and bool(
			audio.set_active_suite_emotion(float(update.get("tension", 0.0)), 0.0, 0.0, false)):
		situation.consume_tension_write()
