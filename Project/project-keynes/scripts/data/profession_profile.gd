class_name ProfessionProfile
extends Resource

## Stable identity fields. Display data may change without invalidating saves.
@export var id: StringName = &""
@export var display_name: String = ""
@export var icon: Texture2D = null
@export var default_consumption_plan_id: StringName = &""

## Per-person, per-day Q32 demographic rates.
@export var birth_rate_q32: int = 0
@export var death_rate_q32: int = 0
@export var satisfaction_birth_weight_q16: int = 65536

