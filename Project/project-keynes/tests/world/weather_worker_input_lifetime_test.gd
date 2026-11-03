extends SceneTree

# Exercise the real capture/cleanup boundary: native daily weather inputs must
# survive clearing the temporary solver state and capturing the following day.
var _checks := 0
var _failures := 0


func _init() -> void:
	var map := MapData.new(3, 2)
	for r in range(2):
		for q in range(3):
			var cell := HexCell.new()
			cell.q = q
			cell.r = r
			cell.s = -q - r
			cell.terrain = TerrainType.TERRAIN.PLAIN
			cell.landform = LandformType.LF.PLAIN
			cell.temperature = 0.6
			cell.moisture = 0.7
			cell.base_moisture = 0.7
			cell.wind_vector = Vector2.RIGHT
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	var world := WorldData.new()
	world.world_bounds = Rect2(-100.0, -100.0, 240.0, 200.0)
	for native_enabled in [true, false]:
		var weather := WeatherSystem.new()
		weather.init(12345, world.world_bounds, 22.0)
		weather.configure_gdext_acceleration(DCWorldExt.new(), native_enabled)
		var first := weather.build_field_knobs_for_worker(map, world, 1, 0.0, 1.5)
		_expect(not first.is_empty(), "capture retains weather configuration (%s)" % native_enabled)
		_expect(int(first.get("n_cells", 0)) == 6, "capture retains cell count")
		var neighbors: PackedInt32Array = first.get("neighbor_indices", PackedInt32Array())
		var temperatures: PackedFloat32Array = first.get("temp_read_arr", PackedFloat32Array())
		_expect(neighbors.size() == 36 and temperatures.size() == 6,
			"capture retains topology and climate input arrays")
		_expect(not weather.is_weather_field_solve_active(), "capture releases temporary solver state")
		var second := weather.build_field_knobs_for_worker(map, world, 2, 0.1, 2.5)
		_expect(int(first.get("season_idx", -1)) == 1
			and int(second.get("season_idx", -1)) == 2,
			"next capture preserves the previous day's input")
	print("weather worker input lifetime: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _expect(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error("[FAIL] " + label)
