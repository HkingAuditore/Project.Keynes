class_name TriggerCatalog
extends Resource

const DEFAULT_PATH := "res://data/triggers/default_trigger_catalog.tres"
const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")
const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")
const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")
const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

const PROTOCOL_VERSION := 3
const AGG_COUNT := 1
const AGG_SUM := 2
const AGG_MIN := 3
const AGG_MAX := 4
const AGG_STATE_LEVEL := 5
const AGG_WINDOW_COUNT := 6
const AGG_WINDOW_SUM := 7
const AGG_DISTINCT_COUNT := 8
const AGG_SNAPSHOT_DIFF := 9
const AGG_CONSECUTIVE_DURATION := 10
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
const EVENT_COUNTRY_DEVELOPMENT_METRIC := 17
const PAYLOAD_TECHNOLOGY_PRACTICE_V1 := 7
const PAYLOAD_WEATHER_OBSERVED_V1 := 9
const PAYLOAD_COUNTRY_DEVELOPMENT_V1 := 10
const SOURCE_NATIVE := 1
const SOURCE_GDSCRIPT := 2
const SCOPE_ENTITY := 2
const VALUE_ONE := 0
const VALUE_I64 := 1
const PAYLOAD_I0 := 2
const PAYLOAD_I1 := 3
const PAYLOAD_I2 := 4
const PAYLOAD_I3 := 5
const ACTION_COUNTRY_COMMAND := 10
const ACTION_ECONOMY_COMMAND := 11
const ACTION_MODIFIER_APPLY := 1
const COUNTRY_DOMAIN := 1
const COMMAND_DISCOVER_COUNTRY_SIGNAL := 14
const SOURCE_KIND_TRIGGER_OUTPUT := 4
const EVENT_CONSTRUCTION_COMPLETED := 6
const EVENT_TRADE_ARRIVED := 7
const PAYLOAD_CONSTRUCTION_COMPLETED_V1 := 3
const PAYLOAD_TRADE_ARRIVED_V1 := 4

## Military facts (design §19.1). TriggerRuntime consumes them through the same
## aggregate / selector machinery as any other fact; the military source keeps
## its own cursor so a slow trigger consumer cannot starve environmental ones.
## Must equal GameplayEventBus.SOURCE_MILITARY (3 is SOURCE_DEBUG, 4 EFFECT).
const SOURCE_MILITARY := 5
const EVENT_MILITARY_WAR_DECLARED := 40
const EVENT_MILITARY_WAR_ENDED := 41
const EVENT_MILITARY_BATTLE_RESOLVED := 42
const EVENT_MILITARY_CELL_CONTROL_CHANGED := 43
const EVENT_MILITARY_ARMY_DESTROYED := 44
const EVENT_MILITARY_COUNTRY_ANNEXED := 45
const EVENT_MILITARY_CONVOY_INTERCEPTED := 46
const EVENT_MILITARY_LEVY_APPLIED := 47
const PAYLOAD_MILITARY_WAR_V1 := 20
const PAYLOAD_MILITARY_BATTLE_V1 := 21
const PAYLOAD_MILITARY_CONTROL_V1 := 22
const PAYLOAD_MILITARY_ANNEX_V1 := 23
const PAYLOAD_MILITARY_CONVOY_V1 := 24
const PAYLOAD_MILITARY_LEVY_V1 := 25
## How many event types one military fact key can own. A key such as
## `military.war.battles_won` fires on battle wins *and* annihilations, so the
## selector's payload filter must be able to see both.
const MILITARY_EVENT_TYPE_MAX_PER_KEY := 8

## Authored military trigger keys. Columns:
##   index, key, event types (comma separated), payload schema, aggregator,
##   value field, selector field, selector value, threshold, window days,
##   display name, description.
## Selector `-1` = no payload filter, so the key accumulates every event of its
## type set. `selector_value` doubles as the "outcome / band" code in the
## payload (e.g. WAR_ENDED result enum, battle size band).
const MILITARY_RULES := [
	[0, "military.war.declared", "40", PAYLOAD_MILITARY_WAR_V1,
		AGG_COUNT, VALUE_I64, -1, 0, 1, 0, "战端初启",
		"本国（或被观察国）发动的战争次数达到门槛。"],
	[1, "military.war.ended", "41", PAYLOAD_MILITARY_WAR_V1,
		AGG_COUNT, VALUE_I64, -1, 0, 1, 0, "战事终结",
		"战争结束（和约、破裂或吞并）的次数；赔款总额累计在 value。"],
	[2, "military.war.victories", "41", PAYLOAD_MILITARY_WAR_V1,
		AGG_COUNT, VALUE_I64, PAYLOAD_I1, 0, 3, 0, "凯旋",
		"以胜方身份结束战争的次数。i1 = WAR_RESULT_WON。"],
	[3, "military.battle.won", "42", PAYLOAD_MILITARY_BATTLE_V1,
		AGG_COUNT, VALUE_I64, -1, 0, 10, 0, "会战名将",
		"赢得的野战 / 会战次数（十年内十场）。"],
	[4, "military.battle.window", "42", PAYLOAD_MILITARY_BATTLE_V1,
		AGG_WINDOW_COUNT, VALUE_I64, -1, 0, 5, 90, "连战连胜",
		"九十日内发生的会战次数，用于紧凑战事节奏的检定。"],
	[5, "military.battle.casualties", "42", PAYLOAD_MILITARY_BATTLE_V1,
		AGG_SUM, VALUE_I64, -1, 0, 10000, 0, "血战",
		"累计造成敌方伤亡人数。"],
	[6, "military.control.changed", "43", PAYLOAD_MILITARY_CONTROL_V1,
		AGG_COUNT, VALUE_I64, -1, 0, 1, 0, "城池易手",
		"控制权变更的格数（含占领与光复）。"],
	[7, "military.control.occupied", "43", PAYLOAD_MILITARY_CONTROL_V1,
		AGG_COUNT, VALUE_I64, PAYLOAD_I3, 1, 1, 0, "城池陷落",
		"聚落等级 ≥ 1 的格被敌方占领。i3 = 城堡等级档。"],
	[8, "military.army.destroyed", "44", PAYLOAD_MILITARY_BATTLE_V1,
		AGG_COUNT, VALUE_I64, -1, 0, 1, 0, "全军覆没",
		"一支部队被歼灭的次数。"],
	[9, "military.army.losses", "44", PAYLOAD_MILITARY_BATTLE_V1,
		AGG_SUM, VALUE_I64, -1, 0, 5000, 0, "折戟沉沙",
		"被歼灭部队的累计人数。"],
	[10, "military.country.annexed", "45", PAYLOAD_MILITARY_ANNEX_V1,
		AGG_COUNT, VALUE_I64, -1, 0, 1, 0, "国破",
		"国家被吞并（只能经由和议）。"],
	[11, "military.convoy.intercepted", "46", PAYLOAD_MILITARY_CONVOY_V1,
		AGG_SUM, VALUE_I64, -1, 0, 1000, 0, "粮道被断",
		"被截获军需车队的累计货值。"],
	[12, "military.levy.applied", "47", PAYLOAD_MILITARY_LEVY_V1,
		AGG_SUM, VALUE_I64, -1, 0, 500, 0, "征发",
		"征发入伍的累计人数（每 epoch 每格一次）。"],
	[13, "military.war.front_holds", "42", PAYLOAD_MILITARY_BATTLE_V1,
		AGG_WINDOW_COUNT, VALUE_I64, PAYLOAD_I3, 2, 3, 180, "固守防线",
		"一百八十日内在大型会战中取胜的次数。"],
]

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
	[28, "hide_working", "breakthrough.hide_working", 1],
]

## These facts are emitted only after a cross-country delivery of the matching
## crop sample, fiber, ore or vessel. Merely knowing a trade route never creates contact.
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
	[10, "bast_fiber", "contact.bast_fiber"],
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
		"qualifier_thresholds": PackedInt64Array(),
		"duration_fields": PackedInt32Array(),
		"development_metric_ids": PackedInt32Array(),
		"development_era_indices": PackedInt32Array(),
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
	compiled_definitions.append_array(_development_definitions())
	compiled_definitions.append_array(_family_buff_definitions())
	# Military facts use source 5 and types 40..47. A narrow catalog (unit tests
	# with a small source_count / event_type_span) cannot address them, so the
	# built-in military counters are only compiled where they fit.
	for military_definition in _military_definitions():
		if military_definition.source_id < source_count \
				and military_definition.event_type < event_type_span:
			compiled_definitions.append(military_definition)
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
		out.qualifier_thresholds.append(definition.qualifier_threshold)
		out.duration_fields.append(definition.duration_field)
		out.development_metric_ids.append(definition.development_metric_id)
		out.development_era_indices.append(definition.development_era_index)
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


## Effect catalog 用这些行预编译 trigger.country.* command 模板。
## 必须覆盖 TriggerRuntime 会开火的全部 COUNTRY_COMMAND 信号，否则 handoff
## 会卡在 trigger_effect_definition_not_compiled，钉死当日日历。
static func breakthrough_effect_rows() -> Array[Dictionary]:
	var signal_catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	if not bool(signal_catalog.get("ok", false)):
		return []
	var signal_ids: PackedStringArray = signal_catalog.get(
		"research_signal_ids", PackedStringArray())
	var rows: Array[Dictionary] = []
	var seen_signals := {}
	var authored_rows: Array = BREAKTHROUGH_RULES + CONTACT_RULES + WEATHER_RULES
	for definition in DevelopmentAchievementCatalogScript.definitions():
		authored_rows.append([0, "", String(definition.signal_id)])
	for row in authored_rows:
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
			"command_key": _country_signal_command_key(signal_id),
		})
	return rows


static func _country_signal_command_key(signal_id: String) -> String:
	if signal_id.begins_with("contact."):
		return "contact.discover"
	if signal_id.begins_with("weather."):
		return "weather.discover"
	if signal_id.begins_with("development."):
		return "development.discover"
	return "breakthrough.discover"


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


static func _development_definitions() -> Array[Resource]:
	var signal_catalog: Dictionary = ResearchSignalCatalogScript.compile_native_catalog()
	var signal_ids: PackedStringArray = signal_catalog.get(
		"research_signal_ids", PackedStringArray())
	var compiled: Dictionary = DevelopmentAchievementCatalogScript.compile_native_catalog(signal_ids)
	var out: Array[Resource] = []
	if not bool(signal_catalog.get("ok", false)) or not bool(compiled.get("ok", false)):
		return out
	for metric in range((compiled.development_metric_ids as PackedStringArray).size()):
		var signal_index := int(compiled.development_metric_signal_indices[metric])
		var signal_id := String(compiled.development_metric_ids[metric])
		var definition := TriggerDefinitionScript.new()
		definition.key = StringName("development.achievement.%s" % signal_id.trim_prefix(
			"development."))
		definition.version = 1
		definition.source_id = SOURCE_NATIVE
		definition.event_type = EVENT_COUNTRY_DEVELOPMENT_METRIC
		definition.payload_schema = PAYLOAD_COUNTRY_DEVELOPMENT_V1
		definition.aggregator = AGG_CONSECUTIVE_DURATION
		definition.value_field = VALUE_I64
		definition.duration_field = PAYLOAD_I1
		definition.qualifier_threshold = int(
			compiled.development_metric_qualifier_thresholds[metric])
		definition.scope = SCOPE_ENTITY
		definition.target_resolver = TARGET_EVENT_ENTITY
		definition.threshold = int(compiled.development_metric_duration_days[metric])
		definition.mode = MODE_ONE_SHOT
		definition.selector_field = PAYLOAD_I0
		definition.selector_value = metric
		definition.condition_ops = PackedInt32Array([2])
		definition.development_metric_id = metric
		definition.development_era_index = int(
			compiled.development_metric_era_indices[metric])
		var effect := TriggerEffectScript.new()
		effect.action = ACTION_COUNTRY_COMMAND
		effect.domain = COUNTRY_DOMAIN
		effect.opcode = COMMAND_DISCOVER_COUNTRY_SIGNAL
		effect.target_resolver = TARGET_EVENT_ENTITY
		effect.value_mode = 0
		effect.value = SOURCE_KIND_TRIGGER_OUTPUT
		effect.command_key = &"development.discover"
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


static func _family_buff_definitions() -> Array[Resource]:
	var out: Array[Resource] = []
	out.append_array(_tiered_family_buff_triggers(
		"family.buff.trade_population", "商路招佃",
		"累计跨格贸易到达后，为家族分支奖励人口。威望越高，所需累计贸易次数越低。",
		SOURCE_NATIVE, EVENT_TRADE_ARRIVED, PAYLOAD_TRADE_ARRIVED_V1,
		AGG_COUNT, 0, PackedInt32Array([5, 5, 4, 3, 2, 1]),
		ACTION_ECONOMY_COMMAND, 2, &"family.population_reward", &"", -1, 0,
		-1, 0, VALUE_ONE, 0, 1))
	out.append_array(_tiered_family_buff_triggers(
		"family.buff.market_window", "市集窗口",
		"三十日内完成二十次跨地区贸易后，按威望刷新本城贸易产出加成与持续时间。",
		SOURCE_NATIVE, EVENT_TRADE_ARRIVED, PAYLOAD_TRADE_ARRIVED_V1,
		AGG_WINDOW_COUNT, 30, PackedInt32Array([20, 20, 20, 20, 20, 20]),
		ACTION_MODIFIER_APPLY, 2, &"family.city.trade_output_boost",
		&"family.city.trade_output_boost", 30, 1, -1, 0, VALUE_ONE, 0, 0,
		PackedInt32Array([39322, 39322, 65536, 91750, 117965, 157286]),
		PackedInt32Array([30, 30, 45, 60, 90, 120])))
	out.append_array(_tiered_family_buff_triggers(
		"family.buff.construction_gift", "营造馈赠",
		"累计建设完工后，为家族分支免费建成一座建筑。威望越高，所需累计建设次数越低。",
		SOURCE_NATIVE, EVENT_CONSTRUCTION_COMPLETED, PAYLOAD_CONSTRUCTION_COMPLETED_V1,
		AGG_SUM, 0, PackedInt32Array([10, 10, 8, 6, 3, 1]),
		ACTION_ECONOMY_COMMAND, 2, &"family.free_building", &"", -1, 0,
		-1, 0, VALUE_I64, 0, 1))
	out.append_array(_tiered_family_buff_triggers(
		"family.buff.drought_store", "旱年储备",
		"连续干旱达到天数门槛后，降低本城主食消费。威望越高，连续天数门槛越高。",
		SOURCE_GDSCRIPT, EVENT_WEATHER_OBSERVED, PAYLOAD_WEATHER_OBSERVED_V1,
		AGG_CONSECUTIVE_DURATION, 0, PackedInt32Array([30, 45, 60, 90, 120, 180]),
		ACTION_MODIFIER_APPLY, 2, &"family.city.staple_consumption_cut",
		&"family.city.staple_consumption_cut", 30, 1, PAYLOAD_I0, 2, VALUE_I64, 0, 0,
		PackedInt32Array([32768, 32768, 65536, 98304, 131072, 163840])))
	return out


static func _tiered_family_buff_triggers(prefix: String, display_name: String,
		description: String, source_id: int, event_type: int, payload_schema: int,
		aggregator: int, window_days: int, thresholds: PackedInt32Array,
		action: int, domain: int, command_key: StringName, definition_key: StringName,
		duration_days: int, opcode: int, selector_field: int = -1,
		selector_value: int = 0, value_field: int = VALUE_I64,
		effect_value_mode: int = 1, effect_value: int = 0,
		effect_values: PackedInt32Array = PackedInt32Array(),
		durations: PackedInt32Array = PackedInt32Array()) -> Array[Resource]:
	var out: Array[Resource] = []
	for tier in range(mini(6, thresholds.size())):
		var definition := TriggerDefinitionScript.new()
		definition.key = StringName("%s_t%d" % [prefix, tier])
		definition.version = 1
		definition.display_name = "%s·%d档" % [display_name, tier]
		definition.description = description
		definition.source_id = source_id
		definition.event_type = event_type
		definition.payload_schema = payload_schema
		definition.aggregator = aggregator
		definition.value_field = value_field
		definition.scope = SCOPE_ENTITY
		definition.target_resolver = TARGET_SOURCE_ENTITY
		definition.threshold = int(thresholds[tier])
		definition.mode = MODE_REPEAT
		definition.window_days = window_days
		definition.dynamic_binding = true
		definition.selector_field = selector_field
		definition.selector_value = selector_value
		definition.condition_ops = PackedInt32Array([2])
		if aggregator == AGG_CONSECUTIVE_DURATION:
			definition.duration_field = 0
			definition.qualifier_threshold = 0
		var effect := TriggerEffectScript.new()
		effect.action = action
		effect.source_priority = 100
		effect.domain = domain
		effect.opcode = opcode
		effect.value_mode = effect_value_mode
		if tier < effect_values.size():
			effect.value = int(effect_values[tier])
		else:
			effect.value = effect_value
		if tier < durations.size():
			effect.duration_days = int(durations[tier])
		else:
			effect.duration_days = duration_days
		effect.command_key = command_key
		effect.definition_key = definition_key
		definition.effects.append(effect)
		out.append(definition)
	return out


static func _signed_hash32(value: String) -> int:
	var hashed := int(value.hash())
	return hashed - 0x100000000 if hashed > 0x7fffffff else hashed


## Military trigger keys. Source id is SOURCE_MILITARY (the forwarder stamps
## military batches with the same id); effects are authored per content card, so
## these definitions intentionally carry no effect and act as the counter
## surface that Effect/Trigger content binds to.
static func _military_definitions() -> Array[Resource]:
	var out: Array[Resource] = []
	for row in MILITARY_RULES:
		var event_type_text := String(row[2])
		var event_types := PackedInt32Array()
		for chunk in event_type_text.split(",", false):
			event_types.append(int(chunk.strip_edges()))
		if event_types.is_empty() or event_types.size() > MILITARY_EVENT_TYPE_MAX_PER_KEY:
			return out
		for event_type in event_types:
			if event_type < EVENT_MILITARY_WAR_DECLARED or event_type > EVENT_MILITARY_LEVY_APPLIED:
				return out
		for event_type in event_types:
			var definition := TriggerDefinitionScript.new()
			var key_suffix := "" if event_types.size() == 1 else "_e%d" % event_type
			definition.key = StringName("%s%s" % [String(row[1]), key_suffix])
			definition.version = 1
			definition.display_name = String(row[10])
			definition.description = String(row[11])
			definition.source_id = SOURCE_MILITARY
			definition.event_type = event_type
			definition.payload_schema = int(row[3])
			definition.aggregator = int(row[4])
			definition.value_field = int(row[5])
			definition.scope = SCOPE_ENTITY
			# Military facts always name their country in payload i0; `cell` is
			# only a hint for the map, never the trigger scope key.
			definition.target_resolver = TARGET_EVENT_ENTITY
			definition.threshold = int(row[8])
			definition.mode = MODE_ONE_SHOT
			definition.window_days = int(row[9])
			definition.selector_field = int(row[6])
			definition.selector_value = int(row[7])
			definition.condition_ops = PackedInt32Array([2]) # PUSH_ACC_GTE
			out.append(definition)
	out.append_array(_military_stack_definitions())
	return out


## §17.1 channel C ("会战事件叠层"): one Modifier stack per qualifying fact.
##
## WHY THESE ARE SEPARATE FROM `MILITARY_RULES`
## --------------------------------------------
## `MILITARY_RULES` is the COUNTER surface: `MODE_ONE_SHOT`, threshold > 1, no
## effect, so a research/petition trigger can ask "won ten battles yet". Channel
## C needs the opposite shape -- every single event must add a timed stack -- so
## these rows use `MODE_REPEAT` with `threshold = 1` and a `COUNT` aggregator,
## which fires once per event, and carry a `MODIFIER_APPLY` effect with the
## card's `duration_days`.
##
## Columns: key suffix, event type, value field used as the selector, selector
## value (-1 = no payload filter), display name, description.
##
## The public key is `military.stack.<suffix>`; the content tool binds a card to
## it with `definition_key`. `source_priority` is the same 100 the other family
## buff triggers use, so TriggerRuntime orders them ahead of research signals.
const MILITARY_STACK_RULES := [
	[0, "battle_won", EVENT_MILITARY_BATTLE_RESOLVED, -1, 0, "乘胜",
		"每赢得一场会战，叠加一层限时加成效力。"],
	[1, "battle_lost", EVENT_MILITARY_BATTLE_RESOLVED, -1, 0, "哀兵",
		"每输掉一场会战，叠加一层限时加成效力。"],
	[2, "cell_captured", EVENT_MILITARY_CELL_CONTROL_CHANGED, -1, 0, "得地",
		"每占领一格，叠加一层限时加成效力。"],
	[3, "cell_lost", EVENT_MILITARY_CELL_CONTROL_CHANGED, -1, 0, "失地",
		"每失去一格，叠加一层限时加成效力。"],
]

## Key prefix of the channel-C stack triggers. Authored in one place so the
## content tool and `trigger_key_for_stack()` cannot drift.
const MILITARY_STACK_KEY_PREFIX := "military.stack."


## Public trigger key for one channel-C stack rule, by suffix.
static func trigger_key_for_stack(suffix: String) -> StringName:
	return StringName(MILITARY_STACK_KEY_PREFIX + suffix)


## §17.1 channel C. `definition_key`/`duration_days` are injected by the authoring
## tool through `TriggerCatalogScript.set_military_stack_effect()`; the shipped
## defaults carry no effect so a catalog without military content is inert.
static var _military_stack_effects: Dictionary = {}


## Registers the Modifier definition + duration a channel-C stack applies.
##
## Kept as a static side table rather than a constant because the values are
## per-card content (each card owns its own definition key and day count), and a
## second copy of them in this file would be a second source of truth for what a
## card does. Returns false for an unknown suffix so a typo fails at authoring
## time instead of silently producing an effect-less trigger.
static func set_military_stack_effect(suffix: String, definition_key: StringName,
		duration_days: int, stacks: int = 1) -> bool:
	var known := false
	for row in MILITARY_STACK_RULES:
		if String(row[1]) == suffix:
			known = true
			break
	if not known or definition_key == &"" or duration_days < 1:
		return false
	_military_stack_effects[suffix] = {
		"definition_key": definition_key,
		"duration_days": duration_days,
		"stacks": maxi(1, stacks),
	}
	return true


static func military_stack_effect(suffix: String) -> Dictionary:
	var row: Variant = _military_stack_effects.get(suffix, {})
	return row if row is Dictionary else {}


static func _military_stack_definitions() -> Array[Resource]:
	var out: Array[Resource] = []
	for row in MILITARY_STACK_RULES:
		var suffix := String(row[1])
		var definition := TriggerDefinitionScript.new()
		definition.key = trigger_key_for_stack(suffix)
		definition.version = 1
		definition.display_name = String(row[5])
		definition.description = String(row[6])
		definition.source_id = SOURCE_MILITARY
		definition.event_type = int(row[2])
		definition.payload_schema = NationalGameplayPayloadSchema(int(row[2]))
		# COUNT over threshold 1 is "once per event": each battle or control
		# change is one stack, which is what a 层 counter means.
		definition.aggregator = AGG_COUNT
		definition.value_field = VALUE_ONE
		definition.scope = SCOPE_ENTITY
		definition.target_resolver = TARGET_EVENT_ENTITY
		definition.threshold = 1
		definition.mode = MODE_REPEAT
		definition.selector_field = int(row[3])
		definition.selector_value = int(row[4])
		definition.condition_ops = PackedInt32Array([2]) # PUSH_ACC_GTE
		var effect_spec := military_stack_effect(suffix)
		if not effect_spec.is_empty():
			var effect := TriggerEffectScript.new()
			effect.action = ACTION_MODIFIER_APPLY
			effect.source_priority = 100
			effect.domain = 1 # ModifierRuntime::COUNTRY: the stacks are national
			effect.opcode = 1
			effect.target_resolver = TARGET_EVENT_ENTITY
			# Every event is one stack, so the magnitude is a constant; the stack
			# COUNT is what the layer policy multiplies.
			effect.value_mode = 0
			effect.value = 0
			effect.duration_days = int(effect_spec["duration_days"])
			effect.stacks = int(effect_spec["stacks"])
			effect.command_key = &"ideology.stack"
			effect.definition_key = StringName(effect_spec["definition_key"])
			definition.effects.append(effect)
		out.append(definition)
	return out


## Payload schema for a military event type, mirrored from
## GameplayEventBus.military_payload_schema(). Local so this catalog does not
## preload the bus, which would make TriggerCatalog depend on the event layer.
static func NationalGameplayPayloadSchema(event_type: int) -> int:
	match event_type:
		EVENT_MILITARY_WAR_DECLARED, EVENT_MILITARY_WAR_ENDED:
			return PAYLOAD_MILITARY_WAR_V1
		EVENT_MILITARY_BATTLE_RESOLVED, EVENT_MILITARY_ARMY_DESTROYED:
			return PAYLOAD_MILITARY_BATTLE_V1
		EVENT_MILITARY_CELL_CONTROL_CHANGED:
			return PAYLOAD_MILITARY_CONTROL_V1
		EVENT_MILITARY_COUNTRY_ANNEXED:
			return PAYLOAD_MILITARY_ANNEX_V1
		EVENT_MILITARY_CONVOY_INTERCEPTED:
			return PAYLOAD_MILITARY_CONVOY_V1
		_:
			return PAYLOAD_MILITARY_LEVY_V1


## Event type -> military rule keys, for Trigger selection diagnostics and for
## content authorship (which key a Card may reference).
static func military_event_type_keys() -> Dictionary:
	var out := {}
	for row in MILITARY_RULES:
		for chunk in String(row[2]).split(",", false):
			var event_type := int(chunk.strip_edges())
			var keys: Array = out.get(event_type, [])
			keys.append(String(row[1]))
			out[event_type] = keys
	return out
