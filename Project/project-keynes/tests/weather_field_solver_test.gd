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
	_test_deterministic_same_seed_same_map()
	print("=== done: %d checks, %d failures ===" % [_checks, _failures])

func _test_orographic_rain_shadow() -> void:
	var map := MapData.new(3, 1)
	map.set_cell(_cell(-1, 0, TerrainType.TERRAIN.PLAIN, LandformType.LF.PLAIN, 0.18, 0.68, 0.78, Vector2.RIGHT))
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.MOUNTAIN, LandformType.LF.MOUNTAIN, 0.82, 0.62, 0.78, Vector2.RIGHT))
	map.set_cell(_cell(1, 0, TerrainType.TERRAIN.PLAIN, LandformType.LF.PLAIN, 0.20, 0.62, 0.78, Vector2.RIGHT))
	var ws := _weather_system(Rect2(Vector2(-80.0, -40.0), Vector2(180.0, 100.0)))
	ws.tick_one_day(map, _world(), 1, 0.0, 1.5)
	var windward := ws.query_at(HexUtils.cube_to_world(0, 0, HEX_SIZE))
	var leeward := ws.query_at(HexUtils.cube_to_world(1, 0, HEX_SIZE))
	_expect(float(windward.get("precip", 0.0)) > float(leeward.get("precip", 0.0)) + 0.05,
		"windward mountain precip should exceed leeward rain shadow")

func _test_warm_convection_prefers_storm() -> void:
	var map := MapData.new(2, 1)
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.OCEAN, LandformType.LF.OCEAN, 0.05, 0.86, 0.92, Vector2.RIGHT, 0.24))
	map.set_cell(_cell(1, 0, TerrainType.TERRAIN.COAST, LandformType.LF.COAST, 0.08, 0.82, 0.88, Vector2.RIGHT, 0.18))
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(140.0, 100.0)))
	ws.tick_one_day(map, _world(), 1, 0.04, 1.5)
	var q := ws.query_at(HexUtils.cube_to_world(0, 0, HEX_SIZE))
	_expect(int(q.get("type", WeatherType.WT.CLEAR)) == WeatherType.WT.STORM,
		"warm humid water with positive ocean anomaly should classify as STORM")

func _test_cold_precip_prefers_blizzard() -> void:
	var map := MapData.new(1, 1)
	map.set_cell(_cell(0, 0, TerrainType.TERRAIN.SNOW, LandformType.LF.PLAIN, 0.20, 0.16, 0.88, Vector2.RIGHT))
	var ws := _weather_system(Rect2(Vector2(-40.0, -40.0), Vector2(100.0, 100.0)))
	ws.tick_one_day(map, _world(), 3, -0.04, 3.5)
	var q := ws.query_at(HexUtils.cube_to_world(0, 0, HEX_SIZE))
	_expect(int(q.get("type", WeatherType.WT.CLEAR)) == WeatherType.WT.BLIZZARD,
		"cold humid precipitating region should classify as BLIZZARD")

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
	return map

func _weather_system(bounds: Rect2) -> WeatherSystem:
	var ws := WeatherSystem.new()
	ws.init(12345, bounds, HEX_SIZE)
	ws.configure_weather_field(true, 2, 0.08, 0.55, 0.35, 0.35, 0.25, 0.40, 16)
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

func _expect(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("[FAIL] " + msg)
		print("[FAIL] " + msg)
