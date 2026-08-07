class_name IdeologyRequirement
extends Resource

enum Kind { TECHNOLOGY = 1, RESEARCH_SIGNAL = 2, GATE = 3 }

@export var kind: int = Kind.TECHNOLOGY
@export var key: StringName = &""
