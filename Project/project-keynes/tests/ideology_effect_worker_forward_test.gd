extends SceneTree

# M2a step 6 gate: the ideology runtime must write Effect instances through
# EffectInstanceForwarder, not straight into EffectRuntime, once EFFECT belongs
# to the worker.
#
# Why this test cannot just run ACTIVE: a fresh ACTIVE start only earns its
# domain grant after the worker commits one fully committed day
# (native_simulation_host.cpp, "A fresh ACTIVE start earns its grant from the
# first fully committed day"). A headless catalog fixture has no Climate trace,
# so that day never completes and EFFECT never leaves the main thread. Worse,
# granting IDEOLOGY to the worker suppresses run_ideology_daily outright, which
# would skip the very reconciliation under test.
#
# So authority is driven through set_effect_forwarder_authority_for_test(), the
# same style of explicit seam the host already exposes for Country sync writes
# and Climate parity forcing. The seam changes only what the forwarder believes;
# ideology keeps reconciling on the main thread either way, which is the
# production situation M2a-5 was written for (IDEOLOGY on main thread, EFFECT on
# the worker).
#
# The observable is get_ideology_effect_instance_report().present, which reports
# EffectRuntime::has_instance_pod for each held ref:
#
#   legacy override -> the refs point at instances EffectRuntime owns  (1)
#   worker override -> the refs were queued to the worker transport and
#                      EffectRuntime never saw them                    (0)
#
# Same fixture, same reconcile, same instance identity. Only the writer differs,
# which is exactly the claim M2a-5 makes.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

const Q16_ONE := 65536
const PROGRAM_KEY := "ideology.effect.v1_granary_belt"
const CARD_DEFINITION_KEY := "v1_granary_belt"
const TEST_MODIFIER_KEY := "country.economic_mobilization"

var _checks := 0
var _failures := 0
var _next_sequence := 1


func _init() -> void:
	_run()
	print("=== ideology effect worker forward: %d checks, %d failures ===" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(country_ir.get("ok", false)))
	if not bool(country_ir.get("ok", false)):
		return
	var content: Resource = IdeologyEffectCatalogScript.load_default()
	_expect("idea effect catalog loads", content != null)
	if content == null:
		return
	var defined: Array = content.effects
	_expect("idea effect catalog declares a program",
		not defined.is_empty() and defined[0] != null)
	if defined.is_empty() or defined[0] == null:
		return

	_test_forwarder_seam(country_ir, defined[0])
	_test_ideology_reroute(country_ir, defined[0])
	_test_adapter_parity(country_ir, defined[0])
	_test_worker_save_restore(country_ir, defined[0])


## The ideology restore proves that every bound instance still exists before it
## accepts a save (`ideology_effect_instance_missing`). Under EFFECT worker
## authority EffectRuntime is writeback-only, so that check used to reject a
## perfectly healthy save -- and it fires during load, which took the whole
## ideology domain down with it. This is the query half of M2b: the reader has to
## ask whichever side owns EFFECT.
##
## The instance is queued, not installed (no worker runs in this fixture), which
## is exactly the race that also had to be closed: a row the transport accepted
## counts as present.
func _test_worker_save_restore(country_ir: Dictionary, program: Resource) -> void:
	var ext: Object = _configured_ext(country_ir, program)
	ext.set_effect_forwarder_authority_for_test(1)
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("restore/worker: country handle is generation safe", handle != 0)
	if handle == 0:
		return
	ext.submit_ideology_commands(_commands([
		{"op": 1, "day": 0, "handle": handle, "idea": 0},
		{"op": 5, "day": 0, "handle": handle, "idea": 0},
	]))
	ext.run_ideology_daily(0)
	var report: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("restore/worker: reconcile holds exactly one instance",
		int(report.get("count", -1)) == 1)
	var captured: PackedByteArray = ext.capture_ideology_state()
	_expect("restore/worker: ideology state captures", captured.size() > 0)
	if captured.is_empty():
		return
	var restored: Dictionary = ext.restore_ideology_state(captured)
	_expect("restore/worker: restore accepts a queued worker instance",
		bool(restored.get("ok", false)))
	if not bool(restored.get("ok", false)):
		print("  restore/worker: reason=%s" % String(
			restored.get("reason", "unknown")))


## M2b G-1: the worker's Effect-intent -> Modifier-POD mapping must reproduce
## EffectRuntime::dispatch_native_modifier field for field. The C++ self-test
## owns the fixture because the worker TU cannot call the reference
## implementation (it must not include modifier_runtime.h); see its declaration
## for why the expected values are transcribed rather than computed.
func _test_adapter_parity(country_ir: Dictionary, program: Resource) -> void:
	var ext: Object = _configured_ext(country_ir, program)
	_expect("adapter parity self-test is exported",
		ext.has_method("runtime_effect_adapter_parity_self_test"))
	_expect("adapter parity self-test passes",
		bool(ext.runtime_effect_adapter_parity_self_test()))


## The seam itself, and both forwarder branches it selects. Without this the
## reroute evidence below would be unreadable: a present==0 could equally mean
## "the forwarder silently dropped the row".
func _test_forwarder_seam(country_ir: Dictionary, program: Resource) -> void:
	var ext: Object = _configured_ext(country_ir, program)
	# The registry template is the unmanaged program in this catalog. The
	# managed ideology program refuses a batch that omits source_kinds, so using
	# it here would test the declarative rule instead of the seam.
	var keys: PackedStringArray = _effect_catalog(program).compile_native_catalog().get(
		"effect_keys", PackedStringArray())
	var plain_key := String(keys[0])

	var to_worker: Dictionary = ext.set_effect_forwarder_authority_for_test(1)
	_expect("worker override is accepted", bool(to_worker.get("ok", false)))
	_expect("worker override reports worker authority",
		bool(to_worker.get("worker_authoritative", false)) and
		int(to_worker.get("override", 0)) == 1)

	var queued: Dictionary = ext.submit_effect_instances(
		_batch(88001, plain_key, 1, true))
	_expect("worker submit succeeds", bool(queued.get("ok", false)))
	_expect("worker submit is marked EFFECT_WORKER",
		String(queued.get("path", "")) == "EFFECT_WORKER")
	_expect("worker submit queues instead of mirroring",
		int(queued.get("effect_pod_queued", -1)) == 1 and
		not queued.has("effect_pod_mirrored"))
	_expect("worker submit reports its own rejection counter",
		queued.has("effect_pod_rejected") and not queued.has("rejected"))

	var removed: Dictionary = ext.retire_effect_instance(88001, 1, 0)
	_expect("worker retire succeeds", bool(removed.get("ok", true)))
	_expect("worker retire is marked EFFECT_WORKER",
		String(removed.get("path", "")) == "EFFECT_WORKER")

	# Flipping the seam is a deliberate jump, not an authority race: it must not
	# burn an epoch, otherwise the next reconcile would drop every held ref.
	var epoch_before := int(ext.set_effect_forwarder_authority_for_test(1).get(
		"authority_epoch", -1))
	var to_legacy: Dictionary = ext.set_effect_forwarder_authority_for_test(0)
	_expect("legacy override reports no worker authority",
		not bool(to_legacy.get("worker_authoritative", true)) and
		int(to_legacy.get("override", -1)) == 0)
	_expect("flipping the seam does not advance the authority epoch",
		int(to_legacy.get("authority_epoch", -2)) == epoch_before)

	var mirrored: Dictionary = ext.submit_effect_instances(
		_batch(88002, plain_key, 1, true))
	_expect("legacy submit succeeds", bool(mirrored.get("ok", false)))
	_expect("legacy submit carries no EFFECT_WORKER marker",
		not mirrored.has("path"))
	_expect("legacy submit still mirrors into the worker transport",
		int(mirrored.get("effect_pod_mirrored", -1)) == 1)


## The M2a-5 claim: the same ideology reconcile writes through two different
## owners depending on where EFFECT lives.
func _test_ideology_reroute(country_ir: Dictionary, program: Resource) -> void:
	var legacy_report := _adopt_and_report(country_ir, program, 0, 1, "legacy")
	var worker_report := _adopt_and_report(country_ir, program, 1, 0, "worker")
	if legacy_report.is_empty() or worker_report.is_empty():
		return
	# Same reconcile, same identity: the only difference is who received it.
	_expect("both authorities produce the same instance identity",
		worker_report.get("instance_ids", PackedInt64Array()) ==
		legacy_report.get("instance_ids", PackedInt64Array()))
	_expect("both authorities record the same target",
		worker_report.get("target_handles", PackedInt64Array()) ==
		legacy_report.get("target_handles", PackedInt64Array()))


## Adopts the card, runs day 0 and returns the level-0 instance report.
## `expected_present` is the EffectRuntime ownership bit the chosen authority
## must produce, and it is re-checked after a level promotion so a silently
## reverted writer cannot pass the level-0 check and drift later.
func _adopt_and_report(country_ir: Dictionary, program: Resource,
		override_mode: int, expected_present: int, label: String) -> Dictionary:
	var ext: Object = _configured_ext(country_ir, program)
	var seam: Dictionary = ext.set_effect_forwarder_authority_for_test(override_mode)
	_expect("%s: seam reports the requested authority" % label,
		bool(seam.get("worker_authoritative", false)) == (override_mode != 0))
	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("%s: country handle is generation safe" % label, handle != 0)
	_expect("%s: discover and adopt queue" % label, bool(
		ext.submit_ideology_commands(_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": 0},
			{"op": 5, "day": 0, "handle": handle, "idea": 0},
		])).get("ok", false)))
	var adopted: Dictionary = ext.run_ideology_daily(0)
	_expect("%s: adopt day applies" % label,
		bool(adopted.get("ok", false)) and
		not bool(adopted.get("suppressed", false)))
	# A rejected batch would surface here instead of silently dropping the refs.
	var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
	_expect("%s: reconcile leaves no last_error" % label,
		String(snapshot.get("last_error", "")).is_empty())

	var first: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("%s: reconcile holds exactly one instance" % label,
		int(first.get("count", -1)) == 1)
	_expect("%s: ownership bit is %d" % [label, expected_present],
		_present_at(first, 0) == expected_present)

	# Re-running the same day must be a no-op, not a resubmit.
	var first_ids: PackedInt64Array = first.get("instance_ids", PackedInt64Array())
	ext.run_ideology_daily(0)
	var rerun: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("%s: same-day rerun does not change identity" % label,
		rerun.get("instance_ids", PackedInt64Array()) == first_ids)

	# Days 1..4 carry the card to level 2, which changes the instance identity.
	# Convergence (count stays 1) and the writer both have to survive that.
	for day in range(1, 5):
		ext.run_ideology_daily(day)
	var promoted: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("%s: level promotion does not accumulate instances" % label,
		int(promoted.get("count", -1)) == 1)
	_expect("%s: level promotion keeps the same writer" % label,
		_present_at(promoted, 0) == expected_present)
	return first


func _present_at(report: Dictionary, index: int) -> int:
	var present: PackedByteArray = report.get("present", PackedByteArray())
	return int(present[index]) if index < present.size() else -1


func _configured_ext(country_ir: Dictionary, program_source: Resource) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var catalog := country_ir.duplicate(true)
	catalog.erase("ok")
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}
	_expect("country runtime configures",
		bool(ext.configure_country(catalog, profile, 1, 97).get("ok", false)))
	_expect("country bootstraps",
		bool(ext.bootstrap_country({}, PackedByteArray([0])).get("ok", false)))
	var modifier := ModifierFacadeScript.new()
	_expect("modifier runtime configures",
		bool(modifier.configure(ext, 1).get("ok", false)))
	var effects: Dictionary = ext.configure_effects(
		_effect_catalog(program_source).compile_native_catalog())
	_expect("effect catalog configures", bool(effects.get("ok", false)))
	_expect("effect pod catalog compiles",
		bool(effects.get("effect_pod_ready", false)))
	_expect("ideology catalog configures",
		bool(ext.configure_ideologies(_ideology_catalog()).get("ok", false)))
	return ext


func _effect_catalog(program_source: Resource) -> Resource:
	var catalog: Resource = EffectCatalogScript.new()
	var definitions: Array[Resource] = []
	var registry: Resource = EffectDefinitionScript.new()
	registry.key = &"ideology.command"
	registry.cadence_days = 3650
	var end := EffectInstruction.new()
	end.op = 12
	var registry_instructions: Array[Resource] = [end]
	registry.instructions = registry_instructions
	var template := EffectCommand.new()
	template.action = 1
	template.domain = 1
	template.opcode = 1
	template.target_resolver = 1
	template.value_mode = 0
	template.command_key = &"ideology.persistent"
	template.definition_key = &"country.economic_mobilization"
	var registry_commands: Array[Resource] = [template]
	registry.commands = registry_commands
	definitions.append(registry)
	var program: Resource = program_source.to_effect_definition()
	if program.commands.size() > 0:
		program.commands[0].definition_key = StringName(TEST_MODIFIER_KEY)
	definitions.append(program)
	catalog.definitions = definitions
	return catalog


func _ideology_catalog() -> Dictionary:
	var ids := PackedStringArray(["idea.granary_belt"])
	return {
		"protocol_version": 1,
		"ideology_capacity": 2,
		"national_spirit_capacity": 1,
		"offer_choice_count": 3,
		"offer_cost_q16": Q16_ONE,
		"max_commands_per_slice": 64,
		"max_transition_commands": 256,
		"max_effect_instances": 128,
		"political_class_ids": PackedStringArray(["general"]),
		"stance_offsets": PackedInt32Array([0, 0]),
		"stance_class_indices": PackedInt32Array(),
		"stance_adopt_q16": PackedInt32Array(),
		"stance_repeal_q16": PackedInt32Array(),
		"stance_promote_q16": PackedInt32Array(),
		"stance_adopt_min_q16": PackedInt32Array(),
		"stance_repeal_min_q16": PackedInt32Array(),
		"stance_promote_min_q16": PackedInt32Array(),
		"adopt_thresholds_q16": PackedInt32Array([0]),
		"repeal_thresholds_q16": PackedInt32Array([0]),
		"promote_thresholds_q16": PackedInt32Array([0]),
		"exclusion_group_ids": PackedInt32Array([-1]),
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
		"synergy_effect_stacks": PackedInt32Array(),
		"synergy_effect_command_keys": PackedStringArray(),
		"synergy_effect_definition_keys": PackedStringArray(),
		"synergy_effect_payload_i0": PackedInt64Array(),
		"synergy_effect_payload_i1": PackedInt64Array(),
		"synergy_effect_payload_i2": PackedInt64Array(),
		"synergy_effect_payload_i3": PackedInt64Array(),
		"ideology_synergy_offsets": PackedInt32Array([0, 0]),
		"ideology_synergy_ids": PackedInt32Array(),
		"ideology_ids": ids,
		"acquisition_flags": PackedByteArray([3]),
		"rarity_weights": PackedInt32Array([1]),
		"ideology_slot_costs": PackedInt32Array([1]),
		"spirit_slot_costs": PackedInt32Array([1]),
		"national_spirit_min_levels": PackedInt32Array([1]),
		"level_offsets": PackedInt32Array([0, 3]),
		"level_thresholds_q16": PackedInt64Array([0, 3 * Q16_ONE, 5 * Q16_ONE]),
		"level_daily_understanding_q16": PackedInt64Array([
			Q16_ONE, Q16_ONE, Q16_ONE]),
		"technology_requirement_offsets": PackedInt32Array([0, 0]),
		"technology_requirements": PackedInt32Array(),
		"signal_requirement_offsets": PackedInt32Array([0, 0]),
		"signal_requirements": PackedInt32Array(),
		"gate_requirement_offsets": PackedInt32Array([0, 0]),
		"gate_requirements": PackedInt32Array(),
		"level_persistent_offsets": PackedInt32Array([0, 1, 2, 3]),
		"persistent_actions": PackedInt32Array([1, 1, 1]),
		"persistent_domains": PackedInt32Array([1, 1, 1]),
		"persistent_opcodes": PackedInt32Array([1, 1, 1]),
		"persistent_values_q16": PackedInt64Array([Q16_ONE, Q16_ONE, Q16_ONE]),
		"persistent_duration_days": PackedInt32Array([-1, -1, -1]),
		"persistent_stacks": PackedInt32Array([1, 1, 1]),
		"persistent_command_keys": PackedStringArray([
			"ideology.persistent", "ideology.persistent", "ideology.persistent"]),
		"persistent_definition_keys": PackedStringArray([
			CARD_DEFINITION_KEY, CARD_DEFINITION_KEY, CARD_DEFINITION_KEY]),
		"persistent_payload_i0": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i1": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i2": PackedInt64Array([0, 0, 0]),
		"persistent_payload_i3": PackedInt64Array([0, 0, 0]),
		"level_on_enter_offsets": PackedInt32Array([0, 0, 0, 0]),
		"on_enter_actions": PackedInt32Array(),
		"on_enter_domains": PackedInt32Array(),
		"on_enter_opcodes": PackedInt32Array(),
		"on_enter_values_q16": PackedInt64Array(),
		"on_enter_duration_days": PackedInt32Array(),
		"on_enter_stacks": PackedInt32Array(),
		"on_enter_command_keys": PackedStringArray(),
		"on_enter_definition_keys": PackedStringArray(),
		"on_enter_payload_i0": PackedInt64Array(),
		"on_enter_payload_i1": PackedInt64Array(),
		"on_enter_payload_i2": PackedInt64Array(),
		"on_enter_payload_i3": PackedInt64Array(),
	}


func _commands(rows: Array[Dictionary]) -> Dictionary:
	var out := {
		"opcodes": PackedInt32Array(), "effective_days": PackedInt64Array(),
		"source_priorities": PackedInt32Array(), "producer_ids": PackedInt32Array(),
		"sequences": PackedInt64Array(),
		"country_handles": PackedInt64Array(), "ideology_ids": PackedInt32Array(),
		"values_q16": PackedInt64Array(), "offer_generations": PackedInt64Array(),
		"choice_indices": PackedInt32Array(), "gate_ids": PackedInt32Array(),
	}
	for row in rows:
		out.opcodes.append(int(row.op))
		out.effective_days.append(int(row.day))
		out.source_priorities.append(0)
		out.producer_ids.append(1)
		out.sequences.append(_next_sequence)
		_next_sequence += 1
		out.country_handles.append(int(row.handle))
		out.ideology_ids.append(int(row.get("idea", -1)))
		out.values_q16.append(int(row.get("value", 0)))
		out.offer_generations.append(int(row.get("offer", 0)))
		out.choice_indices.append(int(row.get("choice", -1)))
		out.gate_ids.append(-1)
	return out


func _batch(instance_id: int, program_key: String, level: int,
		active: bool) -> Dictionary:
	var batch := {}
	batch["instance_ids"] = PackedInt64Array([instance_id])
	batch["program_keys"] = PackedStringArray([program_key])
	batch["generations"] = PackedInt32Array([1])
	batch["source_types"] = PackedInt32Array([0])
	batch["source_ids"] = PackedInt64Array([7])
	batch["source_handles"] = PackedInt64Array([7])
	batch["target_handles"] = PackedInt64Array([4242])
	batch["target_generations"] = PackedInt32Array([1])
	batch["levels"] = PackedInt32Array([level])
	batch["next_due_days"] = PackedInt64Array([0])
	batch["active"] = PackedByteArray([1 if active else 0])
	return batch


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if not ok:
		_fail(label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("[FAIL] %s" % label)
