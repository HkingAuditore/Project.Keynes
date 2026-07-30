extends SceneTree

const VisualTileLayout = preload("res://scripts/rendering/visual_tile_layout.gd")


func _init() -> void:
	var failures: Array[String] = []
	_test_budget_and_aspect(failures)
	_test_device_clamp(failures)
	_test_extreme_aspects(failures)
	_test_compatibility_fallback(failures)
	_test_wrap_address(failures)
	_test_non_wrap_address(failures)
	_test_single_layer_tiled(failures)
	if failures.is_empty():
		print("visual_tile_layout_test: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_budget_and_aspect(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(-4.0, -2.0, 150.0, 100.0), 140.0, "high", false,
		{"mode": "tiled", "budget_mp": 8.0, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	_expect(layout.mode == "tiled", "desktop high unexpectedly fell back", failures)
	_expect(layout.layer_count <= 64, "layer cap exceeded", failures)
	_expect(layout.layer_size.x <= 516 and layout.layer_size.y <= 516,
		"layer edge exceeded", failures)
	_expect(layout.visual_domain.position.x == 0.0 and layout.visual_domain.size.x == 140.0,
		"wrap visual domain includes padding", failures)
	_expect(layout.wrap_x and layout.wrap_period_x == 140.0,
		"explicit wrap contract is missing", failures)
	_expect(layout.effective_budget_px >= 7_500_000,
		"effective budget lost too much resolution", failures)


func _test_device_clamp(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 100.0, 100.0), 0.0, "high", false,
		{"mode": "tiled", "budget_mp": 16.0, "max_array_layers": 4,
			"max_texture_size": 520, "resident_cap_mb": 24.0,
			"peak_cap_mb": 32.0, "rendering_method": "mobile"}
	)
	_expect(layout.layer_count <= 4 or layout.mode == "legacy",
		"device layer limit was ignored", failures)
	_expect(layout.estimated_resident_bytes <= 24 * 1024 * 1024 or layout.mode == "legacy",
		"resident cap was ignored", failures)


func _test_extreme_aspects(failures: Array[String]) -> void:
	var wide = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 800.0, 20.0), 0.0, "medium", false,
		{"mode": "tiled", "budget_mp": 1.0, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	var tall = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 20.0, 800.0), 0.0, "medium", false,
		{"mode": "tiled", "budget_mp": 1.0, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	_expect(wide.mode == "tiled" and wide.grid_size.x > wide.grid_size.y,
		"extreme wide layout lost its aspect", failures)
	_expect(tall.mode == "tiled" and tall.grid_size.y > tall.grid_size.x,
		"extreme tall layout lost its aspect", failures)
	_expect(wide.layer_count <= 64 and tall.layer_count <= 64,
		"extreme aspect exceeded layer cap", failures)


func _test_compatibility_fallback(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 100.0, 80.0), 100.0, "high", false,
		{"mode": "tiled", "budget_mp": 1.0,
			"rendering_method": "gl_compatibility"}
	)
	_expect(layout.mode == "legacy" and layout.fallback_reason == "compatibility_renderer",
		"Compatibility renderer did not force legacy", failures)


func _test_wrap_address(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(-5.0, -10.0, 110.0, 80.0), 100.0, "medium", false,
		{"mode": "tiled", "budget_mp": 1.0, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	var a: Dictionary = layout.world_to_tile_address(Vector2(-1.0, 0.0))
	var b: Dictionary = layout.world_to_tile_address(Vector2(99.0, 0.0))
	var c: Dictionary = layout.world_to_tile_address(Vector2(199.0, 0.0))
	_expect(a.layer == b.layer and b.layer == c.layer,
		"wrapped positions resolved to different layers", failures)
	_expect((a.local_uv as Vector2).distance_to(b.local_uv) < 1e-5,
		"wrapped positions resolved to different local UV", failures)
	var bottom: Dictionary = layout.world_to_tile_address(Vector2(20.0, -1000.0))
	var top: Dictionary = layout.world_to_tile_address(Vector2(20.0, 1000.0))
	_expect(float((bottom.global_uv as Vector2).y) == 0.0 \
		and float((top.global_uv as Vector2).y) > 0.999,
		"Y address did not clamp at visual-domain bounds", failures)


func _test_non_wrap_address(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(-50.0, -10.0, 100.0, 80.0), 0.0, "low", false,
		{"mode": "tiled", "budget_mp": 1.0, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	var left: Dictionary = layout.world_to_tile_address(Vector2(-50.0, 0.0))
	var right: Dictionary = layout.world_to_tile_address(Vector2(50.0, 0.0))
	_expect(not layout.wrap_x and layout.wrap_period_x == 0.0,
		"non-wrapped layout was marked wrapped", failures)
	_expect(left.layer != right.layer or left.local_uv != right.local_uv,
		"non-wrapped endpoints were folded together", failures)


func _test_single_layer_tiled(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 100.0, 80.0), 100.0, "low", false,
		{"mode": "tiled", "budget_mp": 0.05, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	_expect(layout.mode == "tiled" and layout.layer_count == 1,
		"N=1 did not retain the tiled contract", failures)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
