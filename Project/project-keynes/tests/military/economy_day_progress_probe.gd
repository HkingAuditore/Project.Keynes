# economy_day_progress_probe.gd
# Read-only diagnostic probe for the military -> Economy conversion bridge.
#   godot --headless --path . -s res://tests/military/economy_day_progress_probe.gd
#
# Boots the SAME headless world as tests/military/military_runtime_smoke_test.gd
# (formal session config, world generation, day advancing, helpers), opens the
# recruit window (force target + barracks) exactly like the smoke test, then over
# PROBE_DAYS days prints ONE line per day:
#   world day | economy last_committed_day / epoch state / worker-authoritative
#   flags / busy | military pending_intents + last_step_day | capital population
#   snapshot ok?
#
# Question under test: does the economy day advance far enough that a POD command
# queued on day D is planned/committed on day D+1? Prints a final verdict plus the
# POD receipts (if any) for the military's COMMAND_MILITARY_CONVERT_COHORT.
#
# This script only reads reports/snapshots and polls receipts. It never mutates
# economy state beyond the same setup the smoke test performs.
extends SceneTree

const SEED := 20260727
const MAP_W := 60
const MAP_H := 40
const FOREIGN_COUNT := 3
const WARMUP_DAYS := 6
const PROBE_DAYS := 40
const TARGET_HEADCOUNT := 12
const BARRACKS_TO_BUILD := 3
const PIPELINE_DEPTH := 3
const MAX_BARRIER_PULSES_PER_DAY := 4096
const MAX_RECEIPTS_PER_DAY := 64

## RuntimeEconomyCommandReceiptCode (gdext/src/runtime_economy_pod.h:197).
const RECEIPT_CODE_NAMES := {
	1: "Accepted", 2: "Pending", 3: "Committed",
	4: "RejectedAtAdmission", 5: "RejectedAtExecution", 6: "Faulted",
}

## Thread-report keys that describe who owns the economy day.
const THREAD_KEYS := [
	"simulation_thread_mode", "requested_simulation_thread_mode",
	"authoritative_domain_mask", "economy_worker_authoritative",
	# worker clock: world_ext_simulation_host exposes `committed_day`; the graph
	# bundle calls the same cursor `simulation_committed_day`.
	"committed_day", "simulation_committed_day",
	"economy_pod_committed_day", "economy_pod_epoch_sample_day",
	"economy_pod_operation_gate_mask", "economy_pod_active_ready",
	"economy_pod_command_verify_count", "economy_pod_command_recapture_count",
	"economy_stage_ops_mutate", "economy_production_writer_effective",
	"economy_production_writer_requested", "simulation_host_state",
]

## Report keys that expose the economy day / epoch / busy state.
const ECON_KEYS := [
	"last_committed_day", "current_day", "sample_day", "commit_day", "epoch_active",
	"epoch_id", "committed_generation", "stage", "published_day", "report_mode",
	"report_boundary_pending", "report_available", "fatal", "fatal_reason",
	"dbg_stage_ops_epoch_active", "simulation_path",
]

var _clock: WorldClock = null
var _host: WorldRuntimeHost = null
var _generator = null
var _ext = null
var _facade = null
var _economy = null
var _capital := -1
var _player := 0
var _day := 0
var _rows: Array[Dictionary] = []
var _receipts: Array[Dictionary] = []


func _init() -> void:
	# Nodes added during SceneTree._init are not inside the tree yet, and
	# WorldRuntimeHost.generate_world bails out when !is_inside_tree().
	await process_frame
	var code: int = await _run()
	print("economy day progress probe: exit %d" % code)
	quit(code)


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		print("SKIP DCWorldExt unavailable")
		return 0
	var probe = ClassDB.instantiate("DCWorldExt")
	if probe == null or not probe.has_method("configure_military") \
			or not probe.has_method("run_military_daily"):
		print("SKIP military bindings missing in loaded dots_ext")
		return 0
	probe = null

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
	config.country.name = "Economy Day Probe"
	config.country.foreign_count = FOREIGN_COUNT
	config.base.map_width = MAP_W
	config.base.map_height = MAP_H
	config.base.initial_seed = SEED
	var session: Dictionary = _host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	print("[econ-probe] session ok=%s kind=%s" % [
		str(session.get("ok", false)), str(session.get("kind", "?"))])
	await _host.generate_world(SEED)
	var map: MapData = _host.get_current_map()
	_generator = _host.get_generator()
	if map == null or _generator == null:
		print("[econ-probe] FAIL world not generated")
		return 1
	_ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	_economy = _generator.get_economy_facade() \
		if _generator.has_method("get_economy_facade") else null
	_facade = _generator.get_military_facade() \
		if _generator.has_method("get_military_facade") else null
	if _host._native_environment_active and _ext != null \
			and _ext.has_method("set_runtime_clock"):
		_ext.set_runtime_clock(false, 50.0)

	# ---- boot evidence: which graph/authority mode does this world run in? ----
	var graph_active := bool(_generator.runtime_graph_active()) \
		if _generator.has_method("runtime_graph_active") else false
	var auth_diag: Dictionary = _host.climate_authority_diagnostics() \
		if _host.has_method("climate_authority_diagnostics") else {}
	var policy: Dictionary = auth_diag.get("authority_policy", {})
	var boot_thread := _thread_fields()
	print("[econ-probe] boot graph_active=%s climate_authority_enabled=%s policy_enabled=%s policy_reason=%s" % [
		str(graph_active), str(_host._native_environment_active),
		str(policy.get("enabled", "?")), str(policy.get("reason", "?"))])
	print("[econ-probe] boot thread %s" % JSON.stringify(boot_thread))
	print("[econ-probe] boot econ %s" % JSON.stringify(_econ_fields()))
	var country = _generator.get_country_facade()
	var start: Dictionary = _generator.gameplay_start_report()
	_capital = int(start.get("cell", -1))
	_player = int(country.cell_summary(_capital).get("country_handle", 0)) \
		if _capital >= 0 else 0
	if _facade == null or not _facade.is_configured() or _player == 0:
		print("[econ-probe] FAIL facade/capital/player unavailable capital=%d player=%d" % [
			_capital, _player])
		return 1
	print("[econ-probe] boot capital=%d player=%d econ_configured=%s" % [
		_capital, _player, str(_economy != null and _economy.report().size() > 0)])

	# ---- same recruit window as the smoke test ----
	var early: Dictionary = _facade.set_target(_player, 0, TARGET_HEADCOUNT)
	print("[econ-probe] pre-first-step set_target=%s" % JSON.stringify(early))
	await _advance_days_to(WARMUP_DAYS)
	var barracks := _barracks_index(_facade.catalog())
	var target: Dictionary = _facade.set_target(_player, 0, TARGET_HEADCOUNT)
	print("[econ-probe] warmup day=%d set_target ok=%s barracks=%d" % [
		_day, str(target.get("ok", false)), barracks])
	for _i in range(BARRACKS_TO_BUILD):
		var built: Dictionary = _facade.build_state_building(
			_player, _capital, maxi(0, barracks))
		print("[econ-probe] warmup state.build ok=%s reason=%s" % [
			str(built.get("ok", false)), str(built.get("reason", ""))])

	# ---- 40 daily lines ----
	print("[econ-probe] ---- per-day probe (%d days) ----" % PROBE_DAYS)
	for _n in range(PROBE_DAYS):
		await _step_one_day()
		_collect_receipts()
		var row := _sample_day()
		_rows.append(row)
		# `last_committed_day` is only published by the FULL economy report; under
		# worker-owned ACTIVE the served report may be the compact slice, so also
		# print current_day/commit_day/generation and the thread-side committed
		# cursor. econ_lcd=absent means "field not in this report shape".
		print("[econ-probe] d=%d econ_lcd=%s mode=%s epoch=%s cur=%s sample=%s commit=%s gen=%s sim_committed=%s thread=%s mask=%s mil_pending=%s mil_step=%s mil_soldiers=%s intents_emitted=%s pod_lcd=%s pop_ok=%s pop_busy=%s" % [
			_day, row.get("econ_lcd", "?"), row.get("report_mode", "?"),
			row.get("epoch_active", "?"), row.get("current_day", "?"),
			row.get("sample_day", "?"), row.get("commit_day", "?"),
			row.get("committed_generation", "?"), row.get("sim_committed", "?"),
			row.get("thread_mode", "?"), row.get("auth_mask", "?"),
			row.get("mil_pending", "?"), row.get("mil_step", "?"),
			row.get("mil_soldiers", "?"), row.get("intents_emitted", "?"),
			row.get("pod_lcd", "?"), str(row.get("pop_ok", "?")),
			str(row.get("pop_busy", "?"))])
		if not bool(row.get("pop_ok", false)):
			print("[econ-probe] d=%d population snapshot UNAVAILABLE reason=%s busy=%s" % [
				_day, str(row.get("pop_reason", "")), str(row.get("pop_busy", false))])
	return _verdict(boot_thread, graph_active)


# ------------------------------------------------------------------ day driver

## One day of the smoke test's `_advance_to` body: clock, climate handoff,
## run_daily_tick + finish, committed-day wait, barrier drain, fatal check.
func _step_one_day() -> void:
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
	if bool(_generator.get_economy_report().get("fatal", false)):
		print("[econ-probe] d=%d FATAL economy %s" % [_day, str(
			_generator.get_economy_report().get("fatal_reason", ""))])


func _advance_days_to(target_day: int) -> void:
	while _day < target_day:
		await _step_one_day()


func _has_hard_barrier() -> bool:
	return _clock._simulation_backpressure_sources.has(&"country_day_barrier") \
		or _clock._simulation_backpressure_sources.has(&"economy_day_barrier")


# ------------------------------------------------------------------ sampling

func _sample_day() -> Dictionary:
	var econ: Dictionary = _econ_fields()
	var thread := _thread_fields()
	var mil: Dictionary = _facade.report() if _facade != null else {}
	var pop: Dictionary = {}
	if _economy != null:
		pop = _economy.population_cell_snapshot(_capital)
	var row := econ.duplicate()
	row["driver_day"] = _day
	row["econ_lcd"] = econ.get("last_committed_day", "absent")
	row["pod_lcd"] = thread.get("economy_pod_committed_day", "?")
	row["sim_committed"] = thread.get("simulation_committed_day",
		thread.get("committed_day", "?"))
	row["thread_mode"] = thread.get("simulation_thread_mode", "?")
	row["auth_mask"] = thread.get("authoritative_domain_mask", "?")
	row["mil_pending"] = mil.get("pending_intents", "?")
	row["mil_step"] = mil.get("last_step_day", "?")
	row["mil_soldiers"] = mil.get("soldiers_total", "?")
	row["intents_emitted"] = mil.get("intents_emitted", "?")
	row["pop_has_populations"] = pop.has("populations")
	row["pop_ok"] = bool(pop.has("populations"))
	row["pop_busy"] = pop.get("busy", false)
	row["pop_reason"] = str(pop.get("reason", pop.get("code", "")))
	row["soldier_cohort"] = _profession_population(pop, "soldier")
	row["unemployed_cohort"] = _profession_population(pop, "unemployed")
	return row


func _econ_fields() -> Dictionary:
	var out := {}
	if _generator == null or not _generator.has_method("get_economy_report"):
		return out
	var report: Dictionary = _generator.get_economy_report()
	for key in ECON_KEYS:
		if report.has(key):
			out[key] = report[key]
	out["report_keys"] = report.size()
	return out


func _thread_fields() -> Dictionary:
	var out := {}
	if _generator == null or not _generator.has_method("get_runtime_thread_report"):
		return out
	var report: Dictionary = _generator.get_runtime_thread_report()
	for key in THREAD_KEYS:
		if report.has(key):
			out[key] = report[key]
	return out


## The military bridge pushes opcode 24 through the POD queue when the legacy
## economy ingress is closed. Drain the receipts so their code/reason is visible.
func _collect_receipts() -> void:
	if _ext == null or not _ext.has_method("poll_economy_pod_receipts"):
		return
	var polled: Dictionary = _ext.poll_economy_pod_receipts(MAX_RECEIPTS_PER_DAY)
	if not bool(polled.get("ok", false)):
		return
	var rows: Array = polled.get("receipts", [])
	for receipt in rows:
		var row: Dictionary = receipt
		row["day"] = _day
		_receipts.append(row)
		print("[econ-probe] d=%d POD receipt opcode=%d code=%s reason=%s request=%d" % [
			_day, int(row.get("opcode", -1)),
			RECEIPT_CODE_NAMES.get(int(row.get("code", -1)), str(row.get("code", "?"))),
			str(row.get("reason", "")), int(row.get("request_id", -1))])


# ------------------------------------------------------------------ verdict

func _verdict(boot_thread: Dictionary, graph_active: bool) -> int:
	var last: Dictionary = _rows[_rows.size() - 1] if not _rows.is_empty() else {}
	var first: Dictionary = _rows[0] if not _rows.is_empty() else {}
	# Committed-day witness: the full report exposes last_committed_day, the
	# compact slice does not; fall back to current_day so the span is measurable.
	var day_first := _day_witness(first)
	var day_last := _day_witness(last)
	var pod_first := _as_int(first.get("pod_lcd", -1), -1)
	var pod_last := _as_int(last.get("pod_lcd", -1), -1)
	var gen_first := _as_int(first.get("committed_generation", -1), -1)
	var gen_last := _as_int(last.get("committed_generation", -1), -1)
	var mil_step := _as_int(last.get("mil_step", -1), -1)
	var pending := _as_int(last.get("mil_pending", -1), -1)
	var soldiers := _as_int(last.get("mil_soldiers", -1), -1)
	var soldier_cohort := _as_int(last.get("soldier_cohort", -1), -1)
	var pop_ok_days := 0
	var busy_days := 0
	var committed_receipts := 0
	var rejected_receipts := 0
	var faulted_receipts := 0
	var reject_reasons := {}
	for row in _rows:
		if bool(row.get("pop_ok", false)):
			pop_ok_days += 1
		if bool(row.get("pop_busy", false)):
			busy_days += 1
	for receipt in _receipts:
		match int(receipt.get("code", -1)):
			3:
				committed_receipts += 1
			4, 5, 6:
				if int(receipt.get("code", -1)) == 6:
					faulted_receipts += 1
				else:
					rejected_receipts += 1
				var reason := str(receipt.get("reason", ""))
				reject_reasons[reason] = int(reject_reasons.get(reason, 0)) + 1
	print("[econ-probe] ---- verdict evidence ----")
	print("[econ-probe] boot graph_active=%s thread_mode=%s mask=%s stage_ops_mutate=%s writer=%s | end thread_mode=%s mask=%s" % [
		str(graph_active), str(boot_thread.get("simulation_thread_mode", "?")),
		str(boot_thread.get("authoritative_domain_mask", "?")),
		str(boot_thread.get("economy_stage_ops_mutate", "?")),
		str(boot_thread.get("economy_production_writer_effective", "?")),
		str(last.get("thread_mode", "?")), str(last.get("auth_mask", "?"))])
	print("[econ-probe] driver_day=%d economy_day %s->%s pod_committed_day %s->%s committed_generation %s->%s mil_last_step_day=%d" % [
		_day, str(day_first), str(day_last), str(pod_first), str(pod_last),
		str(gen_first), str(gen_last), mil_step])
	print("[econ-probe] final pending_intents=%d soldiers_total=%d economy_soldier_cohort=%d" % [
		pending, soldiers, soldier_cohort])
	print("[econ-probe] population snapshot readable days=%d/%d busy_days=%d" % [
		pop_ok_days, _rows.size(), busy_days])
	print("[econ-probe] POD receipts total=%d committed=%d rejected=%d faulted=%d" % [
		_receipts.size(), committed_receipts, rejected_receipts, faulted_receipts])
	for reason in reject_reasons.keys():
		print("[econ-probe]   reject reason=%s count=%d" % [
			str(reason), int(reject_reasons[reason])])
	var day_advances := pod_last >= pod_first + PROBE_DAYS - PIPELINE_DEPTH - 4 \
		or day_last >= day_first + PROBE_DAYS - PIPELINE_DEPTH - 4 \
		or gen_last >= gen_first + PROBE_DAYS - PIPELINE_DEPTH - 4
	print("[econ-probe] VERDICT: economy POD stage %s in this world" % [
		"RUNS" if day_advances else "DOES NOT RUN"])
	if day_advances:
		print("[econ-probe]   economy day advances ~1/day (pod_committed_day %d, committed_generation %d); lag vs driver=%s day(s)" % [
			pod_last, gen_last, str(_day - day_last)])
	else:
		print("[econ-probe]   economy day stalled: driver day=%d, witness last=%s" % [
			_day, str(day_last)])
	# The command bridge is a separate question from day advancement.
	if committed_receipts == 0 and rejected_receipts + faulted_receipts > 0:
		print("[econ-probe]   OPCODE 24 REJECTED: receipts committed=0 rejected=%d -> the command queued on day D is NOT planned/committed on D+1, so no Economy cohort is converted (soldiers_total=%d)" % [
			rejected_receipts, soldiers])
	elif committed_receipts > 0:
		print("[econ-probe]   opcode 24 committed %d time(s) (soldiers_total=%d, soldier cohort=%d)" % [
			committed_receipts, soldiers, soldier_cohort])
	elif _receipts.is_empty():
		print("[econ-probe]   no POD receipts observed (bridge never reached the POD queue)")
	return 0


## Committed-day witness for one sampled day: prefer last_committed_day, else
## current_day, else sample_day; -1 when the report shape carries none of them.
func _day_witness(row: Dictionary) -> int:
	for key in ["last_committed_day", "current_day", "sample_day"]:
		if row.has(key):
			return _as_int(row[key], -1)
	return -1


static func _as_int(value, fallback: int) -> int:
	if value is int or value is float or value is bool:
		return int(value)
	if value is String and String(value).is_valid_int():
		return int(value)
	return fallback


# ------------------------------------------------------------------ helpers

static func _barracks_index(catalog: Dictionary) -> int:
	var buildings: Array = catalog.get("state_buildings", [])
	for index in range(buildings.size()):
		var building: Dictionary = buildings[index]
		if int(building.get("role", -1)) == 0 and int(building.get("unlock_bit", -1)) < 0:
			return index
	return -1


static func _profession_population(snapshot: Dictionary, stable_id: String) -> int:
	var catalog_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var rows: PackedInt32Array = snapshot.get("profession_ids", PackedInt32Array())
	var pops: PackedInt64Array = snapshot.get("populations", PackedInt64Array())
	var total := 0
	for row in range(mini(rows.size(), pops.size())):
		var profession := int(rows[row])
		if profession >= 0 and profession < catalog_ids.size() \
				and String(catalog_ids[profession]) == stable_id:
			total += int(pops[row])
	return total
