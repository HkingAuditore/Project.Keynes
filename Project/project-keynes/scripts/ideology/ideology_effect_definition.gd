class_name IdeologyEffectDefinition
extends Resource

## Authoring-only ideology effect program. Compiled into a shared
## EffectDefinition whose key is "ideology.effect.<definition_key>", so the card
## arena can reference the program by the definition_key it already stores.
##
## Unlike a flat ModifierDefinition this carries conditions, a target selector
## and a lifecycle, which is what turns "a card gives +4%" into
## "[condition] -> {target cells} -> {result}" and lets one card's result become
## another card's condition.

const Q16_ONE := 65536

enum TargetDomain {
	SETTLEMENT_CELL = 2,
	COUNTRY = 3,
	CLIMATE = 4,
	BUILDING_RESOURCE = 5,
}

enum Operation {
	ADD = 0,
	MULTIPLY = 1,
	OVERRIDE = 2,
	CONDITIONAL_OVERRIDE = 3,
	EVENT_COMMAND = 4,
}

enum Lifecycle {
	PERMANENT = 0,
	DURATION = 1,
	EVENT_ONCE = 2,
}

enum StackPolicy {
	REPLACE = 0,
	REFRESH = 1,
	ADD_STACK = 2,
	MAX = 3,
	MIN = 4,
}

enum TargetSelectorKind {
	OWNER = 0,
	SOURCE_CELL = 2,
	SOURCE_COUNTRY = 3,
	STATIC_HANDLE = 4,
	SELECTOR_ID = 5,
	NEIGHBORS_R1 = 6,
	NEIGHBORS_R2 = 7,
	## Connected component of cells sharing the anchor's terrain.
	SAME_TERRAIN_COMPONENT = 8,
	## Connected component of cells whose dominant extracted good matches.
	SAME_RESOURCE_COMPONENT = 9,
	## Whole-map scan filtered by a runtime predicate id.
	PREDICATE_ANY_CELL = 10,
	## Every cell within `param[0]` hex steps of the anchor.
	DISTANCE_N = 11,
	## The anchor's owner's whole territory, filtered by `param[1]` = 1-based
	## tag id (0 = every owned cell). See TargetTagDictionary.
	OWN_TERRITORY = 12,
	## Every cell on the grid matching `param[1]` = 1-based tag id (0 = the
	## whole grid). The ownership-free twin of OWN_TERRITORY.
	TAG_ANY_CELL = 13,
	## X1: evaluate the radial fan-out once per SOURCE cell. `param[1]` is the
	## 1-based tag id that selects the source cells among the country's own
	## territory, `param[0]` is the union cap; each source contributes its R1
	## neighbours, the results are unioned, sorted and capped.
	##
	## Without these kinds a card like "主产铁矿的地块：周围 1 格工业 +10%" could
	## only be anchored on the country's first owned cell, so it silently buffed
	## the capital's neighbourhood instead of every iron cell's.
	TAG_SOURCE_R1 = 14,
	## Same, R2.
	TAG_SOURCE_R2 = 15,
	## Authoring ceiling. Validate against this, never against a named kind:
	## the previous check compared with DISTANCE_N, so kinds 12 and 13 were
	## rejected by the authoring layer long after the runtime accepted them.
	SELECTOR_MAX_KIND = 15,
}

## Hard cap mirrored from EffectRuntime::SELECTOR_MAX_CELLS.
const SELECTOR_MAX_CELLS := 32

## How many names `target_selector_tags` may hold. Not a runtime limit — the
## runtime sees one id either way. It is an authoring guard: the compiler folds
## the names into their DNF clause *product*, so each extra name multiplies the
## clause count, and a 6-tag card would blow the row budget on its own.
const MAX_SELECTOR_TAGS := 4

## Matches an IdeologyCatalog card-effect `definition_key`.
@export var definition_key: StringName = &""
## One player-facing line for the card face ("聚落地块：出生率 +5%，住房需求 -8%").
##
## A program row has no Modifier definition of its own, so the catalog's
## Modifier presenter cannot render it. Without this field a cell-level card
## would show only its cost line -- the effect would exist, apply, and be
## invisible. Authored here rather than derived from the commands because the
## tag condition ("聚落地块") is what makes the numbers readable, and that lives
## on the selector, not on any single command.
@export_multiline var summary: String = ""
@export var target_domain: int = TargetDomain.COUNTRY
@export var operation: int = Operation.ADD
@export var lifecycle: int = Lifecycle.PERMANENT
@export var duration_days: int = -1
@export var stack_policy: int = StackPolicy.REPLACE
@export var stack_key: StringName = &""
@export_range(1, 256, 1) var max_stacks: int = 1
@export var priority: int = 0
@export var target_selector_kind: int = TargetSelectorKind.OWNER
@export var target_selector_id: StringName = &""
## [0] = cell cap (0 = runtime default, hard cap 32), [1] = terrain id /
## resource id / predicate id / 1-based tag id, depending on the selector.
@export var target_selector_param: PackedInt32Array = PackedInt32Array([0, 0])
## Tag name for OWN_TERRITORY / TAG_ANY_CELL, e.g. &"cell.market".
##
## Written instead of `target_selector_param[1]` because that slot is a raw
## 1-based array index into the tag dictionary: an author who types 4 there is
## correct only until someone appends a tag above it, and the failure is silent
## (the card keeps working, on different cells). The catalog compiler resolves
## this name once, at build time, and hard-fails on an unknown name.
@export var target_selector_tag: StringName = &""
## Two or more tags that must ALL hold — the authoring form of a 3+-tag AND.
##
## The dictionary only ships pairwise composites (`cell.metropolis.manufacturing`
## and friends), because pre-baking every triple would be a combinatorial menu.
## This field intersects them at build time instead: the compiler folds the
## tags' DNF clause lists into one synthetic tag and appends it to the
## dictionary, so the runtime still reads a single `param[1]` id and needs no
## change at all.
##
## Use this OR `target_selector_tag`, never both — one slot, one source of truth.
## Order does not matter: names are sorted before folding, so two cards that
## list the same tags in different orders share one dictionary entry.
@export var target_selector_tags: PackedStringArray = PackedStringArray()
@export_range(1, 3650, 1) var cadence_days: int = 1
@export var conditions: Array[Resource] = []
@export var instructions: Array[Resource] = []
@export var commands: Array[Resource] = []


## Key an EffectDefinition is registered under. Static twin of `program_key()`,
## so a table of override rows can resolve a target without instantiating the
## program resource it is describing.
static func definition_key_of(bare_key: StringName) -> String:
	if bare_key == &"":
		return ""
	return "ideology.effect.%s" % String(bare_key)


func program_key() -> StringName:
	if definition_key == &"":
		return &""
	return StringName(definition_key_of(definition_key))


func to_effect_definition() -> Resource:
	var out: Resource = load("res://scripts/effect/effect_definition.gd").new()
	out.key = program_key()
	out.version = 1
	out.cadence_days = cadence_days if cadence_days > 0 else 1
	out.max_work = 128
	out.enabled = true
	out.conditions = conditions.duplicate()
	out.instructions = instructions.duplicate()
	out.commands = commands.duplicate()
	out.source_kind = 0
	out.target_domain = target_domain
	out.operation = operation
	out.lifecycle = lifecycle
	out.duration_days = duration_days
	out.stack_policy = stack_policy
	out.stack_key = stack_key
	out.max_stacks = max_stacks
	out.priority = priority
	out.target_selector_kind = target_selector_kind
	out.target_selector_id = target_selector_id
	out.target_selector_param = PackedInt32Array([
		int(target_selector_param[0]) if target_selector_param.size() > 0 else 0,
		int(target_selector_param[1]) if target_selector_param.size() > 1 else 0,
	])
	out.managed = true
	return out


func validate() -> String:
	if definition_key == &"" or program_key() == &"":
		return "ideology_effect_definition_key_missing"
	if target_domain not in [
			TargetDomain.SETTLEMENT_CELL, TargetDomain.COUNTRY,
			TargetDomain.CLIMATE, TargetDomain.BUILDING_RESOURCE]:
		return "ideology_effect_target_domain_invalid"
	if operation < 0 or operation > 4:
		return "ideology_effect_operation_invalid"
	if lifecycle < 0 or lifecycle > 2:
		return "ideology_effect_lifecycle_invalid"
	if lifecycle == Lifecycle.DURATION and duration_days < 1:
		return "ideology_effect_duration_invalid"
	if lifecycle != Lifecycle.DURATION and duration_days == 0:
		return "ideology_effect_duration_invalid"
	if stack_policy < 0 or stack_policy > 4:
		return "ideology_effect_stack_policy_invalid"
	if max_stacks < 1 or max_stacks > 256:
		return "ideology_effect_max_stacks_invalid"
	if target_selector_kind < 0 or target_selector_kind > TargetSelectorKind.SELECTOR_MAX_KIND:
		return "ideology_effect_selector_invalid"
	if target_selector_param.size() > 0 \
			and (int(target_selector_param[0]) < 0 \
			or int(target_selector_param[0]) > SELECTOR_MAX_CELLS):
		return "ideology_effect_selector_cap_invalid"
	# A tag name is only meaningful for the two tag-scoped kinds, and it must
	# not compete with a raw param[1]: two sources of truth for one slot is how
	# a card ends up filtering on a tag its author cannot see.
	if target_selector_tag != &"" and not target_selector_tags.is_empty():
		# Both forms write `param[1]`. Accepting both would mean picking a
		# winner and silently discarding the other one's intent.
		return "ideology_effect_selector_tag_conflicts_with_tags"
	var tag_names := PackedStringArray()
	if not target_selector_tags.is_empty():
		tag_names = target_selector_tags
	elif target_selector_tag != &"":
		tag_names = PackedStringArray([String(target_selector_tag)])
	if not tag_names.is_empty():
		if target_selector_kind not in [
				TargetSelectorKind.OWN_TERRITORY,
				TargetSelectorKind.TAG_ANY_CELL,
				TargetSelectorKind.TAG_SOURCE_R1,
				TargetSelectorKind.TAG_SOURCE_R2]:
			return "ideology_effect_selector_tag_kind_invalid"
		if target_selector_param.size() > 1 \
				and int(target_selector_param[1]) != 0:
			return "ideology_effect_selector_tag_conflicts_with_param"
		if tag_names.size() > MAX_SELECTOR_TAGS:
			return "ideology_effect_selector_tag_count_invalid"
		var seen_tag_names := {}
		for tag_name in tag_names:
			var trimmed := String(tag_name).strip_edges()
			if trimmed.is_empty():
				return "ideology_effect_selector_tag_name_empty"
			# `A AND A` is `A`, so a repeat is never a contradiction — which is
			# exactly why it has to fail: it is always a copy-paste slip, and
			# collapsing it quietly would leave the card saying something its
			# author did not write.
			if seen_tag_names.has(trimmed):
				return "ideology_effect_selector_tag_name_duplicate"
			seen_tag_names[trimmed] = true
	if instructions.is_empty():
		return "ideology_effect_program_missing"
	if commands.is_empty():
		return "ideology_effect_commands_missing"
	return ""
