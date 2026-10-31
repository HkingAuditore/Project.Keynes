extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	print("[agrarian-age-fmod-test] ", "PASS " if ok else "FAIL ", message)
	_failed = _failed or not ok


func _run() -> void:
	await get_tree().process_frame
	var audio := get_tree().root.get_node("GameAudio")
	_check(audio.status == "ready", "FMOD backend ready")
	if audio.status != "ready":
		get_tree().quit(1)
		return

	var settings := get_tree().root.get_node_or_null("GameSettings")
	var before: Dictionary = settings.values() if settings != null else {}
	if settings != null:
		settings.update({"master_volume": 0.2, "master_muted": true}, false)

	# 0. Era Advancement Transition (Stone Age -> Agrarian Age) verification
	_check(audio.play_stone_to_agrarian_transition(), "play Era Transition event:/Music/Transition/era_stone_to_agrarian")
	_check(audio.advance_stone_to_agrarian_suite(0.45, 0.5, false), "advance_stone_to_agrarian_suite orchestration")

	# 1. Start Agrarian Age Suite from Intro (0.0s)
	_check(audio.play_agrarian_age_suite(true, 0.0, 0.5, 0), "start Agrarian Age suite from Intro (0.0s)")
	await get_tree().create_timer(0.65).timeout
	var d0: Dictionary = audio.diagnostics()
	_check(bool(d0.get("music_playing", false)) and d0.get("music_key") == &"agrarian_age_suite", "Agrarian Age suite playing")
	_check(int(d0.get("timeline_ms", 0)) > 50 and int(d0.get("timeline_ms", 0)) < 2500,
		"Intro timeline advancing (%d ms)" % int(d0.get("timeline_ms", 0)))
	_check(audio.set_active_suite_emotion(0.65, 0.8, 0.9, true),
		"Agrarian Age Tension accepts legacy suite emotion API")
	var tension_readback: Dictionary = audio.diagnostics()
	_check(absf(float(tension_readback.get("tension", 0.0)) - 0.65) < 0.01,
		"Agrarian Age Tension parameter readback")
	_check(absf(float(tension_readback.get("war", 1.0))) < 0.01
			and absf(float(tension_readback.get("ceremony", 1.0))) < 0.01,
		"Agrarian Age keeps War/Ceremony neutral")

	# 2. Population threshold & hysteresis verification (Agrarian thresholds: 600/480 and 1600/1360)
	var r0: float = audio.update_agrarian_age_population_count(200)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 0 and r0 < 0.20, "Pop 200 -> Tier 0 (hamlet)")
	var r1: float = audio.update_agrarian_age_population_count(900)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1 and r1 >= 0.40, "Pop 900 -> Tier 1 (irrigated village rhythm layer)")
	# Hysteresis check: 520 is below 600 entry threshold, but above 480 exit threshold -> stays Tier 1!
	audio.update_agrarian_age_population_count(520)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1, "Pop 520 stays Tier 1 via hysteresis (>=480)")
	var r2: float = audio.update_agrarian_age_population_count(1900)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 2 and r2 >= 0.84, "Pop 1900 -> Tier 2 (harvest choir & bronze bells)")
	_check(audio.set_agrarian_age_population(0.92, true), "set Population=0.92 immediate")
	_check(absf(float(audio.diagnostics().get("population", 0.0)) - 0.92) < 0.01, "Population parameter readback")

	# 3. Camera Zoom-In (0.0) & Zoom-Out (1.0) verification
	_check(audio.set_agrarian_age_camera_zoom(0.0, true), "set CameraZoom=0.0 (close-up paddy & millstone)")
	_check(absf(float(audio.diagnostics().get("camera_zoom", 0.5)) - 0.0) < 0.01, "CameraZoom=0.0 readback")
	_check(audio.set_agrarian_age_camera_zoom(1.0, true), "set CameraZoom=1.0 (macro plain & celestial calendar)")
	_check(absf(float(audio.diagnostics().get("camera_zoom", 0.5)) - 1.0) < 0.01, "CameraZoom=1.0 readback")

	# 4. Conditional Loop Region A (16.0s .. 68.0s) wrap verification
	_check(audio.set_agrarian_age_loop_section(1, true), "select Loop A (16.0s)")
	_check(audio.jump_agrarian_age_timeline_ms(67600), "jump near end of Loop A (67600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_a := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_a >= 16000 and pos_a < 17700, "Loop A conditional region wrapped back to 16.0s (pos=%d ms)" % pos_a)

	# 5. Full Loop Region ABC (16.0s .. 172.0s) wrap verification
	_check(audio.set_agrarian_age_loop_section(0, false), "select Full Loop ABC (0)")
	_check(audio.jump_agrarian_age_timeline_ms(171600), "jump near end of Full Suite (171600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_full := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_full >= 16000 and pos_full < 17700, "Full Loop ABC wrapped from 172.0s to 16.0s (pos=%d ms)" % pos_full)

	audio.stop_music()
	if settings != null:
		settings.update(before, false)
	print("AGRARIAN_AGE_FMOD_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
