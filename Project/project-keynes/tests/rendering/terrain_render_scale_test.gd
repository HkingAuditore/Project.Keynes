extends SceneTree

const TerrainRenderScale = preload("res://scripts/rendering/terrain_render_scale.gd")

class LeftFog extends "res://scripts/rendering/renderer_fog_culling.gd":
	func _covers_screen(region: Rect2, _world: WorldData, _hex_size: float) -> bool:
		return region.end.x <= _screen_rect.get_center().x

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var output := SubViewport.new()
	output.size = Vector2i(200, 100)
	output.disable_3d = true
	output.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(output)
	var renderer := Node2D.new()
	output.add_child(renderer)
	output.canvas_transform = Transform2D(0.0, Vector2(20, 0))
	var land := _add_surface(renderer, Color.RED, Vector2(50, 50))
	var water := _add_surface(renderer, Color.BLUE, Vector2(110, 50))
	var marker := _add_surface(renderer, Color.GREEN, Vector2(110, 50))
	marker.scale = Vector2(0.2, 0.2)
	marker.z_index = 9
	var scale := TerrainRenderScale.new()
	renderer.add_child(scale)

	scale.apply(land, 100, Viewport.MSAA_DISABLED)
	scale.attach_water(water)
	_check(land.get_parent() == renderer and water.get_parent() == renderer, "100% draws directly")
	for percent in [90, 85, 75]:
		scale.apply(land, percent, Viewport.MSAA_DISABLED)
		scale.attach_water(water)
		var target := land.get_parent() as SubViewport
		_check(target != null and target.size == Vector2i(2 * percent, percent),
			"terrain renders at %d%%" % percent)
		_check(water.get_parent() == target and water.get_index() == land.get_index() + 1,
			"water follows land in the scaled viewport")
		_check(marker.get_parent() == renderer, "marker stays on the main canvas")
		if DisplayServer.get_name() != "headless":
			await process_frame
			await RenderingServer.frame_post_draw
			var image := output.get_texture().get_image()
			_check(image.get_pixel(70, 50).is_equal_approx(Color.RED), "land follows camera")
			_check(image.get_pixel(130, 50).is_equal_approx(Color.GREEN), "marker overlaps water")
			_check(image.get_pixel(141, 50).is_equal_approx(Color.BLUE), "water follows camera")

	output.size = Vector2i(240, 160)
	output.canvas_transform = Transform2D(0.0, Vector2(30, 16))
	var replacement := _add_surface(renderer, Color.BLUE, Vector2(110, 50))
	water.queue_free()
	scale.attach_water(replacement)
	scale.apply(land, 75, Viewport.MSAA_DISABLED)
	_check((land.get_parent() as SubViewport).size == Vector2i(180, 120), "matches viewport resize")
	if DisplayServer.get_name() != "headless":
		await process_frame
		await RenderingServer.frame_post_draw
		var image := output.get_texture().get_image()
		_check(image.get_pixel(80, 66).is_equal_approx(Color.RED), "land follows pan after resize")
		_check(image.get_pixel(140, 66).is_equal_approx(Color.GREEN), "marker remains aligned")
		_check(image.get_pixel(151, 66).is_equal_approx(Color.BLUE), "replacement water renders")

	scale.apply(land, 100, Viewport.MSAA_DISABLED)
	_check(land.get_parent() == renderer and replacement.get_parent() == renderer,
		"returning to 100% restores both surfaces")
	_check(renderer.get_node_or_null("TerrainBlit") == null, "100% releases the blit")
	_check(replacement.get_index() == land.get_index() + 1, "direct draw order is restored")
	_check_scaled_fog(output, renderer, scale, land, replacement)
	output.queue_free()
	await process_frame
	print("terrain render scale: %d failures" % _failures)
	quit(0 if _failures == 0 else 1)


func _check_scaled_fog(output: SubViewport, renderer: Node2D, scale: TerrainRenderScale,
		land: MeshInstance2D, water: MeshInstance2D) -> void:
	var fog := FogOfWarLayer.new()
	renderer.add_child(fog)
	var culler := LeftFog.new()
	culler._screen_rect = output.get_visible_rect()
	var graphics := preload("res://scripts/rendering/renderer_graphics_settings.gd").new()
	graphics._terrain_scale = scale
	var vertices := PackedVector2Array([Vector2(-192, -192), Vector2(384, -192),
		Vector2(384, 192), Vector2(-192, 192)])
	var host := {"_graphics_details": graphics, "_coverage_land_mesh": land.mesh,
		"_coverage_water_mesh": water.mesh, "_world": WorldData.new(),
		"_coverage_mesh_result": {"land_vertices": vertices, "water_vertices": vertices}}
	renderer.position = Vector2(17, 3)
	land.position = Vector2(-6, 8)
	water.position = land.position
	var expected := land.get_global_transform_with_canvas()
	for percent in [100, 85, 75, 100]:
		scale.apply(land, percent, Viewport.MSAA_DISABLED)
		scale.attach_water(water)
		_check(culler._prepare_partial_meshes(host, land, water, fog)
			and culler._terrain_canvas_transform.is_equal_approx(expected),
			"partial fog uses the original map coordinates at %d%%" % percent)
		var visible_point := expected.affine_inverse() * Vector2(220, 80)
		var hidden_point := expected.affine_inverse() * Vector2(18, 80)
		_check(culler._regions.any(func(rect: Rect2) -> bool: return rect.has_point(visible_point))
			and not culler._regions.any(func(rect: Rect2) -> bool: return rect.has_point(hidden_point)),
			"the same exposed and covered regions survive resizing to %d%%" % percent)
	culler.free()


func _add_surface(parent: Node2D, color: Color, center: Vector2) -> MeshInstance2D:
	var node := MeshInstance2D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(60, 60)
	node.mesh = quad
	node.modulate = color
	node.position = center
	parent.add_child(node)
	return node


func _check(ok: bool, description: String) -> void:
	if not ok:
		_failures += 1
		push_error(description)
