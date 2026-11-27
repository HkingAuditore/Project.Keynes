class_name StarterEconomyPlanner
extends RefCounted

const BuildingProfileScript = preload("res://scripts/data/building_profile.gd")
const ResourceProfileRegistry = preload(
	"res://scripts/data/resource_profile_registry.gd")

const BUILDING_DIR := "res://data/economy/buildings"
const ECONOMY_PROFILE_PATH := "res://data/economy/default_economy.tres"
const SURVIVAL_PLAN_PATH := \
	"res://data/economy/consumption_plans/survival_household.tres"
const CLOTHING_CURVE_PATH := \
	"res://data/economy/environment_curves/cold_clothing_quantity.tres"
const PRODUCTION_CLIMATE_DIR := "res://data/economy/production_climates"
const STARTER_POPULATION := 40
const GOODS_SCALE := 1000
const Q16_ONE := 65536
const RESOURCE_RUNWAY_DAYS := 365
const RENEWABLE_SAFE_HARVEST_Q16 := 0
const RENEWABLE_MIN_RESERVE_Q16 := 22938
const RENEWABLE_GROWTH_DIVISOR := 8
const MIN_FOOD_COVERAGE_Q16 := 85197 # 130%; climate and population-growth buffer
const TARGET_SUPPLY_MAX_Q16 := 91750 # 140%
const TARGET_FOOD_MAX_Q16 := 98304 # 150%

const FIXED_BUILDING_IDS := {
	"early_merchant_post": true,
	"placer_gold_working": true,
	"deadwood_gathering_camp": true,
}
const PRECIOUS_STARTER_BUILDING_IDS := {
	"placer_gold_working": true,
}
const PRECIOUS_GOOD_IDS := {"gold": true}
const PRECIOUS_RESOURCE_IDS := {"gold_ore": true}
# One pending knowledge practice (catalog cost_points 3000 → 3000 * GOODS_SCALE).
# A larger grant zeros government procurement remaining_points, so automatic
# investment never seeds the first unlocked research building.
const STARTER_TREASURY_TECHNOLOGY_POINTS := 3000 * GOODS_SCALE
const FALLBACK_KNOWLEDGE_TECH_ID := "tech.early_knowledge_institution"
const FALLBACK_KNOWLEDGE_BUILDING_ID := "early_knowledge_institution"
const CONSTRUCTION_BACKBONE := [
	{
		"tech_id": "tech.deadwood_collection",
		"building_id": "deadwood_gathering_camp",
		"resource_id": "timber",
		"good_id": "logs",
	},
]



## Read-only deterministic planner; NativeEconomyRuntime owns runtime state.

const StarterInputs = preload("res://scripts/economy/starter_economy_inputs.gd")
const StarterConstruction = preload("res://scripts/economy/starter_economy_construction.gd")
const StarterSupplySearch = preload("res://scripts/economy/starter_economy_supply_search.gd")


static func plan(map: MapData, cell_idx: int, starter_route: Dictionary,
		facade = null) -> Dictionary:
	if map == null or cell_idx < 0 or cell_idx >= map.cell_count():
		return StarterInputs._error("starter_planner_cell_invalid",
			"开局经济规划器收到无效地块。")
	var selected_ids: PackedStringArray = starter_route.get(
		"starter_building_ids", PackedStringArray())
	var technology_ids: PackedStringArray = starter_route.get(
		"starter_technology_ids", PackedStringArray())
	if selected_ids.is_empty() or technology_ids.is_empty():
		return StarterInputs._error("starter_planner_route_invalid",
			"开局经济规划器缺少建筑或科技路线。")
	StarterInputs._active_reserve_overlay = starter_route.get("reserve_overlay", {})
	if StarterInputs._active_reserve_overlay == null:
		StarterInputs._active_reserve_overlay = {}
	StarterInputs._ensure_profiles_loaded()
	var output_efficiency_q16 := _configured_output_efficiency_q16(facade)
	var completed := {}
	for technology_id in technology_ids:
		completed[String(technology_id)] = true
	var selected := {}
	for building_id in selected_ids:
		selected[String(building_id)] = true

	var candidates: Array[Dictionary] = []
	var profile_by_id := {}
	for profile in StarterInputs._building_profiles:
		profile_by_id[String(profile.id)] = profile
		var building_id := String(profile.id)
		var is_selected := selected.has(building_id)
		if not is_selected:
			continue
		if StarterInputs._is_unselected_precious_profile(profile, is_selected):
			continue
		if StarterInputs._is_unselected_knowledge_profile(profile, is_selected):
			continue
		var employee_professions: PackedStringArray = profile.employee_profession_ids
		var employee_slots: PackedInt64Array = profile.employee_slots_per_building
		var has_employees: bool = not employee_professions.is_empty() \
				or not employee_slots.is_empty()
		if has_employees:
			if is_selected and allows_starter_employee_roles(building_id):
				pass
			elif is_selected:
				return StarterInputs._error("starter_employee_role_forbidden",
					"石器时代初始建筑不得包含雇员岗位：%s" % building_id)
			else:
				continue
		var owner_slots := int(profile.owner_slots_per_building)
		if owner_slots <= 0:
			continue
		var resource_cap := StarterInputs._resource_building_count_cap(profile, map, cell_idx)
		if resource_cap == 0 or not StarterInputs._conditions_met(profile, map, cell_idx):
			# Optional producers can drop out; remaining core must still close food.
			continue
		var fixed := FIXED_BUILDING_IDS.has(building_id) \
			or StarterInputs._profile_outputs(profile, "technology_points") \
			or StarterInputs._profile_outputs(profile, "clothing")
		var minimum := 1 if is_selected else 0
		var maximum := 1 if fixed else STARTER_POPULATION / owner_slots
		if resource_cap >= 0:
			maximum = mini(maximum, resource_cap)
		maximum = mini(maximum, StarterInputs._useful_count_limit(profile, starter_route, map,
			cell_idx, maximum, is_selected, output_efficiency_q16))
		if maximum < minimum:
			return StarterInputs._error("starter_building_capacity_unsatisfied",
				"当地资源承载力不足以预建：%s" % building_id)
		candidates.append({
			"id": building_id,
			"profile": profile,
			"owner_slots": owner_slots,
			"employee_slots": _employee_slot_count(profile),
			"min_count": minimum,
			"max_count": maximum,
			"resource_cap": resource_cap,
			"climate_q16": StarterInputs._production_climate_q16(profile, map, cell_idx),
		})

	for building_id in selected_ids:
		var found := false
		for candidate in candidates:
			if String(candidate.id) == String(building_id):
				found = true
				break
		if found:
			continue
		if String(building_id) == "stone_age_hunting_camp" \
				or String(building_id) == "hide_scraping_shelter":
			continue
		return StarterInputs._error("starter_building_missing",
			"规划目录缺少路线建筑：%s" % building_id)
	if candidates.is_empty():
		return StarterInputs._error("starter_planner_no_candidates", "当地没有可规划的石器时代建筑。")
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.id) < String(b.id))
	var search_context := StarterSupplySearch._compile_search_context(
		candidates, map, cell_idx, starter_route, output_efficiency_q16)
	if not bool(search_context.get("ok", false)):
		return search_context

	var minimum_owner_slots := 0
	for candidate in candidates:
		minimum_owner_slots += int(candidate.min_count) * int(candidate.owner_slots)
	if minimum_owner_slots > STARTER_POPULATION:
		return StarterInputs._error("starter_population_overcommitted",
			"路线基础建筑的自营岗位容量已经超过 40 个。")
	var suffix_min := PackedInt32Array()
	var suffix_max := PackedInt32Array()
	suffix_min.resize(candidates.size() + 1)
	suffix_max.resize(candidates.size() + 1)
	for index in range(candidates.size() - 1, -1, -1):
		suffix_min[index] = suffix_min[index + 1] + \
			int(candidates[index].min_count) * int(candidates[index].owner_slots)
		suffix_max[index] = suffix_max[index + 1] + \
			int(candidates[index].max_count) * int(candidates[index].owner_slots)
	var search := {"best": {}, "evaluated": 0}
	StarterSupplySearch._search_counts(candidates, 0, PackedInt32Array(), 0, suffix_min, suffix_max,
		search_context, search)
	var best: Dictionary = search.best
	if best.is_empty():
		return {
			"ok": false,
			"code": "starter_capacity_plan_unsatisfied",
			"message": "当地资源无法组成不超过 40 个自营岗位的可持续开局产业。",
			"candidate_building_ids": StarterSupplySearch._candidate_ids(candidates),
			"evaluated_combinations": int(search.evaluated),
		}
	if facade != null:
		var facade_check := _validate_facade(best, facade)
		if not bool(facade_check.get("ok", false)):
			return facade_check
	var construction_contract := StarterConstruction._compile_starter_construction_contract(
		best, starter_route, completed, map, cell_idx, profile_by_id)
	if not bool(construction_contract.get("ok", false)):
		return construction_contract
	best.merge(construction_contract, true)
	var pending_construction := StarterConstruction._compile_pending_knowledge_construction(
		starter_route, profile_by_id)
	if not bool(pending_construction.get("ok", false)):
		return pending_construction
	best.merge(pending_construction, true)
	best["candidate_building_ids"] = StarterSupplySearch._candidate_ids(candidates)
	best["evaluated_combinations"] = int(search.evaluated)
	best["starter_treasury_good_id"] = "technology_points"
	best["starter_treasury_quantity"] = STARTER_TREASURY_TECHNOLOGY_POINTS
	best["starter_output_efficiency_q16"] = output_efficiency_q16
	return best

static func _configured_output_efficiency_q16(facade = null) -> int:
	# Selection happens before an EconomyFacade exists; both paths must use the
	# same production multiplier rather than silently planning against 1x output.
	var profile = facade.profile() if facade != null else load(ECONOMY_PROFILE_PATH)
	if profile == null:
		return Q16_ONE
	return clampi(int(profile.building_output_efficiency_q16), Q16_ONE, Q16_ONE * 4)

static func select_pending_knowledge(map: MapData, cell_idx: int,
		region: String) -> Dictionary:
	StarterInputs._ensure_profiles_loaded()
	# The institution is universal. Regional geography now selects one of its
	# five visible research routes, rather than selecting five different
	# buildings and technologies at game start.
	return {
		"ok": true,
		"tech_id": FALLBACK_KNOWLEDGE_TECH_ID,
		"building_id": FALLBACK_KNOWLEDGE_BUILDING_ID,
	}

static func select_construction_backbone(map: MapData, cell_idx: int) -> Dictionary:
	StarterInputs._ensure_profiles_loaded()
	for option_value in CONSTRUCTION_BACKBONE:
		var option: Dictionary = option_value
		var building_id := String(option.get("building_id", ""))
		if building_id.is_empty() or not _knowledge_building_operable(
				map, cell_idx, building_id):
			continue
		return {
			"ok": true,
			"tech_id": String(option.tech_id),
			"building_id": building_id,
			"resource_id": String(option.resource_id),
			"good_id": String(option.good_id),
		}
	return StarterInputs._error("starter_construction_backbone_unavailable",
		"出生点没有可工的枯枝采集营。")

static func _knowledge_building_operable(map: MapData, cell_idx: int,
		building_id: String) -> bool:
	var profile = StarterInputs._building_profile_by_id(building_id)
	if profile == null:
		return false
	if not StarterInputs._conditions_met(profile, map, cell_idx):
		return false
	if StarterInputs._resource_building_count_cap(profile, map, cell_idx) == 0:
		return false
	return StarterInputs._production_climate_q16(profile, map, cell_idx) > 0

static func _validate_facade(plan_result: Dictionary, facade) -> Dictionary:
	var ids: PackedStringArray = plan_result.starter_building_ids
	var counts: PackedInt64Array = plan_result.starter_building_counts
	var job_total := 0
	for index in range(ids.size()):
		var job_spec: Dictionary = facade.building_job_spec(ids[index])
		if not bool(job_spec.get("ok", false)):
			return StarterInputs._error("starter_facade_catalog_mismatch",
				"运行时目录缺少规划建筑：%s" % ids[index])
		if not (job_spec.employee_professions as PackedStringArray).is_empty() \
				or not (job_spec.employee_slots as PackedInt64Array).is_empty():
			if not allows_starter_employee_roles(String(ids[index])):
				return StarterInputs._error("starter_employee_role_forbidden",
					"石器时代初始建筑不得包含雇员岗位：%s" % ids[index])
		job_total += int(job_spec.owner_slots) * int(counts[index])
	if job_total <= 0 or job_total > STARTER_POPULATION \
			or job_total != int(plan_result.get("starter_job_capacity", -1)):
		return StarterInputs._error("starter_facade_job_capacity_mismatch",
			"规划目录与运行时目录的可自主匹配岗位容量不一致。")
	return {"ok": true}

static func allows_starter_employee_roles(building_id: String) -> bool:
	return PRECIOUS_STARTER_BUILDING_IDS.has(String(building_id))

static func _employee_slot_count(profile) -> int:
	var total := 0
	for slot in profile.employee_slots_per_building:
		total += int(slot)
	return total


static func _ensure_profiles_loaded() -> void:
	StarterInputs._ensure_profiles_loaded()


static func _starter_output_quantity(raw_quantity: int, climate_q16: int,
		output_efficiency_q16: int) -> int:
	return StarterInputs._starter_output_quantity(raw_quantity, climate_q16, output_efficiency_q16)


static func _compile_search_context(candidates: Array[Dictionary], map: MapData,
		cell_idx: int, starter_route: Dictionary,
		output_efficiency_q16: int = Q16_ONE) -> Dictionary:
	return StarterSupplySearch._compile_search_context(candidates, map, cell_idx, starter_route, output_efficiency_q16)


static func _search_counts(candidates: Array[Dictionary], index: int,
		counts: PackedInt32Array, owner_slots: int, suffix_min: PackedInt32Array,
		suffix_max: PackedInt32Array, context: Dictionary,
		search: Dictionary) -> void:
	StarterSupplySearch._search_counts(candidates, index, counts, owner_slots, suffix_min, suffix_max, context, search)


static func _evaluate_counts(candidates: Array[Dictionary], counts: PackedInt32Array,
		context: Dictionary) -> Dictionary:
	return StarterSupplySearch._evaluate_counts(candidates, counts, context)
