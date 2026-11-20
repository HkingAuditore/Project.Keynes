extends SceneTree

const Planner = preload("res://scripts/economy/starter_economy_planner.gd")
const Building = preload("res://scripts/data/building_profile.gd")
const Economy = preload("res://scripts/data/economy_profile.gd")
const Registry = preload("res://scripts/data/resource_profile_registry.gd")
const Bootstrap = preload("res://scripts/economy/starter_settlement_bootstrap.gd")
const Q16 := 65536

var _checks := 0
var _failures := 0


class ProfileFacade extends RefCounted:
	var configured_profile

	func profile():
		return configured_profile


func _init() -> void:
	Planner._ensure_profiles_loaded()
	_test_configured_multiplier()
	_test_minimum_capacity_without_soft_inputs()
	_test_hard_input_closure()
	_test_soft_inputs_do_not_discount_extraction()
	_test_opening_cash_preserves_food_bridge()
	print("[starter-planner-balance] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _test_configured_multiplier() -> void:
	var facade := ProfileFacade.new()
	facade.configured_profile = Economy.new()
	facade.configured_profile.building_output_efficiency_q16 = 98304
	_expect("configured facade supplies the production multiplier",
		Planner._configured_output_efficiency_q16(facade) == 98304)
	var production = load("res://data/economy/default_economy.tres")
	_expect("pre-facade selection uses the same formal profile",
		Planner._configured_output_efficiency_q16() ==
		int(production.building_output_efficiency_q16))
	_expect("catalog rounding precedes climate rounding",
		Planner._starter_output_quantity(1001, 32768, 98304) == 750)


func _test_minimum_capacity_without_soft_inputs() -> void:
	# Forty people's staple target is 17,600 units/day; the 130% safety floor
	# requires >22,880. A 4,000-unit producer needs exactly 6/4/3 buildings at
	# 1x/1.5x/2x. Missing optional tools must neither halve nor bonus its output.
	var profile = _food_profile()
	var map := _map()
	for scenario in [[65536, 6], [98304, 4], [131072, 3]]:
		var candidates: Array[Dictionary] = [_candidate(profile)]
		var context: Dictionary = Planner._compile_search_context(
			candidates, map, 0, _route(), int(scenario[0]))
		var search := {"best": {}, "evaluated": 0}
		Planner._search_counts(candidates, 0, PackedInt32Array(), 0,
			PackedInt32Array([1, 0]), PackedInt32Array([40, 0]), context, search)
		var best: Dictionary = search.best
		_expect("soft tools are not a mandatory opening input",
			(candidates[0].inputs as Dictionary).is_empty())
		_expect("minimum opening capacity tracks the configured multiplier %d" % scenario[0],
			not best.is_empty() and int(best.get("starter_building_total", 0)) == int(scenario[1]))
		_expect("the 40-person/130%% safety contract survives %d" % scenario[0],
			int(best.get("starter_job_capacity", 41)) <= 40 and
			int(best.get("food_coverage_q16", 0)) >= 85197)
		_expect("one fewer producer cannot pass the safety floor",
			Planner._evaluate_counts(candidates,
				PackedInt32Array([int(scenario[1]) - 1]), context).is_empty())
	map = null


func _test_hard_input_closure() -> void:
	var food = _food_profile()
	food.input_good_ids = PackedStringArray(["flint"])
	food.input_quantities_per_day = PackedInt64Array([100])
	food.input_required_q16 = PackedInt32Array([65536])
	var upstream = Building.new()
	upstream.id = &"synthetic_flint"
	upstream.output_good_ids = PackedStringArray(["flint"])
	upstream.output_quantities_per_day = PackedInt64Array([300])
	var candidates: Array[Dictionary] = [_candidate(food), _candidate(upstream)]
	var map := _map()
	var context: Dictionary = Planner._compile_search_context(
		candidates, map, 0, _route(), 98304)
	_expect("higher output cannot bypass missing hard input",
		Planner._evaluate_counts(candidates, PackedInt32Array([4, 0]), context).is_empty())
	_expect("hard input closure succeeds with enough upstream physical supply",
		not Planner._evaluate_counts(candidates, PackedInt32Array([4, 1]), context).is_empty())
	_expect("global output efficiency does not multiply input consumption",
		int(candidates[0].inputs.get("flint", 0)) == 100)
	map = null


func _test_soft_inputs_do_not_discount_extraction() -> void:
	var profile = _food_profile()
	profile.resource_ids = PackedStringArray(["gold_ore"])
	profile.resource_quantities_per_day = PackedInt64Array([1000])
	profile.resource_interaction_modes = PackedStringArray(["extract"])
	var map := _map()
	for resource in Registry.ordered():
		if String(resource.id) == "gold_ore":
			map.set(Registry.reserve_map_field(resource), PackedFloat32Array([5.5 * 365]))
	var candidates: Array[Dictionary] = [_candidate(profile)]
	var context: Dictionary = Planner._compile_search_context(
		candidates, map, 0, _route(), 65536)
	_expect("missing optional tools do not halve natural-resource use",
		is_equal_approx(float(candidates[0].resources.get("extract|gold_ore", 0.0)), 1.0))
	_expect("six producers exceed the finite reserve's 5.5-unit daily runway budget",
		Planner._evaluate_counts(candidates, PackedInt32Array([6]), context).is_empty())
	var faster: Array[Dictionary] = [_candidate(profile)]
	var faster_context: Dictionary = Planner._compile_search_context(
		faster, map, 0, _route(), 98304)
	_expect("higher output closes food with four producers within the same reserve",
		not Planner._evaluate_counts(faster, PackedInt32Array([4]), faster_context).is_empty())
	_expect("output multiplier never increases the resource budget",
		float(context.resource_limits.get("extract|gold_ore", 0.0)) ==
		float(faster_context.resource_limits.get("extract|gold_ore", -1.0)))
	map = null


func _food_profile():
	var profile = Building.new()
	profile.id = &"synthetic_food"
	profile.output_good_ids = PackedStringArray(["gathered_plants"])
	profile.output_quantities_per_day = PackedInt64Array([4000])
	profile.input_good_ids = PackedStringArray(["tools"])
	profile.input_quantities_per_day = PackedInt64Array([100])
	profile.input_required_q16 = PackedInt32Array([32768])
	return profile


func _test_opening_cash_preserves_food_bridge() -> void:
	var signatures := PackedInt32Array()
	var cells := PackedInt32Array()
	var populations := PackedInt64Array()
	var funds := PackedInt64Array()
	Bootstrap._append_population_row(signatures, cells, populations, funds, 0, 1, 7)
	Bootstrap._append_population_row(signatures, cells, populations, funds, 0, 2, 33)
	_expect("forty founders receive exactly 2400 currency, independent of professions",
		funds.size() == 2 and funds[0] == 7 * 60 * 10000 and
		funds[1] == 33 * 60 * 10000 and funds[0] + funds[1] == 2400 * 10000)
	_expect("lower cash grant preserves the fifteen-day physical food bridge",
		Bootstrap.STARTER_POPULATION == 40 and Bootstrap.SURVIVAL_DAYS == 15 and
		Bootstrap.LOCAL_INPUT_BUFFER_DAYS == 3)


func _candidate(profile) -> Dictionary:
	return {"id": String(profile.id), "profile": profile, "owner_slots": 1,
		"employee_slots": 0, "min_count": 1, "max_count": 40,
		"climate_q16": Q16}


func _route() -> Dictionary:
	return {"starter_food_good_ids": PackedStringArray(["gathered_plants"])}


func _map() -> MapData:
	var map := MapData.new(1, 1)
	map.set_cell(HexCell.new(0, 0))
	map._build_indices()
	map.temp_arr = PackedFloat32Array([0.5])
	return map


func _expect(label: String, passed: bool) -> void:
	_checks += 1
	if not passed:
		_failures += 1
		push_error(label)
