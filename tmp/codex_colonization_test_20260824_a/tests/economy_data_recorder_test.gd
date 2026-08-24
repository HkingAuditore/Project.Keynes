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
	quit(0 if _failures == 0 else 1)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] %s" % label)
	else:
		push_error("  [FAIL] %s" % label)
		_failures += 1
