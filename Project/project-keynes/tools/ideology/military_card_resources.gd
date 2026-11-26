extends RefCounted

## Build and update the saved resources for military ideology cards.

const MilitaryCardSpecs = preload("res://tools/ideology/military_card_specs.gd")

const DefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const LevelScript = preload("res://scripts/ideology/ideology_level_definition.gd")
const StanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const RequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const ModifierDefinitionScript = preload("res://scripts/modifier/modifier_definition.gd")
const ModifierTermScript = preload("res://scripts/modifier/modifier_term.gd")
const Q16 := 65536
const LEVEL_THRESHOLDS := [0, 524288, 1572864]
const LEVEL_DAILY := [205, 103, 0]
const RARITY_WEIGHTS := {1: 120, 2: 60, 3: 20}
const THRESHOLDS := {
	1: [4096, 0, 16384],
	2: [8192, 0, 20480],
	3: [12288, 0, 24576],
}
## Entry milestone per era (data/technology/technology_network.json `eras`).
const ERA_MILESTONES := [
	"", "tech.agrarian_society", "tech.kingdom_administration",
	"tech.imperial_integration", "tech.global_exchange",
	"tech.enlightenment_institutions", "tech.industrialization",
	"tech.electrical_society", "tech.atomic_modernity",
	"tech.information_society", "tech.cognitive_automation",
]


static func _modifier_definition(key: String, display_name: String, description: String,
		terms: Array, scale: float) -> Resource:
	var definition := ModifierDefinitionScript.new()
	definition.key = StringName(key)
	definition.version = 1
	definition.display_name = display_name
	definition.description = description
	definition.domain = 1
	definition.stack_policy = 1
	definition.max_stacks = 1
	definition.default_duration_days = -1
	var out: Array[Resource] = []
	var base := "TermIdeology" + _camel(key.trim_prefix("ideology."))
	for index in terms.size():
		var term := _term(terms[index], scale)
		_set_uid(term, "%s%d" % [base, index])
		out.append(term)
	definition.terms = out
	_set_uid(definition, "DefIdeology" + _camel(key.trim_prefix("ideology.")))
	return definition


static func _term(spec: Array, scale: float) -> Resource:
	var term := ModifierTermScript.new()
	term.stat_key = StringName(String(spec[0]))
	term.operation = int(spec[1])
	var value := float(spec[2])
	if bool(spec[3]) and not is_equal_approx(scale, 1.0):
		if term.operation == MilitaryCardSpecs.MUL:
			value = 1.0 + (value - 1.0) * scale
		else:
			value = value * scale
	term.value = snappedf(value, 0.0001)
	return term


static func _persistent_row(definition_key: String) -> Resource:
	var row := EffectCommandScript.new()
	row.action = 1
	row.domain = 1
	row.opcode = 1
	row.target_resolver = 1
	row.value_mode = 0
	row.value_q16 = Q16
	row.duration_days = -1
	row.stacks = 1
	row.command_key = &"ideology.persistent"
	row.definition_key = StringName(definition_key)
	return row


static func _card_definition(card: Dictionary) -> Resource:
	var key := String(card["key"])
	var camel := _camel(key)
	var rarity := int(card["rarity"])
	var definition := DefinitionScript.new()
	definition.id = StringName("idea.%s" % key)
	definition.icon_key = StringName(String(card["icon"]))
	definition.name_key = StringName(String(card["name"]))
	definition.detail_key = String(card["detail"])
	definition.school_id = StringName(String(card["school"]))
	definition.rarity = rarity
	definition.rarity_weight = int(RARITY_WEIGHTS[rarity])
	definition.era_index = int(card["era"])
	definition.national_spirit_min_level = 1
	definition.exclusion_group = StringName(String(card.get("exclusion", "")))
	# Legendary cards are rule cards and never copy sources (X6-c contract).
	definition.copyable = rarity != 3
	var thresholds: Array = THRESHOLDS[rarity]
	definition.adopt_threshold_q16 = int(thresholds[0])
	definition.repeal_threshold_q16 = int(thresholds[1])
	definition.promote_threshold_q16 = int(thresholds[2])
	var requirements: Array[Resource] = []
	var milestone := String(ERA_MILESTONES[int(card["era"])])
	if not milestone.is_empty():
		var requirement := RequirementScript.new()
		requirement.kind = RequirementScript.Kind.TECHNOLOGY
		requirement.key = StringName(milestone)
		_set_uid(requirement, "Require%sG0" % camel)
		requirements.append(requirement)
	definition.draw_requirements = requirements
	var stances: Array[Resource] = []
	for stance_spec in [["general", 16384, -8192, 20480], ["military", 24576, -16384, 24576],
			["worker", -8192, 8192, -4096]]:
		var stance := StanceScript.new()
		stance.class_id = StringName(String(stance_spec[0]))
		stance.adopt_stance_q16 = int(stance_spec[1])
		stance.repeal_stance_q16 = int(stance_spec[2])
		stance.promote_stance_q16 = int(stance_spec[3])
		_set_uid(stance, "Stance%s%s" % [camel, _camel(String(stance_spec[0]))])
		stances.append(stance)
	definition.class_stances = stances
	var levels: Array[Resource] = []
	for level in 3:
		var level_definition := LevelScript.new()
		level_definition.understanding_threshold_q16 = int(LEVEL_THRESHOLDS[level])
		level_definition.daily_understanding_q16 = int(LEVEL_DAILY[level])
		var rows: Array[Resource] = []
		# Channel A: one row per authored program for this card. The row is a
		# ROUTING MARKER -- the program owns conditions, cadence, selector and
		# magnitude -- so its own domain/opcode are never read. Without it the
		# level has no program binding and the cell program never activates.
		var specs: Array = MilitaryCardSpecs.channel_a_programs().get(String(card["key"]), [])
		for spec in specs:
			var program_row := _persistent_row(
				"%s_%s" % [String(card["key"]), String(spec["key"])])
			_set_uid(program_row, "Effect%s%sL%d"
				% [camel, _camel(String(spec["key"])), level + 1])
			rows.append(program_row)
		if rows.is_empty():
			var row := _persistent_row("ideology.%s.l%d" % [key, level + 1])
			_set_uid(row, "Effect%sL%d" % [camel, level + 1])
			rows.append(row)
		level_definition.persistent_effects = rows
		level_definition.on_enter_effects = []
		_set_uid(level_definition, "Level%sL%d" % [camel, level + 1])
		levels.append(level_definition)
	definition.levels = levels
	_set_uid(definition, "Idea" + camel)
	var error: String = definition.validate()
	if not error.is_empty():
		push_error("[military-cards] %s invalid: %s" % [definition.id, error])
	return definition


## Readable sub-resource ids in the saved .tres (Godot otherwise invents
## `Resource_xxxxx`). Falls back silently if the property is unavailable.
static func _set_uid(resource: Resource, uid: String) -> void:
	if resource.has_method("set_scene_unique_id"):
		resource.set_scene_unique_id(uid)


static func _camel(text: String) -> String:
	var out := ""
	for part in text.replace(".", "_").split("_", false):
		out += part.substr(0, 1).to_upper() + part.substr(1)
	return out


## Rebuilds an existing per-level Modifier definition in place.
##
## Returns true when anything changed. A definition whose terms already match is
## left untouched, which is what keeps a second run a no-op at the SAVE level --
## the tool reports "nothing to do" instead of rewriting identical resources and
## churning the file (and the catalog hash) on every invocation.
static func _rewrite_modifier_definition(definition: Resource, detail: String,
		terms: Array, scale: float) -> bool:
	var changed := false
	var wanted := _scaled_terms(terms, scale)
	var current := _terms_signature(definition.terms)
	if current != _signature_of(wanted):
		# Terms are replaced wholesale rather than appended: a card moving from
		# a national approximation to a cell program must LOSE the old national
		# row, and appending would leave both live at once.
		var out: Array[Resource] = []
		var base := "TermIdeology" + _camel(String(definition.key).trim_prefix("ideology."))
		for index in wanted.size():
			var term := _term(wanted[index], 1.0)
			_set_uid(term, "%sR%d" % [base, index])
			out.append(term)
		definition.terms = out
		changed = true
	if String(definition.description) != detail:
		definition.description = detail
		changed = true
	return changed


static func _scaled_terms(terms: Array, scale: float) -> Array:
	var out: Array = []
	for spec in terms:
		var value := float(spec[2])
		if bool(spec[3]) and not is_equal_approx(scale, 1.0):
			if int(spec[1]) == MilitaryCardSpecs.MUL:
				value = 1.0 + (value - 1.0) * scale
			else:
				value = value * scale
		# Keep the benefit flag: `_term` reads index 3 and the sorted signature
		# must stay comparable with `_terms_signature`, which includes it.
		out.append([String(spec[0]), int(spec[1]), snappedf(value, 0.0001),
			bool(spec[3])])
	return out


## Term signature in the same shape `_scaled_terms` produces, so a definition
## written by an earlier run compares equal instead of looking different on
## every invocation (which made the tool never reach "nothing to do").
static func _terms_signature(terms: Array) -> String:
	var out: Array = []
	for term in terms:
		if term == null:
			continue
		out.append([String(term.stat_key), int(term.operation),
			snappedf(float(term.value), 0.0001)])
	return str(out)


static func _signature_of(rows: Array) -> String:
	var out: Array = []
	for row in rows:
		out.append([String(row[0]), int(row[1]), snappedf(float(row[2]), 0.0001)])
	return str(out)


## Brings an existing card's authored surface in line with `card` WITHOUT
## touching its identity (id, rarity weights, thresholds, stances). A card is
## re-saved only when one of the fields this tool owns actually differs.
static func _rewrite_card_definition(definition: Resource, card: Dictionary) -> bool:
	var changed := false
	if String(definition.detail_key) != String(card["detail"]):
		definition.detail_key = String(card["detail"])
		changed = true
	if String(definition.school_id) != String(card["school"]):
		definition.school_id = StringName(String(card["school"]))
		changed = true
	if String(definition.icon_key) != String(card["icon"]):
		definition.icon_key = StringName(String(card["icon"]))
		changed = true
	# Channel-A levels must BIND their programs. A card authored by an earlier
	# round points at `ideology.<key>.lN`, a national Modifier row; leaving it
	# there would keep the approximation alive beside the new cell programs.
	var specs: Array = MilitaryCardSpecs.channel_a_programs().get(String(card["key"]), [])
	if specs.is_empty():
		return changed
	var camel := _camel(String(card["key"]))
	for level in definition.levels.size():
		var level_definition: Resource = definition.levels[level]
		if level_definition == null:
			continue
		var current: Array = level_definition.persistent_effects
		if current.size() == specs.size():
			var already := true
			for index in current.size():
				var expected := "%s_%s" % [String(card["key"]),
					String(specs[index]["key"])]
				if current[index] == null \
						or String(current[index].definition_key) != expected:
					already = false
					break
			if already:
				continue
		var rows: Array[Resource] = []
		for spec in specs:
			var row := _persistent_row("%s_%s" % [String(card["key"]),
				String(spec["key"])])
			_set_uid(row, "Effect%s%sL%d" % [camel, _camel(String(spec["key"])),
				level + 1])
			rows.append(row)
		level_definition.persistent_effects = rows
		changed = true
	return changed
