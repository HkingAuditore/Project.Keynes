extends Node

signal request_changed(kind: String)

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const PLAYER_GAME_SCENE := "res://scenes/player_game.tscn"

var _pending_request: Dictionary = {}
var _session: Dictionary = {}
var _transition_id := 0
var _transition_active := false
var _transition_layer: CanvasLayer


func _ready() -> void:
	_attach_headless_runner("PK_GAME_SAVE_ROUNDTRIP_TEST",
		"res://tests/game/game_save_roundtrip_test.gd")
	# 存档回放复现入口。见 tests/headless_save_replay.gd 与
	# tools/runtime/Invoke-SaveReplay.ps1。
	_attach_headless_runner("PK_SAVE_REPLAY",
		"res://tests/game/headless_save_replay.gd")
	_attach_headless_runner("PK_FAMILY_PROBE",
		"res://tests/family/family_economy_probe.gd")
	_attach_headless_runner("PK_COLONIZATION_PROBE",
		"res://tests/country/colonization_probe.gd")
	# 新开局日历冻结的复现入口：走真实 begin_new_game + 泵帧，见
	# tests/probes/_tmp_autoplay.gd（PK_AUTOPLAY_PROBE=1）。
	_attach_headless_runner("PK_AUTOPLAY_PROBE",
		"res://tests/probes/_tmp_autoplay.gd")


func _attach_headless_runner(env_name: String, script_path: String) -> void:
	if OS.get_environment(env_name) != "1":
		return
	var runner_script = load(script_path)
	if runner_script == null:
		push_error("[game-flow] headless runner missing: %s" % script_path)
		return
	get_tree().root.call_deferred("add_child", runner_script.new() as Node)


func begin_new_game(config: NewGameConfig) -> Dictionary:
	if _transition_active:
		return _result(false,"transition_pending","正在准备游戏。")
	if config == null:
		return _result(false, "new_game_config_missing", "缺少新游戏配置。")
	var validation := config.validate()
	if not bool(validation.get("ok", false)):
		return validation
	_pending_request = {
		"kind": "new_game",
		"config": config.to_dictionary(),
	}
	request_changed.emit("new_game")
	var error := _queue_player_scene()
	if error != OK:
		_pending_request.clear()
		return _result(false, "scene_change_failed", "无法进入游戏场景。")
	return _result(true, "ok", "")


func begin_load_game(slot_id: String) -> Dictionary:
	if _transition_active:
		return _result(false,"transition_pending","正在准备游戏。")
	if slot_id not in ["manual_1", "manual_2", "manual_3", "autosave"]:
		return _result(false, "slot_invalid", "存档槽位无效。")
	_pending_request = {"kind": "load_game", "slot_id": slot_id}
	request_changed.emit("load_game")
	var error := _queue_player_scene()
	if error != OK:
		_pending_request.clear()
		return _result(false, "scene_change_failed", "无法进入游戏场景。")
	return _result(true, "ok", "")


func peek_request() -> Dictionary:
	return _pending_request.duplicate(true)


func consume_request() -> Dictionary:
	var request := _pending_request.duplicate(true)
	_pending_request.clear()
	request_changed.emit("")
	return request


func set_session(context: Dictionary) -> void:
	_session = context.duplicate(true)


func session() -> Dictionary:
	return _session.duplicate(true)


func clear_session() -> void:
	_session.clear()


func return_to_main_menu() -> Dictionary:
	_transition_id += 1
	_transition_active = false
	if is_instance_valid(_transition_layer):
		_transition_layer.queue_free()
	_pending_request.clear()
	_session.clear()
	var error := get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	return _result(error == OK, "ok" if error == OK else "scene_change_failed",
		"" if error == OK else "无法返回主菜单。")


func _queue_player_scene() -> Error:
	var overlay_scene := load("res://scenes/ui/world_loading_overlay.tscn") as PackedScene
	if overlay_scene == null:
		return ERR_CANT_OPEN
	var error := ResourceLoader.load_threaded_request(PLAYER_GAME_SCENE,"PackedScene")
	if error != OK:
		return error
	_transition_active = true
	_transition_id += 1
	_transition_layer = CanvasLayer.new()
	_transition_layer.layer = 100
	get_tree().root.add_child(_transition_layer)
	var overlay := overlay_scene.instantiate() as WorldLoadingOverlay
	_transition_layer.add_child(overlay)
	overlay.show_message("正在创建世界")
	overlay.set_layout_state((_pending_request.get("config",{}) as Dictionary).get("base",{}))
	overlay.return_requested.connect(return_to_main_menu)
	overlay.retry_requested.connect(func() -> void:
		if is_instance_valid(_transition_layer):_transition_layer.queue_free()
		_queue_player_scene())
	call_deferred("_finish_player_scene_transition",_transition_id,overlay)
	return OK


func _finish_player_scene_transition(id: int, overlay: WorldLoadingOverlay) -> void:
	await get_tree().process_frame
	var load_progress: Array = []
	while id==_transition_id and ResourceLoader.load_threaded_get_status(PLAYER_GAME_SCENE, load_progress)==ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		var stage_frac := float(load_progress[0]) if not load_progress.is_empty() else 0.0
		overlay.set_progress("preparing", clampf(stage_frac * 0.12, 0.02, 0.12))
		await get_tree().process_frame
	if id!=_transition_id:return
	if ResourceLoader.load_threaded_get_status(PLAYER_GAME_SCENE)!=ResourceLoader.THREAD_LOAD_LOADED:
		overlay.show_failure("游戏场景载入失败。")
		_transition_active = false
		return
	overlay.set_progress("preparing", 0.15)
	var ext: RefCounted = ClassDB.instantiate("DCWorldExt")
	await LoadingCatalogCache.prepare(ext)
	if id!=_transition_id:return
	var scene := ResourceLoader.load_threaded_get(PLAYER_GAME_SCENE) as PackedScene
	var error := get_tree().change_scene_to_packed(scene)
	if error != OK:
		overlay.show_failure("无法进入游戏场景。")
		_transition_active = false
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if id==_transition_id and is_instance_valid(_transition_layer):
		_transition_layer.queue_free()
	_transition_active = false


func quit_game() -> void:
	get_tree().quit()


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}
