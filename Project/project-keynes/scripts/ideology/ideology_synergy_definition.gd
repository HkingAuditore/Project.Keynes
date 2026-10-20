class_name IdeologySynergyDefinition
extends Resource

const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const ParameterScript = preload("res://scripts/ideology/ideology_effect_parameter.gd")

@export var id: StringName = &""
@export var display_name: String = ""
## Named form: an explicit card list. Leave empty to use the route form below.
@export var required_ideology_ids: PackedStringArray = PackedStringArray()
@export var minimum_levels: PackedInt32Array = PackedInt32Array()
## Mask values, not bit indices: 2 = can sit in an ideology slot, 4 = can sit in
## a national-spirit slot, 6 = either. `validate()` enforces `& ~6 == 0`.
@export var location_masks: PackedByteArray = PackedByteArray()
## 0 requires every row (named synergy); N>0 activates once N rows hold
## (school resonance tiers).
@export_range(0, 64, 1) var min_count: int = 0
## Non-empty for school resonance rows; resonance_tier is the 1-based tier.
@export var school_id: StringName = &""
@export_range(0, 8, 1) var resonance_tier: int = 0
## Route (体系) form: instead of enumerating sibling ids, select every card whose
## `IdeologyDefinition.route_tags()` contains this tag. `IdeologyCatalog`
## expands the selection into ordinary requirement rows at compile time, so the
## native runtime stays unchanged -- it still only ever sees a flat
## (ideology, min_level, location_mask) table plus `min_count`.
##
## `min_count` stays authored ("2 张"/"4 张" tiers) and is *not* derived from
## the selection size: a route with twelve cards still opens its first tier at
## two. `route_tag_min_level` / `route_tag_location_mask` apply to every
## expanded row; the route form has no per-card overrides by design, because a
## per-card row is exactly the enumeration this field replaces.
@export var route_tag: StringName = &""
@export_range(0, 63, 1) var route_tag_min_level: int = 0
@export_flags("Equipped:2", "NationalSpirit:4") var route_tag_location_mask: int = 2
@export var persistent_effects: Array[Resource] = []
## L3-9 runtime rewrites: while this synergy is active, each row multiplies the
## magnitude of the program it names. Only `Field.MAGNITUDE_SCALE` is accepted --
## the other override fields are compile-time (L3-9 first slice) and applying
## them per country would mean per-instance program templates.
@export var overrides: Array[Resource] = []


## True when this row selects its members by 体系 tag instead of by id.
func uses_route_tag() -> bool:
	return not String(route_tag).strip_edges().is_empty()


func validate() -> String:
	if id == &"":
		return "ideology_synergy_shape_invalid"
	if uses_route_tag():
		# The two forms are alternatives, never a union: keeping both would make
		# the requirement set depend on which branch the compiler happened to
		# take, which is the class of bug this project already paid for once.
		if not required_ideology_ids.is_empty():
			return "ideology_synergy_route_tag_conflicts_with_ids"
		if route_tag_location_mask & ~6 != 0 or route_tag_location_mask == 0:
			return "ideology_synergy_route_tag_mask_invalid"
		if min_count < 1:
			return "ideology_synergy_route_tag_min_count_invalid"
	else:
		if required_ideology_ids.is_empty() \
				or minimum_levels.size() != required_ideology_ids.size() \
				or location_masks.size() != required_ideology_ids.size():
			return "ideology_synergy_shape_invalid"
		if min_count < 0 or min_count > required_ideology_ids.size():
			return "ideology_synergy_min_count_invalid"
		var seen := {}
		for index in required_ideology_ids.size():
			var ideology_id := String(required_ideology_ids[index])
			if ideology_id.is_empty() or seen.has(ideology_id) \
					or minimum_levels[index] < 0 \
					or int(location_masks[index]) & ~6 != 0 \
					or int(location_masks[index]) == 0:
				return "ideology_synergy_requirement_invalid"
			seen[ideology_id] = true
	for effect in persistent_effects:
		if effect == null or not effect is EffectCommandScript:
			return "ideology_synergy_effect_invalid"
	var seen_override_targets := {}
	for override in overrides:
		if override == null or not override is ParameterScript:
			return "ideology_synergy_override_resource_invalid"
		var override_error: String = override.validate()
		if not override_error.is_empty():
			return override_error
		if int(override.field) != ParameterScript.Field.MAGNITUDE_SCALE:
			return "ideology_synergy_override_field_invalid"
		var target := String(override.target_definition_key).strip_edges()
		if target.is_empty():
			return "ideology_synergy_override_target_empty"
		# Two rows for one target would multiply twice and read as a typo, which
		# it is: one synergy rewrites a program once.
		if seen_override_targets.has(target):
			return "ideology_synergy_override_target_duplicate"
		seen_override_targets[target] = true
	return ""
