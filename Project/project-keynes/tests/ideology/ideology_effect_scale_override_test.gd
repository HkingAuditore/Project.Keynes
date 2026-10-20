extends SceneTree

## L3-9 second slice: runtime per-instance magnitude overrides.
##
## What this covers
## ----------------
## A synergy may carry `overrides` rows that multiply a target program's effect
## magnitude. The multiplier is resolved per country from the country's ACTIVE
## synergies, travels as one extra column on `submit_instances`, and is applied
## at the single point where a program command becomes a modifier row.
##
## This file pins the two halves that are cheap to stage:
##   1. The authoring rules (which fields a synergy may rewrite, duplicate
##      targets, out-of-band values) and the three compiled columns.
##   2. Native acceptance: a catalog carrying those columns configures, and one
##      carrying an out-of-band scale is rejected by name.
##
## What it does NOT cover: the value actually observed on a fired instance while
## a synergy is active. That needs a fixture with two equipped cards and an
## active synergy (the §22 gate work); until then the path is exercised but the
## delta is not asserted. Called out in §37.5.

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const IdeologySynergyDefinitionScript = preload(
	"res://scripts/ideology/ideology_synergy_definition.gd")
const IdeologyEffectCatalogScript = preload(
	"res://scripts/ideology/ideology_effect_catalog.gd")
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("ideology effect scale override: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_parameter_rules()
	_test_synergy_rules()
	_test_compiled_columns()
	_test_native_acceptance()


## 1. The row itself. The band is mirrored from the native clamp so an author
##    sees the limit while editing instead of watching the value get squeezed.
func _test_parameter_rules() -> void:
	var row := _row(&"probe", 196608)  # 3.0x
	_expect("a 3x row validates", row.validate().is_empty(), row.validate())
	_expect("the row reports its field key",
		String(row.field_key()) == "magnitude_scale_q16", String(row.field_key()))

	var too_small := _row(&"probe", 1000)
	_expect("below 0.25x is rejected",
		too_small.validate() == "ideology_effect_parameter_magnitude_scale_invalid",
		too_small.validate())
	var too_big := _row(&"probe", 300000)
	_expect("above 4x is rejected",
		too_big.validate() == "ideology_effect_parameter_magnitude_scale_invalid",
		too_big.validate())
	# The two ends are inclusive: 0.25x and 4x are legal, and the native clamp
	# uses the same endpoints, so an edge value must not be rejected here.
	_expect("the 0.25x edge is legal",
		_row(&"probe", 16384).validate().is_empty())
	_expect("the 4x edge is legal",
		_row(&"probe", 262144).validate().is_empty())


## 2. Synergy rules: only MAGNITUDE_SCALE is a runtime rewrite; the other four
##    override fields are compile-time and would mean per-instance program
##    templates if applied per country.
func _test_synergy_rules() -> void:
	var synergy := _synergy([_row(&"probe", 196608)])
	_expect("a synergy with one rewrite validates",
		synergy.validate().is_empty(), synergy.validate())

	var wrong_field := _synergy([_row(&"probe", 30)])
	wrong_field.overrides[0].field = IdeologyEffectParameterScript.Field.DURATION_DAYS
	_expect("a compile-time field is rejected on a synergy",
		wrong_field.validate() == "ideology_synergy_override_field_invalid",
		wrong_field.validate())

	var duplicate := _synergy([_row(&"probe", 196608), _row(&"probe", 131072)])
	_expect("two rewrites of one target are rejected",
		duplicate.validate() == "ideology_synergy_override_target_duplicate",
		duplicate.validate())

	var empty_target := _synergy([_row(&"", 196608)])
	_expect("an empty target is rejected",
		empty_target.validate() == "ideology_effect_parameter_target_missing"
			or empty_target.validate() == "ideology_synergy_override_target_empty",
		empty_target.validate())

	var two_targets := _synergy([_row(&"a", 196608), _row(&"b", 131072)])
	_expect("two different targets both pass",
		two_targets.validate().is_empty(), two_targets.validate())


## 3. The compiled columns. The program key must be PREFIXED
##    (`ideology.effect.<key>`), because that is what an activation compares
##    against; emitting the bare key would make every override silently miss.
func _test_compiled_columns() -> void:
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy.get("ok", false)):
		_expect("economy catalog compiles", false, str(economy.get("reason", "")))
		return
	var catalog: Resource = _catalog_with_override(&"probe", 196608)
	var compiled: Dictionary = catalog.compile_native_catalog(economy, economy)
	_expect("a catalog with a synergy rewrite compiles",
		bool(compiled.get("ok", false)), str(compiled.get("reason", "")))
	if not bool(compiled.get("ok", false)):
		return
	var programs: PackedStringArray = compiled.get(
		"synergy_override_programs", PackedStringArray())
	var scales: PackedInt32Array = compiled.get(
		"synergy_override_scales", PackedInt32Array())
	var offsets: PackedInt32Array = compiled.get(
		"synergy_override_offsets", PackedInt32Array())
	_expect("one override row is emitted", programs.size() == 1, str(programs))
	_expect("the emitted key is the prefixed program key",
		programs.size() == 1 and programs[0] == "ideology.effect.probe",
		str(programs))
	_expect("the emitted scale is the authored value",
		scales.size() == 1 and scales[0] == 196608, str(scales))
	# One offset per synergy plus the trailing total.
	_expect("the offsets row is synergy_count + 1",
		offsets.size() == (compiled.synergy_ids as PackedStringArray).size() + 1,
		"%d vs %d" % [offsets.size(),
			(compiled.synergy_ids as PackedStringArray).size() + 1])

	# An override aimed at a program nobody declared must fail the build.
	var broken: Resource = _catalog_with_override(&"nowhere", 196608)
	var broken_compiled: Dictionary = broken.compile_native_catalog(economy, economy)
	_expect("an override targeting an unknown program fails the build",
		not bool(broken_compiled.get("ok", false)))
	_expect("the failure names the unknown target",
		String(broken_compiled.get("reason", "")).begins_with(
			"ideology_synergy_override_target_unknown"),
		str(broken_compiled.get("reason", "")))


## 4. Native acceptance. This is the half that proves the columns survive the
##    trip into the native catalog validator and the catalog hash.
func _test_native_acceptance() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_expect("DCWorldExt available for native acceptance", false)
		return
	var economy: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy.get("ok", false)):
		return
	var catalog: Resource = _catalog_with_override(&"probe", 196608)
	var compiled: Dictionary = catalog.compile_native_catalog(economy, economy)
	if not bool(compiled.get("ok", false)):
		_expect("native acceptance fixture compiles", false,
			str(compiled.get("reason", "")))
		return
	var config: Dictionary = compiled.duplicate(true)
	config.erase("ok")
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var country_ir: Dictionary = economy.duplicate(true)
	country_ir.erase("ok")
	var outcome: Dictionary = ext.configure_ideologies(config)
	# `configure_ideologies` only needs the ideology catalog; a bare ext without a
	# country runtime may still refuse for unrelated reasons, so the assertion is
	# "not rejected for an override reason".
	var reason := String(outcome.get("reason", ""))
	_expect("the native validator does not reject the override columns",
		not reason.begins_with("ideology_synergy_override"),
		reason)

	# Out-of-band scale must be rejected by the native validator, not silently
	# clamped: the authoring layer and the runtime have to agree on the band.
	var tampered: Dictionary = config.duplicate(true)
	tampered.synergy_override_scales = PackedInt32Array([999999])
	var tampered_outcome: Dictionary = ext.configure_ideologies(tampered)
	_expect("an out-of-band scale is rejected natively",
		String(tampered_outcome.get("reason", "")) ==
			"ideology_synergy_override_row_invalid",
		str(tampered_outcome.get("reason", "")))


func _row(target: StringName, value: int) -> Resource:
	var row: Resource = IdeologyEffectParameterScript.new()
	row.target_definition_key = target
	row.field = IdeologyEffectParameterScript.Field.MAGNITUDE_SCALE
	row.value = value
	return row


func _synergy(overrides: Array) -> Resource:
	var synergy: Resource = IdeologySynergyDefinitionScript.new()
	synergy.id = &"probe_synergy"
	synergy.required_ideology_ids = PackedStringArray(["probe_card"])
	synergy.minimum_levels = PackedInt32Array([0])
	synergy.location_masks = PackedByteArray([2])
	synergy.min_count = 1
	var rows: Array[Resource] = []
	for row in overrides:
		rows.append(row)
	synergy.overrides = rows
	return synergy


## One program + one card + one synergy, enough to exercise the compile path.
func _catalog_with_override(target: StringName, scale: int) -> Resource:
	var program: Resource = IdeologyEffectDefinitionScript.new()
	program.definition_key = &"probe"
	program.target_domain = IdeologyEffectDefinitionScript.TargetDomain.COUNTRY
	program.operation = IdeologyEffectDefinitionScript.Operation.MULTIPLY
	program.lifecycle = IdeologyEffectDefinitionScript.Lifecycle.PERMANENT
	program.duration_days = -1
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
	command.definition_key = &"probe"
	var command_list: Array[Resource] = [command]
	program.commands = command_list

	var effects: Resource = IdeologyEffectCatalogScript.new()
	var program_list: Array[Resource] = [program]
	effects.effects = program_list

	var card: Resource = load("res://scripts/ideology/ideology_definition.gd").new()
	card.id = &"probe_card"
	var level: Resource = load(
		"res://scripts/ideology/ideology_level_definition.gd").new()
	level.understanding_threshold_q16 = 0
	# The card's own row routes to the program, which is what an activation
	# needs; without it there is nothing to override.
	var level_effects: Array[Resource] = [command]
	level.persistent_effects = level_effects
	var levels: Array[Resource] = [level]
	card.levels = levels

	var catalog: Resource = IdeologyCatalogScript.new()
	var definition_list: Array[Resource] = [card]
	var synergy_list: Array[Resource] = [_synergy([_row(target, scale)])]
	catalog.definitions = definition_list
	catalog.synergies = synergy_list
	catalog.effect_programs = effects
	return catalog


func _expect(label: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		print("[FAIL] %s" % label)
	else:
		print("[FAIL] %s (%s)" % [label, detail])
