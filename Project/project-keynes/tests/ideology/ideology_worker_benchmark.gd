extends SceneTree

# B1 benchmark (03 §6.1): the IDEOLOGY cost on the WORKER path, 64 countries.
#
# Scope is deliberately "produce numbers, optimise nothing". It measures the
# existing worker stage counters rather than adding instrumentation, so the
# figures are what the game already pays:
#
#   ideology_pod_plan_ms    plan + intent building for one committed day
#   ideology_pod_replay_ms  commit_day replay for the same day
#
# The game ships on the worker authority (05 §2.8), so the main-thread ideology
# path is NOT measured here -- it is frozen.
#
# Everything is fixed to one seed and one DLL; a number without both is
# meaningless for comparison.

const COUNTRY_COUNT := 64
const MEASURED_DAYS := 20
const WARMUP_DAYS := 3
const IDEOLOGY_COUNT := 6
const ACTIVE_PER_COUNTRY := 3
const SEED := 20261022

var _ext: Object = null
var _handles := PackedInt64Array()
var _plan_ms: Array = []
var _replay_ms: Array = []
var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("=== b1 ideology worker benchmark: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	_ext.create_entities(COUNTRY_COUNT)
	if not _expect("country runtime configures",
			_configure_country()):
		return
	if not _expect("modifier runtime configures",
			bool(_modifier().configure(_ext, COUNTRY_COUNT).get("ok", false))):
		return
	if not _expect("effect runtime configures", _configure_effects()):
		return
	if not _expect("ideology runtime configures",
			bool(_ext.configure_ideologies(_ideology_catalog()).get("ok", false))):
		return
	if not _expect("country worker inputs publish",
			bool(_ext.capture_country_runtime_snapshot().get("ok", false))
			and bool(_ext.capture_country_pod_catalog().get("ok", false))):
		return
	if not _expect("ideology worker inputs publish",
			bool(_ext.publish_ideology_worker_inputs().get("ok", false))):
		return
	if not _expect("worker starts", _start_worker()):
		return
	_run_days()
	_stop_worker()
	_report()


func _configure_country() -> bool:
	var catalog: Dictionary = preload(
		"res://scripts/economy/economy_catalog.gd").compile_native_catalog()
	if not bool(catalog.get("ok", false)):
		return false
	catalog.erase("ok")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	if not bool(_ext.configure_country(
			catalog, profile, COUNTRY_COUNT, SEED).get("ok", false)):
		return false
	var cell_bytes := PackedByteArray()
	cell_bytes.resize(COUNTRY_COUNT)
	for cell in range(COUNTRY_COUNT):
		cell_bytes[cell] = cell
	if not bool(_ext.bootstrap_country({}, cell_bytes).get("ok", false)):
		return false
	for country in range(COUNTRY_COUNT):
		var handle := int(_ext.get_country_cell_summary(country).get(
			"country_handle", 0))
		if handle == 0:
			return false
		_handles.append(handle)
	return true


func _modifier():
	return preload("res://scripts/modifier/modifier_facade.gd").new()


func _configure_effects() -> bool:
	var catalog: Resource = preload(
		"res://scripts/effect/effect_domain_catalog.gd").build()
	if catalog == null:
		return false
	var native: Dictionary = catalog.compile_native_catalog()
	native["max_transactions"] = COUNTRY_COUNT * ACTIVE_PER_COUNTRY * 2 + 1024
	native["max_native_modifier_commands"] = COUNTRY_COUNT * ACTIVE_PER_COUNTRY + 1024
	return bool(_ext.configure_effects(native).get("ok", false))


func _start_worker() -> bool:
	var started: Dictionary = _ext.start_runtime_worker({
		"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true,
		"authoritative_domain_mask": 0x10,
		"day": 0,
		"speed_days_per_second": 0.0,
		"paused": false,
	})
	return bool(started.get("ok", false))


func _run_days() -> void:
	# Equip work so the day is not an empty scan: a benchmark over idle countries
	# measures the fast path only.
	_submit_equip(0)
	for day in range(1, MEASURED_DAYS + WARMUP_DAYS + 1):
		_run_economy(day)
		_ext.publish_ideology_worker_inputs()
		_ext.set_runtime_clock(true, 1.0)
		_wait_committed(day)
		var report: Dictionary = _ext.get_runtime_thread_report()
		if day <= WARMUP_DAYS:
			continue
		_plan_ms.append(float(report.get("ideology_pod_plan_ms", 0.0)))
		_replay_ms.append(float(report.get("ideology_pod_replay_ms", 0.0)))


func _submit_equip(day: int) -> void:
	var batch := _empty_batch()
	for country in range(COUNTRY_COUNT):
		for idea in range(ACTIVE_PER_COUNTRY):
			batch.opcodes.append(1)
			batch.effective_days.append(day)
			batch.producer_ids.append(1)
			batch.source_priorities.append(0)
			batch.sequences.append(country * ACTIVE_PER_COUNTRY + idea + 1)
			batch.country_handles.append(_handles[country])
			batch.ideology_ids.append(idea)
			batch.values_q16.append(0)
			batch.offer_generations.append(0)
			batch.choice_indices.append(-1)
			batch.gate_ids.append(-1)
	_ext.submit_ideology_commands(batch)
	var equip := _empty_batch()
	for country in range(COUNTRY_COUNT):
		for idea in range(ACTIVE_PER_COUNTRY):
			equip.opcodes.append(5)
			equip.effective_days.append(day)
			equip.producer_ids.append(1)
			equip.source_priorities.append(0)
			equip.sequences.append(country * ACTIVE_PER_COUNTRY + idea + 1)
			equip.country_handles.append(_handles[country])
			equip.ideology_ids.append(idea)
			equip.values_q16.append(0)
			equip.offer_generations.append(0)
			equip.choice_indices.append(-1)
			equip.gate_ids.append(-1)
	_ext.submit_ideology_commands(equip)


func _run_economy(day: int) -> void:
	for slice_index in 512:
		var report: Dictionary = _ext.run_economy_slice({
			"day_index": day,
			"tick_index": day * 1000 + slice_index,
		})
		if bool(report.get("done", false)):
			return


func _wait_committed(day: int) -> void:
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var report: Dictionary = _ext.get_runtime_thread_report()
		if int(report.get("ideology_pod_committed_day", -1)) >= day:
			return
		OS.delay_msec(1)


func _stop_worker() -> void:
	_ext.request_runtime_stop()


func _report() -> void:
	_expect("benchmark collected %d days" % MEASURED_DAYS,
		_plan_ms.size() == MEASURED_DAYS)
	if _plan_ms.is_empty():
		return
	var plan := _stats(_plan_ms)
	var replay := _stats(_replay_ms)
	print("=== B1 ideology worker: %d countries x %d active, %d days, seed %d ===" % [
		COUNTRY_COUNT, ACTIVE_PER_COUNTRY, MEASURED_DAYS, SEED])
	print("  plan_ms   p50=%.4f p95=%.4f max=%.4f avg=%.4f" % [
		plan.p50, plan.p95, plan.maximum, plan.avg])
	print("  replay_ms p50=%.4f p95=%.4f max=%.4f avg=%.4f" % [
		replay.p50, replay.p95, replay.maximum, replay.avg])
	print("  gate (skill): 64-country p95 <= 0.35 ms -> %s" % [
		"PASS" if plan.p95 <= 0.35 else "OVER BUDGET"])


func _stats(values: Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += float(value)
	return {
		"p50": _percentile(sorted, 0.50),
		"p95": _percentile(sorted, 0.95),
		"maximum": float(sorted[sorted.size() - 1]),
		"avg": total / float(sorted.size()),
	}


func _percentile(sorted: Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	var index := int(ceil(fraction * float(sorted.size()))) - 1
	return float(sorted[clampi(index, 0, sorted.size() - 1)])


func _empty_batch() -> Dictionary:
	return {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"producer_ids": PackedInt32Array(), "source_priorities": PackedInt32Array(),
		"sequences": PackedInt64Array(), "country_handles": PackedInt64Array(),
		"ideology_ids": PackedInt32Array(), "values_q16": PackedInt64Array(),
		"offer_generations": PackedInt64Array(), "choice_indices": PackedInt32Array(),
		"gate_ids": PackedInt32Array()}


func _ideology_catalog() -> Dictionary:
	var ids := PackedStringArray()
	var levels := PackedInt64Array()
	for idea in range(IDEOLOGY_COUNT):
		ids.append("idea.b%d" % idea)
		levels.append(0)
	var offsets := PackedInt32Array()
	for idea in range(IDEOLOGY_COUNT + 1):
		offsets.append(idea)
	var rarity := PackedInt32Array()
	var eras := PackedInt32Array()
	var acquisition := PackedInt32Array()
	for idea in range(IDEOLOGY_COUNT):
		rarity.append(1)
		eras.append(0)
		acquisition.append(3)
	return {
		"protocol_version": 1, "ideology_capacity": ACTIVE_PER_COUNTRY,
		"national_spirit_capacity": 1, "offer_choice_count": 3,
		"offer_cost_q16": 65536, "max_commands_per_slice": 64,
		"political_class_ids": PackedStringArray(["general"]),
		"stance_offsets": PackedInt32Array(_zero_range(IDEOLOGY_COUNT + 1)),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(),
		"stance_repeal_q16": PackedInt32Array(),
		"stance_promote_q16": PackedInt32Array(),
		"stance_adopt_min_q16": PackedInt32Array(),
		"stance_repeal_min_q16": PackedInt32Array(),
		"stance_promote_min_q16": PackedInt32Array(),
		"adopt_thresholds_q16": PackedInt32Array(_zero_range(IDEOLOGY_COUNT)),
		"repeal_thresholds_q16": PackedInt32Array(_zero_range(IDEOLOGY_COUNT)),
		"promote_thresholds_q16": PackedInt32Array(_zero_range(IDEOLOGY_COUNT)),
		"exclusion_group_ids": PackedInt32Array(_minus_one_range(IDEOLOGY_COUNT)),
		"synergy_ids": PackedStringArray(),
		"synergy_requirement_offsets": PackedInt32Array([0]),
		"synergy_requirement_ideology_ids": PackedInt32Array(),
		"synergy_requirement_min_levels": PackedInt32Array(),
		"synergy_requirement_location_masks": PackedByteArray(),
		"synergy_effect_offsets": PackedInt32Array([0]),
		"synergy_effect_actions": PackedInt32Array(),
		"synergy_effect_domains": PackedInt32Array(),
		"synergy_effect_opcodes": PackedInt32Array(),
		"synergy_effect_values_q16": PackedInt64Array(),
		"synergy_effect_duration_days": PackedInt32Array(),
		"ideology_ids": ids,
		"level_offsets": offsets,
		"level_understanding_q16": levels,
		"rarity_weights": rarity,
		"era_indices": eras,
		"acquisition_masks": acquisition,
		"requirement_offsets": PackedInt32Array(_zero_range(IDEOLOGY_COUNT + 1)),
		"requirement_technology_ids": PackedInt32Array(),
		"requirement_min_eras": PackedInt32Array(_zero_range(IDEOLOGY_COUNT)),
		"requirement_gate_ids": PackedInt32Array(),
		"requirement_gate_values": PackedByteArray(),
		"gate_key_ids": PackedStringArray(),
		"era_index_count": 4,
	}


func _zero_range(count: int) -> Array:
	var out: Array = []
	for _i in range(count):
		out.append(0)
	return out


func _minus_one_range(count: int) -> Array:
	var out: Array = []
	for _i in range(count):
		out.append(-1)
	return out


func _expect(label: String, ok: bool) -> bool:
	_checks += 1
	if not ok:
		_fail(label)
	return ok


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
