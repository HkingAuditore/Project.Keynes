@tool
extends EditorScript

func _run() -> void:
	print("=== DCWorldExt smoke test (write_* API) ===")
	print("class_exists: ", ClassDB.class_exists("DCWorldExt"))
	if not ClassDB.class_exists("DCWorldExt"):
		push_error("DCWorldExt NOT registered — extension load failed silently.")
		return
	var w: Object = ClassDB.instantiate("DCWorldExt")
	print("instance: ", w)

	# F32 single
	var cid_f := int(w.register_component("cell_temp", 0, 1, false))
	w.create_pool("cells", 100)
	w.write_f32(cid_f, 5, 42.0)
	var v_f: PackedFloat32Array = w.view_f32(cid_f)
	print("write_f32 -> view_f32[5] = ", v_f[5], "  (expect 42.0)")
	assert(v_f[5] == 42.0, "write_f32 round-trip failed")

	# I32 single
	var cid_i := int(w.register_component("front_age", 1, 1, false))
	w.write_i32(cid_i, 7, 12345)
	var v_i: PackedInt32Array = w.view_i32(cid_i)
	print("write_i32 -> view_i32[7] = ", v_i[7], "  (expect 12345)")
	assert(v_i[7] == 12345, "write_i32 round-trip failed")

	# U8 single (with 0xFF clamp)
	var cid_u := int(w.register_component("front_kind", 2, 1, false))
	w.write_u8(cid_u, 3, 0x12345)   # high bits should be masked
	var v_u: PackedByteArray = w.view_u8(cid_u)
	print("write_u8(0x12345) -> view_u8[3] = ", v_u[3], "  (expect 69 = 0x45)")
	assert(v_u[3] == 0x45, "write_u8 mask failed")

	# F32 range
	var src := PackedFloat32Array([1.5, 2.5, 3.5, 4.5])
	w.write_f32_range(cid_f, 10, src)
	var v_f2: PackedFloat32Array = w.view_f32(cid_f)
	print("write_f32_range -> view_f32[10..14] = ", v_f2[10], v_f2[11], v_f2[12], v_f2[13])
	assert(v_f2[10] == 1.5 and v_f2[11] == 2.5 and v_f2[12] == 3.5 and v_f2[13] == 4.5,
		"write_f32_range failed")

	# 不应破坏其他位置
	assert(v_f2[5] == 42.0, "write_f32_range leaked outside [10,14)")

	print("=== ALL CHECKS PASSED ===")
