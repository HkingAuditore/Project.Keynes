# military_living_world_probe.gd
# Living-world military REPORT probe. It is NOT an assertion suite: it always
# exits 0 and prints one compact JSON line every 5 days so a human (or a log
# diff) can see whether Economy cohorts are actually converted to soldiers.
#
# Headless (verification):
#   .../Godot_v4.6.2-stable_win64_console.exe --headless --path Project/project-keynes \
#     -s res://tests/military/military_living_world_probe.gd -- --days=60
# In-game manual check (same script, real renderer, opens a window):
#   .../Godot_v4.6.2-stable_win64_console.exe --path Project/project-keynes \
#     -s res://tests/military/military_living_world_probe.gd
#
# User args (after `--`):  --days=N (default 120)   no-setup
#
# The world boots exactly like tests/military/military_runtime_smoke_test.gd
# (WorldClock + WorldRuntimeHost + NewGameConfig formal start, same seed/size),
# so the numbers here are directly comparable with that suite.
#
# Printed per report: day; military report (soldiers_total, pending_intents,
# last_step_day, intents_emitted, military_day_ms); player country snapshot
# (soldiers_total / soldiers_militia / post_count); capital cell snapshot
# (quota, pending_enlist, posts, present); capital economy population snapshot
# (population + the soldier / unemployed profession counts, resolved with the
# same helper the smoke test uses).
#
# Setup mode (default): at day 40 set the player force target (facade.set_target
# with mode 0) and build 3 barracks at the capital -- i.e. exactly what a player
# does in-game before expecting recruitment to start.
extends SceneTree

## Default seed of the comparable smoke world. The formal long acceptance run
## overrides it with `--seed=1812289715` (the plan's original seed).
const SEED := 20260727
const MAP_W := 60
const MAP_H := 40
const FOREIGN_COUNT := 3
const DEFAULT_DAYS := 120
const REPORT_EVERY_DAYS := 5
const SETUP_DAY := 40
const TARGET_HEADCOUNT := 12
const BARRACKS_TO_BUILD := 3
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096
## Bounded retry for the Economy population read: whole-graph ACTIVE serves it
## from the worker's committed read view, so the first read of a key can be
## pending (`economy_read_view_pending`) until the worker serves it.
const POP_READ_ATTEMPTS := 8
const DEFAULT_MAX_SECONDS := 3600.0


## Out-of-coroutine safety net: a script error inside the driver would leave the
## SceneTree idling forever, so a wall-clock cap always terminates with exit 0.
class Watchdog extends Node:
	var limit_sec := 3600.0
	var _started_usec := 0

	func _ready() -> void:
		_started_usec = Time.get_ticks_usec()

	func _process(_delta: float) -> void:
		if Time.get_ticks_usec() - _started_usec < int(limit_sec * 1000000.0):
			return
		print("[military-probe] watchdog timeout after %.0fs; quitting 0" % limit_sec)
		get_tree().quit(0)


class ErrorCounter extends Logger:
	var errors := PackedStringArray()
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String,
			rationale: String, _editor_notify: bool, error_type: int,
			_script_backtrace: Array[ScriptBacktrace]) -> void:
		# error_type 1 = warning; everything else (error / script / shader) counts.
		if error_type == 1:
			return
		_mutex.lock()
		errors.append("%s:%d %s %s %s" % [file, line, function, code, rationale])
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass


var _clock: WorldClock = null
var _host: WorldRuntimeHost = null
var _generator = null
var _facade = null
var _econ = null
var _capital := -1
var _player := 0
var _day := 0
var _total_days := DEFAULT_DAYS
## Overridable seed: the formal long acceptance run uses the plan's original
## seed, which is not this probe's default world.
var _seed := SEED
var _setup_enabled := true
var _setup_done := false
var _halted := false
var _pop_diag_printed := false
var _logger: ErrorCounter = null
var _seq := 1


func _init() -> void:
	# Nodes added during SceneTree._init are not inside the tree yet, and
	# WorldRuntimeHost.generate_world bails out when !is_inside_tree().
	await process_frame
	await _run()
	if _logger != null:
		OS.remove_logger(_logger)
	quit(0)


func _run() -> void:
	_parse_args()
	var watchdog := Watchdog.new()
	watchdog.limit_sec = _env_max_seconds()
	get_root().add_child(watchdog)
	if not ClassDB.class_exists("DCWorldExt"):
		print("[military-probe] SKIP DCWorldExt unavailable")
		return
	var api_probe = ClassDB.instantiate("DCWorldExt")
	var has_api: bool = api_probe != null \
		and api_probe.has_method("run_military_daily") \
		and api_probe.has_method("get_military_report")
	api_probe = null
	if not has_api:
		print("[military-probe] SKIP military bindings missing in loaded dots_ext")
		return
	if ClassDB.class_exists("Logger"):
		_logger = ErrorCounter.new()
		OS.add_logger(_logger)

	_clock = WorldClock.new()
	_clock.auto_start = false
	_clock.initial_speed = 50.0
	_clock.debug_step_log = false
	get_root().add_child(_clock)
	_clock.set_speed(50.0)
	_clock.pause(true)
	_host = WorldRuntimeHost.new()
	_host.map_width = MAP_W
	_host.map_height = MAP_H
	_host.initial_seed = _seed
	get_root().add_child(_host)
	_host.configure(null, null, _clock)
	var config := NewGameConfig.create_default()
	config.country.name = "Military Probe"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = _seed
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not bool(session.get("ok", false)):
		print("[military-probe] SKIP session configure failed: %s" % JSON.stringify(
			_compact(session)))
		return
	await _host.generate_world(SEED)
	_generator = _host.get_generator()
	var map: MapData = _host.get_current_map()
	if map == null or _generator == null:
		print("[military-probe] SKIP world generation failed")
		return
	var runtime_ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	if _host.runtime_climate_authority_enabled and runtime_ext != null \
			and runtime_ext.has_method("set_runtime_clock"):
		runtime_ext.set_runtime_clock(false, 50.0)

	_facade = _generator.get_military_facade() \
		if _generator.has_method("get_military_facade") else null
	_econ = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	if _facade == null or not _facade.is_configured():
		print("[military-probe] SKIP military facade not configured: %s" % JSON.stringify(
			{} if _facade == null else _compact(_facade.configure_result())))
		return
	var country = _generator.get_country_facade() \
		if _generator.has_method("get_country_facade") else null
	var start: Dictionary = _generator.gameplay_start_report()
	_capital = int(start.get("cell", -1))
	if country == null or _capital < 0:
		print("[military-probe] SKIP player capital unresolved (cell=%d)" % _capital)
		return
	_player = int(country.cell_summary(_capital).get("country_handle", 0))
	if _player == 0:
		print("[military-probe] SKIP player country handle unresolved at cell %d" % _capital)
		return
	print("[military-probe] boot %s" % JSON.stringify({
		"graph_active": bool(_generator.runtime_graph_active()),
		"capital": _capital,
		"player": _player,
		"days": _total_days,
		"setup_day": SETUP_DAY if _setup_enabled else -1,
		"target": TARGET_HEADCOUNT,
		"barracks": BARRACKS_TO_BUILD,
		"climate_authority": _host.runtime_climate_authority_enabled,
		"terrain_ready": bool(_facade.terrain_ready()),
	}))
	# Subscribe the Economy read-view key while the main thread still owns the
	# boundary; after the worker takes over this key is served from its committed
	# view, so the first report line is not stuck on `economy_read_view_pending`.
	_warm_population()
	_print_progress("boot")

	while _day < _total_days and not _halted:
		await _advance_to(_day + 1)
		if _halted:
			break
		if _setup_enabled and not _setup_done and _day >= SETUP_DAY:
			_apply_setup()
		if _day % REPORT_EVERY_DAYS == 0 or _day >= _total_days:
			await _print_report()
	if not _halted and _day % REPORT_EVERY_DAYS != 0:
		await _print_report()
	_print_progress("end")
	# Static allocation, for the plan's "same-condition 50-day sample" comparison:
	# the maintenance/order tables are sparse row tables, so this must not grow
	# with the number of simulated days.
	print("[military-probe] memory static_mb=%.1f peak_mb=%.1f" % [
		OS.get_static_memory_usage() / 1048576.0,
		OS.get_static_memory_peak_usage() / 1048576.0])
	var final := {
		"day": _day,
		"halted": _halted,
		"setup_done": _setup_done,
		"errors": 0 if _logger == null else _logger.errors.size(),
	}
	print("[military-probe] final %s" % JSON.stringify(final))
	if _logger != null:
		var errors := _logger.errors
		for i in range(mini(errors.size(), 10)):
			print("  [error] " + errors[i])


# ------------------------------------------------------------------ args

func _parse_args() -> void:
	_total_days = DEFAULT_DAYS
	var env_days := OS.get_environment("PROBE_DAYS")
	if not env_days.is_empty() and env_days.is_valid_int():
		_total_days = maxi(1, int(env_days))
	for arg in OS.get_cmdline_user_args():
		var text := String(arg)
		if text == "no-setup" or text == "--no-setup":
			_setup_enabled = false
		elif text.begins_with("--days="):
			var value := text.substr(7)
			if value.is_valid_int():
				_total_days = maxi(1, int(value))
		elif arg.begins_with("--seed="):
			_seed = int(arg.substr("--seed=".length()))


func _env_max_seconds() -> float:
	var env := OS.get_environment("PROBE_MAX_SECONDS")
	if not env.is_empty() and env.is_valid_float():
		return maxf(30.0, float(env))
	return DEFAULT_MAX_SECONDS


# ------------------------------------------------------------------ driver

## Same driver as the smoke test: step the world one day, drain the worker
## commit, then let the host replay the military days it owns.
func _advance_to(target_day: int) -> void:
	while _day < target_day:
		_day += 1
		_clock.current_day = float(_day)
		var phase := _clock.season_phase_for_day(_day)
		if _host.runtime_climate_authority_enabled:
			var capacity_deadline := Time.get_ticks_usec() + 60000000
			while not bool(_host.wait_for_climate_consumed(0).get("ok", true)) \
					and Time.get_ticks_usec() < capacity_deadline:
				_host._consume_runtime_commit_if_ready()
				await process_frame
			_host._consume_runtime_commit_if_ready()
		_host.run_daily_tick(_day, phase)
		_host.finish_daily_tick(0.0, {})
		if _host.runtime_climate_authority_enabled:
			var deadline := Time.get_ticks_usec() + 60000000
			while Time.get_ticks_usec() < deadline:
				_host._consume_runtime_commit_if_ready()
				var progress: Dictionary = _generator.get_runtime_thread_report()
				if int(progress.get("simulation_committed_day",
						progress.get("committed_day", -1))) >= _day - 1 - PIPELINE_DEPTH:
					break
				await process_frame
		var pulses := 0
		while _has_hard_barrier() and pulses < MAX_BARRIER_PULSES_PER_DAY:
			_clock.simulation_backpressure_pulse.emit(_day)
			pulses += 1
			await process_frame
		if _has_hard_barrier():
			_halted = true
			print("[military-probe] halted: hard barrier did not drain at day %d" % _day)
			return
		var economy_report: Dictionary = _generator.get_economy_report()
		if bool(economy_report.get("fatal", false)):
			_halted = true
			print("[military-probe] halted: economy fatal at day %d: %s" % [
				_day, str(economy_report.get("fatal_reason", ""))])
			return
	# Let the host drain committed military days (whole-graph ACTIVE replays at
	# most 4 per frame) before the report reads the military stores.
	for _frame in range(64):
		_host._consume_runtime_commit_if_ready()
		if _facade == null or int(_facade.report().get("last_step_day", -1)) \
				>= _day - 1 - PIPELINE_DEPTH:
			break
		await process_frame


func _has_hard_barrier() -> bool:
	return _clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")


# ------------------------------------------------------------------ setup

## The player action under test: pick a headcount target and put barracks at the
## capital. `set_target(country, 0, N)` = absolute headcount (same call the smoke
## test makes before the recruit window).

## Moves market stock into the country TREASURY (economy opcode 13). A sponsored
## state build debits treasury goods, and a fresh 60x40 country starts with an
## empty treasury, so without this the day loop parks forever on
## `country_treasury_goods_insufficient`.
func _pod_country_goods(cell: int, good: int, qty: int) -> Dictionary:
	var ext = _econ.world_ext() if _econ != null else null
	if ext == null or not ext.has_method("submit_economy_pod_commands"):
		return {"ok": false, "reason": "economy_pod_lane_unavailable"}
	return ext.submit_economy_pod_commands({
		"request_ids": PackedInt64Array([_next_seq()]),
		"opcodes": PackedInt32Array([13]),
		"transaction_ids": PackedInt64Array([0]),
		"session_epochs": PackedInt64Array([0]),
		"economy_generations": PackedInt64Array([0]),
		"payload0s": PackedInt64Array([qty]),
		"payload1s": PackedInt64Array([0]),
		"payload2s": PackedInt64Array([0]),
		"target_cells": PackedInt32Array([cell]),
		"target_countries": PackedInt64Array([good]),
		"target_cohorts": PackedInt64Array([int(_player)]),
		"target_buildings": PackedInt64Array([0]),
	})


func _next_seq() -> int:
	_seq += 1
	return _seq

func _apply_setup() -> void:
	_setup_done = true
	var barracks := _barracks_index(_facade.catalog())
	var target: Dictionary = _facade.set_target(_player, 0, TARGET_HEADCOUNT)
	print("[military-probe] setup day=%d set_target=%s barracks_index=%d" % [
		_day, JSON.stringify(_verdict(target)), barracks])
	# Build the way the production UI does: the economy bills the real materials
	# (`treasury_sponsored_build`) after the country holds the gate technology, and
	# only then does `state.build` book the core's construction cache. The old
	# single-call path silently built nothing, which is why an earlier long run
	# reported posts=0 for 5500 days and never exercised maintenance at all.
	var econ = _generator.get_economy_facade() \
		if _generator != null and _generator.has_method("get_economy_facade") else null
	var country = _generator.get_country_facade() \
		if _generator != null and _generator.has_method("get_country_facade") else null
	var rows: Array = _facade.catalog().get("state_buildings", [])
	if barracks >= 0 and not rows.is_empty() and econ != null and country != null:
		var tech := String((rows[barracks] as Dictionary).get("unlock_tech_id", ""))
		if not tech.is_empty():
			var granted: Dictionary = country.grant_technology(_player, StringName(tech),
				_day + 1, _day * 1000 + 7)
			print("[military-probe] setup gate tech %s = %s" % [tech,
				JSON.stringify(_verdict(granted))])
		# A sponsored build debits the country TREASURY of real goods; a fresh
		# country has none, so move the recipe out of the capital's market first.
		var mats: PackedInt32Array = (rows[barracks] as Dictionary).get(
			"material_goods", PackedInt32Array())
		var qtys: PackedInt64Array = (rows[barracks] as Dictionary).get(
			"material_qty", PackedInt64Array())
		for m in range(mats.size()):
			if m >= qtys.size():
				break
			var want := int(qtys[m]) * BARRACKS_TO_BUILD
			if want <= 0:
				continue
			print("[military-probe] setup treasury good %d qty=%d -> %s" % [mats[m], want,
				JSON.stringify(_verdict(_pod_country_goods(_capital, mats[m], want)))])
		var econ_id := int(_facade.state_building_economy_id(barracks))
		var type_ids: PackedStringArray = econ.building_type_ids()
		for index in range(BARRACKS_TO_BUILD):
			if econ_id < 0 or econ_id >= type_ids.size():
				print("[military-probe] setup economy type unresolved id=%d" % econ_id)
				break
			var sponsored: Dictionary = econ.treasury_sponsored_build(_player, _capital,
				StringName(type_ids[econ_id]), _day + 1, _day * 1000 + 10 + index)
			var booked: Dictionary = _facade.build_state_building(_player, _capital,
				barracks)
			print("[military-probe] setup barracks[%d] cell=%d sponsored=%s booked=%s" % [
				index, _capital, JSON.stringify(_verdict(sponsored)),
				JSON.stringify(_verdict(booked))])


static func _barracks_index(catalog: Dictionary) -> int:
	# Every shipped barracks carries a gate technology, so "unlock_bit < 0" no
	# longer finds one (it returned -1, and a -1 index silently built nothing for
	# a whole 5500-day run). Prefer a tech-free row when one exists, otherwise take
	# the first barracks and let the caller grant its gate tech.
	var buildings: Array = catalog.get("state_buildings", [])
	var first := -1
	for index in range(buildings.size()):
		var building: Dictionary = buildings[index]
		if int(building.get("role", -1)) != 0:
			continue
		if first < 0:
			first = index
		if String(building.get("unlock_tech_id", "")).is_empty():
			return index
	return first


# ------------------------------------------------------------------ report

func _print_report() -> void:
	var report: Dictionary = {}
	if _facade != null:
		report = _facade.report()
	var country: Dictionary = {}
	if _facade != null and _player != 0:
		country = _facade.country_snapshot(_player)
	var cell: Dictionary = {}
	if _facade != null and _capital >= 0:
		cell = _facade.cell_snapshot(_capital)
	var pop: Dictionary = await _population()
	# One compact line per report; JSON.stringify emits no newlines.
	print(JSON.stringify({
		"day": _day,
		"mil": {
			"soldiers_total": int(report.get("soldiers_total", -1)),
			"pending_intents": int(report.get("pending_intents", -1)),
			"last_step_day": int(report.get("last_step_day", -1)),
			"intents_emitted": int(report.get("intents_emitted", -1)),
			"military_day_ms": snappedf(float(report.get("military_day_ms", -1.0)), 0.01),
			# Goods ledger identity (received = stock + transit + consumed +
			# intercepted_out - intercepted_in + returned). It must stay 0 for the
			# whole run, and the maintenance counters are the only evidence that the
			# physical repair channel really ran rather than idling.
			"reconcile_delta": int(report.get("reconcile_delta", 0)),
			"ledger_received": int(report.get("ledger_received", 0)),
			"ledger_consumed": int(report.get("ledger_consumed", 0)),
			"maint_rows": int(report.get("maintenance_rows", 0)),
			"maint_need": int(report.get("maintenance_need_goods", 0)),
			"maint_met": int(report.get("maintenance_met_goods", 0)),
			"maint_spend": int(report.get("maintenance_spend", 0)),
			"maint_backlog": int(report.get("maintenance_backlog", 0)),
			"maint_disrepair": int(report.get("maintenance_disrepair_rows", 0)),
			"maint_ms": snappedf(float(report.get("maintenance_ms", -1.0)), 0.001),
		},
		"country": {
			"soldiers_total": int(country.get("soldiers_total", -1)),
			"soldiers_militia": int(country.get("soldiers_militia", -1)),
			"post_count": int(country.get("post_count", -1)),
		},
		"cell": {
			"quota": int(cell.get("quota", -1)),
			"pending_enlist": int(cell.get("pending_enlist", -1)),
			"posts": int(cell.get("post_count", -1)),
			"present": int(cell.get("present", -1)),
		},
		"pop": pop,
	}))


## Capital population: `population` plus the profession lanes that matter for the
## convert (soldier = destination signature, unemployed = source signature).
## Unreadable turns into -1 lanes instead of an assertion: the probe reports.
func _population() -> Dictionary:
	var missing := {"population": -1, "soldier": -1, "unemployed": -1}
	if _econ == null or _capital < 0:
		return missing
	var snapshot: Dictionary = {}
	for _attempt in range(POP_READ_ATTEMPTS):
		snapshot = _econ.population_cell_snapshot(_capital)
		if snapshot.has("population") and snapshot.has("populations"):
			return {
				"population": int(snapshot.get("population", -1)),
				"soldier": _profession_population(snapshot, "soldier"),
				"unemployed": _profession_population(snapshot, "unemployed"),
			}
		# The worker publishes the read view at its day boundary; give it a few
		# frames to do so before giving up on this report line.
		_host._consume_runtime_commit_if_ready()
		await process_frame
	if not _pop_diag_printed:
		_pop_diag_printed = true
		print("[military-probe] pop unavailable day=%d %s" % [_day, JSON.stringify({
			"ok": bool(snapshot.get("ok", false)),
			"busy": bool(snapshot.get("busy", false)),
			"code": String(snapshot.get("code", "")),
			"reason": String(snapshot.get("reason", "")),
			"read_view_pending": bool(snapshot.get("read_view_pending", false)),
			"details_pending": bool(snapshot.get("details_pending", false)),
		})])
	return missing


func _warm_population() -> void:
	if _econ == null or _capital < 0:
		return
	var snapshot: Dictionary = _econ.population_cell_snapshot(_capital)
	var soldier := -1
	if snapshot.has("populations"):
		soldier = _profession_population(snapshot, "soldier")
	print("[military-probe] pop warmup %s" % JSON.stringify({
		"ok": bool(snapshot.get("ok", false)),
		"has_population": snapshot.has("population"),
		"busy": bool(snapshot.get("busy", false)),
		"population": int(snapshot.get("population", -1)),
		"soldier": soldier,
	}))


func _print_progress(label: String) -> void:
	var thread: Dictionary = _generator.get_runtime_thread_report() \
		if _generator != null and _generator.has_method("get_runtime_thread_report") else {}
	var mil: Dictionary = _facade.report() if _facade != null else {}
	var should_run_next := false
	var host_last_commit := -1
	if _facade != null:
		should_run_next = bool(_facade.should_run(int(mil.get("last_step_day", 0)) + 1))
	if _host.has_method("military_report"):
		host_last_commit = int(_host.military_report().get("host_last_commit_day", -1))
	print("[military-probe] progress %s %s" % [label, JSON.stringify({
		"driver_day": _day,
		"committed": int(thread.get("simulation_committed_day",
			thread.get("committed_day", -1))),
		"host_state": String(thread.get("simulation_host_state", "")),
		"mil_last_step_day": int(mil.get("last_step_day", -1)),
		"host_mil_last_commit_day": host_last_commit,
		"should_run_next": should_run_next,
	})])


# ------------------------------------------------------------------ helpers

## Same resolution as the smoke test: profession rows are dense ids, so the
## stable id is looked up through the snapshot's own profession id table.
static func _profession_population(snapshot: Dictionary, stable_id: String) -> int:
	var catalog_ids: PackedStringArray = snapshot.get("profession_stable_ids",
		PackedStringArray())
	var rows: PackedInt32Array = snapshot.get("profession_ids", PackedInt32Array())
	var pops: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var total := 0
	for row in range(mini(rows.size(), pops.size())):
		var profession := int(rows[row])
		if profession >= 0 and profession < catalog_ids.size() \
				and String(catalog_ids[profession]) == stable_id:
			total += int(pops[row])
	return total


static func _verdict(result: Dictionary) -> Dictionary:
	var out := {"ok": bool(result.get("ok", false))}
	var reason := String(result.get("reason", ""))
	if reason.is_empty():
		reason = String(result.get("code", ""))
	var rejected = result.get("rejected", [])
	if reason.is_empty() and rejected is Array and not (rejected as Array).is_empty():
		reason = JSON.stringify((rejected as Array)[0])
	if not reason.is_empty():
		out["reason"] = reason
	for key in ["accepted", "rejected_local", "sequence"]:
		if result.has(key):
			out[key] = result[key]
	return out


static func _compact(value: Dictionary) -> Dictionary:
	var out := {}
	for key in value.keys():
		var item = value[key]
		if item is Array or item is Dictionary or typeof(item) >= TYPE_PACKED_BYTE_ARRAY:
			continue
		out[key] = item
	return out
