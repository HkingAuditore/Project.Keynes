class_name ResearchPredicate
extends Resource

enum Kind {
	TECH_COMPLETED,
	SIGNAL_PRESENT,
	SIGNAL_COUNT,
	SIGNAL_VALUE,
	EVENT_OCCURRED,
	CURRENT_STATE,
	COUNTRY_FLAG,
	COUNTRY_STAT,
	BUILDING_COUNT,
	GOOD_STOCK,
}

enum Comparator {
	EQUAL,
	NOT_EQUAL,
	GREATER_EQUAL,
	GREATER,
	LESS_EQUAL,
	LESS,
}

@export var kind: Kind = Kind.TECH_COMPLETED
@export var reference_id: StringName = &""
@export var comparator: Comparator = Comparator.GREATER_EQUAL
@export var value: int = 1
@export var scope: int = 0
@export var window_days: int = 0
@export var selector_tags: PackedStringArray = PackedStringArray()
