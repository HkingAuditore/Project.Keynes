class_name ModifierStatDefinition
extends Resource

@export var key: StringName
@export_enum("Climate", "Country", "Economy", "Gameplay") var domain: int = 0
@export var min_value: float = 0.0
@export var max_value: float = 1.0
@export var persistable: bool = true
@export_flags("Add", "Subtract", "Multiply", "Divide") var allowed_operations: int = 15
@export_enum("Double", "EconomyFixedPoint") var value_conversion: int = 0
## How the additive part folds when several SOURCES contribute to one
## (stat, scope) bucket. Sum is the historical behaviour and stays the default,
## so a stat that does not opt in behaves exactly as it did before L1-6.
##  - Sum: every row adds.
##  - MaxSource: sum within a source, then take the largest source. This is the
##    "多源取最大" the cards ask for: three adjacent paddy fields still count once.
##  - TopNSources: add the `source_cap` largest sources and drop the rest. This
##    is "多源叠加，上限 +X%".
@export_enum("Sum", "MaxSource", "TopNSources") var aggregate_policy: int = 0
## Only read by TopNSources. 0 means "no cap".
@export_range(0, 64, 1) var source_cap: int = 0
