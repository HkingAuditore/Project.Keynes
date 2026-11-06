extends RefCounted

## A session owns this subscription, not a UI controller. Attach only after the
## executor exists; immediately deliver current state and detach before stop.
var _clock_ref: WeakRef
var _apply: Callable
var _running: Callable


func attach(clock: WorldClock, apply: Callable, running: Callable) -> void:
	detach()
	_clock_ref = weakref(clock)
	_apply = apply
	_running = running
	clock.control_changed.connect(_on_control_changed)
	synchronize()


func synchronize() -> void:
	var clock = _clock_ref.get_ref() if _clock_ref != null else null
	if clock != null:
		_on_control_changed(clock.paused, clock.speed_multiplier)


func detach() -> void:
	var clock = _clock_ref.get_ref() if _clock_ref != null else null
	if clock != null and clock.control_changed.is_connected(_on_control_changed):
		clock.control_changed.disconnect(_on_control_changed)
	_clock_ref = null
	_apply = Callable()
	_running = Callable()


func _on_control_changed(paused: bool, speed: float) -> void:
	if _apply.is_valid():
		_apply.call(paused, speed)
	if _running.is_valid():
		_running.call(not paused and speed > 0.0)
