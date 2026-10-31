extends SceneTree

## A RESTARTED worker must survive its first Economy day and the days after it.
##
## WHY THIS FILE EXISTS
##
## Every restarted worker lifetime dies on the first Economy day it is supposed to
## resume on, with
##
##   [runtime-worker-exception] what=economy_column_read_range_invalid day=N
##   -> code=unhandled_worker_exception
##
## The exception carries the field name and the offending index/size, printed by
## `economy_tracking_range_failure` on stderr before it throws:
##
##   [economy-tracking-range] reason=economy_column_read_range_invalid
##                            field=<column> index=<i> size=<n>
##
## That line is the evidence this fixture is built around: `what()` alone only
## names the symptom. Because a faulted host cannot be restarted
## (`runtime_thread_mode_hot_switch_forbidden`), the fault ends the session, so the
## only thing that can be measured before the fix is the fault itself.
##
## PHASES
##
##   1. RESTART: build a 0xFFF ACTIVE worker world, drive days until the deferred
##      grant promotes, stop the worker, start it again on the same world, then
##      drive days and report `fault`, `completed_days`, and the Economy stage
##      witnesses per day.
##   2. CONTROL: build the same world and drive the same number of days without
##      ever stopping the worker. A fix must not change its numbers.
##
## Run:
##   Godot_v4.6.2-stable_win64.exe --headless --path Project/project-keynes \
##     -s tests/economy/economy_worker_restart_day_test.gd

const WIDTH := 16
const HEIGHT := 12
const CELLS: int = WIDTH * HEIGHT
const SEED := 20261029
const WORKER_SPEED := 10.0

const MASK_ALL := 0xFFF
const DOMAIN_ECONOMY := 0x100

const MAX_PROMOTE_DAYS := 12
## Days driven AFTER the restart. The acceptance bar is 10.
const POST_RESTART_DAYS := 12
## Days driven before the restart, on top of the promotion day.
const PRE_RESTART_EXTRA_DAYS := 2
const MAX_SLICES_PER_DAY := 64
const STATE_WAIT_MS := 15000
const COMMIT_WAIT_MS := 4000
const GLOBAL_BUDGET_MS := 900000

const WorkerWaitHelper = preload("res://tests/ideology/ideology_worker_wait_helper.gd")

## Phase switch, so a single phase can be iterated on without paying for both.
const RUN_RESTART_PHASE := true
const RUN_CONTROL_PHASE := true

var _checks := 0
var _failures := 0
var _run_started_ms := 0
var _worlds: Array = []


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== economy worker restart day: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	_run_started_ms = Time.get_ticks_msec()
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var restart_days := 0
	if RUN_RESTART_PHASE:
		restart_days = await _phase_restart()
		await _dispose_all_worlds()
	if RUN_CONTROL_PHASE:
		await _phase_control(restart_days)
		await _dispose_all_worlds()
	return 0


# =========================================================================
# Phase 1: stop the worker mid-run, start it again, drive days
# =========================================================================
func _phase_restart() -> int:
	print("[RESTART] building a %dx%d seed=%d mask=0x%03X ACTIVE worker world"
		% [WIDTH, HEIGHT, SEED, MASK_ALL])
	var w := await _build_world("restart")
	if w.is_empty():
		return 0
	var promoted := false
	for _index in range(MAX_PROMOTE_DAYS):
		_drive_day(w)
		if int(_probe(w)["granted"]) == MASK_ALL:
			promoted = true
			break
	_expect("RESTART: the deferred mask promotes to 0xFFF once a day commits",
		promoted, _probe_line(_probe(w)))
	if not promoted:
		return 0
	_drive_days(w, PRE_RESTART_EXTRA_DAYS)
	var before := _probe(w, "before-restart")
	print("[RESTART] BEFORE: %s" % _probe_line(before))
	var before_economy_day := int(before["economy_day"])
	var before_economy_hash := int(before["economy_hash"])
	# ── the restart ─────────────────────────────────────────────────────
	var at_start := _restart_worker(w)
	if at_start.is_empty():
		return 0
	print("[RESTART] AT START: %s" % _probe_line(at_start))
	print("[RESTART] resume: host committed day %d, economy pod committed day %d"
		% [int(at_start["committed"]), int(at_start["economy_day"])])
	# ── driven days after the restart ───────────────────────────────────
	var survived := 0
	var first_fault_day := -1
	var fault := ""
	for _index in range(POST_RESTART_DAYS):
		_drive_day(w)
		var p := _probe(w, "post-restart")
		print("[RESTART] DAY %d: %s" % [int(w["tick"]), _probe_line(p)])
		fault = String(p["fault"])
		if not fault.is_empty():
			first_fault_day = int(w["tick"])
			break
		survived += 1
	var after := _probe(w, "after-restart")
	print("[RESTART] AFTER %d DRIVEN DAYS: %s" % [survived, _probe_line(after)])
	if not fault.is_empty():
		print("[RESTART] AT FAULT: %s" % _economy_line(_economy_probe(w)))
	print("[RESTART] economy stage output: committed_day %d -> %d, state_hash "
		% [before_economy_day, int(after["economy_day"])]
		+ "%d -> %d, economy_domain_bit=%s"
		% [before_economy_hash, int(after["economy_hash"]),
			str((int(after["pod_mask"]) & DOMAIN_ECONOMY) != 0)])
	_expect("RESTART: the restarted worker survives at least 10 driven days "
		+ "without a fault",
		fault.is_empty() and survived >= 10,
		"survived=%d fault='%s' first_fault_day=%d" % [survived, fault,
			first_fault_day])
	_expect("RESTART: completed_days keeps advancing after the restart",
		int(after["completed_days"]) > int(before["completed_days"]),
		"completed_days %d -> %d" % [int(before["completed_days"]),
			int(after["completed_days"])])
	_expect("RESTART: the Economy stage produces output after the restart "
		+ "(its committed day and state hash move on)",
		int(after["economy_day"]) > before_economy_day
			and int(after["economy_hash"]) != before_economy_hash,
		"economy committed day %d -> %d, hash %d -> %d"
			% [before_economy_day, int(after["economy_day"]),
				before_economy_hash, int(after["economy_hash"])])
	# Surviving is not enough: the Economy stage has to have actually committed
	# the days it was given, otherwise "no fault" would also describe a worker
	# that quietly stopped advancing.
	_expect("RESTART: the Economy stage committed at least 10 days of its own "
		+ "after the restart",
		int(after["economy_day"]) - before_economy_day >= 10,
		"economy committed day %d -> %d (+%d)"
			% [before_economy_day, int(after["economy_day"]),
				int(after["economy_day"]) - before_economy_day])
	return survived


# =========================================================================
# Phase 2: negative control -- the same world, never restarted
# =========================================================================
func _phase_control(days_after_promotion: int) -> void:
	print("[CONTROL] building the same world, never restarted")
	var w := await _build_world("control")
	if w.is_empty():
		return
	var promoted := false
	for _index in range(MAX_PROMOTE_DAYS):
		_drive_day(w)
		if int(_probe(w)["granted"]) == MASK_ALL:
			promoted = true
			break
	_expect("CONTROL: the deferred mask promotes to 0xFFF once a day commits",
		promoted, _probe_line(_probe(w)))
	if not promoted:
		return
	_drive_days(w, PRE_RESTART_EXTRA_DAYS)
	var before := _probe(w, "control-before")
	print("[CONTROL] BEFORE: %s" % _probe_line(before))
	var total := maxi(days_after_promotion, POST_RESTART_DAYS)
	var survived := 0
	var fault := ""
	for _index in range(total):
		_drive_day(w)
		var p := _probe(w, "control")
		fault = String(p["fault"])
		if not fault.is_empty():
			break
		survived += 1
	var after := _probe(w, "control-after")
	print("[CONTROL] AFTER %d DRIVEN DAYS: %s" % [survived, _probe_line(after)])
	_expect("CONTROL: a never-restarted worker keeps running for the same "
		+ "number of driven days",
		fault.is_empty() and survived >= total,
		"survived=%d/%d fault='%s'" % [survived, total, fault])
	_expect("CONTROL: completed_days keeps advancing",
		int(after["completed_days"]) > int(before["completed_days"]),
		"completed_days %d -> %d" % [int(before["completed_days"]),
			int(after["completed_days"])])
	print("[CONTROL] economy stage output: committed_day %d -> %d, state_hash %d -> %d"
		% [int(before["economy_day"]), int(after["economy_day"]),
			int(before["economy_hash"]), int(after["economy_hash"])])


## Parks the worker at a day boundary, stops it, and starts it again with the same
## mask. Returns the probe taken right after the start, or {} when the restart was
## refused.
func _restart_worker(w: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
	var before_day := int(w["tick"])
	print("[RESTART] stop -> restart with mask 0x%03X at main day %d"
		% [MASK_ALL, before_day])
	var parked := _wait_worker_state(w, "PAUSED", 3000)
	print("[RESTART] parked at a day boundary: %s (state=%s)"
		% [str(parked), String(ext.get_runtime_thread_report().get(
			"simulation_host_state", "?"))])
	ext.request_runtime_stop()
	var stopped := _wait_worker_state(w, "STOPPED", STATE_WAIT_MS)
	_expect("RESTART: the stop completes", stopped,
		_probe_line(_probe(w, "during-stop")))
	# The economy epoch is the only part of a worker lifetime that is not
	# reproducible from a day boundary. Read it while the worker is guaranteed
	# stopped, so "was the stop a boundary stop or a mid-epoch stop" is measured
	# instead of assumed.
	var economy_at_stop := _economy_probe(w)
	print("[RESTART] AT STOP: %s" % _economy_line(economy_at_stop))
	var started: Dictionary = ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": MASK_ALL,
		"day": maxi(0, before_day),
		"speed_days_per_second": WORKER_SPEED,
		"paused": false,
	})
	if not _require("RESTART: the worker restarts with mask 0x%03X" % MASK_ALL,
			bool(started.get("ok", false)), str(started)):
		return {}
	ext.set_runtime_clock(true, WORKER_SPEED)
	return _probe(w, "after-restart")


# =========================================================================
# world construction
# =========================================================================
func _build_world(name: String) -> Dictionary:
	var started := Time.get_ticks_msec()
	var clock := WorldClock.new()
	clock.auto_start = false
	clock.initial_speed = 1.0
	clock.debug_step_log = false
	get_root().add_child(clock)
	clock.pause(true)
	var host := WorldRuntimeHost.new()
	host.map_width = WIDTH
	host.map_height = HEIGHT
	host.initial_seed = SEED
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_shadow_on_generate = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = MASK_ALL
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "W %s" % name
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("BUILD/%s: the session configures" % name,
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("BUILD/%s: production world generation succeeded" % name,
			generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("BUILD/%s: production DCWorldExt is bound" % name, ext != null):
		return {}
	ext.set_runtime_clock(true, WORKER_SPEED)
	var w := {
		"name": name, "host": host, "clock": clock, "ext": ext,
		"generator": generator, "tick": 0, "cells": CELLS,
		"started_ms": Time.get_ticks_msec(),
	}
	w["tick"] = maxi(0, _world_day(ext))
	_worlds.append(w)
	print("[BUILD/%s] ready in %d ms: start_day=%d"
		% [name, Time.get_ticks_msec() - started, int(w["tick"])])
	return w


# =========================================================================
# probes
# =========================================================================
func _probe(w: Dictionary, label: String = "") -> Dictionary:
	var ext: Object = w["ext"]
	var r: Dictionary = ext.get_runtime_thread_report()
	return {
		"label": label,
		"main_day": int(w["tick"]),
		"state": String(r.get("simulation_host_state", "?")),
		"mode": String(r.get("simulation_thread_mode", "?")),
		"requested": int(r.get("requested_authority_mask", 0)),
		"granted": int(r.get("authoritative_domain_mask", 0)),
		"authority_ready": bool(r.get("authority_ready", false)),
		"committed": int(r.get("simulation_committed_day", -1)),
		"completed_days": int(r.get("completed_days", -1)),
		"day_stages": int(r.get("day_stage_count", -1)),
		"day_completed": int(r.get("day_completed_stage_count", -1)),
		"pod_mask": int(r.get("pod_completed_domain_mask", 0)),
		"env_day": int(r.get("simulation_environment_day", -1)),
		"env_consumed": int(r.get("environment_consumed_days", -1)),
		"env_rejected": int(r.get("stale_environment_rejected", -1)),
		"economy_day": int(r.get("economy_pod_committed_day", -1)),
		"economy_hash": int(r.get("economy_pod_state_hash", 0)),
		"economy_generation": int(r.get("economy_pod_generation", 0)),
		"economy_stage_mask": int(r.get("economy_pod_completed_stage_mask", 0)),
		"economy_ready": bool(r.get("economy_pod_ready", false)),
		"economy_work": int(r.get("economy_pod_work_units", 0)),
		"backing": String(r.get("economy_formula_backing", "?")),
		"writer": String(r.get("economy_production_writer_effective", "?")),
		"exec_mode": int(r.get("economy_execution_mode", -1)),
		"pod_active_ready": bool(r.get("economy_pod_active_ready", false)),
		"authority_switch_count": int(r.get("economy_authority_switch_count", -1)),
		"authority_switch_blocker": String(
			r.get("economy_authority_switch_blocker", "")),
		"fault": String(r.get("fault_code", "")),
	}


func _probe_line(p: Dictionary) -> String:
	return ("main_day=%d state=%s mode=%s granted=0x%03X committed=%d days=%d "
		% [int(p["main_day"]), String(p["state"]), String(p["mode"]),
			int(p["granted"]), int(p["committed"]), int(p["completed_days"])]
		+ "stages=%d/%d pod=0x%03X env(day=%d consumed=%d rej=%d) "
		% [int(p["day_completed"]), int(p["day_stages"]), int(p["pod_mask"]),
			int(p["env_day"]), int(p["env_consumed"]), int(p["env_rejected"])]
		+ "econ(day=%d hash=%d gen=%d stages=0x%x work=%d) "
		% [int(p["economy_day"]), int(p["economy_hash"]),
			int(p["economy_generation"]), int(p["economy_stage_mask"]),
			int(p["economy_work"])]
		+ "backing=%s writer=%s exec=%d pod_ready=%s switches=%d/%s fault='%s'"
		% [String(p["backing"]), String(p["writer"]), int(p["exec_mode"]),
			str(p["pod_active_ready"]), int(p["authority_switch_count"]),
			String(p["authority_switch_blocker"]), String(p["fault"])])


## The Economy runtime's own view of an interrupted day. Only safe to call while
## the worker is not running (report() reads live state, not a published copy).
func _economy_probe(w: Dictionary) -> Dictionary:
	var ext: Object = w["ext"]
	if not ext.has_method("get_economy_report"):
		return {}
	var r: Dictionary = ext.get_economy_report()
	return {
		"epoch_active": bool(r.get("epoch_active", false)),
		"epoch_id": int(r.get("epoch_id", -1)),
		"current_day": int(r.get("current_day", -1)),
		"last_committed_day": int(r.get("last_committed_day", -1)),
		"market_count": int(r.get("market_count", -1)),
		"good_count": int(r.get("good_count", -1)),
		"environment_day": int(r.get("environment_day", -1)),
		"stage": String(r.get("stage", "?")),
		"fatal": String(r.get("fatal_reason", "")),
	}


func _economy_line(p: Dictionary) -> String:
	if p.is_empty():
		return "no get_economy_report()"
	return ("epoch_active=%s epoch_id=%d current_day=%d last_committed_day=%d "
		% [str(p["epoch_active"]), int(p["epoch_id"]), int(p["current_day"]),
			int(p["last_committed_day"])]
		+ "market_count=%d good_count=%d env_day=%d stage=%s fatal='%s'"
		% [int(p["market_count"]), int(p["good_count"]),
			int(p["environment_day"]), String(p["stage"]), String(p["fatal"])])


# =========================================================================
# day driving
# =========================================================================
func _service_peers(ext: Object, passes: int = 6) -> void:
	if not ext.has_method("service_country_worker_peer_adapter"):
		return
	for _pass in range(passes):
		ext.service_country_worker_peer_adapter(96, true)


## One main-thread day. A worker fault does NOT stop the drive: the fault is the
## measurement, so it is reported and the caller decides.
func _drive_day(w: Dictionary) -> Dictionary:
	if Time.get_ticks_msec() - _run_started_ms > GLOBAL_BUDGET_MS:
		print("[BUDGET] wall-clock budget exhausted at day %d of '%s'"
			% [int(w["tick"]), String(w["name"])])
		return {"ok": false, "budget": true}
	var ext: Object = w["ext"]
	var clock: WorldClock = w["clock"]
	var host: WorldRuntimeHost = w["host"]
	w["tick"] = int(w["tick"]) + 1
	var day := int(w["tick"])
	var before := int(ext.get_runtime_thread_report().get(
		"simulation_committed_day", -1))
	clock.current_day = float(day)
	_service_peers(ext)
	host.run_daily_tick(day, clock.season_phase_for_day(day))
	host.finish_daily_tick(0.0, {})
	if clock.has_method("has_hard_barrier"):
		var pulses := 0
		while bool(clock.has_hard_barrier()) and pulses < 400:
			clock.simulation_backpressure_pulse.emit(day)
			pulses += 1
	# Soft barrier: let the worker consume the day this tick just captured. A
	# stalled or faulted worker must not hang the fixture, so it is a bounded
	# wait, exactly like the production host's day wait.
	_wait_worker_day(w, before, COMMIT_WAIT_MS)
	return {"ok": true, "day": day}


func _wait_worker_day(w: Dictionary, before: int, timeout_ms: int) -> void:
	var ext: Object = w["ext"]
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = ext.get_runtime_thread_report()
			return int(report.get("simulation_committed_day", -1)) > before \
				or String(report.get("simulation_host_state", "")) in [
					"STOPPED", "FAULTED"],
		timeout_ms,
		func() -> void:
			_service_peers(ext, 1))


func _drive_days(w: Dictionary, days: int) -> void:
	for _index in range(days):
		_drive_day(w)


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_runtime_thread_report"):
		return 0
	var report: Dictionary = ext.get_runtime_thread_report()
	for key in ["simulation_committed_day", "world_day", "day"]:
		if report.has(key):
			return int(report[key])
	return 0


func _wait_worker_state(w: Dictionary, wanted: String, timeout_ms: int) -> bool:
	var ext: Object = w["ext"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == wanted:
			return true
		if state == "FAULTED":
			return false
		_service_peers(ext, 1)
		OS.delay_msec(2)
	return false


# =========================================================================
# teardown + assertions
# =========================================================================
func _dispose_all_worlds() -> void:
	for index in range(_worlds.size() - 1, -1, -1):
		var w: Dictionary = _worlds[index]
		var ext: Object = w.get("ext", null)
		if ext != null and ext.has_method("request_runtime_stop"):
			ext.request_runtime_stop()
		var deadline := Time.get_ticks_msec() + 5000
		while Time.get_ticks_msec() < deadline:
			var state := String(ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) if ext != null else "STOPPED"
			if state == "STOPPED" or state == "FAULTED":
				break
			OS.delay_msec(5)
		var host: Object = w.get("host", null)
		if host != null and is_instance_valid(host):
			host.queue_free()
		var clock: Object = w.get("clock", null)
		if clock != null and is_instance_valid(clock):
			clock.queue_free()
	_worlds.clear()
	await process_frame
	await process_frame
	await process_frame


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("[PASS] " + label)
		return
	_failures += 1
	printerr("[FAIL] " + label
		+ ((" :: " + detail) if not detail.is_empty() else ""))


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(label: String) -> void:
	_expect(label, false)
