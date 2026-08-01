extends SceneTree

# Full terrain/vegetation contract smoke test.
# Run with:
#   godot --headless --path Project/project-keynes \
#     --script res://tests/biome_vegetation_alignment_test.gd --quit

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	print("[biome-vegetation-alignment] checks=%d failures=%d" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	_test_all_pairs_are_bounded()
	_test_every_terrain_has_a_canonical_vegetation()
	_test_cross_biome_pairs_reconcile()
	_test_transitional_pairs_remain_allowed()
	_test_derive_representatives()
	_test_native_generation_has_no_unresolved_cross_biome_pairs()


func _test_all_pairs_are_bounded() -> void:
	var invalid := 0
	for terrain in range(31):
		for vegetation in range(28):
			var weight: float = VegetationType.biome_envelope_weight(terrain, vegetation)
			if weight < 0.18 or weight > 1.0:
				invalid += 1
	_expect("all 31x28 envelope entries are bounded", invalid == 0)


func _test_every_terrain_has_a_canonical_vegetation() -> void:
	var canonical: Dictionary = {
		int(TerrainType.TERRAIN.OCEAN): int(VegetationType.VEG.NONE),
		int(TerrainType.TERRAIN.COAST): int(VegetationType.VEG.SEAGRASS),
		int(TerrainType.TERRAIN.PLAIN): int(VegetationType.VEG.TEMPERATE_GRASSLAND),
		int(TerrainType.TERRAIN.GRASSLAND): int(VegetationType.VEG.TEMPERATE_GRASSLAND),
		int(TerrainType.TERRAIN.FOREST): int(VegetationType.VEG.TEMPERATE_DECIDUOUS),
		int(TerrainType.TERRAIN.HILL): int(VegetationType.VEG.TEMPERATE_DECIDUOUS),
		int(TerrainType.TERRAIN.MOUNTAIN): int(VegetationType.VEG.ALPINE_MEADOW),
		int(TerrainType.TERRAIN.DESERT): int(VegetationType.VEG.XERIC_DESERT),
		int(TerrainType.TERRAIN.TUNDRA): int(VegetationType.VEG.TUNDRA),
		int(TerrainType.TERRAIN.SNOW): int(VegetationType.VEG.POLAR_DESERT),
		int(TerrainType.TERRAIN.SWAMP): int(VegetationType.VEG.SWAMP),
		int(TerrainType.TERRAIN.JUNGLE): int(VegetationType.VEG.TROPICAL_RAINFOREST),
		int(TerrainType.TERRAIN.SAVANNA): int(VegetationType.VEG.SAVANNA),
		int(TerrainType.TERRAIN.TAIGA): int(VegetationType.VEG.TAIGA),
		int(TerrainType.TERRAIN.STEPPE): int(VegetationType.VEG.TEMPERATE_STEPPE),
		int(TerrainType.TERRAIN.SHRUBLAND): int(VegetationType.VEG.MEDITERRANEAN_SHRUB),
		int(TerrainType.TERRAIN.MANGROVE): int(VegetationType.VEG.MANGROVE),
		int(TerrainType.TERRAIN.GLACIER): int(VegetationType.VEG.NONE),
		int(TerrainType.TERRAIN.LAKE): int(VegetationType.VEG.NONE),
		int(TerrainType.TERRAIN.REEF): int(VegetationType.VEG.CORAL_REEF),
		int(TerrainType.TERRAIN.SEA_ICE): int(VegetationType.VEG.NONE),
		int(TerrainType.TERRAIN.KELP): int(VegetationType.VEG.KELP_FOREST),
		int(TerrainType.TERRAIN.DELTA): int(VegetationType.VEG.MARSH),
		int(TerrainType.TERRAIN.OASIS): int(VegetationType.VEG.OASIS_VEG),
		int(TerrainType.TERRAIN.SALT_FLAT): int(VegetationType.VEG.NONE),
		int(TerrainType.TERRAIN.BADLANDS): int(VegetationType.VEG.DESERT_SCRUB),
		int(TerrainType.TERRAIN.COLD_DESERT): int(VegetationType.VEG.DESERT_SCRUB),
		int(TerrainType.TERRAIN.CHAPARRAL): int(VegetationType.VEG.MEDITERRANEAN_SHRUB),
		int(TerrainType.TERRAIN.MOOR): int(VegetationType.VEG.PEAT_BOG),
		int(TerrainType.TERRAIN.FLOODPLAIN): int(VegetationType.VEG.MARSH),
		int(TerrainType.TERRAIN.MESA): int(VegetationType.VEG.DESERT_SCRUB),
	}
	_expect("canonical table covers every terrain id", canonical.size() == 31)
	for terrain in canonical:
		var weight := VegetationType.biome_envelope_weight(int(terrain), int(canonical[terrain]))
		_expect("canonical envelope is strong t=%d" % int(terrain), weight >= 0.90)


func _test_cross_biome_pairs_reconcile() -> void:
	var incompatible: Array = [
		[TerrainType.TERRAIN.COAST, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.SNOW, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.SWAMP, VegetationType.VEG.MANGROVE],
		[TerrainType.TERRAIN.MANGROVE, VegetationType.VEG.TEMPERATE_STEPPE],
		[TerrainType.TERRAIN.DELTA, VegetationType.VEG.TAIGA],
		[TerrainType.TERRAIN.OASIS, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.SALT_FLAT, VegetationType.VEG.SAVANNA],
		[TerrainType.TERRAIN.BADLANDS, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.MESA, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.FOREST, VegetationType.VEG.MONSOON_FOREST],
		[TerrainType.TERRAIN.GRASSLAND, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.STEPPE, VegetationType.VEG.TROPICAL_DRY_FOREST],
		[TerrainType.TERRAIN.DESERT, VegetationType.VEG.TROPICAL_DRY_FOREST],
		[TerrainType.TERRAIN.SAVANNA, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.TUNDRA, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.TAIGA, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.COLD_DESERT, VegetationType.VEG.BOREAL_SHRUB],
	]
	for pair in incompatible:
		_expect("cross-biome pair reconciles t=%d v=%d" % [int(pair[0]), int(pair[1])],
			VegetationType.needs_biome_reconciliation(int(pair[0]), int(pair[1])))


func _test_transitional_pairs_remain_allowed() -> void:
	var transitional: Array = [
		[TerrainType.TERRAIN.JUNGLE, VegetationType.VEG.TROPICAL_DRY_FOREST],
		[TerrainType.TERRAIN.SAVANNA, VegetationType.VEG.TROPICAL_DRY_FOREST],
		[TerrainType.TERRAIN.FLOODPLAIN, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.FLOODPLAIN, VegetationType.VEG.TROPICAL_DRY_FOREST],
		[TerrainType.TERRAIN.FLOODPLAIN, VegetationType.VEG.TAIGA],
		[TerrainType.TERRAIN.TUNDRA, VegetationType.VEG.TAIGA],
		[TerrainType.TERRAIN.TAIGA, VegetationType.VEG.BOREAL_SHRUB],
		[TerrainType.TERRAIN.SWAMP, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.COAST, VegetationType.VEG.SEAGRASS],
	]
	for pair in transitional:
		_expect("transitional pair is not hard-reconciled t=%d v=%d" % [int(pair[0]), int(pair[1])],
			not VegetationType.needs_biome_reconciliation(int(pair[0]), int(pair[1])))


func _test_derive_representatives() -> void:
	var generator := MapGenerator.new()
	var cases: Array = [
		[TerrainType.TERRAIN.FOREST, 0.60, 0.60, 0.60, VegetationType.VEG.SUBTROPICAL_FOREST],
		[TerrainType.TERRAIN.JUNGLE, 0.50, 0.78, 0.50, VegetationType.VEG.MONSOON_FOREST],
		[TerrainType.TERRAIN.JUNGLE, 0.70, 0.82, 0.60, VegetationType.VEG.TROPICAL_RAINFOREST],
		[TerrainType.TERRAIN.SAVANNA, 0.50, 0.75, 0.53, VegetationType.VEG.SAVANNA],
		[TerrainType.TERRAIN.SAVANNA, 0.60, 0.75, 0.56, VegetationType.VEG.MONSOON_FOREST],
		[TerrainType.TERRAIN.GRASSLAND, 0.45, 0.50, 0.40, VegetationType.VEG.TEMPERATE_GRASSLAND],
		[TerrainType.TERRAIN.STEPPE, 0.35, 0.45, 0.25, VegetationType.VEG.TEMPERATE_STEPPE],
		[TerrainType.TERRAIN.DESERT, 0.08, 0.80, 0.08, VegetationType.VEG.XERIC_DESERT],
		[TerrainType.TERRAIN.DESERT, 0.28, 0.80, 0.20, VegetationType.VEG.DESERT_SCRUB],
		[TerrainType.TERRAIN.TUNDRA, 0.25, 0.12, 0.30, VegetationType.VEG.TUNDRA],
		[TerrainType.TERRAIN.TAIGA, 0.40, 0.30, 0.50, VegetationType.VEG.TAIGA],
		[TerrainType.TERRAIN.DELTA, 0.70, 0.60, 0.50, VegetationType.VEG.MANGROVE],
		[TerrainType.TERRAIN.DELTA, 0.70, 0.40, 0.50, VegetationType.VEG.MARSH],
		[TerrainType.TERRAIN.FLOODPLAIN, 0.70, 0.80, 0.75, VegetationType.VEG.MONSOON_FOREST],
		[TerrainType.TERRAIN.SWAMP, 0.80, 0.30, 0.30, VegetationType.VEG.PEAT_BOG],
	]
	for item in cases:
		var cell := HexCell.new(0, 0)
		cell.terrain = int(item[0])
		cell.moisture = float(item[1])
		var result := generator._derive_vegetation(cell, int(LandformType.LF.PLAIN), float(item[2]))
		_expect("derive representative t=%d" % int(item[0]), result == int(item[4]))


func _test_native_generation_has_no_unresolved_cross_biome_pairs() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		print("[biome-vegetation-alignment] SKIP native generation: DCWorldExt missing")
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	_expect("DCWorldExt instantiated", ext != null)
	if ext == null or not ext.has_method("run_native_world_generate_full_pass"):
		return
	var cfg := {
		"width": 56,
		"height": 36,
		"num_continents": 3,
		"sea_level": 0.42,
		"continent_size": 0.9,
		"river_count": 6,
		"water_dist_max": 8,
		"water_big_river_flow_min": 0.55,
		"lake_moist_floor": 0.55,
		"lake_moist_scale": 2.5,
		"river_riparian_floor": 0.36,
		"river_riparian_gain": 0.12,
		"river_riparian_scale": 2.0,
		"swamp_water_band": 2,
	}
	var result: Dictionary = ext.call("run_native_world_generate_full_pass", 20260731, cfg,
		{"native_generation_mode": 2})
	_expect("native generation succeeds", int(result.get("rc", -1)) == 0 and not bool(result.get("fallback", true)))
	if int(result.get("rc", -1)) != 0:
		return
	var terrain: PackedByteArray = result.get("terrain_arr", PackedByteArray())
	var vegetation: PackedByteArray = result.get("vegetation_arr", PackedByteArray())
	var unresolved := 0
	for i in range(mini(terrain.size(), vegetation.size())):
		if VegetationType.needs_biome_reconciliation(int(terrain[i]), int(vegetation[i])):
			unresolved += 1
	_expect("native output has no unresolved cross-biome pairs", unresolved == 0)
	print("[biome-vegetation-alignment] native unresolved=%d reconciled=%d" % [
		unresolved, int(result.get("vegetation_biome_reconciled_count", 0))])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		push_error("[biome-vegetation-alignment] FAIL: %s" % label)
