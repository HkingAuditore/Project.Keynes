extends RefCounted


static func sync_is_water_arr_from_terrain(owner: Variant) -> void:
	var n: int = mini(owner.terrain_arr.size(), owner.is_water_arr.size())
	var lut: PackedByteArray = MapData.is_water_lut()
	for i in range(n):
		owner.is_water_arr[i] = lut[int(owner.terrain_arr[i])]


static func sync_runtime_terrain_facade_from_soa(owner: Variant) -> int:
	var n: int = mini(owner._cell_array.size(), owner.terrain_arr.size())
	var changed: int = 0
	var lut: PackedByteArray = MapData.is_water_lut()
	for i in range(n):
		var terrain_byte: int = int(owner.terrain_arr[i]) & 0xFF
		if i < owner.is_water_arr.size():
			owner.is_water_arr[i] = lut[terrain_byte]
		var cell: HexCell = owner._cell_array[i]
		if cell != null and int(cell.terrain) != terrain_byte:
			cell.apply_terrain(terrain_byte)
			changed += 1
	return changed


static func set_runtime_terrain(owner: Variant, idx: int, terrain_id: int, sync_cell: bool = true) -> void:
	if idx < 0 or idx >= owner._cell_array.size():
		return
	var terrain_byte: int = terrain_id & 0xFF
	if idx < owner.terrain_arr.size():
		owner.terrain_arr[idx] = terrain_byte
	if idx < owner.is_water_arr.size():
		owner.is_water_arr[idx] = MapData.terrain_is_water_u8(terrain_byte)
	if sync_cell:
		var cell: HexCell = owner.cell_at(idx)
		if cell != null:
			cell.apply_terrain(terrain_byte)
