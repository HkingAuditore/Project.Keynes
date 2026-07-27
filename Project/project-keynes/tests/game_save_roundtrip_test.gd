extends Node

var _failures := PackedStringArray()
var _game_flow: Node
var _game_save: Node


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_game_flow = get_tree().root.get_node_or_null("GameFlow")
	_game_save = get_tree().root.get_node_or_null("GameSave")
	_expect("game flow autoload is available", _game_flow != null)
	_expect("game save autoload is available", _game_save != null)
	if _game_flow == null or _game_save == null:
		_finish()
		return
	var config := NewGameConfig.new()
	config.country.name = "Roundtrip Nation"
	config.base.map_width = 40
	config.base.map_height = 28
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	var previous_scene := get_tree().current_scene
	var begin: Dictionary = _game_flow.call("begin_new_game", config)
	_expect("new game request accepted", bool(begin.get("ok", false)))
	var first_host: WorldRuntimeHost = await _wait_for_runtime(previous_scene)
	_expect("new game reached ready runtime", first_host != null)
	if first_host == null:
		_finish()
		return

	var first_scene := first_host.get_parent() as PlayerGame
	var first_clock: WorldClock = first_scene.get_node("WorldClock")
	first_clock.speed_multiplier = 0.0
	first_clock.pause(false)
	var expected := _capture_hashes(first_host, first_clock)
	var save_result: Dictionary = await _game_save.call("request_manual_save", "manual_3")
	_expect("PKSV manual save completed", bool(save_result.get("ok", false)))
	var slots: Array = _game_save.call("list_slots")
	var slot := _slot(slots, "manual_3")
	_expect("saved slot is visible and loadable",
		bool(slot.get("exists", false)) and bool(slot.get("loadable", false)))
	_expect("save restores request-time pause state",
		not first_clock.paused and is_zero_approx(first_clock.speed_multiplier))
	if not bool(save_result.get("ok", false)):
		_finish()
		return

	var load_begin: Dictionary = _game_flow.call("begin_load_game", "manual_3")
	_expect("load request accepted", bool(load_begin.get("ok", false)))
	var loaded_host: WorldRuntimeHost = await _wait_for_runtime(first_scene)
	_expect("load reached ready runtime", loaded_host != null)
	if loaded_host != null:
		var loaded_scene := loaded_host.get_parent() as PlayerGame
		var loaded_clock: WorldClock = loaded_scene.get_node("WorldClock")
		var loaded_generator := loaded_host.generator()
		_expect("load finalized restore-only country/economy bootstrap",
			String(loaded_generator.gameplay_start_report().get(
				"settlement_source", "")) == "save_restore")
		_expect("restored native authorities are bootstrapped",
			bool(loaded_generator.get_country_report().get("bootstrapped", false))
			and bool(loaded_generator.get_economy_report().get("bootstrapped", false)))
		var actual := _capture_hashes(loaded_host, loaded_clock)
		for key in expected:
			_expect("round-trip hash %s" % key, str(actual.get(key, "")) == str(expected[key]))
		_expect("loaded clock retains unpaused zero-speed mode",
			not loaded_clock.paused and is_zero_approx(loaded_clock.speed_multiplier))
	_finish()


func _wait_for_runtime(previous_scene) -> WorldRuntimeHost:
	for _frame in range(2400):
		await get_tree().process_frame
		var scene_ref := get_tree().current_scene
		if scene_ref == null or scene_ref == previous_scene or not scene_ref is PlayerGame:
			continue
		var host := scene_ref.get_node_or_null("RuntimeHost") as WorldRuntimeHost
		if host != null and host.current_map() != null and host.generator() != null \
				and bool(host.generator().gameplay_start_report().get("ok", false)):
			await get_tree().process_frame
			return host
	return null


func _capture_hashes(host: WorldRuntimeHost, clock: WorldClock) -> Dictionary:
	var generator := host.generator()
	var hashes := {}
	hashes.clock = _hash_variant(clock.export_state())
	hashes.dynamic_world = _hash_variant(generator.get_data_core_world().serialize())
	hashes.environment = _hash_variant(generator.export_environment_runtime_state())
	hashes.country = str(generator.get_country_facade().report().get("state_hash", ""))
	hashes.economy = str(generator.get_economy_facade().report().get("state_hash", ""))
	hashes.session = _hash_variant(_game_flow.call("session"))
	# PKFG：cell_explored 是单调累积的玩家进度，重算不回来，必须逐字节对上。
	hashes.explored = _hash_variant(host.current_map().explored_arr)
	return hashes


func _hash_variant(value) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


func _slot(slots: Array, slot_id: String) -> Dictionary:
	for value in slots:
		if String((value as Dictionary).get("slot_id", "")) == slot_id:
			return value
	return {}


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _finish() -> void:
	print("game save round-trip: %d failures" % _failures.size())
	get_tree().quit(0 if _failures.is_empty() else 1)
