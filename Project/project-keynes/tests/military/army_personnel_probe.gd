# army_personnel_probe.gd
# Army PERSONNEL LANE report probe (army-personnel contract §2.3). Like
# military_living_world_probe.gd it is NOT an assertion suite: it always exits 0
# and prints one compact JSON line every 5 days so a human (or a log diff) can
# watch people actually leave the home cell, live in the formation's Economy lane
# and come back when the formation is disbanded.
#
# Headless (verification):
#   .../Godot_v4.6.2-stable_win64_console.exe --headless --path Project/project-keynes \
#     -s res://tests/military/army_personnel_probe.gd -- --days=120
# In-game manual check (same script, real renderer, opens a window):
#   .../Godot_v4.6.2-stable_win64_console.exe --path Project/project-keynes \
#     -s res://tests/military/army_personnel_probe.gd
#
# User args (after `--`):  --days=N (default 120)   no-setup
#
# World boot is identical to military_runtime_smoke_test.gd / the living-world
# probe (same seed/size/formal start), so the numbers here line up with those.
#
# Per report line, for every player army (and the capital):
#   day, army handle, personnel (Economy lane heads), headcount (Military lots),
#   personnel_pending (in flight), lane funds, satisfaction (ration ratio the
#   core publishes to the lane + any lane fields the loaded economy exposes),
#   cell, ration stock still held by the formation.
# Plus the capital cell's soldier cohort, so the embark drop is visible.
#
# Setup mode (default): day 40 sets the player force target and builds 3
# barracks at the capital (the living-world probe's setup), then the army is
# created at the capital on day 62 -- after recruitment has filled the barracks.
extends SceneTree

const SEED := 20260727
const MAP_W := 60
const MAP_H := 40
const FOREIGN_COUNT := 3
const DEFAULT_DAYS := 120
const REPORT_EVERY_DAYS := 5
const SETUP_DAY := 40
const ARMY_DAY := 62
const TARGET_HEADCOUNT := 12
const BARRACKS_TO_BUILD := 3
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096
## Bounded retry for the Economy population read (see the living-world probe).
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
		print("[army-lane-probe] watchdog timeout after %.0fs; quitting 0" % limit_sec)
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
var _setup_enabled := true
var _setup_done := false
var _army_created := false
var _army_handle := 0
var _halted := false
var _logger: ErrorCounter = null


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
		print("[army-lane-probe] SKIP DCWorldExt unavailable")
		return
	var api_probe = ClassDB.instantiate("DCWorldExt")
	var has_api: bool = api_probe != null \
		and api_probe.has_method("run_military_daily") \
		and api_probe.has_method("get_military_army")
	api_probe = null
	if not has_api:
		print("[army-lane-probe] SKIP military bindings missing in loaded dots_ext")
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
	_host.initial_seed = SEED
	get_root().add_child(_host)
	_host.configure(null, null, _clock)
	var config := NewGameConfig.create_default()
	config.country.name = "Army Lane Probe"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = SEED
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not bool(session.get("ok", false)):
		print("[army-lane-probe] SKIP session configure failed: %s" % JSON.stringify(
			_compact(session)))
		return
	await _host.generate_world(SEED)
	_generator = _host.get_generator()
	var map: MapData = _host.get_current_map()
	if map == null or _generator == null:
		print("[army-lane-probe] SKIP world generation failed")
		return
	var runtime_ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	if _host._native_environment_active and runtime_ext != null \
			and runtime_ext.has_method("set_runtime_clock"):
		runtime_ext.set_runtime_clock(false, 50.0)

	_facade = _generator.get_military_facade() \
		if _generator.has_method("get_military_facade") else null
	_econ = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	if _facade == null or not _facade.is_configured():
		print("[army-lane-probe] SKIP military facade not configured: %s" % JSON.stringify(
			{} if _facade == null else _compact(_facade.configure_result())))
		return
	var country = _generator.get_country_facade() \
		if _generator.has_method("get_country_facade") else null
	var start: Dictionary = _generator.gameplay_start_report()
	_capital = int(start.get("cell", -1))
	if country == null or _capital < 0:
		print("[army-lane-probe] SKIP player capital unresolved (cell=%d)" % _capital)
		return
	_player = int(country.cell_summary(_capital).get("country_handle", 0))
	if _player == 0:
		print("[army-lane-probe] SKIP player country handle unresolved at cell %d" % _capital)
		return
	var report: Dictionary = _facade.report()
	print("[army-lane-probe] boot %s" % JSON.stringify({
		"graph_active": bool(_generator.runtime_graph_active()),
		"capital": _capital,
		"player": _player,
		"days": _total_days,
		"setup_day": SETUP_DAY if _setup_enabled else -1,
		"army_day": ARMY_DAY if _setup_enabled else -1,
		"target": TARGET_HEADCOUNT,
		"barracks": BARRACKS_TO_BUILD,
		"climate_authority": _host._native_environment_active,
		"terrain_ready": bool(_facade.terrain_ready()),
		# False on a build whose economy has no ArmyPersonnelStore bindings: the
		# probe still runs, the lane columns just read -1.
		"army_lane_supported": bool(_daily_lane_fields().get("army_lane_supported", false)),
	}))

	while _day < _total_days and not _halted:
		await _advance_to(_day + 1)
		if _halted:
			break
		if _setup_enabled and not _setup_done and _day >= SETUP_DAY:
			_apply_setup()
		if _setup_enabled and not _army_created and _day >= ARMY_DAY:
			_create_army()
		if _day % REPORT_EVERY_DAYS == 0 or _day >= _total_days:
			await _print_report()
	if not _halted and _day % REPORT_EVERY_DAYS != 0:
		await _print_report()
	var final := {
		"day": _day,
		"halted": _halted,
		"setup_done": _setup_done,
		"army": _army_handle,
		"errors": 0 if _logger == null else _logger.errors.size(),
	}
	print("[army-lane-probe] final %s" % JSON.stringify(final))
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


func _env_max_seconds() -> float:
	var env := OS.get_environment("PROBE_MAX_SECONDS")
	if not env.is_empty() and env.is_valid_float():
		return maxf(30.0, float(env))
	return DEFAULT_MAX_SECONDS


# ------------------------------------------------------------------ driver

## Same driver as the smoke test / living-world probe: step the world one day,
## drain the worker commit, then let the host replay the military days it owns.
func _advance_to(target_day: int) -> void:
	while _day < target_day:
		_day += 1
		_clock.current_day = float(_day)
		var phase := _clock.season_phase_for_day(_day)
		_host._admit_runtime_calendar(_day + 1)
		_host.finish_daily_tick(0.0, {})
		if _host._native_environment_active:
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
			print("[army-lane-probe] halted: hard barrier did not drain at day %d" % _day)
			return
		var economy_report: Dictionary = _generator.get_economy_report()
		if bool(economy_report.get("fatal", false)):
			_halted = true
			print("[army-lane-probe] halted: economy fatal at day %d: %s" % [
				_day, str(economy_report.get("fatal_reason", ""))])
			return
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

func _apply_setup() -> void:
	_setup_done = true
	var barracks := _barracks_index(_facade.catalog())
	var target: Dictionary = _facade.set_target(_player, 0, TARGET_HEADCOUNT)
	print("[army-lane-probe] setup day=%d set_target=%s barracks_index=%d" % [
		_day, JSON.stringify(_verdict(target)), barracks])
	for index in range(BARRACKS_TO_BUILD):
		var built: Dictionary = _facade.build_state_building(_player, _capital,
			maxi(0, barracks))
		print("[army-lane-probe] setup state.build[%d] cell=%d = %s" % [
			index, _capital, JSON.stringify(_verdict(built))])


## The player action under test: form a field army out of the capital garrison.
## army.create boards every soldier lot at the cell, so the capital cohort must
## shrink by exactly the formation's personnel on the next Economy day.
func _create_army() -> void:
	_army_created = true
	var soldiers_before := await _cell_soldiers(_capital)
	var created: Dictionary = _facade.create_army(_player, _capital, {})
	_army_handle = 0
	var armies: Array = _facade.armies(_player)
	if not armies.is_empty():
		_army_handle = int((armies[0] as Dictionary).get("handle", 0))
	print("[army-lane-probe] army.create day=%d = %s capital_soldier=%d armies=%d handle=%d" % [
		_day, JSON.stringify(_verdict(created)), soldiers_before, armies.size(), _army_handle])


static func _barracks_index(catalog: Dictionary) -> int:
	var buildings: Array = catalog.get("state_buildings", [])
	for index in range(buildings.size()):
		var building: Dictionary = buildings[index]
		if int(building.get("role", -1)) == 0 and int(building.get("unlock_bit", -1)) < 0:
			return index
	return -1


# ------------------------------------------------------------------ report

func _print_report() -> void:
	var report: Dictionary = {}
	if _facade != null:
		report = _facade.report()
	var rows: Array = []
	var armies: Array = []
	if _facade != null and _player != 0:
		armies = _facade.armies(_player)
	for entry in armies:
		var row: Dictionary = entry
		var handle := int(row.get("handle", 0))
		if handle == 0:
			continue
		var detail: Dictionary = _facade.army(handle)
		rows.append({
			"handle": handle,
			# What Economy holds in the formation's lane row, and what Military
			# books for it: they are the same people and must not diverge.
			"personnel": int(detail.get("personnel", -1)),
			"headcount": int(detail.get("headcount", -1)),
			"personnel_pending": int(detail.get("personnel_pending", -1)),
			"lane_supported": bool(detail.get("lane_supported", false)),
			# Military's own copy of the lane cash (0 until the wage transfer moves).
			"lane_funds": int(detail.get("funds", 0)),
			# Ration satisfaction the core publishes to the lane this day, and the
			# ration need units still held by the formation.
			"satisfaction_q16": int(detail.get("ration_ratio_q16", -1)),
			"supply_ratio_q16": int(detail.get("supply_ratio_q16", -1)),
			"ration_stock": int(detail.get("ration_stock", -1)),
			"cell": int(detail.get("cell", -1)),
			"morale_q16": int(detail.get("morale_q16", -1)),
			"organization_q16": int(detail.get("organization_q16", -1)),
			"economy_lane": _economy_lane_fields(handle),
		})
	# One compact line per report; JSON.stringify emits no newlines.
	print(JSON.stringify({
		"day": _day,
		"mil": {
			"soldiers_total": int(report.get("soldiers_total", -1)),
			"armies_active": int(report.get("armies_active", -1)),
			"pending_intents": int(report.get("pending_intents", -1)),
			"last_step_day": int(report.get("last_step_day", -1)),
			"intents_emitted": int(report.get("intents_emitted", -1)),
		},
		# Lane telemetry lives in the DAILY report (run_military_daily), not in the
		# cold get_military_report summary.
		"lane_day": _daily_lane_fields(),
		"capital_soldier": await _cell_soldiers(_capital),
		"armies": rows,
	}))


## Lane telemetry from the last military day (military facade keeps it after
## every run_daily). Empty when the day never ran or the bridge is older.
func _daily_lane_fields() -> Dictionary:
	var daily: Dictionary = _facade.last_daily_report() if _facade != null else {}
	var out := {}
	for key in ["army_lane_ops", "army_lane_supported", "army_lane_trimmed"]:
		if daily.has(key):
			out[key] = daily[key]
	return out


## Any army-lane views the loaded economy exposes. The bindings are Economy's
## (army-personnel contract §1.4) and may not exist yet, so this is duck-typed:
## a probe must report, not crash, on a build without the lane.
func _economy_lane_fields(handle: int) -> Dictionary:
	if _econ == null:
		return {}
	for method in ["military_army_lane", "army_lane_snapshot", "military_army_population"]:
		if not _econ.has_method(method):
			continue
		var value = _econ.call(method, handle)
		if value is Dictionary or value is int or value is float:
			return {"source": method, "value": value}
		return {"source": method, "value": str(value)}
	return {}


## Capital / destination soldier cohort, retried while the Economy read view is
## still being published by the worker. -1 when it never becomes readable.
func _cell_soldiers(cell: int) -> int:
	if _econ == null or cell < 0:
		return -1
	var snapshot: Dictionary = _econ.population_cell_snapshot(cell)
	for _attempt in range(POP_READ_ATTEMPTS):
		if snapshot.has("populations") and snapshot.has("profession_stable_ids"):
			return _profession_population(snapshot, "soldier")
		_host._consume_runtime_commit_if_ready()
		await process_frame
		snapshot = _econ.population_cell_snapshot(cell)
	return -1


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
