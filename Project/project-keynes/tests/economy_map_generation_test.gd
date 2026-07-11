extends SceneTree

var failures := 0


func _init() -> void:
	var profile = load("res://data/world/earth_like.tres").duplicate(true)
	profile.native_generation_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_daily_sim_mode = ClimateProfile.NATIVE_MODE_ACTIVE
	profile.native_environment_runtime_enabled = false
	var cfg := MapConfig.make(8, 6)
	cfg.seed = 20260712
	cfg.num_continents = 1
	cfg.sea_level = 0.45
	cfg.continent_size = 0.85
	cfg.climate_profile = profile
	var generator := MapGenerator.new()
	generator.climate_profile = profile
	generator.set_test_economy_bootstrap_enabled(true)
	var generated: Dictionary = generator.generate(cfg, 10.0)
	var map: MapData = generated.get("map", null)
	_expect("map generated", map != null)
	var facade = generator.get_economy_facade()
	_expect("economy facade configured", facade != null and facade.is_configured())
	if map != null and facade != null:
		var populated_cell := _first_populated_cell(map, facade)
		_expect("generated map has populated land", populated_cell >= 0)
		if populated_cell >= 0:
			var buildings: Dictionary = facade.building_cell_snapshot(populated_cell)
			_expect("generated economy includes building groups",
				_sum_i64(buildings.get("building_counts_by_type", PackedInt64Array())) > 0)
			_expect("building snapshot is committed", bool(buildings.get("committed", false)))
	if failures == 0:
		print("[economy-map-generation] PASS")
	quit(0 if failures == 0 else 1)


func _first_populated_cell(map: MapData, facade) -> int:
	for cell in range(map.cell_count()):
		var snapshot: Dictionary = facade.population_cell_snapshot(cell)
		if int(snapshot.get("population", 0)) > 0:
			return cell
	return -1


func _sum_i64(values: PackedInt64Array) -> int:
	var total := 0
	for value in values:
		total += int(value)
	return total


func _expect(label: String, condition: bool) -> void:
	print("  [%s] %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1
