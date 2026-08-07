class_name IdeologyDefinition
extends Resource

const IdeologyLevelDefinitionScript = preload("res://scripts/ideology/ideology_level_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")

enum Acquisition { DISCOVER = 1, DRAW = 2 }

@export var id: StringName = &""
@export var icon_key: StringName = &""
@export var name_key: StringName = &""
@export_multiline var detail_key: String = ""
@export_range(1, 1000000, 1) var rarity_weight: int = 100
@export_range(1, 64, 1) var ideology_slot_cost: int = 1
@export_range(1, 64, 1) var national_spirit_slot_cost: int = 1
@export_flags("Discover", "Draw") var acquisition_flags: int = Acquisition.DISCOVER | Acquisition.DRAW
@export_range(0, 63, 1) var national_spirit_min_level: int = 0
@export var draw_requirements: Array[Resource] = []
@export var levels: Array[Resource] = []

func validate() -> String:
	if id == &"" or rarity_weight <= 0 or ideology_slot_cost <= 0 \
			or national_spirit_slot_cost <= 0 or acquisition_flags == 0:
		return "ideology_definition_invalid"
	if levels.is_empty() or levels.size() > 64:
		return "ideology_level_count_invalid"
	if national_spirit_min_level >= levels.size():
		return "ideology_national_spirit_level_invalid"
	var previous := -1
	for level in levels:
		if level == null or not level is IdeologyLevelDefinitionScript:
			return "ideology_level_resource_invalid"
		if level.understanding_threshold_q16 < previous:
			return "ideology_threshold_order_invalid"
		previous = level.understanding_threshold_q16
	for requirement in draw_requirements:
		if requirement == null or not requirement is IdeologyRequirementScript \
			or requirement.key == &"":
			return "ideology_requirement_invalid"
	return ""
