extends RefCounted

## Only the latest published fields are needed to draw. Preserve the union of
## changed cells until that update is installed, including changes since a hold.
const DIRTY := "display_dirty_cells"
const CLASSES := "display_class_cells"
const CELLS := "cell_lut_frame"
const MAX_DRAW_SPACING := 4
const DRAWS_TO_RECOVER := 3
const INITIAL_UPDATE_USEC := 2000

var _latest: Dictionary = {}
var _held_dirty: Dictionary = {}
var _held_classes: Dictionary = {}
var _full_update := false
var needs_recovery := false

var _frame_started_usec := 0
var _last_draw_usec := 0
var _fps := 0
var _draw_spacing := 1
var _timely_draws := 0
var _last_update_frame := -1
var _update_usec := INITIAL_UPDATE_USEC


func queue(commit: Dictionary) -> bool:
	if commit.is_empty():
		return false
	if has_pending():
		_add_cells(_held_dirty, _latest.get(DIRTY, PackedInt32Array()))
		_add_cells(_held_classes, _latest[CLASSES])
	_full_update = _full_update or not commit.has(DIRTY)
	var dirty: PackedInt32Array = commit.get(DIRTY, PackedInt32Array())
	_latest = {DIRTY: dirty, CLASSES: commit.get(CLASSES, dirty)}
	if commit.get("map_lut_pending", false):
		_latest["map_lut_day"] = commit.committed_day
		_latest["map_lut_generation"] = commit.generation
	elif commit.has(CELLS):
		_latest[CELLS] = commit[CELLS]
	return true


func has_pending() -> bool:
	return not _latest.is_empty()


func collect(vision_dirty: PackedInt32Array) -> Dictionary:
	var update := _latest.duplicate(false)
	if _full_update:
		update.erase(DIRTY)
	else:
		update[DIRTY] = _collect_cells(_held_dirty, _latest[DIRTY], vision_dirty)
	update[CLASSES] = _collect_cells(_held_classes, _latest[CLASSES], vision_dirty)
	return update


func _collect_cells(held: Dictionary, latest: PackedInt32Array,
		extra: PackedInt32Array) -> PackedInt32Array:
	if held.is_empty() and extra.is_empty():
		return latest
	_add_cells(held, latest)
	_add_cells(held, extra)
	return PackedInt32Array(held.keys())


func _add_cells(held: Dictionary, cells: PackedInt32Array) -> void:
	for cell in cells:
		held[cell] = true


func _clear_pending() -> void:
	_latest.clear()
	_held_dirty.clear()
	_held_classes.clear()
	_full_update = false
	needs_recovery = false


func start_frame(usec: int) -> void:
	_frame_started_usec = usec


func observe_draw(usec: int, fps: int) -> void:
	var budget := _frame_budget_usec(fps)
	var prior := _last_draw_usec
	_last_draw_usec = usec
	if budget == 0 or prior == 0:
		return
	# Vsync and timer jitter may make a draw slightly longer than the target.
	if usec - prior > budget * 1.1:
		_draw_spacing = mini(MAX_DRAW_SPACING, _draw_spacing + 1)
		_timely_draws = 0
	else:
		_timely_draws += 1
		if _timely_draws == DRAWS_TO_RECOVER:
			_draw_spacing = maxi(1, _draw_spacing - 1)
			_timely_draws = 0


func can_apply(frame: int, usec: int, fps: int) -> bool:
	var budget := _frame_budget_usec(fps)
	if budget == 0 or _frame_started_usec == 0:
		return true
	if _last_update_frame >= 0 and frame - _last_update_frame < _draw_spacing:
		return false
	# A past expensive update can lower cadence, but its estimate must not
	# prevent all future updates even on an otherwise empty frame.
	var update_usec := minf(_update_usec, budget * 0.5)
	return usec - _frame_started_usec + update_usec < budget * 0.9


func _frame_budget_usec(fps: int) -> float:
	if fps != _fps:
		_fps = fps
		_last_draw_usec = 0
		_draw_spacing = 1
		_timely_draws = 0
	return 1_000_000.0 / fps if fps in [30, 60] else 0.0


func applied(frame: int, elapsed_usec: int) -> void:
	_last_update_frame = frame
	_update_usec = roundi(lerpf(_update_usec, elapsed_usec, 0.25))
	_clear_pending()


func reject() -> void:
	# Keep the latest payload so a paused world can recover without another day.
	needs_recovery = true
	_full_update = true


func reset() -> void:
	_clear_pending()
	_frame_started_usec = 0
	_last_draw_usec = 0
	_fps = 0
	_draw_spacing = 1
	_timely_draws = 0
	_last_update_frame = -1
	_update_usec = INITIAL_UPDATE_USEC
