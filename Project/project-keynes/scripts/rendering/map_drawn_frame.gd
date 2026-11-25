extends RefCounted

## Records the map that was drawn, independently of the next simulation batch.
## Vision arrays in a staged revision are immutable even if MapData is patched.
var valid := false
var day := -1
var transform := Transform2D.IDENTITY
var logical_size := Vector2.ZERO
var vision_revision := -1
var visible := PackedByteArray()
var explored := PackedByteArray()

var received_day := -1
var staged_day := -1
var staged_revision := -1
var staged_visible := PackedByteArray()
var staged_explored := PackedByteArray()
var _submitted_day := -1
var _submitted_revision := -1
var _submitted_visible := PackedByteArray()
var _submitted_explored := PackedByteArray()
var _submitted_transform := Transform2D.IDENTITY
var _submitted_size := Vector2.ZERO


func stage_vision(revision: int, visible_cells: PackedByteArray, explored_cells: PackedByteArray) -> void:
	if revision == staged_revision:
		return
	staged_revision = revision
	staged_visible = visible_cells.duplicate()
	staged_explored = explored_cells.duplicate()


func submit(camera_transform: Transform2D, view_size: Vector2) -> void:
	_submitted_day = staged_day
	_submitted_revision = staged_revision
	_submitted_visible = staged_visible
	_submitted_explored = staged_explored
	_submitted_transform = camera_transform
	_submitted_size = view_size


func present() -> bool:
	var changed := not valid or day != _submitted_day or vision_revision != _submitted_revision
	valid = true
	day = _submitted_day
	transform = _submitted_transform
	logical_size = _submitted_size
	vision_revision = _submitted_revision
	visible = _submitted_visible
	explored = _submitted_explored
	return changed


func fields_current(current_vision_revision: int) -> bool:
	return valid and day == received_day and vision_revision == current_vision_revision


func screen_transform(current_size: Vector2) -> Transform2D:
	# The window stretches its last map texture when resized between map draws.
	return transform.scaled(current_size / logical_size)
