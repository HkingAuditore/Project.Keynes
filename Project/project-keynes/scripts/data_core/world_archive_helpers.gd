extends RefCounted

## Serialization helpers; DCWorld remains the sole state owner.

static func serialize_cells_dict(host) -> Dictionary:
	var out: Dictionary = {}
	# 按 component_schema.gd 自动遍历 production entries（跳过 demo 字段）。
	for e in DCComponentSchema.entries_production():
		var cpp_name: String = String(e.cpp_name)
		var cid: int = host.component_id(e.name)
		if cid < 0:
			continue
		var dt: int = int(e.dtype)
		match dt:
			DCComponentIds.F32:
				out[cpp_name] = host.view_f32(cid)
			DCComponentIds.I32:
				out[cpp_name] = host.view_i32(cid)
			DCComponentIds.U8:
				out[cpp_name] = host.view_u8(cid)
			_:
				push_warning("[DCWorld] serialize: unknown dtype=%d for %s — skipped" % [dt, cpp_name])
	return out


static func deserialize_cells_dict(host, cells: Dictionary) -> void:
	for e in DCComponentSchema.entries_production():
		var cpp_name: String = String(e.cpp_name)
		if not cells.has(cpp_name):
			continue
		var cid: int = host.component_id(e.name)
		if cid < 0:
			continue
		var dt: int = int(e.dtype)
		match dt:
			DCComponentIds.F32:
				var f32: PackedFloat32Array = cells[cpp_name]
				if f32.size() == host._entity_count:
					host.write_f32_range(cid, 0, f32)
			DCComponentIds.I32:
				var i32: PackedInt32Array = cells[cpp_name]
				if i32.size() == host._entity_count:
					host.write_i32_range(cid, 0, i32)
			DCComponentIds.U8:
				var u8: PackedByteArray = cells[cpp_name]
				if u8.size() == host._entity_count:
					host.write_u8_range(cid, 0, u8)


static func serialize_fronts_dict(host) -> Dictionary:
	# Phase 4.1 PR-4.1.2 后扩展：caller 通过 WeatherFront.pack_into_dict 提供
	# 当前 _active_fronts 的 batch dict；DCWorld 把它合并进存档。
	# 当前 phase（仅骨架）：返回空 dict。
	return {}


static func deserialize_fronts_dict(host, _d: Dictionary) -> void:
	# Phase 4.1 PR-4.1.2 后扩展。
	pass
