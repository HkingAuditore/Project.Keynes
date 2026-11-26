extends RefCounted

# Accesses the attached columns while retaining the cell's local fallback.


static func read_f32(cell: Variant, slot: int, fallback: float,
		requires_native_slot: bool) -> float:
	if cell._facade_enabled:
		var cid: int = cell._cid_array[slot]
		if cid >= 0:
			if cell._world_ext != null and (not requires_native_slot or cell._cid_array_ext[slot] >= 0):
				return cell._world_ext.read_f32(cell._cid_array_ext[slot], cell.index)
			return cell._world.read_f32(cid, cell.index)
	return fallback

static func write_f32(cell: Variant, slot: int, value: float) -> void:
	if cell._facade_enabled:
		var cid: int = cell._cid_array[slot]
		if cid >= 0:
			cell._world.write_f32(cid, cell.index, value)


static func read_i32(cell: Variant, slot: int, fallback: int,
		requires_native_slot: bool) -> int:
	if cell._facade_enabled:
		var cid: int = cell._cid_array[slot]
		if cid >= 0:
			if cell._world_ext != null and (not requires_native_slot or cell._cid_array_ext[slot] >= 0):
				return cell._world_ext.read_i32(cell._cid_array_ext[slot], cell.index)
			return cell._world.read_i32(cid, cell.index)
	return fallback

static func write_i32(cell: Variant, slot: int, value: int) -> void:
	if cell._facade_enabled:
		var cid: int = cell._cid_array[slot]
		if cid >= 0:
			cell._world.write_i32(cid, cell.index, value)


static func read_u8(cell: Variant, slot: int, fallback: int,
		requires_native_slot: bool) -> int:
	if cell._facade_enabled:
		var cid: int = cell._cid_array[slot]
		if cid >= 0:
			if cell._world_ext != null and (not requires_native_slot or cell._cid_array_ext[slot] >= 0):
				return cell._world_ext.read_u8(cell._cid_array_ext[slot], cell.index)
			return cell._world.read_u8(cid, cell.index)
	return fallback

static func write_u8(cell: Variant, slot: int, value: int) -> void:
	if cell._facade_enabled:
		var cid: int = cell._cid_array[slot]
		if cid >= 0:
			cell._world.write_u8(cid, cell.index, value)
