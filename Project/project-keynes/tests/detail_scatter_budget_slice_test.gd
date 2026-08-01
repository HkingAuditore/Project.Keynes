extends SceneTree

# Headless:
#   godot --headless --path Project/project-keynes --script res://tests/detail_scatter_budget_slice_test.gd

const HexRendererScript := preload("res://scripts/rendering/hex_renderer.gd")
const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")
const MANIFEST_PATH := "res://data/visual/world_decoration_manifest.tres"
const SEAGRASS_PATH := "res://data/visual/seagrass_default.tres"

var _checks: int = 0
var _failures: int = 0


class ForcedRefreshLayer:
	extends Node
	var refresh_calls: int = 0

	func refresh_for_succession(_indices: PackedInt32Array) -> void:
		refresh_calls += 1


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var renderer = HexRendererScript.new()
	renderer.detail_scatter_refresh_layers_per_frame = 1
	renderer.detail_scatter_desktop_total_instance_budget = 150
	renderer.detail_scatter_rebuild_log_enabled = false
	for i in range(3):
		var layer = ShrubLayerScript.new()
		layer.name = "BudgetLayer%d" % i
		layer._instance_count = 100
		renderer.add_child(layer)
		renderer._detail_layers.append(layer)

	renderer._detail_budget_applied_fraction = 1.0
	renderer._apply_detail_global_budget(false, true)
	_expect("first frame applies only one layer",
		renderer._detail_budget_apply_active
		and renderer._detail_budget_apply_cursor == 1
		and renderer._detail_budget_apply_count == 1)
	_expect("first layer receives the 0.5 budget fraction",
		is_equal_approx(renderer._detail_layers[0]._shadow_fraction, 0.5))
	_expect("remaining layers wait for later frames",
		is_equal_approx(renderer._detail_layers[1]._shadow_fraction, 1.0)
		and is_equal_approx(renderer._detail_layers[2]._shadow_fraction, 1.0))

	renderer._apply_detail_global_budget(false, true)
	renderer._apply_detail_global_budget(false, true)
	_expect("three frames finish the three-layer budget pass",
		not renderer._detail_budget_apply_active
		and renderer._detail_budget_apply_count == 3
		and is_equal_approx(renderer._detail_budget_applied_fraction, 0.5))
	_expect("all layers converge on the same budget fraction",
		is_equal_approx(renderer._detail_layers[1]._shadow_fraction, 0.5)
		and is_equal_approx(renderer._detail_layers[2]._shadow_fraction, 0.5))

	var applied_before: int = int(renderer._detail_budget_apply_count)
	var scans_before: int = int(renderer._detail_budget_total_scan_count)
	renderer._apply_detail_global_budget(false, true)
	_expect("unchanged fraction skips another full traversal",
		renderer._detail_budget_apply_count == applied_before
		and renderer._detail_budget_apply_skip_count > 0)
	_expect("unchanged budget reuses the cached visible total",
		renderer._detail_budget_total_scan_count == scans_before
		and is_zero_approx(renderer._detail_budget_last_scan_ms))
	renderer._mark_detail_budget_total_dirty()
	renderer._apply_detail_global_budget(false, false)
	_expect("dirty budget performs exactly one new total scan",
		renderer._detail_budget_total_scan_count == scans_before + 1)

	var cache_layer = ShrubLayerScript.new()
	cache_layer._map = _make_cache_map(4, 4)
	cache_layer._hex_size = 10.0
	cache_layer._chunk_size_cells = 2
	var bounds_a: Rect2 = cache_layer._chunk_world_bounds(0)
	var bounds_b: Rect2 = cache_layer._chunk_world_bounds(0)
	_expect("chunk geometry is built once and reused",
		bounds_a == bounds_b
		and cache_layer._chunk_cell_cache_builds == 1
		and cache_layer._chunk_bounds_cache_builds == 1)
	cache_layer._hex_size = 20.0
	cache_layer._invalidate_chunk_spatial_cache()
	var bounds_scaled: Rect2 = cache_layer._chunk_world_bounds(0)
	_expect("chunk geometry cache invalidates when map scale changes",
		cache_layer._chunk_bounds_cache_builds == 2
		and bounds_scaled.size.x > bounds_a.size.x)

	var chunk_node := MultiMeshInstance2D.new()
	var chunk_mm := MultiMesh.new()
	chunk_mm.instance_count = 100
	chunk_node.multimesh = chunk_mm
	cache_layer._chunk_nodes[0] = chunk_node
	cache_layer._chunk_instance_counts[0] = 100
	cache_layer._camera_view_initialized = true
	cache_layer._camera_view_rect = Rect2(Vector2(-1000, -1000), Vector2(2000, 2000))
	cache_layer._zoom_visible_fraction = 1.0
	var active_a: int = cache_layer.active_instance_count()
	var active_b: int = cache_layer.active_instance_count()
	_expect("active instance count is cached between unchanged budget scans",
		active_a == 100 and active_b == 100
		and cache_layer._active_instance_count_scans == 1)
	cache_layer._chunk_nodes.clear()
	chunk_node.free()
	cache_layer.free()

	var manifest = load(MANIFEST_PATH)
	var paths: Array[String] = []
	if manifest != null and manifest.has_method("valid_layers"):
		for profile in manifest.valid_layers():
			paths.append(str(profile.resource_path))
	_expect("default manifest keeps twenty visual layers", paths.size() == 20)
	_expect("default manifest no longer spawns seagrass coverage",
		not paths.has(SEAGRASS_PATH))

	# 等待超时只允许打破预算推进一个任务；不能让整队超时任务同帧倾泻。
	renderer._detail_layers.clear()
	var forced_layer := ForcedRefreshLayer.new()
	renderer.add_child(forced_layer)
	renderer._detail_layers.append(forced_layer)
	renderer.detail_scatter_refresh_chunks_per_frame = 4
	renderer.detail_scatter_refresh_apply_budget_ms = 2.5
	renderer._drain_credit_ms = 0.0
	var old_msec := Time.get_ticks_msec() - 1000
	for i in range(4):
		renderer._detail_refresh_queue.append({
			"layer": forced_layer,
			"cell_indices": PackedInt32Array([i]),
			"enqueued_msec": old_msec,
			"visible_priority": true,
		})
	renderer._drain_detail_refresh_queue()
	_expect("visible timeout forces exactly one task per frame",
		forced_layer.refresh_calls == 1 and renderer._detail_refresh_queue.size() == 3)

	renderer._detail_layers.clear()
	renderer.free()
	print("=== detail scatter budget slice: %d checks, %d failures ===" % [_checks, _failures])


func _make_cache_map(width: int, height: int) -> MapData:
	var map := MapData.new(width, height)
	var pos_x := PackedFloat32Array()
	var pos_y := PackedFloat32Array()
	pos_x.resize(width * height)
	pos_y.resize(width * height)
	for row in range(height):
		for col in range(width):
			var idx := row * width + col
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.index = idx
			map.set_cell(cell)
			pos_x[idx] = float(col)
			pos_y[idx] = float(row)
	map.cell_pos_x_arr = pos_x
	map.cell_pos_y_arr = pos_y
	return map


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
