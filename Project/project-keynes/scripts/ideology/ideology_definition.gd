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
## A card counts toward at most three routes: one primary + two extra. The cap
## exists so a typo loop cannot quietly enrol one card into every bond.
const MAX_SECONDARY_ROUTE_TAGS := 2

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
## Primary build route (体系) of this card. Read at compile time by
## `IdeologyCatalog` to expand route-tag synergies into concrete requirement
## rows, and by the collection UI as the "体系" label. A card with this set is
## counted by that route's bonds even when it names none of its siblings.
@export var route_tag: StringName = &""
## Extra build routes this card also belongs to -- the design intends many
## cards to carry a second 体系 ("会参与两个体系的羁绊计数"). Kept separate from
## `route_tag` instead of turning it into an array so the primary route stays a
## single authored field with no ordering rule to remember.
@export var secondary_route_tags: PackedStringArray = PackedStringArray()
## X6-c: this card's persistent programs come from the card in the immediately
## left ideology slot. The copier owns fresh Effect instances under its own
## (ideology_id, level) identity. Legendary/rule cards are never copy sources.
@export var copy_left_programs: bool = false
## Whether another card may use this definition's programs as a copy source.
## The generator writes false for every Legendary/rule card.
@export var copyable: bool = true

## Every build route this card belongs to: the primary first, then the extras,
## de-duplicated and with blanks dropped. Single source of truth for both the
## compile-time route index and the UI label list -- callers must go through
## here rather than reading `route_tag` on its own.
func route_tags() -> PackedStringArray:
	var tags := PackedStringArray()
	var primary := String(route_tag).strip_edges()
	if not primary.is_empty():
		tags.append(primary)
	for value in secondary_route_tags:
		var tag := String(value).strip_edges()
		if tag.is_empty() or tags.has(tag):
			continue
		tags.append(tag)
	return tags


func validate() -> String:
	if id == &"" or rarity_weight <= 0 or ideology_slot_cost <= 0 \
			or national_spirit_slot_cost <= 0 or acquisition_flags == 0 \
			or rarity < Rarity.COMMON or rarity > Rarity.LEGENDARY:
		return "ideology_definition_invalid"
	if era_index < 0 or era_index > MAX_ERA_INDEX:
		return "ideology_era_index_invalid"
	if secondary_route_tags.size() > MAX_SECONDARY_ROUTE_TAGS:
		return "ideology_route_tag_count_invalid"
	# A repeat is rejected rather than folded. `route_tags()` de-duplicates so a
	# route index can never double-count the same card, but folding here too
	# would hide the only signal a copy-paste mistake leaves behind.
	var primary_route := String(route_tag).strip_edges()
	var seen_routes := {}
	if not primary_route.is_empty():
		seen_routes[primary_route] = true
	for value in secondary_route_tags:
		var route := String(value).strip_edges()
		if route.is_empty():
			return "ideology_route_tag_empty"
		if seen_routes.has(route):
			return "ideology_route_tag_duplicate"
		seen_routes[route] = true
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
