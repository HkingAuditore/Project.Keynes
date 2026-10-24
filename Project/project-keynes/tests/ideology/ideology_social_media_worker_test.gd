extends SceneTree

## social_media acceptance on the production ACTIVE worker path.
##
## The fixture forces low class opinion through the existing X14 source
## override for the floor assertions, then uses the live Economy population
## delta path from the X6-a fixture for the x1.4 term. Unequip restores both.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const CARD := "social_media"
const MODIFIER_DOMAIN_COUNTRY := 1
const POPULATION_STEP := 4096
const POINT_POPULATION_STAT := "country.ideology.point_population_factor"
const OPINION_FLOOR_STAT := "country.ideology.opinion_factor_floor"

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _generator: MapGenerator
var _handle := 0
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
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology social_media worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var fixture := await _build_world()
	if fixture.is_empty():
		_teardown()
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_generator = fixture["generator"]
	_handle = int(fixture["handle"])
	_anchor = int(fixture["anchor"])
	_population_cell = int(fixture["population_cell"])
	_population_cohort = int(fixture["population_cohort"])
	_tick = int(fixture["tick"])
	var ok := await _test_social_media()
	_teardown()
	return 0 if ok else 1


func _test_social_media() -> bool:
	if not _require("the fixture has a population cohort",
			_population_cohort != 0, str(_population_cohort)):
		return false
	_drive_days(1)
	if not _require("Economy publishes its first committed opinion revision",
			_wait_opinion_revision(),
			str(_ext.get_country_class_opinion_snapshot())):
		return false
	if not _require("the live opinion source publishes to the worker",
			bool(_ext.publish_ideology_worker_inputs().get("ok", false)),
			str(_ext.get_runtime_thread_report())):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	_tick = _drive_days(1)
	if not _require("the worker Ideology POD becomes ready",
			bool(_ext.get_runtime_thread_report().get(
				"ideology_pod_ready", false)),
			str(_ext.get_runtime_thread_report().get(
				"ideology_pod_fallback_reason", ""))):
		return false
	if not _wait_point_baseline():
		return false
	_tick = _drive_days(1)

	# The controlled source changes class opinion and country population
	# together. The population delta must be in the same snapshot the worker
	# settles, otherwise the point baseline advances without a term.
	if not _force_low_opinion():
		return false
	var baseline := _settle_positive_population("controlled baseline")
	if baseline.is_empty():
		return false
	_expect("without social_media the low-opinion factor floor is 0.5",
		int(baseline.get("point_ledger_opinion_factor_q16", 0))
			== Q16_ONE / 2,
		str(baseline))
	var baseline_population = int(baseline.get(
		"point_ledger_population_q16", 0))

	if not _equip(CARD):
		return false
	var snapshot := _snapshot()
	_expect("social_media occupies a slot",
		int(snapshot.get("ideology_slots_used", 0)) >= 1, str(snapshot))
	var with_card := _settle_positive_population("social_media L1")
	if with_card.is_empty():
		return false
	_expect("social_media applies the 0.4 opinion floor to the worker ledger",
		int(with_card.get("point_ledger_opinion_factor_q16", 0))
			== int(round(0.4 * Q16_ONE)), str(with_card))
	_expect("social_media lowers the frozen opinion floor to 0.4",
		_is_floor(0.4), "factor=%.5f" % _evaluated_floor())

	var expected_population := int(round(1.4 * baseline_population))
	_expect("social_media L1 multiplies the controlled population term by 1.4",
		absi(int(with_card.get("point_ledger_population_q16", 0))
			- expected_population) <= 1024,
		"%s vs 1.4 * %s" % [
			str(with_card.get("point_ledger_population_q16", -1)),
			str(baseline_population)])

	if not _unequip(CARD):
		return false
	_tick = _drive_days(2)
	if not _wait_for_floor(0.5):
		return false
	_expect("unequip restores the population factor to 1.0",
		absf(_evaluated_population_factor() - 1.0) <= 0.0005,
		"factor=%.5f" % _evaluated_population_factor())
	_expect("unequip restores the opinion factor floor to 0.5",
		_is_floor(0.5), "factor=%.5f" % _evaluated_floor())
	return true


func _force_low_opinion() -> bool:
	var source := _wait_committed_opinion("the controlled source")
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
			country >= 0 && class_count > 0
				and population.size() == satisfaction.size()
				and population.size() == weighted.size(),
			str(source)):
		return false
	var frozen_satisfaction := satisfaction.duplicate()
	_opinion_country_row = country
	_opinion_class_count = class_count
	for row in range(satisfaction.size()):
		if int(row / class_count) != country:
			continue
		frozen_satisfaction[row] = 0
		weighted[row] = 0
	_opinion_population = population.duplicate()
	_opinion_satisfaction_q16 = frozen_satisfaction
	_opinion_weighted = weighted.duplicate()
	var override: Dictionary = _ext.set_class_opinion_source_override_for_test(
		_opinion_population, _opinion_satisfaction_q16, _opinion_weighted)
	return _require("the X14 low-opinion source override applies",
		bool(override.get("ok", false)), str(override))


func _wait_committed_opinion(label: String) -> Dictionary:
	for _index in range(16):
		var source: Dictionary = _ext.get_country_class_opinion_snapshot()
		if bool(source.get("ok", false)):
			return source
		if String(source.get("reason", "")) != "economy_read_view_pending" \
				and String(source.get("code", "")) != "economy_busy_retry":
			break
		_tick = _drive_days(1)
	_require("%s reads a committed opinion view" % label, false,
		str(_ext.get_country_class_opinion_snapshot()))
	return {}


func _settle_positive_population(label: String) -> Dictionary:
	if not _require("%s: the controlled country row is known" % label,
			_opinion_country_row >= 0, str(_opinion_country_row)):
		return {}
	var row_begin := _opinion_country_row * _opinion_class_count
	var row_end := mini(row_begin + _opinion_class_count,
		_opinion_population.size())
	for row in range(row_begin, row_end):
		_opinion_population[row] += POPULATION_STEP
	var before_day := int(_snapshot().get("point_ledger_day", -1))
	if not _publish_opinion_source(label):
		return {}
	var last := _snapshot()
	for _index in range(16):
		_tick = _drive_days(1)
		last = _snapshot()
		if int(last.get("point_ledger_day", -1)) > before_day \
				and int(last.get("point_ledger_population_q16", 0)) > 0:
			return last
	_require("%s produces a positive population term" % label, false, str(last))
	return {}


func _wait_point_baseline() -> bool:
	for _index in range(16):
		if bool(_snapshot().get("point_baseline_ready", false)):
			return true
		_tick = _drive_days(1)
	return _require("the worker establishes the point baseline", false,
		str(_snapshot()))


func _publish_opinion_source(label: String) -> bool:
	var override: Dictionary = _ext.set_class_opinion_source_override_for_test(
		_opinion_population, _opinion_satisfaction_q16, _opinion_weighted)
	if not _require("%s: controlled opinion source applies" % label,
			bool(override.get("ok", false)), str(override)):
		return false
	var published: Dictionary = _ext.publish_ideology_worker_inputs()
	return _require("%s: worker publication accepts the controlled source"
			% label,
		bool(published.get("ok", false)), str(published))


func _snapshot() -> Dictionary:
	return _ext.get_ideology_snapshot(_handle)


func _evaluated_floor() -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_COUNTRY, _handle, 0, OPINION_FLOOR_STAT, 0.5))


func _evaluated_population_factor() -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_COUNTRY, _handle, 0, POINT_POPULATION_STAT, 1.0))


func _is_floor(expected: float) -> bool:
	var value := _evaluated_floor()
	return is_finite(value) and absf(value - expected) <= 0.0005


func _wait_for_floor(expected: float) -> bool:
	for _index in range(12):
		if _is_floor(expected):
			_expect("frozen worker opinion floor is %.2f" % expected, true)
			return true
		_tick = _drive_days(1)
	return _require("frozen worker opinion floor is %.2f" % expected,
		false, "factor=%.5f snapshot=%s" % [_evaluated_floor(),
			str(_snapshot())])


func _equip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s absent from the compiled catalog" % card)
		return false
	var gates: Dictionary = DrawGateHelper.grant_draw_gates(
		_host, card, _handle, _tick, _next_sequence)
	if not _require("%s: draw gates clear" % card,
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	_tick = _drive_days(2)
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts discover" % card,
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_tick = _drive_days(3)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts equip" % card,
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	for _index in range(12):
		var snapshot := _snapshot()
		var row := PackedInt32Array(snapshot.get(
			"idea_ids", PackedInt32Array())).find(dense)
		var locations := PackedInt32Array(snapshot.get(
			"locations", PackedInt32Array()))
		var rows := PackedStringArray(_ext.list_modifiers(
			1, _handle, "").get("definition_keys", PackedStringArray()))
		if row >= 0 and row < locations.size() \
				and int(locations[row]) == 1 \
				and rows.has("ideology.%s.l1" % card):
			_expect("%s: modifier row appears after equip" % card, true)
			return true
		_tick = _drive_days(1)
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[social-media-equip] opcodes=%s reasons=%s snapshot=%s rows=%s" % [
			str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_snapshot()),
			str(_ext.list_modifiers(1, _handle, ""))])
	return _require("%s: card is equipped with its L1 modifier row" % card,
		false, str(_snapshot()))


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var before := int(_snapshot().get("ideology_slots_used", -1))
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	var slots := before
	for _index in range(12):
		_tick = _drive_days(1)
		var snapshot := _snapshot()
		slots = int(snapshot.get("ideology_slots_used", -1))
		var row := PackedInt32Array(snapshot.get(
			"idea_ids", PackedInt32Array())).find(dense)
		if slots < before and row >= 0 \
				and int(PackedInt32Array(snapshot.get(
					"locations", PackedInt32Array()))[row]) == 0:
			return true
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[social-media-unequip] opcodes=%s statuses=%s reasons=%s snapshot=%s" % [
			str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("statuses", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_snapshot())])
	return _require("%s: unequip releases the slot (slots=%d before=%d)" % [
		card, slots, before], false, str(_snapshot()))


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
	host.generate_test_economy_data = true
	host.test_economy_population_scale = 100
	host.runtime_climate_authority_enabled = true
	host.runtime_economy_auto_pod_active = true
	host.runtime_authority_domain_mask = 0xFFF
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 SocialMedia"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("the social_media session configures",
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
			_wait_worker_paused()):
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
	if not _require("Effect input digest refreshes",
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return {}
	var population := _find_population_cohort()
	if population.is_empty():
		return {}
	return {
		"host": host, "clock": clock, "ext": ext, "generator": generator,
		"handle": handle, "anchor": anchor,
		"population_cell": int(population.get("cell", -1)),
		"population_cohort": int(population.get("cohort", 0)), "tick": _tick,
	}


func _find_population_cohort() -> Dictionary:
	var cells: Array[int] = []
	if _anchor >= 0 and _anchor < WIDTH * HEIGHT:
		cells.append(_anchor)
	for cell in range(WIDTH * HEIGHT):
		if cell != _anchor:
			cells.append(cell)
	for cell in cells:
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) != _handle:
			continue
		var snapshot: Dictionary = _ext.get_population_cell_snapshot(cell, false)
		var handles: PackedInt64Array = snapshot.get(
			"handles", PackedInt64Array())
		if not handles.is_empty():
			return {"cell": cell, "cohort": int(handles[0])}
	_fail("the fixture has no owned population cohort")
	return {}


func _dense_id(card: String) -> int:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(
		economy_catalog, economy_catalog)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get(
		"ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _submit(rows: Array) -> Dictionary:
	return _ext.submit_ideology_commands(_commands(rows))


func _commands(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producer := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row in rows:
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", 0)))
		producer.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", 0)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return {
		"opcodes": opcodes, "effective_days": days, "producer_ids": producer,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	}


func _drive_days(days: int) -> int:
	for _day in range(days):
		var fault := _worker_fault()
		if not fault.is_empty():
			_require("the worker stays healthy before day %d" % (_tick + 1),
				false, fault)
			break
		_tick += 1
		_clock.current_day = float(_tick)
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		_ext.set_runtime_clock(false, WORKER_SPEED)
		var before := int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(before)
		_wait_simulation_day(_tick)
		_ext.set_runtime_clock(true, WORKER_SPEED)
	return _tick


func _wait_pod_day(before: int) -> void:
	for _iteration in range(2000):
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		var report: Dictionary = _ext.get_runtime_thread_report()
		if int(report.get("ideology_pod_committed_day", -1)) > before:
			return
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return


func _wait_simulation_day(target: int) -> void:
	for _iteration in range(2000):
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		var report: Dictionary = _ext.get_runtime_thread_report()
		if int(report.get("simulation_committed_day", -1)) >= target:
			return
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return


func _wait_worker_paused() -> bool:
	for _iteration in range(5000):
		var state := String(_ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED":
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _wait_opinion_revision() -> bool:
	var deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if int(_ext.get_country_class_opinion_snapshot().get(
				"revision", 0)) > 0:
			return true
		var report: Dictionary = _ext.get_runtime_thread_report()
		if String(report.get("fault_code", "")) != "":
			return false
		if int(report.get("economy_input_requested_day", -1)) >= 0:
			_ext.capture_economy_day_inputs(-1)
		OS.delay_msec(5)
	return false


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method(
		"has_hard_barrier") else false


func _worker_fault() -> String:
	if _ext == null:
		return ""
	return String(_ext.get_runtime_thread_report().get("fault_code", ""))


func _world_day() -> int:
	return int(_ext.get_economy_report().get("current_day", 0))


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("[PASS] " + label)
		return
	_failures += 1
	printerr("[FAIL] " + label +
		(" " + detail if not detail.is_empty() else ""))


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition


func _fail(reason: String) -> void:
	_expect(reason, false)
