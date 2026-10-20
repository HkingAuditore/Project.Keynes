extends SceneTree

## L0-1 acceptance: the metric selection set addresses 256 ids, and the
## catalogue can no longer declare more metrics than the economy computes.
##
## Why this exists
## ---------------
## `metric_mask` used to be a bare `uint64_t`, so `EffectRuntime::configure`
## rejected any program whose METRIC_* condition or READ_METRIC instruction named
## an id past 63 with `effect_metric_mask_overflow`. That ceiling was an accident
## of the container type, not a design decision -- and the build redesign pushes
## the metric table past 64, so every card above the old ceiling was unloadable.
##
## Two things are proved here:
##
##  1. `MetricMask` really does address ids 64..255 (delegated to the C++ self
##     check, because the economy's metric *table* is still 51 rows and so a
##     GDScript-level catalog cannot reach id 64 yet).
##
##  2. The replacement ceiling is `NativeEconomyRuntime::FAMILY_METRIC_COUNT`,
##     enforced by an explicit contract instead of an undocumented 64-bit
##     coincidence. A catalogue that declares 52 metric keys is rejected with
##     `effect_metric_count_exceeds_economy`, because the 52nd id would never be
##     sampled and its conditions would sit silently false forever -- the exact
##     failure mode the metric-publish work (L0-2) removed.
##
## The boundary is read from `domain.metric_keys.size()`, not written down here,
## so growing the table (L0-1 content side) does not need this file edited. It
## moved 50 -> 51 when `cell.terrain` landed; that required changing zero
## assertions.
##
## Deliberately NOT proved here: that a card on id 64 fires. That needs the
## metric table itself to grow, which is content (X9..X14): the enum, the fill
## branch in `fill_family_behavior_metrics`, `FAMILY_METRIC_COUNT` and
## `effect_domain_catalog.gd:metric_keys` all move together. The contract below
## is what makes that step safe to take.

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectDomainCatalogScript = preload("res://scripts/effect/effect_domain_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")

const OP_METRIC_GTE := 2
const OP_CONST := 1
const OP_EMIT_COMMAND := 11
## `ModifierRuntime::ECONOMY`, required by a managed cell-domain definition.
const MODIFIER_DOMAIN_ECONOMY := 2
const TEST_MODIFIER_KEY := "economy.city.output_factor"
const SEL_OWNER := 0
const DOMAIN_SETTLEMENT_CELL := 2

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("metric mask capacity: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[SKIP] DCWorldExt unavailable")
		return
	_test_mask_capacity()
	_test_authoritative_table()
	_test_catalog_contract()


## Pure value-type assertions live in C++ (`metric_mask_tests.cpp`): the mask is
## a bit container, and its capacity cannot be observed from GDScript while the
## metric table is short.
func _test_mask_capacity() -> void:
	if not ClassDB.class_has_method("DCWorldExt", "runtime_metric_mask_self_test"):
		_expect("runtime_metric_mask_self_test is exported", false)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("MetricMask self check passes",
		bool(ext.call("runtime_metric_mask_self_test")))


## The declared table is the authority for what an id *means*; the economy's
## FAMILY_METRIC_COUNT is the authority for what can be *computed*. They are the
## same length and the contract holds.
func _test_authoritative_table() -> void:
	var domain: Resource = EffectDomainCatalogScript.build()
	_expect("effect domain catalog builds", domain != null)
	if domain == null:
		return
	var keys: PackedStringArray = domain.metric_keys
	_expect("authoritative metric table is non-empty", not keys.is_empty())
	_expect("metric ids stay densely ordered from 0", not keys.is_empty() and
		String(keys[0]) == "family.magnitude_q16")
	_expect("cell.population keeps id 9", keys.size() > 9 and
		String(keys[9]) == "cell.population")

	var catalog: Dictionary = domain.compile_native_catalog()
	_expect("effect domain catalog compiles", bool(catalog.get("ok", false)),
		str(catalog.get("reason", "")))
	if not bool(catalog.get("ok", false)):
		return
	var declared: PackedStringArray = catalog.get("metric_keys", PackedStringArray())
	_expect("compiled catalog carries the declared table",
		declared.size() == keys.size())


## The contract: a catalogue may not declare an id the sampler cannot compute.
## Without this the surplus id would compile fine and then never publish.
func _test_catalog_contract() -> void:
	var domain: Resource = EffectDomainCatalogScript.build()
	if domain == null:
		return
	var computed: int = domain.metric_keys.size()

	# Exactly the computed table: accepted, and a condition on the last id is
	# legal -- that is the boundary the old 64 ceiling used to cut through.
	var edge := _configure(_catalog_with_metric_count(computed,
		_metric_program(computed - 1)))
	if _require("catalog at the computed count configures",
			not edge.is_empty(), str(edge)):
		_expect("last declared id is accepted", bool(edge.get("ok", false)),
			str(edge))

	# One past it: rejected, with a reason that names the contract.
	var over := _catalog_with_metric_count(computed + 1,
		_metric_program(computed - 1))
	var rejected := _configure(over)
	_expect("catalog one metric past the computed count is rejected",
		not bool(rejected.get("ok", false)), str(rejected))
	_expect("rejection names the metric capacity contract",
		String(rejected.get("reason", "")) == "effect_metric_count_exceeds_economy",
		str(rejected))
	_expect("rejection reports both sides of the boundary",
		int(rejected.get("declared_metrics", -1)) == computed + 1
		and int(rejected.get("computed_metrics", -1)) == computed,
		str(rejected))


## Builds an Effect catalog declaring `metric_count` ids (padded with inert
## names) plus `program`, then hands it to a fresh world.
func _configure(catalog: Resource) -> Dictionary:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	return ext.configure_effects(catalog.compile_native_catalog())


func _catalog_with_metric_count(metric_count: int, program: Resource) -> Resource:
	var catalog: Resource = EffectCatalogScript.new()
	var keys := PackedStringArray()
	keys.resize(metric_count)
	for index in range(metric_count):
		keys[index] = "fixture.metric_%d" % index
	catalog.metric_keys = keys
	var definitions: Array[Resource] = []
	var registry: Resource = EffectDefinitionScript.new()
	registry.key = &"ideology.command"
	registry.cadence_days = 3650
	var end := EffectInstruction.new()
	end.op = 12
	var registry_instructions: Array[Resource] = [end]
	registry.instructions = registry_instructions
	var template: Resource = EffectCommandScript.new()
	template.action = 1
	template.domain = MODIFIER_DOMAIN_ECONOMY
	template.opcode = 1
	template.target_resolver = 1
	template.value_mode = 0
	template.command_key = &"ideology.persistent"
	template.definition_key = StringName(TEST_MODIFIER_KEY)
	var registry_commands: Array[Resource] = [template]
	registry.commands = registry_commands
	definitions.append(registry)
	var definition: Resource = program.to_effect_definition()
	if definition.commands.size() > 0:
		definition.commands[0].definition_key = StringName(TEST_MODIFIER_KEY)
		definition.commands[0].domain = MODIFIER_DOMAIN_ECONOMY
	definitions.append(definition)
	catalog.definitions = definitions
	return catalog


## A managed cell-domain program that conditions on `metric_id` and emits one
## command, so the definition passes every validation except the one under test.
func _metric_program(metric_id: int) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = StringName("l0_1_metric_capacity")
	program.target_domain = DOMAIN_SETTLEMENT_CELL
	program.target_selector_kind = SEL_OWNER
	program.cadence_days = 1
	var condition: Resource = EffectConditionScript.new()
	condition.op = OP_METRIC_GTE
	condition.arg0 = metric_id
	condition.value_q16 = 0
	var conditions: Array[Resource] = [condition]
	program.conditions = conditions
	var constant: Resource = EffectInstructionScript.new()
	constant.op = OP_CONST
	constant.value_q16 = 65536
	var emit: Resource = EffectInstructionScript.new()
	emit.op = OP_EMIT_COMMAND
	emit.arg0 = 0
	var instructions: Array[Resource] = [constant, emit]
	program.instructions = instructions
	var command: Resource = EffectCommandScript.new()
	command.action = 1
	command.domain = MODIFIER_DOMAIN_ECONOMY
	command.opcode = 1
	command.target_resolver = 1
	command.value_mode = 1
	command.value_q16 = 65536
	command.duration_days = -1
	command.stacks = 1
	command.command_key = &"ideology.persistent"
	command.definition_key = StringName(TEST_MODIFIER_KEY)
	var commands: Array[Resource] = [command]
	program.commands = commands
	return program


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		push_error("[FAIL] %s" % label)
	else:
		push_error("[FAIL] %s (%s)" % [label, detail])


func _require(label: String, condition: bool, detail: String = "") -> bool:
	_expect(label, condition, detail)
	return condition
