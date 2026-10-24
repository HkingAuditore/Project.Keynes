extends SceneTree

## X6-c worker acceptance: deterministic slot order + copied left-neighbour
## programs, using the production catalog and the production worker pod.
##
## `algorithmic_governance` reads the managed program list of the card in the
## immediately-left ideology slot, but owns fresh Effect instances under its own
## idea id. The test changes the left source, checks the copied program hashes
## and activation signature, excludes a legendary source at L1, then restores
## the slot indices and copied source from a runtime save.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const CITIES_POPULATION := 800

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const SOURCE_A := "public_hygiene"
const SOURCE_B := "urban_sanitation"
const COPIER := "algorithmic_governance"
const LEGENDARY_SOURCE := "computing_networks"
const CAPACITY_TECHNOLOGY := "tech.kingdom_administration"

var _host: WorldRuntimeHost
var _clock: WorldClock
var _generator: MapGenerator
var _ext: Object
var _handle := 0
var _tick := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _program_hash_a := 0
var _program_hash_b := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x6c worker: %d checks, %d failures ===" % [
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
	_generator = fixture["generator"]
	_ext = fixture["ext"]
	_handle = int(fixture["handle"])
	_tick = int(fixture["tick"])
	var ok := await _test_copy_lifecycle()
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 64)
		var reasons := PackedStringArray(receipts.get(
			"reasons", PackedStringArray()))
		if not reasons.is_empty():
			print("[x6c-receipts] %s" % str(reasons))
	_teardown()
	return 0 if ok else 1


func _test_copy_lifecycle() -> bool:
	if not _install_selector_fixture():
		return false
	if not await _equip(SOURCE_A):
		return false
	if _slot_of(SOURCE_A) != 0:
		return _require("source A occupies slot 0", false,
			str(_slots()))
	_program_hash_a = _wait_idea_report_hash(SOURCE_A)
	var signature_before_copier := _signature(COPIER)
	if not await _equip(SOURCE_B):
		return false
	if _slot_of(SOURCE_B) != 1:
		return _require("source B occupies slot 1", false,
			str(_slots()))
	_program_hash_b = _wait_idea_report_hash(SOURCE_B)
	# `algorithmic_governance` is an era-10 card; the era-2 milestone grants the
	# third ideology slot used by the copier in this fixture.
	if not await _grant_technology(CAPACITY_TECHNOLOGY):
		return false
	if not await _equip(COPIER):
		return false
	_expect("copier occupies slots [0, 1, 2]",
		_slots() == PackedInt32Array([0, 1, 2]), str(_slots()))
	var copied_b := _copier_report_rows()
	_expect("source programs are distinct and published",
		_program_hash_a != 0 and _program_hash_b != 0 and
			_program_hash_a != _program_hash_b,
		"A=%d B=%d" % [_program_hash_a, _program_hash_b])
	_expect("copier owns B's managed program hash",
		copied_b.has(_program_hash_b), str(copied_b))
	_expect("copier owns exactly one source-B program row",
		copied_b.size() == 1 and copied_b[0] == _program_hash_b,
		str(copied_b))
	_expect("copier instances target B's metropolis cells",
		not _report_targets(copied_b).is_empty(), str(copied_b))
	var signature_b := _signature(COPIER)
	_expect("equipping the copier changes its activation signature",
		signature_b != signature_before_copier,
		"before=%d after=%d" % [signature_before_copier, signature_b])

	if not _unequip(SOURCE_B):
		return false
	if not await _equip(LEGENDARY_SOURCE):
		return false
	# The smallest free ideology slot is the one B released. Legendary sources
	# are copyable=0 at every level, so the copier must not adopt any program.
	_expect("replacement source occupies B's freed slot 1",
		_slot_of(LEGENDARY_SOURCE) == 1, str(_slots()))
	var legendary_rows := _copier_report_rows()
	_expect("copier excludes a legendary source's programs",
		legendary_rows.is_empty(), str(legendary_rows))
	var signature_legendary := _signature(COPIER)
	_expect("changing the left source changes the copier signature",
		signature_legendary != signature_b,
		"B=%d legendary=%d" % [signature_b, signature_legendary])
	if not _install_selector_fixture():
		return false

	if not _unequip(LEGENDARY_SOURCE):
		return false
	if not await _equip(SOURCE_B):
		return false
	_expect("source B returns to its deterministic smallest slot",
		_slot_of(SOURCE_B) == 1, str(_slots()))
	var restored_rows := _copier_report_rows()
	_expect("copier re-adopts B's program after the source returns",
		restored_rows.has(_program_hash_b), str(restored_rows))
	var saved_slots := _slots()
	var saved_signature := _signature(COPIER)
	var saved := _request_save(2026102403)
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	var country_pkcn: PackedByteArray = saved.get("country_pkcn", PackedByteArray())
	if not _require("PKSR captures the X6-c slot state",
			bool(saved.get("ready", false)) and not bundle.is_empty()
				and not country_pkcn.is_empty(), str(saved)):
		return false
	_ext.request_runtime_stop()
	_wait_stopped()
	var restored: Dictionary = _ext.restore_runtime_bundle(bundle)
	if not _require("the worker bundle restores X6-c state",
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
	if not _require("the worker restarts on restored X6-c state",
			bool(restarted.get("ok", false)), str(restarted)):
		return false
	if not _require("the restored worker reaches a paused boundary",
			_wait_worker_paused(_ext), str(_ext.get_runtime_thread_report())):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	_expect("save/load preserves slot indices",
		_slots() == saved_slots, "before=%s after=%s" % [
			str(saved_slots), str(_slots())])
	_expect("save/load preserves the copied source program",
		_copier_report_rows().has(_program_hash_b), str(_copier_report_rows()))
	_expect("save/load preserves the copier activation signature",
		_signature(COPIER) == saved_signature,
		"saved=%d restored=%d" % [saved_signature, _signature(COPIER)])
	_tick = _drive_days(3)
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
	config.country.name = "C0 X6c"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("x6c session configures", bool(session.get("ok", false)),
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
	var deadline := Time.get_ticks_msec() + 16000
	var location := -1
	while Time.get_ticks_msec() < deadline:
		location = _location_for(_snapshot(), dense)
		if location == 1:
			return true
		_tick = _drive_days(1)
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[x6c-equip] %s opcodes=%s reasons=%s snapshot=%s" % [
			card, str(receipts.get("opcodes", PackedInt32Array())),
			str(receipts.get("reasons", PackedStringArray())),
			str(_ext.get_ideology_snapshot(_handle))])
	return _require("%s: card is equipped (location=%d)" % [card, location],
		location == 1, str(_ext.get_ideology_snapshot(_handle)))


func _unequip(card: String) -> bool:
	var dense := _dense_id(card)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("%s: worker accepts unequip" % card,
			bool(result.get("ok", false)), str(result)):
		return false
	var deadline := Time.get_ticks_msec() + 16000
	var location := 1
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		location = _location_for(_snapshot(), dense)
		if location == 0:
			return true
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[x6c-unequip] %s opcodes=%s statuses=%s reasons=%s snapshot=%s"
			% [card, str(receipts.get("opcodes", PackedInt32Array())),
				str(receipts.get("statuses", PackedInt32Array())),
				str(receipts.get("reasons", PackedStringArray())),
				str(_ext.get_ideology_snapshot(_handle))])
	return _require("%s: unequip releases its slot (location=%d)" % [
			card, location], location == 0,
		str(_ext.get_ideology_snapshot(_handle)))


func _snapshot() -> Dictionary:
	return _ext.get_ideology_snapshot(_handle)


func _install_selector_fixture() -> bool:
	var cells := _owned_land_cells()
	if not _require("X6-c fixture owns at least one land cell", cells.size() >= 1,
			str(cells)):
		return false
	var settlement_cell := int(cells[0])
	# A second owned land cell is not guaranteed by the starter fixture. The
	# selector is tag-driven, so the same cell can hold both source bands in
	# distinct override calls when the map only owns one land tile.
	var metropolis_cell := int(cells[1]) if cells.size() >= 2 else settlement_cell
	var cleared: Dictionary = _ext.clear_cell_tag_overrides_for_test()
	if not _require("X6-c clears prior tag overrides",
			bool(cleared.get("ok", false)), str(cleared)):
		return false
	# Pin the population bands instead of relying on starter-world population.
	# The same cell legitimately satisfies both settlement (>= 400) and
	# metropolis (>= 1200) at 800, so one owned land cell is enough.
	var population_metric := _effect_metric_id("cell.population")
	if not _require("X6-c resolves cell.population", population_metric >= 0,
			str(population_metric)):
		return false
	var population_override: Dictionary = _ext.set_effect_metric_override_for_test(
		population_metric, CITIES_POPULATION * Q16_ONE, true)
	if not _require("X6-c pins settlement and metropolis population",
			bool(population_override.get("ok", false)),
			str(population_override)):
		return false
	for pair in [[settlement_cell, "cell.settlement"],
			[metropolis_cell, "cell.metropolis"]]:
		var result: Dictionary = _ext.set_cell_tag_override_for_test(
			String(pair[1]), int(pair[0]), true)
		if not _require("X6-c sets %s on cell %d" % [
				str(pair[1]), int(pair[0])],
				bool(result.get("ok", false)), str(result)):
			return false
	if not _require("X6-c refreshes the selector fixture",
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return false
	return true


func _owned_land_cells() -> PackedInt32Array:
	var out := PackedInt32Array()
	var map = _host.get_current_map()
	for cell in range(WIDTH * HEIGHT):
		if int(_ext.get_country_cell_summary(cell).get(
				"country_handle", 0)) != _handle:
			continue
		if map != null and bool(map.is_water_arr[cell]):
			continue
		out.append(cell)
		if out.size() >= 2:
			break
	return out


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


func _slot_at(snapshot: Dictionary, dense: int) -> int:
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var slots: PackedInt32Array = snapshot.get("slot_indices", PackedInt32Array())
	var row := ids.find(dense)
	if row < 0 or row >= slots.size():
		return -1
	return int(slots[row])


func _slot_of(card: String) -> int:
	return _slot_at(_snapshot(), _dense_id(card))


func _slots() -> PackedInt32Array:
	var snapshot := _snapshot()
	var ids: PackedInt32Array = snapshot.get("idea_ids", PackedInt32Array())
	var locations: PackedInt32Array = snapshot.get(
		"locations", PackedInt32Array())
	var slots: PackedInt32Array = snapshot.get("slot_indices", PackedInt32Array())
	var rows: Array[Dictionary] = []
	for row in range(ids.size()):
		if row < locations.size() and int(locations[row]) == 1:
			rows.append({"id": int(ids[row]),
				"slot": int(slots[row]) if row < slots.size() else -1})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["slot"]) < int(b["slot"]))
	var out := PackedInt32Array()
	for row in rows:
		out.append(int(row["slot"]))
	return out


func _copier_report_rows() -> Array[int]:
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	var idea_ids: PackedInt64Array = report.get("idea_ids", PackedInt64Array())
	var hashes: PackedInt64Array = report.get(
		"program_hashes", PackedInt64Array())
	var copier := _dense_id(COPIER)
	var out: Array[int] = []
	for row in range(mini(idea_ids.size(), hashes.size())):
		if int(idea_ids[row]) == copier:
			out.append(int(hashes[row]))
	return out


func _report_targets(hashes: Array[int]) -> Array[int]:
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	var idea_ids: PackedInt64Array = report.get("idea_ids", PackedInt64Array())
	var program_hashes: PackedInt64Array = report.get(
		"program_hashes", PackedInt64Array())
	var targets: PackedInt64Array = report.get(
		"target_handles", PackedInt64Array())
	var copier := _dense_id(COPIER)
	var out: Array[int] = []
	for row in range(mini(mini(idea_ids.size(), program_hashes.size()),
			targets.size())):
		if int(idea_ids[row]) == copier and hashes.has(int(program_hashes[row])):
			out.append(int(targets[row]))
	return out


func _signature(card: String) -> int:
	return int(_ext.compute_idea_activation_signature_for_test(
		_handle, _dense_id(card)))


func _idea_report_hash(card: String) -> int:
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	var idea_ids: PackedInt64Array = report.get("idea_ids", PackedInt64Array())
	var hashes: PackedInt64Array = report.get(
		"program_hashes", PackedInt64Array())
	var dense := _dense_id(card)
	for row in range(mini(idea_ids.size(), hashes.size())):
		if int(idea_ids[row]) == dense:
			return int(hashes[row])
	return 0


func _wait_idea_report_hash(card: String) -> int:
	var deadline := Time.get_ticks_msec() + 16000
	var hash := _idea_report_hash(card)
	while hash == 0 and Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		hash = _idea_report_hash(card)
	return hash


func _effect_metric_id(metric_key: String) -> int:
	var catalog: Resource = load("res://data/effects/default_effect_catalog.tres")
	if catalog == null:
		return -1
	var compiled: Dictionary = catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return -1
	var keys: PackedStringArray = compiled.get(
		"metric_keys", PackedStringArray())
	return keys.find(metric_key)


func _has_technology(technology_id: String) -> bool:
	var ids: PackedStringArray = _ext.get_country_snapshot(_handle).get(
		"technology_ids", PackedStringArray())
	return ids.has(technology_id)


func _grant_technology(technology_id: String) -> bool:
	var facade = _generator.get_country_facade()
	if not _require("country facade available for %s" % technology_id,
			facade != null):
		return false
	var result: Dictionary = facade.grant_technology(
		_handle, StringName(technology_id), _tick + 1, _next_sequence)
	if not _require("%s: worker accepts grant" % technology_id,
			bool(result.get("ok", false)), str(result)):
		return false
	_next_sequence += 1
	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline:
		_tick = _drive_days(1)
		if _has_technology(technology_id):
			return true
	return _require("%s: becomes visible to Country" % technology_id,
		false, str(_ext.get_country_snapshot(_handle)))


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
