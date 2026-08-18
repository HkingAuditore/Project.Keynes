extends SceneTree

const StartProfile = preload("res://scripts/game/start_location_profile.gd")

var _failures := PackedStringArray()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile: ClimateProfile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var config := NewGameConfig.new()
	config.country.name = "Runtime Test Nation"
	config.country.foreign_count = 5
	config.base.map_width = 60
	config.base.map_height = 40
	config.base.initial_seed = 20260727
	config.base.num_continents = 2
	config.base.continent_size = 0.9
	config.base.sea_level = 0.42
	config.base.river_count = 8
	_expect("new-game config is valid", bool(config.validate().get("ok", false)))

	var map_config := MapConfig.make(60, 40)
	map_config.seed = 20260727
	map_config.num_continents = 2
	map_config.continent_size = 0.9
	map_config.sea_level = 0.42
	map_config.river_count = 8
	map_config.climate_profile = profile
	var clock := WorldClock.new()
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_world_clock_ref(clock)
	generator.set_gameplay_start_config(config.to_dictionary())
	var generated: Dictionary = await generator.generate(map_config, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("formal world generated", map != null)
	if map == null:
		_finish()
		return

	var start: Dictionary = generator.gameplay_start_report()
	_expect("formal start bootstrap succeeded", bool(start.get("ok", false)))
	var cell_idx := int(start.get("cell", -1))
	var country_starts: Array = start.get("country_starts", [])
	_expect("requested foreign countries generated",
		int(start.get("foreign_count", -1)) == 5 and country_starts.size() == 6)
	_expect("start cell is in range", cell_idx >= 0 and cell_idx < map.cell_count())
	if cell_idx >= 0 and cell_idx < map.cell_count():
		_expect("start cell is passable land",
			map.is_water_arr[cell_idx] == 0
			and TerrainType.is_passable_land(int(map.terrain_arr[cell_idx])))
	var represented_routes := {}
	for start_value in country_starts:
		var country_start: Dictionary = start_value
		var route := String(country_start.get("regional_route", ""))
		represented_routes[route] = true
		_expect("regional starter route is classified", route in ["coastal", "floodplain",
			"cold_highland", "tropical_forest", "arid_highland", "temperate"])
		var technologies: PackedStringArray = country_start.get(
			"starter_technology_ids", PackedStringArray())
		var route_buildings: PackedStringArray = country_start.get(
			"starter_building_ids", PackedStringArray())
		var pending_tech := String(country_start.get("pending_knowledge_tech_id", ""))
		var pending_building := String(country_start.get(
			"pending_knowledge_building_id", ""))
		var discovered: PackedStringArray = country_start.get(
			"starter_discovered_technology_ids", PackedStringArray())
		_expect("regional route grants the survival-core starter technologies",
			technologies.size() >= 5 and technologies.size() <= 7
			and technologies.has("tech.gathering")
			and technologies.has("tech.hunting")
			and technologies.has("tech.early_trade")
			and technologies.has("tech.deadwood_collection")
			and not technologies.has("tech.oral_memory_practice")
			and not technologies.has(pending_tech))
		_expect("regional route prebuilds the survival-core buildings",
			route_buildings.size() >= 5 and route_buildings.size() <= 8
			and route_buildings.has("gathering_ground")
			and route_buildings.has("deadwood_gathering_camp")
			and not route_buildings.has("oral_memory_circle")
			and not route_buildings.has(pending_building)
			and route_buildings.has("early_merchant_post"))
		_expect("regional route reveals one pending knowledge practice",
			not pending_tech.is_empty()
			and not pending_building.is_empty()
			and discovered.has(pending_tech)
			and int(country_start.get("starter_treasury_quantity", 0)) == 10000000
			and not (country_start.get("pending_knowledge_construction_good_ids",
				PackedStringArray()) as PackedStringArray).is_empty())
		_expect("regional route declares food, knowledge, precious metal and trade",
			not (country_start.get("starter_food_good_ids", PackedStringArray()) as
				PackedStringArray).is_empty()
			and String(country_start.get("starter_clothing_good_id", "")) == "clothing"
			and String(country_start.get("starter_construction_good_id", "")) == "logs"
			and String(country_start.get("starter_knowledge_good_id", "")) ==
				"technology_points"
			and String(country_start.get("starter_precious_good_id", "")) in
				["gold", "silver"]
			and technologies.has("tech.early_trade")
			and route_buildings.has("early_merchant_post"))
		var construction_offsets: PackedInt32Array = country_start.get(
			"starter_construction_group_offsets", PackedInt32Array())
		var construction_candidates: PackedStringArray = country_start.get(
			"starter_construction_candidate_good_ids", PackedStringArray())
		var construction_efficiencies: PackedInt32Array = country_start.get(
			"starter_construction_candidate_efficiency_q16", PackedInt32Array())
		var selected_materials: PackedStringArray = country_start.get(
			"starter_construction_selected_good_ids", PackedStringArray())
		var selected_quantities: PackedInt64Array = country_start.get(
			"starter_construction_selected_quantities", PackedInt64Array())
		_expect("regional route compiles complete grouped construction materials",
			String(country_start.get("starter_construction_seed_building_id", "")) ==
				String(country_start.get("primary_food_building_id", ""))
			and construction_offsets.size() >= 2
			and int(construction_offsets[0]) == 0
			and int(construction_offsets[construction_offsets.size() - 1]) ==
				construction_candidates.size()
			and construction_candidates.size() == construction_efficiencies.size()
			and not selected_materials.is_empty()
			and selected_materials.size() == selected_quantities.size())
		_expect("starter buildings close food, knowledge and precious output",
			_starter_route_outputs(country_start))
		_expect("opening top-up only raises missing reserves to profile minimums",
			_topups_are_minimum_fills(country_start, map, int(country_start.get("cell", -1))))
		for resource_id in country_start.get("starter_food_resource_ids", PackedStringArray()):
			_expect("selected food resource %s exists locally" % resource_id,
				not String(resource_id).is_empty() and _resource_reserve(
					map, String(resource_id), int(country_start.get("cell", -1))) > 0.0)
		for resource_id in [String(country_start.get("starter_construction_resource_id", "")),
				String(country_start.get("precious_resource", ""))]:
			_expect("selected route resource %s exists locally" % resource_id,
				not resource_id.is_empty() and _resource_reserve(
					map, resource_id, int(country_start.get("cell", -1))) > 0.0)
		var clothing_resource := String(country_start.get("starter_clothing_resource_id", ""))
		if not clothing_resource.is_empty():
			_expect("selected clothing resource %s exists locally" % clothing_resource,
				_resource_reserve(map, clothing_resource,
					int(country_start.get("cell", -1))) > 0.0
				and route_buildings.has("hide_scraping_shelter")
				and technologies.has("tech.hide_scraping"))
	_expect("one generated world demonstrates differentiated regional routes",
		represented_routes.size() >= 2)

	var country = generator.get_country_facade()
	_expect("country facade is configured", country != null and country.is_configured())
	if country != null:
		var owned := 0
		var owned_cells := {}
		for index in range(map.cell_count()):
			var summary: Dictionary = country.cell_summary(index)
			if int(summary.get("country_slot", -1)) >= 0:
				owned += 1
				owned_cells[index] = true
		_expect("every country owns exactly one cell", owned == country_starts.size())
		for start_value in country_starts:
			var country_start: Dictionary = start_value
			var country_cell := int(country_start.get("cell", -1))
			_expect("country start is owned", owned_cells.has(country_cell))
			var summary: Dictionary = country.cell_summary(country_cell)
			var snapshot: Dictionary = country.snapshot(
				int(summary.get("country_handle", -1)))
			_expect("stable country id is preserved",
				String(snapshot.get("country_id", "")) ==
					String(country_start.get("country_id", "")))
			_expect("country has one-cell territory",
				(snapshot.get("territory_cells", PackedInt32Array())
					as PackedInt32Array).size() == 1)
			var completed_ids: PackedStringArray = snapshot.get(
				"technology_ids", PackedStringArray())
			var starter_ids: PackedStringArray = country_start.get(
				"starter_technology_ids", PackedStringArray())
			var has_route_technologies := true
			for technology_id in starter_ids:
				if not completed_ids.has(technology_id):
					has_route_technologies = false
					break
			_expect("country receives its regional starter technologies and closure",
				has_route_technologies and completed_ids.size() >= starter_ids.size())
			var pending_tech := String(country_start.get("pending_knowledge_tech_id", ""))
			var research: Dictionary = country.research_snapshot(
				int(summary.get("country_handle", -1)))
			var catalog_ids: PackedStringArray = country.native_catalog().get(
				"technology_ids", PackedStringArray())
			var pending_index := catalog_ids.find(pending_tech)
			_expect("country treasury seeds opening technology points",
				int(research.get("technology_points_stock", 0)) == 10000000)
			_expect("country discovers the pending knowledge practice without completing it",
				pending_index >= 0
				and int((research.get("technology_states", PackedInt32Array()) as
					PackedInt32Array)[pending_index]) == 2
				and not completed_ids.has(pending_tech))
		var start_summary: Dictionary = country.cell_summary(cell_idx)
		var player: Dictionary = country.snapshot(int(start_summary.get("country_handle", -1)))
		_expect("stable player country id is preserved",
			String(player.get("country_id", "")) == "country.player")
		var minimum_distance := int(start.get("minimum_country_distance", 0))
		_expect("country distance uses the reduced map-scale requirement",
			minimum_distance == StartLocationPolicy.minimum_country_distance(60, 40)
			and minimum_distance == 6)
		for left in range(country_starts.size()):
			for right in range(left + 1, country_starts.size()):
				var distance := _land_distance(map,
					int((country_starts[left] as Dictionary).cell),
					int((country_starts[right] as Dictionary).cell))
				_expect("country starts respect minimum distance",
					distance >= minimum_distance)

	var economy = generator.get_economy_facade()
	_expect("economy facade is configured", economy != null and economy.is_configured())
	if economy != null and cell_idx >= 0:
		for start_value in country_starts:
			var country_start: Dictionary = start_value
			var settlement_cell := int(country_start.get("cell", -1))
			var precious := String(country_start.get("precious_resource", ""))
			var population: Dictionary = economy.population_cell_snapshot(settlement_cell)
			_expect("starter population is exactly 20",
				int(population.get("population", 0)) == 20)
			_expect("starter leaves non-founder population for native job matching",
				_profession_population(population, "unemployed") > 0
				and _sum_i64(population.get("owner_employed_by_cohort",
					PackedInt64Array())) > 0
				and _sum_i64(population.get("owner_employed_by_cohort",
					PackedInt64Array())) < 20
				and _sum_i64(population.get("employee_employed_by_cohort",
					PackedInt64Array())) == 0)
			var market: Dictionary = economy.market_cell_snapshot(settlement_cell)
			var food_goods: PackedStringArray = country_start.get(
				"starter_food_good_ids", PackedStringArray())
			var food_bridge_present := not food_goods.is_empty()
			for food_good in food_goods:
				food_bridge_present = food_bridge_present and _market_stock(
					market, String(food_good)) > 0
			_expect("starter receives a fifteen-day local-food bridge",
				food_bridge_present and _market_stock(market, "processed_food") == 0)
			var selected_materials: PackedStringArray = country_start.get(
				"starter_construction_selected_good_ids", PackedStringArray())
			var selected_quantities: PackedInt64Array = country_start.get(
				"starter_construction_selected_quantities", PackedInt64Array())
			var complete_material_seed := not selected_materials.is_empty() and \
				selected_materials.size() == selected_quantities.size()
			for material_index in range(selected_materials.size()):
				var expected_stock := maxi(60000,
					int(selected_quantities[material_index]) * 4)
				complete_material_seed = complete_material_seed and _market_stock(
					market, String(selected_materials[material_index])) >= expected_stock
			_expect("starter stocks every selected construction group material",
				complete_material_seed)
			var pending_goods: PackedStringArray = country_start.get(
				"pending_knowledge_construction_good_ids", PackedStringArray())
			var pending_quantities: PackedInt64Array = country_start.get(
				"pending_knowledge_construction_quantities", PackedInt64Array())
			var knowledge_materials_present := not pending_goods.is_empty() \
				and pending_goods.size() == pending_quantities.size()
			for pending_index in range(pending_goods.size()):
				knowledge_materials_present = knowledge_materials_present \
					and _market_stock(market, String(pending_goods[pending_index])) \
						>= int(pending_quantities[pending_index])
			_expect("starter stocks pending knowledge-shed construction materials",
				knowledge_materials_present)
			_expect("starter capital has a deterministic settlement name",
				bool(population.get("settlement_name_active", false)) and
				bool(population.get("settlement_name_forced", false)) and
				not String(population.get("settlement_name", "")).is_empty())
			var buildings: Dictionary = economy.building_cell_snapshot(settlement_cell)
			var route_buildings: PackedStringArray = country_start.get(
				"starter_building_ids", PackedStringArray())
			var route_counts: PackedInt64Array = country_start.get(
				"starter_building_counts", PackedInt64Array())
			_expect("starter contains exactly its regional weak buildings", _sum_i64(
				buildings.get("building_counts_by_type", PackedInt64Array())) ==
				_sum_i64(route_counts))
			for building_index in range(route_buildings.size()):
				var building_id := String(route_buildings[building_index])
				_expect("starter building %s exists" % building_id,
					_building_count(buildings, building_id) == int(route_counts[building_index]))
			_expect("starter food lots operate without leftover construction techs",
				_food_lots_operable(buildings, route_buildings))
			_expect("starter route keeps self-operated jobs within the 20-person cap",
				int(country_start.get("starter_job_capacity", 0)) > 0
				and int(country_start.get("starter_job_capacity", 0)) <= 20)
			_expect("starter route confines employee slots to precious workings",
				int(country_start.get("starter_employee_job_capacity", 0)) ==
					_precious_employee_slots(String(country_start.get(
						"precious_resource", ""))))
			_expect("starter route does not preallocate professions",
				not country_start.has("owner_job_capacity_by_profession"))
			_expect("starter excludes estates, mature mines and factories",
				_not_mature_start(route_buildings))
			var families: Dictionary = economy.family_cell_snapshot(
				settlement_cell, 0, 64)
			var family_handles: PackedInt64Array = families.get(
				"family_handles", PackedInt64Array())
			_expect("starter capital has exactly one founder family",
				bool(families.get("ok", false)) and family_handles.size() == 1)
			if family_handles.size() == 1:
				var family_handle := int(family_handles[0])
				var family: Dictionary = economy.family_snapshot(family_handle)
				var industries: Dictionary = economy.family_industries(
					family_handle, 0, 64)
				var founder_building := String(route_buildings[0])
				_expect("founder family is attached to the first regional producer",
					int(family.get("population", 0)) >= 1
					and int(family.get("population", 0)) <= 2
					and int(family.get("owned_buildings", 0)) == 1
					and (industries.get("building_type_stable_ids",
						PackedStringArray()) as PackedStringArray).has(
						founder_building))
				var people: Dictionary = economy.family_notable_people(
					family_handle, 0, 64)
				var person_handles: PackedInt64Array = people.get(
					"person_handles", PackedInt64Array())
				_expect("founder family has exactly one notable founder",
					person_handles.size() == 1)
				if person_handles.size() == 1:
					var person: Dictionary = economy.notable_person_snapshot(
						int(person_handles[0]))
					_expect("notable founder traces to the regional producer owner job",
						bool(person.get("ok", false))
						and not String(person.get("full_name", "")).is_empty()
						and not String(person.get("profession_stable_id", "")).is_empty()
						and String(person.get("building_type_stable_id", "")) ==
							founder_building
						and int(person.get("job_kind", 0)) == 1
						and int(person.get("building_handle", 0)) != 0)
	_expect("all settlements contribute population",
		int(start.get("total_population", 0)) == country_starts.size() * 20)
	_expect("all capitals receive one founder family and notable person",
		int(start.get("founder_family_count", 0)) == country_starts.size()
		and int(start.get("founder_person_count", 0)) == country_starts.size())
	_expect("production bootstrap source is used",
		String(start.get("settlement_source", "")) == "starter_settlement_bootstrap_v9")
	_finish()


func _topups_are_minimum_fills(country_start: Dictionary, map: MapData,
		cell_idx: int) -> bool:
	var topups: Dictionary = country_start.get("resource_topups", {})
	for resource_id in topups:
		if float(topups[resource_id]) <= 0.0:
			return false
		var current := _resource_reserve(map, String(resource_id), cell_idx)
		var minimum := float(StartProfile.MINIMUM_RESERVES.get(String(resource_id), 0.0))
		if current + 0.0001 < minimum:
			return false
	return true


func _precious_employee_slots(precious_resource: String) -> int:
	if precious_resource == "gold_ore":
		return 1
	if precious_resource == "silver_ore":
		return 2
	return 0


func _resource_reserve(map: MapData, resource_id: String, cell_idx: int) -> float:
	ResourceProfileRegistry.ensure_loaded()
	for resource in ResourceProfileRegistry.ordered():
		if resource != null and String(resource.id) == resource_id:
			var values = map.get(ResourceProfileRegistry.reserve_map_field(resource))
			return float(values[cell_idx])
	return 0.0


func _land_distance(map: MapData, source: int, target: int) -> int:
	var distances := PackedInt32Array()
	distances.resize(map.cell_count())
	distances.fill(-1)
	var queue := PackedInt32Array()
	queue.resize(map.cell_count())
	var head := 0
	var tail := 1
	queue[0] = source
	distances[source] = 0
	var neighbors := map.neighbor_indices_packed()
	while head < tail:
		var cell := int(queue[head])
		head += 1
		if cell == target:
			return int(distances[cell])
		for direction in range(6):
			var neighbor := int(neighbors[cell * 6 + direction])
			if neighbor < 0 or distances[neighbor] >= 0 \
					or map.is_water_arr[neighbor] != 0 \
					or not TerrainType.is_passable_land(int(map.terrain_arr[neighbor])):
				continue
			distances[neighbor] = int(distances[cell]) + 1
			queue[tail] = neighbor
			tail += 1
	return 0x3fffffff


func _building_count(snapshot: Dictionary, building_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var counts: PackedInt64Array = snapshot.get("building_counts_by_type", PackedInt64Array())
	var index := ids.find(building_id)
	return int(counts[index]) if index >= 0 and index < counts.size() else 0


func _food_lots_operable(snapshot: Dictionary, route_buildings: PackedStringArray) -> bool:
	if not route_buildings.has("gathering_ground"):
		return false
	for building_id in ["gathering_ground", "stone_age_hunting_camp"]:
		if route_buildings.has(building_id) and not _building_staffed_and_available(
				snapshot, building_id):
			return false
	return true


func _building_staffed_and_available(snapshot: Dictionary, building_id: String) -> bool:
	var ids: PackedStringArray = snapshot.get("building_type_ids", PackedStringArray())
	var available = snapshot.get("building_technology_available", PackedByteArray())
	var type_index := ids.find(building_id)
	if type_index < 0 or type_index >= available.size() or int(available[type_index]) == 0:
		return false
	var group_types: PackedInt32Array = snapshot.get("group_type_ids", PackedInt32Array())
	var filled: PackedInt64Array = snapshot.get("filled_owner", PackedInt64Array())
	var fill := 0
	for group in range(mini(group_types.size(), filled.size())):
		if int(group_types[group]) == type_index:
			fill += int(filled[group])
	return fill > 0


func _market_stock(snapshot: Dictionary, good_id: String) -> int:
	var ids: PackedStringArray = snapshot.get("good_ids", PackedStringArray())
	var stock: PackedInt64Array = snapshot.get("stock", PackedInt64Array())
	var index := ids.find(good_id)
	return int(stock[index]) if index >= 0 and index < stock.size() else 0


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _profession_population(snapshot: Dictionary, stable_id: String) -> int:
	var catalog_ids: PackedStringArray = snapshot.get(
		"profession_stable_ids", PackedStringArray())
	var row_professions: PackedInt32Array = snapshot.get(
		"profession_ids", PackedInt32Array())
	var row_populations: PackedInt64Array = snapshot.get(
		"populations", PackedInt64Array())
	var total := 0
	for row in range(mini(row_professions.size(), row_populations.size())):
		var profession := int(row_professions[row])
		if profession >= 0 and profession < catalog_ids.size() \
				and String(catalog_ids[profession]) == stable_id:
			total += int(row_populations[row])
	return total


func _starter_route_outputs(country_start: Dictionary) -> bool:
	var produced := {}
	var buildings: PackedStringArray = country_start.get(
		"starter_building_ids", PackedStringArray())
	for building_id in buildings:
		var profile: BuildingProfile = load(
			"res://data/economy/buildings/%s.tres" % building_id)
		if profile == null:
			return false
		for good_id in profile.output_good_ids:
			produced[String(good_id)] = true
	var food_goods: PackedStringArray = country_start.get(
		"starter_food_good_ids", PackedStringArray())
	if food_goods.is_empty():
		return false
	var physical_food_output := false
	for food_good in food_goods:
		physical_food_output = physical_food_output or produced.has(String(food_good))
	if not physical_food_output:
		return false
	var knowledge_building := String(country_start.get(
		"pending_knowledge_building_id", ""))
	if knowledge_building.is_empty():
		return false
	var knowledge_profile: BuildingProfile = load(
		"res://data/economy/buildings/%s.tres" % knowledge_building)
	if knowledge_profile == null or not knowledge_profile.output_good_ids.has(
			String(country_start.get("starter_knowledge_good_id", ""))):
		return false
	if not produced.has(String(country_start.get("starter_precious_good_id", ""))):
		return false
	if buildings.has("hide_scraping_shelter") \
			and not produced.has(String(country_start.get("starter_clothing_good_id", ""))):
		return false
	return true


func _not_mature_start(buildings: PackedStringArray) -> bool:
	for building_id in buildings:
		var stable_id := String(building_id)
		for forbidden in ["estate", "manor", "factory", "industrial", "deep_mine",
				"steam_mine", "plantation"]:
			if stable_id.contains(forbidden):
				return false
	return true


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures.append(label)


func _finish() -> void:
	print("gameplay start runtime: %d failures" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
