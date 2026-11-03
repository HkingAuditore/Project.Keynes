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

const IDEOLOGY_PATH := "res://data/ideologies/default_ideology_catalog.tres"
const MODIFIER_PATH := "res://data/modifiers/default_modifier_catalog.tres"
const EFFECT_PROGRAM_PATH := "res://data/ideologies/default_ideology_effects.tres"
const TRIGGER_PATH := "res://data/triggers/default_trigger_catalog.tres"

const DefinitionScript = preload("res://scripts/ideology/ideology_definition.gd")
const LevelScript = preload("res://scripts/ideology/ideology_level_definition.gd")
const StanceScript = preload("res://scripts/ideology/ideology_class_stance.gd")
const RequirementScript = preload("res://scripts/ideology/ideology_requirement.gd")
const SynergyScript = preload("res://scripts/ideology/ideology_synergy_definition.gd")
const EffectCommandScript = preload("res://scripts/effect/effect_command.gd")
const EffectProgramScript = preload("res://scripts/ideology/ideology_effect_definition.gd")
const EffectProgramCatalogScript = preload("res://scripts/ideology/ideology_effect_catalog.gd")
const EffectCatalogScript = preload("res://scripts/effect/effect_catalog.gd")
const EffectConditionScript = preload("res://scripts/effect/effect_condition.gd")
const ModifierDefinitionScript = preload("res://scripts/modifier/modifier_definition.gd")
const ModifierTermScript = preload("res://scripts/modifier/modifier_term.gd")
const IdeologyCatalogScript = preload("res://scripts/ideology/ideology_catalog.gd")
const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const TriggerCatalogScript = preload("res://scripts/trigger/trigger_catalog.gd")
const TargetTagDictionaryScript = preload("res://scripts/effect/target_tag_dictionary.gd")

const Q16 := 65536
const LEVEL_THRESHOLDS := [0, 524288, 1572864]
const LEVEL_DAILY := [205, 103, 0]
## 初识 / 通晓 / 化育. Benefits scale, costs stay flat (same rule as the generator).
const LEVEL_SCALES := [1.0, 1.6, 2.2]
const LEVEL_TITLES := ["初识", "通晓", "化育"]
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

const ADD := 0
const MUL := 2

## Upgrade families whose buildings carry `industry.military`. The arsenal /
## total-war cards name the weapon families (a card face holds at most six lines).
const ARSENAL_FAMILIES := ["melee_arms", "missile_arms", "firearms", "ordnance"]
const TOTAL_WAR_FAMILIES := ["firearms", "ordnance", "ammunition", "armored_vehicles"]

## term: [stat_key, op, value, is_benefit]. Benefits scale with level.
static func _t(stat: String, op: int, value: float, benefit := true) -> Array:
	return [stat, op, value, benefit]


static func _family_terms(families: Array, factor: float) -> Array:
	var out: Array = []
	for family in families:
		out.append(_t("country.output.family.%s_factor" % family, MUL, factor))
	return out


## §17.1 channel A: a managed Effect program over a cell tag, emitting one
## `military.cell.*` row per selected cell.
##
## Columns: program suffix, summary, tag name(s), selector kind, radius/cap/source
## cap (kind 16 only), stat, factor, and whether the factor is a benefit.
##
## `selector_cap` is 0 for the unbounded kinds (12/14/15/16): 0 means "the
## kind's own ceiling", which for a territory/source query is the whole set. A
## literal 32 would reinstate the old policy cap for these cards only.
static func channel_a_programs() -> Dictionary:
	return {
		"fortress_city": [
			# 城镇聚落格 -> 本国部队防御 +8%；邻格 +4%.
			# Two programs because the design names two different magnitudes on
			# two different cell sets; folding them into one would require the
			# "primary cell vs neighbour" split channel A deliberately avoids.
			{"key": "self", "summary": "城镇及以上聚落格：当地驻军防御 +8%",
				"tags": ["cell.settlement"], "selector": 12, "selector_cap": 0,
				"stat": "military.cell.defense_factor", "factor": 1.08},
			{"key": "ring", "summary": "城镇聚落格的邻格：当地驻军防御 +4%",
				"tags": ["cell.settlement"], "selector": 14, "selector_cap": 0,
				"stat": "military.cell.defense_factor", "factor": 1.04},
		],
		"military_farms": [
			# The +3% agriculture and the -2% manufacturing are BOTH per-cell
			# stats, so they ride on this program. The supply saving is Military's
			# own `military.cell.*` row and also per cell.
			{"key": "self", "summary": "有兵营的格：农业产出 +3%，制造业产出 −2%，当地驻军补给消耗 −10%",
				"tags": ["cell.barracks"], "selector": 12, "selector_cap": 0,
				"stat": "military.cell.supply_consumption_factor", "factor": 0.90,
				"extra": [["economy.city.building.agriculture_output_factor", 1.03],
					["economy.city.building.manufacturing_output_factor", 0.98, false]]},
			{"key": "ring", "summary": "有兵营的格的邻格：农业产出 +3%，制造业产出 −2%，当地驻军补给消耗 −10%",
				"tags": ["cell.barracks"], "selector": 14, "selector_cap": 0,
				"stat": "military.cell.supply_consumption_factor", "factor": 0.90,
				"extra": [["economy.city.building.agriculture_output_factor", 1.03],
					["economy.city.building.manufacturing_output_factor", 0.98, false]]},
		],
		"arsenal_city": [
			{"key": "self", "summary": "有军工建筑的格：当地兵营兵额 +10%",
				"tags": ["cell.military_industry"], "selector": 12, "selector_cap": 0,
				"stat": "military.cell.barracks_capacity_factor", "factor": 1.10},
			{"key": "ring", "summary": "有军工建筑的格的邻格：当地兵营兵额 +10%",
				"tags": ["cell.military_industry"], "selector": 14, "selector_cap": 0,
				"stat": "military.cell.barracks_capacity_factor", "factor": 1.10},
		],
		"frontier_garrison": [
			# 戍边 extension: 边境格的兵营兵额 +20%，驻防防御 +10%.
			{"key": "border", "summary": "边境且有兵营的格：当地兵营兵额 +20%，当地驻军防御 +10%",
				"tags": ["cell.border", "cell.barracks"], "selector": 12, "selector_cap": 0,
				"stats": [["military.cell.barracks_capacity_factor", 1.20],
					["military.cell.defense_factor", 1.10]]},
		],
	}


## §17.1 channel C: a timed stack per qualifying Military fact.
##
## Columns: trigger suffix (TriggerCatalog.military.stack.<suffix>),
## definition key suffix, duration, max stacks, and the Modifier terms ONE
## stack applies. The trigger fires once per event and `queue_apply` adds one
## stack with `duration_days`, so the card's ceiling is `max_stacks` layers.
static func channel_c_stacks() -> Dictionary:
	return {
		"wrath_of_the_fallen": {
			"trigger": "battle_lost", "duration_days": 60, "max_stacks": 5,
			"terms": [_t("country.military.attack_factor", MUL, 1.04)],
			"summary": "每输掉一场会战：全国部队攻击 +4%，持续 60 日，最多 5 层"},
		"pursuit": {
			"trigger": "battle_won", "duration_days": 20, "max_stacks": 3,
			"terms": [
				_t("country.military.speed_factor", MUL, 1.05),
				_t("country.military.attack_factor", MUL, 1.02)],
			"summary": "每赢得一场会战：全国部队速度 +5%、攻击 +2%，持续 20 日，最多 3 层"},
		"war_feeds_war": {
			"trigger": "cell_captured", "duration_days": 90, "max_stacks": 10,
			"terms": [_t("country.military.occupation_tax_efficiency", MUL, 1.03)],
			"summary": "每占领一格：占领税效率 +3%，持续 90 日，最多 10 层"},
		"merit_ranks": {
			"trigger": "battle_won", "duration_days": 90, "max_stacks": 5,
			"terms": [_t("economy.profession.soldier.satisfaction_bp", ADD, 200.0)],
			"summary": "每赢得一场会战：士兵职业满意度 +2%，持续 90 日，最多 5 层"},
		"scorched_earth": {
			"trigger": "cell_lost", "duration_days": 60, "max_stacks": 1,
			"terms": [
				_t("country.military.rule.home_ground", ADD, 0.05),
				_t("country.construction.cost_factor", MUL, 1.02, false)],
			"summary": "每失去一格：本土作战部队攻防 +5%，持续 60 日"},
	}


## Every card row. `channel` A and C entries are rewritten below into
## managed Effect programs / event stacks; a card whose channel is "国家" or
## "B" keeps a flat national Modifier row from this table or from
## `channel_a_programs()` / `channel_c_stacks()`.
static func cards() -> Array:
	var total_war_terms: Array = _family_terms(TOTAL_WAR_FAMILIES, 1.06)
	total_war_terms.append(_t("country.military.barracks_capacity_factor", MUL, 1.10))
	total_war_terms.append(_t("country.household.consumption_factor", MUL, 0.97, false))
	return [
		{"key": "militia_tradition", "name": "兵民一体", "school": "mobilization",
			"rarity": 1, "era": 0, "icon": "country.politics", "channel": "国家",
			"detail": "民兵攻防提高；代价是全国制造业产出略降。",
			"terms": [
				_t("country.military.militia_factor", MUL, 1.30),
				_t("country.output.manufacturing_factor", MUL, 0.98, false)]},
		{"key": "levy_system", "name": "府兵制", "school": "mobilization",
			"rarity": 1, "era": 1, "icon": "country.politics", "channel": "国家",
			"exclusion": "military_order",
			"detail": "兵额提高、军饷降低；代价是单格征召上限提高、部队士气下降。",
			"terms": [
				_t("country.military.barracks_capacity_factor", MUL, 1.20),
				_t("country.military.wage_factor", MUL, 0.85),
				_t("country.military.levy_rate", ADD, 0.01, false),
				_t("country.military.morale_add", ADD, -0.05, false)]},
		{"key": "volunteer_army", "name": "募兵制", "school": "commerce",
			"rarity": 2, "era": 2, "icon": "country.politics", "channel": "国家",
			"exclusion": "military_order",
			"detail": "训练时间缩短；代价是军饷提高。",
			"terms": [
				_t("country.military.training_time_factor", MUL, 0.80),
				_t("country.military.wage_factor", MUL, 1.20, false)]},
		{"key": "professional_army", "name": "职业常备军", "school": "mobilization",
			"rarity": 3, "era": 5, "icon": "country.politics", "channel": "国家",
			"exclusion": "military_order",
			"detail": "部队攻防与组织度恢复提高；代价是兵额减少、军饷提高。",
			"terms": [
				_t("country.military.attack_factor", MUL, 1.10),
				_t("country.military.defense_factor", MUL, 1.10),
				_t("country.military.organization_recovery_factor", MUL, 1.25),
				_t("country.military.barracks_capacity_factor", MUL, 0.80, false),
				_t("country.military.wage_factor", MUL, 1.25, false)]},
		{"key": "mutual_support", "name": "犄角之势", "school": "mobilization",
			"rarity": 1, "era": 2, "icon": "country.politics", "channel": "B",
			"detail": "周围 2 格内每有一支其他本国部队（最多 3 支），防御提高；代价是补给消耗增加。",
			"terms": [
				_t("country.military.rule.mutual_support", ADD, 0.03),
				_t("country.military.supply_consumption_factor", MUL, 1.05, false)]},
		{"key": "fortress_city", "name": "坚城", "school": "harmony",
			"rarity": 2, "era": 2, "icon": "country.politics", "channel": "A",
			"detail": "城镇及以上聚落格的本国部队防御提高，其邻格也有较小提高；代价是全国建设成本增加。",
			"terms": [
				_t("country.construction.cost_factor", MUL, 1.02, false)]},
		{"key": "wrath_of_the_fallen", "name": "哀兵必胜", "school": "mobilization",
			"rarity": 2, "era": 3, "icon": "country.politics", "channel": "C",
			"detail": "每输掉一场会战，全国部队攻击提高，持续 60 日，可叠加；代价是组织度恢复变慢。",
			# The stack layer carries the per-battle attack bonus. This national
			# row carries the card's standing cost, so the card obeys the same
			# "benefit plus price" shape every other card has.
			"terms": [
				_t("country.military.organization_recovery_factor", MUL, 0.97, false)]},
		{"key": "pursuit", "name": "乘胜追击", "school": "mobilization",
			"rarity": 1, "era": 1, "icon": "country.politics", "channel": "C",
			"detail": "每赢得一场会战，全国部队速度与攻击提高，持续 20 日，可叠加；代价是组织度恢复变慢。",
			"terms": [
				_t("country.military.organization_recovery_factor", MUL, 0.95, false)]},
		{"key": "war_feeds_war", "name": "以战养战", "school": "commerce",
			"rarity": 2, "era": 3, "icon": "country.politics", "channel": "C",
			"detail": "每占领一格，占领税效率提高，持续 90 日，可叠加；代价是被征发格的消费惩罚加倍。",
			"terms": [
				_t("country.household.consumption_factor", MUL, 1.01, false)]},
		{"key": "merit_ranks", "name": "军功爵制", "school": "mobilization",
			"rarity": 2, "era": 2, "icon": "country.politics", "channel": "C",
			"detail": "每赢得一场会战，士兵职业满意度提高，持续 90 日，可叠加；代价是军饷提高。",
			"terms": [
				_t("country.military.wage_factor", MUL, 1.05, false)]},
		{"key": "military_farms", "name": "屯田", "school": "agrarian",
			"rarity": 1, "era": 2, "icon": "economy.crop", "channel": "A",
			"detail": "有兵营的格及其邻格农业产出提高、驻防补给消耗降低；代价是这些格的制造业产出略降。",
			# The local manufacturing cost and the supply saving are PER-CELL (see
			# `channel_a_programs()`): a national definition cannot carry a cell
			# stat, and charging the whole country's industry for a local farming
			# decision would be a different card. This row is the card's national
			# price: garrisons get supply in kind from the farms, so the state
			# spends less on the车队 that used to carry it.
			"terms": [
				_t("country.military.supply_transport_factor", MUL, 0.95, false)]},
		{"key": "arsenal_city", "name": "武库", "school": "industry",
			"rarity": 1, "era": 2, "icon": "economy.building.factory", "channel": "A",
			"detail": "兵器作坊产出提高；有军工建筑的格及其邻格兵营兵额提高；代价是全国家庭消费需求增加。",
			"terms": _family_terms(ARSENAL_FAMILIES, 1.04) + [
				_t("country.household.consumption_factor", MUL, 1.01, false)]},
		{"key": "last_stand", "name": "背水一战", "school": "mobilization",
			"rarity": 3, "era": 3, "icon": "country.politics", "channel": "B",
			"detail": "被包围的部队攻防大幅提高；代价是部队组织度恢复变慢。",
			"terms": [
				_t("country.military.rule.last_stand", ADD, 0.25),
				_t("country.military.organization_recovery_factor", MUL, 0.95, false)]},
		{"key": "hold_the_line", "name": "寸土不让", "school": "harmony",
			"rarity": 1, "era": 4, "icon": "country.politics", "channel": "B",
			"detail": "固守且正受攻击的部队防御提高；代价是部队速度略降。",
			"terms": [
				_t("country.military.rule.hold_the_line", ADD, 0.10),
				_t("country.military.speed_factor", MUL, 0.98, false)]},
		{"key": "encirclement_doctrine", "name": "合围", "school": "learning",
			"rarity": 2, "era": 5, "icon": "metric.technology", "channel": "B",
			"detail": "攻击被我方包围的敌军时攻击提高；代价是战斗宽度缩小。",
			"terms": [
				_t("country.military.rule.encirclement", ADD, 0.15),
				_t("country.military.frontage_factor", MUL, 0.90, false)]},
		{"key": "blitzkrieg", "name": "闪击", "school": "industry",
			"rarity": 3, "era": 7, "icon": "economy.building.factory", "channel": "B",
			"detail": "速度快的部队在交战初期攻击提高；代价是补给消耗增加。",
			"terms": [
				_t("country.military.rule.blitz", ADD, 0.20),
				_t("country.military.supply_consumption_factor", MUL, 1.15, false)]},
		{"key": "scorched_earth", "name": "焦土", "school": "harmony",
			"rarity": 2, "era": 4, "icon": "country.politics", "channel": "C",
			"detail": "每失去一格，本土作战的部队攻防提高，持续 60 日；代价是建设成本增加。",
			"terms": [
				_t("country.construction.cost_factor", MUL, 1.02, false)]},
		{"key": "total_war", "name": "总体战", "school": "industry",
			"rarity": 3, "era": 7, "icon": "economy.building.factory", "channel": "国家",
			"detail": "战时军工产出与兵额提高；代价是战时家庭消费与出生率下降。",
			"terms": total_war_terms, "at_war_only": true},
		{"key": "deterrence", "name": "威慑", "school": "learning",
			"rarity": 3, "era": 8, "icon": "metric.technology", "channel": "国家",
			"detail": "全国部队防御提高；代价是军饷提高。",
			"terms": [
				_t("country.military.defense_factor", MUL, 1.08),
				_t("country.military.wage_factor", MUL, 1.10, false)]},
	]


## 戍边 already exists (`idea.frontier_garrison`); these terms are appended to its
## existing per-level Modifier definitions instead of authoring a second card.
static func frontier_extension_terms() -> Array:
	return [
		_t("country.military.barracks_capacity_factor", MUL, 1.20),
		_t("country.military.fortification_factor", MUL, 1.10),
	]


static func synergies() -> Array:
	var complex_terms: Array = _family_terms(TOTAL_WAR_FAMILIES, 1.05)
	return [
		{"id": "synergy.tuntian_garrison", "name": "屯戍一体",
			"members": ["idea.military_farms", "idea.frontier_garrison"],
			"description": "屯田与戍边同时生效：补给消耗再降低。",
			"terms": [_t("country.military.supply_consumption_factor", MUL, 0.80)]},
		{"id": "synergy.military_industrial_complex", "name": "兵工复合体",
			"members": ["idea.arsenal_city", "idea.total_war"],
			"description": "武库与总体战同时生效：军工产出再提高。",
			"terms": complex_terms},
		{"id": "synergy.death_ground", "name": "置之死地",
			"members": ["idea.wrath_of_the_fallen", "idea.last_stand"],
			"description": "哀兵必胜与背水一战同时生效：被包围部队与全军攻击再提高。",
			"terms": [
				_t("country.military.rule.last_stand", ADD, 0.05),
				_t("country.military.attack_factor", MUL, 1.02)]},
	]


## Mobilization resonance additions (§17.3): tier "2" morale +0.03, tier "4" 兵额 +10%.
const RESONANCE_EXTRA := {
	"ideology.resonance.mobilization.2": [["country.military.morale_add", ADD, 0.03, true]],
	"ideology.resonance.mobilization.4": [["country.military.barracks_capacity_factor", MUL, 1.10, true]],
}
const RESONANCE_SYNERGY_IDS := [
	"resonance.mobilization.2", "resonance.mobilization.4",
	"resonance.mobilization.5", "resonance.mobilization.6",
]

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
	for card in cards():
		all_terms.append_array(card["terms"])
	all_terms.append_array(frontier_extension_terms())
	for synergy in synergies():
		all_terms.append_array(synergy["terms"])
	for extra in RESONANCE_EXTRA.values():
		all_terms.append_array(extra)
	# Channel A/C terms live on their own programs/stacks, so they are validated
	# through the same table but reached through their own accessors.
	for spec in channel_a_programs().values():
		for program in spec:
			for row in _channel_a_terms(program):
				all_terms.append(row)
	for stack in channel_c_stacks().values():
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
	for card in cards():
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
				upgraded = upgraded or _rewrite_modifier_definition(
					definition_index[modifier_key], String(card["detail"]),
					card["terms"], float(LEVEL_SCALES[level]))
				continue
			var modifier_definition := _modifier_definition(modifier_key,
				"%s（%s）" % [card["name"], LEVEL_TITLES[level]], String(card["detail"]),
				card["terms"], float(LEVEL_SCALES[level]))
			new_modifier_definitions.append(modifier_definition)
			definition_index[modifier_key] = modifier_definition
			upgraded = true
		if existing == null:
			var definition := _card_definition(card)
			new_definitions.append(definition)
			card_index[card_id] = definition
			changed += 1
			_say("add card %s %s [channel %s]" % [card_id, card["name"], card["channel"]])
			continue
		if _rewrite_card_definition(existing, card):
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
		changed += _append_terms(definition, frontier_extension_terms(),
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
	for spec in synergies():
		var synergy_id := String(spec["id"])
		if synergy_index.has(synergy_id):
			_say("skip synergy (exists): %s" % synergy_id)
			continue
		var modifier_key := "ideology.%s" % synergy_id
		if not definition_index.has(modifier_key):
			var modifier_definition := _modifier_definition(modifier_key,
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
		var row := _persistent_row(modifier_key)
		synergy.persistent_effects = [row]
		_set_uid(synergy, "Synergy" + _camel(synergy_id.trim_prefix("synergy.")))
		_set_uid(row, "EffectSynergy" + _camel(synergy_id.trim_prefix("synergy.")))
		new_synergies.append(synergy)
		synergy_index[synergy_id] = synergy
		changed += 1
		_say("add synergy %s %s" % [synergy_id, spec["name"]])

	# --- 4. mobilization resonance -------------------------------------------
	for key in RESONANCE_EXTRA:
		var definition: Resource = definition_index.get(String(key))
		if definition == null:
			_say("FAILED: %s missing" % key)
			return 1
		changed += _append_terms(definition, RESONANCE_EXTRA[key], 1.0)
	var mobilization_cards := PackedStringArray()
	for card in cards():
		if String(card["school"]) == "mobilization":
			mobilization_cards.append("idea.%s" % card["key"])
	for synergy_id in RESONANCE_SYNERGY_IDS:
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
			for card in cards():
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
	for card_key in channel_a_programs():
		var specs: Array = channel_a_programs()[card_key]
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
	for card_key in channel_a_programs():
		for spec in channel_a_programs()[card_key]:
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
	for term in _channel_a_terms(spec):
		var row := EffectCommandScript.new()
		# action 1 = MODIFIER apply; domain 2 = Modifier ECONOMY (per cell), which
		# is where every `military.cell.*` stat is declared. A country-domain row
		# would be rejected by the ideology compiler as an unreversible national
		# modifier on a cell program.
		row.action = 1
		row.domain = 2
		row.opcode = 1
		row.target_resolver = 1
		row.value_mode = 0
		row.value_q16 = Q16
		row.duration_days = -1
		row.stacks = 1
		row.command_key = &"ideology.cell"
		row.definition_key = StringName("ideology.military.%s.%d"
			% [definition_key, index])
		_set_uid(row, "MilCell%sCmd%d" % [_camel(definition_key), index])
		# The definition key names the CELL modifier row; it must resolve to a
		# Modifier definition, authored below.
		_row_definitions[String(row.definition_key)] = term
		commands.append(row)
		index += 1
	program.commands = commands
	program.instructions = [_magnitude_instruction()]
	_set_uid(program, "MilProg" + _camel(definition_key))
	return program


## Cell modifier definition key -> the `_t` row it applies. Filled while the
## channel-A programs are built and consumed by `_author_cell_modifier_rows()`.
var _row_definitions: Dictionary = {}


## One CONST instruction, so the program has a value source without a ramp.
func _magnitude_instruction() -> Resource:
	var instruction: Resource = load(
		"res://scripts/effect/effect_instruction.gd").new()
	instruction.op = 1 # CONST
	instruction.value_q16 = Q16
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
			if _rewrite_modifier_definition(existing, String(spec[0]), [spec], 1.0):
				changed += 1
				_say("upgrade cell row %s" % key)
			continue
		var definition := _modifier_definition(String(key), String(key),
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
	for card_key in channel_c_stacks():
		var spec: Dictionary = channel_c_stacks()[card_key]
		var suffix := String(spec["trigger"])
		var terms: Array = spec["terms"]
		for level in 3:
			# One Modifier definition per (card, level): the trigger applies the
			# level the card is currently at, so the stack's magnitude has to be
			# the level-scaled one rather than a single shared row.
			var definition_key := "ideology.stack.%s.l%d" % [card_key, level + 1]
			var scaled: Array = []
			for spec_row in terms:
				scaled.append_array(_scaled_terms([spec_row], float(LEVEL_SCALES[level])))
			var key := StringName(definition_key)
			var existing: Resource = definition_index.get(String(key))
			if existing != null:
				if int(existing.stack_policy) != 2 or int(existing.max_stacks) != int(spec["max_stacks"]):
					existing.stack_policy = 2
					existing.max_stacks = int(spec["max_stacks"])
					existing.default_duration_days = int(spec["duration_days"])
					changed += 1
					_say("repair stack row %s policy/stacks/duration" % definition_key)
				elif _rewrite_modifier_definition(existing, String(spec["summary"]),
						[scaled[0]] if scaled.size() == 1 else scaled, 1.0):
					changed += 1
			else:
				var definition := _modifier_definition(definition_key,
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


func _modifier_definition(key: String, display_name: String, description: String,
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


func _term(spec: Array, scale: float) -> Resource:
	var term := ModifierTermScript.new()
	term.stat_key = StringName(String(spec[0]))
	term.operation = int(spec[1])
	var value := float(spec[2])
	if bool(spec[3]) and not is_equal_approx(scale, 1.0):
		if term.operation == MUL:
			value = 1.0 + (value - 1.0) * scale
		else:
			value = value * scale
	term.value = snappedf(value, 0.0001)
	return term


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
		var term := _term(spec, scale)
		_set_uid(term, "TermIdeology%sMil%d" % [
			_camel(String(definition.key).trim_prefix("ideology.")), terms.size()])
		terms.append(term)
		added += 1
	if added == 0:
		return 0
	definition.terms = terms
	_say("extend %s +%d terms" % [definition.key, added])
	return 1


func _persistent_row(definition_key: String) -> Resource:
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


func _card_definition(card: Dictionary) -> Resource:
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
		var specs: Array = channel_a_programs().get(String(card["key"]), [])
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
func _set_uid(resource: Resource, uid: String) -> void:
	if resource.has_method("set_scene_unique_id"):
		resource.set_scene_unique_id(uid)


static func _camel(text: String) -> String:
	var out := ""
	for part in text.replace(".", "_").split("_", false):
		out += part.substr(0, 1).to_upper() + part.substr(1)
	return out


## The Modifier terms ONE channel-A program applies, as `_t` rows.
##
## `stat` (single) and `stats` (list) are both accepted because most programs
## move one stat while 戍边's border program moves two; forcing the single form
## would have meant two overlapping programs over the same tag, and the derived
## layer would then count the cell twice for `barracks_capacity_factor`.
static func _channel_a_terms(program: Dictionary) -> Array:
	var out: Array = []
	if program.has("stats"):
		for pair in program["stats"]:
			out.append(_t(String(pair[0]), MUL, float(pair[1])))
	else:
		out.append(_t(String(program["stat"]), MUL, float(program["factor"])))
	for pair in program.get("extra", []):
		# `extra` rows are the card's PRICE (a cell stat the effect costs the
		# player) as well as ordinary benefits, so the benefit flag is part of
		# the row: a price must not scale with the card's level.
		var benefit := bool(pair[2]) if pair.size() > 2 else float(pair[1]) >= 1.0
		out.append(_t(String(pair[0]), MUL, float(pair[1]), benefit))
	return out


## Rebuilds an existing per-level Modifier definition in place.
##
## Returns true when anything changed. A definition whose terms already match is
## left untouched, which is what keeps a second run a no-op at the SAVE level --
## the tool reports "nothing to do" instead of rewriting identical resources and
## churning the file (and the catalog hash) on every invocation.
func _rewrite_modifier_definition(definition: Resource, detail: String,
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
			if int(spec[1]) == MUL:
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
func _rewrite_card_definition(definition: Resource, card: Dictionary) -> bool:
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
	var specs: Array = channel_a_programs().get(String(card["key"]), [])
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

