class_name IdeologyDefinition
extends Resource

const IdeologyLevelDefinitionScript = preload("res://scripts/ideology/ideology_level_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const IdeologyClassStanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const IdeologyAffinityScript = preload("res://scripts/ideology/ideology_affinity.gd")

enum Acquisition { DISCOVER = 1, DRAW = 2 }
enum Rarity { COMMON = 1, RARE = 2, LEGENDARY = 3 }

const RARITY_LABELS := {1: "寻常", 2: "珍稀", 3: "传世"}
## Upper bound of the era table in data/technology/technology_network.json.
## tests/ideology_content_test.gd asserts this matches the live era count.
const MAX_ERA_INDEX := 10
const MAX_AFFINITIES := 8

@export var id: StringName = &""
@export var icon_key: StringName = &""
@export var name_key: StringName = &""
@export_multiline var detail_key: String = ""
## School (流派) used by resonance synergies and the collection tabs.
@export var school_id: StringName = &""
@export_enum("Common:1", "Rare:2", "Legendary:3") var rarity: int = Rarity.COMMON
@export_range(1, 1000000, 1) var rarity_weight: int = 100
@export_range(1, 64, 1) var ideology_slot_cost: int = 1
@export_range(1, 64, 1) var national_spirit_slot_cost: int = 1
@export_flags("Discover", "Draw") var acquisition_flags: int = Acquisition.DISCOVER | Acquisition.DRAW
@export_range(0, 63, 1) var national_spirit_min_level: int = 0
@export var draw_requirements: Array[Resource] = []
@export var class_stances: Array[Resource] = []
@export_range(-65536, 65536, 1) var adopt_threshold_q16: int = 0
@export_range(-65536, 65536, 1) var repeal_threshold_q16: int = 0
@export_range(-65536, 65536, 1) var promote_threshold_q16: int = 16384
@export var exclusion_group: StringName = &""
@export var levels: Array[Resource] = []
## 0..10, matching the order of `eras` in data/technology/technology_network.json.
## The lower bound of availability is compiled into a technology requirement on
## that era's entry milestone; the draw weight then decays as later eras arrive.
@export_range(0, 10, 1) var era_index: int = 0
## Soft weight biases keyed by context gates (geo.* / dev.*). Never a veto.
@export var era_affinities: Array[Resource] = []
## Build-route label used by the collection UI and the content lint. Purely
## authoring/display metadata; the runtime never reads it.
@export var route_tag: StringName = &""

func validate() -> String:
	if id == &"" or rarity_weight <= 0 or ideology_slot_cost <= 0 \
			or national_spirit_slot_cost <= 0 or acquisition_flags == 0 \
			or rarity < Rarity.COMMON or rarity > Rarity.LEGENDARY:
		return "ideology_definition_invalid"
	if era_index < 0 or era_index > MAX_ERA_INDEX:
		return "ideology_era_index_invalid"
	if era_affinities.size() > MAX_AFFINITIES:
		return "ideology_affinity_count_invalid"
	for affinity in era_affinities:
		if affinity == null or not affinity is IdeologyAffinityScript:
			return "ideology_affinity_resource_invalid"
		var affinity_error: String = affinity.validate()
		if not affinity_error.is_empty():
			return affinity_error
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
	var seen_classes := {}
	for stance in class_stances:
		if stance == null or not stance is IdeologyClassStanceScript:
			return "ideology_stance_resource_invalid"
		var stance_error: String = stance.validate()
		if not stance_error.is_empty():
			return stance_error
		var class_id := String(stance.class_id)
		if seen_classes.has(class_id):
			return "ideology_stance_class_duplicate"
		seen_classes[class_id] = true
	return ""
