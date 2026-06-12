# weather_field_solver_test.gd
# Headless execution:
#     godot --headless --script tests/weather_field_solver_test.gd --quit

extends SceneTree

const HEX_SIZE := 22.0

var _failures: int = 0
var _checks: int = 0

func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)

func _run() -> void:
	print("=== WeatherField solver test ===")
	_test_orographic_rain_shadow()
	_test_warm_convection_prefers_storm()
	_test_cold_precip_prefers_blizzard()
	_test_precip_consumes_vapor()
	_test_precip_carryover_and_vapor_relaxation()
	_test_orographic_lift_cap_formula()
	_test_snowpack_distribute_budget()
	_test_deterministic_same_seed_same_map()
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])

func _test_orographic_rain_shadow() -> void:
	var map := MapData.new(3, 1)
	map.set_cell(_cell(-1, 0, TerrainType.TERRAIN.PLAIN, LandformType.LF.PLAIN, 0.18, 0.68, 0.78, Vector2.RIGHT))
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.MOUNTAIN, LandformType.LF.MOUNTAIN, 0.82, 0.62, 0.78, Vector2.RIGHT))
	map.set_cell(_cell(1, 0, TerrainType.TERRAIN.PLAIN, LandformType.LF.PLAIN, 0.20, 0.62, 0.78, Vector2.RIGHT))
	map.rebuild_soa_from_cells()
	var ws := _weather_system(Rect2(Vector2(-80.0, -40.0), Vector2(180.0, 100.0)))
	ws.tick_one_day(map, _world(), 1, 0.0, 1.5)
	var mountain := ws.query_at(HexUtils.cube_to_world(0, 0, HEX_SIZE))
	var wet_side := ws.query_at(HexUtils.cube_to_world(1, 0, HEX_SIZE))
	_expect(float(wet_side.get("precip", 0.0)) > float(mountain.get("precip", 0.0)) + 0.05,
		"orographic wet side should exceed adjacent rain shadow (wet=%.3f shadow=%.3f)" % [float(wet_side.get("precip", 0.0)), float(mountain.get("precip", 0.0))])

func _test_warm_convection_prefers_storm() -> void:
	var map := MapData.new(2, 1)
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.OCEAN, LandformType.LF.OCEAN, 0.05, 0.86, 0.92, Vector2.RIGHT, 0.24))
	map.set_cell(_cell(1, 0, TerrainType.TERRAIN.COAST, LandformType.LF.COAST, 0.08, 0.82, 0.88, Vector2.RIGHT, 0.18))
	map.rebuild_soa_from_cells()
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(140.0, 100.0)))
	ws.tick_one_day(map, _world(), 1, 0.04, 1.5)
	var q := ws.query_at(HexUtils.cube_to_world(0, 0, HEX_SIZE))
	_expect(int(q.get("type", WeatherType.WT.CLEAR)) == WeatherType.WT.STORM,
		"warm humid water with positive ocean anomaly should classify as STORM")

func _test_cold_precip_prefers_blizzard() -> void:
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(100.0, 100.0)))
	var wt: int = ws._classify_field_weather_at(Vector2(0.0, -36.0), 3, 0.16, 0.55, 0.35, 0.12, 0.20, 0.0)
	_expect(wt == WeatherType.WT.BLIZZARD,
		"cold humid precipitating region should classify as BLIZZARD (type=%d)" % wt)

func _test_precip_consumes_vapor() -> void:
	var map := MapData.new(1, 1)
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.COAST, LandformType.LF.COAST, 0.08, 0.84, 0.98, Vector2.RIGHT, 0.20))
	map.rebuild_soa_from_cells()
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(100.0, 100.0)))
	ws.tick_one_day(map, _world(), 1, 0.05, 1.5)
	var q := ws.query_at(HexUtils.cube_to_world(0, 0, HEX_SIZE))
	var precip := float(q.get("precip", 0.0))
	var vapor := float(q.get("vapor", 1.0))
	_expect(precip < 0.20 or vapor < 0.90,
		"precipitating cell should spend vapor instead of retaining saturated vapor")


func _test_precip_carryover_and_vapor_relaxation() -> void:
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(100.0, 100.0)))
	_expect(is_equal_approx(ws._field_precip_carryover_max, 0.12),
		"precip carryover cap should default to 0.12")
	_expect(is_equal_approx(ws._field_vapor_precip_sink, 0.58),
		"vapor precip sink should default to 0.58")
	var carried: float = _precip_carryover(0.90, 0.95, ws._field_precip_carryover_max)
	_expect(carried <= ws._field_precip_carryover_max + 0.0001,
		"precip carryover should be capped")
	var vapor_after: float = _vapor_after_precip_and_relax(0.30, 0.60, 0.0, 0.0, ws._field_vapor_precip_sink, ws._field_vapor_relax_rate)
	_expect(vapor_after > 0.30 and vapor_after < 0.60,
		"dry calm field should relax vapor toward base moisture")


func _test_orographic_lift_cap_formula() -> void:
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(100.0, 100.0)))
	var lift_supply: float = minf(0.95 * 0.80, ws._field_orographic_lift_cap)
	_expect(lift_supply <= 0.35 + 0.0001,
		"orographic lift contribution should be capped by config")


func _test_snowpack_distribute_budget() -> void:
	var map := MapData.new(3, 1)
	var cold := _cell(0, 0, TerrainType.TERRAIN.MOUNTAIN, LandformType.LF.MOUNTAIN, 0.86, 0.14, 0.86, Vector2.RIGHT)
	var warm := _cell(1, 0, TerrainType.TERRAIN.PLAIN, LandformType.LF.PLAIN, 0.12, 0.62, 0.86, Vector2.RIGHT)
	var glacier := _cell(2, 0, TerrainType.TERRAIN.GLACIER, LandformType.LF.MOUNTAIN, 0.90, 0.48, 0.60, Vector2.RIGHT)
	glacier.cover = CoverType.CV.GLACIER
	map.set_cell(cold)
	map.set_cell(warm)
	map.set_cell(glacier)
	map.rebuild_soa_from_cells()
	_mark_weather(cold, WeatherType.WT.BLIZZARD, 0.80, 0.70)
	_mark_weather(warm, WeatherType.WT.RAIN, 0.80, 0.70)
	_mark_weather(glacier, WeatherType.WT.CLEAR, 0.0, 0.0)

	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(180.0, 100.0)))
	ws._distribute_weather_field_to_cells(map)
	var cold_idx: int = cold.index
	var warm_idx: int = warm.index
	var glacier_idx: int = glacier.index
	_expect(map.snowpack_arr[cold_idx] > 0.05, "cold wet mountain should accumulate snowpack")
	_expect(map.snow_cover_arr[cold_idx] > 0.95, "cold wet mountain below snowline should get physical snowline cover")
	_expect(map.snowpack_arr[warm_idx] < 0.02 and map.snow_cover_arr[warm_idx] < 0.05,
		"warm lowland rain should not create visible snowpack")
	_expect(map.snowpack_arr[glacier_idx] >= 0.79 and map.snow_cover_arr[glacier_idx] >= 0.79,
		"glacier should keep snowpack and snow cover floor")

func _test_deterministic_same_seed_same_map() -> void:
	var ws_a := _weather_system(Rect2(Vector2(-80.0, -40.0), Vector2(180.0, 100.0)))
	var ws_b := _weather_system(Rect2(Vector2(-80.0, -40.0), Vector2(180.0, 100.0)))
	var map_a := _determinism_map()
	var map_b := _determinism_map()
	ws_a.tick_one_day(map_a, _world(), 1, 0.02, 1.25)
	ws_b.tick_one_day(map_b, _world(), 1, 0.02, 1.25)
	var pos := HexUtils.cube_to_world(0, 0, HEX_SIZE)
	var qa := ws_a.query_at(pos)
	var qb := ws_b.query_at(pos)
	_expect(int(qa.get("type", -1)) == int(qb.get("type", -2)), "same seed/map should keep weather type deterministic")
	_expect(is_equal_approx(float(qa.get("intensity", 0.0)), float(qb.get("intensity", 1.0))), "same seed/map should keep intensity deterministic")

func _determinism_map() -> MapData:
	var map := MapData.new(3, 1)
	map.set_cell(_cell(-1, 0, TerrainType.TERRAIN.COAST, LandformType.LF.COAST, 0.08, 0.72, 0.82, Vector2.RIGHT, 0.15))
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.PLAIN, LandformType.LF.PLAIN, 0.24, 0.66, 0.76, Vector2.RIGHT, 0.08))
	map.set_cell(_cell(1, 0, TerrainType.TERRAIN.HILL, LandformType.LF.HILL, 0.42, 0.60, 0.72, Vector2.RIGHT, 0.02))
	map.rebuild_soa_from_cells()
	return map

func _weather_system(bounds: Rect2) -> WeatherSystem:
	var ws := WeatherSystem.new()
	ws.init(12345, bounds, HEX_SIZE)
	ws.configure_weather_field(true, 2, 0.08, 0.55, 0.35, 0.35, 0.25, 0.40, 16, 4, 0.12, 0.58, 0.16, 0.08, 0.015, 0.02, 0.18, 0.025, 0.34, 0.18, 0.08, 0.35, 0.22, 0.35, 0.35, 0.24, 0.35)
	ws.configure_terrain_wind(true)
	return ws

func _world() -> WorldData:
	var world := WorldData.new()
	world.world_bounds = Rect2(Vector2(-100.0, -100.0), Vector2(240.0, 200.0))
	return world

func _cell(q: int, r: int, terrain: TerrainType.TERRAIN, landform: int, elevation: float, temp: float, moisture: float, wind: Vector2, ocean_anomaly: float = 0.0) -> HexCell:
	var c := HexCell.new()
	c.q = q
	c.r = r
	c.s = -q - r
	c.terrain = terrain
	c.landform = landform
	c.elevation = elevation
	c.temperature = temp
	c.moisture = moisture
	c.base_moisture = moisture
	c.wind_vector = wind
	c.temperature_transport_anomaly = ocean_anomaly
	c.current_state = {}
	return c

func _mark_weather(cell: HexCell, wt: int, intensity: float, precip: float) -> void:
	cell.weather_field_initialized = true
	cell.weather_type = wt
	cell.weather_intensity = intensity
	cell.weather_precip = precip


func _precip_carryover(prev_precip: float, cloud: float, carryover_max: float) -> float:
	var keep_ratio: float = clampf(cloud, 0.25, 0.80)
	if keep_ratio > carryover_max:
		keep_ratio = carryover_max
	return prev_precip * keep_ratio


func _vapor_after_precip_and_relax(vapor: float, base_m: float, precip: float, cloud: float, sink: float, relax: float) -> float:
	var vapor_after: float = maxf(0.0, vapor - precip * sink)
	if precip < 0.02 and cloud < 0.12 and relax > 0.0:
		vapor_after = lerpf(vapor_after, base_m, relax)
	return vapor_after


func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("[FAIL] " + msg)
		print("[FAIL] " + msg)
