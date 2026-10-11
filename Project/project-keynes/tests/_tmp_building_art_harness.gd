extends Node2D

## Visual harness for the building layer: columns are the 11 eras, rows are
## local economies (industry mix + settlement tier + wealth bands; last row
## snowed in). With the `wealth` user arg the columns instead sweep living
## level and inequality at era 5. Renders through the production
## BuildingVisualLayer + native planner and saves screenshots.
##   godot --path Project/project-keynes res://tests/_tmp_building_art_harness.tscn -- <out_dir> [detail|wealth]

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const IntelCacheScript = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const LayerScript = preload("res://scripts/rendering/building_visual_layer.gd")

const COLS := 11
const ROWS := 6
const HEX := 22.0
# Per row: authored type id -> building count, and [tier, living, rich, poor].
const ROW_MIX := [
	{"tenant_paddy": 8, "wheat_farm": 3},
	{"wheat_farm": 60, "pastoral_camp": 20, "bakery": 10, "merchant_post": 4},
	{"textile_mill": 120, "tannery": 40, "merchant_post": 30, "wheat_farm": 10},
	{"coal_mine": 80, "bloomery": 60, "fired_brick_kiln": 20, "stone_collector": 10},
	{"merchant_post": 300, "classical_academy": 80, "computers_plant": 40, "bakery": 30},
	{"marine_fish_collector": 30, "timber_collector": 20, "salt_collector": 10},
]
const ROW_SOCIAL := [
	[1, 2, 0, 0],
	[3, 3, 0, 1],
	[5, 3, 0, 3],
	[4, 2, 0, 2],
	[7, 6, 3, 1],
	[3, 3, 0, 0],
]

var _layer: BuildingVisualLayer
var _camera: Camera2D
var _map: MapData
var _out_dir := "user://building_art"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_out_dir = args[0]
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_map = MapData.new(COLS, ROWS)
	for row in ROWS:
		for col in COLS:
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.landform = LandformType.LF.PLAIN
			cell.terrain = TerrainType.TERRAIN.GRASSLAND
			_map.set_cell(cell)
	_map.rebuild_soa_from_cells()
	var n := _map.cell_count()

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c in n:
		var p := Vector2(_map.cell_pos_x_arr[c], _map.cell_pos_y_arr[c]) * HEX
		lo = lo.min(p)
		hi = hi.max(p)
	var world := WorldData.new()
	world.world_bounds = Rect2(lo - Vector2(60, 60), hi - lo + Vector2(120, 120))
	world.lut_dims = Vector2i(n, 1)
	var dyn := Image.create(n, 1, false, Image.FORMAT_RGBA8)
	var enum_img := Image.create(n, 1, false, Image.FORMAT_RGBA8)
	var weather := Image.create(n, 1, false, Image.FORMAT_RGBA8)
	for c in n:
		var row := c / COLS
		dyn.set_pixel(c, 0, Color(0.6, 0.45, 0.95 if row == ROWS - 1 else 0.0, 1.0))
		enum_img.set_pixel(c, 0, Color(0, 0, 0, 1.0))
		weather.set_pixel(c, 0, Color(0, 0.0, 0, 1))
	world.dyn_lut_tex = ImageTexture.create_from_image(dyn)
	world.enum_lut_tex = ImageTexture.create_from_image(enum_img)
	world.weather_lut_tex = ImageTexture.create_from_image(weather)

	_draw_ground(n)

	var compiled := EconomyCatalogScript.compile_native_catalog()
	var ids := compiled.building_type_ids as PackedStringArray
	var wealth_sweep := OS.get_cmdline_user_args().has("wealth")

	var cells := PackedInt32Array()
	var slots := PackedInt32Array()
	var eras := PackedInt32Array()
	var offsets := PackedInt32Array([0])
	var types := PackedInt32Array()
	var counts := PackedInt64Array()
	var tiers := PackedByteArray()
	var living := PackedByteArray()
	var rich := PackedByteArray()
	var poor := PackedByteArray()
	for c in n:
		var row := c / COLS
		var col := c % COLS
		cells.append(c)
		slots.append(0)
		eras.append(5 if wealth_sweep else col)
		var mix: Dictionary = ROW_MIX[row]
		var pairs: Array = []
		for type_id in mix:
			var t := ids.find(String(type_id))
			if t >= 0:
				pairs.append([t, int(mix[type_id])])
		pairs.sort_custom(func(x, y): return int(x[0]) < int(y[0]))
		for pair in pairs:
			types.append(int(pair[0]))
			counts.append(int(pair[1]))
		offsets.append(types.size())
		var social: Array = ROW_SOCIAL[row]
		tiers.append(int(social[0]))
		if wealth_sweep:
			living.append(roundi(float(col) * 0.6))
			rich.append(3 if col >= 7 else (1 if col >= 5 else 0))
			poor.append(3 if col <= 2 else (1 if col <= 5 else 0))
		else:
			living.append(int(social[1]))
			rich.append(int(social[2]))
			poor.append(int(social[3]))
	var intel: BuildingVisualIntelCache = IntelCacheScript.new()
	intel.configure(n)
	var applied := intel.apply_snapshot({
		"cell_indices": cells, "country_slots": slots, "era_indices": eras,
		"type_offsets": offsets, "type_indices": types, "counts": counts,
		"settlement_tiers": tiers, "living_levels": living,
		"rich_buckets": rich, "poor_buckets": poor,
	})
	print("[harness] intel ok=", applied.get("ok"), " ", applied.get("reason", ""))

	_layer = LayerScript.new()
	add_child(_layer)
	var setup := _layer.configure(_map, world, HEX, compiled, intel)
	print("[harness] configure ", setup.get("ok"), " ", setup.get("reason", ""))
	_layer.set_visual_quality(2)
	_layer.set_day_night_enabled(false)
	_layer.set_season_phase(1.0)

	_camera = Camera2D.new()
	add_child(_camera)
	_camera.make_current()
	_run.call_deferred(world)


func _draw_ground(n: int) -> void:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.08
	for c in n:
		var center := Vector2(_map.cell_pos_x_arr[c], _map.cell_pos_y_arr[c]) * HEX
		var poly := Polygon2D.new()
		var pts := PackedVector2Array()
		for k in 6:
			var ang := deg_to_rad(60.0 * k - 30.0)
			pts.append(center + Vector2(cos(ang), sin(ang)) * HEX)
		poly.polygon = pts
		var v := noise.get_noise_2d(center.x, center.y) * 0.06
		var snowy := c / COLS == ROWS - 1
		poly.color = Color(0.83, 0.86, 0.88) if snowy else Color(0.42 + v, 0.47 + v, 0.27 + v * 0.5)
		poly.z_index = -5
		poly.z_as_relative = false
		add_child(poly)
		var edge := Line2D.new()
		edge.points = pts
		edge.closed = true
		edge.width = 0.3
		edge.default_color = Color(0, 0, 0, 0.25)
		edge.z_index = -4
		edge.z_as_relative = false
		add_child(edge)


func _view(center: Vector2, zoom: float) -> void:
	_camera.position = center
	_camera.zoom = Vector2(zoom, zoom)
	var size := get_viewport_rect().size / zoom
	_layer.set_camera_view(Rect2(center - size * 0.5, size), center, zoom)


func _cell_center(col: int, row: int) -> Vector2:
	var c := row * COLS + col
	return Vector2(_map.cell_pos_x_arr[c], _map.cell_pos_y_arr[c]) * HEX


func _shot(name: String) -> void:
	_layer.wait_for_layout(10000)
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := _out_dir.path_join(name + ".png")
	img.save_png(path)
	print("[harness] saved ", path, " diag=", _layer.diagnostics().get("body_instances"),
		" lots=", _layer.diagnostics().get("last_chunk_lot_count"),
		" decals=", _layer.diagnostics().get("last_chunk_decal_count"),
		" chunk_upload_max_ms=", _layer.diagnostics().get("max_chunk_upload_ms"),
		" submit_max_ms=", _layer.diagnostics().get("max_submit_ms"),
		" worker_us_avg=", _layer.diagnostics().get("cache", {}).get("worker_plan_us_avg"),
		" planned=", _layer.diagnostics().get("cache", {}).get("planned_cells"))


func _run(world: WorldData) -> void:
	var mid := world.world_bounds.get_center()
	if OS.get_cmdline_user_args().has("detail"):
		_view(_cell_center(3, 2), 24.0)
		await _shot("detail_classical")
		_view(_cell_center(6, 3), 24.0)
		await _shot("detail_industrial")
		_view(_cell_center(9, 4), 24.0)
		await _shot("detail_information")
		_view(_cell_center(1, 1), 24.0)
		await _shot("detail_agrarian")
		_view(_cell_center(2, 0), 24.0)
		await _shot("detail_paddy")
		_view(_cell_center(8, 4), 24.0)
		await _shot("detail_rich_capital")
		_view(_cell_center(5, 5), 24.0)
		await _shot("detail_coast_snow")
		get_tree().quit(0)
		return
	if OS.get_cmdline_user_args().has("wealth"):
		_view(mid, 2.2)
		await _shot("wealth_overview")
		_view((_cell_center(0, 2) + _cell_center(3, 3)) * 0.5, 5.0)
		await _shot("wealth_poor_close")
		_view((_cell_center(7, 2) + _cell_center(10, 3)) * 0.5, 5.0)
		await _shot("wealth_rich_close")
		get_tree().quit(0)
		return
	_view(mid, 2.2)
	await _shot("overview")
	_view((_cell_center(0, 1) + _cell_center(3, 2)) * 0.5, 5.0)
	await _shot("early_close")
	_view((_cell_center(4, 1) + _cell_center(7, 2)) * 0.5, 5.0)
	await _shot("mid_close")
	_view((_cell_center(7, 2) + _cell_center(10, 3)) * 0.5, 5.0)
	await _shot("modern_close")
	_view((_cell_center(1, 4) + _cell_center(5, 5)) * 0.5, 5.0)
	await _shot("snow_close")
	_view(_cell_center(6, 2), 10.0)
	await _shot("city_zoom")
	_layer.set_day_night_enabled(true)
	var lon := fposmod((mid.x - world.world_bounds.position.x) / world.world_bounds.size.x, 1.0)
	_layer.set_day_phase(fposmod(lon + 0.5, 1.0))
	_view(mid, 2.2)
	await _shot("night_overview")
	_layer.set_day_phase(fposmod(lon + 0.21, 1.0))
	await _shot("dusk_overview")
	get_tree().quit(0)
