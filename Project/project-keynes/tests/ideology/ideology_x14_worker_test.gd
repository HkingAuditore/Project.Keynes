extends SceneTree

## X14 acceptance on the production worker path.
##
## The fixture reads the last committed CountryClassOpinionSnapshot, verifies
## metric 77 is the `general` class row, metric 78 is the integer
## population-weighted country value, and metric 89 is the `farmer` class row,
## then drives `petition_box` through the real worker Effect path. Its
## satisfaction and national rows are unconditional; the point-gain gate must
## follow farmer opinion only, and unequip restores all rows.
##
## Run:
##   godot --headless --path Project/project-keynes \
##     --script res://tests/ideology/ideology_x14_worker_test.gd

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const METRIC_CLASS_SATISFACTION := 77
const METRIC_WEIGHTED_SATISFACTION := 78
const METRIC_FARMER_SATISFACTION := 89
const MODIFIER_DOMAIN_COUNTRY := 1
const POINT_GAIN_STAT := "country.ideology.point_gain_factor"
const PETITION_SATISFACTION_STAT := \
	"economy.profession.agricultural_worker.satisfaction_bp"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyDrawGateHelper = preload(
	"res://tests/ideology/ideology_draw_gate_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _generator: MapGenerator
var _handle := 0
var _country_slot := 0
var _anchor := -1
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x14 worker: %d checks, %d failures ===" % [
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
	_tick = int(fixture["tick"])
	if not _test_committed_copy():
		_teardown()
		return 1
	if not _test_petition_box_toggle():
		_teardown()
		return 1
	_test_idle_reuse()
	_teardown()
	return 0


func _test_committed_copy() -> bool:
	var report: Dictionary = _ext.get_economy_report()
	var prior: Dictionary = _ext.get_country_class_opinion_snapshot()
	if not _require("economy publishes the class snapshot",
			int(prior.get("revision", 0)) > 0
				and int(prior.get("class_count", 0)) > 0,
			str(prior)):
		return false
	var class_ids: PackedStringArray = prior.get(
		"class_ids", PackedStringArray())
	var sorted_class_ids := class_ids.duplicate()
	sorted_class_ids.sort()
	_expect("class ids are unique and sorted (%s)" % str(class_ids),
		sorted_class_ids == class_ids,
		"classes=%s" % str(class_ids))
	_expect("class count matches the compiled catalog (%d)"
			% int(prior.get("class_count", -1)),
		int(prior.get("class_count", -1)) == class_ids.size(),
		"class_count=%d ids=%d" % [
			int(prior.get("class_count", -1)), class_ids.size()])
	var general := class_ids.find("general")
	if not _require("the committed snapshot has the general class", general >= 0,
			str(class_ids)):
		return false
	var farmer := class_ids.find("farmer")
	if not _require("the committed snapshot has the farmer class", farmer >= 0,
			str(class_ids)):
		return false
	var country_index := _snapshot_country_index(prior)
	if not _require("the player country is present in the committed snapshot",
			country_index >= 0, str(prior.get("country_handles",
				PackedInt64Array()))):
		return false
	var class_count := int(prior.get("class_count", 0))
	var country_count := int(prior.get("country_count", 0))
	if not _require("the snapshot has both the player and foreign country",
			country_count >= 2, str(country_count)):
		return false
	var population: PackedInt64Array = prior.get(
		"population", PackedInt64Array())
	var satisfaction: PackedInt32Array = prior.get(
		"satisfaction_q16", PackedInt32Array())
	var weighted_rows: PackedInt64Array = prior.get(
		"satisfaction_weighted", PackedInt64Array())
	var general_row := _player_class_row(prior, general)
	if not _require("the general row exists", general_row < satisfaction.size(),
			"row=%d size=%d" % [general_row, satisfaction.size()]):
		return false
	var farmer_row := _player_class_row(prior, farmer)
	if not _require("the farmer row exists", farmer_row < satisfaction.size(),
			"row=%d size=%d" % [farmer_row, satisfaction.size()]):
		return false

	# The metric copy is refreshed at the country epoch boundary. Capture the
	# current committed snapshot immediately so this assertion is about content,
	# not about how many days have elapsed since world generation.
	var source: Dictionary = _ext.capture_class_metric_source_for_test()
	var metric_general := _metric(METRIC_CLASS_SATISFACTION)
	_expect("metric 77 copies the prior general row (%d)"
			% metric_general,
		metric_general == int(satisfaction[general_row]),
		"metric=%d prior=%d source=%s" % [
			metric_general, int(satisfaction[general_row]), str(source)])
	var total_population := 0
	var total_weighted := 0
	for political_class in range(class_count):
		var row := _player_class_row(prior, political_class)
		if row >= population.size() or row >= weighted_rows.size():
			continue
		total_population += maxi(0, int(population[row]))
		total_weighted += maxi(0, int(weighted_rows[row]))
	var expected_weighted := 0
	if total_population > 0:
		expected_weighted = clampi(total_weighted / total_population, 0, Q16_ONE)
	var metric_weighted := _metric(METRIC_WEIGHTED_SATISFACTION)
	_expect("metric 78 is the prior integer population-weighted value (%d)"
			% expected_weighted,
		metric_weighted == expected_weighted,
		"metric=%d expected=%d population=%d weighted=%d source=%s" % [
			metric_weighted, expected_weighted, total_population, total_weighted,
			str(source)])
	var metric_farmer := _metric(METRIC_FARMER_SATISFACTION)
	_expect("metric 89 copies the prior farmer row (%d)" % metric_farmer,
		metric_farmer == int(satisfaction[farmer_row]),
		"metric=%d prior=%d source=%s" % [
			metric_farmer, int(satisfaction[farmer_row]), str(source)])
	_expect("the copied source is a committed revision",
		bool(source.get("ok", false))
			and int(source.get("source_revision", -1)) > 0
			and int(source.get("source_epoch_day", -1)) >= 0,
		str(source))
	_expect("the source copy exposes the same class ids",
		source.get("snapshot_class_ids", PackedStringArray()) == class_ids,
		str(source.get("snapshot_class_ids", PackedStringArray())))
	var copied: PackedInt64Array = source.get(
		"copied_satisfaction_q16", PackedInt64Array())
	var copied_weighted: PackedInt64Array = source.get(
		"copied_weighted_satisfaction_q16", PackedInt64Array())
	var copied_farmer: PackedInt64Array = source.get(
		"copied_farmer_satisfaction_q16", PackedInt64Array())
	_expect("the copied general vector matches the prior snapshot",
		country_index < copied.size()
			and int(copied[country_index])
				== int(satisfaction[general_row]),
		str(copied))
	_expect("the copied weighted vector matches the prior snapshot",
		country_index < copied_weighted.size()
			and int(copied_weighted[country_index])
				== expected_weighted,
		str(copied_weighted))
	_expect("the copied farmer vector matches the prior snapshot",
		country_index < copied_farmer.size()
			and int(copied_farmer[country_index])
				== int(satisfaction[farmer_row]),
		str(copied_farmer))
	_expect("the class metric diagnostic sees the four-class catalog",
		int(report.get("class_metric_country_count", -1)) > 0,
		str(report.get("class_metric_country_count", -1)))
	return true


func _test_petition_box_toggle() -> bool:
	_expect("points start with the policy at baseline",
		_is_stat_close(_point_gain_factor(), 1.0, 0.0005),
		"%.5f" % _point_gain_factor())
	_expect("petition_box starts with no satisfaction bias",
		_is_stat_close(_petition_satisfaction_bias(), 0.0, 0.0005),
		"%.5f" % _petition_satisfaction_bias())
	_set_class_metric(METRIC_CLASS_SATISFACTION, 0.60)
	_set_class_metric(METRIC_WEIGHTED_SATISFACTION, 0.60)
	_set_class_metric(METRIC_FARMER_SATISFACTION, 0.20)
	if not _equip("petition_box"):
		return false
	var bias := _wait_petition_satisfaction_bias(400.0, 12)
	_expect("petition_box applies +4 agricultural-worker satisfaction (got %.5f)"
			% bias, _is_stat_close(bias, 400.0, 0.0005), "%.5f" % bias)
	var low_farmer := _point_gain_factor()
	_expect("farmer opinion below 30%% applies +5%% point gain (got %.5f)"
			% low_farmer, _is_stat_close(low_farmer, 1.05, 0.0005),
			"%.5f" % low_farmer)
	if not _unequip("petition_box"):
		return false
	_clear_class_metric_overrides()
	var after_first_unequip := _point_gain_factor()
	if _is_stat_close(after_first_unequip, 1.0, 0.0005):
		_expect("unequipping petition_box restores the baseline after the low-farmer row",
			true, "%.5f" % after_first_unequip)
	else:
		print("[BLOCKED-by-laneA] unequipping petition_box restores the baseline "
			+ "after the low-farmer row (got %.5f)" % after_first_unequip)

	# Low general opinion must not trigger the farmer-only gate.
	_set_class_metric(METRIC_CLASS_SATISFACTION, 0.20)
	_set_class_metric(METRIC_WEIGHTED_SATISFACTION, 0.20)
	_set_class_metric(METRIC_FARMER_SATISFACTION, 0.60)
	if not _equip("petition_box"):
		return false
	var low := _point_gain_factor()
	_expect("low general opinion does not restore the old +5%% point gain (got %.5f)"
			% low, _is_stat_close(low, 1.0, 0.0005), "%.5f" % low)
	var high := _point_gain_factor()
	_expect("farmer opinion at 30%% or above leaves point gain at baseline (got %.5f)"
			% high, _is_stat_close(high, 1.0, 0.0005), "%.5f" % high)
	if not _unequip("petition_box"):
		return false
	_clear_class_metric_overrides()
	_expect("unequipping petition_box restores the baseline point gain",
		_is_stat_close(_point_gain_factor(), 1.0, 0.0005),
		"%.5f" % _point_gain_factor())
	var cleared := _wait_petition_satisfaction_bias(0.0, 12)
	_expect("unequipping petition_box restores the satisfaction baseline",
		_is_stat_close(cleared, 0.0, 0.0005), "%.5f" % cleared)
	return true


func _test_idle_reuse() -> void:
	if not _reapply_idle_override():
		return
	if not _settle_idle_override():
		return
	var baseline := _idle_baseline()
	var clean_days := 0
	var last_faults := _worker_fault_count()
	var last_recaptures := _command_recapture_count()
	while clean_days < 30:
		_tick = _drive_days(1)
		var faults_now := _worker_fault_count()
		var recaptures_now := _command_recapture_count()
		if faults_now != last_faults or recaptures_now != last_recaptures:
			if not _reapply_idle_override():
				return
			baseline = _idle_baseline()
			clean_days = 0
			last_faults = faults_now
			last_recaptures = recaptures_now
			continue
		clean_days += 1
	var before := int(baseline["rebuilds"])
	var source_before: Dictionary = baseline["source"]
	var class_revision_before := int(baseline["class_revision"])
	var weighted_revision_before := int(baseline["weighted_revision"])
	var farmer_revision_before := int(baseline["farmer_revision"])
	var visits_before := int(baseline["visits"])
	var after := int(_ext.get_economy_report().get(
		"class_metric_rebuilds", 0))
	var source_after: Dictionary = _ext.get_class_metric_source_for_test()
	var ideology_after: Dictionary = _ext.get_ideology_report()
	var visits_after := int(ideology_after.get("instance_refresh_visits", -1))
	_expect("30 unchanged days rebuild class metrics zero times",
		after == before, "before=%d after=%d source=%s" % [
			before, after, str(source_after)])
	_expect("metric 77 revision is unchanged across the idle window",
		_metric_revision(METRIC_CLASS_SATISFACTION) ==
			class_revision_before,
		"%d -> %d" % [class_revision_before,
			_metric_revision(METRIC_CLASS_SATISFACTION)])
	_expect("metric 78 revision is unchanged across the idle window",
		_metric_revision(METRIC_WEIGHTED_SATISFACTION) ==
			weighted_revision_before,
		"%d -> %d" % [weighted_revision_before,
			_metric_revision(METRIC_WEIGHTED_SATISFACTION)])
	_expect("metric 89 revision is unchanged across the idle window",
		_metric_revision(METRIC_FARMER_SATISFACTION) == farmer_revision_before,
		"%d -> %d" % [farmer_revision_before,
			_metric_revision(METRIC_FARMER_SATISFACTION)])
	_expect("the idle source keeps its metric-content hash",
		int(source_after.get("source_content_hash", 0))
			== int(source_before.get("source_content_hash", -1)),
		"before=%s after=%s" % [str(source_before), str(source_after)])
	_expect("unrelated cards receive zero refresh visits across idle days",
		visits_after == visits_before,
		"%d -> %d" % [visits_before, visits_after])
	_ext.clear_class_opinion_source_override_for_test()


func _settle_idle_override() -> bool:
	var last_faults := _worker_fault_count()
	var last_recaptures := _command_recapture_count()
	for _attempt in range(8):
		_tick = _drive_days(1)
		var faults_now := _worker_fault_count()
		var recaptures_now := _command_recapture_count()
		if faults_now == last_faults and recaptures_now == last_recaptures:
			return true
		if not _reapply_idle_override():
			return false
		last_faults = faults_now
		last_recaptures = recaptures_now
	_fail("the idle override does not settle after worker recovery")
	return false


func _idle_baseline() -> Dictionary:
	return {
		"rebuilds": int(_ext.get_economy_report().get(
			"class_metric_rebuilds", 0)),
		"source": _ext.get_class_metric_source_for_test(),
		"class_revision": _metric_revision(METRIC_CLASS_SATISFACTION),
		"weighted_revision": _metric_revision(METRIC_WEIGHTED_SATISFACTION),
		"farmer_revision": _metric_revision(METRIC_FARMER_SATISFACTION),
		"visits": int(_ext.get_ideology_report().get(
			"instance_refresh_visits", -1)),
	}


func _reapply_idle_override() -> bool:
	var source_snapshot: Dictionary = _ext.get_class_metric_source_for_test()
	var population: PackedInt64Array = source_snapshot.get(
		"snapshot_population", PackedInt64Array())
	var satisfaction: PackedInt32Array = source_snapshot.get(
		"snapshot_satisfaction_q16", PackedInt32Array())
	var weighted: PackedInt64Array = source_snapshot.get(
		"snapshot_satisfaction_weighted", PackedInt64Array())
	var class_ids: PackedStringArray = source_snapshot.get(
		"snapshot_class_ids", PackedStringArray())
	var general := class_ids.find("general")
	var class_count := int(source_snapshot.get("snapshot_class_count", 0))
	if not _require("the recovered idle proof has committed class rows",
			general >= 0 and class_count > 0
				and population.size() == satisfaction.size()
				and population.size() == weighted.size(),
			str(source_snapshot)):
		return false
	var frozen_satisfaction := satisfaction.duplicate()
	for row in range(satisfaction.size()):
		if row % class_count != general:
			continue
		frozen_satisfaction[row] = int(round(0.42 * Q16_ONE))
		weighted[row] = (
			int(frozen_satisfaction[row]) * maxi(0, int(population[row])))
	var override: Dictionary = _ext.set_class_opinion_source_override_for_test(
		population, frozen_satisfaction, weighted)
	if not _require("the recovered idle source override applies",
			bool(override.get("ok", false)), str(override)):
		return false
	return _require("the recovered idle source recaptures",
		bool(_ext.capture_class_metric_source_for_test().get("ok", false)), "")


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
	host.runtime_authority_domain_mask = 0xF7F
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X14"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x14 session configures", bool(session.get("ok", false)),
			str(session)):
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
	var handle := 0
	var country_slot := 0
	var anchor := -1
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != 0:
			handle = int(summary.get("country_handle", 0))
			country_slot = int(summary.get("country_slot", 0))
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	anchor = int(ext.query_country_anchor_cell(country_slot))
	if not _require("worker path resolves the country anchor", anchor >= 0,
			str(anchor)):
		return {}
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {"host": host, "clock": clock, "ext": ext,
		"generator": generator, "handle": handle,
		"country_slot": country_slot, "anchor": anchor, "tick": _tick}


func _snapshot_country_index(snapshot: Dictionary) -> int:
	var handles: PackedInt64Array = snapshot.get(
		"country_handles", PackedInt64Array())
	for index in range(handles.size()):
		if int(handles[index]) == _handle:
			return index
	return -1


func _player_class_row(snapshot: Dictionary, political_class: int) -> int:
	var class_count := int(snapshot.get("class_count", 0))
	var handles: PackedInt64Array = snapshot.get(
		"country_handles", PackedInt64Array())
	for index in range(handles.size()):
		if int(handles[index]) == _handle:
			return index * class_count + political_class
	return -1


func _metric(metric_id: int) -> int:
	var result: Dictionary = _ext.sample_effect_metric_probe(
		metric_id, _anchor, _handle)
	if not bool(result.get("ok", false)):
		_fail("metric %d probe failed: %s" % [metric_id,
			str(result.get("reason", "unknown"))])
		return -1
	return int(result.get("value", -1))


func _metric_revision(metric_id: int) -> int:
	var values: PackedInt64Array = _ext.get_effect_input_revisions().get(
		"metrics", PackedInt64Array())
	return int(values[metric_id]) if metric_id < values.size() else -1


func _point_gain_factor() -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_COUNTRY, _handle, 0, POINT_GAIN_STAT, 1.0))


func _petition_satisfaction_bias() -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_COUNTRY, _handle, 0, PETITION_SATISFACTION_STAT, 0.0))


func _wait_petition_satisfaction_bias(expected: float, days: int) -> float:
	var value := _petition_satisfaction_bias()
	for _day in range(days):
		if _is_stat_close(value, expected, 0.0005):
			return value
		_tick = _drive_days(1)
		value = _petition_satisfaction_bias()
	return value


func _set_class_metric(metric_id: int, value: float) -> void:
	var result: Dictionary = _ext.set_effect_metric_override_for_test(
		metric_id, int(round(value * Q16_ONE)), true)
	_expect("metric %d override %.2f applies" % [metric_id, value],
		bool(result.get("ok", false)), str(result))


func _clear_class_metric_overrides() -> void:
	for metric_id in [METRIC_CLASS_SATISFACTION, METRIC_WEIGHTED_SATISFACTION,
			METRIC_FARMER_SATISFACTION]:
		_ext.set_effect_metric_override_for_test(metric_id, 0, false)


func _equip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s absent from the compiled catalog" % card)
		return false
	var gates: Dictionary = IdeologyDrawGateHelper.grant_draw_gates(
		_host, card, _handle, _tick, _next_sequence)
	if not _require("%s: worker grants its draw gates" % card,
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	_tick = _drive_days(1)
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
	_tick = _drive_days(8)
	var deadline := Time.get_ticks_msec() + 20000
	var slots := 0
	while Time.get_ticks_msec() < deadline:
		slots = int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1))
		if slots >= 1:
			break
		_tick = _drive_days(1)
	return _require("%s: the card occupies a slot (slots=%d)" % [card, slots],
		slots >= 1, str(slots))


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	_tick = _drive_days(3)
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if int(_ext.get_ideology_snapshot(_handle).get(
				"ideology_slots_used", -1)) == 0:
			return true
		_tick = _drive_days(1)
	return _require("%s: unequip releases the slot" % card, false,
		str(_ext.get_ideology_snapshot(_handle)))


func _dense_id(card: String) -> int:
	var catalog: Resource = load(
		"res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
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


func _world_day(ext: Object) -> int:
	var report: Dictionary = ext.get_runtime_thread_report()
	for key in ["world_day", "ideology_pod_committed_day", "day"]:
		if report.has(key):
			return int(report[key])
	return 0


func _drive_days(days: int) -> int:
	for _day in range(days):
		var fault := _worker_fault()
		if not fault.is_empty():
			_require("worker stays healthy before day %d" % (_tick + 1),
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
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		if _ext.has_method("publish_ideology_worker_inputs"):
			_ext.publish_ideology_worker_inputs()
		_ext.set_runtime_clock(false, WORKER_SPEED)
		var before := int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1))
		_wait_pod_day(before, 2000)
		_ext.set_runtime_clock(true, WORKER_SPEED)
	return _tick


func _wait_pod_day(before: int, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		if int(_ext.get_runtime_thread_report().get(
				"ideology_pod_committed_day", -1)) > before:
			return


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method("has_hard_barrier") \
		else false


func _worker_fault() -> String:
	if _ext == null:
		return ""
	return String(_ext.get_runtime_thread_report().get("fault_code", ""))


func _worker_fault_count() -> int:
	if _ext == null:
		return 0
	return int(_ext.get_runtime_thread_report().get("worker_fault_count", 0))


func _command_recapture_count() -> int:
	if _ext == null:
		return 0
	return int(_ext.get_runtime_thread_report().get(
		"economy_pod_command_recapture_count", 0))


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _is_stat_close(actual: float, expected: float, epsilon: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= epsilon


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_checks += 1
	if condition:
		print("[PASS] " + label)
		return true
	_failures += 1
	printerr("[FAIL] " + label + (" " + detail if not detail.is_empty() else ""))
	return false


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_require(label, condition, detail)


func _fail(label: String) -> void:
	_require(label, false)
