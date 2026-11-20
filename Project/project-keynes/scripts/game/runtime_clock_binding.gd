extends RefCounted

## A session owns this subscription, not a UI controller. Attach only after the
## executor exists; immediately deliver current state and detach before stop.
var _clock_ref: WeakRef
var _apply: Callable
var _running: Callable
var _fast_headless := false

# Godot sleeps between headless iterations even with low-processor mode off.
# At 100x the default 6.9 ms sleep can consume most of a day's 10 ms budget
# before the next clock admission.
const FAST_HEADLESS_SLEEP_USEC := 500
static var _fast_headless_sessions := 0
static var _previous_sleep_usec := 0


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
	else:
		_set_fast_headless(false)


func detach() -> void:
	_set_fast_headless(false)
	var clock = _clock_ref.get_ref() if _clock_ref != null else null
	if clock != null:
		if clock.control_changed.is_connected(_on_control_changed):
			clock.control_changed.disconnect(_on_control_changed)
		clock.bind_runtime_calendar(Callable())
	_clock_ref = null
	_apply = Callable()
	_running = Callable()


func _on_control_changed(paused: bool, speed: float) -> void:
	_set_fast_headless(not paused and speed >= 100.0 and DisplayServer.get_name() == "headless")
	if _apply.is_valid():
		_apply.call(paused, speed)
	if _running.is_valid():
		_running.call(not paused and speed > 0.0)


func _set_fast_headless(enabled: bool) -> void:
	if _fast_headless == enabled:
		return
	_fast_headless = enabled
	if enabled:
		if _fast_headless_sessions == 0:
			_previous_sleep_usec = OS.low_processor_usage_mode_sleep_usec
			OS.low_processor_usage_mode_sleep_usec = mini(_previous_sleep_usec, FAST_HEADLESS_SLEEP_USEC)
		_fast_headless_sessions += 1
	else:
		_release_fast_headless()


static func _release_fast_headless() -> void:
	_fast_headless_sessions -= 1
	if _fast_headless_sessions == 0 and _previous_sleep_usec > FAST_HEADLESS_SLEEP_USEC \
			and OS.low_processor_usage_mode_sleep_usec == FAST_HEADLESS_SLEEP_USEC:
		OS.low_processor_usage_mode_sleep_usec = _previous_sleep_usec


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _fast_headless:
		_release_fast_headless()
