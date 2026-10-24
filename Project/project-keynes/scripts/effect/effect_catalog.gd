class_name EffectCatalog
extends Resource

const DEFAULT_PATH := "res://data/effects/default_effect_catalog.tres"
const EffectDefinitionScript = preload("res://scripts/effect/effect_definition.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const EffectInstructionScript = preload("res://scripts/effect/effect_instruction.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

const PROTOCOL_VERSION := 1
const Q16_ONE := 65536

## The worker Effect POD is a restricted subset of the main-thread EffectRuntime
## (gdext/src/runtime_effect_pod.cpp:300-400). Its validation is catalog-wide:
## one unsupported program makes the whole POD catalog refuse to configure,
## which in turn leaves the EFFECT bit incomplete and stops the entire
## twelve-domain authority graph from ever being granted. So a definition the
## POD cannot express must be excluded from the POD payload instead of
## poisoning it. The main thread keeps every definition either way.
## Mirrors POD_MAX_SELECTOR_KIND / POD_MAX_STATE_ID in
## gdext/src/runtime_effect_pod.cpp. The POD never resolves a selector itself
## (the main thread resolves cells and passes a target_handle) and reads state
## through one shared switch, so both ceilings track the main thread's, not a
## narrower subset. Keep the two files in step.
const POD_MAX_SELECTOR_KIND := 17
## 5 = STATE_LATCHED (previous evaluation's condition result). Ids are
## append-only on both sides; bumping this without the matching case in
## RuntimeEffectPodAuthority::state_value trips
## `effect_pod_state_parity_self_test` rather than failing silently.
const POD_MAX_STATE_ID := 5
const POD_CONDITION_STATE_GTE := 5
const POD_INSTRUCTION_READ_STATE := 3
## Metric-reading opcodes, mirrored from gdext/src/effect_runtime.h. Only these
## carry a metric id in arg0; every other opcode's arg0 means something else, so
## scanning opcodes blindly would invent metric reads that do not exist.
const CONDITION_METRIC_GTE := 2
const CONDITION_METRIC_LTE := 3
const CONDITION_METRIC_EQ := 4
const INSTRUCTION_READ_METRIC := 2

@export var metric_keys: PackedStringArray = PackedStringArray()
## Optional cell-tag predicates (see gdext/src/target_tag.h). One entry per tag:
##   {"name": String, "rows": [{"metric": String, "op": int,
##                              "threshold_q16": int, "clause": int}, ...]}
## `op`: 0 >=  1 <=  2 ==  3 !=. Rows in one tag with the same `clause` are
## ANDed; distinct clause ids are ORed, and clause ids must not decrease. That
## covers both shapes the tag dictionary needs ("grain" = output is wheat OR
## rice OR ...; "rich in iron" = resource is iron AND share >= 50%).
## Empty by default: a catalog without tags keeps byte-identical output, and the
## territory selector then has no tag to filter on.
@export var target_tags: Array[Dictionary] = []
@export var behavior_command_keys: PackedStringArray = PackedStringArray()
@export var definitions: Array[Resource] = []
@export_range(1, 16000000, 1) var max_instances: int = 4096
@export_range(1, 16000000, 1) var max_transactions: int = 8192
@export_range(1, 1000000, 1) var max_work_per_slice: int = 1024
@export_range(1, 4000000, 1) var max_native_modifier_commands: int = 4096
# Cold packed extensions owned by EffectRuntime. Kept out of individual
# EffectDefinition resources because alternative offers have three command
# spans and are planned before one span becomes a transaction.
var native_extensions: Dictionary = {}

static func load_default() -> Resource:
	var loaded := ResourceLoader.load(DEFAULT_PATH, "Resource")
	if loaded != null:
		return loaded
	var catalog_script: Script = load("res://scripts/effect/effect_catalog.gd") as Script
	return catalog_script.new() if catalog_script != null else null

func compile_native_catalog() -> Dictionary:
	var out := {
		"protocol_version": PROTOCOL_VERSION,
		"max_instances": max_instances,
		"max_transactions": max_transactions,
		"max_work_per_slice": max_work_per_slice,
		"max_native_modifier_commands": max_native_modifier_commands,
		"metric_keys": metric_keys,
		"behavior_command_keys": behavior_command_keys,
		"effect_keys": PackedStringArray(), "versions": PackedInt32Array(),
		"cadence_days": PackedInt32Array(), "max_work": PackedInt32Array(),
		"enabled": PackedByteArray(), "behavior_keys": PackedStringArray(),
		"source_kinds": PackedInt32Array(), "target_domains": PackedInt32Array(),
		"operations": PackedInt32Array(), "lifecycles": PackedInt32Array(),
		"duration_days": PackedInt32Array(),
		"stack_policies": PackedInt32Array(), "stack_keys": PackedStringArray(),
		"max_stacks": PackedInt32Array(), "priorities": PackedInt32Array(),
		"target_selector_kinds": PackedInt32Array(),
		"target_selector_ids": PackedStringArray(),
		"target_selector_params": PackedInt32Array(),
		"magnitude_by_prestige_q16": PackedInt32Array(),
		"condition_offsets": PackedInt32Array([0]), "condition_ops": PackedInt32Array(),
		"condition_arg0": PackedInt32Array(), "condition_values": PackedInt64Array(),
		"instruction_offsets": PackedInt32Array([0]), "instruction_ops": PackedInt32Array(),
		"instruction_arg0": PackedInt32Array(), "instruction_arg1": PackedInt32Array(),
		"instruction_values": PackedInt64Array(), "command_offsets": PackedInt32Array([0]),
		"command_actions": PackedInt32Array(), "command_domains": PackedInt32Array(),
		"command_opcodes": PackedInt32Array(), "command_target_resolvers": PackedInt32Array(),
		"command_static_targets": PackedInt64Array(), "command_value_modes": PackedInt32Array(),
		"command_values": PackedInt64Array(), "command_duration_days": PackedInt32Array(),
		"command_stacks": PackedInt32Array(), "command_keys": PackedStringArray(),
		"command_definition_keys": PackedStringArray(), "command_payload_i0": PackedInt64Array(),
		"command_payload_i1": PackedInt64Array(), "command_payload_i2": PackedInt64Array(),
		"command_payload_i3": PackedInt64Array(),
		"managed_flags": PackedByteArray(),
		"pod_expressible": PackedByteArray(),
		"target_tags": PackedStringArray(),
		"tag_offsets": PackedInt32Array(),
		"tag_metric_ids": PackedInt32Array(),
		"tag_metric_ops": PackedInt32Array(),
		"tag_metric_clauses": PackedInt32Array(),
		"tag_metric_thresholds_q16": PackedInt64Array(),
	}
	# Maps metric key -> dense id, which is also the duplicate guard. Tag rows
	# resolve their metric through this map, so it must hold the id rather than a
	# plain `true`: storing a boolean here silently made every tag row read
	# metric id 1 (int(true)) instead of the id the author named.
	var metric_seen := {}
	for metric_index in range(metric_keys.size()):
		var key := String(metric_keys[metric_index])
		if key.is_empty() or metric_seen.has(key):
			return {"ok": false, "reason": "effect_metric_key_invalid_or_duplicate"}
		metric_seen[key] = metric_index
	var definition_seen := {}
	var any_managed := false
	var any_selector_params := false
	for definition in definitions:
		if definition != null and definition is EffectDefinitionScript:
			if bool(definition.managed):
				any_managed = true
			if not definition.target_selector_param.is_empty():
				any_selector_params = true
			if any_managed and any_selector_params:
				break
	for definition in definitions:
		if definition == null or not definition is EffectDefinitionScript:
			return {"ok": false, "reason": "effect_definition_resource_invalid"}
		if definition.key == &"" or definition_seen.has(definition.key) \
				or definition.version <= 0 or definition.cadence_days <= 0 \
				or definition.max_work <= 0 \
				or (definition.behavior_id == &"" and definition.instructions.is_empty()):
			return {"ok": false, "reason": "effect_definition_invalid_or_duplicate"}
		definition_seen[definition.key] = true
		out.pod_expressible.append(1 if _pod_expressible(definition) else 0)
		out.effect_keys.append(String(definition.key))
		out.versions.append(definition.version)
		out.cadence_days.append(definition.cadence_days)
		out.max_work.append(definition.max_work)
		out.enabled.append(1 if definition.enabled else 0)
		out.behavior_keys.append(String(definition.behavior_id))
		out.source_kinds.append(int(definition.source_kind))
		out.target_domains.append(int(definition.target_domain))
		out.operations.append(int(definition.operation))
		out.lifecycles.append(int(definition.lifecycle))
		out.duration_days.append(int(definition.duration_days))
		out.stack_policies.append(int(definition.stack_policy))
		out.stack_keys.append(String(definition.stack_key))
		out.max_stacks.append(maxi(1, int(definition.max_stacks)))
		out.priorities.append(int(definition.priority))
		out.target_selector_kinds.append(int(definition.target_selector_kind))
		out.target_selector_ids.append(String(definition.target_selector_id))
		if any_selector_params:
			var params := PackedInt32Array(definition.target_selector_param)
			for slot in range(2):
				out.target_selector_params.append(
					int(params[slot]) if slot < params.size() else 0)
		if any_managed:
			out.managed_flags.append(1 if bool(definition.managed) else 0)
		var prestige := PackedInt32Array(definition.magnitude_by_prestige_q16)
		if prestige.size() == 0:
			prestige = PackedInt32Array([Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE, Q16_ONE])
		if prestige.size() != 6:
			return {"ok": false, "reason": "effect_prestige_magnitude_shape_invalid"}
		for tier in range(6):
			var magnitude := int(prestige[tier])
			if magnitude < 0 or magnitude > Q16_ONE * 4:
				return {"ok": false, "reason": "effect_prestige_magnitude_invalid"}
			out.magnitude_by_prestige_q16.append(magnitude)
		for condition in definition.conditions:
			if condition == null or not condition is EffectConditionScript:
				return {"ok": false, "reason": "effect_condition_resource_invalid"}
			if condition.op < 1 or condition.op > 8:
				return {"ok": false, "reason": "effect_condition_opcode_invalid"}
			out.condition_ops.append(condition.op)
			out.condition_arg0.append(condition.arg0)
			out.condition_values.append(condition.value_q16)
		out.condition_offsets.append(out.condition_ops.size())
		for instruction in definition.instructions:
			if instruction == null or not instruction is EffectInstructionScript:
				return {"ok": false, "reason": "effect_instruction_resource_invalid"}
			if instruction.op < 1 or instruction.op > 12:
				return {"ok": false, "reason": "effect_instruction_opcode_invalid"}
			out.instruction_ops.append(instruction.op)
			out.instruction_arg0.append(instruction.arg0)
			out.instruction_arg1.append(instruction.arg1)
			out.instruction_values.append(instruction.value_q16)
		out.instruction_offsets.append(out.instruction_ops.size())
		for command in definition.commands:
			if command == null or not command is EffectCommandScript:
				return {"ok": false, "reason": "effect_command_resource_invalid"}
			if command.action < 1 or command.action > 6 or command.domain < -1 \
					or command.domain >= 32 or command.target_resolver < 0 \
					or command.target_resolver > 2 or command.value_mode < 0 \
					or command.value_mode > 1 or command.stacks <= 0 \
					or command.duration_days < -1 or command.command_key == &"" \
					or (command.action != 1 and command.action != 3 \
						and command.definition_key == &""):
				return {"ok": false, "reason": "effect_command_invalid"}
			if command.target_resolver == 0 and command.static_target == 0:
				return {"ok": false, "reason": "effect_command_static_target_invalid"}
			var native_error := _native_command_error(command)
			if not native_error.is_empty():
				return {"ok": false, "reason": native_error}
			out.command_actions.append(command.action)
			out.command_domains.append(command.domain)
			out.command_opcodes.append(command.opcode)
			out.command_target_resolvers.append(command.target_resolver)
			out.command_static_targets.append(command.static_target)
			out.command_value_modes.append(command.value_mode)
			out.command_values.append(command.value_q16)
			out.command_duration_days.append(command.duration_days)
			out.command_stacks.append(command.stacks)
			out.command_keys.append(String(command.command_key))
			out.command_definition_keys.append(String(command.definition_key))
			out.command_payload_i0.append(command.payload_i0)
			out.command_payload_i1.append(command.payload_i1)
			out.command_payload_i2.append(command.payload_i2)
			out.command_payload_i3.append(command.payload_i3)
		out.command_offsets.append(out.command_actions.size())
	# Tag predicates, emitted only when authored. The native side treats an
	# absent table as "no tags", so leaving these arrays empty is what keeps
	# every pre-tag catalog byte-identical.
	if not target_tags.is_empty():
		out.tag_offsets = PackedInt32Array([0])
		for tag in target_tags:
			var tag_name := String(tag.get("name", ""))
			if tag_name.is_empty():
				return {"ok": false, "reason": "target_tag_name_empty"}
			var sees: Array = tag.get("rows", [])
			if sees.is_empty():
				return {"ok": false, "reason": "target_tag_has_no_rows"}
			out.target_tags.append(tag_name)
			var previous_clause := -1
			for row in sees:
				var metric_key := String(row.get("metric", ""))
				if not metric_seen.has(metric_key):
					return {"ok": false,
						"reason": "target_tag_metric_not_declared:" + metric_key}
				var op := int(row.get("op", 0))
				if op < 0 or op >= 5:
					return {"ok": false, "reason": "target_tag_op_invalid"}
				var clause := int(row.get("clause", 0))
				if clause < previous_clause:
					return {"ok": false, "reason": "target_tag_clause_not_sorted"}
				previous_clause = clause
				out.tag_metric_ids.append(int(metric_seen[metric_key]))
				out.tag_metric_ops.append(op)
				out.tag_metric_clauses.append(clause)
				out.tag_metric_thresholds_q16.append(int(row.get("threshold_q16", 0)))
			out.tag_offsets.append(out.tag_metric_ids.size())
	# P2-D: metric scope has to match program scope. Both mistakes compile and
	# then lie at runtime: a `city.*` metric read by a COUNTRY-domain program
	# samples one cell and presents it as a national number, and a `cell.*`
	# metric read by a COUNTRY program returns whatever the anchor cell happens
	# to hold. The native validator cannot see this at all -- it only knows ids.
	for definition in definitions:
		if definition == null or not definition is EffectDefinitionScript:
			continue
		var domain := int(definition.target_domain)
		var used := {}
		for condition in definition.conditions:
			if condition == null:
				continue
			var op := int(condition.op)
			if op == CONDITION_METRIC_GTE or op == CONDITION_METRIC_LTE \
					or op == CONDITION_METRIC_EQ:
				used[int(condition.arg0)] = true
		for instruction in definition.instructions:
			if instruction == null:
				continue
			if int(instruction.op) == INSTRUCTION_READ_METRIC:
				used[int(instruction.arg0)] = true
		for metric_id in used:
			if metric_id < 0 or metric_id >= metric_keys.size():
				continue
			var metric_key := String(metric_keys[metric_id])
			if metric_key.begins_with("city.") and domain != 2 and domain != 5:
				return {"ok": false,
					"reason": "effect_city_metric_requires_cell_domain:" + metric_key}
			if metric_key.begins_with("cell.") and domain == 3:
				return {"ok": false,
					"reason": "effect_cell_metric_on_country_domain:" + metric_key}
	out.ok = true
	for extension_key in native_extensions:
		if out.has(extension_key):
			return {"ok": false, "reason": "effect_native_extension_key_collision"}
		out[extension_key] = native_extensions[extension_key]
	return out

## Mirrors the POD compiler's capability limits. Keep in lockstep with
## gdext/src/runtime_effect_pod.cpp:
##   target_selector_kind   MAX_SELECTOR_KIND   (0..13, 12 = OWN_TERRITORY,
##                                                13 = TAG_ANY_CELL)
##   condition STATE_GTE    MAX_STATE_ID        (arg0 0..5, 5 = STATE_LATCHED)
##   instruction READ_STATE MAX_STATE_ID        (arg0 0..5)
## Both ceilings equal the main thread's, not a narrower subset. They were
## 7 / 3 once, and because POD catalog validation is all-or-nothing a single
## card above the ceiling took the whole worker authority graph down.
## MODIFIER command domain/opcode are already pinned tighter here by
## _native_command_error(), so they need no separate POD check.
static func _pod_expressible(definition: Resource) -> bool:
	if int(definition.target_selector_kind) > POD_MAX_SELECTOR_KIND:
		return false
	for condition in definition.conditions:
		if condition == null or not condition is EffectConditionScript:
			return false
		if int(condition.op) == POD_CONDITION_STATE_GTE \
				and int(condition.arg0) > POD_MAX_STATE_ID:
			return false
	for instruction in definition.instructions:
		if instruction == null or not instruction is EffectInstructionScript:
			return false
		if int(instruction.op) == POD_INSTRUCTION_READ_STATE \
				and int(instruction.arg0) > POD_MAX_STATE_ID:
			return false
	return true


static func _native_command_error(command: Resource) -> String:
	match int(command.action):
		1:
			if command.domain < 0 or command.domain > 3 \
					or (command.opcode != 1 and command.opcode != 2):
				return "effect_modifier_opcode_unregistered"
		2:
			if command.domain != 1 or command.opcode < 1 or command.opcode > 14:
				return "effect_country_opcode_unregistered"
		3:
			if command.domain != 2 or not _economy_opcode_registered(int(command.opcode)):
				return "effect_economy_opcode_unregistered"
		4:
			if command.domain != 3 or command.opcode <= 0:
				return "effect_gameplay_opcode_unregistered"
		5:
			if command.domain != 4 or command.opcode <= 0:
				return "effect_publish_event_opcode_unregistered"
		6:
			if command.domain != 6 or command.opcode not in [1, 2, 3]:
				return "effect_custom_domain_adapter_unregistered"
			if command.opcode == 3 and (command.value_q16 <= 0 \
					or command.value_q16 > 65535):
				return "effect_ideology_free_draw_count_invalid"
		_:
			return "effect_command_action_unregistered"
	return ""


static func _economy_opcode_registered(opcode: int) -> bool:
	# 1-15 are the original ledger/family reward opcodes. 17-19 are family
	# expedition commands. 21-22 are conserved family absorb/discount adapters.
	# COMMAND_BUILD_CANAL=20 stays domain-only and is not authored here.
	# COMMAND_FAMILY_SET_SPLIT_POLICY=23 only mutates FamilyStore flags.
	return (opcode >= 1 and opcode <= 15) \
		or (opcode >= 17 and opcode <= 19) \
		or opcode == 21 or opcode == 22 or opcode == 23
