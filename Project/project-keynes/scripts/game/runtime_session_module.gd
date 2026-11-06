extends RefCounted

## An adapter owns its resources. The session only orders lifecycle calls.
## prepare/release return {ok, code}; cancel must synchronously wake preparation
## and stop new work. Release may await a real worker completion, never a timer.
var _id := ""
var _after := PackedStringArray()
var _owns := PackedStringArray()
var _prepare: Callable
var _cancel: Callable
var _release: Callable


func configure(id: String, after: PackedStringArray, owns: PackedStringArray,
		prepare: Callable, cancel: Callable, release: Callable):
	_id = id
	_after = after.duplicate()
	_owns = owns.duplicate()
	_prepare = prepare
	_cancel = cancel
	_release = release
	return self


func descriptor() -> Dictionary:
	if _id.is_empty() or not _prepare.is_valid() or not _cancel.is_valid() \
			or not _release.is_valid():
		return {}
	return {"id": _id, "after": _after.duplicate(), "owns": _owns.duplicate(), "module": self}


func prepare() -> Dictionary:
	if not _prepare.is_valid():
		return {"ok": false, "code": "module_owner_released"}
	return _checked(await _prepare.call())


func cancel() -> void:
	if _cancel.is_valid():
		_cancel.call()


func release() -> Dictionary:
	if not _release.is_valid():
		return {"ok": false, "code": "module_owner_released"}
	return _checked(await _release.call())


func _checked(result: Variant) -> Dictionary:
	if not result is Dictionary or not result.get("ok") is bool:
		return {"ok": false, "code": "module_result_invalid", "module": _id}
	return result
