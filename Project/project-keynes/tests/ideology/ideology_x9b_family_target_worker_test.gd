extends SceneTree

## X9-b acceptance for family-targeted ideology writes.
##
## A production worker world must resolve `family_office`'s L3 packet against
## the Economy-owned branch/ownership tables, write the +6% output row on the
## stable family handle, and remove it on unequip. The fixture also proves the
## family digest is reused on unchanged committed days and changes only when the
## branch/ownership input changes.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const MODIFIER_DOMAIN_ECONOMY := 2
const MODIFIER_SCOPE_ENTITY := 2
const OUTPUT_STAT := "economy.city.output_factor"
const CARD := "family_office"
const L2_THRESHOLD_Q16 := 524288
const L3_THRESHOLD_Q16 := 1572864
const WorkerWaitHelper = preload(
	"res://tests/ideology/ideology_worker_wait_helper.gd")
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
var _family_handle := 0
var _family_cell := -1
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _tick := 0


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology x9b family target worker: %d checks, %d failures ===" % [
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
	if not _find_family_target():
		_teardown()
		return 1
	if not await _test_family_target_apply_and_reuse():
		_teardown()
		return 1
	if not await _test_family_target_unequip():
		_teardown()
		return 1
	_teardown()
	return 0


func _test_family_target_apply_and_reuse() -> bool:
	var selected: Dictionary = _ext.get_family_cell_snapshot(
		_family_cell, 0, 64)
	if not _require("the fixture resolves a family-owned cell",
			bool(selected.get("ok", false))
				and int(selected.get("total", 0)) > 0,
			str(selected)):
		return false
	var override: Dictionary = _ext.set_family_target_min_branches_override_for_test(1)
	if not _require("X9-b test hook relaxes the authored branch floor",
			bool(override.get("ok", false)), str(override)):
		return false
	_tick = _drive_days(1)
	var before_revision := int(_ext.get_effect_input_revisions().get(
		"family", 0))
	if not _install_family_office_draw_gates():
		return false
	if not _equip_card():
		return false
	var equipped := await _wait_family_output(1.06)
	_expect("family_office L3 adds +6%% output on the family-owned target "
			+ "(got %.5f)" % equipped,
		_is_close(equipped, 1.06), "%.5f" % equipped)
	var target_stat := _family_stat()
	_expect("the family target carries an ECONOMY ENTITY modifier row",
		_is_close(target_stat, 1.06), "%.5f" % target_stat)
	var after_apply := int(_ext.get_effect_input_revisions().get(
		"family", 0))
	_expect("applying the family target advances the family revision",
		after_apply > before_revision, "%d -> %d" % [
			before_revision, after_apply])
	var idle_before := int(_ext.get_effect_input_revisions().get(
		"family", 0))
	for _index in range(5):
		_tick = _drive_days(1)
	var idle_after := int(_ext.get_effect_input_revisions().get(
		"family", 0))
	_expect("five unchanged committed days reuse the family digest",
		idle_after == idle_before, "%d -> %d" % [idle_before, idle_after])
	var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	_expect("family_office occupies an ideology slot",
		int(snapshot.get("ideology_slots_used", -1)) >= 1, str(snapshot))
	return true


func _test_family_target_unequip() -> bool:
	var override_cleared: Dictionary = _ext.set_family_target_min_branches_override_for_test(0)
	if not _require("X9-b test hook restores the authored branch floor",
			bool(override_cleared.get("ok", false)), str(override_cleared)):
		return false
	if not _unequip_card():
		return false
	var restored := await _wait_family_output(1.0)
	_expect("unequipping family_office restores the family-owned output target",
		_is_close(restored, 1.0), "%.5f" % restored)
	return true


func _install_family_office_draw_gates() -> bool:
	var gates: Dictionary = IdeologyDrawGateHelper.grant_draw_gates(
		_host, CARD, _handle, _tick, _next_sequence)
	if not _require("family_office: worker grants its draw gates",
			bool(gates.get("ok", false)), str(gates)):
		return false
	_next_sequence = maxi(_next_sequence, int(gates.get(
		"next_sequence", _next_sequence)))
	_tick = _drive_days(1)
	return true


func _equip_card() -> bool:
	var dense := _dense_id(CARD)
	if dense < 0:
		return false
	var discovered: Dictionary = _submit([{
		"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("family_office: worker accepts discover",
			bool(discovered.get("ok", false)), str(discovered)):
		return false
	_tick = _drive_days(2)
	var equipped: Dictionary = _submit([{
		"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("family_office: worker accepts equip",
			bool(equipped.get("ok", false)), str(equipped)):
		return false
	_tick = _drive_days(3)
	var raised := _submit([{
		"op": 8, "day": _tick, "handle": _handle, "idea": dense,
		"value": L2_THRESHOLD_Q16,
	}])
	if not _require("family_office: worker accepts L1->L2 promotion",
			bool(raised.get("ok", false)), str(raised)):
		return false
	_tick = _drive_days(2)
	var level_three := _submit([{
		"op": 8, "day": _tick, "handle": _handle, "idea": dense,
		"value": L3_THRESHOLD_Q16 - L2_THRESHOLD_Q16,
	}])
	if not _require("family_office: worker accepts L2->L3 promotion",
			bool(level_three.get("ok", false)), str(level_three)):
		return false
	_tick = _drive_days(6)
	return true


func _unequip_card() -> bool:
	var dense := _dense_id(CARD)
	if dense < 0:
		return false
	var result: Dictionary = _submit([{
		"op": 6, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("family_office: worker accepts unequip",
			bool(result.get("ok", false)), str(result)):
		return false
	_tick = _drive_days(6)
	var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	if int(snapshot.get("ideology_slots_used", -1)) == 0:
		_expect("unequipping family_office releases its slot", true, "")
	else:
		_expect("unequipping family_office releases its slot", false, str(snapshot))
	return true


func _find_family_target() -> bool:
	var best_cell := -1
	var best_handle := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = _ext.get_country_cell_summary(cell)
		if int(summary.get("country_handle", 0)) != _handle:
			continue
		var page: Dictionary = _ext.get_family_cell_snapshot(cell, 0, 64)
		if not bool(page.get("ok", false)):
			continue
		var handles: PackedInt64Array = page.get(
			"family_handles", PackedInt64Array())
		var owned: PackedInt64Array = page.get(
			"owned_buildings", PackedInt64Array())
		for index in range(mini(handles.size(), owned.size())):
			if int(owned[index]) <= 0:
				continue
			best_cell = cell
			best_handle = int(handles[index])
			break
		if best_handle != 0:
			break
	if not _require("the worker world exposes a family-owned building",
			best_handle != 0 and best_cell >= 0,
			"family=%d cell=%d snapshots=%s" % [
				best_handle, best_cell, str(_ext.get_family_cell_snapshot(
					0, 0, 64))]):
		return false
	_family_handle = best_handle
	_family_cell = best_cell
	return true


func _family_stat() -> float:
	return float(_ext.evaluate_modifier_stat(
		MODIFIER_DOMAIN_ECONOMY, _family_handle, 0, OUTPUT_STAT, 1.0))


func _wait_family_output(expected: float) -> float:
	var value := _family_stat()
	await WorkerWaitHelper.wait_for(
		func() -> bool:
			value = _family_stat()
			return _is_close(value, expected),
		8, 120000,
		func() -> void: _tick = _drive_days(1))
	return _family_stat()


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
	config.country.name = "C0 X9b family target"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("the X9-b session configures",
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
	var anchor := int(ext.query_country_anchor_cell(country_slot))
	if not _require("the worker resolves the country anchor", anchor >= 0,
			str(anchor)):
		return {}
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {
		"host": host, "clock": clock, "ext": ext,
		"generator": generator, "handle": handle,
		"country_slot": country_slot, "anchor": anchor, "tick": _tick,
	}


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
	return PackedStringArray(native.get("ideology_ids", PackedStringArray())).find(
		"idea.%s" % card)


func _submit(rows: Array) -> Dictionary:
	var opcodes := PackedInt32Array()
	var days := PackedInt64Array()
	var producers := PackedInt32Array()
	var sequences := PackedInt64Array()
	var handles := PackedInt64Array()
	var ideas := PackedInt32Array()
	var values := PackedInt64Array()
	var priorities := PackedInt32Array()
	var generations := PackedInt64Array()
	var choices := PackedInt32Array()
	var gates := PackedInt32Array()
	for row_value in rows:
		var row: Dictionary = row_value
		opcodes.append(int(row.get("op", 0)))
		days.append(int(row.get("day", _tick)))
		producers.append(1)
		sequences.append(_next_sequence)
		_next_sequence += 1
		handles.append(int(row.get("handle", _handle)))
		ideas.append(int(row.get("idea", -1)))
		values.append(int(row.get("value", 0)))
		priorities.append(0)
		generations.append(0)
		choices.append(-1)
		gates.append(-1)
	return _ext.submit_ideology_commands({
		"opcodes": opcodes, "effective_days": days, "producer_ids": producers,
		"sequences": sequences, "country_handles": handles,
		"ideology_ids": ideas, "values_q16": values,
		"source_priorities": priorities, "offer_generations": generations,
		"choice_indices": choices, "gate_ids": gates,
	})


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
	WorkerWaitHelper.wait_until(
		func() -> bool:
			var report: Dictionary = _ext.get_runtime_thread_report()
			return int(report.get("ideology_pod_committed_day", -1)) > before \
				or String(report.get("simulation_host_state", "")) in [
					"STOPPED", "FAULTED"],
		timeout_ms,
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


func _teardown() -> void:
	if _ext != null and _ext.has_method("set_family_target_min_branches_override_for_test"):
		_ext.set_family_target_min_branches_override_for_test(0)
	if _ext != null and _ext.has_method("request_runtime_stop"):
		_ext.request_runtime_stop()


func _is_close(value: float, expected: float, tolerance: float = 0.0005) -> bool:
	return is_finite(value) and absf(value - expected) <= tolerance


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
