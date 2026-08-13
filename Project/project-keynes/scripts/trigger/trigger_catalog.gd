class_name TriggerCatalog
extends Resource

const DEFAULT_PATH := "res://data/triggers/default_trigger_catalog.tres"
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")

const PROTOCOL_VERSION := 2
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

const EVENT_TECHNOLOGY_PRACTICE := 14
const EVENT_TECHNOLOGY_CONTACT := 16
const EVENT_WEATHER_OBSERVED := 11
const PAYLOAD_TECHNOLOGY_PRACTICE_V1 := 7
const PAYLOAD_WEATHER_OBSERVED_V1 := 9
const SOURCE_NATIVE := 1
const SOURCE_GDSCRIPT := 2
const SCOPE_ENTITY := 2
const VALUE_I64 := 1
const PAYLOAD_I0 := 2
const ACTION_COUNTRY_COMMAND := 10
const COUNTRY_DOMAIN := 1
const COMMAND_DISCOVER_COUNTRY_SIGNAL := 14
const SOURCE_KIND_TRIGGER_OUTPUT := 4

## Economy publishes only already-qualified practice facts. TriggerRuntime owns
## their durable accumulation; EffectRuntime owns the Country command/ACK.
const BREAKTHROUGH_RULES := [
	[0, "maize_selection", "breakthrough.maize_selection", 365],
	[1, "dryland_days", "breakthrough.dryland_adaptation", 730],
	[2, "dryland_droughts", "breakthrough.dryland_adaptation", 3],
	[3, "hydraulic_engineering", "breakthrough.hydraulic_engineering", 1],
	[4, "metalworking", "breakthrough.metalworking", 5000 * 1000],
	[5, "printing", "breakthrough.printing", 10000 * 1000],
	[6, "steam_power", "breakthrough.steam_power", 3 * 1095],
	[7, "electrification", "breakthrough.electrification", 3 * 730],
	[8, "industrial_organization", "breakthrough.industrial_organization", 3 * 365],
	[9, "automation", "breakthrough.automation", 2 * 365],
	[10, "climate_modeling", "breakthrough.climate_modeling", 5],
	[11, "seed_saving", "breakthrough.seed_saving", 120],
	[12, "rainfed_adaptation", "breakthrough.rainfed_adaptation", 240],
	[13, "paddy_control", "breakthrough.paddy_control", 240],
	[14, "terrace_maintenance", "breakthrough.terrace_maintenance", 240],
	[15, "mine_support", "breakthrough.mine_support", 360],
	[16, "mine_drainage", "breakthrough.mine_drainage", 360],
	[17, "kiln_temperature", "breakthrough.kiln_temperature", 360],
	[18, "print_calibration", "breakthrough.print_calibration", 360],
	[19, "steam_sealing", "breakthrough.steam_sealing", 360],
	[20, "motor_winding", "breakthrough.motor_winding", 360],
	[21, "assembly_line", "breakthrough.assembly_line", 360],
	[22, "digital_control", "breakthrough.digital_control", 360],
	[23, "maritime_operations", "breakthrough.maritime_operations", 360],
	[24, "watershed_management", "breakthrough.watershed_management", 360],
	[25, "forest_management", "breakthrough.forest_management", 360],
	[26, "chemical_process_control", "breakthrough.chemical_process_control", 360],
	[27, "energy_control", "breakthrough.energy_control", 360],
]

## These facts are emitted only after a cross-country delivery of the matching
## crop sample or ore. Merely knowing a trade route never creates contact.
const CONTACT_RULES := [
	[0, "maize", "contact.maize"],
	[1, "wheat", "contact.wheat"],
	[2, "rice", "contact.rice"],
	[3, "potato", "contact.potato"],
	[4, "cotton", "contact.cotton"],
	[5, "flax", "contact.flax"],
	[6, "spice", "contact.spice"],
	[7, "rubber", "contact.rubber"],
	[8, "tin", "contact.tin"],
	[9, "maritime_vessel", "contact.maritime_vessel"],
]

const WEATHER_RULES := [
	[0, "typhoon", "weather.typhoon", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[1, "major_flood", "weather.major_flood", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[2, "drought", "weather.drought", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[3, "monsoon", "weather.monsoon", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[4, "frost", "weather.frost", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[5, "storm_surge", "weather.storm_surge", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[6, "repeated_crop_failure", "weather.repeated_crop_failure", SOURCE_NATIVE, AGG_SUM, 3],
]

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
		"dynamic_bindings": PackedByteArray(),
		"selector_fields": PackedInt32Array(), "selector_values": PackedInt64Array(),
		"selector_negated": PackedByteArray(),
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
	var compiled_definitions: Array[Resource] = definitions.duplicate()
	compiled_definitions.append_array(_breakthrough_definitions())
	compiled_definitions.append_array(_contact_definitions())
	compiled_definitions.append_array(_weather_definitions())
	var seen := {}
	for definition in compiled_definitions:
		if definition == null or not definition is TriggerDefinitionScript:
			return {"ok": false, "reason": "trigger_definition_resource_invalid"}
		if definition.key == &"" or seen.has(definition.key) or definition.threshold <= 0 \
				or definition.selector_field < -1 or definition.selector_field > 7:
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
		out.dynamic_bindings.append(1 if definition.dynamic_binding else 0)
		out.selector_fields.append(definition.selector_field)
		var selector_value := int(definition.selector_value)
		if definition.selector_key != &"":
			selector_value = _signed_hash32(String(definition.selector_key))
		out.selector_values.append(selector_value)
		out.selector_negated.append(1 if definition.selector_negated else 0)
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


static func breakthrough_effect_rows() -> Array[Dictionary]:
	var signal_catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	if not bool(signal_catalog.get("ok", false)):
		return []
	var signal_ids: PackedStringArray = signal_catalog.get(
		"research_signal_ids", PackedStringArray())
	var rows: Array[Dictionary] = []
	var seen_signals := {}
	for row in BREAKTHROUGH_RULES + CONTACT_RULES + WEATHER_RULES:
		var signal_id := String(row[2])
		if seen_signals.has(signal_id):
			continue
		var signal_index := signal_ids.find(signal_id)
		if signal_index < 0:
			return []
		seen_signals[signal_id] = true
		rows.append({
			"signal_id": signal_id,
			"signal_index": signal_index,
			"command_key": "contact.discover" if signal_id.begins_with("contact.") \
				else ("weather.discover" if signal_id.begins_with("weather.") \
				else "breakthrough.discover"),
		})
	return rows


static func _weather_definitions() -> Array[Resource]:
	var signal_catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	var signal_ids: PackedStringArray = signal_catalog.get(
		"research_signal_ids", PackedStringArray())
	var out: Array[Resource] = []
	if not bool(signal_catalog.get("ok", false)):
		return out
	for row in WEATHER_RULES:
		var signal_id := String(row[2])
		var signal_index := signal_ids.find(signal_id)
		if signal_index < 0:
			return []
		var definition := TriggerDefinitionScript.new()
		definition.key = StringName("technology.weather.%s" % String(row[1]))
		definition.version = 1
		definition.source_id = int(row[3])
		definition.event_type = EVENT_WEATHER_OBSERVED
		definition.payload_schema = PAYLOAD_WEATHER_OBSERVED_V1
		definition.aggregator = int(row[4])
		definition.value_field = VALUE_I64
		definition.scope = SCOPE_ENTITY
		definition.target_resolver = TARGET_EVENT_ENTITY
		definition.threshold = int(row[5])
		definition.mode = MODE_ONE_SHOT
		definition.selector_field = PAYLOAD_I0
		definition.selector_value = int(row[0])
		definition.condition_ops = PackedInt32Array([2])
		var effect := TriggerEffectScript.new()
		effect.action = ACTION_COUNTRY_COMMAND
		effect.domain = COUNTRY_DOMAIN
		effect.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL
		effect.target_resolver = TARGET_EVENT_ENTITY
		effect.value_mode = 0
		effect.value = SOURCE_KIND_TRIGGER_OUTPUT
		effect.command_key = &"weather.discover"
		effect.definition_key = StringName(signal_id)
		effect.payload_i0 = signal_index
		definition.effects = [effect]
		out.append(definition)
	return out


static func _contact_definitions() -> Array[Resource]:
	var signal_catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	var signal_ids: PackedStringArray = signal_catalog.get(
		"research_signal_ids", PackedStringArray())
	var out: Array[Resource] = []
	if not bool(signal_catalog.get("ok", false)):
		return out
	for row in CONTACT_RULES:
		var signal_id := String(row[2])
		var signal_index := signal_ids.find(signal_id)
		if signal_index < 0:
			return []
		var definition := TriggerDefinitionScript.new()
		definition.key = StringName("technology.contact.%s" % String(row[1]))
		definition.version = 1
		definition.source_id = SOURCE_NATIVE
		definition.event_type = EVENT_TECHNOLOGY_CONTACT
		definition.payload_schema = PAYLOAD_TECHNOLOGY_PRACTICE_V1
		definition.aggregator = AGG_COUNT
		definition.value_field = VALUE_I64
		definition.scope = SCOPE_ENTITY
		definition.target_resolver = TARGET_EVENT_ENTITY
		definition.threshold = 1
		definition.mode = MODE_ONE_SHOT
		definition.selector_field = PAYLOAD_I0
		definition.selector_value = int(row[0])
		definition.condition_ops = PackedInt32Array([2])
		var effect := TriggerEffectScript.new()
		effect.action = ACTION_COUNTRY_COMMAND
		effect.domain = COUNTRY_DOMAIN
		effect.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL
		effect.target_resolver = TARGET_EVENT_ENTITY
		effect.value_mode = 0
		effect.value = SOURCE_KIND_TRIGGER_OUTPUT
		effect.command_key = &"contact.discover"
		effect.definition_key = StringName(signal_id)
		effect.payload_i0 = signal_index
		definition.effects = [effect]
		out.append(definition)
	return out


static func _breakthrough_definitions() -> Array[Resource]:
	var signal_catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	var signal_ids: PackedStringArray = signal_catalog.get(
		"research_signal_ids", PackedStringArray())
	var out: Array[Resource] = []
	if not bool(signal_catalog.get("ok", false)):
		return out
	for row in BREAKTHROUGH_RULES:
		var signal_id := String(row[2])
		var signal_index := signal_ids.find(signal_id)
		if signal_index < 0:
			return []
		var definition := TriggerDefinitionScript.new()
		definition.key = StringName("technology.practice.%s" % String(row[1]))
		definition.version = 1
		definition.source_id = SOURCE_NATIVE
		definition.event_type = EVENT_TECHNOLOGY_PRACTICE
		definition.payload_schema = PAYLOAD_TECHNOLOGY_PRACTICE_V1
		definition.aggregator = AGG_SUM
		definition.value_field = VALUE_I64
		definition.scope = SCOPE_ENTITY
		definition.target_resolver = TARGET_EVENT_ENTITY
		definition.threshold = int(row[3])
		definition.mode = MODE_ONE_SHOT
		definition.selector_field = PAYLOAD_I0
		definition.selector_value = int(row[0])
		definition.condition_ops = PackedInt32Array([2]) # PUSH_ACC_GTE
		var effect := TriggerEffectScript.new()
		effect.action = ACTION_COUNTRY_COMMAND
		effect.domain = COUNTRY_DOMAIN
		effect.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL
		effect.target_resolver = TARGET_EVENT_ENTITY
		effect.value_mode = 0
		effect.value = SOURCE_KIND_TRIGGER_OUTPUT
		effect.command_key = &"breakthrough.discover"
		effect.definition_key = StringName(signal_id)
		# TriggerRuntime packs the event's first-practice cell into the low word.
		effect.payload_i0 = signal_index
		definition.effects = [effect]
		out.append(definition)
	return out


static func _signed_hash32(value: String) -> int:
	var hashed := int(value.hash())
	return hashed - 0x100000000 if hashed > 0x7fffffff else hashed
