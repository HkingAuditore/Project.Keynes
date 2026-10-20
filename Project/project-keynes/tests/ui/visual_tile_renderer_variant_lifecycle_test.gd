extends SceneTree

var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var renderer := HexRenderer.new()
	root.add_child(renderer)
	await process_frame

	var world := WorldData.new()
	var layout := VisualTileLayout.new()
	layout.mode = VisualTileLayout.MODE_TILED
	var tiles := VisualTileSet.new()
	tiles.layout = layout
	tiles.ready = true
	tiles.horizon_ready = true
	world.visual_tiles = tiles

	renderer.set_map(null, world)
	_expect(_shader_has_define(renderer, "MAP_VISUAL_TILED"),
		"set_map reloads the tiled shader after world injection")

	world.visual_tiles = null
	renderer.set_map(null, world)
	_expect(not _shader_has_define(renderer, "MAP_VISUAL_TILED"),
		"set_map restores the legacy shader when tiled visuals are absent")

	renderer.queue_free()
	await process_frame
	print("visual_tile_renderer_variant_lifecycle_test: %s" %
		("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(0 if _failures == 0 else 1)


func _shader_has_define(renderer: HexRenderer, define_name: String) -> bool:
	if renderer._shader_mat == null or renderer._shader_mat.shader == null:
		return false
	return renderer._shader_mat.shader.code.begins_with("#define %s\n" % define_name)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  [PASS] %s" % label)
		return
	_failures += 1
	push_error("  [FAIL] %s" % label)
