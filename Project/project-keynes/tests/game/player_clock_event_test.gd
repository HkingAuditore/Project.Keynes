extends SceneTree

class Controller extends PlayerController:
	func sync_ui() -> void: pass
	func _configure_narrative_runtime() -> void: pass

class AudioSituation extends RefCounted:
	var deltas: Array[float] = []
	func process_audio_update(delta: float) -> Dictionary:
		deltas.append(delta)
		return {"tension_write_due": false}

var failures := 0
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var first := WorldClock.new()
	var second := WorldClock.new()
	first.auto_start = false
	second.auto_start = false
	root.add_child(first)
	root.add_child(second)
	first.set_process(false)
	second.set_process(false)
	first.pause(false)
	second.pause(false)
	var controller := Controller.new()
	root.add_child(controller)
	controller.configure(null, null, null, first, null)
	controller.set_popups_suppressed(true)
	_pause_clock(first)
	_expect("the pause call completes before deferred suppression", first.paused)
	await process_frame
	await process_frame
	_expect("a suppressed offer releases its own automatic pause", not first.paused)
	first.pause(true)
	await process_frame
	_expect("manual pause remains effective", first.paused)
	first.pause(false)
	first.latch_authority_fault_hold()
	await process_frame
	_expect("fault pause remains effective", first.paused)
	first.clear_authority_fault_hold()
	first.pause(false)
	_save_clock(first)
	await process_frame
	_expect("save pause remains effective", first.paused)
	first.pause(false)
	controller.configure(null, null, null, second, null)
	var playback: Node = controller._music_playback
	controller.configure(null, null, null, second, null)
	_expect("reconfiguration reuses one music driver", playback == controller._music_playback)
	for name in controller.CLOCK_CALLBACKS:
		_expect("reconfiguration detaches the previous clock " + String(name),
			not first.is_connected(name, Callable(controller, controller.CLOCK_CALLBACKS[name])))
	_pause_clock(first)
	await process_frame
	_expect("the previous clock cannot resume itself through this controller", first.paused)
	_pause_clock(second)
	await process_frame
	await process_frame
	_expect("the replacement clock receives automatic-pause events", not second.paused)
	controller.set_popups_suppressed(false)
	_pause_clock(second)
	await process_frame
	_expect("disabling suppression keeps the offer pause", second.paused)
	var situation := AudioSituation.new()
	playback.situation = situation
	playback._process(0.25)
	_expect("the presentation driver keeps music smoothing active", situation.deltas == [0.25])
	controller.free()
	first.free()
	second.free()
	await process_frame
	print("player clock events: %d failures" % failures)
	quit(0 if failures == 0 else 1)

func _pause_clock(clock: WorldClock) -> void:
	clock.pause(true)
func _save_clock(clock: WorldClock) -> void:
	clock.pause(true)
func _expect(label: String, value: bool) -> void:
	if not value:
		failures += 1
		push_error(label)
