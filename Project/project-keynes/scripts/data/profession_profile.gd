class_name ProfessionProfile
extends Resource

## Stable identity fields. Display data may change without invalidating saves.
@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null
@export var default_consumption_plan_id: StringName = &""
## Executable availability requirements. Only `tech.*` tags are interpreted by
## the economy runtime; other namespaces remain descriptive metadata.
@export var technology_tags: PackedStringArray = PackedStringArray()

## Per-person, per-day Q32 demographic rates.
## 3.0% births and 2.5% natural deaths per 365-day year produce a
## fully-satisfied long-run net growth target of approximately 0.5%.
@export var birth_rate_q32: int = 353011
@export var death_rate_q32: int = 294176
@export var satisfaction_birth_weight_q16: int = 65536
