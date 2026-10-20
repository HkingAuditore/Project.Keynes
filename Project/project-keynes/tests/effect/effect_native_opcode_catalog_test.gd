extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

var _checks := 0
var _failures := 0

func _init() -> void:
	_run()
	print("effect_native_opcode_catalog_test: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("effect_native_opcode_catalog_test: SKIP (DCWorldExt unavailable)")
		return
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("country catalog compiles", bool(country_ir.get("ok", false)))
	if not bool(country_ir.get("ok", false)):
		return
	_expect("all Country/Economy opcode templates compile and configure",
			_configure(_valid_catalog(country_ir)))
	_expect("invalid Country opcode rejected at catalog compile",
			_compile_reason(_catalog_with_invalid(2, 1, 15), "effect_country_opcode_unregistered"))
	_expect("invalid Economy opcode rejected at catalog compile",
			_compile_reason(_catalog_with_invalid(3, 2, 16), "effect_economy_opcode_unregistered"))
	_expect("unregistered Gameplay domain rejected at catalog compile",
			_compile_reason(_catalog_with_invalid(4, 4, 1), "effect_gameplay_opcode_unregistered"))
	_expect("unregistered CustomDomain rejected at catalog compile",
			_compile_reason(_catalog_with_invalid(6, 7, 1), "effect_custom_domain_adapter_unregistered"))
	var static_target := _catalog_with_invalid(2, 1, 1)
	var static_definition: EffectDefinition = static_target.definitions[0]
	var static_command: EffectCommand = static_definition.commands[0]
	static_command.target_resolver = 0
	static_command.static_target = 0
	_expect("missing static target rejected at catalog compile",
			_compile_reason(static_target, "effect_command_static_target_invalid"))

func _configure(catalog: Resource) -> bool:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var country_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	var country := country_ir.duplicate(true)
	country.erase("ok")
	if not bool(ext.configure_country(country, {"country_runtime_mode": "ACTIVE"}, 1, 991).get("ok", false)):
		return false
	if not bool(ext.bootstrap_country({}, PackedByteArray([0])).get("ok", false)):
		return false
	return bool(ext.configure_effects(catalog.compile_native_catalog()).get("ok", false))

func _compile_reason(catalog: Resource, expected: String) -> bool:
	var compiled: Dictionary = catalog.compile_native_catalog()
	return not bool(compiled.get("ok", false)) and String(compiled.get("reason", "")) == expected

func _valid_catalog(country_ir: Dictionary) -> Resource:
	var catalog := EffectCatalogScript.new()
	catalog.max_instances = 128
	catalog.max_transactions = 128
	catalog.metric_keys = PackedStringArray()
	var definition := EffectDefinitionScript.new()
	definition.key = &"native.opcode.coverage"
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [end]
	for opcode in range(1, 15):
		definition.commands.append(_command(2, 1, opcode, "country.%d" % opcode))
	for opcode in range(1, 16):
		definition.commands.append(_command(3, 2, opcode, "economy.%d" % opcode))
	definition.commands.append(_command(4, 3, 1, "gameplay.1"))
	definition.commands.append(_command(5, 4, 7001, "event.7001"))
	definition.commands.append(_command(6, 6, 1, "custom.audit"))
	catalog.definitions = [definition]
	return catalog

func _catalog_with_invalid(action: int, domain: int, opcode: int) -> Resource:
	var catalog := EffectCatalogScript.new()
	var definition := EffectDefinitionScript.new()
	definition.key = &"native.opcode.invalid"
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [end]
	definition.commands = [_command(action, domain, opcode, "invalid.command")]
	catalog.definitions = [definition]
	return catalog

func _command(action: int, domain: int, opcode: int, key: String) -> Resource:
	var command := EffectCommandScript.new()
	command.action = action
	command.domain = domain
	command.opcode = opcode
	command.target_resolver = 1
	command.value_mode = 0
	command.command_key = StringName(key)
	command.definition_key = StringName(key)
	return command

func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("  [OK] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)
