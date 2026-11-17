extends RefCounted

const TriggerDefinitionScript = preload("res://scripts/trigger/trigger_definition.gd")

const TriggerEffectScript = preload("res://scripts/trigger/trigger_effect.gd")

const ResearchSignalCatalogScript = preload("res://scripts/research/research_signal_catalog.gd")

const DevelopmentAchievementCatalogScript = preload(
	"res://scripts/research/development_achievement_catalog.gd")

const AGG_COUNT := 1

const AGG_SUM := 2

const AGG_CONSECUTIVE_DURATION := 10

const TARGET_EVENT_ENTITY := 2

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

const VALUE_I64 := 1

const PAYLOAD_I0 := 2

const PAYLOAD_I1 := 3

const ACTION_COUNTRY_COMMAND := 10

const COUNTRY_DOMAIN := 1

const COMMAND_DISCOVER_COUNTRY_SIGNAL := 14

const SOURCE_KIND_TRIGGER_OUTPUT := 4

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
	[11, "medicinal_herb", "contact.medicinal_herb"],
]

const WEATHER_RULES := [
	[0, "typhoon", "weather.typhoon", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[1, "major_flood", "weather.major_flood", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[2, "drought", "weather.drought", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[3, "monsoon", "weather.monsoon", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[4, "frost", "weather.frost", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[5, "storm_surge", "weather.storm_surge", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[6, "repeated_crop_failure", "weather.repeated_crop_failure", SOURCE_NATIVE, AGG_SUM, 3],
	# 7-9 are published by scripts/research/weather_research_signal_publisher.gd.
	# row[0] must equal the publisher's RULE_* constant: it becomes the trigger
	# selector on payload_i0.
	[7, "heatwave", "weather.heatwave", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[8, "freeze_thaw", "weather.freeze_thaw", SOURCE_GDSCRIPT, AGG_COUNT, 1],
	[9, "prolonged_wet_season", "weather.prolonged_wet_season", SOURCE_GDSCRIPT, AGG_COUNT, 1],
]

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
