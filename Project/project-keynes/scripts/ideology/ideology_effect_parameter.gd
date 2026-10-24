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
	## X5: replace the program's selector tag with `tag_value` (a single tag
	## name or a `|`-separated union). Applied per country while its synergy is
	## active, so the program itself stays immutable and shared.
	TAG = 5,
	## X5: replace the selector kind. Only the radial pairs 6<->7 and 14<->15
	## are allowed by the generator's pair lint.
	SELECTOR_KIND = 6,
	## X5: replace `target_selector_param[0]` (the per-selector cell cap).
	SELECTOR_CAP = 7,
}

## Which programs a runtime rewrite applies to.
enum MatchKind {
	PROGRAM = 0,
	TAG = 1,
	## Compile-only: IdeologyCatalog expands each ROUTE row into PROGRAM rows
	## before the native runtime sees it.
	ROUTE = 2,
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
	Field.TAG: "tag",
	Field.SELECTOR_KIND: "selector_kind",
	Field.SELECTOR_CAP: "selector_cap",
}

@export var target_definition_key: StringName = &""
@export_enum("DurationDays:0", "MaxStacks:1", "CadenceDays:2", "Priority:3",
	"MagnitudeScale:4", "Tag:5", "SelectorKind:6", "SelectorCap:7")
var field: int = Field.DURATION_DAYS
@export_range(-2147483648, 2147483647, 1) var value: int = 0
## X5 match selector. Legacy magnitude-scale rows leave these at their defaults,
## which means "the program named by target_definition_key".
@export_enum("Program:0", "Tag:1", "Route:2") var match_kind: int = MatchKind.PROGRAM
@export var match_value: StringName = &""
## TAG-field replacement. Unlike `value`, this is a name so it can be renumbered
## with the rest of the target-tag dictionary.
@export var tag_value: StringName = &""
## Free-form note. Overrides are the kind of data that looks arbitrary six months
## later, so the reason travels with the row.
@export_multiline var note: String = ""


func field_key() -> StringName:
	return StringName(String(FIELD_KEYS.get(field, "")))


## Canonical name of a TAG replacement. Sorting makes `a|b` and `b|a` resolve to
## one synthetic dictionary entry, and keeps the generator/native contract
## independent of authored order.
func tag_union_name() -> String:
	if field != Field.TAG:
		return ""
	var names := PackedStringArray()
	for part in String(tag_value).split("|", false):
		var name := String(part).strip_edges()
		if not name.is_empty() and not names.has(name):
			names.append(name)
	names.sort()
	return "|".join(names)


func validate() -> String:
	if not FIELD_KEYS.has(field):
		return "ideology_effect_parameter_field_invalid"
	if match_kind not in [MatchKind.PROGRAM, MatchKind.TAG, MatchKind.ROUTE]:
		return "ideology_effect_parameter_match_kind_invalid"
	var match_text := String(match_value).strip_edges()
	if match_text.is_empty() and match_kind == MatchKind.PROGRAM:
		match_text = String(target_definition_key).strip_edges()
	if match_text.is_empty():
		return "ideology_effect_parameter_match_value_missing"
	if match_kind == MatchKind.PROGRAM and target_definition_key == &"":
		return "ideology_effect_parameter_target_missing"
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
		Field.TAG:
			var tag_text := String(tag_value).strip_edges()
			if tag_text.is_empty():
				return "ideology_effect_parameter_tag_missing"
			if value != 0:
				return "ideology_effect_parameter_tag_value_invalid"
			var seen := {}
			for part in tag_text.split("|", false):
				var name := String(part).strip_edges()
				if name.is_empty():
					return "ideology_effect_parameter_tag_name_empty"
				if seen.has(name):
					return "ideology_effect_parameter_tag_name_duplicate"
				seen[name] = true
		Field.SELECTOR_KIND:
			if value not in [
					IdeologyEffectDefinition.TargetSelectorKind.NEIGHBORS_R1,
					IdeologyEffectDefinition.TargetSelectorKind.NEIGHBORS_R2,
					IdeologyEffectDefinition.TargetSelectorKind.TAG_SOURCE_R1,
					IdeologyEffectDefinition.TargetSelectorKind.TAG_SOURCE_R2]:
				return "ideology_effect_parameter_selector_kind_invalid"
		Field.SELECTOR_CAP:
			if value < 1 or value > IdeologyEffectDefinition.SELECTOR_MAX_CELLS:
				return "ideology_effect_parameter_selector_cap_invalid"
	if field != Field.TAG and tag_value != &"":
		return "ideology_effect_parameter_tag_value_unexpected"
	return ""
