class_name IdeologyCatalog
extends Resource

const NativeCompiler = preload("res://scripts/ideology/ideology_catalog_compiler.gd")
const EffectRows = preload("res://scripts/ideology/ideology_catalog_effect_rows.gd")
const IdeologyCardFaceText = preload("res://scripts/ideology/ideology_card_face_text.gd")


const DEFAULT_PATH := "res://data/ideologies/default_ideology_catalog.tres"
const IdeologyDefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const IdeologyRequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const IdeologyProfileScript = preload("res://scripts/ideology/ideology_profile.gd")
const IdeologyClassStanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const IdeologySynergyDefinitionScript = preload("res://scripts/ideology/ideology_synergy_definition.gd")
const IdeologyEffectParameterScript = preload(
	"res://scripts/ideology/ideology_effect_parameter.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const ModifierCatalogScript = preload("res://scripts/modifier/modifier_catalog.gd")
const IdeologyEffectCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
## Only for `SELECTOR_MAX_CELLS`: the concurrency budget must use the same cell
## cap the runtime enforces, and a second literal here is exactly the mirror
## constant that drifted the last three times this project tried it.
const IdeologyEffectDefinitionScript = preload(
	"res://scripts/ideology/ideology_effect_definition.gd")
const IdeologyIncidenceCompilerScript = preload(
	"res://scripts/ideology/ideology_incidence_compiler.gd")
const ResearchSignalCatalogScript = preload(
	"res://scripts/research/research_signal_catalog.gd")

const PROTOCOL_VERSION := 1
## Card effect rows name a program by its BARE key (`v1_granary_belt`); the
## compiler and the runtime both store it prefixed (`ideology.effect.<key>`,
## see IdeologyEffectDefinition.program_key and
## NativeIdeologyRuntime::effect_program_key). Comparing a row key against the
## declared set without this prefix silently reports zero owned programs, which
## left the instance budget unenforced.
const PROGRAM_KEY_PREFIX := "ideology.effect."
## Display order and labels of the six schools (流派). Resonance rows and the
## collection tabs follow this order.
const SCHOOLS := [
	{"id": "agrarian", "name": "农本", "motto": "重农固本，仓廩实而知礼节"},
	{"id": "commerce", "name": "商贸", "motto": "通有无，兴市舶，以财养国"},
	{"id": "learning", "name": "学识", "motto": "格物致知，以学立政"},
	{"id": "mobilization", "name": "动员", "motto": "聚众成城，万人一心"},
	{"id": "industry", "name": "工造", "motto": "利器善事，百工居胆"},
	{"id": "harmony", "name": "调和", "motto": "顺天应时，山泽有度"},
]
const LEVEL_LABELS := ["初识", "通晓", "化育"]

@export var profile: Resource
@export var definitions: Array[Resource] = []
@export var synergies: Array[Resource] = []
## Declarative effect programs (`ideology.effect.<definition_key>`) that replace
## the legacy "one-shot Modifier per effect row" path. Null falls back to the
## default catalog, so a project without authored programs keeps the old shape.
@export var effect_programs: Resource

## TEST HOOK, not a gameplay knob. A fixture that is not about the support gate
## sets this to false before generating a world; `load_default()` then hands out a
## catalog whose profile disables the gate. Production never touches it.
static var support_gate_enabled := true

static func load_default(loaded: Resource = null) -> Resource:
	if loaded == null:
		loaded = ResourceLoader.load(DEFAULT_PATH, "Resource")
	if loaded != null and not support_gate_enabled and loaded.profile != null:
		var profile: Resource = loaded.profile.duplicate()
		profile.support_gate_enabled = false
		loaded.profile = profile
	return loaded

func compile_native_catalog(country_catalog: Dictionary,
		economy_catalog: Dictionary = {}) -> Dictionary:
	return NativeCompiler.compile(profile, definitions, synergies, effect_programs,
		country_catalog, economy_catalog)


static func _expand_route_synergy_members(route_tag: String,
		route_index: Dictionary, min_count: int) -> Dictionary:
	return EffectRows._expand_route_synergy_members(route_tag, route_index, min_count)


func catalog_view(country_catalog: Dictionary = {},
		economy_catalog: Dictionary = {}) -> Dictionary:
	var compiled := compile_native_catalog(country_catalog, economy_catalog)
	if not bool(compiled.get("ok", false)): return compiled
	var modifier_catalog = ModifierCatalogScript.load_default()
	var rows: Array[Dictionary] = []
	for i in compiled.ideology_ids.size():
		var definition = null
		for candidate in definitions:
			if candidate != null and String(candidate.id) == String(compiled.ideology_ids[i]):
				definition = candidate
				break
		if definition == null:
			continue
		var level_thresholds := PackedInt64Array()
		var level_effect_lines: Array = []
		for level_index in definition.levels.size():
			var level = definition.levels[level_index]
			level_thresholds.append(level.understanding_threshold_q16)
			level_effect_lines.append(_present_effect_lines(
				modifier_catalog, String(definition.id), level_index,
				level.persistent_effects, level.on_enter_effects))
		var level_labels := PackedStringArray()
		for level_index in definition.levels.size():
			level_labels.append(LEVEL_LABELS[level_index] if level_index < LEVEL_LABELS.size()
				else "%d级" % (level_index + 1))
		var required_technologies := PackedStringArray()
		var required_technology_names := PackedStringArray()
		var required_research_signal_names := PackedStringArray()
		var required_gates := PackedStringArray()
		for requirement in definition.draw_requirements:
			if requirement == null:
				continue
			if requirement.kind == IdeologyRequirementScript.Kind.TECHNOLOGY:
				required_technologies.append(String(requirement.key))
				required_technology_names.append(technology_display_name(String(requirement.key)))
			elif requirement.kind == IdeologyRequirementScript.Kind.RESEARCH_SIGNAL:
				required_research_signal_names.append(
					research_signal_display_name(String(requirement.key)))
			elif requirement.kind == IdeologyRequirementScript.Kind.GATE:
				required_gates.append(String(requirement.key))
		rows.append({"id": String(definition.id), "dense_id": i, "icon_key": String(definition.icon_key),
			"name_key": String(definition.name_key),
			"display_name": _display_name(definition),
			"detail_key": String(definition.detail_key),
			"school_id": String(definition.school_id),
			"school_name": school_name(String(definition.school_id)),
			"era_index": int(definition.era_index),
			"era_name": era_display_name(int(definition.era_index)),
			"route_tag": String(definition.route_tag),
			"required_gates": required_gates,
			"rarity": int(definition.rarity),
			"rarity_label": String(IdeologyDefinitionScript.RARITY_LABELS.get(
				int(definition.rarity), "")),
			"level_labels": level_labels,
			"required_technologies": required_technologies,
			"required_technology_names": required_technology_names,
			"required_research_signal_names": required_research_signal_names,
			"rarity_weight": definition.rarity_weight, "ideology_slot_cost": definition.ideology_slot_cost,
			"national_spirit_slot_cost": definition.national_spirit_slot_cost,
			"acquisition_flags": definition.acquisition_flags,
			"min_spirit_level": definition.national_spirit_min_level,
			"level_thresholds_q16": level_thresholds,
			"level_effect_lines": level_effect_lines,
			"adopt_threshold_q16": definition.adopt_threshold_q16,
			"repeal_threshold_q16": definition.repeal_threshold_q16,
			"promote_threshold_q16": definition.promote_threshold_q16,
			"exclusion_group": String(definition.exclusion_group),
			"exclusion_rivals": _exclusion_rivals(definition),
			"route_tags": definition.route_tags(),
			"route_names": _route_display_names(definition.route_tags()),
			"synergy_names": PackedStringArray(),
			"synergy_tooltip": ""})
	var synergy_rows: Array[Dictionary] = []
	var synergy_by_ideology: Dictionary = {}
	for i in compiled.synergy_ids.size():
		var synergy = _synergy_resource(String(compiled.synergy_ids[i]))
		if synergy == null:
			continue
		if synergy.hidden:
			continue
		# Requirement rows are read back from the compiled table, not re-derived
		# from the resource. A named synergy and an expanded route synergy both
		# land here as the same thing, so the UI has exactly one shape to handle
		# and cannot disagree with what the runtime will actually check.
		var member_ids := PackedStringArray()
		var member_names := PackedStringArray()
		var requirement_begin := int(compiled.synergy_requirement_offsets[i])
		var requirement_end := int(compiled.synergy_requirement_offsets[i + 1])
		for cursor in range(requirement_begin, requirement_end):
			var dense := int(compiled.synergy_requirement_ideology_ids[cursor])
			member_ids.append(String(compiled.ideology_ids[dense]))
			member_names.append(_display_name_for_id(
				String(compiled.ideology_ids[dense])))
		var effect_lines := _present_effect_lines(
			modifier_catalog, "", 0, synergy.persistent_effects)
		var display := _synergy_display_name(synergy)
		var effect_text := "、".join(effect_lines) if not effect_lines.is_empty() else "额外国家修正"
		var route_key := String(synergy.route_tag).strip_edges()
		var tooltip := "以下理念同时生效（含民族精神）：%s；%s" % [
			"与".join(member_names), effect_text]
		if synergy.uses_route_tag():
			var location := "理念槽中" if int(synergy.route_tag_location_mask) == 2 \
				else ("民族精神中" if int(synergy.route_tag_location_mask) == 4 \
				else "生效理念中（含民族精神）")
			tooltip = "%s至少 %d 张%s体系理念：%s" % [location,
				int(synergy.min_count), route_display_name(route_key), effect_text]
		var resonance_school := String(synergy.school_id)
		if not resonance_school.is_empty():
			tooltip = "%s共鸣·至少 %d 张生效（含民族精神）：%s" % [school_name(resonance_school),
				int(synergy.min_count), effect_text]
		synergy_rows.append({
			"dense_id": i,
			"id": String(compiled.synergy_ids[i]),
			"display_name": display,
			"effect_lines": effect_lines,
			"required_names": member_names,
			"required_ids": member_ids,
			"route_tag": route_key,
			"minimum_levels": synergy.minimum_levels if not synergy.uses_route_tag() \
				else PackedInt32Array(),
			"min_count": int(synergy.min_count),
			"school_id": resonance_school,
			"resonance_tier": int(synergy.resonance_tier),
			"tooltip": tooltip,
		})
		if not resonance_school.is_empty():
			continue
		for required_id in member_ids:
			var key := String(required_id)
			var attached: Array = synergy_by_ideology.get(key, [])
			attached.append({"display_name": display, "tooltip": tooltip})
			synergy_by_ideology[key] = attached
	for row in rows:
		var attached: Array = synergy_by_ideology.get(String(row.get("id", "")), [])
		var names := PackedStringArray()
		var tooltips := PackedStringArray()
		for item in attached:
			names.append(String((item as Dictionary).get("display_name", "")))
			tooltips.append(String((item as Dictionary).get("tooltip", "")))
		row["synergy_names"] = names
		row["synergy_tooltip"] = "\n".join(tooltips)
	var unlock_keys := PackedStringArray(
		profile.capacity_unlock_technology_keys if profile != null else PackedStringArray())
	var unlock_names := PackedStringArray()
	for key in unlock_keys:
		unlock_names.append(technology_display_name(String(key)))
	return {"ok": true, "ideologies": rows, "synergies": synergy_rows,
		"schools": SCHOOLS.duplicate(true),
		"political_class_ids": compiled.political_class_ids,
		"gate_keys": compiled.gate_keys,
		"ideology_capacity": int(compiled.get("ideology_capacity", 0)),
		"national_spirit_capacity": int(compiled.get("national_spirit_capacity", 0)),
		"ideology_capacity_max": int(compiled.get("ideology_capacity_max", 0)),
		"national_spirit_capacity_max": int(compiled.get("national_spirit_capacity_max", 0)),
		"capacity_unlock_technology_keys": unlock_keys,
		"capacity_unlock_technology_names": unlock_names,
		"capacity_unlock_ideology_deltas": compiled.get("capacity_unlock_ideology_deltas", PackedInt32Array()),
		"capacity_unlock_spirit_deltas": compiled.get("capacity_unlock_spirit_deltas", PackedInt32Array()),
		"offer_cost_q16": int(compiled.get("offer_cost_q16", 65536)),
		"offer_cost_growth_percent": int(compiled.get("offer_cost_growth_percent", 100)),
		"starting_points_q16": int(compiled.get("starting_points_q16", 0))}

static func school_name(school_id: String) -> String:
	for school in SCHOOLS:
		if String(school.id) == school_id:
			return String(school.name)
	return school_id

const ROUTE_DISPLAY_NAMES = EffectRows.ROUTE_DISPLAY_NAMES


static func route_display_name(route_tag: String) -> String:
	return String(ROUTE_DISPLAY_NAMES.get(route_tag, route_tag))

static func _route_display_names(tags: PackedStringArray) -> PackedStringArray:
	var names := PackedStringArray()
	for tag in tags:
		names.append(route_display_name(String(tag)))
	return names

static var _technology_names := {}

## Cold-path display name for a technology key (slot unlock captions and draw
## requirements). Reads the cached authoring network once.
static func technology_display_name(technology_key: String) -> String:
	if _technology_names.is_empty():
		var technology_script = load("res://scripts/economy/technology_catalog.gd")
		var payload: Dictionary = technology_script._network_payload() \
			if technology_script != null else {}
		for node in payload.get("nodes", []) as Array:
			if node is Dictionary:
				_technology_names[String(node.get("id", ""))] = String(
					node.get("display_name", node.get("id", "")))
		_technology_names[""] = ""
	return String(_technology_names.get(technology_key, technology_key))

static var _research_signal_names: Dictionary = {}

static func research_signal_display_name(signal_key: String) -> String:
	if _research_signal_names.is_empty():
		for metadata in ResearchSignalCatalogScript.public_metadata():
			_research_signal_names[String(metadata.get("id", ""))] = String(
				metadata.get("display_name", metadata.get("id", "")))
		_research_signal_names[""] = ""
	return String(_research_signal_names.get(signal_key, signal_key))


## Ordered era table read from the authoring network once. Era index -> entry
## milestone, display name and decay display all resolve through here so the
## ideology layer never depends on TechnologyCatalog being compiled first.
static func era_rows() -> Array:
	return NativeCompiler.era_rows()


static func era_display_name(era_index: int) -> String:
	var rows := era_rows()
	if era_index < 0 or era_index >= rows.size():
		return ""
	return String((rows[era_index] as Dictionary).get("display_name", ""))

## Technology that must be completed before the player counts as "in" this era,
## i.e. the era's own entry gate. Empty for era 0 (no gate).
static func era_entry_technology_key(era_index: int) -> String:
	var rows := era_rows()
	if era_index <= 0 or era_index >= rows.size():
		return ""
	return String((rows[era_index] as Dictionary).get("entry_milestone_id", ""))

func _display_name(definition) -> String:
	var name_key := String(definition.name_key)
	if not name_key.is_empty() and not name_key.contains("."):
		return name_key
	return String(definition.id)

func _display_name_for_id(ideology_id: String) -> String:
	for definition in definitions:
		if definition != null and String(definition.id) == ideology_id:
			return _display_name(definition)
	return ideology_id

func _exclusion_rivals(definition) -> PackedStringArray:
	var rivals := PackedStringArray()
	var group := String(definition.exclusion_group).strip_edges()
	if group.is_empty():
		return rivals
	for other in definitions:
		if other == null or other == definition \
				or String(other.exclusion_group).strip_edges() != group:
			continue
		rivals.append(_display_name(other))
	return rivals

func _synergy_resource(synergy_id: String):
	for synergy in synergies:
		if synergy != null and String(synergy.id) == synergy_id:
			return synergy
	return null

func _synergy_display_name(synergy) -> String:
	var display := String(synergy.display_name).strip_edges()
	if not display.is_empty():
		return display
	return String(synergy.id)

func _present_effect_lines(modifier_catalog, card_id: String, level_index: int,
		effects: Array[Resource], on_enter_effects: Array[Resource] = []) -> PackedStringArray:
	var persistent_lines := PackedStringArray()
	var on_enter_lines := PackedStringArray()
	if modifier_catalog != null \
			and modifier_catalog.has_method("present_definition_for_ideology"):
		for effect in effects:
			if effect == null or not effect is EffectCommandScript:
				continue
			for line in modifier_catalog.present_definition_for_ideology(
					effect.definition_key, int(effect.value_q16)):
				_append_clean_line(persistent_lines, line)
	elif modifier_catalog != null and modifier_catalog.has_method("present_definition"):
		for effect in effects:
			if effect == null or not effect is EffectCommandScript:
				continue
			for line in modifier_catalog.present_definition(
					effect.definition_key, int(effect.value_q16)):
				_append_clean_line(persistent_lines, line)
	# A managed program row names a program, not a Modifier definition, so the
	# presenter above returns nothing for it. Falling back to the program's own
	# summary is the only thing standing between a cell-level card and a card
	# face that lists its cost and nothing else.
	for effect in effects:
		if effect == null or not effect is EffectCommandScript:
			continue
		var summary := _program_summary(String(effect.definition_key))
		if not summary.is_empty():
			_append_clean_line(persistent_lines, summary)
	for effect in on_enter_effects:
		if effect == null or not effect is EffectCommandScript:
			continue
		var on_enter := _present_on_enter_effect(effect, modifier_catalog)
		if not on_enter.is_empty():
			_append_clean_line(on_enter_lines, on_enter)
	for line in _present_rule_lines(card_id, level_index):
		_append_clean_line(persistent_lines, line)
	# Layout may wrap or scroll these lines; it must never silently drop a price,
	# a rule rewrite, or a first-entry reward to fit a fixed presentation budget.
	var lines := persistent_lines.duplicate()
	for line in on_enter_lines:
		if not lines.has(line):
			lines.append(line)
	return lines

func _present_rule_lines(card_id: String, level_index: int) -> PackedStringArray:
	var lines := PackedStringArray()
	if card_id.is_empty():
		return lines
	for definition in definitions:
		if definition == null or String(definition.id) != card_id:
			continue
		if definition.copy_left_programs:
			lines.append("复制同一区域内左邻槽位理念当前等级的持续效果（包含其代价）；左邻为空或为传世理念时不复制，不复制首次奖励和条件改写规则")
		break
	# Hidden self-synergies carry real player-facing rules. Their generated notes
	# use the same authoring fields as the executable rewrite; no second card-ID
	# override table is allowed here. Location mask 2 is an ideology-slot rule.
	for synergy in synergies:
		if synergy == null or not synergy.hidden \
				or synergy.required_ideology_ids.size() != 1 \
				or String(synergy.required_ideology_ids[0]) != card_id \
				or int(synergy.minimum_levels[0]) > level_index:
			continue
		for parameter in synergy.overrides:
			if parameter == null or String(parameter.note).strip_edges().is_empty():
				continue
			var note := "置于理念槽时：%s" % String(parameter.note)
			if not lines.has(note):
				lines.append(note)
	return lines

## Player-facing summary of the managed program named by `definition_key`.
##
## `effect_programs` is optional: a catalog that declares no programs (every
## fixture before this round, and any save-less test) simply yields "".
func _program_summary(definition_key: String) -> String:
	if definition_key.is_empty():
		return ""
	var catalog: Resource = effect_programs
	if catalog == null:
		catalog = IdeologyEffectCatalogScript.load_default()
	if catalog == null:
		return ""
	var rows: Variant = catalog.get("effects")
	if rows == null:
		return ""
	for program in rows:
		if program == null:
			continue
		if String(program.get("definition_key")) != definition_key:
			continue
		var summary: Variant = program.get("summary")
		if summary == null:
			return ""
		return String(summary).strip_edges()
	return ""


func _present_on_enter_effect(effect: Resource, modifier_catalog = null) -> String:
	return IdeologyCardFaceText._present_on_enter_effect(effect, modifier_catalog)

func _append_clean_line(lines: PackedStringArray, raw_line: Variant) -> void:
	var line := _clean_card_face_text(String(raw_line))
	if not line.is_empty() and not lines.has(line):
		lines.append(line)

func _clean_card_face_text(raw: String) -> String:
	return IdeologyCardFaceText._clean_card_face_text(self, raw)


func _replace_source_count_text(text: String) -> String:
	return IdeologyCardFaceText._replace_source_count_text(self, text)

func _format_card_face_number(value: float) -> String:
	return IdeologyCardFaceText._format_card_face_number(value)
