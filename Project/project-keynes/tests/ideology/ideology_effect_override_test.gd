extends SceneTree

## L3-9 (first slice) acceptance: the program override layer.
##
## Why this exists
## ---------------
## A program's shape -- duration, stack cap, cadence, priority -- is frozen into
## `FamilyEffectMetadataPod` at catalog compile time, with no way for another
## card to change it. "命名协同" (§6.2) is exactly that: card A changes card B's
## rule. The compile-time half is this layer: an authored table of
## "program X, field F becomes V" applied while programs are translated into
## EffectDefinitions.
##
## What is pinned here
## -------------------
##  1. The rules: target must exist, field must be known, and the value must be
##     one the program itself would accept -- an override must not be able to
##     smuggle in a value `IdeologyEffectDefinition.validate()` would reject.
##  2. Duplicates are rejected, because two overrides of one field make the
##     result depend on array order.
##  3. Application: the override lands on the EffectDefinition the runtime will
##     actually read, and a non-matching target changes nothing.
##  4. End to end through `EffectDomainCatalog.build()`: a catalog with an
##     override compiles, and the compiled program carries the overridden value.

const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("ideology effect override: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_row_rules()
	_test_catalog_rules()
	_test_application()
	_test_end_to_end()


## 1. Row-level rules. The ranges mirror `IdeologyEffectDefinition.validate()`
##    on purpose: an override is applied AFTER that validation, so it is the one
##    path through which an invalid value could reach the runtime.
func _test_row_rules() -> void:
	var row := _row(&"probe", IdeologyEffectParameterScript.Field.DURATION_DAYS, 30)
	_expect("a well-formed row validates", row.validate().is_empty(), row.validate())
	_expect("the row reports its field key", String(row.field_key()) == "duration_days",
		String(row.field_key()))

	var no_target := _row(&"", IdeologyEffectParameterScript.Field.DURATION_DAYS, 30)
	_expect("a row without a target is rejected",
		no_target.validate() == "ideology_effect_parameter_target_missing",
		no_target.validate())

	var bad_field := _row(&"probe", 99, 1)
	_expect("an unknown field is rejected",
		bad_field.validate() == "ideology_effect_parameter_field_invalid",
		bad_field.validate())

	# duration 0 means "no duration" which the program rejects for a DURATION
	# lifecycle; -2 is below the only legal sentinel.
	for bad_duration in [0, -2]:
		var duration_row := _row(&"probe",
			IdeologyEffectParameterScript.Field.DURATION_DAYS, bad_duration)
		_expect("duration %d is rejected" % bad_duration,
			duration_row.validate() == "ideology_effect_parameter_duration_invalid",
			duration_row.validate())

	var zero_stacks := _row(&"probe",
		IdeologyEffectParameterScript.Field.MAX_STACKS, 0)
	_expect("a zero stack cap is rejected",
		zero_stacks.validate() == "ideology_effect_parameter_max_stacks_invalid",
		zero_stacks.validate())
	# 256 is the program's own ceiling; 257 must not pass just because it came
	# through the override path.
	var huge_stacks := _row(&"probe",
		IdeologyEffectParameterScript.Field.MAX_STACKS, 257)
	_expect("a stack cap above the program ceiling is rejected",
		huge_stacks.validate() == "ideology_effect_parameter_max_stacks_invalid",
		huge_stacks.validate())

	var zero_cadence := _row(&"probe",
		IdeologyEffectParameterScript.Field.CADENCE_DAYS, 0)
	_expect("a zero cadence is rejected",
		zero_cadence.validate() == "ideology_effect_parameter_cadence_invalid",
		zero_cadence.validate())


## 2. Catalog-level rules. An override aimed at a program nobody declared is a
##    typo that would silently apply to nothing, which is the failure mode this
##    whole layer has to avoid.
func _test_catalog_rules() -> void:
	var catalog: Resource = IdeologyEffectCatalogScript.new()
	var programs: Array[Resource] = [_program(&"probe")]
	var overrides: Array[Resource] = [
		_row(&"probe", IdeologyEffectParameterScript.Field.DURATION_DAYS, 30)]
	catalog.effects = programs
	catalog.overrides = overrides
	_expect("a catalog with a matching override validates",
		catalog.validate().is_empty(), catalog.validate())

	overrides[0] = _row(&"nowhere", IdeologyEffectParameterScript.Field.DURATION_DAYS, 30)
	_expect("an override targeting an unknown program is rejected by name",
		catalog.validate() == "ideology_effect_catalog_override_target_unknown:nowhere",
		catalog.validate())

	overrides[0] = _row(&"probe", IdeologyEffectParameterScript.Field.DURATION_DAYS, 30)
	overrides.append(_row(&"probe",
		IdeologyEffectParameterScript.Field.DURATION_DAYS, 60))
	_expect("two overrides of the same field are rejected",
		catalog.validate() == "ideology_effect_catalog_override_duplicate:"
			+ "probe.duration_days", catalog.validate())

	# Different fields of the same program are the normal case and must pass.
	overrides.remove_at(1)
	overrides.append(_row(&"probe", IdeologyEffectParameterScript.Field.PRIORITY, 5))
	_expect("two different fields of one program both apply",
		catalog.validate().is_empty(), catalog.validate())


## 3. Application. The assertion that matters: the value lands on the
##    EffectDefinition the runtime reads, not on a copy nobody consults.
func _test_application() -> void:
	var catalog: Resource = IdeologyEffectCatalogScript.new()
	var programs: Array[Resource] = [_program(&"probe")]
	var overrides: Array[Resource] = [
		_row(&"probe", IdeologyEffectParameterScript.Field.DURATION_DAYS, 45),
		_row(&"probe", IdeologyEffectParameterScript.Field.CADENCE_DAYS, 3),
	]
	catalog.effects = programs
	catalog.overrides = overrides
	var definition: Resource = programs[0].to_effect_definition()
	_expect("the program's own duration is authored at 10",
		int(definition.duration_days) == 10, str(definition.duration_days))
	var error: String = catalog.apply_overrides(definition, &"probe")
	_expect("applying overrides succeeds", error.is_empty(), error)
	_expect("the duration override lands on the emitted definition",
		int(definition.duration_days) == 45, str(definition.duration_days))
	_expect("the cadence override lands too",
		int(definition.cadence_days) == 3, str(definition.cadence_days))
	# Fields nobody overrode must keep the program's own value: an override layer
	# that also rewrote unrelated fields would make every diff unreadable.
	_expect("an untouched field keeps the program's value",
		int(definition.max_stacks) == 1 and int(definition.priority) == 0,
		"%d / %d" % [int(definition.max_stacks), int(definition.priority)])

	# Targeting a different program must be a no-op, not a partial application.
	var other: Resource = _program(&"other").to_effect_definition()
	catalog.apply_overrides(other, &"other")
	_expect("overrides aimed at another program change nothing",
		int(other.duration_days) == 10 and int(other.cadence_days) == 1,
		"%d / %d" % [int(other.duration_days), int(other.cadence_days)])


## 4. End to end. `EffectDomainCatalog.build()` is the only caller that matters,
##    and it must both accept a valid override and reject an invalid one before a
##    single program reaches the runtime.
func _test_end_to_end() -> void:
	var override_catalog: Resource = IdeologyEffectCatalogScript.new()
	var programs: Array[Resource] = [_program(&"probe")]
	var overrides: Array[Resource] = [
		_row(&"probe", IdeologyEffectParameterScript.Field.DURATION_DAYS, 45)]
	override_catalog.effects = programs
	override_catalog.overrides = overrides
	# `build()` reads the default catalog when no override is given; passing an
	# explicit resource is the documented test injection point (see §29.6).
	var built: Resource = EffectDomainCatalogScript.build(null, override_catalog)
	_expect("the effect catalog builds with an override catalog", built != null)
	if built == null:
		return
	# Read the compiled program back as a resource rather than through the native
	# dict: the claim under test is "the value the runtime receives", and the
	# resource is what the native compiler reads.
	var emitted: Resource = null
	for candidate in built.definitions:
		if candidate != null and String(candidate.key) == "ideology.effect.probe":
			emitted = candidate
			break
	_expect("the overridden program reaches the built catalog", emitted != null)
	if emitted != null:
		_expect("the built program carries the overridden duration",
			int(emitted.duration_days) == 45, str(emitted.duration_days))
		_expect("the built program keeps the un-overridden cadence",
			int(emitted.cadence_days) == 1, str(emitted.cadence_days))
		var compiled: Dictionary = built.compile_native_catalog()
		_expect("the built catalog still compiles natively",
			bool(compiled.get("ok", false)), str(compiled.get("reason", "")))

	# An out-of-range override must fail the build rather than reach native.
	overrides[0] = _row(&"probe", IdeologyEffectParameterScript.Field.MAX_STACKS, 999)
	# `build()` rejects by returning null and pushing the reason to the log
	# (`_reject`), so "no catalog was produced" is the observable fact here. The
	# reason string itself is asserted at the row level in `_test_row_rules`.
	var rejected: Resource = EffectDomainCatalogScript.build(null, override_catalog)
	_expect("an invalid override fails the build instead of reaching native",
		rejected == null)


func _row(target: StringName, field: int, value: int) -> Resource:
	var row: Resource = IdeologyEffectParameterScript.new()
	row.target_definition_key = target
	row.field = field
	row.value = value
	return row


## Minimal but valid program: DURATION lifecycle so the duration field is
## meaningful, one instruction and one command so `validate()` passes.
func _program(key: StringName) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = key
	program.target_domain = IdeologyEffectDefinitionScript.TargetDomain.COUNTRY
	program.operation = IdeologyEffectDefinitionScript.Operation.MULTIPLY
	program.lifecycle = IdeologyEffectDefinitionScript.Lifecycle.DURATION
	program.duration_days = 10
	program.stack_policy = IdeologyEffectDefinitionScript.StackPolicy.REPLACE
	program.stack_key = key
	program.max_stacks = 1
	program.priority = 0
	program.cadence_days = 1
	var instruction: Resource = EffectInstructionScript.new()
	instruction.op = 1
	instruction.value_q16 = 104858
	var instruction_list: Array[Resource] = [instruction]
	program.instructions = instruction_list
	var command: Resource = EffectCommandScript.new()
	command.action = 1
	command.domain = 1
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 1
	command.value_q16 = 104858
	command.duration_days = -1
	command.stacks = 1
	command.command_key = &"ideology.persistent"
	command.definition_key = key
	var command_list: Array[Resource] = [command]
	program.commands = command_list
	return program


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("[FAIL] %s" % label)
	else:
		print("[FAIL] %s (%s)" % [label, detail])
