extends SceneTree

class Controller extends PlayerController:
	func sync_ui() -> void: pass
	func _configure_narrative_runtime() -> void: pass

class AudioSituation extends RefCounted:
	var deltas: Array[float] = []
	func process_audio_update(delta: float) -> Dictionary:
		deltas.append(delta)
		return {"tension_write_due": false}

class CeremonySurface extends RefCounted:
	var _era_indicator: EraIndicator
	var _era_ceremony: EraAscensionCeremony
	var _era_ceremony_index := 1
	var _player_controller = null
	var workspace_rechecks := 0

	func notify_workspace_closed() -> void:
		workspace_rechecks += 1

var failures := 0
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check_climate_input_matches_calendar_year()
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
	_pause_clock(first)
	_expect("the manual pause is immediate", first.paused)
	await process_frame
	await process_frame
	_expect("display callbacks leave the manual pause in place", first.paused)
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
	_expect("the replacement clock keeps its own manual pause", second.paused)
	second.pause(false)
	await process_frame
	_expect("the replacement clock resumes when requested", not second.paused)
	var situation := AudioSituation.new()
	playback.situation = situation
	playback._process(0.25)
	_expect("the presentation driver keeps music smoothing active", situation.deltas == [0.25])
	second.pause(true)
	var ceremony := CeremonySurface.new()
	preload("res://scripts/ui/game_ui/era_progression.gd").new()._on_era_ceremony_finished(ceremony)
	_expect("ending a ceremony does not release a manual pause", second.paused)
	_expect("ending a ceremony clears the displayed era", ceremony._era_ceremony_index == -1)
	_expect("ending a ceremony rechecks deferred story presentation", ceremony.workspace_rechecks == 1)
	controller.free()
	first.free()
	second.free()
	await process_frame
	print("player clock events: %d failures" % failures)
	quit(0 if failures == 0 else 1)

func _check_climate_input_matches_calendar_year() -> void:
	var clock := WorldClock.new()
	clock.days_per_year_count = 365
	clock._last_day = 364
	clock._last_season = 3
	clock._last_year = 0
	clock.seed_annual_climate(20260718)
	var old_anomaly := clock.climate_anomaly
	var old_rng_state := clock._rng.state
	var new_anomaly := clock.climate_anomaly_for_day(365)
	var years: Array[int] = []
	var sampled: Array[float] = []
	_expect("the final day of the old year keeps its current anomaly",
		clock.climate_anomaly_for_day(364) == old_anomaly)
	_expect("sampling the next year leaves the calendar and random state intact",
		new_anomaly != old_anomaly and clock.climate_anomaly == old_anomaly
		and clock._rng.state == old_rng_state and clock._last_year == 0)
	clock.year_changed.connect(func(year): years.append(year))
	clock.day_changed.connect(func(day): sampled.append(clock.climate_anomaly_for_day(day)))
	clock._advance_one_sim_day()
	sampled.append(clock.climate_anomaly_for_day(365))
	_expect("new-year inputs agree on both sides of the calendar signal",
		years == [1] and sampled == [new_anomaly, new_anomaly]
		and clock.climate_anomaly == new_anomaly)
	clock.free()

func _pause_clock(clock: WorldClock) -> void:
	clock.pause(true)
func _save_clock(clock: WorldClock) -> void:
	clock.pause(true)
func _expect(label: String, value: bool) -> void:
	if not value:
		failures += 1
		push_error(label)
