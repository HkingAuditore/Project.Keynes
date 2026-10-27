extends SceneTree

## Worker acceptance for managed Effect lifecycle (doc 14, section 4).
##
## This is the production-shaped counterpart to the POD self-test: a real
## WorldRuntimeHost, 0xFFF worker authority, village_compact equipped through
## submit_ideology_commands, and the per-cell Modifier row observed through the
## Effect/Modifier worker chain.
##
## The condition input is forced on one owned agriculture cell. The result under
## test is always evaluate_modifier_stat(domain 2, cell, ...), because a card can
## apply a row without that row ever reaching the cell the program selected.
##
## Run:
##   godot --headless --path Project/project-keynes \
##     --script res://tests/ideology/ideology_worker_managed_lifecycle_test.gd

const WIDTH := 16
const HEIGHT := 12
const SEED := 20261023
const WORKER_SPEED := 10.0
const Q16_ONE := 65536
const METRIC_NEIGHBOR_POPULATION := 54
const NEIGHBOR_THRESHOLD := 800
const AGRICULTURE_STAT := "economy.city.building.agriculture_output_factor"
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const DrawGateHelper = preload("res://tests/ideology/ideology_draw_gate_helper.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")

var _host: WorldRuntimeHost
var _clock: WorldClock
var _ext: Object
var _handle := 0
var _tick := 0
var _checks := 0
var _failures := 0
var _next_sequence := 1
var _effect_bytes_series: PackedInt32Array = PackedInt32Array()


func _init() -> void:
	call_deferred("_run_and_finish")


func _run_and_finish() -> void:
	var code := await _run()
	print("[lifecycle] effect_bytes=%s" % str(_effect_bytes_series))
	print("=== ideology worker managed lifecycle: %d checks, %d failures ===" % [
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
	_handle = int(fixture["handle"])
	_tick = int(fixture["tick"])
	if not await _exercise_lifecycle():
		_teardown()
		return 1
	_teardown()
	return 0


func _wait_ideology_commit() -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		var report: Dictionary = _ext.get_runtime_thread_report()
		if int(report.get("ideology_pod_committed_day", -1)) >= 1:
			return true
		_tick = _drive_days(1)
	return _require("worker has committed an ideology day",
		int(_ext.get_runtime_thread_report().get(
			"ideology_pod_committed_day", -1)) >= 1,
		str(_ext.get_runtime_thread_report()))


func _prepare_condition_input() -> bool:
	var snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	var report: Dictionary = _ext.get_runtime_thread_report()
	var pod_ready := bool(report.get("ideology_pod_ready", false)) and \
		bool(report.get("effect_pod_ready", false)) and \
		bool(report.get("modifier_pod_ready", false))
	_require("worker Effect/Ideology PODs are ready", pod_ready, str(report))
	_require("ideology snapshot resolves the player country",
		bool(snapshot.get("ok", false)), str(snapshot))
	var digest_ok := _set_metric(NEIGHBOR_THRESHOLD + 1)
	_require("condition metric override + digest refresh applies",
		digest_ok, str(snapshot))
	return pod_ready and digest_ok


func _exercise_lifecycle() -> bool:
	if not _wait_ideology_commit():
		return false
	if not _prepare_condition_input():
		return false
	var dense := _dense_id("village_compact")
	if not _require("village_compact is in the compiled catalog", dense >= 0):
		return false

	# DISCOVER and EQUIP are separate plans: the pod requires known_bits, which
	# only the first plan commits.
	_grant_draw_gates("village_compact", _tick)
	var discover: Dictionary = _submit([
		{"op": 1, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("worker accepts village_compact DISCOVER",
			bool(discover.get("ok", false)), str(discover)):
		return false
	_tick = _drive_days(2)
	_grant_draw_gates("village_compact", _tick)
	var equip: Dictionary = _submit([
		{"op": 5, "day": _tick, "handle": _handle, "idea": dense}])
	if not _require("worker accepts village_compact EQUIP",
			bool(equip.get("ok", false)), str(equip)):
		return false
	_tick = _drive_days(3)

	var instance_report := PackedInt64Array()
	var instance_deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < instance_deadline:
		var report: Dictionary = _ext.get_ideology_effect_instance_report(_handle)
		instance_report = report.get("instance_ids", PackedInt64Array())
		if not instance_report.is_empty():
			break
		_tick = _drive_days(1)
	if not _require("managed card publishes an Effect instance report",
			not instance_report.is_empty(), str(instance_report)):
		var receipts: Dictionary = _ext.poll_ideology_receipts(0, 32)
		printerr("[lifecycle] receipts=%s snapshot=%s" % [
			str(receipts), str(_ext.get_ideology_snapshot(_handle))])
		return false

	var instance_ids: PackedInt64Array = instance_report
	var target_handles := PackedInt64Array()
	var target_domains := PackedInt32Array()
	var instance_report_data: Dictionary = _ext.get_ideology_effect_instance_report(
		_handle)
	target_handles = instance_report_data.get(
		"target_handles", PackedInt64Array())
	target_domains = instance_report_data.get(
		"target_domains", PackedInt32Array())
	var cell := _owned_agriculture_cell(instance_ids, target_handles,
		target_domains)
	if not _require("an owned agriculture cell exists for the card", cell >= 0):
		return false
	var installed_snapshot: Dictionary = _ext.get_ideology_snapshot(_handle)
	var installed_report: Dictionary = _ext.get_ideology_effect_instance_report(
		_handle)
	_require("village_compact occupies an ideology slot",
		int(installed_snapshot.get("ideology_slots_used", 0)) >= 1,
		str(installed_snapshot.get("ideology_slots_used", -1)))
	_require("village_compact publishes a non-empty instance report",
		int(installed_report.get("count", 0)) >= 1,
		str(installed_report.get("count", -1)))
	_require("village_compact instance targets an owned cell",
		cell >= 0, str(cell))
	var above := NEIGHBOR_THRESHOLD + 1
	var below := NEIGHBOR_THRESHOLD - 1
	if not _set_metric(above):
		return false
	var above_revision := _metric_revision()
	_require("condition metric above threshold published a revision",
		above_revision >= 1, str(above_revision))
	var sampled_above: Dictionary = _ext.sample_effect_metric_probe(
		METRIC_NEIGHBOR_POPULATION, cell, _handle)
	_require("condition metric override reaches the worker input",
		bool(sampled_above.get("ok", false)) and
		int(sampled_above.get("value", -1)) == above * Q16_ONE,
		str(sampled_above))
	var applied := _wait_for_factor(cell, 1.08, 12)
	_expect("above threshold applies village_compact L1 (+8%%) (got %.5f)" % applied,
		_is_close(applied, 1.08, 0.0005), "%.5f" % applied)

	if not _set_metric(below):
		return false
	var below_delivered := _wait_for_metric_value(cell, below)
	_require("below-threshold metric reaches the worker",
		int(below_delivered) == below * Q16_ONE, str(below_delivered))
	# Start the retirement budget at worker delivery, not at the producer
	# write. The metric queue can span several committed days under load.
	var retired := _wait_for_retirement(cell, 3)
	_expect("below threshold retires the cell row within 3 days (got %.5f)" % retired,
		_is_close(retired, 1.00, 0.0005), "%.5f" % retired)

	# Save while the row is retired. The restored main-thread mirror must carry
	# effect_applied=0 so it cannot resurrect a row that the worker removed.
	var saved: Dictionary = _request_save(2026102304)
	var bundle: PackedByteArray = saved.get("bytes", PackedByteArray())
	if not _require("PKSR captures the retired lifecycle state",
			bool(saved.get("ready", false)) and not bundle.is_empty(),
			str(saved)):
		return false

	if not _set_metric(above):
		return false
	var reapplied := _wait_for_factor(cell, 1.08, 12)
	_expect("above threshold reapplies village_compact L1 (+8%%) (got %.5f)" % reapplied,
		_is_close(reapplied, 1.08, 0.0005), "%.5f" % reapplied)

	# Pin the card at L3 before the idle window. L3 has no further understanding
	# growth or level transition, so every following day with the metric fixed
	# must be silent.
	var raise: Dictionary = _submit([
		{"op": 8, "day": _tick, "handle": _handle, "idea": dense,
		 "value": 24 * Q16_ONE}])
	if not _require("worker accepts village_compact understanding bump",
			bool(raise.get("ok", false)), str(raise)):
		return false
	var at_l3 := _wait_for_factor(cell, 1.14, 16)
	_expect("village_compact reaches L3 (+14%%) before idle sampling (got %.5f)"
		% at_l3, _is_close(at_l3, 1.14, 0.0005), "%.5f" % at_l3)

	# Fixed above-threshold input: the first day may reconcile the new revision,
	# all following days must be silent. Measure only the true idle window after
	# the reapply ACK and its compacted transaction have settled.
	_tick = _drive_days(2)
	var idle_start_transactions := _effect_transaction_count()
	var initial_sample := _effect_bytes()
	_effect_bytes_series.append(initial_sample)
	var idle_start := _effect_bytes_series[_effect_bytes_series.size() - 1]
	var steady_bytes := idle_start
	# A save-poll sample can be missing during the first idle day. That is not a
	# plateau transition; the first valid sample establishes the comparison point.
	var steady_known := steady_bytes >= 0
	var idle_previous_transactions := idle_start_transactions
	var previous_unmanaged_in_flight := false
	for day in range(29):
		_tick = _drive_days(1)
		var report: Dictionary = _ext.get_runtime_thread_report()
		var intent_count := int(report.get("effect_pod_intent_count", -1))
		var managed_intents := int(report.get(
			"effect_pod_managed_intent_count", -1))
		var program_ids: PackedInt32Array = report.get(
			"effect_pod_intent_program_ids", PackedInt32Array())
		var transactions := _effect_transaction_count()
		# Unmanaged family/technology programs may legitimately fire on cadence.
		# A committed transaction becomes ACKED later in the same day; compaction
		# happens on the next commit. The managed lifecycle contract is that an
		# unchanged, applied ideology card emits nothing, and every unmanaged
		# transaction is gone again by the following committed day.
		_expect("idle day %d emits no managed Effect intent (got %d)" % [
				day, managed_intents], managed_intents == 0,
			"effect_intents=%d program_ids=%s tx=%d" % [
				intent_count, str(program_ids), transactions])
		var unmanaged_in_flight := intent_count > 0 and managed_intents == 0
		_expect("idle day %d keeps its transaction log compacted" % day,
			transactions == idle_start_transactions if not unmanaged_in_flight
				else transactions <= idle_start_transactions + 1,
			"%d -> %d" % [idle_previous_transactions, transactions])
		idle_previous_transactions = transactions
		if day == 0 or intent_count != 0 or \
				transactions != idle_start_transactions:
			print("[lifecycle-idle] effect_intents=%d managed=%d unmanaged=%d program_ids=%s tx=%d" % [
				intent_count, managed_intents,
				int(report.get("effect_pod_unmanaged_intent_count", -1)),
				str(program_ids), transactions])
			print("[lifecycle-idle-programs] %s" % str(
				_intent_program_keys(program_ids)))
		# EFP1 may carry one live, not-yet-compacted unmanaged transaction
		# on its firing day. The next commit compacts it. An unmanaged
		# firing may also add one durable unmanaged instance, so that first
		# post-fire day establishes a new plateau; every later idle day must
		# return to the current plateau. A missing save-poll sample is ignored;
		# it is not a plateau transition.
		var bytes := _effect_bytes()
		_effect_bytes_series.append(bytes)
		if bytes >= 0:
			if not steady_known:
				steady_bytes = bytes
				steady_known = true
			elif not unmanaged_in_flight:
				if previous_unmanaged_in_flight:
					steady_bytes = bytes
				else:
					_expect("idle day %d returns EFP1 to its steady size" % day,
						bytes == steady_bytes, str(_effect_bytes_series.slice(-4)))
		# Missing save samples are hang-guard evidence only. They must not
		# alter the "previous day was unmanaged" transition state.
		previous_unmanaged_in_flight = unmanaged_in_flight
	# Let the final committed unmanaged transaction compact before asserting the
	# idle plateau. A save is a worker barrier, so this advances committed days,
	# never wall-clock time.
	_tick = _drive_days(1)
	var final_sample := -1
	var final_series: PackedInt32Array = _effect_bytes_series.duplicate()
	final_series.append(_effect_bytes())
	for sample in final_series:
		if sample >= 0:
			final_sample = sample
	_effect_bytes_series.append(final_sample)
	var idle_end := final_sample
	_expect("PKSR EFP1 ends on its latest compacted plateau (%d -> %d)" % [
			idle_start, idle_end], idle_end >= 0 and idle_end == steady_bytes,
		str(final_series))

	# Back to the retired state, then restore the bundle captured there.
	if not _set_metric(below):
		return false
	var below_delivered_again := _wait_for_metric_value(cell, below)
	_require("second below-threshold metric reaches the worker",
		int(below_delivered_again) == below * Q16_ONE, str(below_delivered_again))
	var retired_again := _wait_for_retirement(cell, 3)
	_expect("below threshold retires again before save (got %.5f)" % retired_again,
		_is_close(retired_again, 1.00, 0.0005), "%.5f" % retired_again)
	var save_second: Dictionary = _request_save(2026102305)
	bundle = save_second.get("bytes", PackedByteArray())
	if not _require("PKSR captures the second retired state",
			bool(save_second.get("ready", false)) and not bundle.is_empty(),
			str(save_second)):
		return false

	_ext.request_runtime_stop()
	_wait_stopped()
	var restored: Dictionary = _ext.restore_runtime_bundle(bundle)
	if not _require("PKSR bundle restores", bool(restored.get("restored", false)),
			str(restored)):
		return false
	var country_restore: Dictionary = _ext.restore_country_runtime_checkpoint(
		save_second.get("country_pkcn", PackedByteArray()))
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
	if not _set_metric(below):
		return false
	_tick = _drive_days(3)
	var after_restore := _factor(cell)
	_expect("restored retired card stays at 1.00 after 3 days (got %.5f)" % after_restore,
		_is_close(after_restore, 1.00, 0.0005), "%.5f" % after_restore)
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
	config.country.name = "C0 Lifecycle"
	config.country.foreign_count = 1
	config.base.map_width = WIDTH
	config.base.map_height = HEIGHT
	config.base.initial_seed = SEED
	config.apply_land_layout("two")
	var session: Dictionary = host.configure_session({
		"kind": "new_game", "config": config.to_dictionary()})
	if not _require("managed lifecycle session configures",
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
	_wait_worker_paused(ext)
	var handle := 0
	var country_slot := 0
	for cell in range(WIDTH * HEIGHT):
		var summary: Dictionary = ext.get_country_cell_summary(cell)
		handle = int(summary.get("country_handle", 0))
		if handle != 0:
			country_slot = int(summary.get("country_slot", 0))
			break
	if not _require("worker path resolves the player country", handle != 0):
		return {}
	# Generation already committed a day, so seed the driver calendar from the
	# committed economy day rather than re-entering day 1.
	_tick = _world_day(ext)
	_tick = _drive_days(3)
	return {"host": host, "clock": clock, "ext": ext, "handle": handle,
		"country_slot": country_slot, "tick": _tick}


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


func _owned_agriculture_cell(instance_ids: PackedInt64Array,
		target_handles: PackedInt64Array, target_domains: PackedInt32Array) -> int:
	# Prefer the cell the activated program actually selected. `target_handles`
	# from the ideology report is authoritative for that program; scanning all
	# owned cells can pick a different agriculture cell and silently measure a
	# row the program never targeted.
	for index in range(mini(instance_ids.size(), target_handles.size())):
		if index >= target_domains.size() or int(target_domains[index]) != 2:
			continue
		var target := int(target_handles[index])
		if target < 0 or target >= WIDTH * HEIGHT:
			continue
		var target_summary: Dictionary = _ext.get_country_cell_summary(target)
		if int(target_summary.get("country_handle", 0)) == _handle:
			return target
	return -1


func _set_metric(value: int) -> bool:
	var override: Dictionary = _ext.set_effect_metric_override_for_test(
		METRIC_NEIGHBOR_POPULATION, value * Q16_ONE, true)
	if not _require("metric 54 override=%d applies" % value,
			bool(override.get("ok", false)), str(override)):
		return false
	return _require("metric 54 digest refreshes at %d" % value,
		bool(_ext.refresh_effect_input_digest_for_test().get("ok", false)))


func _intent_program_keys(program_ids: PackedInt32Array) -> Array:
	var catalog: Resource = EffectDomainCatalogScript.build()
	if catalog == null:
		return []
	var compiled: Dictionary = catalog.compile_native_catalog()
	if not bool(compiled.get("ok", false)):
		return []
	var keys: PackedStringArray = compiled.get("effect_keys", PackedStringArray())
	var expressible: PackedByteArray = compiled.get("pod_expressible",
		PackedByteArray())
	var filtered := PackedStringArray()
	for index in range(keys.size()):
		if index < expressible.size() and int(expressible[index]) == 0:
			continue
		filtered.append(keys[index])
	var out := []
	for program_id in program_ids:
		if program_id < 0 or program_id >= filtered.size():
			out.append("%d:?" % program_id)
			continue
		var key := filtered[program_id]
		out.append("%d:%s(managed=%s)" % [program_id, key,
			str(_ext.effect_program_is_managed(key))])
	return out


func _wait_for_factor(cell: int, expected: float, days: int) -> float:
	var value := _factor(cell)
	for _day in range(days):
		_tick = _drive_days(1)
		value = _factor(cell)
		if _is_close(value, expected, 0.0005):
			return value
	return value


func _wait_for_retirement(cell: int, days: int) -> float:
	var value := _factor(cell)
	# The metric probe is the worker's delivered value, but Effect may still be
	# evaluating its previous committed day. Anchor the 3-day budget to an
	# Effect snapshot transition, not to the producer's wall clock or to the
	# legacy main-thread EffectRuntime report.
	var generation := _effect_snapshot_generation()
	var budget := 0
	for _attempt in range(days + 1):
		value = _factor(cell)
		if _is_close(value, 1.00, 0.0005):
			return value
		if budget >= days:
			break
		_tick = _drive_days(1)
		var next_generation := _effect_snapshot_generation()
		if next_generation > generation:
			generation = next_generation
			budget += 1
	return _factor(cell)


func _wait_for_metric_value(cell: int, expected: int) -> int:
	# Worker metrics advance on their own committed input revision. The probe
	# can already show the producer value while Effect still evaluates the prior
	# revision, so wait for a worker commit after the producer revision changed
	# before starting the retirement day budget.
	var producer_revision := _metric_revision()
	for _day in range(13):
		var sample: Dictionary = _ext.sample_effect_metric_probe(
			METRIC_NEIGHBOR_POPULATION, cell, _handle)
		var value := int(sample.get("value", -1)) \
			if bool(sample.get("ok", false)) else -1
		if value == expected * Q16_ONE and _metric_revision() \
				>= producer_revision:
			# The probe is the worker's delivered value. Drive one more committed
			# boundary so Effect evaluates it before the retirement budget starts.
			_tick = _drive_days(1)
			return value
		if _day < 12:
			_tick = _drive_days(1)
	return -1


func _factor(cell: int) -> float:
	return float(_ext.evaluate_modifier_stat(
		2, 0, cell, AGRICULTURE_STAT, 1.0))


func _effect_bytes() -> int:
	var request_id := 300000 + _tick * 17 + _next_sequence
	_next_sequence += 1
	var saved: Dictionary = _request_save(request_id)
	var bytes := int(saved.get("effect_bytes", -1))
	if bool(saved.get("ready", false)) and bytes >= 0:
		return bytes
	return -1


func _request_save(request_id: int) -> Dictionary:
	var request: Dictionary = _ext.request_runtime_save(request_id)
	var accepted := String(request.get("code", "")) == "ok" \
		and bool(request.get("pending", false))
	var deadline := Time.get_ticks_msec() + 120000
	for _iteration in range(2000):
		if accepted:
			break
		if Time.get_ticks_msec() >= deadline:
			break
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		_ext.poll_runtime_save(request_id)
		request = _ext.request_runtime_save(request_id)
		accepted = String(request.get("code", "")) == "ok" \
			and bool(request.get("pending", false))
		if not accepted and String(request.get("code", "")) \
				!= "save_request_busy":
			return request
		OS.delay_msec(2)
	if not accepted:
		return {"pending": false, "ready": false, "code": "save_request_timeout",
			"request_id": request_id}
	# The worker barrier can take several committed days under load. A measured
	# EFP1 plateau must not advance the world just to obtain a save sample.
	deadline = Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < deadline:
		if _ext.has_method("service_country_worker_peer_adapter"):
			_ext.service_country_worker_peer_adapter(64, true)
		var saved: Dictionary = _ext.poll_runtime_save(request_id)
		if bool(saved.get("ready", false)):
			return saved
		# Bundle and Country checkpoint can land on adjacent committed days.
		# Retry the failed request at the next committed boundary instead of
		# treating the transient mismatch as a terminal save error.
		if String(saved.get("reason", "")).begins_with(
				"save_country_checkpoint_day_mismatch:"):
			_tick = _drive_days(1)
			request_id += 1000000
			request = _ext.request_runtime_save(request_id)
			accepted = String(request.get("code", "")) == "ok" \
				and bool(request.get("pending", false))
			if not accepted and String(request.get("code", "")) \
					== "save_request_busy":
				continue
			if not accepted:
				return request
			continue
		if not bool(saved.get("pending", true)) \
				and String(saved.get("code", "")) != "save_pending":
			return saved
		OS.delay_msec(2)
	return {"pending": true, "ready": false, "code": "save_poll_timeout",
		"request_id": request_id,
		"report": _ext.get_runtime_thread_report()}


func _metric_revision() -> int:
	var metrics: PackedInt64Array = _ext.get_effect_input_revisions().get(
		"metrics", PackedInt64Array())
	return int(metrics[METRIC_NEIGHBOR_POPULATION]) \
		if METRIC_NEIGHBOR_POPULATION < metrics.size() else -1


func _effect_transaction_count() -> int:
	var report: Dictionary = _ext.get_runtime_thread_report()
	return int(report.get("effect_pod_transaction_count", -1))


func _effect_snapshot_generation() -> int:
	return int(_ext.get_runtime_thread_report().get(
		"effect_pod_snapshot_generation", 0))


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
		"sequences": sequences, "country_handles": handles, "ideology_ids": ideas,
		"values_q16": values, "source_priorities": priorities,
		"offer_generations": generations, "choice_indices": choices,
		"gate_ids": gates,
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


func _grant_draw_gates(card_id: String, day: int) -> void:
	var granted := DrawGateHelper.grant_draw_gates(
		_host, card_id, _handle, day)
	if not bool(granted.get("ok", false)):
		printerr("[lifecycle-gate] %s failed: %s" % [
			card_id, String(granted.get("reason", "unknown"))])


func _world_day(ext: Object) -> int:
	if ext == null or not ext.has_method("get_economy_report"):
		return 0
	return int(ext.get_economy_report().get("current_day", 0))


func _has_hard_barrier() -> bool:
	return bool(_clock.has_hard_barrier()) if _clock.has_method("has_hard_barrier") \
		else false


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


func _is_close(a: float, b: float, tolerance: float) -> bool:
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
