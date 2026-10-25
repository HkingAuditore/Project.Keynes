extends Node

var _failed := false


func _ready() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	print("[loading-music-test] ", "PASS " if ok else "FAIL ", message)
	_failed = _failed or not ok


func _run() -> void:
	var audio := get_node("/root/GameAudio")
	_check(audio.status == "ready", "FMOD backend ready")
	if audio.status != "ready":
		get_tree().quit(1)
		return
	# 使用真实菜单生命周期，覆盖旧菜单移除后、世界就绪前的加载空窗。
	var menu := load("res://scenes/main_menu.tscn").instantiate() as Control
	add_child(menu)
	await get_tree().create_timer(0.8).timeout
	var instance: int = audio.get("_music")
	_check(instance != 0, "menu started music")
	var overlay := load("res://scenes/ui/world_loading_overlay.tscn").instantiate() as WorldLoadingOverlay
	add_child(overlay)
	overlay.show_message("正在创建世界")
	menu.queue_free()
	await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	var before: Dictionary = audio.diagnostics()
	_check(int(audio.get("_music")) == instance, "menu removal preserves music instance")
	await get_tree().create_timer(1.0).timeout
	var during: Dictionary = audio.diagnostics()
	_check(bool(during.get("music_playing", false)), "music remains active during loading")
	_check(int(during.get("timeline_ms", 0)) > int(before.get("timeline_ms", 0)) + 400,
		"FMOD timeline advances while loading overlay is visible")
	_check(audio.set_era(0), "world-ready era music takes over")
	_check(int(audio.get("_music")) == instance, "Stone Age handoff reuses menu suite")
	await get_tree().create_timer(0.3).timeout
	var after_handoff: Dictionary = audio.diagnostics()
	_check(int(after_handoff.get("timeline_ms", 0)) >= int(during.get("timeline_ms", 0)),
		"world-ready handoff preserves timeline instead of restarting intro")
	_check(audio.set_era(2), "loaded Kingdom-era save switches suite")
	await get_tree().create_timer(0.4).timeout
	_check(audio.diagnostics().get("music_key") == &"kingdom_age_suite", "Kingdom suite active")
	overlay.queue_free()
	audio.stop_music()
	print("LOADING_MUSIC_CONTINUITY_TEST_OK=", not _failed)
	get_tree().quit(1 if _failed else 0)
