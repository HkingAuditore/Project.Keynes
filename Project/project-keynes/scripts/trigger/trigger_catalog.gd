class_name TriggerCatalog
extends Resource

const DEFAULT_PATH := "res://data/triggers/default_trigger_catalog.tres"
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")

const PROTOCOL_VERSION := 1
const AGG_COUNT := 1
const AGG_SUM := 2
const AGG_MIN := 3
const AGG_MAX := 4
const AGG_STATE_LEVEL := 5
const AGG_WINDOW_COUNT := 6
const AGG_WINDOW_SUM := 7
const AGG_DISTINCT_COUNT := 8
const AGG_SNAPSHOT_DIFF := 9
const TARGET_STATIC := 0
const TARGET_SOURCE_ENTITY := 1
const TARGET_EVENT_ENTITY := 2
const TARGET_EVENT_GROUP := 3
const TARGET_SNAPSHOT := 4
const MODE_REPEAT := 1
const MODE_ONE_SHOT := 2

@export var definitions: Array[Resource] = []
@export var max_state_instances: int = 4096
@export var max_pending_events: int = 8192
@export var distinct_capacity: int = 64
@export var source_count: int = 64
@export var event_type_span: int = 256
@export var strict_source_cursors: bool = false

static func load_default() -> Resource:
	var loaded = ResourceLoader.load(DEFAULT_PATH, "Resource")
	return loaded if loaded != null else TriggerCatalog.new()

func compile_native_catalog() -> Dictionary:
	var out := {
		"protocol_version": PROTOCOL_VERSION,
		"max_state_instances": max_state_instances,
		"max_pending_events": max_pending_events,
		"distinct_capacity": distinct_capacity,
		"source_count": source_count,
		"event_type_span": event_type_span,
		"strict_source_cursors": strict_source_cursors,
		"trigger_keys": PackedStringArray(), "versions": PackedInt32Array(),
		"source_ids": PackedInt32Array(), "event_types": PackedInt32Array(),
		"payload_schemas": PackedInt32Array(), "aggregators": PackedInt32Array(),
		"value_fields": PackedInt32Array(), "distinct_fields": PackedInt32Array(),
		"scopes": PackedInt32Array(), "target_resolvers": PackedInt32Array(),
		"static_targets": PackedInt64Array(), "thresholds": PackedInt64Array(),
		"modes": PackedInt32Array(), "cooldown_days": PackedInt32Array(),
		"window_days": PackedInt32Array(), "enabled": PackedByteArray(),
		"condition_offsets": PackedInt32Array([0]), "condition_ops": PackedInt32Array(),
		"effect_offsets": PackedInt32Array([0]), "effect_actions": PackedInt32Array(),
		"effect_domains": PackedInt32Array(), "effect_source_priorities": PackedInt32Array(),
		"effect_opcodes": PackedInt32Array(),
		"effect_target_resolvers": PackedInt32Array(), "effect_static_targets": PackedInt64Array(),
		"effect_value_modes": PackedInt32Array(), "effect_values": PackedInt64Array(),
		"effect_duration_days": PackedInt32Array(), "effect_stacks": PackedInt32Array(),
		"effect_command_keys": PackedStringArray(), "effect_definition_keys": PackedStringArray(),
		"effect_payload_i0": PackedInt64Array(), "effect_payload_i1": PackedInt64Array(),
		"effect_payload_i2": PackedInt64Array(), "effect_payload_i3": PackedInt64Array(),
	}
	var seen := {}
	for definition in definitions:
		if definition == null or not definition is TriggerDefinitionScript:
			return {"ok": false, "reason": "trigger_definition_resource_invalid"}
		if definition.key == &"" or seen.has(definition.key) or definition.threshold <= 0:
			return {"ok": false, "reason": "trigger_definition_key_invalid_or_duplicate"}
		if definition.source_id < 0 or definition.source_id >= source_count \
				or definition.event_type < 0 or definition.event_type >= event_type_span:
			return {"ok": false, "reason": "trigger_definition_source_or_type_invalid"}
		seen[definition.key] = true
		out.trigger_keys.append(String(definition.key)); out.versions.append(definition.version)
		out.source_ids.append(definition.source_id); out.event_types.append(definition.event_type)
		out.payload_schemas.append(definition.payload_schema); out.aggregators.append(definition.aggregator)
		out.value_fields.append(definition.value_field); out.distinct_fields.append(definition.distinct_field)
		out.scopes.append(definition.scope); out.target_resolvers.append(definition.target_resolver)
		out.static_targets.append(definition.static_target); out.thresholds.append(definition.threshold)
		out.modes.append(definition.mode); out.cooldown_days.append(definition.cooldown_days)
		out.window_days.append(definition.window_days); out.enabled.append(1 if definition.enabled else 0)
		for op in definition.condition_ops: out.condition_ops.append(int(op))
		out.condition_offsets.append(out.condition_ops.size())
		for effect in definition.effects:
			if effect == null:
				return {"ok": false, "reason": "trigger_effect_resource_invalid"}
			out.effect_actions.append(int(effect.action)); out.effect_domains.append(int(effect.domain))
			out.effect_source_priorities.append(int(effect.source_priority))
			out.effect_opcodes.append(int(effect.opcode)); out.effect_target_resolvers.append(int(effect.target_resolver))
			out.effect_static_targets.append(int(effect.static_target)); out.effect_value_modes.append(int(effect.value_mode))
			out.effect_values.append(int(effect.value)); out.effect_duration_days.append(int(effect.duration_days))
			out.effect_stacks.append(int(effect.stacks)); out.effect_command_keys.append(String(effect.command_key))
			out.effect_definition_keys.append(String(effect.definition_key)); out.effect_payload_i0.append(int(effect.payload_i0))
			out.effect_payload_i1.append(int(effect.payload_i1)); out.effect_payload_i2.append(int(effect.payload_i2)); out.effect_payload_i3.append(int(effect.payload_i3))
		out.effect_offsets.append(out.effect_actions.size())
	out.ok = true
	return out
