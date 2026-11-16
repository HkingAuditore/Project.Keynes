extends RefCounted

## Notification-only queue. Publication never reads a half-written MapData batch.
## Full publications merge in O(1); a new publication cannot restart an active
## sweep and starve its tail. Sparse cells and the full sweep share progress.
const BANDS := 1
const CLIMATE := 2
const GEOMETRY := 4
const ALL := BANDS | CLIMATE | GEOMETRY

var _count := 0
var _cells: Array[int] = []
var _flags: Dictionary = {}
var _head := 0
var _cursor := 0
var _full_flags := 0
var _next_flags := 0
var _turn := 0

func configure(count: int) -> void:
	_count = count
	_cells.clear()
	_flags.clear()
	_head = 0
	_cursor = 0
	_full_flags = 0
	_next_flags = 0
	_turn = 0

func request(flags: int, cells: PackedInt32Array = PackedInt32Array()) -> void:
	flags &= ALL
	if flags == 0 or _count <= 0:
		return
	if cells.is_empty():
		if _full_flags == 0 or _cursor == 0:
			_full_flags |= flags
		else:
			_next_flags |= flags
		return
	for cell in cells:
		if cell < 0 or cell >= _count:
			continue
		if not _flags.has(cell):
			_cells.append(cell)
		_flags[cell] = int(_flags.get(cell, 0)) | flags

func take() -> Vector2i:
	var sparse := _head < _cells.size()
	_turn += 1
	if sparse and (_full_flags == 0 or _turn % 4 != 0):
		var cell := _cells[_head]
		_head += 1
		var flags := int(_flags[cell])
		_flags.erase(cell)
		if _head == _cells.size():
			_cells.clear()
			_head = 0
		elif _head >= 256 and _head * 2 >= _cells.size():
			# Repeated sparse updates may keep the queue nonempty indefinitely.
			# Amortized compaction bounds retained consumed entries as well.
			_cells = _cells.slice(_head)
			_head = 0
		return Vector2i(cell, flags)
	if _full_flags != 0 and _cursor < _count:
		var task := Vector2i(_cursor, _full_flags)
		_cursor += 1
		if _cursor == _count:
			_cursor = 0
			_full_flags = _next_flags
			_next_flags = 0
		return task
	return Vector2i(-1, 0)

func pending() -> bool:
	return _head < _cells.size() or (_full_flags != 0 and _count > 0)

func diagnostics() -> Dictionary:
	return {"pending_observation_cells": _flags.size(),
		"observation_sweep_cursor": _cursor,
		"observation_sweep_pending": _full_flags != 0,
		"observation_resweep_pending": _next_flags != 0}
