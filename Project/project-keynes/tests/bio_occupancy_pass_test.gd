extends SceneTree

# bio_occupancy_pass_test.gd
# 生物占领：主产地铺满生境、空生态位补齐、卫星岛跳过、大陆可玩底盘、信封门控、
# 已占领格气候余量持久化、农业引种绕过省界。
#
# Headless:
#   godot --headless --script tests/bio_occupancy_pass_test.gd --quit

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	print("=== bio occupancy pass test ===")
	_test_catalog_and_schema()
	_test_native_passes()
	print("=== bio occupancy pass summary: %d checks, %d failures ===" % [_checks, _failures])


func _test_catalog_and_schema() -> void:
	var occupancy: Dictionary = DCComponentSchema.find_by_name(&"cell.bio_occupancy_bits")
	var landmass: Dictionary = DCComponentSchema.find_by_name(&"cell.landmass_id")
	var province: Dictionary = DCComponentSchema.find_by_name(&"cell.province_id")
	_expect("schema has occupancy bits", not occupancy.is_empty())
	_expect("schema has landmass id", not landmass.is_empty())
	_expect("schema has province id", not province.is_empty())
	if not occupancy.is_empty():
		_expect("occupancy dtype I32", int(occupancy.get("dtype", -1)) == DCComponentIds.I32)
		_expect("occupancy map_field", String(occupancy.get("map_field", "")) == "bio_occupancy_bits_arr")
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	_expect("catalog compiles", bool(catalog.get("ok", false)))
	_expect("19 bio species", int(catalog.get("research_bio_species_count", 0)) == 19)
	var sheep_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.sheep")
	var maize_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.maize")
	_expect("sheep occupancy bit assigned", sheep_bit >= 0 and sheep_bit < 32)
	_expect("maize occupancy bit assigned", maize_bit >= 0 and maize_bit < 32)
	var carrier_ids: PackedStringArray = catalog.get("research_bio_carrier_ids", PackedStringArray())
	var bits: PackedInt32Array = catalog.get("research_bio_occupancy_bits", PackedInt32Array())
	var sheep_carrier := ""
	for i in range(mini(carrier_ids.size(), bits.size())):
		if int(bits[i]) == sheep_bit:
			sheep_carrier = String(carrier_ids[i])
			break
	_expect("sheep carrier is pasture", sheep_carrier == "pasture")
	var intro_goods: PackedStringArray = catalog.get("research_bio_introduce_good_ids", PackedStringArray())
	_expect("corn_grain introduces maize", intro_goods.has("corn_grain"))
	var rubber_carrier := ""
	var rubber_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.rubber")
	for i in range(mini(carrier_ids.size(), bits.size())):
		if int(bits[i]) == rubber_bit:
			rubber_carrier = String(carrier_ids[i])
			break
	_expect("rubber carrier is plantation_land only", rubber_carrier == "plantation_land")
	var policies: PackedInt32Array = catalog.get("research_bio_origin_policy", PackedInt32Array())
	var guilds: PackedInt32Array = catalog.get("research_bio_guild", PackedInt32Array())
	var reed_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.reed")
	var wheat_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.wheat")
	var reed_policy := -1
	var wheat_guild := -1
	for i in range(mini(policies.size(), bits.size())):
		if int(bits[i]) == reed_bit:
			reed_policy = int(policies[i])
		if int(bits[i]) == wheat_bit and i < guilds.size():
			wheat_guild = int(guilds[i])
	_expect("reed is cosmopolitan", reed_policy == ResearchSignalCatalog.OCCUPANCY_ORIGIN_COSMOPOLITAN)
	_expect("wheat guild is food", wheat_guild == ResearchSignalCatalog.OCCUPANCY_GUILD_FOOD)
	var habitats: PackedInt32Array = catalog.get("research_bio_habitat_class", PackedInt32Array())
	_expect("habitat class compiled", habitats.size() == bits.size() and habitats.size() == 19)
	var wheat_habitat := -1
	var pig_habitat := -1
	var pig_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.pig")
	for i in range(mini(habitats.size(), bits.size())):
		if int(bits[i]) == wheat_bit:
			wheat_habitat = int(habitats[i])
		if int(bits[i]) == pig_bit:
			pig_habitat = int(habitats[i])
	_expect("wheat habitat is open_food", wheat_habitat == ResearchSignalCatalog.OCCUPANCY_HABITAT_OPEN_FOOD)
	_expect("pig habitat is forest_grazer", pig_habitat == ResearchSignalCatalog.OCCUPANCY_HABITAT_FOREST_GRAZER)


func _test_native_passes() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_skip("DCWorldExt class not found")
		return
	var ext := DCWorldExt.new()
	if not ext.has_method("run_bio_province_pass") \
			or not ext.has_method("run_bio_seed_pass") \
			or not ext.has_method("run_bio_occupancy_pass"):
		_skip("bio occupancy passes not exported")
		return
	var landform_csr := _test_landform_csr_excludes_bio(ext)
	if not landform_csr:
		return
	_test_landmass_isolation_and_gaps(ext)
	_test_origin_picks_largest_envelope(ext)
	_test_origin_hearth_is_compact(ext)
	_test_forest_grazer_niche(ext)
	_test_cold_and_dry_endemic_envelopes(ext)
	_test_three_continent_food_floor(ext)
	_test_occupancy_persistence_and_introduce(ext)


func _test_landform_csr_excludes_bio(ext) -> bool:
	var map := _make_two_continent_map()
	var catalog: Dictionary = TechnologyCatalog.compile_native_catalog()
	var ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var dense := PackedInt32Array()
	for key in [
		"landform.freshwater_access", "landform.river_valley", "landform.volcanic",
		"landform.high_plateau", "landform.coastal_estuary", "landform.coast",
		"landform.arid_basin", "landform.marsh", "landform.forest",
		"landform.grassland", "landform.mountain",
		"landform.delta", "landform.floodplain", "landform.monsoon_basin",
		"landform.loess_plain", "landform.steppe_plain", "landform.tundra",
		"landform.conifer_forest", "landform.oasis", "landform.steep_slope",
		"landform.stable_wind_corridor",
	]:
		dense.append(ids.find(key))
	var result: Dictionary = ext.run_research_signal_generation_pass({
		"width": map.width,
		"height": map.height,
		"seed": 7,
		"generation_vegetation": map.vegetation_arr,
		"landform": map.landform_arr,
		"has_river": map.has_river_arr,
		"has_volcano": map.has_volcano_arr,
		"is_water": map.is_water_arr,
		"temperature": map.temp_arr,
		"moisture": map.moisture_arr,
		"elevation": map.elevation_arr,
		"signal_ids": dense,
	})
	_expect("landform CSR ok", bool(result.get("ok", false)))
	if not bool(result.get("ok", false)):
		return false
	var signal_ids: PackedInt32Array = result.get("cell_signal_ids", PackedInt32Array())
	var maize := ids.find("bio.maize")
	var sheep := ids.find("bio.sheep")
	var leaked := false
	for sid in signal_ids:
		if int(sid) == maize or int(sid) == sheep:
			leaked = true
			break
	_expect("static CSR no longer stamps bio occupancy", not leaked)
	return true


func _test_landmass_isolation_and_gaps(ext) -> void:
	var map := _make_two_continent_map()
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] == 0:
			map.has_river_arr[cell] = 1
	var knobs := _species_knobs(map, PackedStringArray(["bio.maize", "bio.wheat", "bio.reed"]))
	knobs["width"] = map.width
	knobs["height"] = map.height
	var province_res: Dictionary = ext.run_bio_province_pass(knobs)
	_expect("province pass ok", bool(province_res.get("ok", false)))
	if not bool(province_res.get("ok", false)):
		return
	var landmass: PackedInt32Array = province_res.get("landmass_ids", PackedInt32Array())
	var provinces: PackedInt32Array = province_res.get("province_ids", PackedInt32Array())
	var land_a := PackedInt32Array()
	var land_b := PackedInt32Array()
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		if off.x <= 3:
			land_a.append(cell)
		else:
			land_b.append(cell)
	_expect("two landmass ids", int(province_res.get("landmass_count", 0)) >= 2)
	if land_a.is_empty() or land_b.is_empty():
		_expect("split continents populated", false)
		return
	_expect("continents are distinct landmasses",
		int(landmass[land_a[0]]) != int(landmass[land_b[0]]) \
		and int(landmass[land_a[0]]) > 0 and int(landmass[land_b[0]]) > 0)
	knobs["province_ids"] = provinces
	knobs["landmass_ids"] = landmass
	knobs["seed"] = 42
	var seed_res: Dictionary = ext.run_bio_seed_pass(knobs)
	_expect("seed pass ok", bool(seed_res.get("ok", false)))
	if not bool(seed_res.get("ok", false)):
		return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var maize_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.maize")
	var wheat_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.wheat")
	var reed_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.reed")
	var maize_a := 0
	var maize_b := 0
	var wheat_a := 0
	var wheat_b := 0
	var reed_a := 0
	var reed_b := 0
	var empty_a := 0
	var empty_b := 0
	var food_overlap := 0
	for cell in land_a:
		var bits := int(occupancy[cell])
		if (bits & (1 << maize_bit)) != 0:
			maize_a += 1
		if (bits & (1 << wheat_bit)) != 0:
			wheat_a += 1
		if (bits & (1 << reed_bit)) != 0:
			reed_a += 1
		if (bits & (1 << maize_bit)) != 0 and (bits & (1 << wheat_bit)) != 0:
			food_overlap += 1
		if bits == 0:
			empty_a += 1
	for cell in land_b:
		var bits := int(occupancy[cell])
		if (bits & (1 << maize_bit)) != 0:
			maize_b += 1
		if (bits & (1 << wheat_bit)) != 0:
			wheat_b += 1
		if (bits & (1 << reed_bit)) != 0:
			reed_b += 1
		if (bits & (1 << maize_bit)) != 0 and (bits & (1 << wheat_bit)) != 0:
			food_overlap += 1
		if bits == 0:
			empty_b += 1
	var food_a := maize_a + wheat_a
	var food_b := maize_b + wheat_b
	_expect("each continent-scale landmass has food occupancy", food_a > 0 and food_b > 0)
	_expect("maize primary hearth is on one landmass", (maize_a > 0) != (maize_b > 0))
	_expect("wheat primary hearth is on one landmass", (wheat_a > 0) != (wheat_b > 0))
	_expect("temperate food hearths do not stack on the same cell", food_overlap == 0)
	_expect("reeds can occupy multiple continent-scale landmasses", reed_a > 0 and reed_b > 0)
	var seeded: PackedInt32Array = seed_res.get("seeded_landmass_counts", PackedInt32Array())
	var occ_bits: PackedInt32Array = knobs.get("species_occupancy_bits", PackedInt32Array())
	var maize_idx := occ_bits.find(maize_bit)
	var wheat_idx := occ_bits.find(wheat_bit)
	var reed_idx := occ_bits.find(reed_bit)
	if maize_idx >= 0 and maize_idx < seeded.size():
		_expect("maize reports a compact origin", int(seeded[maize_idx]) == 1)
	if wheat_idx >= 0 and wheat_idx < seeded.size():
		_expect("wheat reports a compact origin", int(seeded[wheat_idx]) == 1)
	if reed_idx >= 0 and reed_idx < seeded.size():
		_expect("reed reports cosmopolitan landmasses", int(seeded[reed_idx]) >= 2)
	var origin_env: PackedInt32Array = seed_res.get("origin_envelope_cell_counts", PackedInt32Array())
	var occupied_n: PackedInt32Array = seed_res.get("occupied_cell_counts", PackedInt32Array())
	if maize_idx >= 0 and maize_idx < origin_env.size() and maize_idx < occupied_n.size():
		_expect("maize fills most of its origin envelope",
			_fills_origin_envelope(int(occupied_n[maize_idx]), int(origin_env[maize_idx])))
	if wheat_idx >= 0 and wheat_idx < origin_env.size() and wheat_idx < occupied_n.size():
		_expect("wheat fills most of its origin envelope",
			_fills_origin_envelope(int(occupied_n[wheat_idx]), int(origin_env[wheat_idx])))
	var occupied_a := land_a.size() - empty_a
	var occupied_b := land_b.size() - empty_b
	_expect("continent cells are mostly occupied", occupied_a >= 4 and occupied_b >= 4)


func _test_origin_picks_largest_envelope(ext) -> void:
	var width := 18
	var height := 3
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map._alloc_soa(map.cell_count())
	for cell in range(map.cell_count()):
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		var water := off.x == 0 or (off.x >= 10 and off.x <= 15) or off.x == width - 1
		map.is_water_arr[cell] = 1 if water else 0
		map.terrain_arr[cell] = TerrainType.TERRAIN.OCEAN if water else TerrainType.TERRAIN.PLAIN
		map.landform_arr[cell] = LandformType.LF.OCEAN if water else LandformType.LF.PLAIN
		map.vegetation_arr[cell] = VegetationType.VEG.NONE if water else VegetationType.VEG.TEMPERATE_GRASSLAND
		map.temp_arr[cell] = 0.55
		map.moisture_arr[cell] = 0.55
		map.elevation_arr[cell] = 0.20
		map.has_river_arr[cell] = 0
		map.has_volcano_arr[cell] = 0
		map.res_arable_land_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_pasture_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_paddy_land_reserve_arr[cell] = 0.0
		map.res_plantation_land_reserve_arr[cell] = 0.0
		map.res_wild_game_reserve_arr[cell] = 0.0
		map.explored_arr[cell] = 0
	var knobs := _species_knobs(map, PackedStringArray(["bio.wheat"]))
	knobs["width"] = map.width
	knobs["height"] = map.height
	var province_res: Dictionary = ext.run_bio_province_pass(knobs)
	_expect("unequal-landmass province pass ok", bool(province_res.get("ok", false)))
	if not bool(province_res.get("ok", false)):
		return
	var landmass: PackedInt32Array = province_res.get("landmass_ids", PackedInt32Array())
	knobs["province_ids"] = province_res.get("province_ids", PackedInt32Array())
	knobs["landmass_ids"] = landmass
	knobs["seed"] = 99
	var seed_res: Dictionary = ext.run_bio_seed_pass(knobs)
	_expect("unequal-landmass seed pass ok", bool(seed_res.get("ok", false)))
	if not bool(seed_res.get("ok", false)):
		return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var wheat_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.wheat")
	var left_n := 0
	var right_n := 0
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		var hex: HexCell = map.cell_at(cell)
		var col := int(HexUtils.cube_to_offset(hex.q, hex.r).x)
		if (int(occupancy[cell]) & (1 << wheat_bit)) == 0:
			continue
		if col <= 9:
			left_n += 1
		else:
			right_n += 1
	_expect("wheat occupies the continent-scale landmass", left_n >= 6)
	_expect("satellite islet does not receive wheat", right_n == 0)
	var seeded: PackedInt32Array = seed_res.get("seeded_landmass_counts", PackedInt32Array())
	_expect("satellite seed reports one landmass", seeded.size() > 0 and int(seeded[0]) == 1)


func _test_origin_hearth_is_compact(ext) -> void:
	var width := 28
	var height := 3
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map._alloc_soa(map.cell_count())
	for cell in range(map.cell_count()):
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		var water := off.x == 0 or off.x == width - 1
		map.is_water_arr[cell] = 1 if water else 0
		map.terrain_arr[cell] = TerrainType.TERRAIN.OCEAN if water else TerrainType.TERRAIN.PLAIN
		map.landform_arr[cell] = LandformType.LF.OCEAN if water else LandformType.LF.PLAIN
		map.vegetation_arr[cell] = VegetationType.VEG.NONE if water else VegetationType.VEG.TEMPERATE_GRASSLAND
		map.temp_arr[cell] = 0.50
		map.moisture_arr[cell] = 0.50
		map.elevation_arr[cell] = 0.20
		map.has_river_arr[cell] = 1 if not water and off.y == 1 else 0
		map.has_volcano_arr[cell] = 0
		map.res_arable_land_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_pasture_reserve_arr[cell] = 0.0
		map.res_paddy_land_reserve_arr[cell] = 0.0
		map.res_plantation_land_reserve_arr[cell] = 0.0
		map.res_wild_game_reserve_arr[cell] = 0.0
		map.explored_arr[cell] = 0
	var knobs := _species_knobs(map, PackedStringArray(["bio.wheat", "bio.rice", "bio.reed"]))
	knobs["width"] = map.width
	knobs["height"] = map.height
	var province_res: Dictionary = ext.run_bio_province_pass(knobs)
	_expect("long-strip province pass ok", bool(province_res.get("ok", false)))
	if not bool(province_res.get("ok", false)):
		return
	knobs["province_ids"] = province_res.get("province_ids", PackedInt32Array())
	knobs["landmass_ids"] = province_res.get("landmass_ids", PackedInt32Array())
	knobs["seed"] = 7
	var seed_res: Dictionary = ext.run_bio_seed_pass(knobs)
	_expect("long-strip seed pass ok", bool(seed_res.get("ok", false)))
	if not bool(seed_res.get("ok", false)):
		return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var wheat_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.wheat")
	var rice_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.rice")
	var reed_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.reed")
	var wheat_cols := PackedInt32Array()
	var rice_count := 0
	var reed_count := 0
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		var hex: HexCell = map.cell_at(cell)
		var col := int(HexUtils.cube_to_offset(hex.q, hex.r).x)
		if (int(occupancy[cell]) & (1 << wheat_bit)) != 0:
			wheat_cols.append(col)
		if (int(occupancy[cell]) & (1 << rice_bit)) != 0:
			rice_count += 1
		if (int(occupancy[cell]) & (1 << reed_bit)) != 0:
			reed_count += 1
	_expect("wheat occupies a regional hearth", wheat_cols.size() >= 12)
	_expect("reeds occupy river cells without wetland vegetation", reed_count >= 8)
	_expect("rice occupies a river hearth", rice_count >= 3)
	var origin_env: PackedInt32Array = seed_res.get("origin_envelope_cell_counts", PackedInt32Array())
	var occupied_n: PackedInt32Array = seed_res.get("occupied_cell_counts", PackedInt32Array())
	var occ_bits: PackedInt32Array = knobs.get("species_occupancy_bits", PackedInt32Array())
	var wheat_idx := occ_bits.find(wheat_bit)
	if wheat_idx >= 0 and wheat_idx < origin_env.size() and wheat_idx < occupied_n.size():
		_expect("wheat fills most of the long-strip envelope",
			_fills_origin_envelope(int(occupied_n[wheat_idx]), int(origin_env[wheat_idx])))
	var food_overlap := 0
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		var bits := int(occupancy[cell])
		if (bits & (1 << wheat_bit)) != 0 and (bits & (1 << rice_bit)) != 0:
			food_overlap += 1
	_expect("wheat and rice hearths stay off the same cells", food_overlap == 0)


func _test_forest_grazer_niche(ext) -> void:
	var width := 14
	var height := 3
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map._alloc_soa(map.cell_count())
	for cell in range(map.cell_count()):
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		var water := off.x == 0 or off.x == width - 1
		map.is_water_arr[cell] = 1 if water else 0
		map.terrain_arr[cell] = TerrainType.TERRAIN.OCEAN if water else TerrainType.TERRAIN.FOREST
		map.landform_arr[cell] = LandformType.LF.OCEAN if water else LandformType.LF.HILL
		map.vegetation_arr[cell] = VegetationType.VEG.NONE if water else VegetationType.VEG.TEMPERATE_DECIDUOUS
		map.temp_arr[cell] = 0.50
		map.moisture_arr[cell] = 0.62
		map.elevation_arr[cell] = 0.28
		map.has_river_arr[cell] = 0
		map.has_volcano_arr[cell] = 0
		map.res_arable_land_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_pasture_reserve_arr[cell] = 0.0
		map.res_paddy_land_reserve_arr[cell] = 0.0
		map.res_plantation_land_reserve_arr[cell] = 0.0
		map.res_wild_game_reserve_arr[cell] = 0.0 if water else 40.0
		map.explored_arr[cell] = 0
	var knobs := _species_knobs(map, PackedStringArray(["bio.wheat", "bio.pig"]))
	knobs["width"] = map.width
	knobs["height"] = map.height
	var province_res: Dictionary = ext.run_bio_province_pass(knobs)
	_expect("forest-niche province pass ok", bool(province_res.get("ok", false)))
	if not bool(province_res.get("ok", false)):
		return
	knobs["province_ids"] = province_res.get("province_ids", PackedInt32Array())
	knobs["landmass_ids"] = province_res.get("landmass_ids", PackedInt32Array())
	knobs["seed"] = 19
	var seed_res: Dictionary = ext.run_bio_seed_pass(knobs)
	_expect("forest-niche seed pass ok", bool(seed_res.get("ok", false)))
	if not bool(seed_res.get("ok", false)):
		return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var pig_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.pig")
	var pig_n := 0
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		if (int(occupancy[cell]) & (1 << pig_bit)) != 0:
			pig_n += 1
	_expect("forest continent has forest_grazer", pig_n >= 8)
	var occ_bits: PackedInt32Array = knobs.get("species_occupancy_bits", PackedInt32Array())
	var origin_env: PackedInt32Array = seed_res.get("origin_envelope_cell_counts", PackedInt32Array())
	var occupied_n: PackedInt32Array = seed_res.get("occupied_cell_counts", PackedInt32Array())
	var pig_idx := occ_bits.find(pig_bit)
	if pig_idx >= 0 and pig_idx < origin_env.size() and pig_idx < occupied_n.size():
		_expect("pig fills forest habitat on its origin landmass",
			_fills_origin_envelope(int(occupied_n[pig_idx]), int(origin_env[pig_idx])))


func _test_cold_and_dry_endemic_envelopes(ext) -> void:
	var width := 24
	var height := 3
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map._alloc_soa(map.cell_count())
	for cell in range(map.cell_count()):
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		var water := off.x == 0 or off.x == width - 1
		map.is_water_arr[cell] = 1 if water else 0
		map.terrain_arr[cell] = TerrainType.TERRAIN.OCEAN if water else TerrainType.TERRAIN.PLAIN
		map.landform_arr[cell] = LandformType.LF.OCEAN if water else LandformType.LF.PLAIN
		map.has_river_arr[cell] = 0
		map.has_volcano_arr[cell] = 0
		map.res_arable_land_reserve_arr[cell] = 0.0
		map.res_pasture_reserve_arr[cell] = 0.0
		map.res_paddy_land_reserve_arr[cell] = 0.0
		map.res_plantation_land_reserve_arr[cell] = 0.0
		map.res_wild_game_reserve_arr[cell] = 0.0
		map.explored_arr[cell] = 0
		if water:
			map.vegetation_arr[cell] = VegetationType.VEG.NONE
			map.temp_arr[cell] = 0.50
			map.moisture_arr[cell] = 0.50
			map.elevation_arr[cell] = 0.0
			continue
		if off.x <= 8:
			map.vegetation_arr[cell] = VegetationType.VEG.DESERT_SCRUB
			map.temp_arr[cell] = 0.72
			map.moisture_arr[cell] = 0.18
			map.elevation_arr[cell] = 0.22
		elif off.x <= 15:
			map.vegetation_arr[cell] = VegetationType.VEG.TEMPERATE_GRASSLAND
			map.temp_arr[cell] = 0.40
			map.moisture_arr[cell] = 0.48
			map.elevation_arr[cell] = 0.48
			map.res_arable_land_reserve_arr[cell] = 80.0
		else:
			map.vegetation_arr[cell] = VegetationType.VEG.TUNDRA
			map.temp_arr[cell] = 0.18
			map.moisture_arr[cell] = 0.40
			map.elevation_arr[cell] = 0.52
	var knobs := _species_knobs(map, PackedStringArray(["bio.camel", "bio.potato", "bio.yak"]))
	knobs["width"] = map.width
	knobs["height"] = map.height
	var province_res: Dictionary = ext.run_bio_province_pass(knobs)
	_expect("endemic envelope province pass ok", bool(province_res.get("ok", false)))
	if not bool(province_res.get("ok", false)):
		return
	knobs["province_ids"] = province_res.get("province_ids", PackedInt32Array())
	knobs["landmass_ids"] = province_res.get("landmass_ids", PackedInt32Array())
	knobs["seed"] = 11
	var seed_res: Dictionary = ext.run_bio_seed_pass(knobs)
	_expect("endemic envelope seed pass ok", bool(seed_res.get("ok", false)))
	if not bool(seed_res.get("ok", false)):
		return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var camel_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.camel")
	var potato_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.potato")
	var yak_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.yak")
	var camel_n := 0
	var potato_n := 0
	var yak_n := 0
	var camel_spill := 0
	var potato_spill := 0
	var yak_spill := 0
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		var hex: HexCell = map.cell_at(cell)
		var col := int(HexUtils.cube_to_offset(hex.q, hex.r).x)
		var has_camel := (int(occupancy[cell]) & (1 << camel_bit)) != 0
		var has_potato := (int(occupancy[cell]) & (1 << potato_bit)) != 0
		var has_yak := (int(occupancy[cell]) & (1 << yak_bit)) != 0
		if has_camel:
			camel_n += 1
			if col > 8:
				camel_spill += 1
		if has_potato:
			potato_n += 1
			if col <= 8 or col > 15:
				potato_spill += 1
		if has_yak:
			yak_n += 1
			if col <= 15:
				yak_spill += 1
	_expect("camels stay in the dry belt", camel_n >= 4 and camel_spill == 0)
	_expect("potatoes stay in cool highlands", potato_n >= 4 and potato_spill == 0)
	_expect("yaks stay in cold highlands", yak_n >= 4 and yak_spill == 0)


func _test_three_continent_food_floor(ext) -> void:
	var width := 16
	var height := 3
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map._alloc_soa(map.cell_count())
	for cell in range(map.cell_count()):
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		var water := off.x == 0 or off.x == 5 or off.x == 10 or off.x == width - 1
		map.is_water_arr[cell] = 1 if water else 0
		map.terrain_arr[cell] = TerrainType.TERRAIN.OCEAN if water else TerrainType.TERRAIN.PLAIN
		map.landform_arr[cell] = LandformType.LF.OCEAN if water else LandformType.LF.PLAIN
		map.vegetation_arr[cell] = VegetationType.VEG.NONE if water else VegetationType.VEG.TEMPERATE_GRASSLAND
		map.temp_arr[cell] = 0.55
		map.moisture_arr[cell] = 0.55
		map.elevation_arr[cell] = 0.20
		map.has_river_arr[cell] = 1 if not water else 0
		map.has_volcano_arr[cell] = 0
		map.res_arable_land_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_pasture_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_paddy_land_reserve_arr[cell] = 0.0 if water else 40.0
		map.res_plantation_land_reserve_arr[cell] = 0.0
		map.res_wild_game_reserve_arr[cell] = 0.0
		map.explored_arr[cell] = 0
	var knobs := _species_knobs(map, PackedStringArray(["bio.maize", "bio.wheat", "bio.rice"]))
	knobs["width"] = map.width
	knobs["height"] = map.height
	var province_res: Dictionary = ext.run_bio_province_pass(knobs)
	_expect("three-continent province pass ok", bool(province_res.get("ok", false)))
	if not bool(province_res.get("ok", false)):
		return
	knobs["province_ids"] = province_res.get("province_ids", PackedInt32Array())
	knobs["landmass_ids"] = province_res.get("landmass_ids", PackedInt32Array())
	knobs["seed"] = 13
	var seed_res: Dictionary = ext.run_bio_seed_pass(knobs)
	_expect("three-continent seed pass ok", bool(seed_res.get("ok", false)))
	if not bool(seed_res.get("ok", false)):
		return
	var occupancy: PackedInt32Array = seed_res.get("occupancy_bits", PackedInt32Array())
	var landmass: PackedInt32Array = knobs["landmass_ids"]
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var food_mask := 0
	for food_id in [&"bio.maize", &"bio.wheat", &"bio.rice"]:
		var bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, food_id)
		if bit >= 0:
			food_mask |= 1 << bit
	var foods_by_land := {}
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] != 0:
			continue
		var lid := int(landmass[cell])
		if lid <= 0:
			continue
		if not foods_by_land.has(lid):
			foods_by_land[lid] = 0
		if (int(occupancy[cell]) & food_mask) != 0:
			foods_by_land[lid] = int(foods_by_land[lid]) + 1
	_expect("three continent-scale landmasses", foods_by_land.size() >= 3)
	var empty_continents := 0
	for lid in foods_by_land.keys():
		if int(foods_by_land[lid]) <= 0:
			empty_continents += 1
	_expect("every continent-scale landmass has food", empty_continents == 0)


func _test_occupancy_persistence_and_introduce(ext) -> void:
	var map := _make_two_continent_map()
	var knobs := _species_knobs(map, PackedStringArray(["bio.sheep", "bio.maize"]))
	var province_res: Dictionary = ext.run_bio_province_pass({
		"width": map.width,
		"height": map.height,
		"is_water": map.is_water_arr,
		"landform": map.landform_arr,
		"vegetation": map.vegetation_arr,
		"neighbor_indices": map.neighbor_indices_packed(),
	})
	if not bool(province_res.get("ok", false)):
		_expect("province for persistence test", false)
		return
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var sheep_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.sheep")
	var maize_bit := ResearchSignalCatalog.occupancy_bit_for_signal(catalog, &"bio.maize")
	_expect("sheep/maize occupancy bits in knobs",
		knobs.species_occupancy_bits.find(sheep_bit) >= 0 \
		and knobs.species_occupancy_bits.find(maize_bit) >= 0)
	var occupancy := PackedInt32Array()
	occupancy.resize(map.cell_count())
	var host := -1
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] == 0:
			host = cell
			occupancy[cell] = (1 << sheep_bit)
			break
	_expect("found land host cell", host >= 0)
	map.res_pasture_reserve_arr[host] = 0.0
	knobs["province_ids"] = province_res.get("province_ids", PackedInt32Array())
	knobs["occupancy_bits"] = occupancy
	knobs["carrier_reserves"] = _refresh_carrier_columns(map, knobs)
	knobs["run_diffusion"] = false
	knobs["explored"] = map.explored_arr
	var after_pasture: Dictionary = ext.run_bio_occupancy_pass(knobs)
	_expect("persistence pass ok", bool(after_pasture.get("ok", false)))
	var after: PackedInt32Array = after_pasture.get("occupancy_bits", PackedInt32Array())
	if host >= 0 and after.size() == occupancy.size():
		_expect("pasture zero does not instantly extinct established sheep",
			(int(after[host]) & (1 << sheep_bit)) != 0)
	_expect("carrier persistence does not emit discovery",
		PackedInt32Array(after_pasture.get("newly_occupied_cells", PackedInt32Array())).is_empty())

	map.vegetation_arr[host] = VegetationType.VEG.TROPICAL_RAINFOREST
	knobs["vegetation"] = map.vegetation_arr
	knobs["occupancy_bits"] = after if after.size() == occupancy.size() else occupancy
	var after_veg: Dictionary = ext.run_bio_occupancy_pass(knobs)
	after = after_veg.get("occupancy_bits", PackedInt32Array())
	if host >= 0 and after.size() == occupancy.size():
		_expect("vegetation succession does not extinct established sheep",
			(int(after[host]) & (1 << sheep_bit)) != 0)

	map.temp_arr[host] = 0.0
	knobs["temperature"] = map.temp_arr
	knobs["occupancy_bits"] = after if after.size() == occupancy.size() else occupancy
	var after_climate: Dictionary = ext.run_bio_occupancy_pass(knobs)
	after = after_climate.get("occupancy_bits", PackedInt32Array())
	if host >= 0 and after.size() == occupancy.size():
		_expect("hostile climate clears occupancy",
			(int(after[host]) & (1 << sheep_bit)) == 0)

	var intro_cell := -1
	for cell in range(map.cell_count()):
		if map.is_water_arr[cell] == 0 and cell != host:
			intro_cell = cell
			break
	var intro_cells := PackedInt32Array([intro_cell])
	var intro_bits := PackedInt32Array([maize_bit])
	knobs["occupancy_bits"] = after if after.size() == map.cell_count() else occupancy
	knobs["introduce_cells"] = intro_cells
	knobs["introduce_bits"] = intro_bits
	map.explored_arr[intro_cell] = 1
	knobs["explored"] = map.explored_arr
	var intro: Dictionary = ext.run_bio_occupancy_pass(knobs)
	_expect("introduce pass ok", bool(intro.get("ok", false)))
	var intro_occ: PackedInt32Array = intro.get("occupancy_bits", PackedInt32Array())
	if intro_cell >= 0 and intro_occ.size() == map.cell_count():
		_expect("local production introduces maize without province origin",
			(int(intro_occ[intro_cell]) & (1 << maize_bit)) != 0)
	var intro_new: PackedInt32Array = intro.get("newly_occupied_cells", PackedInt32Array())
	_expect("explored 0→1 occupancy is reported for DISCOVER",
		intro_new.find(intro_cell) >= 0)


func _make_two_continent_map() -> MapData:
	var width := 10
	var height := 3
	var map := MapData.new(width, height)
	for row in range(height):
		for col in range(width):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map._alloc_soa(map.cell_count())
	for cell in range(map.cell_count()):
		var hex: HexCell = map.cell_at(cell)
		var off := HexUtils.cube_to_offset(hex.q, hex.r)
		var water := off.x == 0 or off.x == 4 or off.x == 5 or off.x == 9
		map.is_water_arr[cell] = 1 if water else 0
		map.terrain_arr[cell] = TerrainType.TERRAIN.OCEAN if water else TerrainType.TERRAIN.PLAIN
		map.landform_arr[cell] = LandformType.LF.OCEAN if water else LandformType.LF.PLAIN
		map.vegetation_arr[cell] = VegetationType.VEG.NONE if water else VegetationType.VEG.TEMPERATE_GRASSLAND
		map.temp_arr[cell] = 0.55
		map.moisture_arr[cell] = 0.55
		map.elevation_arr[cell] = 0.20
		map.has_river_arr[cell] = 0
		map.has_volcano_arr[cell] = 0
		map.res_arable_land_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_pasture_reserve_arr[cell] = 0.0 if water else 80.0
		map.res_paddy_land_reserve_arr[cell] = 0.0
		map.res_plantation_land_reserve_arr[cell] = 0.0
		map.res_wild_game_reserve_arr[cell] = 0.0 if water else 40.0
		map.explored_arr[cell] = 0
	return map


func _species_knobs(map: MapData, species_ids: PackedStringArray) -> Dictionary:
	var catalog: Dictionary = ResearchSignalCatalog.compile_native_catalog()
	var all_ids: PackedStringArray = catalog.get("research_signal_ids", PackedStringArray())
	var bio_signal_ids: PackedInt32Array = catalog.get("research_bio_signal_ids", PackedInt32Array())
	var wanted := {}
	for species_id in species_ids:
		wanted[String(species_id)] = true
	var keep := PackedInt32Array()
	for i in range(bio_signal_ids.size()):
		var signal_index := int(bio_signal_ids[i])
		if signal_index < 0 or signal_index >= all_ids.size():
			continue
		if wanted.has(String(all_ids[signal_index])):
			keep.append(i)
	var knobs := {
		"cell_count": map.cell_count(),
		"width": map.width,
		"height": map.height,
		"seed": 42,
		"is_water": map.is_water_arr,
		"vegetation": map.vegetation_arr,
		"landform": map.landform_arr,
		"has_river": map.has_river_arr,
		"temperature": map.temp_arr,
		"moisture": map.moisture_arr,
		"elevation": map.elevation_arr,
		"neighbor_indices": map.neighbor_indices_packed(),
		"species_signal_ids": _take_i32(catalog.get("research_bio_signal_ids", PackedInt32Array()), keep),
		"species_occupancy_bits": _take_i32(catalog.get("research_bio_occupancy_bits", PackedInt32Array()), keep),
		"species_temp_lo": _take_f32(catalog.get("research_bio_temp_lo", PackedFloat32Array()), keep),
		"species_temp_hi": _take_f32(catalog.get("research_bio_temp_hi", PackedFloat32Array()), keep),
		"species_moist_lo": _take_f32(catalog.get("research_bio_moist_lo", PackedFloat32Array()), keep),
		"species_moist_hi": _take_f32(catalog.get("research_bio_moist_hi", PackedFloat32Array()), keep),
		"species_elev_lo": _take_f32(catalog.get("research_bio_elev_lo", PackedFloat32Array()), keep),
		"species_elev_hi": _take_f32(catalog.get("research_bio_elev_hi", PackedFloat32Array()), keep),
		"species_veg_mask0": _take_i32(catalog.get("research_bio_veg_mask0", PackedInt32Array()), keep),
		"species_veg_mask1": _take_i32(catalog.get("research_bio_veg_mask1", PackedInt32Array()), keep),
		"species_flags": _take_i32(catalog.get("research_bio_flags", PackedInt32Array()), keep),
		"species_max_cost": _take_i32(catalog.get("research_bio_max_cost", PackedInt32Array()), keep),
		"species_fill_keep": _take_f32(catalog.get("research_bio_fill_keep", PackedFloat32Array()), keep),
		"species_origin_policy": _take_i32(catalog.get("research_bio_origin_policy", PackedInt32Array()), keep),
		"species_guild": _take_i32(catalog.get("research_bio_guild", PackedInt32Array()), keep),
		"species_habitat_class": _take_i32(catalog.get("research_bio_habitat_class", PackedInt32Array()), keep),
	}
	var carrier_ids: PackedStringArray = catalog.get("research_bio_carrier_ids", PackedStringArray())
	var carrier_alts: PackedStringArray = catalog.get("research_bio_carrier_alt_ids", PackedStringArray())
	var unique: Array[String] = []
	var index_of := {}
	var columns: Array = []
	var empty := PackedFloat32Array()
	empty.resize(map.cell_count())
	var primary := PackedInt32Array()
	var alt := PackedInt32Array()
	primary.resize(keep.size())
	alt.resize(keep.size())
	for k in range(keep.size()):
		var src := int(keep[k])
		var id := String(carrier_ids[src]) if src < carrier_ids.size() else ""
		var alt_id := String(carrier_alts[src]) if src < carrier_alts.size() else ""
		if not id.is_empty() and not index_of.has(id):
			index_of[id] = unique.size()
			unique.append(id)
			columns.append(_reserve_column(map, id, empty))
		if not alt_id.is_empty() and not index_of.has(alt_id):
			index_of[alt_id] = unique.size()
			unique.append(alt_id)
			columns.append(_reserve_column(map, alt_id, empty))
		primary[k] = int(index_of.get(id, -1)) if not id.is_empty() else -1
		alt[k] = int(index_of.get(alt_id, -1)) if not alt_id.is_empty() else -1
	knobs["species_carrier_index"] = primary
	knobs["species_carrier_alt_index"] = alt
	knobs["carrier_reserves"] = columns
	knobs["carrier_resource_ids"] = unique
	return knobs


func _refresh_carrier_columns(map: MapData, knobs: Dictionary) -> Array:
	var ids: Array = knobs.get("carrier_resource_ids", [])
	var empty := PackedFloat32Array()
	empty.resize(map.cell_count())
	var columns: Array = []
	for id in ids:
		columns.append(_reserve_column(map, String(id), empty))
	return columns


func _reserve_column(map: MapData, resource_id: String, empty: PackedFloat32Array) -> PackedFloat32Array:
	for profile in ResourceProfileRegistry.ordered():
		if String(profile.id) != resource_id:
			continue
		var field := ResourceProfileRegistry.reserve_map_field(profile)
		if field.is_empty():
			break
		var values: PackedFloat32Array = map.get(field)
		if values.size() == map.cell_count():
			return values
		break
	return empty


func _take_i32(src: PackedInt32Array, keep: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(keep.size())
	for i in range(keep.size()):
		var idx := int(keep[i])
		out[i] = int(src[idx]) if idx >= 0 and idx < src.size() else 0
	return out


func _take_f32(src: PackedFloat32Array, keep: PackedInt32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(keep.size())
	for i in range(keep.size()):
		var idx := int(keep[i])
		out[i] = float(src[idx]) if idx >= 0 and idx < src.size() else 0.0
	return out


func _fills_origin_envelope(occupied: int, origin_envelope: int) -> bool:
	if origin_envelope <= 0:
		return occupied <= 0
	return occupied >= 8 or occupied * 2 >= origin_envelope


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("[PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _skip(reason: String) -> void:
	print("[SKIP] %s" % reason)
