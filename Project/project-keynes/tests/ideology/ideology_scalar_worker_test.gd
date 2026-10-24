extends SceneTree

## Doc 17 section 5 acceptance on the production worker path.
##
## The real default ideology catalog is used deliberately. The scalar values are
## derived from equipped card state, so a synthetic catalog adds no coverage and
## cannot prove the production catalog/runtime seam. Two granary-route cards
## cross the `route.granary.2` synergy and exercise route_count,
## active_synergy_count and unlocked_era; public_hygiene also carries an era-3
## draw gate.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const Q16_ONE := 65536

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _generator: MapGenerator
var _handle := 0
var _tick := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology scalar worker: %d checks, %d failures ===" % [
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
	_tick = int(fixture["tick"])
	var ok := await _test_scalars()
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 64)
		var reasons := PackedStringArray(receipts.get(
			"reasons", PackedStringArray()))
		if not reasons.is_empty():
			print("[scalar-receipts] %s" % str(reasons))
	_teardown()
	return 0 if ok else 1


func _test_scalars() -> bool:
	if not await _equip("pit_dwelling"):
		return false
	var snapshot := _snapshot()
	_expect("one card reports equipped_count 1",
		int(snapshot.get("ideology_scalar_equipped_count", -1)) == 1,
		str(snapshot))
	var routes: Dictionary = snapshot.get("ideology_scalar_route_counts", {})
	_expect("one granary card reports route_count.granary 1",
		int(routes.get("granary", -1)) == 1, str(routes))
	_expect("one card activates no synergy",
		int(snapshot.get("ideology_scalar_active_synergy_count", -1)) == 0,
		str(snapshot))
	var one_card_signature := int(
		_ext.compute_idea_activation_signature_for_test(
			_handle, _dense_id("pit_dwelling")))

	if not await _equip("public_hygiene"):
		return false
	if not _wait_technology("tech.imperial_integration"):
		return false
	snapshot = _snapshot()
	routes = snapshot.get("ideology_scalar_route_counts", {})
	_expect("two cards report equipped_count 2",
		int(snapshot.get("ideology_scalar_equipped_count", -1)) == 2,
		str(snapshot))
	_expect("two granary cards report route_count.granary 2",
		int(routes.get("granary", -1)) == 2, str(routes))
	_expect("route.granary.2 activates one synergy",
		int(snapshot.get("ideology_scalar_active_synergy_count", -1)) == 1,
		str(snapshot))
	_expect("the empire milestone unlocks era 3",
		int(snapshot.get("ideology_scalar_unlocked_era", -1)) == 3,
		str(snapshot))
	var two_card_signature := int(
		_ext.compute_idea_activation_signature_for_test(
			_handle, _dense_id("pit_dwelling")))
	_expect("route_count change moves the observer signature",
		two_card_signature != one_card_signature,
		"before=%d after=%d" % [one_card_signature, two_card_signature])

	if not _unequip("public_hygiene"):
		return false
	snapshot = _snapshot()
	routes = snapshot.get("ideology_scalar_route_counts", {})
	_expect("unequip restores equipped_count 1",
		int(snapshot.get("ideology_scalar_equipped_count", -1)) == 1,
		str(snapshot))
	_expect("unequip restores route_count.granary 1",
		int(routes.get("granary", -1)) == 1, str(routes))
	_expect("unequip deactivates the granary synergy",
		int(snapshot.get("ideology_scalar_active_synergy_count", -1)) == 0,
		str(snapshot))

	if not await _equip("public_hygiene"):
		return false
	snapshot = _snapshot()
	_expect("saved state has two equipped cards",
		int(snapshot.get("ideology_scalar_equipped_count", -1)) == 2,
		str(snapshot))
	var saved_signature := int(
		_ext.compute_idea_activation_signature_for_test(
			_handle, _dense_id("pit_dwelling")))
	var saved := _request_save(2026102402)
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	var country_pkcn: PackedByteArray = saved.get(
		"country_pkcn", PackedByteArray())
	if not _require("PKSR captures Effect and Ideology sections",
			bool(saved.get("ready", false)) and not bundle.is_empty()
				and not country_pkcn.is_empty(), str(saved)):
		return false
	_ext.request_runtime_stop()
	_wait_stopped()
	var restored: Dictionary = _ext.restore_runtime_bundle(bundle)
	if not _require("the worker bundle restores",
			bool(restored.get("restored", false)), str(restored)):
		return false
	var country_restore: Dictionary = _ext.restore_country_runtime_checkpoint(
		country_pkcn)
	if not _require("the restored bundle also restores Country",
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
	if not _require("the worker restarts on restored state",
			bool(restarted.get("ok", false)), str(restarted)):
		return false
	if not _require("the restored worker reaches a paused boundary",
			_wait_worker_paused(_ext), str(_ext.get_runtime_thread_report())):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	_tick = _drive_days(3)
	snapshot = _snapshot()
	routes = snapshot.get("ideology_scalar_route_counts", {})
	_expect("save/load preserves equipped_count 2",
		int(snapshot.get("ideology_scalar_equipped_count", -1)) == 2,
		str(snapshot))
	_expect("save/load preserves route_count.granary 2",
		int(routes.get("granary", -1)) == 2, str(routes))
	_expect("save/load preserves active_synergy_count 1",
		int(snapshot.get("ideology_scalar_active_synergy_count", -1)) == 1,
		str(snapshot))
	_expect("save/load preserves unlocked_era 3",
		int(snapshot.get("ideology_scalar_unlocked_era", -1)) == 3,
		str(snapshot))
	_expect("save/load preserves the activation signature",
		int(_ext.compute_idea_activation_signature_for_test(
			_handle, _dense_id("pit_dwelling"))) == saved_signature,
		"saved=%d restored=%d" % [saved_signature,
			int(_ext.compute_idea_activation_signature_for_test(
				_handle, _dense_id("pit_dwelling")))])
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
	config.country.name = "C0 Scalar"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("scalar session configures", bool(session.get("ok", false)),
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
	_ext = ext
	_generator = generator
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
	return {"host": host, "clock": clock, "ext": ext,
		"generator": generator, "handle": handle, "tick": _tick}


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
	var deadline := Time.get_ticks_msec() + 16000
	var slots := 0
	var known := false
	var location := -1
	while Time.get_ticks_msec() < deadline:
		var snapshot := _snapshot()
		known = PackedInt32Array(snapshot.get(
			"known_ids", PackedInt32Array())).has(dense)
		slots = int(snapshot.get("ideology_slots_used", -1))
		location = _location_for(snapshot, dense)
		if known and slots >= 1 and location == 1:
			return true
		_tick = _drive_days(1)
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[scalar-equip] %s opcodes=%s reasons=%s snapshot=%s" % [
			card, str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_ext.get_ideology_snapshot(_handle))])
	return _require(
		"%s: card is known and equipped (known=%s slots=%d location=%d)"
			% [card, str(known), slots, location],
		known and slots >= 1 and location == 1,
		str(_ext.get_ideology_snapshot(_handle)))


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
	var deadline := Time.get_ticks_msec() + 16000
	var slots := before
	var location := 1
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		var snapshot := _snapshot()
		slots = int(snapshot.get("ideology_slots_used", -1))
		location = _location_for(snapshot, dense)
		if slots < before and location == 0:
			return true
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[scalar-unequip] %s opcodes=%s statuses=%s reasons=%s snapshot=%s" % [
			card, str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("statuses", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_ext.get_ideology_snapshot(_handle))])
	return _require(
		"%s: unequip releases the slot (slots=%d before=%d location=%d)"
			% [card, slots, before, location],
		slots < before and location == 0,
		str(_ext.get_ideology_snapshot(_handle)))


func _location_for(snapshot: Dictionary, dense: int) -> int:
	var ids: PackedInt32Array = snapshot.get(
		"idea_ids", PackedInt32Array())
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


func _wait_technology(technology_id: String) -> bool:
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		var snapshot: Dictionary = _ext.get_country_snapshot(_handle)
		if PackedStringArray(snapshot.get(
				"technology_ids", PackedStringArray())).has(technology_id):
			return true
		_tick = _drive_days(1)
	return _require("%s becomes visible to Country" % technology_id, false,
		str(_ext.get_country_snapshot(_handle)))


func _snapshot() -> Dictionary:
	return _ext.get_ideology_snapshot(_handle)


func _drive_days(days: int) -> int:
	for _day in range(days):
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
	var request: Dictionary = _ext.request_runtime_save(request_id)
	var busy_deadline := Time.get_ticks_msec() + 8000
	while String(request.get("code", "")) == "save_request_busy" \
			and Time.get_ticks_msec() < busy_deadline:
		OS.delay_msec(20)
		_ext.poll_runtime_save(request_id)
		request = _ext.request_runtime_save(request_id)
	if not bool(request.get("pending", false)):
		return request
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		var saved: Dictionary = _ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)):
			return saved
		OS.delay_msec(5)
	return {}


func _wait_pod_day(baseline: int, timeout_msec: int) -> int:
	var deadline := Time.get_ticks_msec() + timeout_msec
	var reached := baseline
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		OS.delay_msec(2)
		var report: Dictionary = _ext.get_runtime_thread_report()
		reached = int(report.get("ideology_pod_committed_day", -1))
		if reached > baseline:
			return reached
		if String(report.get("simulation_host_state", "")) in [
				"STOPPED", "FAULTED"]:
			return reached
	return reached


func _wait_worker_paused(ext: Object) -> bool:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var state := String(ext.get_runtime_thread_report().get(
			"simulation_host_state", ""))
		if state == "PAUSED":
			return true
		if state in ["STOPPED", "FAULTED"]:
			return false
		OS.delay_msec(2)
	return false


func _wait_stopped() -> void:
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		if String(_ext.get_runtime_thread_report().get(
				"simulation_host_state", "")) == "STOPPED":
			return
		OS.delay_msec(5)


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
