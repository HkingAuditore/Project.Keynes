extends SceneTree

const VisualTileLayout = preload("res://scripts/rendering/visual_tile_layout.gd")


func _init() -> void:
	var failures: Array[String] = []
	_test_world_area_scaling(failures)
	_test_device_profiles(failures)
	_test_budget_cap_is_secondary(failures)
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


func _test_world_area_scaling(failures: Array[String]) -> void:
	var common := {
		"mode": "tiled", "hex_size": 20.0, "texels_per_hex": 8.0,
		"max_array_layers": 64, "max_texture_size": 4096,
		"resident_cap_mb": 512.0, "peak_cap_mb": 768.0,
		"rendering_method": "mobile",
	}
	var base = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 2000.0, 1200.0), 0.0, "medium", false, common)
	var doubled = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 4000.0, 2400.0), 0.0, "medium", false, common)
	_expect(base.mode == "tiled" and doubled.mode == "tiled",
		"area-derived layouts unexpectedly fell back", failures)
	_expect(base.grid_size == Vector2i(2, 1) and doubled.grid_size == Vector2i(4, 2),
		"grid was not derived from per-tile world coverage", failures)
	_expect(doubled.layer_count == base.layer_count * 4,
		"doubling both world axes did not quadruple layer count", failures)
	_expect((base.tile_world_span as Vector2).distance_to(doubled.tile_world_span) < 0.001,
		"device tile world coverage changed with map size", failures)
	_expect(absf(base.effective_texels_per_hex - doubled.effective_texels_per_hex) < 0.001,
		"world-space visual density changed with map size", failures)


func _test_device_profiles(failures: Array[String]) -> void:
	# Current large preset: width=100, height=64, hex_size=22.
	var wrap_period := 100.0 * sqrt(3.0) * 22.0
	var bounds := Rect2(-44.0, -44.0, wrap_period + 88.0, 2211.0)
	var common := {
		"mode": "tiled", "hex_size": 22.0, "max_array_layers": 64,
		"max_texture_size": 4096, "rendering_method": "mobile",
	}
	var desktop_auto = VisualTileLayout.resolve(
		bounds, wrap_period, "auto", false, common)
	var desktop_high = VisualTileLayout.resolve(
		bounds, wrap_period, "high", false, common)
	var mobile_high = VisualTileLayout.resolve(
		bounds, wrap_period, "high", true, common)
	_expect(desktop_auto.profile == "desktop_auto"
		and desktop_auto.requested_texels_per_hex == 14.0,
		"desktop auto profile density changed", failures)
	_expect(desktop_auto.grid_size == Vector2i(5, 3)
		and desktop_auto.layer_count == 15
		and desktop_auto.logical_size == Vector2i(2440, 1416),
		"desktop auto no longer resolves the large preset to the expected coverage", failures)
	_expect(desktop_high.requested_texels_per_hex == 16.0
		and desktop_high.grid_size == Vector2i(6, 4)
		and desktop_high.layer_count == 24,
		"desktop high profile layout changed", failures)
	_expect(mobile_high.requested_texels_per_hex == 10.0
		and mobile_high.grid_size == Vector2i(4, 2)
		and mobile_high.layer_count == 8,
		"mobile high profile layout changed", failures)
	_expect(desktop_auto.requested_tile_world_span.x > 0.0
		and desktop_auto.tile_world_area > 0.0,
		"tile world coverage diagnostics are missing", failures)


func _test_budget_cap_is_secondary(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 3000.0, 1800.0), 0.0, "high", false,
		{"mode": "tiled", "hex_size": 20.0, "texels_per_hex": 16.0,
			"budget_mp": 1.0, "max_array_layers": 64,
			"max_texture_size": 4096, "rendering_method": "mobile"}
	)
	_expect(layout.mode == "tiled", "whole-map compatibility cap caused fallback", failures)
	_expect(layout.requested_texels_per_hex == 16.0,
		"whole-map cap replaced the requested device density", failures)
	_expect(layout.effective_budget_px <= 1_100_000,
		"whole-map compatibility cap was not enforced", failures)
	_expect(layout.degradation_reason.contains("whole_map_budget_cap"),
		"whole-map cap degradation was not diagnosed", failures)


func _test_device_clamp(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 4000.0, 3000.0), 0.0, "high", false,
		{"mode": "tiled", "hex_size": 20.0, "texels_per_hex": 24.0,
			"max_array_layers": 4, "max_texture_size": 520,
			"resident_cap_mb": 24.0, "peak_cap_mb": 32.0,
			"rendering_method": "mobile"}
	)
	_expect(layout.layer_count <= 4 or layout.mode == "legacy",
		"device layer limit was ignored", failures)
	_expect(layout.estimated_resident_bytes <= 24 * 1024 * 1024 or layout.mode == "legacy",
		"resident cap was ignored", failures)
	_expect(layout.mode == "legacy" or layout.effective_texels_per_hex < layout.requested_texels_per_hex,
		"device clamp did not reduce world-space density", failures)
	_expect(not layout.degradation_reason.is_empty(),
		"device density degradation has no reason", failures)


func _test_extreme_aspects(failures: Array[String]) -> void:
	var common := {
		"mode": "tiled", "hex_size": 10.0, "texels_per_hex": 8.0,
		"max_array_layers": 64, "max_texture_size": 4096,
		"rendering_method": "mobile",
	}
	var wide = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 800.0, 20.0), 0.0, "medium", false, common)
	var tall = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 20.0, 800.0), 0.0, "medium", false, common)
	_expect(wide.mode == "tiled" and wide.grid_size.x > wide.grid_size.y,
		"extreme wide layout lost its aspect", failures)
	_expect(tall.mode == "tiled" and tall.grid_size.y > tall.grid_size.x,
		"extreme tall layout lost its aspect", failures)
	_expect(wide.layer_count <= 64 and tall.layer_count <= 64,
		"extreme aspect exceeded layer cap", failures)


func _test_compatibility_fallback(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(0.0, 0.0, 100.0, 80.0), 100.0, "high", false,
		{"mode": "tiled", "hex_size": 20.0,
			"rendering_method": "gl_compatibility"}
	)
	_expect(layout.mode == "legacy" and layout.fallback_reason == "compatibility_renderer",
		"Compatibility renderer did not force legacy", failures)


func _test_wrap_address(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(-5.0, -10.0, 110.0, 80.0), 100.0, "medium", false,
		{"mode": "tiled", "hex_size": 10.0, "texels_per_hex": 8.0,
			"max_array_layers": 64, "max_texture_size": 4096,
			"rendering_method": "mobile"}
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
	_expect(float((bottom.global_uv as Vector2).y) == 0.0
		and float((top.global_uv as Vector2).y) > 0.999,
		"Y address did not clamp at visual-domain bounds", failures)


func _test_non_wrap_address(failures: Array[String]) -> void:
	var layout = VisualTileLayout.resolve(
		Rect2(-50.0, -10.0, 100.0, 80.0), 0.0, "low", false,
		{"mode": "tiled", "hex_size": 10.0, "texels_per_hex": 8.0,
			"max_array_layers": 64, "max_texture_size": 4096,
			"rendering_method": "mobile"}
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
		{"mode": "tiled", "hex_size": 20.0, "texels_per_hex": 6.0,
			"max_array_layers": 64, "max_texture_size": 4096,
			"rendering_method": "mobile"}
	)
	_expect(layout.mode == "tiled" and layout.layer_count == 1,
		"N=1 did not retain the tiled contract", failures)


func _expect(condition: bool, message: String, failures: Array[String]) -> void:
	if not condition:
		failures.append(message)
