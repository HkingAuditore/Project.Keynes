extends SceneTree

## Mandate of Heaven / school-strength acceptance on the production worker path.
##
## The fixture changes only the existing hazard-free country metric by key. The
## observable is the frozen harmony factor in the country Modifier snapshot and
## the live Effect instance report: equip rewrites the selector, the factor scales
## another harmony card, unequip restores the original behavior, and PKSR/PKCN
## restore preserves the equipped card and its frozen factor.

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261024
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const METRIC_KEY := "country.hazard_free_cell_share_q16"
const MODIFIER_DOMAIN_COUNTRY := 1
const HARMONY_FACTOR_STAT := \
	"country.ideology.school_strength_factor.harmony"
const DEATH_FACTOR_STAT := "country.population.death_factor"

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectDomainCatalogScript = preload(
	"res://scripts/effect/effect_domain_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const WorkerWaitHelper = preload(
	"res://tests/ideology/ideology_worker_wait_helper.gd")
const POINT_GAIN_STAT := "country.ideology.point_gain_factor"

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _tick := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _hazard_metric := -1


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("=== ideology school strength worker: %d checks, %d failures ===" % [
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
	_hazard_metric = _metric_id(METRIC_KEY)
	if not _require("hazard-free metric resolves by key", _hazard_metric >= 0,
			str(_hazard_metric)):
		_teardown()
		return 1
	var ok := await _wait_ideology_ready()
	ok = ok and await _test_factor_and_scaling()
	ok = ok and await _test_low_hazard_relief()
	ok = ok and await _test_save_restore()
	if _ext.has_method("poll_ideology_receipts"):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 64)
		var reasons := PackedStringArray(receipts.get(
			"reasons", PackedStringArray()))
		if not reasons.is_empty():
			print("[school-strength-receipts] %s" % str(reasons))
	_teardown()
	return 0 if ok else 1


func _test_factor_and_scaling() -> bool:
	_expect("harmony starts at 1.00 without the card",
		_is_close(_harmony_factor(), 1.0), "%.5f" % _harmony_factor())
	if not _override_hazard(0.90):
		return false
	if not await _equip("mandate_of_heaven"):
		return false
	var factor := _wait_harmony_factor(1.10, 16)
	_expect("mandate_of_heaven L1 freezes harmony at 1.10 (got %.5f)"
			% factor, _is_close(factor, 1.10), "%.5f" % factor)
	_expect("mandate_of_heaven places its point-gain row",
		_is_close(_point_gain_factor(), 0.95, 0.001),
		"%.5f" % _point_gain_factor())
	var own_scale := _instance_scale("mandate_of_heaven")
	_expect("the factor-writing instance keeps scale 1.00 (got %.5f)"
			% own_scale, _is_close(own_scale, 1.0), "%.5f" % own_scale)
	if not await _equip("shell_midden"):
		return false
	var scaled := _wait_instance_scale("shell_midden", 1.10, 16)
	_expect("a second harmony card inherits the 1.10 school strength (got %.5f)"
			% scaled, _is_close(scaled, 1.10), "%.5f" % scaled)
	if not _override_hazard(0.40):
		return false
	var death := _wait_death_factor(0.95, 16)
	_expect("low hazard relief applies the L1 0.95 death factor (got %.5f)"
			% death, _is_close(death, 0.95), "%.5f" % death)
	if not await _unequip("shell_midden"):
		return false
	if not await _unequip("mandate_of_heaven"):
		return false
	var restored := _wait_harmony_factor(1.0, 16)
	var restored_death := _wait_death_factor(1.0, 16)
	_expect("unequip restores harmony to 1.00 (got %.5f)" % restored,
		_is_close(restored, 1.0), "%.5f" % restored)
	_expect("unequip restores the death factor to 1.00 (got %.5f)"
			% restored_death, _is_close(restored_death, 1.0),
		"%.5f" % restored_death)
	return true


func _wait_ideology_ready() -> bool:
	_drive_days(1)
	if not _require("Economy publishes its first committed opinion revision",
			await _wait_opinion_revision(),
			str(_ext.get_country_class_opinion_snapshot())):
		return false
	if not _require("the live opinion source publishes to the worker",
			bool(_ext.publish_ideology_worker_inputs().get("ok", false)),
			str(_ext.get_runtime_thread_report())):
		return false
	_ext.set_runtime_clock(true, WORKER_SPEED)
	_tick = _drive_days(1)
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
	return _require("the worker Ideology POD becomes ready", ready,
		str(_ext.get_runtime_thread_report().get(
			"ideology_pod_fallback_reason", "")))


func _test_low_hazard_relief() -> bool:
	if not _override_hazard(0.40):
		return false
	_expect("an absent card leaves death factor at 1.00",
		_is_close(_death_factor(), 1.0), "%.5f" % _death_factor())
	return true


func _test_save_restore() -> bool:
	if not _override_hazard(0.90):
		return false
	if not await _equip("mandate_of_heaven"):
		return false
	var before := _wait_harmony_factor(1.10, 16)
	var saved := _request_save(2026102402)
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	var pkcn: PackedByteArray = saved.get("country_pkcn", PackedByteArray())
	if not _require("PKSR captures the equipped school-strength card",
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
	if not _override_hazard(0.90):
		return false
	var after := _wait_harmony_factor(before, 16)
	_expect("restored PKSR keeps the frozen harmony factor (got %.5f)"
			% after, _is_close(after, before), "restored=%.5f saved=%.5f" % [
				after, before])
	var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	var dense := _dense_id("mandate_of_heaven")
	_expect("restored ideology still owns mandate_of_heaven",
		snapshot.get("known_ids", PackedInt32Array()).has(dense),
		str(snapshot.get("known_ids", PackedInt32Array())))
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
	config.country.name = "C0 School Strength"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("school-strength session configures",
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
		printerr("[school-strength-equip] %s opcodes=%s reasons=%s snapshot=%s"
			% [card, str(receipts.get("opcodes", PackedInt32Array())),
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
		printerr("[school-strength-unequip] %s opcodes=%s statuses=%s reasons=%s "
			% [card, str(receipts.get("opcodes", PackedInt32Array())),
				str(receipts.get("statuses", PackedInt32Array())),
				str(receipts.get("reasons", PackedStringArray()))])
	return _require("%s: unequip releases the slot (slots=%d)" % [card, slots],
		slots < started_slots, str(slots))


func _metric_id(key: String) -> int:
	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		return -1
	return PackedStringArray(domain.metric_keys).find(key)


func _override_hazard(value: float) -> bool:
	var applied: Dictionary = _ext.set_effect_metric_override_for_test(
		_hazard_metric, int(round(value * Q16_ONE)), true)
	if not _require("hazard-free override %.2f applies" % value,
			bool(applied.get("ok", false)), str(applied)):
		return false
	if not _require("effect input digest refreshes after hazard override",
			bool(_ext.refresh_effect_input_digest_for_test().get("ok", false))):
		return false
	var probe: Dictionary = _ext.sample_effect_metric_probe(_hazard_metric,
		_owned_anchor(), _handle)
	_require("hazard-free probe returns the override",
		bool(probe.get("ok", false))
			and int(probe.get("value", -1)) == int(round(value * Q16_ONE)),
		str(probe))
	return true


func _harmony_factor() -> float:
	return float(_ext.evaluate_modifier_stat(MODIFIER_DOMAIN_COUNTRY, _handle, 0,
		HARMONY_FACTOR_STAT, 1.0))


func _death_factor() -> float:
	return float(_ext.evaluate_modifier_stat(MODIFIER_DOMAIN_COUNTRY, _handle, 0,
		DEATH_FACTOR_STAT, 1.0))


func _point_gain_factor() -> float:
	return float(_ext.evaluate_modifier_stat(MODIFIER_DOMAIN_COUNTRY, _handle, 0,
		POINT_GAIN_STAT, 1.0))


func _wait_harmony_factor(expected: float, days: int) -> float:
	var value := _harmony_factor()
	for _day in range(days):
		if _is_close(value, expected):
			return value
		_tick = _drive_days(1)
		value = _harmony_factor()
	return value


func _wait_death_factor(expected: float, days: int) -> float:
	var value := _death_factor()
	for _day in range(days):
		if _is_close(value, expected):
			return value
		_tick = _drive_days(1)
		value = _death_factor()
	return value


func _instance_scale(card: String) -> float:
	var dense := _dense_id(card)
	var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
	var idea_ids := PackedInt64Array(report.get("idea_ids", PackedInt64Array()))
	var scales := PackedInt32Array(report.get("magnitude_scales",
		PackedInt32Array()))
	var fallback := -1.0
	for index in range(mini(idea_ids.size(), scales.size())):
		if int(idea_ids[index]) != dense:
			continue
		var value := float(scales[index]) / Q16_ONE
		fallback = value
		if value > 1.0:
			return value
	return fallback


func _wait_instance_scale(card: String, expected: float, days: int) -> float:
	var value := _instance_scale(card)
	for _day in range(days):
		if _is_close(value, expected):
			return value
		_tick = _drive_days(1)
		value = _instance_scale(card)
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


func _wait_opinion_revision() -> bool:
	return await WorkerWaitHelper.wait_until(
		func() -> bool:
			if String(_ext.get_runtime_thread_report().get(
					"fault_code", "")) != "":
				return false
			var opinion: Dictionary = _ext.get_country_class_opinion_snapshot()
			if int(opinion.get("revision", 0)) > 0:
				return true
			var report: Dictionary = _ext.get_runtime_thread_report()
			if int(report.get("economy_input_requested_day", -1)) >= 0:
				_ext.capture_economy_day_inputs(-1)
			return false,
		120000,
		func() -> void:
			if _ext.has_method("service_country_worker_peer_adapter"):
				_ext.service_country_worker_peer_adapter(64, true))


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
