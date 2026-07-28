class_name ModifierStatDefinition
extends Resource

@export var key: StringName
@export_enum("Climate", "Country", "Economy", "Gameplay") var domain: int = 0
@export var min_value: float = 0.0
@export var max_value: float = 1.0
@export var persistable: bool = true
@export_flags("Add", "Subtract", "Multiply", "Divide") var allowed_operations: int = 15
@export_enum("Double", "EconomyFixedPoint") var value_conversion: int = 0
