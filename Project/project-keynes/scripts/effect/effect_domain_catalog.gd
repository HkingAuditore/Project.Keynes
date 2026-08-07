class_name EffectDomainCatalog
extends RefCounted

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const FamilyTraitCatalogScript = preload("res://scripts/family/family_trait_catalog.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")

const Q16_ONE := 65536

## Builds the shared Effect IR from existing authoritative domain catalogs.
## Domain catalogs remain the source of truth; this only creates executable
## programs and never duplicates domain state.
static func build() -> Resource:
	var catalog: Resource = EffectCatalogScript.load_default()
	if catalog == null:
		catalog = EffectCatalogScript.new()
	catalog.metric_keys = PackedStringArray(["family.magnitude_q16"])
	catalog.behavior_command_keys = PackedStringArray()
	var definitions: Array[Resource] = []

	var technology_catalog := TechnologyCatalogScript.compile_native_catalog()
	if not bool(technology_catalog.get("ok", false)):
		return null
	var technology_ids: PackedStringArray = technology_catalog.get(
		"technology_ids", PackedStringArray())
	var technology_modifiers: PackedStringArray = technology_catalog.get(
		"technology_modifier_definition_keys", PackedStringArray())
	var technology_flags: PackedInt32Array = technology_catalog.get(
		"technology_flags", PackedInt32Array())
	var definition_seen := {}
	for i in range(mini(technology_ids.size(), technology_modifiers.size())):
		if i < technology_flags.size() and (int(technology_flags[i]) & TechnologyCatalogScript.FLAG_STARTING) != 0:
			continue
		var modifier_key := String(technology_modifiers[i])
		if modifier_key.is_empty():
			continue
		var program_key := "technology.%s" % String(technology_ids[i])
		if definition_seen.has(program_key):
			continue
		definition_seen[program_key] = true
		definitions.append(_technology_definition(String(technology_ids[i]), modifier_key))

	var economy_catalog := EconomyCatalogScript.compile_native_catalog()
	if bool(economy_catalog.get("ok", false)):
		var trait_catalog = FamilyTraitCatalogScript.load_default()
		if trait_catalog != null:
			var trait_columns: Dictionary = trait_catalog.compile_native_columns(economy_catalog)
			if bool(trait_columns.get("ok", false)):
				var keys: PackedStringArray = trait_columns.get(
					"family_trait_modifier_definition_keys", PackedStringArray())
				var targets: PackedInt32Array = trait_columns.get(
					"family_trait_modifier_targets", PackedInt32Array())
				for i in range(keys.size()):
					if String(keys[i]).is_empty() or (i < targets.size() and int(targets[i]) != 0):
						continue
					var program_key := "family.modifier.%s" % String(keys[i])
					if definition_seen.has(program_key):
						continue
					definition_seen[program_key] = true
					definitions.append(_family_definition(String(keys[i])))

	# Precompile person programs from existing Modifier definitions. The native
	# PERSON_COMMIT producer currently activates the gameplay.generic.bonus
	# program; PersonStore still owns person state and these rows keep stable
	# definition keys out of the native evaluation loop.
	var modifier_catalog_resource: Resource = ModifierCatalogScript.load_default()
	var modifier_catalog: Dictionary = modifier_catalog_resource.compile_native_catalog() \
		if modifier_catalog_resource != null else {"ok": false}
	if bool(modifier_catalog.get("ok", false)):
		var modifier_keys: PackedStringArray = modifier_catalog.get(
			"definition_keys", PackedStringArray())
		var modifier_domains: PackedInt32Array = modifier_catalog.get(
			"definition_domains", PackedInt32Array())
		for i in range(modifier_keys.size()):
			if i >= modifier_domains.size() or int(modifier_domains[i]) not in [2, 3]:
				continue
			var person_program := "person.modifier.%s" % String(modifier_keys[i])
			if definition_seen.has(person_program):
				continue
			definition_seen[person_program] = true
			definitions.append(_person_definition(String(modifier_keys[i]), int(modifier_domains[i])))
		# TriggerRuntime hands typed Modifier actions to EffectRuntime. One
		# executable command row per existing Modifier definition keeps stable
		# definition keys in the cold catalog and avoids runtime string lookup.
		for i in range(modifier_keys.size()):
			if i >= modifier_domains.size():
				continue
			var trigger_modifier_key := String(modifier_keys[i])
			if trigger_modifier_key.is_empty() or int(modifier_domains[i]) < 0 \
					or int(modifier_domains[i]) >= 4:
				continue
			var trigger_program := "trigger.modifier.%s" % trigger_modifier_key
			if definition_seen.has(trigger_program):
				continue
			definition_seen[trigger_program] = true
			definitions.append(_trigger_modifier_definition(
				trigger_modifier_key, int(modifier_domains[i])))
	if not definition_seen.has("person.modifier"):
		definitions.append(_person_definition(""))
	# Ideology owns progression, but its authored command templates must be
	# compiled by EffectRuntime so domain mutation remains ACK-gated there.
	var ideology_catalog: Resource = IdeologyCatalogScript.load_default()
	var ideology_country_catalog := EconomyCatalogScript.compile_native_catalog()
	if ideology_catalog != null and bool(ideology_country_catalog.get("ok", false)):
		var ideology_ir: Dictionary = ideology_catalog.compile_native_catalog(ideology_country_catalog)
		if not bool(ideology_ir.get("ok", false)):
			return null
		definitions.append(_ideology_command_definition(ideology_ir))
	definitions.sort_custom(func(a, b) -> bool: return String(a.key) < String(b.key))
	catalog.definitions = definitions
	return catalog


static func _technology_definition(technology_id: String, modifier_key: String) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("technology.%s" % technology_id)
	definition.version = 1
	definition.cadence_days = 3650
	var constant := EffectInstructionScript.new()
	constant.op = 1 # CONST
	constant.value_q16 = Q16_ONE
	var emit := EffectInstructionScript.new()
	emit.op = 11 # EMIT_COMMAND
	emit.arg0 = 0
	var end := EffectInstructionScript.new()
	end.op = 12 # END
	definition.instructions = [constant, emit, end]
	definition.commands = [_command(1, 1, 1, &"technology.modifier", modifier_key)]
	return definition


static func _family_definition(modifier_key: String) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("family.modifier.%s" % modifier_key)
	definition.version = 1
	definition.cadence_days = 30
	var read := EffectInstructionScript.new()
	read.op = 2 # READ_METRIC
	read.arg0 = 0
	var emit := EffectInstructionScript.new()
	emit.op = 11
	emit.arg0 = 0
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [read, emit, end]
	definition.commands = [_command(1, 2, 1, &"family.modifier", modifier_key)]
	return definition


static func _person_definition(modifier_key: String = "", domain: int = 3) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("person.modifier" if modifier_key.is_empty() else
		"person.modifier.%s" % modifier_key)
	definition.version = 1
	definition.cadence_days = 3650
	var constant := EffectInstructionScript.new()
	constant.op = 1
	constant.value_q16 = Q16_ONE
	var emit := EffectInstructionScript.new()
	emit.op = 11
	emit.arg0 = 0
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions = [constant, emit, end]
	definition.commands = [_command(1, domain, 1, &"person.modifier", modifier_key)]
	return definition


static func _trigger_modifier_definition(modifier_key: String, domain: int) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = StringName("trigger.modifier.%s" % modifier_key)
	definition.version = 1
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12 # END; Trigger handoff emits the typed command directly.
	definition.instructions = [end]
	definition.commands = [_command(1, domain, 1, &"trigger.modifier", modifier_key)]
	return definition


static func _ideology_command_definition(ideology_ir: Dictionary) -> Resource:
	var definition := EffectDefinitionScript.new()
	definition.key = &"ideology.command"
	definition.version = 1
	definition.cadence_days = 3650
	var end := EffectInstructionScript.new()
	end.op = 12 # External ideology ingress owns firing; this program is a template registry.
	definition.instructions = [end]
	for prefix in ["persistent", "on_enter"]:
		var actions: PackedInt32Array = ideology_ir.get("%s_actions" % prefix, PackedInt32Array())
		var domains: PackedInt32Array = ideology_ir.get("%s_domains" % prefix, PackedInt32Array())
		var opcodes: PackedInt32Array = ideology_ir.get("%s_opcodes" % prefix, PackedInt32Array())
		var values: PackedInt64Array = ideology_ir.get("%s_values_q16" % prefix, PackedInt64Array())
		var durations: PackedInt32Array = ideology_ir.get("%s_duration_days" % prefix, PackedInt32Array())
		var stacks: PackedInt32Array = ideology_ir.get("%s_stacks" % prefix, PackedInt32Array())
		var keys: PackedStringArray = ideology_ir.get("%s_command_keys" % prefix, PackedStringArray())
		var definitions: PackedStringArray = ideology_ir.get("%s_definition_keys" % prefix, PackedStringArray())
		var i0: PackedInt64Array = ideology_ir.get("%s_payload_i0" % prefix, PackedInt64Array())
		var i1: PackedInt64Array = ideology_ir.get("%s_payload_i1" % prefix, PackedInt64Array())
		var i2: PackedInt64Array = ideology_ir.get("%s_payload_i2" % prefix, PackedInt64Array())
		var i3: PackedInt64Array = ideology_ir.get("%s_payload_i3" % prefix, PackedInt64Array())
		for i in actions.size():
			if i >= domains.size() or i >= opcodes.size() or i >= values.size() \
					or i >= durations.size() or i >= stacks.size() or i >= keys.size() \
					or i >= definitions.size():
				return EffectDefinitionScript.new() # configure will reject the empty key.
			var command := EffectCommandScript.new()
			command.action = actions[i]
			command.domain = domains[i]
			command.opcode = opcodes[i]
			command.target_resolver = 1
			command.value_mode = 0
			command.value_q16 = values[i]
			command.duration_days = durations[i]
			command.stacks = stacks[i]
			command.command_key = StringName(keys[i])
			command.definition_key = StringName(definitions[i])
			command.payload_i0 = i0[i] if i < i0.size() else 0
			command.payload_i1 = i1[i] if i < i1.size() else 0
			command.payload_i2 = i2[i] if i < i2.size() else 0
			command.payload_i3 = i3[i] if i < i3.size() else 0
			definition.commands.append(command)
	return definition


static func _command(action: int, domain: int, opcode: int,
		command_key: StringName, definition_key: String) -> Resource:
	var command := EffectCommandScript.new()
	command.action = action
	command.domain = domain
	command.opcode = opcode
	command.target_resolver = 1 # TARGET_INSTANCE
	command.value_mode = 1 # VALUE_STACK_TOP
	command.duration_days = -1
	command.stacks = 1
	command.command_key = command_key
	command.definition_key = StringName(definition_key)
	return command
