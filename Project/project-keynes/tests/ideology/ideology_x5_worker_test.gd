extends SceneTree

## X5 worker acceptance: a per-country selector rewrite is active while its
## carrier card is equipped, disappears on unequip, and survives PKSR restore.
##
## The observable is always the Effect instance report plus the cell Modifier
## value. `antibiotics` rewrites every `cell.metropolis` selector to
## `cell.settlement`; `autonomous_logistics` rewrites thoroughfare R1 programs
## to R2. Both are resolved on the main-side ideology runtime after the worker
## has committed the card, so a catalog-only assertion would miss the seam.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const METRIC_CELL_TRADE_EVENTS := 8
const METRIC_CELL_POPULATION := 9
const METRIC_CELL_LANDFORM := 10
const METRIC_CELL_TERRAIN := 50
const METRIC_CELL_DOMINANT_OUTPUT_GOOD_ID := 45
const MODIFIER_DOMAIN_ECONOMY := 2
const OUTPUT_STAT := "economy.city.output_factor"
const SEL_NEIGHBORS_R1 := 6
const REWRITE_POPULATION := 800
const METROPOLIS_POPULATION := 1200
const MARKET_TRADE_EVENTS := 24

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const WorkerWaitHelper = preload(
	"res://tests/ideology/ideology_worker_wait_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _tick := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _metropolis_landform := -1
var _metropolis_terrain := -1
var _metropolis_good := -1


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x5 worker: %d checks, %d failures ===" % [
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
	_handle = int(fixture["handle"])
	_tick = int(fixture["tick"])
	var ok := await _test_tag_rewrite()
	ok = ok and await _test_route_rewrite()
	ok = ok and await _test_save_restore()
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 64)
		var reasons := PackedStringArray(receipts.get(
			"reasons", PackedStringArray()))
		if not reasons.is_empty():
			print("[x5-receipts] %s" % str(reasons))
	_teardown()
	return 0 if ok else 1


func _test_tag_rewrite() -> bool:
	var source := _pick_owned_settlement_not_metropolis()
	if not _require("an owned settlement-not-metropolis cell exists", source >= 0,
			str(source)):
		return false
	# Keep the source out of both native population bands. It is a settlement only
	# after `antibiotics` rewrites urban_sanitation's metropolis selector; before
	# that, neither the original metropolis tag nor a settlement tag may match.
	var snap: Dictionary = _ext.get_population_cell_snapshot(source, false)
	_require("source cell has a population snapshot", bool(snap.get("ok", false)),
		str(snap))
	if not _override_metric(METRIC_CELL_POPULATION, REWRITE_POPULATION):
		return false
	var before := _read_cell(source)
	_expect("cell starts at 1.00 before any equipped card", _is_close(before, 1.0),
		"%.5f" % before)
	if not await _equip("urban_sanitation"):
		return false
	var unchanged := _wait_for_cell(source, 1.0, 2)
	_expect("urban_sanitation alone leaves the non-metropolis source unchanged",
		_is_close(unchanged, 1.0), "%.5f" % unchanged)
	if not await _equip("antibiotics"):
		return false
	var rewritten := _wait_for_cell(source, 1.08, 12)
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	var targets := PackedInt64Array(report.get(
		"target_handles", PackedInt64Array()))
	_expect("antibiotics rewrites cell.metropolis to cell.settlement (got %.5f)"
			% rewritten, _is_close(rewritten, 1.08), "%.5f" % rewritten)
	_expect("rewritten instance report contains the source cell",
		targets.has(source), str(targets))
	if not await _unequip("antibiotics"):
		return false
	var restored := _wait_for_cell(source, 1.0, 12)
	_expect("unequipping antibiotics restores the original selector (got %.5f)"
			% restored, _is_close(restored, 1.0), "%.5f" % restored)
	if not await _unequip("urban_sanitation"):
		return false
	_clear_metric(METRIC_CELL_POPULATION)
	return true


func _test_route_rewrite() -> bool:
	if not _override_metric(METRIC_CELL_TRADE_EVENTS, MARKET_TRADE_EVENTS):
		return false
	var source := _pick_owned_market_source()
	if not _require("an owned market source exists for the route rewrite",
			source >= 0, str(source)):
		return false
	var target := _ring_target_outside_all_source_r1()
	if target < 0:
		# Metric 8 is fixture-wide; tagging every owned cell as `cell.market`
		# makes the union of all R1 rings cover the whole country on a 16x12
		# map. A target inside another source's R1 cannot distinguish R1 from
		# R2, so record the limitation rather than assert a vacuous value.
		print("[x5-route-skip] no owned R2 cell lies outside all source R1 rings "
			+ "(source=%d)" % source)
		_clear_metric(METRIC_CELL_TRADE_EVENTS)
		return true
	var before := _read_cell(target)
	_expect("route target starts at 1.00", _is_close(before, 1.0),
		"%.5f" % before)
	if not await _equip("autonomous_logistics"):
		return false
	var rewritten := _wait_for_cell(target, 1.02, 12)
	_expect("autonomous_logistics widens thoroughfare R1 to R2 (got %.5f)"
			% rewritten, _is_close(rewritten, 1.02), "%.5f" % rewritten)
	if not await _unequip("autonomous_logistics"):
		return false
	var restored := _wait_for_cell(target, 1.0, 12)
	_expect("unequipping autonomous_logistics restores the R1 selector (got %.5f)"
			% restored, _is_close(restored, 1.0), "%.5f" % restored)
	_clear_metric(METRIC_CELL_TRADE_EVENTS)
	return true


func _test_save_restore() -> bool:
	if not await _equip("urban_sanitation") or not await _equip("antibiotics"):
		return false
	var source := _pick_owned_settlement_not_metropolis()
	if not _require("save/load source cell still resolves", source >= 0, str(source)):
		return false
	if not _override_metric(METRIC_CELL_POPULATION, REWRITE_POPULATION):
		return false
	var before := _wait_for_cell(source, 1.08, 12)
	# Understanding keeps tiering the card up while the fixture drives days, so
	# the level captured by the save is whatever is live at this instant. The
	# restore contract is "preserve the captured tier", not "return to L1".
	var captured := _read_cell(source)
	_expect("tag rewrite is live before saving", before >= 1.0799,
		"%.5f" % before)
	var saved := _request_save(2026102401)
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	var pkcn: PackedByteArray = saved.get("country_pkcn", PackedByteArray())
	if not _require("PKSR captures the equipped rewrite",
			bool(saved.get("ready", false)) and not bundle.is_empty()
				and not pkcn.is_empty(), str(saved)):
		return false
	_ext.request_runtime_stop()
	_wait_stopped()
	var restored: Dictionary = _ext.restore_runtime_bundle(bundle)
	if not _require("PKSR bundle restores", bool(restored.get("restored", false)),
			str(restored)):
		return false
	var country_restore: Dictionary = _ext.restore_country_runtime_checkpoint(pkcn)
	if not _require("restored bundle also restores its Country checkpoint",
			bool(country_restore.get("ok", false)), str(country_restore)):
		return false
	var restarted: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0xFFF,
		"day": 0,
		"speed_days_per_second": WORKER_SPEED,
		"paused": false,
	})
	if not _require("worker restarts on the restored bundle",
			bool(restarted.get("ok", false)), str(restarted)):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	if not _override_metric(METRIC_CELL_POPULATION, REWRITE_POPULATION):
		return false
	# The restored card level is part of the saved state, not a fresh L1 derive.
	# It must come back at exactly the tier live when the save was taken; a
	# rebuild from the current selector would silently drop the understanding
	# tier (and an L2/L3 save would read as 1.08).
	var after := _read_cell(source)
	var restored_tier := await WorkerWaitHelper.wait_for(
		func() -> bool:
			after = _read_cell(source)
			return _is_close(after, captured),
		16, 120000,
		func() -> void: _tick = _drive_days(1))
	_expect("restored tag rewrite still applies (got %.5f)" % after,
		restored_tier and _is_close(after, captured),
		"restored=%.5f captured=%.5f" % [after, captured])
	_clear_metric(METRIC_CELL_POPULATION)
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
	host.runtime_parity_forcing = true
	get_root().add_child(host)
	await process_frame
	host.configure(null, null, clock)
	host.set_climate_authority_override("force_on")
	var config := NewGameConfig.create_default()
	config.country.name = "C0 X5"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x5 session configures", bool(session.get("ok", false)),
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
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(true, WORKER_SPEED)
	if not _require("worker reaches a paused boundary", _wait_worker_paused(ext)):
		return {}
	var handle := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != 0:
			handle = int(summary.get("country_handle", 0))
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	_handle = handle
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	if not _require("effect input digest refreshes",
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return {}
	return {"host": host, "clock": clock, "ext": ext, "handle": handle,
		"tick": _tick}


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
	_tick = _drive_days(1)
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts discover" % card,
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_tick = _drive_days(2)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts equip" % card,
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_tick = _drive_days(2)
	var slots := 0
	var known_id := -1
	var ready := await WorkerWaitHelper.wait_for(
		func() -> bool:
			var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
			known_id = dense if PackedInt32Array(snapshot.get(
				"known_ids", PackedInt32Array())).has(dense) else -1
			slots = int(snapshot.get("ideology_slots_used", -1))
			return known_id == dense and slots >= 1,
		16, 120000,
		func() -> void: _tick = _drive_days(1))
	if ready:
		return true
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[x5-equip] %s opcodes=%s reasons=%s snapshot=%s" % [card,
			str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_ext.get_ideology_snapshot(_handle))])
	return _require("%s: card is known and occupies a slot (known=%d slots=%d)"
		% [card, known_id, slots], known_id == dense and slots >= 1,
		str(slots))


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	var slots := int(_ext.get_ideology_snapshot(_handle).get(
		"ideology_slots_used", -1))
	var started_slots := slots
	var released := await WorkerWaitHelper.wait_for(
		func() -> bool:
			slots = int(_ext.get_ideology_snapshot(_handle).get(
				"ideology_slots_used", -1))
			return slots < started_slots,
		16, 120000,
		func() -> void: _tick = _drive_days(1))
	if released:
		return true
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[x5-unequip] %s opcodes=%s statuses=%s reasons=%s snapshot=%s"
			% [card, str(receipts.get("opcodes", PackedInt32Array())),
				str(receipts.get("statuses", PackedInt32Array())),
				str(receipts.get("reasons", PackedStringArray())),
				str(_ext.get_ideology_snapshot(_handle))])
	return _require("%s: unequip releases the slot (slots=%d)" % [card, slots],
		slots < started_slots, str(slots))


func _pick_owned_settlement_not_metropolis() -> int:
	for cell in range(WIDTH * HEIGHT):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) != _handle:
			continue
		var snapshot: Dictionary = _ext.get_population_cell_snapshot(cell, false)
		var population := int(snapshot.get("population", 0))
		if population >= REWRITE_POPULATION \
				and population < METROPOLIS_POPULATION:
			return cell
	# The starter fixture does not guarantee a settlement above P1; the first
	# owned land cell is still a valid settlement after the metric override.
	for cell in range(WIDTH * HEIGHT):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == _handle:
			if not bool(_host.get_current_map().is_water_arr[cell]):
				return cell
	return -1


func _pick_owned_market_source() -> int:
	for cell in range(WIDTH * HEIGHT):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) != _handle:
			continue
		if int(_ext.sample_effect_metric_probe(METRIC_CELL_TRADE_EVENTS, cell,
				_handle).get("value", 0)) >= MARKET_TRADE_EVENTS * Q16_ONE:
			return cell
	return -1


func _ring_target_outside_all_source_r1() -> int:
	var sources := _owned_market_sources()
	if sources.is_empty():
		return -1
	# Metric 8 is overridden for the whole grid, so every owned cell is a market
	# source. A cell can only prove the R1 -> R2 widening if it is in NO source's
	# R1 ring; checking only the chosen source would make the "before" read fail
	# whenever another market already covers it.
	var covered := {}
	for source in sources:
		for cell in _ext.query_effect_target_cells(
				int(source), SEL_NEIGHBORS_R1, 32, 0):
			covered[int(cell)] = true
	for source in sources:
		for cell in _ext.query_effect_target_cells(int(source), 7, 32, 0):
			var target := int(cell)
			if covered.has(target):
				continue
			if int(_ext.get_country_cell_summary(target).get(
					"country_handle", 0)) == _handle:
				return target
	return -1


func _owned_market_sources() -> PackedInt32Array:
	var out := PackedInt32Array()
	for cell in range(WIDTH * HEIGHT):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == _handle:
			out.append(cell)
	return out


func _override_metric(metric: int, value: int) -> bool:
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		metric, value * Q16_ONE, true)
	if not bool(applied.get("ok", false)):
		return _require("metric %d override applies" % metric, false, str(applied))
	if not _require("effect input digest refreshes after metric %d" % metric,
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return false
	var probe: Dictionary = _ext.sample_effect_metric_probe(metric,
		_owned_anchor(), _handle)
	_require("metric %d probe returns the override" % metric,
		bool(probe.get("ok", false))
			and int(probe.get("value", -1)) == value * Q16_ONE, str(probe))
	return true


func _clear_metric(metric: int) -> void:
	_ext.set_effect_metric_override_for_test(metric, 0, false)
	_ext.refresh_effect_input_digest_for_test()


func _read_cell(cell: int) -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, 0, cell, OUTPUT_STAT, 1.0))


func _wait_for_cell(cell: int, expected: float, days: int) -> float:
	var value := _read_cell(cell)
	for _day in range(days):
		if _is_close(value, expected):
			return value
		_tick = _drive_days(1)
		value = _read_cell(cell)
	return value


func _drive_days(days: int) -> int:
	for _day in range(days):
		_tick += 1
		_clock.current_day = float(_tick)
		_host.run_daily_tick(_tick, _clock.season_phase_for_day(_tick))
		_host.finish_daily_tick(0.0, {})
		var pulses := 0
		while _has_hard_barrier() and pulses < 400:
			_clock.simulation_backpressure_pulse.emit(_tick)
			pulses += 1
		# Publish the revision the day just produced, not the previous one.
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
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


func _request_save(request_id: int) -> Dictionary:
	var request: Dictionary = {}
	for _attempt in range(24):
		request = _ext.request_runtime_save(request_id)
		if String(request.get("code", "")) != "save_request_busy":
			break
		_ext.poll_runtime_save(request_id)
		OS.delay_msec(5)
	if not bool(request.get("pending", false)):
		return request
	var saved := {}
	var ready := WorkerWaitHelper.wait_until(
		func() -> bool:
			saved = _ext.poll_runtime_save(request_id)
			return bool(saved.get("ready", false)),
		120000,
		func() -> void:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true))
	if ready:
		return saved
	return {}


func _owned_anchor() -> int:
	for cell in range(WIDTH * HEIGHT):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) == _handle:
			return cell
	return 0


func _wait_pod_day(baseline: int, timeout_msec: int) -> int:
	var reached := baseline
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = _ext.get_runtime_thread_report()
			reached = int(report.get("ideology_pod_committed_day", -1))
			return reached > baseline \
				or String(report.get("simulation_host_state", "")) in [
					"STOPPED", "FAULTED"],
		maxi(timeout_msec, 120000),
		func() -> void:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true))
	return reached


func _wait_worker_paused(ext: Object) -> bool:
	return WorkerWaitHelper.wait_until(
		func() -> bool:
			return String(ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "PAUSED",
		120000)


func _wait_stopped() -> void:
	WorkerWaitHelper.wait_until(
		func() -> bool:
			return String(_ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "STOPPED",
		120000,
		func() -> void: _ext.poll_runtime_save(0))


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method(
		"has_hard_barrier") else false


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_economy_report"):
		return 0
	return int(ext.get_economy_report().get("current_day", 0))


func _is_close(a: float, b: float, tolerance: float = 0.0005) -> bool:
	return absf(a - b) <= tolerance


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
	_failures += 1
	printerr("ERROR: [FAIL] %s" % reason)
