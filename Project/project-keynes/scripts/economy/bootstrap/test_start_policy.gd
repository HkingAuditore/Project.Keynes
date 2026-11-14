extends RefCounted

# Authored test-world capabilities; never grants all production technologies.
# Keep the authored diagnostic settlement stable when unrelated recipes are added.
const MERCHANT_BUILDING_ID := "early_merchant_post"
const BUILDING_IDS = [
	"gathering_ground", "timber_collector", "stone_collector", MERCHANT_BUILDING_ID,
	"communal_hearth", "flint_quarry", "lumber_plant", "stone_age_hunting_camp",
	"placer_gold_working", "surface_silver_working", "household_weaving_shelter",
	"knapping_workshop",
]

const TECHNOLOGY_IDS := [
	"tech.hunting", "tech.gathering", "tech.stone_knapping", "tech.fire_control",
	"tech.deadwood_collection", "tech.ground_stone_tools",
	"tech.communal_specialization", "tech.timber_sawing", "tech.gold_panning",
	"tech.surface_silver_collection", "tech.weaving",
	"tech.early_trade",
	"tech.household_production", "tech.hand_spinning",
	"tech.masonry",
]

const GOODS_SCALE := 1000
const Q16_ONE := 65536
const INT64_MAX := 9223372036854775807
const COLLECTOR_COUNT_CAP := 24
const CELL_POPULATION_CAP := 300
const RESOURCE_TIERED_POPULATION_SCALE := 0
const DEFAULT_POPULATION_SCALE := RESOURCE_TIERED_POPULATION_SCALE
const SUPPORTED_POPULATION_SCALES := [0, 1, 10, 100, 1000]
const RESOURCE_TIER_SCALES := [1, 10, 100, 500]
const INITIAL_RESOURCE_HORIZON_DAYS := 3650
const CONSTRUCTION_SOURCE_MIN_HORIZON_DAYS := 365
const FOOD_REQUIREMENT_PER_CAPITA := 1300
const CLOTHING_REQUIREMENT_PER_CAPITA := 4
const SURVIVAL_FUND_DAYS := 30
const INITIAL_HOUSEHOLD_STOCK_DAYS := 1
const INITIAL_BUILDING_INPUT_STOCK_DAYS := 1
const RESOURCE_BUILDING_RUNWAY_DAYS := INITIAL_RESOURCE_HORIZON_DAYS
const RENEWABLE_SAFE_HARVEST_Q16 := 32768
const RENEWABLE_MIN_RESERVE_Q16 := 22938
const RENEWABLE_GROWTH_DIVISOR := 8
const OWNER_OPERATING_CYCLES := 2
const PLANNED_UTILIZATION_Q16 := 49152
const TARGET_EMPLOYMENT_Q16 := Q16_ONE
const INITIAL_CARRYING_CAPACITY_SHARE_Q16 := 32768
const BOOTSTRAP_BRIDGE_STOCK := {
	"logs": 1000,
	"gathered_plants": 250,
	"flint": 500,
}

const TEST_COLLECTOR_COUNT_CAPS := {
	"flint_quarry": 1,
	"household_weaving_shelter": 2,
	"placer_gold_working": 1,
	"stone_age_hunting_camp": 12,
	"stone_collector": 1,
	"surface_silver_working": 1,
	"timber_collector": 3,
}

const TEST_INDUSTRY_COUNTS := {
	"communal_hearth": 2,
	"knapping_workshop": 2,
}

const FOOD_GOOD_IDS := {
	"prepared_staples": true, "bread": true, "grain": true, "gathered_plants": true,
	"potatoes": true,
	"game_meat": true, "meat": true, "fish": true, "canned_fish": true,
	"dairy_products": true, "vegetables": true, "processed_food": true,
}
const CLOTHING_GOOD_IDS := {
	"cloth": true, "fur": true, "clothing": true, "footwear": true,
}

const MID_STONE_TECHNOLOGY_IDS = TECHNOLOGY_IDS


static func technology_available(tags: PackedStringArray) -> bool:
	var has_technology_gate := false
	for tag in tags:
		var stable_id := String(tag)
		if not stable_id.begins_with("tech."):
			continue
		has_technology_gate = true
		if TECHNOLOGY_IDS.has(stable_id):
			return true
	return not has_technology_gate


static func building_available(spec: Dictionary) -> bool:
	if not technology_available(spec.get("technology_tags", PackedStringArray())):
		return false
	for tag in spec.get("required_technology_tags", PackedStringArray()):
		if not TECHNOLOGY_IDS.has(String(tag)):
			return false
	return true
