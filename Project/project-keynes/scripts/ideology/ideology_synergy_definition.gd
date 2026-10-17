class_name IdeologySynergyDefinition
extends Resource

const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")

@export var id: StringName = &""
@export var display_name: String = ""
@export var required_ideology_ids: PackedStringArray = PackedStringArray()
@export var minimum_levels: PackedInt32Array = PackedInt32Array()
## Bit 1 accepts equipped ideology; bit 2 accepts national spirit.
@export var location_masks: PackedByteArray = PackedByteArray()
## 0 requires every row (named synergy); N>0 activates once N rows hold
## (school resonance tiers).
@export_range(0, 64, 1) var min_count: int = 0
## Non-empty for school resonance rows; resonance_tier is the 1-based tier.
@export var school_id: StringName = &""
@export_range(0, 8, 1) var resonance_tier: int = 0
@export var persistent_effects: Array[Resource] = []


func validate() -> String:
	if id == &"" or required_ideology_ids.is_empty() \
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
	return ""
