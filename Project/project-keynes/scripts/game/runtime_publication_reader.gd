extends RefCounted

## Zero uses each process frame. A late frame drains one accumulated batch
## and advances to the next deadline on the original monotonic time grid.
var interval_usec: int = 0:
	set(value):
		interval_usec = maxi(0, value)
		reset()
var _next_usec := -1


func due(now_usec: int) -> bool:
	if interval_usec == 0:
		return true
	if _next_usec < 0:
		_next_usec = now_usec
	if now_usec < _next_usec:
		return false
	_next_usec = now_usec + interval_usec - (now_usec - _next_usec) % interval_usec
	return true


func reset() -> void:
	_next_usec = -1
