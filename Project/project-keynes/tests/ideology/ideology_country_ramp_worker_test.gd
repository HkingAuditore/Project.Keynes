extends SceneTree

## R-7 item G: a country-domain RampTerm carrier on the WORKER path.
##
## Country-metric cards (treasury_reserve, silver_standard, subsidy_state) on the
## production worker refresh: the fixture overrides metrics 68/69 and reads the
## resulting ideology Modifier rows.
##
## Run from the lane root:
##   godot --headless --path Project/project-keynes \
##     --script res://tests/ideology/ideology_country_ramp_worker_test.gd

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
## Metric 69 is `count_q16(percentage_points)`. The test override replaces the
## sampled value verbatim, so the fixture must pass the Q16-encoded point count.
const METRIC_NET_TAX_BURDEN := 68
const METRIC_TREASURY_RESERVE := 69
const DEATH_FACTOR_STAT := "country.population.death_factor"
const BUILD_COST_STAT := "country.construction.cost_factor"
const TRADE_CAPACITY_STAT := "country.trade.capacity_factor"
const CONSUMPTION_STAT := "country.household.consumption_factor"
const POINT_GAIN_STAT := "country.ideology.point_gain_factor"
const CELL_OUTPUT_STATS := [
	"economy.city.building.agriculture_output_factor",
	"economy.city.building.extractive_output_factor",
	"economy.city.building.manufacturing_output_factor",
	"economy.city.building.energy_output_factor",
	"economy.city.building.knowledge_output_factor",
]
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const WorkerWaitHelper = preload(
	"res://tests/ideology/ideology_worker_wait_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology country ramp worker: %d checks, %d failures ==="
		% [_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	OS.set_environment("PK_DISABLE_SUPPORT_GATE", "1")
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var fixture := await _build_world()
	if fixture.is_empty():
		printerr("ERROR: [FAIL] country-ramp fixture unavailable; "
			+ "checks=%d failures=%d" % [_checks, _failures])
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_ext = fixture["ext"]
	_handle = int(fixture["handle"])
	if not await _test_country_ramp():
		_teardown()
		return 1
	_teardown()
	return 0


func _test_country_ramp() -> bool:
	var baseline := _read_death_factor()
	if not _expect_close("baseline death factor is 1.00", baseline, 1.0):
		return false
	# progressive_tax and sovereign_fund are holdouts (09-content-status) and are
	# absent from the shipped catalog.
	if not await _exercise_treasury_reserve():
		return false
	if not await _exercise_silver_standard():
		return false
	if not await _exercise_subsidy_state():
		return false
	return true


func _exercise_treasury_reserve() -> bool:
	_ext.set_effect_metric_override_for_test(
		METRIC_TREASURY_RESERVE, 3 * Q16_ONE, true)
	_ext.refresh_effect_input_digest_for_test()
	var trade_capacity_before := _read_country_stat(TRADE_CAPACITY_STAT)
	if not _equip("treasury_reserve"):
		return false
	if not await _set_reserve_and_refresh(3):
		return false
	for stat in [DEATH_FACTOR_STAT, BUILD_COST_STAT]:
		if not _expect_close("treasury_reserve L1 at 3 bands: %s" % stat,
				_wait_for_stat(stat, 0.97, 3), 0.97):
			return false
	var trade_capacity := _read_country_stat(TRADE_CAPACITY_STAT)
	_expect("treasury_reserve keeps its trade-capacity price below the baseline",
		trade_capacity < trade_capacity_before,
		"before=%.5f after=%.5f" % [trade_capacity_before, trade_capacity])
	if not await _set_reserve_and_refresh(20):
		return false
	for stat in [DEATH_FACTOR_STAT, BUILD_COST_STAT]:
		if not _expect_close(
				"treasury_reserve L1 cap at metric 69=20: %s" % stat,
				_wait_for_stat(stat, 0.95, 3), 0.95):
			return false
	if not _unequip("treasury_reserve"):
		return false
	return _expect_close(
		"treasury_reserve: unequip restores construction cost",
		_read_country_stat(BUILD_COST_STAT), 1.0)


func _exercise_silver_standard() -> bool:
	if not _equip("silver_standard"):
		return false
	if not await _set_reserve_and_refresh(10):
		return false
	if not _expect_close("silver_standard L1: trade capacity at 10 bands",
			_wait_for_stat(TRADE_CAPACITY_STAT, 1.10, 3), 1.10):
		return false
	if not _expect_close("silver_standard L1: national consumption price",
			_read_country_stat(CONSUMPTION_STAT), 1.02):
		return false
	if not await _set_reserve_and_refresh(20):
		return false
	if not _expect_close("silver_standard L1: trade cap at 12 bands",
			_wait_for_stat(TRADE_CAPACITY_STAT, 1.12, 3), 1.12):
		return false
	if not _unequip("silver_standard"):
		return false
	return _expect_close("silver_standard: unequip restores trade capacity",
		_read_country_stat(TRADE_CAPACITY_STAT), 1.0)


func _exercise_subsidy_state() -> bool:
	if not await _set_metric_and_refresh(
			METRIC_NET_TAX_BURDEN, int(0.04 * Q16_ONE), "net tax 4%"):
		return false
	if not _equip("subsidy_state"):
		return false
	var target := _first_reported_cell_target()
	if not _require("subsidy_state: target report selects an owned cell",
			target >= 0, str(_ext.get_ideology_effect_target_report(_handle))):
		return false
	for stat in CELL_OUTPUT_STATS:
		if not _expect_close(
				"subsidy_state L1: 4%% net tax cell gets +10%% %s" % stat,
				_wait_for_cell_stat(target, stat, 1.10, 3), 1.10):
			return false
	if not _expect_close("subsidy_state L1: construction cost price",
			_read_country_stat(BUILD_COST_STAT), 1.04):
		return false
	if not await _set_metric_and_refresh(
			METRIC_NET_TAX_BURDEN, int(0.10 * Q16_ONE), "net tax 10%"):
		return false
	for stat in CELL_OUTPUT_STATS:
		if not _expect_close(
				"subsidy_state L1: 10%% net tax misses the gate: %s" % stat,
				_wait_for_cell_stat(target, stat, 1.0, 3), 1.0):
			return false
	if not _unequip("subsidy_state"):
		return false
	return _expect_close(
		"subsidy_state: unequip restores construction cost",
		_read_country_stat(BUILD_COST_STAT), 1.0)


func _wait_for_stat(stat: String, expected: float, days: int) -> float:
	var value := _read_country_stat(stat)
	if absf(value - expected) <= 0.0005:
		return value
	for _day in range(days):
		_tick = _drive_days(1)
		value = _read_country_stat(stat)
		if absf(value - expected) <= 0.0005:
			return value
	return value


func _wait_for_cell_stat(cell_id: int, stat: String, expected: float,
		days: int) -> float:
	var value := _read_cell_stat(cell_id, stat)
	if absf(value - expected) <= 0.0005:
		return value
	for _day in range(days):
		_tick = _drive_days(1)
		value = _read_cell_stat(cell_id, stat)
		if absf(value - expected) <= 0.0005:
			return value
	return value


## The country stat as the ideology rows alone set it. `_equip` grants each
## card's draw-gate technologies, and their own modifier rows land on some of
## the same stats (trade capacity), so the whole-stat value is not the card's.
func _read_country_stat(stat: String) -> float:
	var explained: Dictionary = _ext.explain_modifier_stat(1, _handle, 0, stat, 1.0)
	var keys := PackedStringArray(explained.get("definition_keys", PackedStringArray()))
	var adds := PackedFloat64Array(explained.get("adds", PackedFloat64Array()))
	var factors := PackedFloat64Array(explained.get("factors", PackedFloat64Array()))
	var add := 0.0
	var factor := 1.0
	for index in range(mini(keys.size(), mini(adds.size(), factors.size()))):
		if keys[index].begins_with("ideology."):
			add += adds[index]
			factor *= factors[index]
	return (1.0 + add) * factor


func _ideology_rows(listed: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for key in PackedStringArray(listed.get("definition_keys", PackedStringArray())):
		if key.begins_with("ideology."):
			out.append(key)
	return out


func _read_cell_stat(cell_id: int, stat: String) -> float:
	return float(_ext.evaluate_modifier_stat(
		2, 0, cell_id, stat, 1.0))


func _first_reported_cell_target() -> int:
	var report: Dictionary = _ext.get_ideology_effect_target_report(_handle)
	var domains := PackedInt32Array(report.get(
		"target_domains", PackedInt32Array()))
	var targets := PackedInt64Array(report.get(
		"target_handles", PackedInt64Array()))
	for index in range(mini(domains.size(), targets.size())):
		if int(domains[index]) != 2:
			continue
		var cell_id := int(targets[index])
		if cell_id < 0 or cell_id >= WIDTH * HEIGHT:
			continue
		var summary: Dictionary = _ext.get_country_cell_summary(cell_id)
		if int(summary.get("country_handle", 0)) == _handle:
			return cell_id
	return -1


## Kept for the original progressive_tax cases; all metric overrides go through
## the same refresh path so the worker observes the new value.
func _set_reserve_and_refresh(reserve_pct: int) -> bool:
	return await _set_metric_and_refresh(
		METRIC_TREASURY_RESERVE, reserve_pct * Q16_ONE,
		"metric 69=%d" % reserve_pct)


func _set_metric_and_refresh(metric: int, value_q16: int,
		label: String) -> bool:
	var override: Dictionary = _ext.set_effect_metric_override_for_test(
		metric, value_q16, true)
	if not _require("%s override applies" % label,
			bool(override.get("ok", false)), str(override)):
		return false
	if not _require("%s digest refreshes" % label,
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return false
	var probe: Dictionary = _ext.sample_effect_metric_probe(
		metric, int(_ext.query_country_anchor_cell(0)), _handle)
	if not _require("%s probe returns the override" % label,
			bool(probe.get("ok", false))
				and int(probe.get("value", -1)) == value_q16, str(probe)):
		return false
	_tick = _drive_days(1)
	# Lambdas capture locals by value; the holder carries the last refresh out.
	var last: Array = [{}]
	var completed: bool = await WorkerWaitHelper.wait_for(
		func() -> bool:
			last[0] = _ext.step_ideology_instance_refresh(_tick)
			return bool(last[0].get("ok", false)) \
				and bool(last[0].get("done", false)),
		3, 120000,
		func() -> void: _tick = _drive_days(1))
	var refresh: Dictionary = last[0]
	if not completed:
		if not bool(refresh.get("ok", false)):
			return _require("%s ideology instance refresh succeeds" % label,
				false, str(refresh))
		return _require("%s ideology instance refresh completes" % label,
			false, "%s report=%s" % [
				str(refresh), str(_ext.get_runtime_thread_report())])
	return true


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
	# The worker services its peer inline in this headless loop. Leave the parity /
	# forced-playback gate off (`X16` uses the same setting for the same reason).
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 country ramp"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("country-ramp session configures",
			bool(session.get("ok", false)), str(session)):
		return {}
	await host.generate_world(SEED)
	var generator: MapGenerator = host.get_generator()
	if not _require("production world generation succeeds", generator != null):
		return {}
	var ext: Object = generator.get_data_core_world_ext()
	if not _require("production DCWorldExt is bound", ext != null):
		return {}
	_host = host
	_clock = clock
	_ext = ext
	ext.set_runtime_clock(true, WORKER_SPEED)
	# The fixture drives the calendar itself; generation already left the worker
	# running. `_drive_days` treats PAUSED as optional and waits on commit, not state.
	var handle := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		handle = int(summary.get("country_handle", 0))
		if handle != 0:
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {"host": host, "clock": clock, "ext": ext, "handle": handle}


func _teardown() -> void:
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _drive_days(days: int) -> int:
	var driven := WorkerWaitHelper.drive_worker_days(
		_host, _clock, _ext, _tick + 1, days, WORKER_SPEED)
	_tick = int(driven["day"])
	_expect("worker commits day %d" % _tick, bool(driven["ok"]), str(driven))
	return _tick


func _equip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		_fail("%s absent from the compiled catalog" % card)
		return false
	var gates: Dictionary = DrawGateHelper.grant_draw_gates(
		_host, card, _handle, _tick, _next_sequence)
	if not _require("%s: worker grants its draw gates" % card,
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	# The worker checks the frozen Country technology snapshot, so let the grant
	# commit before submitting DISCOVER.
	_drive_days(1)
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts discover" % card,
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_drive_days(2)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts equip" % card,
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_drive_days(3)
	var deadline := Time.get_ticks_msec() + 20000
	var slots_used := 0
	while Time.get_ticks_msec() < deadline:
		slots_used = int(_ext.get_ideology_snapshot(_handle).get(
			"ideology_slots_used", -1))
		if slots_used >= 1:
			break
		_drive_days(1)
	if not _require("%s: the card actually occupies a slot (slots=%d)"
			% [card, slots_used], slots_used >= 1, str(slots_used)):
		return false
	var row_deadline := Time.get_ticks_msec() + 20000
	var rows := PackedStringArray()
	while Time.get_ticks_msec() < row_deadline:
		var listed: Dictionary = _ext.list_modifiers(1, _handle, "")
		rows = PackedStringArray(listed.get(
			"definition_keys", PackedStringArray()))
		var instances: Dictionary = _ext.get_ideology_effect_target_report(
			_handle)
		if not rows.is_empty() and int(instances.get("count", 0)) > 0:
			break
		_drive_days(1)
	var instances: Dictionary = _ext.get_ideology_effect_target_report(_handle)
	return _require(
		"%s: the card published its targets (count=%d rows=%s)"
			% [card, int(instances.get("count", -1)), str(rows)],
		int(instances.get("count", 0)) > 0, str(instances))


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	_drive_days(3)
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
		var rows: Dictionary = _ext.list_modifiers(1, _handle, "")
		if int(snapshot.get("ideology_slots_used", -1)) == 0 and \
				_ideology_rows(rows).is_empty():
			break
		_drive_days(1)
	var final_snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	var final_rows: Dictionary = _ext.list_modifiers(1, _handle, "")
	return _require(
		"%s: unequip releases its slot and modifier row (slots=%d rows=%s)"
			% [card, int(final_snapshot.get("ideology_slots_used", -1)),
				str(final_rows.get("definition_keys", PackedStringArray()))],
		int(final_snapshot.get("ideology_slots_used", -1)) == 0 and
			_ideology_rows(final_rows).is_empty(),
		str(final_rows))


func _read_death_factor() -> float:
	return _read_country_stat(DEATH_FACTOR_STAT)


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


func _dense_id(card: String) -> int:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(country_ir, country_ir)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s"
			% String(native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get(
		"ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_economy_report"):
		return 0
	return int(ext.get_economy_report().get("current_day", 0))


func _expect_close(label: String, actual: float, expected: float) -> bool:
	return _expect(label + " (got %.5f)" % actual,
		absf(actual - expected) <= 0.0005, "%.5f vs %.5f" % [actual, expected])


func _expect(label: String, condition: bool, detail: String = "") -> bool:
	_checks += 1
	if condition:
		return true
	_failures += 1
	printerr("ERROR: [FAIL] %s%s" % [label,
		(" (%s)" % detail) if not detail.is_empty() else ""])
	return false


func _require(label: String, condition: bool, detail: String = "") -> bool:
	return _expect(label, condition, detail)


func _fail(reason: String) -> void:
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)
