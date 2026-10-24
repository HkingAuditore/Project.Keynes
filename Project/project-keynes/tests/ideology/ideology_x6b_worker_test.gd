extends SceneTree

## X6-b worker acceptance: a card tier grants a free draw through the native
## Effect custom-domain adapter, and OPEN_OFFER consumes that row state without
## charging points. Uses the production catalog and worker authority.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const CARD := "civil_examination"

const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const WorkerWaitHelper = preload(
	"res://tests/ideology/ideology_worker_wait_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _generator: MapGenerator
var _ext: Object
var _handle := 0
var _tick := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x6b worker: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(code if code != 0 else (0 if _failures == 0 else 1))


func _run() -> int:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return 1
	var probe: Object = DCWorldExt.new()
	if not _require("X6-b POD self-test exported",
			probe.has_method("runtime_ideology_pod_self_test")):
		return 1
	if not _require("X6-b free vs paid draw RNG contract",
			bool(probe.runtime_ideology_pod_self_test()),
			"POD self-test failed"):
		return 1
	var fixture := await _build_world()
	if fixture.is_empty():
		_teardown()
		return 1
	_host = fixture["host"]
	_clock = fixture["clock"]
	_generator = fixture["generator"]
	_ext = fixture["ext"]
	_handle = int(fixture["handle"])
	_tick = int(fixture["tick"])
	var ok := await _test_free_draw_lifecycle()
	_teardown()
	return 0 if ok else 1


func _test_free_draw_lifecycle() -> bool:
	if not await _equip(CARD):
		return false
	var snapshot := _snapshot()
	_expect("equipped card occupies the first ideology slot",
		int(snapshot.get("ideology_slots_used", 0)) >= 1,
		str(snapshot.get("ideology_slots_used", 0)))
	# Level progression is one tier per transition. Crossing straight to the L3
	# threshold from L2 leaves the row at L2 with no transition, so the fixture
	# must settle L2 and then cross L3.
	var to_l2: Dictionary = _submit([{
		"op": 8, "day": _tick, "handle": _handle,
		"idea": _dense_id(CARD), "value": 786432}])
	if not _require("worker accepts understanding through L2",
			bool(to_l2.get("ok", false)), str(to_l2)):
		return false
	if not await _wait_for("L2 transition settles before crossing L3",
			func() -> bool:
				var rows := _snapshot()
				var dense := _dense_id(CARD)
				var row := PackedInt32Array(rows.get(
					"idea_ids", PackedInt32Array())).find(dense)
				return row >= 0 \
					and int(PackedInt32Array(rows.get(
						"levels", PackedInt32Array()))[row]) == 2 \
					and int(PackedByteArray(rows.get(
						"transition_pending", PackedByteArray()))[row]) == 0,
			48):
		return false
	var to_l3: Dictionary = _submit([{
		"op": 8, "day": _tick, "handle": _handle,
		"idea": _dense_id(CARD), "value": 524288}])
	if not _require("worker accepts understanding through L3",
			bool(to_l3.get("ok", false)), str(to_l3)):
		return false
	if not await _wait_for("exactly one Effect-delivered free draw",
			func() -> bool: return int(_snapshot().get("free_draws", 0)) == 1,
			32):
		return false
	_tick = _drive_days(4)
	_expect("extra days do not duplicate the on-enter grant",
		int(_snapshot().get("free_draws", 0)) == 1,
		str(_snapshot()))
	_expect("snapshot exposes free_draws",
		_snapshot().has("free_draws")
			and int(_snapshot().get("free_draws", 0)) == 1,
		str(_snapshot()))
	var before := _snapshot()
	var saved := _request_save(2026102401)
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	var country_pkcn: PackedByteArray = saved.get(
		"country_pkcn", PackedByteArray())
	if not _require("PKSR captures free_draws",
			bool(saved.get("ready", false)) and not bundle.is_empty()
				and not country_pkcn.is_empty(), str(saved)):
		return false
	_ext.request_runtime_stop()
	_wait_stopped()
	var restored: Dictionary = _ext.restore_runtime_bundle(bundle)
	if not _require("runtime bundle restores X6-b state",
			bool(restored.get("restored", false)), str(restored)):
		return false
	var country_restore: Dictionary = _ext.restore_country_runtime_checkpoint(
		country_pkcn)
	if not _require("Country checkpoint restores with the bundle",
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
	if not _require("worker restarts on the restored X6-b state",
			bool(restarted.get("ok", false)), str(restarted)):
		return false
	if not _require("restored worker reaches a paused boundary",
			_wait_worker_paused(_ext), str(_ext.get_runtime_thread_report())):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	_tick = _drive_days(1)
	_expect("save/load preserves free_draws",
		int(_snapshot().get("free_draws", 0)) == 1, str(_snapshot()))

	before = _snapshot()
	var points_before := int(before.get("ideology_points_q16", 0))
	var lifetime_before := int(before.get("lifetime_points_q16", 0))
	var draw_before := int(before.get("draw_sequence", 0))
	var opened: Dictionary = _submit([{
		"op": 3, "day": _tick, "handle": _handle}])
	if not _require("OPEN_OFFER accepts the free draw",
			bool(opened.get("ok", false)), str(opened)):
		return false
	if not await _wait_for("free draw is consumed and an offer opens",
			func() -> bool:
				var row := _snapshot()
				return int(row.get("free_draws", 0)) == 0 \
					and int(row.get("draw_sequence", 0)) == draw_before + 1 \
					and int(row.get("offer_generation", 0)) > 0,
			16):
		return false
	var after := _snapshot()
	var lifetime_after := int(after.get("lifetime_points_q16", 0))
	var points_after := int(after.get("ideology_points_q16", 0))
	# Accrual can land between the two samples: a committed settlement adds the
	# same amount to both the balance and lifetime. spent is therefore the
	# amount actually charged to the balance, and a free draw may only make it
	# zero or negative (unspent accrual). A paid draw would make it positive.
	var spent := points_before + (lifetime_after - lifetime_before) \
		- points_after
	_expect("a free draw spends no points",
		spent <= 0 and points_after >= points_before,
		"before=%d after=%d lifetime_before=%d lifetime_after=%d spent=%d" % [
			points_before, points_after,
			lifetime_before, lifetime_after, spent])
	_expect("a free draw decrements free_draws",
		int(after.get("free_draws", 0)) == 0, str(after))
	_expect("a free draw advances pity / draw_sequence",
		int(after.get("draw_sequence", 0)) == draw_before + 1,
		"before=%d after=%d" % [
			draw_before, int(after.get("draw_sequence", 0))])
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
	config.country.name = "C0 X6b"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x6b session configures", bool(session.get("ok", false)),
			str(session)):
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
	_generator = generator
	_ext = ext
	ext.set_runtime_ideology_parity_enabled(true)
	ext.set_runtime_clock(true, WORKER_SPEED)
	if not _require("worker reaches a paused boundary",
			_wait_worker_paused(ext)):
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
	return {"host": host, "clock": clock, "generator": generator, "ext": ext,
		"handle": handle, "tick": _tick}


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
	var location := -1
	var rows := PackedStringArray()
	var equipped_row := await WorkerWaitHelper.wait_for(
		func() -> bool:
			location = _location_for(_snapshot(), dense)
			if location != 1:
				return false
			rows = PackedStringArray(_ext.list_modifiers(
				1, _handle, "").get("definition_keys",
				PackedStringArray()))
			for row in rows:
				if String(row).begins_with("ideology.%s" % card):
					return true
			return false,
		24, 120000,
		func() -> void: _tick = _drive_days(1))
	if equipped_row:
		return _require("%s: equip consumes a slot" % card,
			int(_snapshot().get("ideology_slots_used", 0)) >= 1,
			str(_snapshot()))
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[x6b-equip] %s opcodes=%s reasons=%s snapshot=%s" % [
			card, str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_ext.get_ideology_snapshot(_handle))])
	return _require("%s: card is equipped with a modifier row (location=%d)"
		% [card, location], equipped_row, str(rows))


func _snapshot() -> Dictionary:
	return _ext.get_ideology_snapshot(_handle)


func _location_for(snapshot: Dictionary, dense: int) -> int:
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get(
		"locations", PackedInt32Array())
	var pending: PackedByteArray = snapshot.get(
		"transition_pending", PackedByteArray())
	var row := ids.find(dense)
	if row < 0 or row >= locations.size():
		return -1
	if row < pending.size() and pending[row] != 0:
		return -1
	return int(locations[row])


func _dense_id(card: String) -> int:
	var catalog: Resource = load("res://data/ideologies/default_ideology_catalog.tres")
	if catalog == null:
		return -1
	var economy_catalog: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var native: Dictionary = catalog.compile_native_catalog(
		economy_catalog, economy_catalog)
	if not bool(native.get("ok", false)):
		_fail("ideology catalog compile failed: %s" % String(
			native.get("reason", "unknown")))
		return -1
	var ids := PackedStringArray(native.get("ideology_ids", PackedStringArray()))
	return ids.find("idea.%s" % card)


const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")


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
		_wait_pod_day(before, 3000)
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


func _wait_for(label: String, predicate: Callable, days: int) -> bool:
	var passed := await WorkerWaitHelper.wait_for(
		predicate, days, 120000,
		func() -> void: _tick = _drive_days(1))
	if passed:
		_expect(label, true)
		return true
	var row := _snapshot()
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 64)
		printerr("[x6b-wait] %s reasons=%s report=%s" % [
			label, str(receipts.get("reasons", PackedStringArray())),
			str(_ext.get_effect_native_adapter_report())])
	return _require(label, false, str(row))


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
			var state := String(ext.get_runtime_thread_report().get(
				"simulation_host_state", ""))
			return state == "PAUSED",
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
