class_name ResearchSignalDefinition
extends Resource

## Static authoring definition. Runtime state stays in NativeCountryRuntime.

enum Kind {
	BIO,
	RESOURCE,
	LANDFORM,
	CLIMATE_FEATURE,
	WEATHER_EVENT,
	TECH_BREAKTHROUGH,
	TECHNOLOGY,
	COUNTRY_FLAG,
	COUNTRY_STAT,
	CONTACT,
}

enum Persistence {
	PERMANENT,
	CURRENT_STATE,
	TIME_WINDOW,
	COUNTER,
	VALUE,
}

enum ObservationMode {
	EXPLORE_CELL,
	OWN_TERRITORY,
	SURVEY,
	WITNESS_EVENT,
	TRIGGER_OUTPUT,
	SNAPSHOT,
}

@export var id: StringName = &""
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var kind: Kind = Kind.BIO
@export var persistence: Persistence = Persistence.PERMANENT
@export var observation_mode: ObservationMode = ObservationMode.EXPLORE_CELL
@export var category_tags: PackedStringArray = PackedStringArray()
@export var habitat_tags: PackedStringArray = PackedStringArray()
@export var source_tags: PackedStringArray = PackedStringArray()
@export var required_realms: PackedStringArray = PackedStringArray()
@export var window_days: int = 0
@export var requires_provenance: bool = false
