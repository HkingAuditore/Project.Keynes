extends SceneTree

const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const ModifierFacadeScript = preload("res://scripts/modifier/modifier_facade.gd")

var _failures := 0

func _init() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("effect_native_multidomain_transaction_test: SKIP (DCWorldExt unavailable)")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	ext.create_entities(1)
	var modifier := ModifierFacadeScript.new()
	_require(bool(modifier.configure(ext, 1).get("ok", false)), "modifier configure")
	var gameplay_handle := int(ext.register_gameplay_modifier_object(
		"effect_native_multidomain_transaction_test"))
	_require(gameplay_handle != 0, "gameplay target allocate")
	_require(bool(ext.configure_effects(_catalog().compile_native_catalog()).get("ok", false)),
		"effect configure")
	_require(bool(ext.submit_effect_instances({
		"instance_ids": PackedInt64Array([90001]),
		"program_keys": PackedStringArray(["native.multidomain"]),
		"generations": PackedInt32Array([1]),
		"source_types": PackedInt32Array([0x4d554c54]),
		"source_ids": PackedInt64Array([77]),
		"source_handles": PackedInt64Array([gameplay_handle]),
		"target_handles": PackedInt64Array([gameplay_handle]),
		"target_generations": PackedInt32Array([int(gameplay_handle >> 32)]),
		"levels": PackedInt32Array([0]),
		"next_due_days": PackedInt64Array([0]),
		"active": PackedByteArray([1]),
	}).get("ok", false)), "effect instance submit")
	_require(bool(ext.run_effect_daily(0).get("ok", false)), "effect evaluate")

	var planned: Dictionary = ext.poll_effect_transactions(0, 8)
	_require(int(planned.get("count", 0)) == 1, "one mixed transaction planned")
	# Adapter bits are action-owned: Modifier, Gameplay, PublishEvent, Custom.
	_require(int(planned.required_ack_masks[0]) == 57,
		"mixed transaction has four non-aliasing adapter ACK bits")
	var modifier_dispatch: Dictionary = ext.dispatch_effect_native_modifier()
	var gameplay_dispatch: Dictionary = ext.dispatch_effect_native_gameplay()
	_require(int(modifier_dispatch.get("submitted_transactions", 0)) == 1 and
		int(modifier_dispatch.get("submitted_commands", 0)) == 1,
		"Modifier adapter claims only its command")
	_require(int(gameplay_dispatch.get("submitted_transactions", 0)) == 1 and
		int(gameplay_dispatch.get("submitted_commands", 0)) == 3,
		"Gameplay boundary claims Gameplay/Event/Custom commands together")
	var hidden: Dictionary = ext.poll_effect_transactions(0, 8)
	_require(int(hidden.get("count", 0)) == 0 and
		int(hidden.get("native_claimed_transactions", 0)) == 1,
		"mixed native transaction never leaks to GDScript fallback")

	_require(bool(ext.run_modifier_daily(0).get("ok", false)), "Modifier safe boundary")
	var modifier_ack: Dictionary = ext.ack_effect_native_modifier()
	_require(int(modifier_ack.get("acknowledged", 0)) == 1,
		"Modifier adapter ACKs its domain: %s" % str(modifier_ack))
	_require(int(ext.get_effect_report().get("transactions_acked", 0)) == 0,
		"transaction remains pending for gameplay domains")
	_require(int(ext.dispatch_effect_native_modifier().get("submitted_transactions", 0)) == 0,
		"completed Modifier domain is not replayed while other domains wait")

	var gameplay_commit: Dictionary = ext.run_gameplay_effects(0)
	_require(bool(gameplay_commit.get("ok", false)) and
		int(gameplay_commit.get("committed", 0)) == 3,
		"Gameplay/Event/Custom commands commit exactly once")
	var gameplay_ack: Dictionary = ext.ack_effect_native_gameplay()
	_require(int(gameplay_ack.get("acknowledged", 0)) == 1,
		"gameplay boundary completes the mixed transaction: %s" % str(gameplay_ack))
	_require(int(ext.get_effect_report().get("transactions_acked", 0)) == 1,
		"transaction ACKs only after every adapter bit")
	_require(int(ext.run_gameplay_effects(0).get("committed", 0)) == 0,
		"gameplay journal does not replay committed commands")

	print("effect_native_multidomain_transaction_test: %s" %
		("PASS" if _failures == 0 else "FAIL"))
	quit(0 if _failures == 0 else 1)

func _catalog() -> Resource:
	var catalog := EffectCatalogScript.new()
	catalog.max_instances = 16
	catalog.max_transactions = 16
	var definition := EffectDefinitionScript.new()
	definition.key = &"native.multidomain"
	definition.cadence_days = 3650
	var constant := EffectInstructionScript.new()
	constant.op = 1 # CONST
	constant.value_q16 = 65536
	definition.instructions.append(constant)
	for command_index in range(4):
		var emit := EffectInstructionScript.new()
		emit.op = 11 # EMIT_COMMAND
		emit.arg0 = command_index
		definition.instructions.append(emit)
	var end := EffectInstructionScript.new()
	end.op = 12
	definition.instructions.append(end)
	definition.commands = [
		_command(1, 3, 1, "native.multidomain.modifier", "gameplay.generic.bonus"),
		_command(4, 3, 8001, "native.multidomain.gameplay", "native.multidomain.gameplay"),
		_command(5, 4, 7001, "native.multidomain.event", "native.multidomain.event"),
		_command(6, 6, 1, "native.multidomain.custom", "native.multidomain.custom"),
	]
	catalog.definitions = [definition]
	return catalog

func _command(action: int, domain: int, opcode: int,
		command_key: String, definition_key: String) -> Resource:
	var command := EffectCommandScript.new()
	command.action = action
	command.domain = domain
	command.opcode = opcode
	command.target_resolver = 1
	command.value_mode = 1
	command.duration_days = -1
	command.stacks = 1
	command.command_key = StringName(command_key)
	command.definition_key = StringName(definition_key)
	return command

func _require(condition: bool, label: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[FAIL] %s" % label)
