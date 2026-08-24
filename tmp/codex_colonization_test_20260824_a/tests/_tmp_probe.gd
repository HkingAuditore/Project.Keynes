extends SceneTree
func _init() -> void:
	var map := MapData.new(15, 11)
	for row in range(11):
		for col in range(15):
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = LandformType.LF.PLAIN
			cell.vegetation = VegetationType.VEG.NONE
			map.set_cell(cell)
	map.rebuild_soa_from_cells()
	var c := map.get_cell_by_cube(HexUtils.offset_to_cube(7, 5))
	print("cell null? ", c == null, " idx=", -1 if c == null else c.index)
	print("slot arr size=", map.country_slot_arr.size(), " n=", map.cell_count())
	map.country_slot_arr[int(c.index)] = 0
	print("after write slot=", map.country_slot_arr[int(c.index)])
	print("landform_arr size=", map.landform_arr.size(), " lf0=", map.landform_arr[0], " PLAIN=", LandformType.LF.PLAIN)
	var w := WorldData.new()
	var baked: Dictionary = VisionSolver.bake_static_fields(map, w)
	print("bake=", baked)
	print("view_block src=", w.cell_view_block[int(c.index)], " height=", w.cell_view_height[int(c.index)])
	print("has_indices=", map.has_indices())
	print("solve=", VisionSolver.solve(map, w, 0))
	quit(0)
