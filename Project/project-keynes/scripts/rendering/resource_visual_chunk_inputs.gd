extends RefCounted

## First presentation of a chunk waits only for its visible, unknown cells.
## Counts are prepared during the existing camera/restore traversal, never by
## scanning chunk rows per frame. Later changes use normal coalesced dirty work.
var _waiting_cells: Dictionary = {}
var _waiting_chunks: Dictionary = {}

func clear() -> void:
	_waiting_cells.clear()
	_waiting_chunks.clear()

func prepare_view(map: MapData, near_cells: Array[int], cell_chunks: Array[Vector2i],
		rows: Dictionary, fog: bool) -> PackedInt32Array:
	clear()
	var unknown := PackedInt32Array()
	for cell in near_cells:
		if rows.has(cell):
			continue
		unknown.append(cell)
		if fog and (cell >= map.visible_arr.size() or map.visible_arr[cell] == 0):
			continue
		var key := cell_chunks[cell]
		_waiting_cells[cell] = key
		_waiting_chunks[key] = int(_waiting_chunks.get(key, 0)) + 1
	return unknown

func complete(cell: int) -> void:
	if not _waiting_cells.has(cell):
		return
	var key: Vector2i = _waiting_cells[cell]
	_waiting_cells.erase(cell)
	var remaining := int(_waiting_chunks[key]) - 1
	if remaining == 0:
		_waiting_chunks.erase(key)
	else:
		_waiting_chunks[key] = remaining

func ready(key: Vector2i) -> bool:
	return not _waiting_chunks.has(key)

func pending_cells() -> int:
	return _waiting_cells.size()
