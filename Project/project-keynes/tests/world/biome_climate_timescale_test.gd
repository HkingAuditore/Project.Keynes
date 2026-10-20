extends SceneTree

# Headless regression test for biome/vegetation climate timescales.

func _init() -> void:
	var map := MapData.new(1, 1)
	map.base_moisture_arr = PackedFloat32Array([0.30])
	map.water_balance_30d_arr = PackedFloat32Array([0.0])
	map.temp_365d_arr = PackedFloat32Array([0.42])
	var cell := HexCell.new(0, 0)
	cell.index = 0
	cell.base_moisture = 0.30
	cell.moisture = 0.90
	cell.temperature = 0.90
	var generator := MapGenerator.new()
	var failures := PackedStringArray()
	if not is_equal_approx(float(generator._biome_moisture(map, cell)), 0.30):
		failures.append("biome moisture used instantaneous moisture instead of long-term inputs")
	if not is_equal_approx(float(generator._biome_temperature(map, cell, 0.90)), 0.42):
		failures.append("biome temperature did not use temp_365d")
	if not float(cell.moisture) > float(generator._biome_moisture(map, cell)):
		failures.append("vegetation/runtime moisture was unexpectedly collapsed into biome moisture")
	if failures.is_empty():
		print("[biome-climate-timescale] PASS")
		quit(0)
		return
	for failure in failures:
		push_error("[biome-climate-timescale] FAIL: %s" % failure)
	quit(1)
