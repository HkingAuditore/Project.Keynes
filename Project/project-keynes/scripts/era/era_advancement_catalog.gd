class_name EraAdvancementCatalog
extends RefCounted

## Static Era Advancement rules (docs/cpp-dots-runtime/era-advancement-runtime.md §3).
##
## Index convention: era indices follow `technology_network.json` `eras[]`
## (0 = stone … 10 = intelligent). A *target* era is the era the player is
## advancing into, so rules exist for target eras 1..10. Advancing into target
## era `t` grants `eras[t].milestone_id`; the stone milestone
## (`tech.settled_knowledge`, era 0) is granted as a prelude of the first
## advancement when the country does not hold it yet (see
## `prelude_milestone_ids()`), so its buff and the stone era-reward pool are
## never lost after milestones stopped being researchable.
##
## Goods quantities are fixed-point GOODS_SCALE units (1 unit = 1000).
## required = floor + per_cell × frozen territory cells.

const TechnologyCatalogScript = preload("res://scripts/economy/technology_catalog.gd")
const ValidatorScript = preload("res://scripts/technology/technology_network_validator.gd")

const GOODS_SCALE := 1000
const TECH_COMPLETION_RATIO := 0.8
const CONDITIONS_REQUIRED := 3
const CONDITIONS_RULE_TEXT := "科技必达 · 其余三选二"
const CONDITIONS_HELP_TEXT := "须完成本时代 80% 科技，并满足人口、建筑、贸易中的至少两项。"
const MIN_TARGET_ERA := 1
const MAX_ERA_INDEX := 10

const CONDITION_KEYS := ["tech", "population", "buildings", "trade"]
const CONDITION_LABELS := {
	"tech": "本时代科技（必需）",
	"population": "国家人口",
	"buildings": "建筑数量",
	"trade": "本时代贸易次数",
}

## Index = target era (0 unused). Population / built units / trade orders.
const POPULATION_THRESHOLDS := [0, 250, 750, 2000, 5000, 12500, 30000, 75000,
	187500, 450000, 1000000]
const BUILDING_THRESHOLDS := [0, 1000, 2000, 4000, 7000, 12000, 20000, 32000, 50000, 75000, 110000]
const TRADE_ORDER_THRESHOLDS := [0, 250, 750, 2000, 5000, 11000, 22500, 45000, 90000,
	175000, 350000]
## Total gate = national base above + per-cell requirement × currently owned cells.
const POPULATION_PER_CELL := [0, 50, 100, 200, 375, 625, 1000, 1500, 2250, 3000, 4500]
const BUILDINGS_PER_CELL := [0, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1200]
const TRADE_ORDERS_PER_CELL := [0, 50, 100, 200, 400, 800, 1500, 3000, 6000, 12000, 24000]
## Scale the authored goods basket by 50× in the first transition up to 265× in the last.
const PROCUREMENT_MULTIPLIERS := [0, 50, 60, 75, 90, 110, 135, 160, 190, 225, 265]

## Goods are chosen from what a country can already produce in the era it is
## leaving (technology tags of each good resolve to that era or earlier).
## They must also be **actually buyable**: the first advancement happens in the
## opening economy, whose local market only trades clothing / game_meat /
## gathered_plants / logs (verified in a real session). A good that nobody
## produces yet stalls the purchase forever at partial progress — flint did.
const PROCUREMENT := [
	[],
	# stone -> agrarian
	[{"good_id": "logs", "per_cell": 20 * GOODS_SCALE, "floor": 40 * GOODS_SCALE},
		{"good_id": "gathered_plants", "per_cell": 30 * GOODS_SCALE, "floor": 60 * GOODS_SCALE},
		{"good_id": "game_meat", "per_cell": 15 * GOODS_SCALE, "floor": 30 * GOODS_SCALE}],
	# agrarian -> kingdom
	[{"good_id": "adobe_brick", "per_cell": 25 * GOODS_SCALE, "floor": 60 * GOODS_SCALE},
		{"good_id": "pottery", "per_cell": 15 * GOODS_SCALE, "floor": 40 * GOODS_SCALE},
		{"good_id": "bronze_tools", "per_cell": 5 * GOODS_SCALE, "floor": 12 * GOODS_SCALE}],
	# kingdom -> empire
	[{"good_id": "bricks", "per_cell": 25 * GOODS_SCALE, "floor": 80 * GOODS_SCALE},
		{"good_id": "wrought_iron", "per_cell": 8 * GOODS_SCALE, "floor": 25 * GOODS_SCALE},
		{"good_id": "manuscripts", "per_cell": 4 * GOODS_SCALE, "floor": 12 * GOODS_SCALE},
		{"good_id": "raw_stone", "per_cell": 30 * GOODS_SCALE, "floor": 90 * GOODS_SCALE}],
	# empire -> exploration
	[{"good_id": "tools", "per_cell": 8 * GOODS_SCALE, "floor": 30 * GOODS_SCALE},
		{"good_id": "lumber", "per_cell": 30 * GOODS_SCALE, "floor": 100 * GOODS_SCALE},
		{"good_id": "cloth", "per_cell": 20 * GOODS_SCALE, "floor": 60 * GOODS_SCALE},
		{"good_id": "furniture", "per_cell": 10 * GOODS_SCALE, "floor": 30 * GOODS_SCALE}],
	# exploration -> enlightenment
	[{"good_id": "paper", "per_cell": 20 * GOODS_SCALE, "floor": 80 * GOODS_SCALE},
		{"good_id": "glass", "per_cell": 15 * GOODS_SCALE, "floor": 60 * GOODS_SCALE},
		{"good_id": "printed_materials", "per_cell": 12 * GOODS_SCALE, "floor": 50 * GOODS_SCALE},
		{"good_id": "tools", "per_cell": 12 * GOODS_SCALE, "floor": 50 * GOODS_SCALE}],
	# enlightenment -> steam
	[{"good_id": "coal", "per_cell": 60 * GOODS_SCALE, "floor": 250 * GOODS_SCALE},
		{"good_id": "wrought_iron", "per_cell": 25 * GOODS_SCALE, "floor": 100 * GOODS_SCALE},
		{"good_id": "cement", "per_cell": 20 * GOODS_SCALE, "floor": 80 * GOODS_SCALE},
		{"good_id": "steam_engines", "per_cell": 2 * GOODS_SCALE, "floor": 8 * GOODS_SCALE}],
	# steam -> electrical
	[{"good_id": "steel", "per_cell": 30 * GOODS_SCALE, "floor": 150 * GOODS_SCALE},
		{"good_id": "railway_equipment", "per_cell": 4 * GOODS_SCALE, "floor": 20 * GOODS_SCALE},
		{"good_id": "concrete", "per_cell": 30 * GOODS_SCALE, "floor": 150 * GOODS_SCALE},
		{"good_id": "industrial_chemicals", "per_cell": 10 * GOODS_SCALE, "floor": 50 * GOODS_SCALE}],
	# electrical -> atomic
	[{"good_id": "electrical_equipment", "per_cell": 8 * GOODS_SCALE, "floor": 40 * GOODS_SCALE},
		{"good_id": "electric_motor", "per_cell": 5 * GOODS_SCALE, "floor": 25 * GOODS_SCALE},
		{"good_id": "refined_fuel", "per_cell": 30 * GOODS_SCALE, "floor": 150 * GOODS_SCALE},
		{"good_id": "machine_parts", "per_cell": 8 * GOODS_SCALE, "floor": 40 * GOODS_SCALE}],
	# atomic -> information
	[{"good_id": "plastics", "per_cell": 30 * GOODS_SCALE, "floor": 150 * GOODS_SCALE},
		{"good_id": "electronic_components", "per_cell": 10 * GOODS_SCALE, "floor": 50 * GOODS_SCALE},
		{"good_id": "pharmaceuticals", "per_cell": 15 * GOODS_SCALE, "floor": 75 * GOODS_SCALE},
		{"good_id": "industrial_machinery", "per_cell": 6 * GOODS_SCALE, "floor": 30 * GOODS_SCALE}],
	# information -> intelligent
	[{"good_id": "computers", "per_cell": 10 * GOODS_SCALE, "floor": 60 * GOODS_SCALE},
		{"good_id": "semiconductors", "per_cell": 10 * GOODS_SCALE, "floor": 60 * GOODS_SCALE},
		{"good_id": "telecom_equipment", "per_cell": 6 * GOODS_SCALE, "floor": 40 * GOODS_SCALE}],
]

static var _eras_cache: Array[Dictionary] = []


static func era_metadata() -> Array[Dictionary]:
	if _eras_cache.is_empty():
		_eras_cache = TechnologyCatalogScript.public_era_metadata()
	return _eras_cache


static func era_count() -> int:
	return era_metadata().size()


static func era_name(era_index: int) -> String:
	var eras := era_metadata()
	if era_index < 0 or era_index >= eras.size():
		return ""
	return String(eras[era_index].get("display_name", ""))


static func era_id(era_index: int) -> String:
	var eras := era_metadata()
	if era_index < 0 or era_index >= eras.size():
		return ""
	return String(eras[era_index].get("id", ""))


static func milestone_id(era_index: int) -> StringName:
	var eras := era_metadata()
	if era_index < 0 or era_index >= eras.size():
		return &""
	return StringName(eras[era_index].get("milestone_id", ""))


static func is_valid_target(target_era: int) -> bool:
	return target_era >= MIN_TARGET_ERA and target_era <= MAX_ERA_INDEX \
		and target_era < era_count()


static func population_threshold(target_era: int, territory_count: int = 1) -> int:
	return int(POPULATION_THRESHOLDS[target_era]) + int(POPULATION_PER_CELL[target_era]) \
		* maxi(1, territory_count) if is_valid_target(target_era) else 0


static func building_threshold(target_era: int, territory_count: int = 1) -> int:
	return int(BUILDING_THRESHOLDS[target_era]) + int(BUILDINGS_PER_CELL[target_era]) \
		* maxi(1, territory_count) if is_valid_target(target_era) else 0


static func trade_order_threshold(target_era: int, territory_count: int = 1) -> int:
	return int(TRADE_ORDER_THRESHOLDS[target_era]) + int(TRADE_ORDERS_PER_CELL[target_era]) \
		* maxi(1, territory_count) if is_valid_target(target_era) else 0


static func procurement_goods(target_era: int) -> Array:
	if not is_valid_target(target_era):
		return []
	var rows := (PROCUREMENT[target_era] as Array).duplicate(true)
	for row: Dictionary in rows:
		row["floor"] = int(row.floor) * int(PROCUREMENT_MULTIPLIERS[target_era])
		row["per_cell"] = int(row.per_cell) * int(PROCUREMENT_MULTIPLIERS[target_era])
	return rows


## Required quantity (GOODS_SCALE units) for one procurement row.
static func required_quantity(row: Dictionary, territory_count: int) -> int:
	return int(row.get("floor", 0)) + int(row.get("per_cell", 0)) * maxi(1, territory_count)


## Milestones granted before the target milestone when the country lacks them.
## Only the first advancement has a prelude: the stone milestone.
static func prelude_milestone_ids(target_era: int) -> Array[StringName]:
	var out: Array[StringName] = []
	if target_era == MIN_TARGET_ERA:
		out.append(milestone_id(0))
	return out


## Player-facing buff lines from a milestone's explicit modifier terms.
static func milestone_buff_lines(milestone_technology_id: StringName) -> PackedStringArray:
	var out := PackedStringArray()
	for definition in TechnologyCatalogScript.public_definitions():
		if StringName(definition.get("id", "")) != milestone_technology_id:
			continue
		for term_value in definition.get("modifier_terms", []):
			var term: Dictionary = term_value
			out.append("%s %s" % [ValidatorScript.modifier_effect_subject(term),
				ValidatorScript.modifier_delta(term)])
		break
	return out


## Buffs granted by advancing into `target_era`. `include_prelude` adds the
## stone milestone lines when that milestone will be granted too.
static func buff_lines(target_era: int, include_prelude: bool = false) -> PackedStringArray:
	var out := PackedStringArray()
	if not is_valid_target(target_era):
		return out
	if include_prelude:
		for prelude in prelude_milestone_ids(target_era):
			out.append_array(milestone_buff_lines(prelude))
	out.append_array(milestone_buff_lines(milestone_id(target_era)))
	return out


## Every good id referenced by the rules (for catalog validation tests).
static func all_good_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for rows in PROCUREMENT:
		for row in rows:
			var good := String((row as Dictionary).get("good_id", ""))
			if not out.has(good):
				out.append(good)
	return out
