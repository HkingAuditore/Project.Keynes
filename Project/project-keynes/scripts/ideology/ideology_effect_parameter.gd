class_name IdeologyEffectParameter
extends Resource

## One entry in the ideology program override layer (L3-9, first slice).
##
## Why this exists
## ---------------
## A program's shape -- how long its instances live, how many stacks they hold,
## how often they tick, how they order against other programs -- is frozen into
## `FamilyEffectMetadataPod` at catalog compile time. That means one card cannot
## currently change another card's program, which is the prerequisite for every
## "命名协同" in the design (§6.2) and for most of X5.
##
## This resource is the override ENTRY: "for program X, field F becomes V". The
## layer is applied by `IdeologyEffectCatalog.apply_overrides()` while the
## programs are translated into EffectDefinitions, so what the runtime receives is
## already the overridden program -- no new column, no save-format change, and the
## hash of the compiled catalog changes exactly when the override does.
##
## What this slice does NOT do: an override is unconditional and catalog-wide.
## Conditional / per-country overrides ("while this card is equipped, that
## program's duration is longer") need the runtime-side table and the parameter
## plumbing described in §34.5. Having the compile-time half in place is what
## makes that second step a delta rather than a redesign.

enum Field {
	DURATION_DAYS = 0,
	MAX_STACKS = 1,
	CADENCE_DAYS = 2,
	PRIORITY = 3,
	## Per-instance effect multiplier. Unlike the four above, this one is applied
	## at RUNTIME (see §37): a synergy that carries this row rewrites the target
	## program's strength for every country where the synergy is active.
	MAGNITUDE_SCALE = 4,
}

## The band the runtime clamps to. Mirrored here so an author sees the limit at
## edit time instead of watching the value get silently squeezed in native.
const MAGNITUDE_SCALE_MIN := 16384   # 0.25x
const MAGNITUDE_SCALE_MAX := 262144  # 4x

const FIELD_KEYS := {
	Field.DURATION_DAYS: "duration_days",
	Field.MAX_STACKS: "max_stacks",
	Field.CADENCE_DAYS: "cadence_days",
	Field.PRIORITY: "priority",
	Field.MAGNITUDE_SCALE: "magnitude_scale_q16",
}

@export var target_definition_key: StringName = &""
@export_enum("DurationDays:0", "MaxStacks:1", "CadenceDays:2", "Priority:3")
var field: int = Field.DURATION_DAYS
@export_range(-2147483648, 2147483647, 1) var value: int = 0
## Free-form note. Overrides are the kind of data that looks arbitrary six months
## later, so the reason travels with the row.
@export_multiline var note: String = ""


func field_key() -> StringName:
	return StringName(String(FIELD_KEYS.get(field, "")))


func validate() -> String:
	if target_definition_key == &"":
		return "ideology_effect_parameter_target_missing"
	if not FIELD_KEYS.has(field):
		return "ideology_effect_parameter_field_invalid"
	# Per-field ranges mirror `IdeologyEffectDefinition.validate()`, because an
	# override that the program itself would reject must not be able to sneak a
	# bad value in after validation has already run.
	match field:
		Field.DURATION_DAYS:
			if value == 0 or value < -1:
				return "ideology_effect_parameter_duration_invalid"
		Field.MAX_STACKS:
			if value < 1 or value > 256:
				return "ideology_effect_parameter_max_stacks_invalid"
		Field.CADENCE_DAYS:
			if value < 1 or value > 3650:
				return "ideology_effect_parameter_cadence_invalid"
		Field.PRIORITY:
			if value < -65536 or value > 65536:
				return "ideology_effect_parameter_priority_invalid"
		Field.MAGNITUDE_SCALE:
			if value < MAGNITUDE_SCALE_MIN or value > MAGNITUDE_SCALE_MAX:
				return "ideology_effect_parameter_magnitude_scale_invalid"
	return ""
