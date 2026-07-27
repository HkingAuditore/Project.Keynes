extends Node

signal request_changed(kind: String)

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const PLAYER_GAME_SCENE := "res://scenes/player_game.tscn"

var _pending_request: Dictionary = {}
var _session: Dictionary = {}


func _ready() -> void:
	if OS.get_environment("PK_GAME_SAVE_ROUNDTRIP_TEST") == "1":
		var runner_script = load("res://tests/game_save_roundtrip_test.gd")
		if runner_script != null:
			var runner: Node = runner_script.new() as Node
			get_tree().root.call_deferred("add_child", runner)


func begin_new_game(config: NewGameConfig) -> Dictionary:
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
	var error := get_tree().change_scene_to_file(PLAYER_GAME_SCENE)
	if error != OK:
		_pending_request.clear()
		return _result(false, "scene_change_failed", "无法进入游戏场景。")
	return _result(true, "ok", "")


func begin_load_game(slot_id: String) -> Dictionary:
	if slot_id not in ["manual_1", "manual_2", "manual_3", "autosave"]:
		return _result(false, "slot_invalid", "存档槽位无效。")
	_pending_request = {"kind": "load_game", "slot_id": slot_id}
	request_changed.emit("load_game")
	var error := get_tree().change_scene_to_file(PLAYER_GAME_SCENE)
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
	_pending_request.clear()
	_session.clear()
	var error := get_tree().change_scene_to_file(MAIN_MENU_SCENE)
	return _result(error == OK, "ok" if error == OK else "scene_change_failed",
		"" if error == OK else "无法返回主菜单。")


func quit_game() -> void:
	get_tree().quit()


static func _result(ok: bool, code: String, message: String) -> Dictionary:
	return {"ok": ok, "code": code, "message": message}
