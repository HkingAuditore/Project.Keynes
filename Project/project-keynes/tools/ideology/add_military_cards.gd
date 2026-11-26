extends SceneTree

## Military ideology content (docs/plans/military-system-design.md §17).
##
## Run headless:
##   <godot_console> --headless --path Project/project-keynes -s res://tools/ideology/add_military_cards.gd
## Optional: `-- --dry-run` validates without saving.
##
## Authoring is done on the LOADED resources with the same Resource classes the
## catalogs already use, then written back with ResourceSaver. Never patch the
## .tres files as text: they are ~16k lines of cross-referenced sub-resources and
## a text edit is how a previous attempt corrupted the catalog.
##
## Idempotent: every card / synergy / modifier definition / appended term is
## keyed, and an existing key is skipped. Running the tool twice is a no-op.
##
## What the runtime can express today (and therefore what this tool writes):
##   * national Modifier definitions on the `country.military.*` stats that
##     modifier_catalog.gd registers in TECHNOLOGY_STATS (channel "国家");
##   * channel B rule parameters `country.military.rule.<rule>` (ADD, 0 = off);
##   * economy stats that already exist (sector output, upgrade-family output,
##     household consumption, construction cost, soldier satisfaction).
## Channel A (`military.cell.*` derived cell layer, cell.barracks / cell.fortified
## tags), channel C (X4 battle event stacks) and the `country.at_war` metric do not
## exist yet; those cards ship a national approximation and are listed in GAPS.
##
## NOTE: tools/ideology/generate_ideology_catalog.py regenerates the ideology
## catalog and the ideology section of the modifier catalog from its own tables.
## Re-running that generator drops this content unless it is ported there; re-run
## this tool afterwards (it is idempotent) until the port happens.

const MilitaryCardResources = preload("res://tools/ideology/military_card_resources.gd")

const MilitaryCardSpecs = preload("res://tools/ideology/military_card_specs.gd")

const IDEOLOGY_PATH := "res://data/ideologies/default_ideology_catalog.tres"
const MODIFIER_PATH := "res://data/modifiers/default_modifier_catalog.tres"
const EFFECT_PROGRAM_PATH := "res://data/ideologies/default_ideology_effects.tres"
const TRIGGER_PATH := "res://data/triggers/default_trigger_catalog.tres"
const SynergyScript = preload("res://scripts/ideology/ideology_synergy_definition.gd")
const EffectProgramScript = preload("res://scripts/ideology/ideology_effect_definition.gd")
const EffectProgramCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TargetTagDictionaryScript = preload("res://scripts/effect/target_tag_dictionary.gd")
## 初识 / 通晓 / 化育. Benefits scale, costs stay flat (same rule as the generator).
const LEVEL_SCALES := [1.0, 1.6, 2.2]
const LEVEL_TITLES := ["初识", "通晓", "化育"]
var _dry_run := false
var _log := PackedStringArray()


func _initialize() -> void:
	_dry_run = OS.get_cmdline_user_args().has("--dry-run")
	call_deferred("_run")


func _run() -> void:
	var code := _apply()
	print("\n".join(_log))
	quit(code)


func _say(line: String) -> void:
	_log.append("[military-cards] " + line)


func _apply() -> int:
	var ideology: Resource = ResourceLoader.load(IDEOLOGY_PATH, "Resource")
	var modifiers: Resource = ResourceLoader.load(MODIFIER_PATH, "Resource")
	var programs: Resource = ResourceLoader.load(EFFECT_PROGRAM_PATH, "Resource")
	if ideology == null or modifiers == null or programs == null:
		_say("FAILED: cannot load catalogs")
		return 1
	var modifier_compiled_before: Dictionary = modifiers.compile_native_catalog()
	if not bool(modifier_compiled_before.get("ok", false)):
		_say("FAILED: modifier catalog does not compile BEFORE edits: %s"
			% String(modifier_compiled_before.get("reason", "")))
		return 1
	var stat_keys: PackedStringArray = modifier_compiled_before.get("stat_keys", PackedStringArray())
	var known_stats := {}
	for key in stat_keys:
		known_stats[String(key)] = true

	# --- validate every stat we intend to write, before touching anything ---
	var all_terms: Array = []
	for card in MilitaryCardSpecs.cards():
		all_terms.append_array(card["terms"])
	all_terms.append_array(MilitaryCardSpecs.frontier_extension_terms())
	for synergy in MilitaryCardSpecs.synergies():
		all_terms.append_array(synergy["terms"])
	for extra in MilitaryCardSpecs.RESONANCE_EXTRA.values():
		all_terms.append_array(extra)
	# Channel A/C terms live on their own programs/stacks, so they are validated
	# through the same table but reached through their own accessors.
	for spec in MilitaryCardSpecs.channel_a_programs().values():
		for program in spec:
			for row in MilitaryCardSpecs._channel_a_terms(program):
				all_terms.append(row)
	for stack in MilitaryCardSpecs.channel_c_stacks().values():
		all_terms.append_array(stack["terms"])
	var unknown := PackedStringArray()
	for term in all_terms:
		if not known_stats.has(String(term[0])) and not unknown.has(String(term[0])):
			unknown.append(String(term[0]))
	if not unknown.is_empty():
		_say("FAILED: unregistered stat keys: %s" % ", ".join(unknown))
		return 1
	# The five channel-A cell stats must be ECONOMY-domain (per cell); a
	# country-domain stat silently targets the anchor cell only, and channel A
	# would look implemented while buffing one cell per country.
	var domains: PackedInt32Array = modifier_compiled_before.get(
		"stat_domains", PackedInt32Array())
	for index in stat_keys.size():
		if not String(stat_keys[index]).begins_with("military.cell."):
			continue
		if index < domains.size() and int(domains[index]) != 2:
			_say("FAILED: %s is not an ECONOMY-domain cell stat (domain=%d)"
				% [stat_keys[index], int(domains[index])])
			return 1

	var changed := 0
	var definition_index := {}
	for definition in modifiers.definitions:
		if definition != null:
			definition_index[String(definition.key)] = definition
	var card_index := {}
	for definition in ideology.definitions:
		if definition != null:
			card_index[String(definition.id)] = definition
	var synergy_index := {}
	for synergy in ideology.synergies:
		if synergy != null:
			synergy_index[String(synergy.id)] = synergy

	# --- 1. new cards ---------------------------------------------------------
	var new_definitions: Array[Resource] = ideology.definitions.duplicate()
	# The SAME objects, not a second copy: every rewrite below goes through
	# `definition_index`, and a duplicated array would let `definition_index`
	# point at resources that never reach the save. GDScript arrays of Resources
	# duplicate by value, so this is not an aliasing accident -- it is the one
	# array this run appends to AND rewrites in.
	var new_modifier_definitions: Array[Resource] = []
	for definition in modifiers.definitions:
		new_modifier_definitions.append(definition)
	for definition in new_modifier_definitions:
		if definition != null:
			definition_index[String(definition.key)] = definition
	for card in MilitaryCardSpecs.cards():
		var card_id := "idea.%s" % String(card["key"])
		# An existing card is UPGRADED, not skipped. A run of this tool from an
		# earlier round left these cards as flat national approximations; skipping
		# them by key would freeze that approximation forever, and the card would
		# keep reading as "channel A" while having no cell program at all.
		var existing: Resource = card_index.get(card_id)
		var upgraded := false
		for level in 3:
			var modifier_key := "ideology.%s.l%d" % [card["key"], level + 1]
			if definition_index.has(modifier_key):
				upgraded = upgraded or MilitaryCardResources._rewrite_modifier_definition(
					definition_index[modifier_key], String(card["detail"]),
					card["terms"], float(LEVEL_SCALES[level]))
				continue
			var modifier_definition := MilitaryCardResources._modifier_definition(modifier_key,
				"%s（%s）" % [card["name"], LEVEL_TITLES[level]], String(card["detail"]),
				card["terms"], float(LEVEL_SCALES[level]))
			new_modifier_definitions.append(modifier_definition)
			definition_index[modifier_key] = modifier_definition
			upgraded = true
		if existing == null:
			var definition := MilitaryCardResources._card_definition(card)
			new_definitions.append(definition)
			card_index[card_id] = definition
			changed += 1
			_say("add card %s %s [channel %s]" % [card_id, card["name"], card["channel"]])
			continue
		if MilitaryCardResources._rewrite_card_definition(existing, card):
			upgraded = true
		if upgraded:
			changed += 1
			_say("upgrade card %s %s [channel %s]" % [card_id, card["name"], card["channel"]])
	# Definitions already present in `new_modifier_definitions` were MUTATED in
	# place by `_rewrite_modifier_definition`, so their new terms are already in
	# the array this loop started from. Re-publish it explicitly anyway: a later
	# pass in this same run (`_author_cell_modifier_rows`) rewrites the array
	# wholesale, and comparing against a stale copy is what made the tool report
	# "14 changes" on every invocation instead of "nothing to do".
	modifiers.definitions = new_modifier_definitions
	# --- 2. extend 戍边 ----------------------------------------------------------
	var frontier: Resource = card_index.get("idea.frontier_garrison")
	if frontier == null:
		_say("FAILED: idea.frontier_garrison missing; refusing to author a duplicate")
		return 1
	for level in 3:
		var modifier_key := "ideology.frontier_garrison.l%d" % (level + 1)
		var definition: Resource = definition_index.get(modifier_key)
		if definition == null:
			_say("FAILED: %s missing" % modifier_key)
			return 1
		changed += _append_terms(definition, MilitaryCardSpecs.frontier_extension_terms(),
			float(LEVEL_SCALES[level]))
	var frontier_detail := "提高边境地块的农业产出与出生率，并提高兵额与本国工事强度，代价是贸易运输速度下降；化育后还扩大相关理念的筛选范围。"
	if String(frontier.detail_key) != frontier_detail:
		frontier.detail_key = frontier_detail
		for level in 3:
			var definition: Resource = definition_index["ideology.frontier_garrison.l%d" % (level + 1)]
			definition.description = frontier_detail
		changed += 1
		_say("extend 戍边 (idea.frontier_garrison) detail text")

	# --- 3. bonds ----------------------------------------------------------------
	var new_synergies: Array[Resource] = ideology.synergies.duplicate()
	for spec in MilitaryCardSpecs.synergies():
		var synergy_id := String(spec["id"])
		if synergy_index.has(synergy_id):
			_say("skip synergy (exists): %s" % synergy_id)
			continue
		var modifier_key := "ideology.%s" % synergy_id
		if not definition_index.has(modifier_key):
			var modifier_definition := MilitaryCardResources._modifier_definition(modifier_key,
				String(spec["name"]), String(spec["description"]), spec["terms"], 1.0)
			new_modifier_definitions.append(modifier_definition)
			definition_index[modifier_key] = modifier_definition
		var synergy := SynergyScript.new()
		synergy.id = StringName(synergy_id)
		synergy.display_name = String(spec["name"])
		var members := PackedStringArray(spec["members"])
		synergy.required_ideology_ids = members
		var levels := PackedInt32Array()
		var masks := PackedByteArray()
		for _member in members:
			levels.append(0)
			masks.append(6)
		synergy.minimum_levels = levels
		synergy.location_masks = masks
		var row := MilitaryCardResources._persistent_row(modifier_key)
		synergy.persistent_effects = [row]
		MilitaryCardResources._set_uid(synergy, "Synergy" + MilitaryCardResources._camel(synergy_id.trim_prefix("synergy.")))
		MilitaryCardResources._set_uid(row, "EffectSynergy" + MilitaryCardResources._camel(synergy_id.trim_prefix("synergy.")))
		new_synergies.append(synergy)
		synergy_index[synergy_id] = synergy
		changed += 1
		_say("add synergy %s %s" % [synergy_id, spec["name"]])

	# --- 4. mobilization resonance -------------------------------------------
	for key in MilitaryCardSpecs.RESONANCE_EXTRA:
		var definition: Resource = definition_index.get(String(key))
		if definition == null:
			_say("FAILED: %s missing" % key)
			return 1
		changed += _append_terms(definition, MilitaryCardSpecs.RESONANCE_EXTRA[key], 1.0)
	var mobilization_cards := PackedStringArray()
	for card in MilitaryCardSpecs.cards():
		if String(card["school"]) == "mobilization":
			mobilization_cards.append("idea.%s" % card["key"])
	for synergy_id in MilitaryCardSpecs.RESONANCE_SYNERGY_IDS:
		var synergy: Resource = synergy_index.get(synergy_id)
		if synergy == null:
			_say("FAILED: %s missing" % synergy_id)
			return 1
		var ids: PackedStringArray = synergy.required_ideology_ids
		var levels: PackedInt32Array = synergy.minimum_levels
		var masks: PackedByteArray = synergy.location_masks
		var added := 0
		for card_id in mobilization_cards:
			if ids.has(card_id):
				continue
			ids.append(card_id)
			levels.append(0)
			masks.append(6)
			added += 1
		if added > 0:
			synergy.required_ideology_ids = ids
			synergy.minimum_levels = levels
			synergy.location_masks = masks
			changed += 1
			_say("resonance %s += %d mobilization cards" % [synergy_id, added])

	ideology.definitions = new_definitions
	ideology.synergies = new_synergies
	# `new_modifier_definitions` is the array every in-place rewrite above wrote
	# through (`definition_index` holds the SAME objects), so publishing it here
	# is what makes those rewrites reach the save. Replacing it later with a
	# freshly-duplicated copy was dropping every rewrite silently.
	modifiers.definitions = new_modifier_definitions

	# --- 4b. channel A programs + channel C stack definitions -------------------
	# Economy is compiled first because the tag dictionary needs its id tables,
	# and the programs must exist before the ideology catalog is compiled: a card
	# row naming a program key is only routed to the managed path when the
	# program is already declared.
	var economy_ir: Dictionary = EconomyCatalogScript.compile_native_catalog()
	if not bool(economy_ir.get("ok", false)):
		_say("FAILED: economy catalog does not compile")
		return 1
	_economy_ir = economy_ir
	var program_changes := _author_effect_programs(programs, economy_ir)
	changed += program_changes
	# --- 4c. cell modifier rows + channel C trigger bindings -------------------
	var cell_row_changes := _author_cell_modifier_rows(modifiers, definition_index)
	changed += cell_row_changes
	var stack_changes := _author_stack_triggers(modifiers, definition_index)
	changed += stack_changes

	# --- 5. validate the edited in-memory catalogs before writing ---------------
	var modifier_ir: Dictionary = modifiers.compile_native_catalog()
	if not bool(modifier_ir.get("ok", false)):
		_say("FAILED: modifier catalog no longer compiles: %s" % String(modifier_ir.get("reason", "")))
		# Name the offending rows instead of leaving the caller to bisect 350
		# definitions by hand.
		var stat_domains := {}
		var compiled_stats: PackedStringArray = modifier_compiled_before.get(
			"stat_keys", PackedStringArray())
		var compiled_domains: PackedInt32Array = modifier_compiled_before.get(
			"stat_domains", PackedInt32Array())
		for index in compiled_stats.size():
			stat_domains[String(compiled_stats[index])] = int(compiled_domains[index]) \
				if index < compiled_domains.size() else -1
		for definition in modifiers.definitions:
			if definition == null or String(definition.key) == "":
				continue
			for term in definition.terms:
				if term == null:
					continue
				var stat := String(term.stat_key)
				var domain := int(stat_domains.get(stat, -99))
				if domain == -99:
					_say("  BAD %s: unknown stat %s" % [definition.key, stat])
				elif domain != int(definition.domain):
					_say("  BAD %s: domain=%d but %s is domain=%d"
						% [definition.key, int(definition.domain), stat, domain])
		return 1
	var ideology_ir: Dictionary = ideology.compile_native_catalog(economy_ir, economy_ir)
	if not bool(ideology_ir.get("ok", false)):
		_say("FAILED: ideology catalog no longer compiles: %s" % String(ideology_ir.get("reason", "")))
		return 1
	var modifier_keys: PackedStringArray = modifier_ir.get("definition_keys", PackedStringArray())
	# Every national row (prefixed `ideology.`) must resolve to a Modifier
	# definition; bare keys are managed-program markers and resolve elsewhere.
	var unresolved := PackedStringArray()
	for column in ["persistent_definition_keys", "synergy_effect_definition_keys"]:
		for key in ideology_ir.get(column, PackedStringArray()):
			if String(key).begins_with("ideology.") and not modifier_keys.has(String(key)) \
					and not unresolved.has(String(key)):
				unresolved.append(String(key))
	if not unresolved.is_empty():
		_say("WARNING: %d ideology rows have no Modifier definition (pre-existing or new): %s"
			% [unresolved.size(), ", ".join(unresolved.slice(0, 12))])
		for key in unresolved:
			for card in MilitaryCardSpecs.cards():
				if key.begins_with("ideology.%s." % card["key"]):
					_say("FAILED: new card row unresolved: %s" % key)
					return 1
	_say("validated: %d cards, %d synergies compile" % [
		(ideology_ir.ideology_ids as PackedStringArray).size(),
		(ideology_ir.synergy_ids as PackedStringArray).size()])

	_say("change tally: programs=%d cell_rows=%d stacks=%d" % [
		program_changes, cell_row_changes, stack_changes])
	if changed == 0:
		_say("nothing to do (already applied)")
		return 0
	if _dry_run:
		_say("dry run: %d changes NOT saved" % changed)
		return 0
	var err := ResourceSaver.save(modifiers, MODIFIER_PATH)
	if err != OK:
		_say("FAILED: save %s: %s" % [MODIFIER_PATH, error_string(err)])
		return 1
	err = ResourceSaver.save(ideology, IDEOLOGY_PATH)
	if err != OK:
		_say("FAILED: save %s: %s" % [IDEOLOGY_PATH, error_string(err)])
		return 1
	err = ResourceSaver.save(programs, EFFECT_PROGRAM_PATH)
	if err != OK:
		_say("FAILED: save %s: %s" % [EFFECT_PROGRAM_PATH, error_string(err)])
		return 1
	_say("saved %d changes" % changed)
	return 0


## Economy catalog IR, compiled once per run: the tag-name resolution needs its
## good/resource id tables and it is the most expensive compile in the tool.
var _economy_ir: Dictionary = {}


func economy_ir_cache() -> Dictionary:
	return _economy_ir


## Creates the channel-A managed Effect programs (one per card per cell set).
##
## Returns the number of programs created or changed. A program whose key
## already exists with the same selector, tags and commands is left alone so a
## second run is a no-op.
func _author_effect_programs(programs: Resource, economy_ir: Dictionary) -> int:
	var changed := 0
	var by_key := {}
	for program in programs.effects:
		if program != null:
			by_key[String(program.program_key())] = program
	var new_effects: Array[Resource] = programs.effects.duplicate()
	for card_key in MilitaryCardSpecs.channel_a_programs():
		var specs: Array = MilitaryCardSpecs.channel_a_programs()[card_key]
		for spec in specs:
			var definition_key := "%s_%s" % [String(card_key), String(spec["key"])]
			var program_key := EffectProgramScript.definition_key_of(definition_key)
			var built := _channel_a_program(definition_key, spec)
			var existing: Resource = by_key.get(program_key)
			if existing != null:
				if _program_differs(existing, built):
					# Replaced by identity: the program is keyed, so mutating it in
					# place is the same edit as replacing it, but replacing keeps
					# this function's contract ("what is in the array is what the
					# tool authored") without a second copy of the field list.
					for index in new_effects.size():
						if new_effects[index] == existing:
							new_effects[index] = built
							break
					by_key[program_key] = built
					changed += 1
					_say("upgrade program %s" % program_key)
				continue
			new_effects.append(built)
			by_key[program_key] = built
			changed += 1
			_say("add program %s" % program_key)
	programs.effects = new_effects
	if changed > 0:
		var error: String = programs.validate()
		if not error.is_empty():
			_say("FAILED: effect program catalog invalid: %s" % error)
	# The tag names a program selects on must exist in the dictionary that will
	# be compiled into the EffectCatalog, or the card silently matches no cell.
	var tag_result: Dictionary = TargetTagDictionaryScript.build(economy_ir)
	if not bool(tag_result.get("ok", false)):
		_say("FAILED: target tag dictionary: %s" % String(tag_result.get("reason", "")))
		return changed
	var known_tags := {}
	for tag in tag_result.get("tags", []):
		known_tags[String(tag["name"])] = true
	for card_key in MilitaryCardSpecs.channel_a_programs():
		for spec in MilitaryCardSpecs.channel_a_programs()[card_key]:
			for tag in spec["tags"]:
				if not known_tags.has(String(tag)):
					_say("FAILED: program %s selects unknown tag %s"
						% [card_key, String(tag)])
	return changed


## Builds one channel-A program resource.
##
## Shape, and why each field is what it is:
##   * `target_domain = SETTLEMENT_CELL` (2): a per-cell program. `COUNTRY` would
##     resolve a single target and the modifier would land on the country.
##   * `lifecycle = PERMANENT`: channel A is a slow variable recomputed with the
##     economy commit, not a timed stack.
##   * `operation = MULTIPLY`: the card authors a factor ("+8%"), and ADD would
##     add 1.08 to a base of 1.0.
##   * `stack_policy = REPLACE`, one instance per target cell.
##   * `selector_cap = 0` for the unbounded kinds -- see `channel_a_programs()`.
func _channel_a_program(definition_key: String, spec: Dictionary) -> Resource:
	var program := EffectProgramScript.new()
	program.definition_key = StringName(definition_key)
	program.summary = String(spec["summary"])
	program.target_domain = EffectProgramScript.TargetDomain.SETTLEMENT_CELL
	program.operation = EffectProgramScript.Operation.MULTIPLY
	program.lifecycle = EffectProgramScript.Lifecycle.PERMANENT
	program.stack_policy = EffectProgramScript.StackPolicy.REPLACE
	program.max_stacks = 1
	program.target_selector_kind = int(spec["selector"])
	program.target_selector_param = PackedInt32Array([int(spec["selector_cap"]), 0])
	var tags := PackedStringArray()
	for tag in spec["tags"]:
		tags.append(String(tag))
	program.target_selector_tags = tags
	var commands: Array[Resource] = []
	var index := 0
	for term in MilitaryCardSpecs._channel_a_terms(spec):
		var row := MilitaryCardResources.EffectCommandScript.new()
		# action 1 = MODIFIER apply; domain 2 = Modifier ECONOMY (per cell), which
		# is where every `military.cell.*` stat is declared. A country-domain row
		# would be rejected by the ideology compiler as an unreversible national
		# modifier on a cell program.
		row.action = 1
		row.domain = 2
		row.opcode = 1
		row.target_resolver = 1
		row.value_mode = 0
		row.value_q16 = MilitaryCardResources.Q16
		row.duration_days = -1
		row.stacks = 1
		row.command_key = &"ideology.cell"
		row.definition_key = StringName("ideology.military.%s.%d"
			% [definition_key, index])
		MilitaryCardResources._set_uid(row, "MilCell%sCmd%d" % [MilitaryCardResources._camel(definition_key), index])
		# The definition key names the CELL modifier row; it must resolve to a
		# Modifier definition, authored below.
		_row_definitions[String(row.definition_key)] = term
		commands.append(row)
		index += 1
	program.commands = commands
	program.instructions = [_magnitude_instruction()]
	MilitaryCardResources._set_uid(program, "MilProg" + MilitaryCardResources._camel(definition_key))
	return program


## Cell modifier definition key -> the `_t` row it applies. Filled while the
## channel-A programs are built and consumed by `_author_cell_modifier_rows()`.
var _row_definitions: Dictionary = {}


## One CONST instruction, so the program has a value source without a ramp.
func _magnitude_instruction() -> Resource:
	var instruction: Resource = load(
		"res://scripts/effect/effect_instruction.gd").new()
	instruction.op = 1 # CONST
	instruction.value_q16 = MilitaryCardResources.Q16
	return instruction


static func _program_differs(existing: Resource, built: Resource) -> bool:
	if int(existing.target_selector_kind) != int(built.target_selector_kind):
		return true
	if PackedInt32Array(existing.target_selector_param) \
			!= PackedInt32Array(built.target_selector_param):
		return true
	if PackedStringArray(existing.target_selector_tags) \
			!= PackedStringArray(built.target_selector_tags):
		return true
	if int(existing.target_domain) != int(built.target_domain) \
			or int(existing.operation) != int(built.operation):
		return true
	if existing.commands.size() != built.commands.size():
		return true
	for index in existing.commands.size():
		var a: Resource = existing.commands[index]
		var b: Resource = built.commands[index]
		if String(a.definition_key) != String(b.definition_key) \
				or int(a.domain) != int(b.domain) \
				or int(a.value_q16) != int(b.value_q16):
			return true
	return false


## Creates the ECONOMY-domain Modifier definitions the channel-A programs name.
##
## Each program row names `ideology.military.<program>.<index>`; that key must
## resolve to a definition whose single term is the stat + factor the row
## applies. Without these rows the ideology compiler rejects the whole catalog
## with `target_selector_invalid` / an unresolved definition key.
func _author_cell_modifier_rows(modifiers: Resource,
		definition_index: Dictionary) -> int:
	if _row_definitions.is_empty():
		return 0
	# The live index, not a local copy: the stack authoring that runs next must
	# see these rows, and a local copy would let the same key be appended twice
	# (`modifier_definition_invalid_or_duplicate`).
	var index := definition_index
	var out: Array[Resource] = modifiers.definitions.duplicate()
	var changed := 0
	for key in _row_definitions:
		var spec: Array = _row_definitions[key]
		# `spec` is a `_t` row; index 3 is the benefit flag, not text.
		var existing: Resource = index.get(key)
		if existing != null:
			# Domain is part of what makes a cell row a cell row: an earlier
			# authoring pass that wrote `domain = 1` would put the per-cell
			# multiplier on the country bucket instead, where no reader looks.
			if int(existing.domain) != 2:
				existing.domain = 2
				changed += 1
				_say("fix domain on cell row %s" % key)
			if MilitaryCardResources._rewrite_modifier_definition(existing, String(spec[0]), [spec], 1.0):
				changed += 1
				_say("upgrade cell row %s" % key)
			continue
		var definition := MilitaryCardResources._modifier_definition(String(key), String(key),
			String(spec[0]), [spec], 1.0)
		# Per-cell rows live in the ECONOMY domain, matching the stat and the
		# command row. `domain = 1` here would make ModifierRuntime reject the
		# apply at its safe boundary after the card looked fine in the catalog.
		definition.domain = 2
		out.append(definition)
		index[key] = definition
		changed += 1
		_say("add cell row %s" % key)
	if changed > 0:
		modifiers.definitions = out
	return changed


## Binds each channel-C card to its TriggerCatalog stack rule.
##
## Returns the number of bindings written. The duration and definition come from
## `channel_c_stacks()`; the trigger itself is declared in
## `scripts/trigger/trigger_catalog.gd` (`military.stack.<suffix>`) and the
## effect is attached through its static authoring hook, because the trigger
## catalog is a shared resource this tool does not rewrite.
func _author_stack_triggers(modifiers: Resource, definition_index: Dictionary) -> int:
	var changed := 0
	for card_key in MilitaryCardSpecs.channel_c_stacks():
		var spec: Dictionary = MilitaryCardSpecs.channel_c_stacks()[card_key]
		var suffix := String(spec["trigger"])
		var terms: Array = spec["terms"]
		for level in 3:
			# One Modifier definition per (card, level): the trigger applies the
			# level the card is currently at, so the stack's magnitude has to be
			# the level-scaled one rather than a single shared row.
			var definition_key := "ideology.stack.%s.l%d" % [card_key, level + 1]
			var scaled: Array = []
			for spec_row in terms:
				scaled.append_array(MilitaryCardResources._scaled_terms([spec_row], float(LEVEL_SCALES[level])))
			var key := StringName(definition_key)
			var existing: Resource = definition_index.get(String(key))
			if existing != null:
				if int(existing.stack_policy) != 2 or int(existing.max_stacks) != int(spec["max_stacks"]):
					existing.stack_policy = 2
					existing.max_stacks = int(spec["max_stacks"])
					existing.default_duration_days = int(spec["duration_days"])
					changed += 1
					_say("repair stack row %s policy/stacks/duration" % definition_key)
				elif MilitaryCardResources._rewrite_modifier_definition(existing, String(spec["summary"]),
						[scaled[0]] if scaled.size() == 1 else scaled, 1.0):
					changed += 1
			else:
				var definition := MilitaryCardResources._modifier_definition(definition_key,
					"%s（叠层）" % card_key, String(spec["summary"]), terms,
					float(LEVEL_SCALES[level]))
				# STACK_REFRESH: each event adds one stack and pushes the expiry
				# out, which is exactly "最多 N 层，持续 M 日".
				definition.stack_policy = 2
				definition.max_stacks = int(spec["max_stacks"])
				definition.default_duration_days = int(spec["duration_days"])
				modifiers.definitions.append(definition)
				definition_index[String(key)] = definition
				changed += 1
				_say("add stack row %s" % definition_key)
		if TriggerCatalogScript.set_military_stack_effect(suffix,
				StringName("ideology.stack.%s.l1" % card_key),
				int(spec["duration_days"]), int(spec["max_stacks"])):
			# Registering the trigger binding is IN-MEMORY only: the trigger
			# catalog is a shared resource this tool does not rewrite, so this
			# call is a no-op on disk and must not count as a change. Counting it
			# made the tool report "5 changes" on every run forever.
			pass
		else:
			_say("FAILED: trigger catalog has no military.stack.%s rule" % suffix)
	return changed


## Append terms whose stat is not already on the definition. Returns 1 if changed.
func _append_terms(definition: Resource, specs: Array, scale: float) -> int:
	var present := {}
	for term in definition.terms:
		if term != null:
			present[String(term.stat_key)] = true
	var terms: Array[Resource] = definition.terms.duplicate()
	var added := 0
	for spec in specs:
		if present.has(String(spec[0])):
			continue
		var term := MilitaryCardResources._term(spec, scale)
		MilitaryCardResources._set_uid(term, "TermIdeology%sMil%d" % [
			MilitaryCardResources._camel(String(definition.key).trim_prefix("ideology.")), terms.size()])
		terms.append(term)
		added += 1
	if added == 0:
		return 0
	definition.terms = terms
	_say("extend %s +%d terms" % [definition.key, added])
	return 1
