extends SceneTree

## M1 acceptance for the ideology Effect-instance path.
##
## A card effect row whose `definition_key` names a declared
## `ideology.effect.<key>` program is no longer fired as a one-shot Modifier
## batch. It becomes a reconciled Effect instance that can carry conditions,
## a cadence and (from M2) a target selector. This test proves the plumbing:
## the program compiles as a managed program, the reconciliation is idempotent,
## conditions actually gate the command, and the instance set survives save/load.

const CountryCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")
const Q16_ONE := 65536

## Mirrors `IdeologyEffectDefinition.program_key()`.
const PROGRAM_KEY := "ideology.effect.v1_granary_belt"
## The authored card row that routes through the program.
const CARD_DEFINITION_KEY := "v1_granary_belt"
## Modifier the program drives. The fixture uses a key the test ModifierRuntime
## already registers; the shipped .tres drives `ideology.agrarian_reform`.
const TEST_MODIFIER_KEY := "country.economic_mobilization"

var _checks := 0
var _failures := 0
var _next_sequence := 1


func _init() -> void:
	_run()
	print("ideology effect instance: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	var content: Resource = IdeologyEffectCatalogScript.load_default()
	_test_content_catalog(content)
	if content == null:
		return
	var defined: Array = content.effects
	if defined.is_empty() or defined[0] == null:
		_expect("content catalog exposes at least one program", false)
		return

	var country_ir: Dictionary = CountryCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(country_ir.get("ok", false)))
	if not bool(country_ir.get("ok", false)):
		return

	var ext: Object = _configured_ext(country_ir, defined[0])
	_test_program_registration(ext)

	var handle := int(ext.get_country_cell_summary(0).get("country_handle", 0))
	_expect("country handle is generation safe", handle != 0)
	_test_instance_lifecycle(ext, handle)
	_test_save_round_trip(country_ir, defined[0])


## ModifierRuntime is required for `dispatch_effect_native_modifier`, which is
## how a program's emitted command becomes observable.
func _configured_ext(country_ir: Dictionary, program_source: Resource) -> Object:
	var ext: Object = _country_ext(country_ir)
	var modifier := ModifierFacadeScript.new()
	_expect("modifier runtime configures",
		bool(modifier.configure(ext, 1).get("ok", false)))
	_expect("effect catalog configures", bool(ext.configure_effects(
		_effect_catalog(program_source).compile_native_catalog()).get("ok", false)))
	_expect("ideology catalog configures", bool(
		ext.configure_ideologies(_ideology_catalog()).get("ok", false)))
	return ext


func _test_content_catalog(content: Resource) -> void:
	_expect("default ideology effect catalog loads", content != null)
	if content == null:
		return
	_expect("default ideology effect catalog validates",
		String(content.validate()).is_empty())
	var keys: Dictionary = content.program_key_set()
	_expect("catalog declares the v1 granary-belt program", keys.has(PROGRAM_KEY))
	_expect("program key is not double-prefixed",
		not keys.has("ideology.effect.ideology.%s" % CARD_DEFINITION_KEY))


func _test_program_registration(ext: Object) -> void:
	_expect("declared program resolves as managed",
		bool(ext.effect_program_is_managed(PROGRAM_KEY)))
	_expect("undefined program is not managed",
		not bool(ext.effect_program_is_managed("ideology.effect.not_a_program")))
	_expect("legacy template registry stays unmanaged",
		not bool(ext.effect_program_is_managed("ideology.command")))


func _test_instance_lifecycle(ext: Object, handle: int) -> void:
	_expect("discover and adopt queue", bool(ext.submit_ideology_commands(
		_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": 0},
			{"op": 5, "day": 0, "handle": handle, "idea": 0},
		])).get("ok", false)))
	_expect("adopt day applies", bool(ext.run_ideology_daily(0).get("ok", false)))
	var level_zero: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("adoption creates exactly one instance",
		int(level_zero.get("count", -1)) == 1)
	if int(level_zero.get("count", -1)) != 1:
		var snapshot: Dictionary = ext.get_ideology_snapshot(handle)
		print("    locations=%s levels=%s last_error=%s" % [
			str(snapshot.get("locations", PackedByteArray())),
			str(snapshot.get("levels", PackedInt32Array())),
			String(snapshot.get("last_error", ""))])
		print("    report=%s" % str(level_zero))
	_expect("instance records the card level",
		int(level_zero.get("idea_levels", PackedInt32Array([-1]))[0]) == 0)
	_expect("instance is owned by the EffectRuntime",
		int(level_zero.get("present", PackedByteArray([0]))[0]) == 1)
	var first_ids: PackedInt64Array = level_zero.get("instance_ids", PackedInt64Array())

	# Level 0 < the program's STATE_GTE(level, 2) condition: the instance exists
	# but must emit nothing.
	_expect("effect day runs", bool(ext.run_effect_daily(0).get("ok", false)))
	var gated: Dictionary = ext.dispatch_effect_native_modifier()
	_expect("condition blocks dispatch below the gated level",
		bool(gated.get("ok", false)) and int(gated.get("submitted_commands", -1)) == 0,
		str(gated))
	ext.ack_effect_native_modifier()

	# Days 1..4 carry the card to level 2. Each level change must converge the
	# instance set instead of accumulating one stale instance per level.
	for day in range(1, 5):
		_expect("ideology day %d applies" % day,
			bool(ext.run_ideology_daily(day).get("ok", false)))
	var promoted: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("level advance does not accumulate instances",
		int(promoted.get("count", -1)) == 1)
	_expect("instance tracks the promoted level",
		int(promoted.get("idea_levels", PackedInt32Array([-1]))[0]) == 2)
	_expect("promoted instance is owned by the EffectRuntime",
		int(promoted.get("present", PackedByteArray([0]))[0]) == 1)
	_expect("instance identity changes when the card level changes",
		int(promoted.get("instance_ids", PackedInt64Array([0]))[0]) != int(
			first_ids[0] if first_ids.size() > 0 else 0))

	_expect("effect day after promotion runs",
		bool(ext.run_effect_daily(4).get("ok", false)))
	var emitted: Dictionary = ext.dispatch_effect_native_modifier()
	_expect("condition lets exactly one command through past the gate",
		bool(emitted.get("ok", false)) and int(emitted.get("submitted_commands", -1)) == 1,
		str(emitted))
	ext.ack_effect_native_modifier()

	# Reconciling again without a level change must be a no-op, which is what
	# makes repeated daily ticks safe.
	var again: Dictionary = ext.get_ideology_effect_instance_report(handle)
	_expect("report is stable across identical reconciles",
		again.get("instance_ids", PackedInt64Array()) == promoted.get("instance_ids",
			PackedInt64Array([0])))


func _test_save_round_trip(country_ir: Dictionary, program_source: Resource) -> void:
	# A dedicated runtime that only adopts the card, so the save carries no
	# in-flight Effect transaction: this test is about the instance set, and a
	# pending transaction would be rejected by PKID's transition audit instead.
	var source: Object = _configured_ext(country_ir, program_source)
	var handle := int(source.get_country_cell_summary(0).get("country_handle", 0))
	_expect("save fixture adopts the card", bool(source.submit_ideology_commands(
		_commands([
			{"op": 1, "day": 0, "handle": handle, "idea": 0},
			{"op": 5, "day": 0, "handle": handle, "idea": 0},
		])).get("ok", false)) and bool(
			source.run_ideology_daily(0).get("ok", false)))
	var expected_ids: PackedInt64Array = source.get_ideology_effect_instance_report(
		handle).get("instance_ids", PackedInt64Array())
	_expect("save fixture holds exactly one instance", expected_ids.size() == 1)
	var effect_bytes: PackedByteArray = source.capture_effect_state()
	var ideology_bytes: PackedByteArray = source.capture_ideology_state()
	_expect("save produces both PKEF and PKID payloads",
		not effect_bytes.is_empty() and not ideology_bytes.is_empty())
	var restored: Object = _configured_ext(country_ir, program_source)
	_expect("PKEF restores first", bool(
		restored.restore_effect_state(effect_bytes).get("ok", false)))
	var ideology_result: Dictionary = restored.restore_ideology_state(ideology_bytes)
	_expect("PKID restores with its Effect instances intact",
		bool(ideology_result.get("ok", false)))
	if not bool(ideology_result.get("ok", false)):
		print("    reason: %s" % String(ideology_result.get("reason", "")))
	var report: Dictionary = restored.get_ideology_effect_instance_report(handle)
	_expect("restored instance count matches",
		int(report.get("count", -1)) == 1)
	var present: PackedByteArray = report.get("present", PackedByteArray())
	_expect("every restored instance is still owned by the EffectRuntime",
		present.size() == 1 and int(present[0]) == 1)
	_expect("restored instance keeps its identity",
		report.get("instance_ids", PackedInt64Array()) == expected_ids)

	# Dropping PKEF must fail loudly instead of leaving the card silently inert.
	var lost: Object = _configured_ext(country_ir, program_source)
	var lost_result: Dictionary = lost.restore_ideology_state(ideology_bytes)
	_expect("PKID rejects a save whose Effect instances are missing",
		not bool(lost_result.get("ok", true))
		and String(lost_result.get("reason", "")) == "ideology_effect_instance_missing")


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
		# Keep the authored condition/instruction shape; only retarget the
		# modifier so this headless fixture can dispatch it.
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
		# One level per ~3 days of understanding, so the gate is observable:
		# day 0..1 stay at level 0, day 2 reaches 1, day 4 reaches 2.
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


func _country_ext(country_ir: Dictionary) -> Object:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var catalog := country_ir.duplicate(true)
	catalog.erase("ok")
	var profile := {
		"country_runtime_mode": "ACTIVE",
		"starting_technology_ids": PackedStringArray(["tech.hunting"]),
	}
	assert(bool(ext.configure_country(catalog, profile, 1, 97).get("ok", false)))
	assert(bool(ext.bootstrap_country({}, PackedByteArray([0])).get("ok", false)))
	return ext


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		if detail.is_empty():
			push_error("[FAIL] %s" % label)
		else:
			push_error("[FAIL] %s (%s)" % [label, detail])
