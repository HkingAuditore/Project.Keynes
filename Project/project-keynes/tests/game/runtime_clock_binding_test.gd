extends SceneTree

const Binding = preload("res://scripts/game/runtime_clock_binding.gd")
var calls: Array = []
var states: Array = []
var checks := 0
var failures := 0

func _init() -> void:
	var clock := WorldClock.new()
	var binding := Binding.new()
	clock.paused = true
	clock.speed_multiplier = 20.0
	binding.attach(clock, _apply, _running)
	_expect("attach replays state after executor creation", calls[-1] == [true, 20.0] and states[-1] == false)
	clock.paused = false
	_expect("direct pause changes reach executor without UI", calls[-1] == [false, 20.0] and states[-1])
	clock.pause(true)
	clock.set_speed(20.0)
	_expect("same speed resumes a paused executor", calls[-1] == [false, 20.0])
	clock.speed_multiplier = 0.0
	_expect("zero speed stops session admission", calls[-1] == [false, 0.0] and not states[-1])
	clock.latch_authority_fault_hold()
	clock.paused = false
	clock.set_speed(50.0)
	_expect("fault hold cannot be bypassed by direct assignment or speed", clock.paused and calls[-1] == [true, 50.0])
	var next := WorldClock.new()
	binding.attach(next, _apply, _running)
	var count := calls.size()
	clock.speed_multiplier = 10.0
	_expect("old clock cannot control a replacement session", calls.size() == count)
	binding.detach()
	count = calls.size()
	next.pause(true)
	_expect("closed session receives no clock commands", calls.size() == count)
	binding.attach(next, _apply, _running)
	next.free()
	binding.synchronize()
	binding.detach()
	_expect("scene destruction permits idempotent detach", true)
	clock.free()
	print("runtime clock binding: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _apply(paused: bool, speed: float) -> void:
	calls.append([paused, speed])

func _running(running: bool) -> void:
	states.append(running)

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("[FAIL] " + label)
