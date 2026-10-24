extends SceneTree

## X6-a acceptance on the production ACTIVE worker path.
##
## The fixture applies the generated country factor definition through the real
## worker Modifier ingress, drives fixed worker day boundaries, and reads the
## point ledger from the committed ideology snapshot. Population is increased
## through the Economy POD ingress so the per-term multiplier is visible without
## touching live Economy stores.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const MODIFIER_DOMAIN_COUNTRY := 1
const MODIFIER_SCOPE_ENTITY := 2
const MODIFIER_DEFINITION := &"ideology.country.ideology.point_population_factor.gain"
const TEST_SOURCE_TYPE := 91
const TEST_PRODUCER_ID := 120
const POPULATION_STEP := 4096
const WorkerWaitHelper = preload(
	"res://tests/ideology/ideology_worker_wait_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _generator: MapGenerator
var _handle := 0
var _country_slot := 0
var _anchor := -1
var _population_cell := -1
var _population_cohort := 0
var _opinion_country_row := -1
var _opinion_class_count := 0
var _opinion_population := PackedInt64Array()
var _opinion_satisfaction_q16 := PackedInt32Array()
var _opinion_weighted := PackedInt64Array()
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _modifier_sequence := 0
var _tick := 0
var _current_factor := NAN


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x6a worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var fixture := await _build_world()
	if fixture.is_empty():
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_generator = fixture["generator"]
	_handle = int(fixture["handle"])
	_country_slot = int(fixture["country_slot"])
	_anchor = int(fixture["anchor"])
	_population_cell = int(fixture["population_cell"])
	_population_cohort = int(fixture["population_cohort"])
	_tick = int(fixture["tick"])
	if not await _test_factor_lifecycle():
		_teardown()
		return 1
	_teardown()
	return 0


func _test_factor_lifecycle() -> bool:
	_drive_days(1)
	if not _require("Economy publishes its first committed opinion revision",
			await _wait_opinion_revision(),
			str(_ext.get_country_class_opinion_snapshot())):
		return false
	var initial_opinion: Dictionary = _ext.get_country_class_opinion_snapshot()
	var opinion_publish: Dictionary = _ext.publish_ideology_worker_inputs()
	if not _require("the Economy opinion snapshot publishes to the worker",
			bool(opinion_publish.get("ok", false)), "%s opinion=%s" % [
				str(opinion_publish), str(initial_opinion)]):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	_tick = _drive_days(1)
	# The Ideology POD needs a committed Economy day input, not just a published
	# opinion revision. Keep capturing the main-thread slot copy while waiting;
	# under load the first plan can otherwise stay parked on
	# ideology_opinion_snapshot_missing for the whole hang guard.
	var ready := await WorkerWaitHelper.wait_for(
		func() -> bool:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true)
			var report: Dictionary = _ext.get_runtime_thread_report()
			if int(report.get("economy_input_requested_day", -1)) >= 0:
				_ext.capture_economy_day_inputs(-1)
			if _ext.has_method("publish_ideology_worker_inputs"):
				_ext.publish_ideology_worker_inputs()
			return bool(report.get("ideology_pod_ready", false)),
		16, 120000,
		func() -> void: _tick = _drive_days(1))
	if not _require("the worker Ideology POD becomes ready", ready,
			str(_ext.get_runtime_thread_report().get(
				"ideology_pod_fallback_reason", ""))):
		return false
	if not await _wait_point_baseline():
		return false
	if not await _capture_controlled_opinion():
		return false
	var baseline_one := _settle_positive_population("baseline period 1")
	if baseline_one.is_empty():
		return false
	var baseline_two := _settle_positive_population("baseline period 2")
	if baseline_two.is_empty():
		return false
	if not _require("the baseline population term is positive",
			int(baseline_one.get("point_ledger_population_q16", 0)) > 0,
			str(baseline_one)):
		return false

	if not _apply_population_factor(2.0):
		return false
	_drive_days(2)
	if not _require("factor 2.0 is frozen into the worker epoch",
			not _factor_entry(2.0).is_empty(), str(_factor_entry())):
		return false
	var factor_two := _settle_positive_population("factor 2 period 1")
	if factor_two.is_empty():
		return false
	_expect("factor 2.0 doubles the population term",
		int(factor_two.get("point_ledger_population_q16", 0))
			== 2 * int(baseline_one.get("point_ledger_population_q16", 0)),
		"%s vs 2 * %s" % [
			str(factor_two.get("point_ledger_population_q16", -1)),
			str(baseline_one.get("point_ledger_population_q16", -1))])
	_expect("factor 2.0 leaves building term unchanged",
		int(factor_two.get("point_ledger_building_q16", -1))
			== int(baseline_one.get("point_ledger_building_q16", -2)))
	_expect("factor 2.0 leaves trade term unchanged",
		int(factor_two.get("point_ledger_trade_q16", -1))
			== int(baseline_one.get("point_ledger_trade_q16", -2)))

	if not _remove_population_factor():
		return false
	_drive_days(2)
	if not _require("the worker commits factor removal",
			_factor_entry().is_empty(), str(_factor_entry())):
		return false
	var factor_removed := _settle_positive_population(
		"factor 2 then removed")
	if factor_removed.is_empty():
		return false
	_expect("removing the factor restores the population term to 1.0",
		int(factor_removed.get("point_ledger_population_q16", 0))
			== int(baseline_two.get("point_ledger_population_q16", 0)),
		"%s vs %s" % [
			str(factor_removed.get("point_ledger_population_q16", -1)),
			str(baseline_two.get("point_ledger_population_q16", -1))])
	_expect("removal leaves building term unchanged",
		int(factor_removed.get("point_ledger_building_q16", -1))
			== int(baseline_two.get("point_ledger_building_q16", -2)))
	_expect("removal leaves trade term unchanged",
		int(factor_removed.get("point_ledger_trade_q16", -1))
			== int(baseline_two.get("point_ledger_trade_q16", -2)))

	if not _apply_population_factor(5.0):
		return false
	_drive_days(2)
	if not _require("raw factor 5.0 reaches the frozen worker epoch",
			not _factor_entry(5.0).is_empty(), str(_factor_entry())):
		return false
	var factor_five := _settle_positive_population("factor 5 period 1")
	if factor_five.is_empty():
		return false
	_expect("raw factor 5.0 clamps to 3.0 in the worker ledger",
		int(factor_five.get("point_ledger_population_q16", 0))
			== 3 * int(baseline_one.get("point_ledger_population_q16", 0)),
		"%s vs 3 * %s" % [
			str(factor_five.get("point_ledger_population_q16", -1)),
			str(baseline_one.get("point_ledger_population_q16", -1))])
	_expect("clamped factor leaves building term unchanged",
		int(factor_five.get("point_ledger_building_q16", -1))
			== int(baseline_one.get("point_ledger_building_q16", -2)))
	_expect("clamped factor leaves trade term unchanged",
		int(factor_five.get("point_ledger_trade_q16", -1))
			== int(baseline_one.get("point_ledger_trade_q16", -2)))
	return true


func _restore_saved_bundle(saved: Dictionary, label: String) -> bool:
	_ext.request_runtime_stop()
	if not _require("%s: worker stops before restore" % label,
			await _wait_stopped(), str(_ext.get_runtime_thread_report())):
		return false
	var restored: Dictionary = _ext.restore_runtime_bundle(
		saved.get("bytes", PackedByteArray()))
	if not _require("%s: PKSR bundle restores" % label,
			bool(restored.get("restored", false)), str(restored)):
		return false
	var country_restored: Dictionary = _ext.restore_country_runtime_checkpoint(
		saved.get("country_pkcn", PackedByteArray()))
	if not _require("%s: Country checkpoint restores" % label,
			bool(country_restored.get("ok", false)), str(country_restored)):
		return false
	if not _require("%s: Country snapshot republishes" % label,
			bool(_ext.capture_country_runtime_snapshot().get("ok", false)), ""):
		return false
	_ext.capture_country_pod_catalog()
	var restarted: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0xF7D,
		"day": 0,
		"speed_days_per_second": WORKER_SPEED,
		"paused": false,
	})
	if not _require("%s: restored ACTIVE worker starts" % label,
			bool(restarted.get("ok", false)), str(restarted)):
		return false
	if not _require("%s: restored worker reaches a paused boundary" % label,
			await _wait_worker_paused(), str(_ext.get_runtime_thread_report())):
		return false
	_tick = _world_day()
	_current_factor = NAN
	return true


## Publish one fixed controlled population delta and return the first settlement
## that pays a positive 1.0-factor population term. The controlled source keeps
## all other classes/countries fixed so the factor-period term is comparable.
func _settle_positive_population(label: String) -> Dictionary:
	var before_snapshot := _snapshot()
	var before_day := int(before_snapshot.get("point_ledger_day", -1))
	var before_lifetime := int(before_snapshot.get(
		"lifetime_points_q16", 0))
	if _opinion_country_row < 0:
		_require("%s: the controlled country row is known" % label, false,
			str(_opinion_country_row))
		return {}
	var row_begin := _opinion_country_row * _opinion_class_count
	var row_end := mini(row_begin + _opinion_class_count,
		_opinion_population.size())
	for row in range(row_begin, row_end):
		_opinion_population[row] += POPULATION_STEP
	if not _publish_opinion_source(label):
		return {}
	var last := _snapshot()
	for _index in range(12):
		_drive_days(1)
		last = _snapshot()
		# Only a period that actually accrued points is comparable. A committed
		# day may repeat the prior ledger row before the published opinion reaches
		# the point kernel; accepting it would count the same points twice.
		if int(last.get("point_ledger_day", -1)) > before_day \
				and int(last.get("lifetime_points_q16", 0)) > before_lifetime \
				and int(last.get("point_ledger_population_q16", 0)) > 0:
			return last
	_require("%s produces a positive population term" % label, false, str(last))
	return {}


func _capture_controlled_opinion() -> bool:
	var source: Dictionary = await _wait_committed_opinion("the controlled source")
	if source.is_empty():
		return false
	var population: PackedInt64Array = source.get(
		"population", PackedInt64Array())
	var satisfaction: PackedInt32Array = source.get(
		"satisfaction_q16", PackedInt32Array())
	var weighted: PackedInt64Array = source.get(
		"satisfaction_weighted", PackedInt64Array())
	var handles: PackedInt64Array = source.get(
		"country_handles", PackedInt64Array())
	var class_count := int(source.get("class_count", 0))
	var country := handles.find(_handle)
	if not _require("the committed opinion source contains the player country",
			country >= 0 and class_count > 0
				and population.size() == satisfaction.size()
				and population.size() == weighted.size(),
			str(source)):
		return false
	_opinion_country_row = country
	_opinion_class_count = class_count
	_opinion_population = population.duplicate()
	_opinion_satisfaction_q16 = satisfaction.duplicate()
	_opinion_weighted = weighted.duplicate()
	return _publish_opinion_source("controlled source initialization")


func _wait_point_baseline() -> bool:
	var snapshot := {}
	var ready := await WorkerWaitHelper.wait_for(
		func() -> bool:
			snapshot = _snapshot()
			return bool(snapshot.get("point_baseline_ready", false)),
		16, 120000,
		func() -> void: _tick = _drive_days(1))
	return _require("the worker establishes the point baseline", ready,
		str(snapshot))


func _wait_committed_opinion(label: String) -> Dictionary:
	var source := {}
	var ready := await WorkerWaitHelper.wait_for(
		func() -> bool:
			source = _ext.get_country_class_opinion_snapshot()
			return bool(source.get("ok", false)),
		16, 120000,
		func() -> void: _tick = _drive_days(1))
	if ready:
		return source
	_require("%s reads a committed opinion view" % label, false,
		str(source))
	return {}


func _publish_opinion_source(label: String) -> bool:
	var override: Dictionary = _ext.set_class_opinion_source_override_for_test(
		_opinion_population, _opinion_satisfaction_q16, _opinion_weighted)
	if not _require("%s: controlled opinion source applies" % label,
			bool(override.get("ok", false)), str(override)):
		return false
	var published: Dictionary = _ext.publish_ideology_worker_inputs()
	return _require("%s: worker publication accepts the controlled source"
			% label, bool(published.get("ok", false)), str(published))


func _snapshot() -> Dictionary:
	return _ext.get_ideology_snapshot(_handle)


func _apply_population_factor(final_factor: float) -> bool:
	if not _require("the production Modifier worker ingress is available",
			_ext.has_method("submit_modifier_commands"), ""):
		return false
	# The generated definition owns a MULTIPLY term of 2.0. Modifier applies a
	# magnitude to the term's delta, so final 2.0 is magnitude 1.0 and final 5.0
	# is magnitude 4.0: 1 + (2 - 1) * 4 = 5.
	var magnitude := int(round((final_factor - 1.0) * Q16_ONE))
	_modifier_sequence += 1
	var submitted := _submit_modifier(1, _modifier_sequence, 0, magnitude)
	if bool(submitted.get("ok", false)):
		_current_factor = final_factor
	return _require("the worker accepts the population factor",
		bool(submitted.get("ok", false))
			and not (submitted.get("request_ids", PackedInt64Array()) as
				PackedInt64Array).is_empty(), str(submitted))


func _remove_population_factor() -> bool:
	var entry := _factor_entry()
	if not _require("the population factor can be removed",
			not entry.is_empty(), str(entry)):
		return false
	_modifier_sequence += 1
	var submitted := _submit_modifier(
		2, _modifier_sequence, int(entry.get("handle", 0)), Q16_ONE)
	if bool(submitted.get("ok", false)):
		_current_factor = 1.0
	return _require("the worker accepts population factor removal",
		bool(submitted.get("ok", false))
			and not (submitted.get("request_ids", PackedInt64Array()) as
				PackedInt64Array).is_empty(), str(submitted))


## Queue directly on the worker authority with no input-generation binding. The
## facade's production request binds to the environment generation observed at
## submit time, while this fixture schedules the command for the next boundary;
## the factor is day-independent, and the explicit unbound flag is the supported
## worker test hook for exactly that case.
func _submit_modifier(opcode: int, sequence: int, modifier_handle: int,
		magnitude_q16: int) -> Dictionary:
	return _ext.submit_modifier_commands({
		"protocol_version": 2,
		"opcodes": PackedInt32Array([opcode]),
		"producer_ids": PackedInt32Array([TEST_PRODUCER_ID]),
		"sequences": PackedInt64Array([sequence]),
		"effective_days": PackedInt64Array([_tick]),
		"definition_keys": PackedStringArray([
			String(MODIFIER_DEFINITION) if opcode == 1 else ""]),
		"domains": PackedInt32Array([MODIFIER_DOMAIN_COUNTRY]),
		"scopes": PackedInt32Array([MODIFIER_SCOPE_ENTITY]),
		"entity_handles": PackedInt64Array([_handle if opcode == 1 else 0]),
		"group_handles": PackedInt64Array([0]),
		"source_types": PackedInt64Array([TEST_SOURCE_TYPE]),
		"source_ids": PackedInt64Array([2]),
		"duration_days": PackedInt32Array([-1]),
		"stacks": PackedInt32Array([1]),
		"magnitude_q16": PackedInt32Array([magnitude_q16]),
		"modifier_handles": PackedInt64Array([modifier_handle]),
		"unbound_input_generation": true,
	})


func _factor_entry(expected_final_factor: float = NAN) -> Dictionary:
	var snapshot: Dictionary = _ext.get_runtime_modifier_snapshot(-1)
	if not bool(snapshot.get("available", false)):
		return {}
	var domains: PackedInt32Array = snapshot.get(
		"entry_domains", PackedInt32Array())
	var scopes: PackedInt32Array = snapshot.get(
		"entry_scopes", PackedInt32Array())
	var entities: PackedInt64Array = snapshot.get(
		"entry_entity_handles", PackedInt64Array())
	var source_types: PackedInt64Array = snapshot.get(
		"entry_source_types", PackedInt64Array())
	var source_ids: PackedInt64Array = snapshot.get(
		"entry_source_ids", PackedInt64Array())
	var handles: PackedInt64Array = snapshot.get(
		"entry_handles", PackedInt64Array())
	var magnitudes: PackedInt32Array = snapshot.get(
		"entry_magnitude_q16", PackedInt32Array())
	for index in range(handles.size()):
		if domains[index] != MODIFIER_DOMAIN_COUNTRY or \
				scopes[index] != MODIFIER_SCOPE_ENTITY or \
				entities[index] != _handle or \
				source_types[index] != TEST_SOURCE_TYPE or \
				source_ids[index] != 2:
			continue
		var magnitude := int(magnitudes[index])
		if not is_nan(expected_final_factor):
			var actual_final := 1.0 + float(magnitude) / float(Q16_ONE)
			if not is_equal_approx(actual_final, expected_final_factor):
				continue
		return {
			"handle": int(handles[index]),
			"magnitude_q16": magnitude,
			"final_factor": 1.0 + float(magnitude) / float(Q16_ONE),
		}
	return {}


func _cell_population() -> int:
	return int(_ext.get_population_cell_snapshot(
		_population_cell, false).get("population", 0))


func _class_opinion_revision() -> int:
	return int(_ext.get_country_class_opinion_snapshot().get("revision", -1))


func _country_class_population() -> int:
	return _opinion_country_population(
		_ext.get_country_class_opinion_snapshot())


func _opinion_country_population(snapshot: Dictionary) -> int:
	var class_count := int(snapshot.get("class_count", 0))
	var handles: PackedInt64Array = snapshot.get(
		"country_handles", PackedInt64Array())
	var population: PackedInt64Array = snapshot.get(
		"population", PackedInt64Array())
	for country in range(handles.size()):
		if int(handles[country]) != _handle:
			continue
		var total := 0
		var begin := country * class_count
		var end := mini(begin + class_count, population.size())
		for row in range(begin, end):
			total += maxi(0, int(population[row]))
		return total
	return 0


func _wait_country_class_population_above(previous: int,
		previous_revision: int) -> bool:
	for _index in range(16):
		if _class_opinion_revision() > previous_revision and \
				_country_class_population() > previous:
			return true
		_drive_days(1)
	return _class_opinion_revision() > previous_revision and \
		_country_class_population() > previous


func _wait_cell_population_above(previous: int) -> bool:
	for _index in range(16):
		if _cell_population() > previous:
			return true
		_drive_days(1)
	return _cell_population() > previous


func _build_world() -> Dictionary:
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
	# Copy the proven scalar/X14 worker world setup. In particular, the Economy
	# test bootstrap and the full ACTIVE domain mask are what produce a valid
	# committed class-opinion snapshot for the Ideology POD.
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = 0xF7F
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X6a"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("the X6a session configures",
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeded", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		return {}
	_host = host
	_clock = clock
	_ext = ext
	_generator = generator
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(true, WORKER_SPEED)
	if not _require("the worker reaches a paused boundary",
			await _wait_worker_paused()):
		return {}
	var handle := 0
	var country_slot := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != 0:
			handle = int(summary.get("country_handle", 0))
			country_slot = int(summary.get("country_slot", 0))
			break
	if not _require("the worker resolves the player country", handle != 0):
		return {}
	_handle = handle
	var anchor := int(ext.query_country_anchor_cell(country_slot))
	if not _require("the worker resolves the country anchor", anchor >= 0,
			str(anchor)):
		return {}
	_tick = _world_day()
	_tick = _drive_days(3)
	var population := _find_population_cohort()
	if population.is_empty():
		return {}
	return {
		"host": host, "clock": clock, "ext": ext, "generator": generator,
		"handle": handle, "country_slot": country_slot, "anchor": anchor,
		"population_cell": int(population.get("cell", -1)),
		"population_cohort": int(population.get("cohort", 0)), "tick": _tick,
	}


func _find_population_cohort() -> Dictionary:
	# The starter settlement is at the country anchor. Scan from there first:
	# the synthetic fixture contains other cohorts whose cells are not settlement
	# evidence cells, and growing one of those never reaches the country opinion.
	var cells: Array[int] = []
	if _anchor >= 0 and _anchor < WIDTH * HEIGHT:
		cells.append(_anchor)
	for cell in range(WIDTH * HEIGHT):
		if cell == _anchor:
			continue
		cells.append(cell)
	for cell in cells:
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) != _handle:
			continue
		var snapshot: Dictionary = _ext.get_population_cell_snapshot(cell, false)
		var handles: PackedInt64Array = snapshot.get(
			"handles", PackedInt64Array())
		if handles.is_empty():
			continue
		return {"cell": cell, "cohort": int(handles[0])}
	_fail("the fixture has no owned population cohort")
	return {}


func _drive_days(days: int) -> int:
	for _day in range(days):
		var fault := _worker_fault()
		if not fault.is_empty():
			_require("the worker stays healthy before day %d" % (_tick + 1),
				false, fault)
			break
		_tick += 1
		_clock.current_day = float(_tick)
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		# Publish AFTER the Economy advance: publishing before it only replays the
		# prior revision and the worker Ideology stage stays parked on
		# ideology_opinion_snapshot_missing.
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		_ext.set_runtime_clock(false, WORKER_SPEED)
		var before := int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		# Match X14: the pod/day wait is a waypoint, not the test's day budget.
		# Wall-clock day budgets here multiplied the fixture warmup under load.
		_wait_pod_day(before, 2000)
		_ext.set_runtime_clock(true, WORKER_SPEED)
	return _tick


func _wait_pod_day(before: int, timeout_msec: int = 120000) -> void:
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = _ext.get_runtime_thread_report()
			return int(report.get("ideology_pod_committed_day", -1)) > before \
				or String(report.get("simulation_host_state", "")) in [
					"STOPPED", "FAULTED"],
		timeout_msec,
		func() -> void:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true))


func _wait_worker_idle(iterations: int = 200) -> void:
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = _ext.get_runtime_thread_report()
			return int(report.get("pending_command_count", 0)) == 0 \
				and int(report.get("pending_save_request_count", 0)) == 0,
		120000,
		func() -> void:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true))


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method(
		"has_hard_barrier") else false


func _worker_fault() -> String:
	if _ext == null:
		return ""
	return String(_ext.get_runtime_thread_report().get("fault_code", ""))


func _wait_worker_paused() -> bool:
	return await WorkerWaitHelper.wait_until(
		func() -> bool:
			return String(_ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "PAUSED",
		120000)


func _wait_stopped() -> bool:
	return await WorkerWaitHelper.wait_until(
		func() -> bool:
			return String(_ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "STOPPED",
		120000)


func _world_day() -> int:
	return int(_ext.get_economy_report().get("current_day", 0))


func _wait_opinion_revision() -> bool:
	var published := await WorkerWaitHelper.wait_until(
		func() -> bool:
			if String(_ext.get_runtime_thread_report().get(
					"fault_code", "")) != "":
				return false
			var opinion: Dictionary = _ext.get_country_class_opinion_snapshot()
			if int(opinion.get("revision", 0)) > 0:
				return true
			var report: Dictionary = _ext.get_runtime_thread_report()
			# Economy's first committed day is gated on the day-1 building context
			# capture. Once the host exposes that request, publish the main-thread
			# slot copy and let the worker consume it.
			if int(report.get("economy_input_requested_day", -1)) >= 0:
				_ext.capture_economy_day_inputs(-1)
			return false,
		120000,
		func() -> void:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true))
	if published:
		return true
	return String(_ext.get_runtime_thread_report().get(
		"fault_code", "")) == ""


func _request_save(request_id: int) -> Dictionary:
	var request: Dictionary = {}
	var last_code := ""
	for _attempt in range(24):
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		request = _ext.request_runtime_save(request_id)
		last_code = String(request.get("code", ""))
		if bool(request.get("pending", false)):
			break
		if last_code != "save_request_busy":
			return request
		_ext.poll_runtime_save(request_id)
		OS.delay_msec(5)
	if bool(request.get("pending", false)):
		var saved := {}
		var ready := WorkerWaitHelper.wait_until(
			func() -> bool:
				saved = _ext.poll_runtime_save(request_id)
				last_code = String(saved.get("code", ""))
				if bool(saved.get("ready", false)):
					return true
				return not bool(saved.get("pending", false)) \
					and last_code != "save_pending",
			120000,
			func() -> void:
				if _ext.has_method("service_country_worker_peer_adapter"):
					_ext.service_country_worker_peer_adapter(64, true))
		if ready:
			return saved
	return {"code": "save_timeout_%s" % last_code,
		"report": _ext.get_runtime_thread_report(),
		"failure": String(_ext.get_runtime_thread_report().get(
			"save_failure_reason", ""))}


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(reason: String) -> void:
	_expect(reason, false)
