extends SceneTree

# Exercise the native stop boundary while a production Economy day is active.
# request_runtime_stop used to reset the worker's borrowed Economy pointer and
# command executor before asking it to stop, racing worker_run_stage_ops_slice.

var _checks := 0
var _failures := 0

class AddedModule extends RefCounted:
	var owner: WeakRef
	var prepared_before_execution := false
	var released_after_execution := false
	var cancel_count := 0
	func adapter(host):
		owner = weakref(host)
		return preload("res://scripts/game/runtime_session_module.gd").new().configure(
			"added_system", PackedStringArray(["restore"]), PackedStringArray(["added.state"]),
			prepare, cancel, release)
	func prepare() -> Dictionary:
		var host = owner.get_ref()
		prepared_before_execution = host.current_map() != null and not host.is_runtime_ready_for_ticks()
		return {"ok": true}
	func cancel() -> void:
		cancel_count += 1
	func release() -> Dictionary:
		var host = owner.get_ref()
		released_after_execution = host.generator() != null and bool(
			host.generator().get_runtime_thread_report().get("simulation_executor_exited", false))
		return {"ok": released_after_execution}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.debug_step_log = false
	root.add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.generate_test_economy_data = false
	root.add_child(host)
	var config := NewGameConfig.create_default()
	config.base.map_width = 30
	config.base.map_height = 20
	config.base.initial_seed = 20260718
	config.country.foreign_count = 1
	var configured := host.configure_session({
		"kind": "new_game", "config": config.to_dictionary(),
	})
	_expect("formal session configures", bool(configured.get("ok", false)))
	host.configure(null, null, clock)
	var added := AddedModule.new()
	_expect("new system registers through session interface", host.register_session_module(added.adapter(host)).ok)
	await host.generate_world(20260718)
	var generator := host.get_generator()
	_expect("world generation completes", generator != null)
	_expect("extension prepares after world data and before execution", added.prepared_before_execution)
	if generator == null:
		host.free()
		clock.free()
		_finish()
		return
	var ext = generator.get_data_core_world_ext()
	ext.set_runtime_clock(false, 50.0)
	var inflight := false
	# This bound fails the fixture if it never exercises a real worker day;
	# waiting for a PAUSED worker would miss the lifetime race entirely.
	for day in range(1, 21):
		clock.current_day = day
		host.run_daily_tick(day, clock.season_phase_for_day(day))
		host.finish_daily_tick(0.0, {})
		for _poll in range(200):
			var report: Dictionary = ext.get_runtime_thread_report()
			if int(report.get("worker_day_inflight", 0)) > 0 \
					and (int(report.get("authoritative_domain_mask", 0)) & 0x100) != 0:
				inflight = true
				break
			OS.delay_usec(100)
		if inflight:
			break
		await process_frame
	_expect("stop is requested during a production worker day", inflight)
	host.set_process(false)
	clock.set_process(false)
	await host._stop_previous_runtime_worker()
	var stopped: Dictionary = ext.get_runtime_thread_report()
	_expect("worker reaches STOPPED", String(stopped.get("simulation_host_state", "")) == "STOPPED")
	_expect("worker finishes its outstanding slice", int(stopped.get("worker_day_inflight", -1)) == 0)
	var control: Dictionary = ext.get_runtime_control_state()
	_expect("stopped worker owns no domains", int(control.get("authoritative_domain_mask", -1)) == 0)
	_expect("stopped worker is not ready or effectively ACTIVE",
		not bool(control.get("authority_ready", true))
		and not bool(control.get("simulation_worker_ready", true))
		and String(control.get("simulation_thread_mode", "")) == "OFF")
	_expect("stop does not fault the worker", int(stopped.get("worker_fault_count", -1)) == 0)
	_expect("worker confirms it has returned, not just received stop", bool(stopped.get("simulation_executor_exited", false)))
	var released := {
		"generator": weakref(generator),
		"map": weakref(host.current_map()),
		"native world": weakref(ext),
		"DataCore world": weakref(generator.get_data_core_world()),
	}
	var closed: Dictionary = await host.close_world()
	_expect("session closes all registered modules", closed.ok and host.session_report().state == "CLOSED")
	_expect("extension releases after execution and before its dependencies", added.released_after_execution)
	_expect("extension cancellation happens exactly once", added.cancel_count == 1)
	_expect("closed host drops its world owner", host.generator() == null and host.current_map() == null)
	# Drop the scene and its owning references on the main thread.
	host.free()
	clock.free()
	generator = null
	ext = null
	await process_frame
	for label in released:
		_expect("exit releases " + label, released[label].get_ref() == null)
	_finish()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("[PASS] " + label)
	else:
		_failures += 1
		push_error("[FAIL] " + label)


func _finish() -> void:
	print("runtime worker stop lifetime: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)
