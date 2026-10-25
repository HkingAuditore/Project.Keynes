extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	print("[kingdom-empire-fmod-test] ", "PASS " if ok else "FAIL ", message)
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

	# ==========================================================================
	# PART 1: KINGDOM AGE (王国时代) + Agrarian->Kingdom Transition
	# ==========================================================================
	_check(audio.play_agrarian_to_kingdom_transition(), "play Era Transition event:/Music/Transition/era_agrarian_to_kingdom")
	_check(audio.advance_agrarian_to_kingdom_suite(0.45, 0.5, false), "advance_agrarian_to_kingdom_suite orchestration")

	_check(audio.play_kingdom_age_suite(true, 0.0, 0.5, 0), "start Kingdom Age suite from Intro (0.0s)")
	_check(audio.set_active_suite_emotion(0.35, 0.0, 0.25, true), "set Kingdom Tension/War/Ceremony")
	await get_tree().create_timer(0.65).timeout
	var dk0: Dictionary = audio.diagnostics()
	_check(bool(dk0.get("music_playing", false)) and dk0.get("music_key") == &"kingdom_age_suite", "Kingdom Age suite playing")
	_check(absf(float(dk0.get("tension", -1.0)) - 0.35) < 0.05 and absf(float(dk0.get("war", -1.0))) < 0.05
		and absf(float(dk0.get("ceremony", -1.0)) - 0.25) < 0.05, "Kingdom emotion parameters read back")
	_check(int(dk0.get("timeline_ms", 0)) > 50 and int(dk0.get("timeline_ms", 0)) < 2500,
		"Kingdom Intro timeline advancing (%d ms)" % int(dk0.get("timeline_ms", 0)))

	# Kingdom population thresholds (1500/1200 and 4000/3400)
	var kr0: float = audio.update_kingdom_age_population_count(600)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 0 and kr0 < 0.20, "Kingdom Pop 600 -> Tier 0")
	var kr1: float = audio.update_kingdom_age_population_count(2200)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1 and kr1 >= 0.40, "Kingdom Pop 2200 -> Tier 1")
	audio.update_kingdom_age_population_count(1300)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1, "Kingdom Pop 1300 stays Tier 1 via hysteresis (>=1200)")
	var kr2: float = audio.update_kingdom_age_population_count(4800)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 2 and kr2 >= 0.84, "Kingdom Pop 4800 -> Tier 2")

	# Kingdom Conditional Loop A (16.0s .. 66.0s) & Full Loop (16.0s .. 166.0s)
	_check(audio.set_kingdom_age_loop_section(1, true), "select Kingdom Loop A (16.0s)")
	_check(audio.jump_kingdom_age_timeline_ms(65600), "jump near end of Kingdom Loop A (65600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_ka := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_ka >= 16000 and pos_ka < 17700, "Kingdom Loop A wrapped back to 16.0s (pos=%d ms)" % pos_ka)

	_check(audio.set_kingdom_age_loop_section(0, false), "select Kingdom Full Loop ABC (0)")
	_check(audio.jump_kingdom_age_timeline_ms(165600), "jump near end of Kingdom Full Suite (165600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_kf := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_kf >= 16000 and pos_kf < 17700, "Kingdom Full Loop wrapped from 166.0s to 16.0s (pos=%d ms)" % pos_kf)
	_check(audio.set_kingdom_age_loop_section(3, true), "select Kingdom Loop C (16.0s + 100s)")
	_check(audio.jump_kingdom_age_timeline_ms(115600), "jump near end of Kingdom Loop C")

	# ==========================================================================
	# PART 2: EMPIRE AGE (帝国时代) + Kingdom->Empire Transition
	# ==========================================================================
	_check(audio.play_kingdom_to_empire_transition(), "play Era Transition event:/Music/Transition/era_kingdom_to_empire")
	_check(audio.advance_kingdom_to_empire_suite(0.45, 0.5, false), "advance_kingdom_to_empire_suite orchestration")

	_check(audio.play_empire_age_suite(true, 0.0, 0.5, 0), "start Empire Age suite from Intro (0.0s)")
	_check(audio.set_active_suite_emotion(0.65, 0.8, 0.1, true), "set Empire Tension/War/Ceremony")
	await get_tree().create_timer(0.65).timeout
	var de0: Dictionary = audio.diagnostics()
	_check(bool(de0.get("music_playing", false)) and de0.get("music_key") == &"empire_age_suite", "Empire Age suite playing")
	_check(absf(float(de0.get("tension", -1.0)) - 0.65) < 0.05 and absf(float(de0.get("war", -1.0)) - 0.8) < 0.05
		and absf(float(de0.get("ceremony", -1.0)) - 0.1) < 0.05, "Empire emotion parameters read back")
	_check(int(de0.get("timeline_ms", 0)) > 50 and int(de0.get("timeline_ms", 0)) < 2500,
		"Empire Intro timeline advancing (%d ms)" % int(de0.get("timeline_ms", 0)))

	# Empire population thresholds (4000/3200 and 10000/8500)
	var er0: float = audio.update_empire_age_population_count(1800)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 0 and er0 < 0.20, "Empire Pop 1800 -> Tier 0")
	var er1: float = audio.update_empire_age_population_count(6000)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1 and er1 >= 0.40, "Empire Pop 6000 -> Tier 1")
	audio.update_empire_age_population_count(3500)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 1, "Empire Pop 3500 stays Tier 1 via hysteresis (>=3200)")
	var er2: float = audio.update_empire_age_population_count(12000)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 2 and er2 >= 0.84, "Empire Pop 12000 -> Tier 2")

	# Empire Conditional Loop A (15.0s .. 65.0s) & Full Loop (15.0s .. 165.0s)
	_check(audio.set_empire_age_loop_section(1, true), "select Empire Loop A (15.0s)")
	_check(audio.jump_empire_age_timeline_ms(64600), "jump near end of Empire Loop A (64600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_ea := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_ea >= 15000 and pos_ea < 16700, "Empire Loop A wrapped back to 15.0s (pos=%d ms)" % pos_ea)

	_check(audio.set_empire_age_loop_section(0, false), "select Empire Full Loop ABC (0)")
	_check(audio.jump_empire_age_timeline_ms(164600), "jump near end of Empire Full Suite (164600 ms)")
	await get_tree().create_timer(0.85).timeout
	var pos_ef := int(audio.diagnostics().get("timeline_ms", 0))
	_check(pos_ef >= 15000 and pos_ef < 16700, "Empire Full Loop wrapped from 165.0s to 15.0s (pos=%d ms)" % pos_ef)
	_check(audio.set_empire_age_loop_section(3, true), "select Empire Loop C (15.0s + 100s)")
	_check(audio.jump_empire_age_timeline_ms(115600), "jump near end of Empire Loop C")

	# ==========================================================================
	# PART 3: FORMAL GAMEPLAY set_era(0..3) + Active Suite Population & Zoom
	# ==========================================================================
	audio.stop_music()
	_check(audio.era_index() == -1, "stop_music resets era_index to -1 for fresh game entry")
	_check(audio.set_era(0), "set_era(0) starts Stone Age suite from Intro on initial game entry")
	await get_tree().create_timer(0.35).timeout
	var ds0: Dictionary = audio.diagnostics()
	_check(ds0.get("music_key") == &"stone_age_suite" and int(ds0.get("timeline_ms", 99999)) < 3000,
		"set_era(0) plays stone_age_suite from Intro (%d ms)" % int(ds0.get("timeline_ms", -1)))
	audio.update_active_suite_population_count(950)
	_check(int(audio.diagnostics().get("pop_tier", -1)) == 2, "update_active_suite_population_count(950) -> Stone Tier 2")
	_check(audio.set_active_suite_camera_zoom(0.18, true), "set_active_suite_camera_zoom(0.18)")
	_check(absf(float(audio.diagnostics().get("camera_zoom", 0.5)) - 0.18) < 0.05, "active suite camera_zoom readback ~0.18")

	_check(audio.set_era(1), "set_era(1) advances Stone -> Agrarian with transition and enters main loop")
	await get_tree().create_timer(0.25).timeout
	var da1: Dictionary = audio.diagnostics()
	_check(da1.get("music_key") == &"agrarian_age_suite" and int(da1.get("timeline_ms", 0)) >= 16000,
		"set_era(1) plays agrarian_age_suite main loop (%d ms)" % int(da1.get("timeline_ms", -1)))

	_check(audio.set_era(2), "set_era(2) advances Agrarian -> Kingdom with transition and enters main loop")
	await get_tree().create_timer(0.25).timeout
	var dk2: Dictionary = audio.diagnostics()
	_check(dk2.get("music_key") == &"kingdom_age_suite" and int(dk2.get("timeline_ms", 0)) >= 16000,
		"set_era(2) plays kingdom_age_suite main loop (%d ms)" % int(dk2.get("timeline_ms", -1)))

	_check(audio.set_era(3), "set_era(3) advances Kingdom -> Empire with transition and enters main loop")
	await get_tree().create_timer(0.25).timeout
	var de3: Dictionary = audio.diagnostics()
	_check(de3.get("music_key") == &"empire_age_suite" and int(de3.get("timeline_ms", 0)) >= 15000,
		"set_era(3) plays empire_age_suite main loop (%d ms)" % int(de3.get("timeline_ms", -1)))
	_check(audio.set_active_suite_emotion(0.4, 0.6, 0.7, true), "set active suite emotions after era switch")
	var de4: Dictionary = audio.diagnostics()
	_check(absf(float(de4.get("tension", -1.0)) - 0.4) < 0.05 and absf(float(de4.get("war", -1.0)) - 0.6) < 0.05
		and absf(float(de4.get("ceremony", -1.0)) - 0.7) < 0.05, "active suite emotion readback after era switch")

	var z_far := PlayerController.camera_zoom_to_audio_ratio(0.55, 0.55, 3.6)
	var z_close := PlayerController.camera_zoom_to_audio_ratio(3.6, 0.55, 3.6)
	_check(absf(z_far - 1.0) < 0.01 and absf(z_close - 0.0) < 0.01,
		"PlayerController.camera_zoom_to_audio_ratio maps zoom_min->1.0 and zoom_max->0.0")

	audio.stop_music()
	if settings != null:
		settings.update(before, false)
	print("KINGDOM_AND_EMPIRE_FMOD_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
