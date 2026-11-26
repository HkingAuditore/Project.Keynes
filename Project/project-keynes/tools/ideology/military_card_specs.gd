extends RefCounted

## Authored military ideology cards, effect programs, and synergies.

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
