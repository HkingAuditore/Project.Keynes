extends SceneTree

const VisualTileLayout = preload("res://scripts/rendering/visual_tile_layout.gd")
const VisualTileSet = preload("res://scripts/rendering/visual_tile_set.gd")
const VisualTileHorizonBaker = preload(
	"res://scripts/rendering/visual_tile_horizon_baker.gd")

var _baker


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var layout = VisualTileLayout.new()
	layout.mode = VisualTileLayout.MODE_TILED
	layout.visual_domain = Rect2(0.0, 0.0, 64.0, 32.0)
	layout.wrap_x = true
	layout.wrap_period_x = 64.0
	layout.grid_size = Vector2i(2, 1)
	layout.layer_count = 2
	layout.interior_size = Vector2i(32, 32)
	layout.gutter_px = 2
	layout.layer_size = Vector2i(36, 36)
	layout.logical_size = Vector2i(64, 32)
	layout.generation_id = 7

	var tiles = VisualTileSet.new()
	if not tiles.initialize_empty(layout):
		push_error("visual_tile_horizon_smoke_test: tile allocation failed")
		quit(1)
		return
	for layer_id in range(layout.layer_count):
		var data := PackedByteArray()
		data.resize(layout.layer_size.x * layout.layer_size.y * 2)
		for y in range(layout.layer_size.y):
			for x in range(layout.layer_size.x):
				var global_x: int = posmod(layer_id * layout.interior_size.x + x - layout.gutter_px,
					layout.logical_size.x)
				var global_y: int = clampi(y - layout.gutter_px, 0, layout.logical_size.y - 1)
				var ridge: float = 0.82 if abs(global_x - 16) <= 1 else 0.35
				var h: float = clampf(ridge + float(global_y) * 0.001, 0.0, 1.0)
				var encoded: int = clampi(int(round(h * 65535.0)), 0, 65535)
				var offset: int = (y * layout.layer_size.x + x) * 2
				data[offset] = (encoded >> 8) & 0xFF
				data[offset + 1] = encoded & 0xFF
		var image := Image.create_from_data(layout.layer_size.x, layout.layer_size.y,
			false, Image.FORMAT_RG8, data)
		tiles.height.update_layer(image, layer_id)

	_baker = VisualTileHorizonBaker.new()
	_baker.start(tiles, layout.generation_id, {
		"height_world_scale": 176.0,
		"bias": 0.004,
		"max_horizon_angle": 1.309,
		"max_iterations": 2048,
	})
	var result: Array = await _baker.completed
	var success: bool = bool(result[0])
	var report: Dictionary = result[1]
	if not success:
		push_error("visual_tile_horizon_smoke_test: compute failed: %s" % JSON.stringify(report))
		quit(1)
		return
	var first: Image = tiles.horizon.get_layer_data(0)
	var last: Image = tiles.horizon.get_layer_data(1)
	var first_bytes := first.get_data()
	var nonzero := false
	for byte in first_bytes:
		if byte != 0:
			nonzero = true
			break
	var y: int = layout.gutter_px + layout.interior_size.y / 2
	var ordinary_ok := first.get_pixel(layout.gutter_px + layout.interior_size.x, y) \
		== last.get_pixel(layout.gutter_px, y)
	var wrap_ok := first.get_pixel(0, y) \
		== last.get_pixel(layout.gutter_px + layout.interior_size.x - 2, y)
	if not nonzero or not ordinary_ok or not wrap_ok:
		push_error("visual_tile_horizon_smoke_test: output mismatch nonzero=%s ordinary=%s wrap=%s" % [
			nonzero, ordinary_ok, wrap_ok])
		quit(1)
		return
	print("visual_tile_horizon_smoke_test: PASS %s" % JSON.stringify(report))
	quit(0)
