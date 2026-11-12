extends Node
## Portable (Web/Android) audio backend smoke test.
##
## Run:
##   $env:PK_AUDIO_FORCE_NATIVE='1'
##   Godot_v4.6.2-stable_win64_console.exe --headless --path Project/project-keynes \
##       res://tests/audio/native_audio_smoke_test.tscn
##
## Exercises the exact code path Android takes: GameAudio -> NativeAudio ->
## assets/audio/native/**/*.ogg, plus settings, era suites, UI/event cues,
## transitions and the Android lifecycle pause/resume contract.

const AudioService := preload("res://scripts/audio/game_audio_service.gd")

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	print("[native-audio-smoke] ", "PASS " if ok else "FAIL ", message)
	if not ok:
		_failed = true


func _run() -> void:
	var audio := get_node_or_null("/root/GameAudio")
	_check(audio != null, "GameAudio autoload present")
	if audio == null:
		_finish()
		return

	var force_env := String(OS.get_environment("PK_AUDIO_FORCE_NATIVE")).strip_edges().to_lower()
	var forced := force_env in ["1", "true", "yes", "on"]
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if String(arg) == "--audio-native":
			forced = true
	print("[native-audio-smoke] platform=%s backend=%s forced=%s" % [
		OS.get_name(), String(audio.backend), forced])
	_check(forced, "force switch present (PK_AUDIO_FORCE_NATIVE=1 or --audio-native)")
	_check(String(audio.status) == "ready", "GameAudio.status == ready (got %s)" % audio.status)
	_check(String(audio.backend) == "native", "GameAudio.backend == native (got %s)" % audio.backend)

	# Prove the platform matrix without an Android device.
	_check(AudioService.fmod_platform_supported("Windows", false) == true,
		"Windows runs the FMOD backend")
	_check(AudioService.fmod_platform_supported("Android", false) == true,
		"Android runs the FMOD backend")
	_check(AudioService.fmod_platform_supported("Web", true) == true,
		"web runs the FMOD HTML5 side module")
	_check(AudioService.fmod_platform_supported("Linux", false) == false,
		"unlisted desktop platforms keep the previous disabled behaviour")
	_check(AudioService.native_backend_reason_for("Android", false, false, false) == "",
		"platform=Android no longer selects the portable backend")
	_check(AudioService.native_backend_reason_for("Windows", false, false, false) == "",
		"platform=Windows keeps FMOD (unless forced)")
	_check(AudioService.native_backend_reason_for("Windows", false, false, true) == "forced",
		"force switch selects backend=native on Windows")

	var native := audio.get_node_or_null("NativeAudio")
	_check(native != null, "GameAudio/NativeAudio child present")
	if native == null:
		_finish()
		return

	# All four era suites must resolve and switch.
	for era in range(4):
		_check(native.play_suite(era) == true, "play_suite(%d) returns true" % era)
		_check(native.music_key == StringName(["stone", "agrarian", "kingdom", "empire"][era] + "_age_suite"),
			"suite key after play_suite(%d) = %s" % [era, native.music_key])
		await get_tree().create_timer(0.12).timeout

	# Back to the menu/Stone Age suite and verify the timeline really advances.
	_check(native.play_suite(0) == true, "play_suite(0) returns true")
	await get_tree().create_timer(1.0).timeout
	_check(native.music.playing, "music.playing after ~1 s")
	var position: float = native.music.get_playback_position()
	_check(position > 0.05, "music.playback_position > 0 after ~1 s (%.3f s)" % position)

	# Exactly the call main_menu.gd:82 makes.
	_check(audio.play_stone_age_suite(true, 0.0, 0.78, 0) == true,
		"main-menu play_stone_age_suite(true, 0.0, 0.78, 0) returns true")
	_check(String(audio.get("_music_key")) == "stone_age_suite",
		"GameAudio._music_key adopts stone_age_suite")

	# Every portable cue shipped in assets/audio/native must resolve.
	var ui_cues := ["click", "page", "open", "close", "confirm", "toggle_on", "toggle_off", "tick"]
	for cue in ui_cues:
		_check(native.play_cue("ui", StringName(cue)) == true, "ui cue %s resolves" % cue)
	_check(int(native.diagnostics().get("ui_voices", 0)) > 0, "a UI voice is playing")
	var event_cues := ["tech_start", "tech_research", "tech_cancel", "territory_expand",
		"ideology_draw", "ideology_use", "ideology_reroll", "ideology_reveal",
		"ideology_choose", "ideology_unequip", "ideology_promote", "building_complete",
		"population_grow", "trade"]
	for cue in event_cues:
		_check(native.play_cue("events", StringName(cue)) == true, "event cue %s resolves" % cue)
	_check(audio.play_event_cue(&"tech_start") == true, "GameAudio.play_event_cue(tech_start)")
	_check(audio.play_ui(&"page") == true, "GameAudio.play_ui(page)")

	var transitions := ["event:/Music/Transition/era_stone_to_agrarian",
		"event:/Music/Transition/era_agrarian_to_kingdom",
		"event:/Music/Transition/era_kingdom_to_empire"]
	for event_path in transitions:
		_check(native.play_transition(event_path) == true, "transition %s resolves" % event_path)
	_check(audio.play_transition(&"trans_stone_to_agrarian") == true,
		"GameAudio.play_transition(trans_stone_to_agrarian)")
	_check(int(native.diagnostics().get("ui_voices", 0)) > 0, "a transition/one-shot voice is playing")

	# Master-bus settings: linear -> dB, same formula as GameSettings.
	var master := AudioServer.get_bus_index("Master")
	var settings := get_node_or_null("/root/GameSettings")
	var original := {"master_volume": 0.8, "master_muted": false}
	if settings != null:
		original = settings.values()
	audio.apply_settings({"master_volume": 0.5, "master_muted": false})
	var applied := db_to_linear(AudioServer.get_bus_volume_db(master))
	_check(absf(applied - 0.5) <= 0.02, "master volume 0.5 -> %.3f linear" % applied)
	audio.apply_settings({"master_volume": 0.8, "master_muted": true})
	_check(AudioServer.is_bus_mute(master), "master mute applies")
	audio.apply_settings(original)

	# Android lifecycle: background pauses in place, foreground resumes the same spot.
	_check(audio.set_era(0) == true, "set_era(0) keeps the menu suite")
	await get_tree().create_timer(0.2).timeout
	var was_playing: bool = native.music.playing
	_check(native.pause_for_lifecycle("smoke") == was_playing,
		"pause_for_lifecycle reports the previous music state")
	_check(native.music.stream_paused, "music.stream_paused after background")
	var paused_at: float = native.music.get_playback_position()
	await get_tree().create_timer(0.4).timeout
	_check(absf(native.music.get_playback_position() - paused_at) <= 0.05,
		"playback position frozen while backgrounded (%.3f)" % paused_at)
	_check(native.resume_from_lifecycle("smoke") == true, "resume_from_lifecycle returns playing")
	_check(not native.music.stream_paused, "music.stream_paused cleared after foreground")
	await get_tree().create_timer(0.4).timeout
	_check(native.music.get_playback_position() > paused_at + 0.05,
		"playback resumes after foreground (%.3f -> %.3f)" % [
			paused_at, native.music.get_playback_position()])

	# Exercise the exact Node notification path Android's SceneTree uses:
	# root.propagate_notification -> NativeAudio._notification. This catches a
	# missing/renamed _notification override even without an Android device.
	get_tree().root.propagate_notification(NOTIFICATION_APPLICATION_PAUSED)
	await get_tree().process_frame
	_check(native.music.stream_paused, "root APPLICATION_PAUSED pauses music")
	get_tree().root.propagate_notification(NOTIFICATION_APPLICATION_RESUMED)
	await get_tree().process_frame
	_check(not native.music.stream_paused, "root APPLICATION_RESUMED resumes music")

	# Era switching and transitions from the service layer.
	_check(audio.set_era(1) == true, "set_era(1) switches to the Agrarian suite")
	_check(native.music_key == &"agrarian_age_suite", "Agrarian suite active")
	_check(audio.set_era(3) == true, "set_era(3) switches to the Empire suite")
	_check(native.music_key == &"empire_age_suite", "Empire suite active")
	_check(audio.diagnostics().get("backend") == "native", "diagnostics.backend == native")

	audio.stop_music()
	_check(not native.music.playing, "stop_music stops playback")
	_finish()


func _finish() -> void:
	print("NATIVE_AUDIO_SMOKE_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
