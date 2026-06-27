extends SceneTree

# Headless:
#   godot --headless --script tests/bake_encoder_cpp_parity_test.gd --quit

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== bake encoder C++ parity smoke ===")
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip("DCWorldExt instantiate returned null")
		return
	_expect("height encoder exported", ext.has_method("encode_bake_height_tex_data"))
	_expect("r8 encoder exported", ext.has_method("encode_bake_r8_tex_data"))
	_expect("flow encoder exported", ext.has_method("encode_bake_flow_tex_data"))
	_expect("enum encoder exported", ext.has_method("encode_bake_enum_atlas_payload"))
	if _failures > 0:
		_finish()
		return
	_test_height_rg8(ext)
	_test_r8_default(ext)
	_test_flow_l8(ext)
	_test_enum_rgba(ext)
	_finish()


func _test_height_rg8(ext: Object) -> void:
	var src := PackedFloat32Array([0.0, 0.5, 1.0, 1.2])
	var ret: Dictionary = ext.call("encode_bake_height_tex_data", {
		"buffer": src,
		"width": 2,
		"height": 2,
	})
	_expect("height path is native", not bool(ret.get("fallback", true)))
	_expect_bytes("height RG8 bytes", ret.get("data", PackedByteArray()),
		PackedByteArray([0, 0, 128, 0, 255, 255, 255, 255]))


func _test_r8_default(ext: Object) -> void:
	var ret: Dictionary = ext.call("encode_bake_r8_tex_data", {
		"buffer": PackedByteArray([1, 2]),
		"width": 2,
		"height": 2,
		"default_byte": 7,
	})
	_expect("r8 short input still native", not bool(ret.get("fallback", true)))
	_expect_bytes("r8 default fill", ret.get("data", PackedByteArray()),
		PackedByteArray([7, 7, 7, 7]))


func _test_flow_l8(ext: Object) -> void:
	var src := PackedFloat32Array([0.0, 0.5, 1.0, -1.0])
	var ret: Dictionary = ext.call("encode_bake_flow_tex_data", {
		"buffer": src,
		"width": 2,
		"height": 2,
	})
	_expect("flow path is native", not bool(ret.get("fallback", true)))
	_expect_bytes("flow L8 bytes", ret.get("data", PackedByteArray()),
		PackedByteArray([0, 128, 255, 0]))


func _test_enum_rgba(ext: Object) -> void:
	var ret: Dictionary = ext.call("encode_bake_enum_atlas_payload", {
		"biome_buffer": PackedByteArray([4, 5, 6]),
		"width": 3,
		"height": 1,
		"n_cells": 2,
		"cell_first_px": PackedInt32Array([0, 2]),
		"cell_px_count": PackedInt32Array([2, 1]),
		"flat_px_indices": PackedInt32Array([0, 2, 1]),
		"landform_by_cell": PackedByteArray([9, 10]),
	})
	_expect("enum path is native", not bool(ret.get("fallback", true)))
	_expect_bytes("enum RGBA bytes", ret.get("data", PackedByteArray()),
		PackedByteArray([4, 0, 0, 9, 5, 1, 0, 10, 6, 0, 0, 9]))


func _expect(name: String, cond: bool) -> void:
	_checks += 1
	if cond:
		print("  [PASS] %s" % name)
	else:
		push_error("  [FAIL] %s" % name)
		_failures += 1


func _expect_bytes(name: String, got: PackedByteArray, expected: PackedByteArray) -> void:
	var ok := got.size() == expected.size()
	if ok:
		for i in range(expected.size()):
			if got[i] != expected[i]:
				ok = false
				break

	_expect(name, ok)
	if not ok:
		print("    got=%s expected=%s" % [str(got), str(expected)])



func _skip(reason: String) -> void:
	print("  [SKIP] %s" % reason)
	_finish()


func _finish() -> void:
	print("=== bake encoder C++ parity summary: %d checks, %d failures ===" % [_checks, _failures])
