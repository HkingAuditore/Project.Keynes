extends RefCounted

## One instance per world. No scene objects, business state, or global services.
## Admission closes immediately; CLOSED means all started modules really released.
signal preparation_returned
signal close_returned(result: Dictionary)

const Registry = preload("res://scripts/game/runtime_module_registry.gd")
enum State { CONFIGURING, PREPARING, READY, RUNNING, PAUSED, SAVING, CLOSING, CLOSED, FAULTED }

static var _next_generation: int = 0
var generation: int
var _state := State.CONFIGURING
var _entries: Array = []
var _ordered: Array = []
var _started: Array = []
var _preparing := false
var _closing := false
var _close_requested := false
var _resume_state := State.PAUSED
var _failure: Dictionary = {}


func _init() -> void:
	_next_generation += 1
	generation = _next_generation


func configure(entries: Array) -> Dictionary:
	if _state != State.CONFIGURING or _close_requested:
		return _error("session_composition_locked")
	var result := Registry.resolve(entries)
	if not bool(result.get("ok", false)):
		return result
	for module in result.modules:
		if not module.has_method("prepare") or not module.has_method("cancel") \
				or not module.has_method("release"):
			return _error("session_module_contract_invalid")
	_entries = entries.duplicate(true)
	_ordered = result.modules.duplicate()
	return {"ok": true, "ids": result.ids}


func prepare() -> Dictionary:
	if _state != State.CONFIGURING or _close_requested or _ordered.is_empty():
		return _error("session_prepare_invalid")
	_state = State.PREPARING
	_preparing = true
	for module in _ordered:
		# Include the active module: failed/partially prepared resources need release.
		_started.append(module)
		var result: Dictionary = await module.prepare()
		if _close_requested:
			_preparing = false
			preparation_returned.emit()
			return _error("session_cancelled")
		if not bool(result.get("ok", false)):
			_failure = result.duplicate(true)
			_state = State.FAULTED
			_preparing = false
			preparation_returned.emit()
			return result
	_state = State.READY
	_preparing = false
	preparation_returned.emit()
	return {"ok": true}


func request_close() -> void:
	if _close_requested:
		return
	_close_requested = true
	_state = State.CLOSING
	# Set the state BEFORE invoking callbacks. Cancellation may resume a suspended
	# prepare inline; that continuation must see closed admission immediately.
	var cancelling := _started.duplicate()
	cancelling.reverse()
	for module in cancelling:
		module.cancel()


func close() -> Dictionary:
	if _state == State.CLOSED:
		return {"ok": true}
	if _closing:
		return await close_returned
	_closing = true
	request_close()
	if _preparing:
		await preparation_returned
	while not _started.is_empty():
		var module = _started.back()
		var result: Dictionary = await module.release()
		if not bool(result.get("ok", false)):
			_failure = result.duplicate(true)
			_state = State.FAULTED
			_closing = false
			close_returned.emit(result)
			return result
		_started.pop_back()
	_ordered.clear()
	_entries.clear()
	_state = State.CLOSED
	_closing = false
	var result := {"ok": true}
	close_returned.emit(result)
	return result


func accepts_work() -> bool:
	return not _close_requested and _state in [State.READY, State.RUNNING, State.PAUSED]


func is_current(token: int) -> bool:
	return token == generation and not _close_requested and _state != State.FAULTED


func is_preparing() -> bool:
	return _state == State.PREPARING and not _close_requested


func is_closing() -> bool:
	return _close_requested


func set_running(running: bool) -> void:
	if accepts_work():
		_state = State.RUNNING if running else State.PAUSED
	elif _state == State.SAVING and not _close_requested:
		_resume_state = State.RUNNING if running else State.PAUSED


func begin_capture() -> Dictionary:
	if not accepts_work():
		return _error("session_capture_unavailable")
	_resume_state = _state
	_state = State.SAVING
	return {"ok": true}


func end_capture() -> void:
	if _state == State.SAVING and not _close_requested:
		_state = _resume_state


func report() -> Dictionary:
	var ids := PackedStringArray()
	for entry in _entries:
		ids.append(String(entry.id))
	return {"generation": generation, "state": State.keys()[_state],
		"accepts_work": accepts_work(), "modules": ids, "failure": _failure.duplicate(true)}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "code": code}
