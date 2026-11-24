# economy_data_recorder_test.gd
#
# Headless execution:
#     godot --headless --script tests/economy_data_recorder_test.gd --quit

extends SceneTree


var _failures: int = 0


func _init() -> void:
	_expect(EconomyDataRecorder._array_size([1, 2]) == 2, "ordinary Array size")
	_expect(EconomyDataRecorder._array_size(PackedInt64Array([3, 4])) == 2,
		"PackedInt64Array size")
	_expect(EconomyDataRecorder._arr_i(PackedInt32Array([7]), 0) == 7,
		"packed numeric value")
	_expect(str(EconomyDataRecorder._arr_i(PackedStringArray(["grain"]), 0)) == "grain",
		"packed stable string id")
	_expect(EconomyDataRecorder._arr_i(PackedInt32Array(), 0) == 0,
		"empty packed array fallback")
	_test_start_resolves_resource_slots_from_world_ext()
	quit(0 if _failures == 0 else 1)


class _MockCell extends RefCounted:
	var index: int = 0
	var q: int = 1
	var r: int = -1
	var s: int = 0


class _MockMap extends RefCounted:
	var _cell := _MockCell.new()
	func cell_count() -> int:
		return 1
	func cell_at(_idx: int):
		return _cell


class _MockWorldExt extends RefCounted:
	func component_id(slot_name: String) -> int:
		if slot_name == "cell_res_timber_reserve":
			return 42
		if slot_name == "cell_res_iron_ore_reserve":
			return 77
		return -1


class _MockEconomyFacade extends RefCounted:
	var last_config: Dictionary = {}
	func start_csv_recording(config: Dictionary) -> Dictionary:
		last_config = config.duplicate(true)
		return {"ok": true, "state": "recording", "recording": true, "sampled_cell_count": 1, "paths": []}
	func request_stop_csv_recording() -> Dictionary:
		return {"state": "completed", "recording": false, "paths": []}
	func csv_recording_status() -> Dictionary:
		return {"state": "recording", "recording": true, "paths": []}


class _MockGenerator extends RefCounted:
	var world_ext := _MockWorldExt.new()
	var economy_facade := _MockEconomyFacade.new()
	func get_data_core_world_ext():
		return world_ext
	func get_economy_facade():
		return economy_facade


class _MockMain extends RefCounted:
	var generator := _MockGenerator.new()
	var map := _MockMap.new()
	func get_generator():
		return generator
	func get_current_map():
		return map
	func get_selected_cell():
		return map.cell_at(0)


func _test_start_resolves_resource_slots_from_world_ext() -> void:
	var main := _MockMain.new()
	var recorder := EconomyDataRecorder.new()
	recorder.bind_main(main)
	recorder.start()
	var cfg: Dictionary = main.generator.economy_facade.last_config
	var slot_ids: PackedInt32Array = cfg.get("resource_slot_ids", PackedInt32Array())
	var res_ids: PackedStringArray = cfg.get("resource_ids", PackedStringArray())
	_expect(recorder.is_recording(), "recorder enters recording state via EconomyFacade")
	_expect(slot_ids == PackedInt32Array([42, 77]),
		"resource_slot_ids resolved from DCWorldExt.component_id")
	_expect(res_ids == PackedStringArray(["timber", "iron_ore"]),
		"resource_ids paired with resolved slot ids")
	recorder.stop_and_export()
	_expect(not recorder.is_recording(), "recorder stops cleanly via EconomyFacade")


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
