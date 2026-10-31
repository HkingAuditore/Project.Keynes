extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	print("[stone-age-fmod-test] ", "PASS " if ok else "FAIL ", message)
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

	# 1. Start Stone Age Suite from Intro (0.0s)
	_check(audio.play_stone_age_suite(true, 0.0, 0.5, 0), "start Stone Age suite from Intro (0.0s)")
	await get_tree().create_timer(0.65).timeout
	var d0: Dictionary = audio.diagnostics()
	_check(bool(d0.get("music_playing", false)) and d0.get("music_key") == &"stone_age_suite", "Stone Age suite playing")
	_check(int(d0.get("timeline_ms", 0)) > 50 and int(d0.get("timeline_ms", 0)) < 2500,
		"Intro timeline advancing (%d ms)" % int(d0.get("timeline_ms", 0)))
	_check(audio.set_active_suite_emotion(0.65, 0.8, 0.9, true),
		"Stone Age Tension accepts legacy suite emotion API")
	var tension_readback: Dictionary = audio.diagnostics()
	_check(absf(float(tension_readback.get("tension", 0.0)) - 0.65) < 0.01,
		"Stone Age Tension parameter readback")
	_check(absf(float(tension_readback.get("war", 1.0))) < 0.01
			and absf(float(tension_readback.get("ceremony", 1.0))) < 0.01,
		"Stone Age keeps War/Ceremony neutral")

	# 2. Population threshold & hysteresis verification
	var r0: float = audio.update_stone_age_population_count(80)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 0 and r0 < 0.20, "Pop 80 -> Tier 0 (gatherers)")
	var r1: float = audio.update_stone_age_population_count(450)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1 and r1 >= 0.40, "Pop 450 -> Tier 1 (tribe rhythm layer)")
	# Hysteresis check: 260 is below 300 entry threshold, but above 240 exit threshold -> stays Tier 1!
	audio.update_stone_age_population_count(260)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1, "Pop 260 stays Tier 1 via hysteresis (>=240)")
	var r2: float = audio.update_stone_age_population_count(1000)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 2 and r2 >= 0.84, "Pop 1000 -> Tier 2 (clan choir layer)")
	_check(audio.set_stone_age_population(0.95, true), "set Population=0.95 immediate")
	_check(absf(float(audio.diagnostics().get("population", 0.0)) - 0.95) < 0.01, "Population parameter readback")

	# 3. Camera Zoom-In (0.0) & Zoom-Out (1.0) verification
	_check(audio.set_stone_age_camera_zoom(0.0, true), "set CameraZoom=0.0 (close-up settlement)")
	_check(absf(float(audio.diagnostics().get("camera_zoom", 0.5)) - 0.0) < 0.01, "CameraZoom=0.0 readback")
	_check(audio.set_stone_age_camera_zoom(1.0, true), "set CameraZoom=1.0 (macro world)")
	_check(absf(float(audio.diagnostics().get("camera_zoom", 0.5)) - 1.0) < 0.01, "CameraZoom=1.0 readback")

	# 4. Conditional Loop Region A (18.0s .. 72.0s) wrap verification
	_check(audio.set_stone_age_loop_section(1, true), "select Loop A (18.0s)")
	_check(audio.jump_stone_age_timeline_ms(71600), "jump near end of Loop A (71600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_a := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_a >= 18000 and pos_a < 19700, "Loop A conditional region wrapped back to 18.0s (pos=%d ms)" % pos_a)

	# 5. Full Loop Region ABC (18.0s .. 180.0s) wrap verification
	_check(audio.set_stone_age_loop_section(0, false), "select Full Loop ABC (0)")
	_check(audio.jump_stone_age_timeline_ms(179600), "jump near end of Full Suite (179600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_full := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_full >= 18000 and pos_full < 19700, "Full Loop ABC wrapped from 180.0s to 18.0s (pos=%d ms)" % pos_full)

	audio.stop_music()
	if settings != null:
		settings.update(before, false)
	print("STONE_AGE_FMOD_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
