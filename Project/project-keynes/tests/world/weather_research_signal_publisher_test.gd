extends SceneTree

const Publisher = preload("res://scripts/research/weather_research_signal_publisher.gd")

class CountryProbe:
	extends RefCounted
	func cell_summary(cell: int) -> Dictionary:
		return {"country_handle": 101 if cell < 3 else 202}


func _init() -> void:
	var map := MapData.new(3, 2)
	for row in range(2):
		for col in range(3):
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	var n := map.cell_count()
	map.weather_type_arr = PackedByteArray()
	map.weather_type_arr.resize(n)
	map.weather_intensity_arr = PackedFloat32Array()
	map.weather_intensity_arr.resize(n)
	map.temp_arr = PackedFloat32Array()
	map.temp_arr.resize(n)
	map.cover_arr = PackedByteArray()
	map.cover_arr.resize(n)
	map.wind_speed_arr = PackedFloat32Array()
	map.wind_speed_arr.resize(n)
	for cell in range(n):
		map.temp_arr[cell] = 0.5
	map.weather_type_arr[0] = WeatherType.WT.DROUGHT
	map.weather_type_arr[1] = WeatherType.WT.DROUGHT
	map.weather_intensity_arr[0] = 0.7
	map.weather_intensity_arr[1] = 0.8
	map.temp_arr[2] = 0.1
	map.weather_type_arr[3] = WeatherType.WT.MONSOON
	map.weather_intensity_arr[3] = 0.75
	map.cover_arr[4] = CoverType.CV.FLOODING
	map.wind_speed_arr[4] = 0.8
	var cyclone_snapshot := {"cyclones": [{
		"cell_idx": 4, "radius_cells": 0.0, "intensity": 0.9,
	}]}
	var batch := Publisher.build_batch(map, CountryProbe.new(), 9, cyclone_snapshot)
	assert(int(batch.count) == 6, str(batch))
	assert((batch.payload_i0 as PackedInt32Array) == PackedInt32Array([2, 4, 0, 1, 3, 5]))
	assert((batch.payload_i1 as PackedInt32Array) == PackedInt32Array([2, 1, 1, 1, 1, 1]))
	assert((batch.payload_i3 as PackedInt32Array) == PackedInt32Array([1, 1, 1, 1, 1, 1]))
	assert((batch.entity_handle as PackedInt64Array) == PackedInt64Array(
		[101, 101, 202, 202, 202, 202]))
	print("[PASS] weather observations aggregate once per country and rule")
	quit(0)
