extends SceneTree

## Deterministic native pressure fixture for the ideology/effect closeout gate.
## Setup is intentionally cold-path GDScript. The measured loop calls only the
## bound native runtimes and records their reports; no gameplay state is mirrored
## in this fixture.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

const Q16_ONE := 65536
const COUNTRY_COUNT := 512
const IDEOLOGY_COUNT := 4096
const ACTIVE_PER_COUNTRY := 15
const IDEOLOGY_CAPACITY := 12
const SPIRIT_CAPACITY := 3
const EFFECT_INSTANCE_CAPACITY := COUNTRY_COUNT * (ACTIVE_PER_COUNTRY + SPIRIT_CAPACITY) + 1024
const MEASURED_DAYS := 50
const DISCOVER_BATCH := 16384
const MAX_DRAIN_SLICES := 4096

var _checks := 0
var _failures := 0
var _ext: Object
var _handles := PackedInt64Array()
var _ideology_ms := PackedFloat64Array()
var _effect_ms := PackedFloat64Array()
var _modifier_ms := PackedFloat64Array()
var _gameplay_ms := PackedFloat64Array()

func _init() -> void:
	_run()
	print("ideology runtime stress: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var started := Time.get_ticks_usec()
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(country_ir.get("ok", false)))
	if not bool(country_ir.get("ok", false)):
		return
	_ext = ClassDB.instantiate("DCWorldExt")
	_ext.create_entities(COUNTRY_COUNT)
	var country_catalog := country_ir.duplicate(true)
	country_catalog.erase("ok")
	var profile := {"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"])}
	_expect("512-country runtime configures",
		bool(_ext.configure_country(country_catalog, profile, COUNTRY_COUNT, 20260807).get("ok", false)))
	_expect("512-country bootstrap commits",
		bool(_ext.bootstrap_country(_country_packet(), PackedByteArray(_zero_bytes(COUNTRY_COUNT))).get("ok", false)))
	if _failures != 0:
		return
	for cell in range(COUNTRY_COUNT):
		_handles.append(int(_ext.get_country_cell_summary(cell).country_handle))
	_expect("all country handles are generation-safe", _handles.size() == COUNTRY_COUNT and _handles.find(0) == -1)

	var modifier := ModifierFacadeScript.new()
	_expect("modifier runtime configures", bool(modifier.configure(_ext, COUNTRY_COUNT).get("ok", false)))
	var effect_catalog := _effect_catalog()
	var effect_compiled: Dictionary = effect_catalog.compile_native_catalog()
	_expect("stress Effect catalog compiles", bool(effect_compiled.get("ok", false)))
	if not bool(effect_compiled.get("ok", false)):
		return
	var effect_runtime_catalog := effect_compiled.duplicate(true)
	effect_runtime_catalog["max_instances"] = EFFECT_INSTANCE_CAPACITY
	effect_runtime_catalog["max_transactions"] = COUNTRY_COUNT * ACTIVE_PER_COUNTRY * 2 + 1024
	effect_runtime_catalog["max_work_per_slice"] = 100000
	effect_runtime_catalog["max_native_modifier_commands"] = COUNTRY_COUNT * ACTIVE_PER_COUNTRY + 1024
	_expect("Effect runtime configures at stress capacity",
		bool(_ext.configure_effects(effect_runtime_catalog).get("ok", false)))
	var ideology_catalog := _ideology_catalog()
	_expect("4096-ideology catalog configures",
		bool(_ext.configure_ideologies(ideology_catalog).get("ok", false)))
	if _failures != 0:
		return

	var setup_started := Time.get_ticks_usec()
	_expect("all country/ideology discovery commands submit",
		_submit_discovery_commands())
	_expect("all discovery commands commit", _drain_ideology(0))
	var known_snapshot: Dictionary = _ext.get_ideology_snapshot(_handles[0])
	_expect("full discovery bitset is represented", (known_snapshot.known_ids as PackedInt32Array).size() == IDEOLOGY_COUNT)

	_expect("first twelve ideologies equip", _submit_and_run_active_commands(1, 0, IDEOLOGY_CAPACITY))
	_expect("first activation Effect transaction commits", _commit_native_effects(1))
	_expect("first activation ACK clears transitions", _drain_ideology(2) and _all_active_count(IDEOLOGY_CAPACITY))
	_expect("three ideologies promote to national spirits", _submit_and_run_active_commands(3, 0, SPIRIT_CAPACITY, 7))
	_expect("three replacement ideologies equip", _submit_and_run_active_commands(4, IDEOLOGY_CAPACITY, ACTIVE_PER_COUNTRY))
	_expect("replacement activation Effect transaction commits", _commit_native_effects(4))
	_expect("replacement activation ACK clears transitions", _drain_ideology(5))
	var setup_diag: Dictionary = _ext.get_ideology_report()
	print("setup ideology diagnostics applied=%d rejected=%d last_error=%s" % [
		int(setup_diag.get("commands_applied", 0)), int(setup_diag.get("commands_rejected", 0)),
		String(setup_diag.get("last_error", ""))])
	_expect("each country has 12 ideology slots and 3 spirits", _validate_active_layout())
	var setup_ms := float(Time.get_ticks_usec() - setup_started) / 1000.0

	var baseline_visits := int(_ext.get_ideology_report().get("active_visits", 0))
	for offset in range(MEASURED_DAYS):
		var day := 6 + offset
		var t0 := Time.get_ticks_usec()
		var ideology_report: Dictionary = _run_ideology_measured(day)
		_ideology_ms.append(float(Time.get_ticks_usec() - t0) / 1000.0)
		var t1 := Time.get_ticks_usec()
		if _ext.effect_should_run(day):
			_expect("effect day %d completes" % day, _drain_effect(day))
		_effect_ms.append(float(Time.get_ticks_usec() - t1) / 1000.0)
		var t2 := Time.get_ticks_usec()
		if _ext.modifier_should_run(day):
			_expect("modifier day %d completes" % day, bool(_ext.run_modifier_daily(day).get("ok", false)))
		_modifier_ms.append(float(Time.get_ticks_usec() - t2) / 1000.0)
		var t3 := Time.get_ticks_usec()
		if _ext.gameplay_effect_should_run(day):
			_expect("gameplay day %d completes" % day, bool(_ext.run_gameplay_effects(day).get("ok", false)))
		_gameplay_ms.append(float(Time.get_ticks_usec() - t3) / 1000.0)
		if offset == 0 or offset == MEASURED_DAYS - 1:
			print("stress day=%d ideology_ms=%.3f active_visits=%d" % [day, _ideology_ms[-1], int(ideology_report.get("active_visits", 0))])

	var ideology_report: Dictionary = _ext.get_ideology_report()
	var effect_report: Dictionary = _ext.get_effect_report()
	var journal_report: Dictionary = _ext.get_gameplay_event_bus_report()
	var visits_delta := int(ideology_report.get("active_visits", 0)) - baseline_visits
	_expect("active dense traversal matches 50 days x 15 x 512", visits_delta == MEASURED_DAYS * ACTIVE_PER_COUNTRY * COUNTRY_COUNT)
	_expect("dormant ideology scan count is zero", int(ideology_report.get("dormant_scan_count", -1)) == 0)
	_expect("dormant Effect scan count is zero", int(effect_report.get("dormant_instances_scanned", -1)) == 0)
	_expect("Effect queue has no overflow", int(effect_report.get("overflow_count", -1)) == 0)
	_expect("all stress Effect transactions are native claimed", int(effect_report.get("native_modifier_transactions", 0)) > 0)
	_expect("no GDScript fallback transactions are exposed", int(_ext.poll_effect_transactions(0, 1).get("count", 0)) == 0)
	_expect("journal has no fallback reason", String(journal_report.get("fallback_reason", "")) == "")
	_write_report(setup_ms, started, visits_delta, ideology_report, effect_report, journal_report)
	print("ideology stress setup_ms=%.3f ideology=%s effect=%s modifier=%s gameplay=%s" % [
		setup_ms, _summary(_ideology_ms), _summary(_effect_ms), _summary(_modifier_ms), _summary(_gameplay_ms)])


func _country_packet() -> Dictionary:
	var ids := PackedStringArray()
	var names := PackedStringArray()
	var cash := PackedInt64Array()
	var territory_offsets := PackedInt32Array([0])
	var territory_cells := PackedInt32Array()
	var technology_offsets := PackedInt32Array([0])
	var technology_indices := PackedInt32Array()
	var treasury_offsets := PackedInt32Array([0])
	var treasury_goods := PackedInt32Array()
	var treasury_quantities := PackedInt64Array()
	for country in range(COUNTRY_COUNT):
		ids.append("stress.country.%04d" % country)
		names.append("Stress Country %04d" % country)
		cash.append(0)
		territory_cells.append(country)
		territory_offsets.append(territory_cells.size())
		technology_offsets.append(technology_indices.size())
		treasury_offsets.append(treasury_goods.size())
	return {"country_ids": ids, "country_names": names, "country_cash": cash,
		"territory_offsets": territory_offsets, "territory_cells": territory_cells,
		"technology_offsets": technology_offsets, "technology_indices": technology_indices,
		"treasury_offsets": treasury_offsets, "treasury_good_indices": treasury_goods,
		"treasury_quantities": treasury_quantities}


func _zero_bytes(count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	return out


func _ideology_catalog() -> Dictionary:
	var out := {"protocol_version": 1, "ideology_capacity": IDEOLOGY_CAPACITY,
		"national_spirit_capacity": SPIRIT_CAPACITY, "offer_choice_count": 3,
		"offer_cost_q16": Q16_ONE, "max_commands_per_slice": 4096,
		"ideology_ids": PackedStringArray(), "acquisition_flags": PackedByteArray(),
		"rarity_weights": PackedInt32Array(), "ideology_slot_costs": PackedInt32Array(),
		"spirit_slot_costs": PackedInt32Array(), "national_spirit_min_levels": PackedInt32Array(),
		"level_offsets": PackedInt32Array([0]), "level_thresholds_q16": PackedInt64Array(),
		"level_daily_understanding_q16": PackedInt64Array(),
		"technology_requirement_offsets": PackedInt32Array([0]), "technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0]), "signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0]), "gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0]), "persistent_actions": PackedInt32Array(),
		"persistent_domains": PackedInt32Array(), "persistent_opcodes": PackedInt32Array(),
		"persistent_values_q16": PackedInt64Array(), "persistent_duration_days": PackedInt32Array(),
		"persistent_stacks": PackedInt32Array(), "persistent_command_keys": PackedStringArray(),
		"persistent_definition_keys": PackedStringArray(), "persistent_payload_i0": PackedInt64Array(),
		"persistent_payload_i1": PackedInt64Array(), "persistent_payload_i2": PackedInt64Array(),
		"persistent_payload_i3": PackedInt64Array(), "level_on_enter_offsets": PackedInt32Array([0]),
		"on_enter_actions": PackedInt32Array(), "on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(), "on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(), "on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(), "on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(), "on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(), "on_enter_payload_i3": PackedInt64Array()}
	for idea in range(IDEOLOGY_COUNT):
		out.ideology_ids.append("stress.idea.%04d" % idea)
		out.acquisition_flags.append(1)
		out.rarity_weights.append(1)
		out.ideology_slot_costs.append(1)
		out.spirit_slot_costs.append(1)
		out.national_spirit_min_levels.append(0)
		out.level_thresholds_q16.append(0)
		out.level_daily_understanding_q16.append(0)
		out.level_offsets.append(out.level_thresholds_q16.size())
		out.technology_requirement_offsets.append(0)
		out.signal_requirement_offsets.append(0)
		out.gate_requirement_offsets.append(0)
		out.persistent_actions.append(1)
		out.persistent_domains.append(1)
		out.persistent_opcodes.append(1)
		out.persistent_values_q16.append(Q16_ONE)
		out.persistent_duration_days.append(-1)
		out.persistent_stacks.append(1)
		out.persistent_command_keys.append("ideology.stress.persistent")
		out.persistent_definition_keys.append("country.economic_mobilization")
		out.persistent_payload_i0.append(0)
		out.persistent_payload_i1.append(0)
		out.persistent_payload_i2.append(0)
		out.persistent_payload_i3.append(0)
		out.level_persistent_offsets.append(out.persistent_actions.size())
		out.level_on_enter_offsets.append(out.on_enter_actions.size())
	return out


func _effect_catalog() -> Resource:
	var catalog := EffectCatalogScript.new()
	catalog.max_instances = EFFECT_INSTANCE_CAPACITY
	catalog.max_transactions = COUNTRY_COUNT * ACTIVE_PER_COUNTRY * 2 + 1024
	catalog.max_work_per_slice = 100000
	catalog.max_native_modifier_commands = COUNTRY_COUNT * ACTIVE_PER_COUNTRY + 1024
	var definition := EffectDefinitionScript.new()
	definition.key = &"ideology.command"
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [end]
	var persistent := EffectCommandScript.new()
	persistent.action = 1
	persistent.domain = 1
	persistent.opcode = 1
	persistent.target_resolver = 1
	persistent.value_mode = 0
	persistent.command_key = &"ideology.stress.persistent"
	persistent.definition_key = &"country.economic_mobilization"
	definition.commands = [persistent]
	catalog.definitions = [definition]
	return catalog


func _submit_discovery_commands() -> bool:
	var total := COUNTRY_COUNT * IDEOLOGY_COUNT
	var sequence := 0
	for begin in range(0, total, DISCOVER_BATCH):
		var end := mini(begin + DISCOVER_BATCH, total)
		var batch := _empty_commands()
		for flat in range(begin, end):
			var country := flat / IDEOLOGY_COUNT
			var idea := flat % IDEOLOGY_COUNT
			sequence += 1
			batch.opcodes.append(1)
			batch.effective_days.append(0)
			batch.source_priorities.append(0)
			batch.sequences.append(sequence)
			batch.country_handles.append(_handles[country])
			batch.ideology_ids.append(idea)
			batch.values_q16.append(0)
			batch.offer_generations.append(0)
			batch.choice_indices.append(-1)
			batch.gate_ids.append(-1)
		var result: Dictionary = _ext.submit_ideology_commands(batch)
		if not bool(result.get("ok", false)):
			push_error("discovery batch rejected: %s" % str(result))
			return false
	return true


func _submit_and_run_active_commands(day: int, first_idea: int, end_idea: int, opcode := 5) -> bool:
	var batch := _empty_commands()
	var sequence := 0
	for country in range(COUNTRY_COUNT):
		for idea in range(first_idea, end_idea):
			sequence += 1
			batch.opcodes.append(opcode)
			batch.effective_days.append(day)
			batch.source_priorities.append(0)
			batch.sequences.append(sequence)
			batch.country_handles.append(_handles[country])
			batch.ideology_ids.append(idea)
			batch.values_q16.append(0)
			batch.offer_generations.append(0)
			batch.choice_indices.append(-1)
			batch.gate_ids.append(-1)
	var result: Dictionary = _ext.submit_ideology_commands(batch)
	return bool(result.get("ok", false)) and _drain_ideology(day)


func _empty_commands() -> Dictionary:
	return {"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(), "sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array()}


func _drain_ideology(day: int) -> bool:
	for _slice in range(MAX_DRAIN_SLICES):
		var report: Dictionary = _ext.run_ideology_daily(day)
		if not bool(report.get("ok", false)):
			push_error("ideology daily failed: %s" % str(report))
			return false
		if bool(report.get("done", false)):
			return true
	push_error("ideology slice drain exceeded %d" % MAX_DRAIN_SLICES)
	return false


func _drain_effect(day: int) -> bool:
	for _slice in range(MAX_DRAIN_SLICES):
		var report: Dictionary = _ext.run_effect_daily(day)
		if not bool(report.get("ok", false)):
			push_error("effect daily failed: %s" % str(report))
			return false
		if bool(report.get("done", false)):
			return true
	push_error("effect slice drain exceeded %d" % MAX_DRAIN_SLICES)
	return false


func _commit_native_effects(day: int) -> bool:
	if not _drain_effect(day):
		return false
	var modifier_dispatch: Dictionary = _ext.dispatch_effect_native_modifier()
	if not bool(modifier_dispatch.get("ok", false)):
		push_error("native modifier dispatch failed: %s" % str(modifier_dispatch))
		return false
	var gameplay_dispatch: Dictionary = _ext.dispatch_effect_native_gameplay()
	if not bool(gameplay_dispatch.get("ok", false)):
		push_error("native gameplay dispatch failed: %s" % str(gameplay_dispatch))
		return false
	if int(_ext.poll_effect_transactions(0, 1).get("count", 0)) != 0:
		push_error("ideology Effect leaked into GDScript fallback polling")
		return false
	if int(modifier_dispatch.get("submitted_transactions", 0)) <= 0:
		push_error("native modifier dispatch submitted no transactions")
		return false
	if not bool(_ext.run_modifier_daily(day).get("ok", false)):
		return false
	if not bool(_ext.ack_effect_native_modifier().get("ok", false)):
		return false
	if int(gameplay_dispatch.get("submitted_transactions", 0)) > 0:
		if not bool(_ext.run_gameplay_effects(day).get("ok", false)):
			return false
		if not bool(_ext.ack_effect_native_gameplay().get("ok", false)):
			return false
	return true


func _run_ideology_measured(day: int) -> Dictionary:
	var final_report: Dictionary = {}
	for _slice in range(MAX_DRAIN_SLICES):
		final_report = _ext.run_ideology_daily(day)
		if not bool(final_report.get("ok", false)):
			push_error("measured ideology daily failed: %s" % str(final_report))
			break
		if bool(final_report.get("done", false)):
			break
	return final_report


func _all_active_count(expected: int) -> bool:
	var snapshot: Dictionary = _ext.get_ideology_snapshot(_handles[0])
	var locations: PackedInt32Array = snapshot.locations
	var count := 0
	for location in locations:
		if location != 0:
			count += 1
	return count == expected


func _validate_active_layout() -> bool:
	for handle in _handles:
		var snapshot: Dictionary = _ext.get_ideology_snapshot(handle)
		if int(snapshot.ideology_slots_used) != IDEOLOGY_CAPACITY \
				or int(snapshot.national_spirit_slots_used) != SPIRIT_CAPACITY:
			print("layout mismatch handle=%d ideology=%d/%d spirit=%d/%d locations=%s" % [
				handle, int(snapshot.ideology_slots_used), IDEOLOGY_CAPACITY,
				int(snapshot.national_spirit_slots_used), SPIRIT_CAPACITY,
				str(snapshot.locations)])
			return false
		var active := 0
		for location in snapshot.locations:
			if int(location) != 0:
				active += 1
		if active != ACTIVE_PER_COUNTRY:
			return false
	return true


func _summary(values: PackedFloat64Array) -> String:
	if values.is_empty():
		return "avg=0.000 p95=0.000 max=0.000"
	var sorted := Array(values)
	sorted.sort()
	var total := 0.0
	for value in sorted:
		total += float(value)
	var p95_index := mini(sorted.size() - 1, maxi(0, int(ceil(sorted.size() * 0.95)) - 1))
	return "avg=%.3f p95=%.3f max=%.3f" % [total / sorted.size(), float(sorted[p95_index]), float(sorted[-1])]


func _write_report(setup_ms: float, started: int, visits_delta: int,
		ideology_report: Dictionary, effect_report: Dictionary, journal_report: Dictionary) -> void:
	var path := ProjectSettings.globalize_path("res://../../tmp/ideology_stress_report.csv")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write stress report: %s" % path)
		return
	file.store_line("metric,value")
	file.store_line("country_count,%d" % COUNTRY_COUNT)
	file.store_line("ideology_count,%d" % IDEOLOGY_COUNT)
	file.store_line("active_per_country,%d" % ACTIVE_PER_COUNTRY)
	file.store_line("setup_ms,%.6f" % setup_ms)
	file.store_line("measured_days,%d" % MEASURED_DAYS)
	file.store_line("active_visits_delta,%d" % visits_delta)
	file.store_line("dormant_scan_count,%d" % int(ideology_report.get("dormant_scan_count", -1)))
	file.store_line("effect_dormant_instances_scanned,%d" % int(effect_report.get("dormant_instances_scanned", -1)))
	file.store_line("effect_overflow_count,%d" % int(effect_report.get("overflow_count", -1)))
	file.store_line("effect_native_modifier_transactions,%d" % int(effect_report.get("native_modifier_transactions", 0)))
	file.store_line("journal_effect_idempotency_count,%d" % int(journal_report.get("effect_idempotency_count", 0)))
	file.store_line("ideology_ms,%s" % _summary(_ideology_ms))
	file.store_line("effect_ms,%s" % _summary(_effect_ms))
	file.store_line("modifier_ms,%s" % _summary(_modifier_ms))
	file.store_line("gameplay_ms,%s" % _summary(_gameplay_ms))
	file.store_line("elapsed_ms,%.3f" % (float(Time.get_ticks_usec() - started) / 1000.0))
	file.close()


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
