extends RefCounted

## Builds shared world geometry, horizon and seasonal vegetation lookup assets; accepts existing material publication callbacks.

static func _build_world_quad_mesh(bounds: Rect2, wrap_period_x: float = 0.0) -> Mesh:
	var p := bounds.position
	var s := bounds.size
	if wrap_period_x > 0.0001:
		p.x = 0.0
		s.x = wrap_period_x
	var verts := PackedVector2Array()
	var indices := PackedInt32Array()
	var tile_offsets := PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		tile_offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	for ox in tile_offsets:
		var base := verts.size()
		var tp := p + Vector2(float(ox), 0.0)
		verts.append(tp)
		verts.append(tp + Vector2(s.x, 0.0))
		verts.append(tp + s)
		verts.append(tp + Vector2(0.0, s.y))
		indices.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func build_gi_horizon_lut(max_angle: float) -> PackedVector3Array:
	var lut := PackedVector3Array()
	lut.resize(16)
	for i in range(16):
		var h: float = float(i) / 15.0 * max_angle
		var m: float = (h + PI * 0.5) * 0.5
		var c: float = cos(h)
		lut[i] = Vector3(c * c, cos(m), sin(m))
	return lut


static func _push_vegetation_season_lut(_shader_mat: ShaderMaterial, _push_world_uniform: Callable) -> void:
	if _shader_mat == null:
		return
	const VEG_COUNT := 28
	var lut := PackedVector4Array()
	lut.resize(VEG_COUNT * 4)
	var shifts := PackedVector4Array()
	shifts.resize(VEG_COUNT)
	for veg in range(VEG_COUNT):
		var profile: VegetationProfile = VegetationProfileRegistry.get_profile(veg)
		if profile == null:
			# 未知 veg → 写中性白 / 零偏移，避免 shader 拿到未初始化数据。
			for s in range(4):
				lut[veg * 4 + s] = Vector4(1.0, 1.0, 1.0, 1.0)
			shifts[veg] = Vector4(0.0, 0.0, 0.0, 0.0)
			continue
		var profile_lut := profile.season_color_lut
		for s in range(4):
			if profile_lut != null and s < profile_lut.size():
				var c: Color = profile_lut[s]
				lut[veg * 4 + s] = Vector4(c.r, c.g, c.b, c.a)
			else:
				lut[veg * 4 + s] = Vector4(1.0, 1.0, 1.0, 1.0)
		var shift: Color = profile.anomaly_color_shift
		shifts[veg] = Vector4(shift.r, shift.g, shift.b, shift.a)
	_push_world_uniform.call("vegetation_season_lut", lut)
	_push_world_uniform.call("vegetation_anomaly_shift", shifts)
