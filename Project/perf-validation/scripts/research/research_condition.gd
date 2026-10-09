class_name ResearchCondition
extends Resource

enum Operator {
	ATOM,
	ALL_OF,
	ANY_OF,
	AT_LEAST,
	NONE_OF,
	NOT,
	SEQUENCE,
	WITHIN_DAYS,
}

@export var operator: Operator = Operator.ATOM
@export var children: Array[Resource] = []
@export var atom: Resource
@export var required_count: int = 0
@export var window_days: int = 0
