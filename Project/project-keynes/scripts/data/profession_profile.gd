class_name ProfessionProfile
extends Resource

## Stable identity fields. Display data may change without invalidating saves.
@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null
@export var default_consumption_plan_id: StringName = &""
## UI/content taxonomy only; employment identity remains the stable profession id.
@export var profession_class_id: StringName = &"general"
## Executable availability requirements. Only `tech.*` tags are interpreted by
## the economy runtime; other namespaces remain descriptive metadata.
@export var technology_tags: PackedStringArray = PackedStringArray()

## Per-person, per-day Q32 demographic rates.
## 4.0% births and 2.5% natural deaths per 365-day year produce a
## fully-satisfied long-run net growth target of approximately 1.5%.
## Satisfaction applies at half weight, preserving some births during shortages.
@export var birth_rate_q32: int = 470681
@export var death_rate_q32: int = 294176
@export var satisfaction_birth_weight_q16: int = 32768
