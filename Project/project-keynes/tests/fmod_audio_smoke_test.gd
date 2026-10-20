extends Node

var _failed := false
func _ready() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	print("[fmod-test] ", "PASS " if ok else "FAIL ", message)
	_failed = _failed or not ok

func _run() -> void:
	await get_tree().process_frame
	var audio := get_tree().root.get_node("GameAudio")
	_check(audio.status == "ready", "backend ready")
	if audio.status != "ready":
		get_tree().quit(1)
		return
	_check(audio.play_prototype(0.8), "start persistent music and set tension")
	_check(audio.play_ui_click(), "play and release one-shot")
	var settings := get_tree().root.get_node_or_null("GameSettings")
	var before: Dictionary = settings.values() if settings != null else {}
	if settings != null:
		settings.update({"master_volume":0.25,"master_muted":true},false)
	else:
		audio.apply_settings({"master_volume":0.25,"master_muted":true})
	var snapshot: Dictionary = audio.diagnostics()
	_check(snapshot.banks == 4, "four banks loaded")
	_check(absf(snapshot.tension - 0.8) < 0.001, "parameter readback")
	_check(absf(snapshot.master_volume - 0.25) < 0.001 and snapshot.master_muted, "settings reach FMOD Master")
	_check(audio.set_tension(9.0), "clamp tension input")
	_check(absf(audio.diagnostics().tension - 1.0) < 0.001, "clamp readback")
	await get_tree().create_timer(8.4).timeout
	var looped: Dictionary = audio.diagnostics()
	_check(looped.timeline_ms > 0 and looped.timeline_ms < 2000, "eight-second loop wraps")
	audio.stop_music()
	_check(not audio.diagnostics().music_playing, "persistent instance released")
	if settings != null:
		settings.update(before,false)
	print("FMOD_AUDIO_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
