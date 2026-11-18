extends Node

const TerrainFogMesh = preload("res://scripts/rendering/terrain_fog_mesh.gd")
const DetailCulling = preload("res://scripts/rendering/fog_detail_culling.gd")
const MIN_TILE_SIZE := 96.0
const TILES_ACROSS_VIEW := 12.0

## Cull proven opaque terrain before submitting its draw commands.
var enabled := true
var partial_enabled := true
var detail_enabled := true
var _detail := DetailCulling.new()
var _last_visible_fog_buffer_size := Vector2i.ZERO
var _screen_rect: Rect2
var _screen_to_buffer: Transform2D
var _buffer_to_world: Transform2D
var _buffer_rect: Rect2
var _sample_padding: float
var _fog_bounds: Rect2
var _uses_blit: bool
var _terrain_canvas_transform: Transform2D

var _land_draw := TerrainFogMesh.DrawCommand.new()
var _water_draw := TerrainFogMesh.DrawCommand.new()
var _land_source: Mesh
var _water_source: Mesh
var _land_cut: Mesh
var _water_cut: Mesh
var _regions: Array[Rect2] = []
var _selection_key: Array = []
var _has_partial_coverage := false


func _enter_tree() -> void:
	name = "TerrainFogCulling"
	RenderingServer.frame_pre_draw.connect(_update_surface_visibility)


func _exit_tree() -> void:
	RenderingServer.frame_pre_draw.disconnect(_update_surface_visibility)
	_land_draw.detach()
	_water_draw.detach()
	_detail.clear()


func _update_surface_visibility() -> void:
	var host: Variant = get_parent()
	if host == null or host._world_quad == null:
		_detail.clear()
		return
	var land: MeshInstance2D = host._world_quad
	var water: MeshInstance2D = host._water_quad
	var fog: FogOfWarLayer = host._fog_layer
	var world: WorldData = host._world
	var fog_ready := false
	if enabled and host._fog_enabled and host.terrain_surface_debug_view == 0 \
			and host.terrain_horizon_debug_view == 0:
		fog_ready = _prepare_fog_view(fog, world)
	else:
		_last_visible_fog_buffer_size = Vector2i.ZERO
	var obscured := fog_ready and _covers_screen(_screen_rect, world, fog._hex_size)
	var draw_surface: bool = not obscured and not (host.PK_WEB_HIDE_WORLD_QUAD and OS.has_feature("web"))
	var show_land := draw_surface and not land.visible
	var show_water := draw_surface and water != null and not water.visible
	land.visible = draw_surface
	if water != null:
		water.visible = draw_surface
	var partial := draw_surface and fog_ready and partial_enabled and _prepare_partial_meshes(host, land, water, fog)
	if partial:
		_land_draw.submit(land, _land_cut, show_land)
		_water_draw.submit(water, _water_cut, show_water)
	else:
		_land_draw.submit(land, null, show_land)
		_water_draw.submit(water, null, show_water)
	if detail_enabled and (obscured or partial):
		var fog_draw: CanvasItem = fog._blit_sprite if _uses_blit else fog._mesh_inst
		_detail.update(host, fog_draw, _screen_rect, _covers_screen.bind(world, fog._hex_size),
			obscured, _terrain_canvas_transform, _regions)
	else:
		_detail.clear()


func _prepare_partial_meshes(host, land: MeshInstance2D, water: MeshInstance2D,
		fog: FogOfWarLayer) -> bool:
	if water == null or land.mesh != host._coverage_land_mesh or water.mesh != host._coverage_water_mesh \
			or not host._coverage_mesh_result.has("land_vertices"):
		return false
	var viewport := fog.get_viewport()
	var surfaces := land.get_viewport()
	if surfaces == null or surfaces != water.get_viewport() or land.get_canvas() != water.get_canvas():
		return false
	var surface_padding := 0.0
	if surfaces == viewport:
		_terrain_canvas_transform = land.get_global_transform_with_canvas()
		if land.get_canvas() != fog.get_canvas() \
				or water.get_global_transform_with_canvas() != _terrain_canvas_transform:
			return false
	else:
		var surface_parent: Node2D = host._graphics_details.scaled_surface_parent(land)
		if surface_parent == null or surface_parent.get_viewport() != viewport \
				or surface_parent.get_canvas() != fog.get_canvas() or water.get_parent() != land.get_parent() \
				or land.top_level or water.top_level or water.transform != land.transform:
			return false
		_terrain_canvas_transform = surface_parent.get_global_transform_with_canvas() * land.transform
		# A source texel can contribute to a neighbouring pixel through the terrain blit's linear filter.
		var texel := _screen_rect.size / surfaces.get_visible_rect().size
		surface_padding = maxf(texel.x, texel.y)
	var to_screen := viewport.get_global_canvas_transform() * _terrain_canvas_transform
	if not to_screen.is_finite() or is_zero_approx(to_screen.determinant()):
		return false
	var world: WorldData = host._world
	# A new upload may still have a pending source image when the full screen
	# reaches outside the fog geometry and the first proof skips the index.
	var key := [world.cell_table_fog_coverage_source, world.cell_table_fog_coverage,
		land.mesh, water.mesh, to_screen, _screen_rect, _screen_to_buffer, _buffer_to_world,
		_buffer_rect, _sample_padding, _fog_bounds, _uses_blit, fog._hex_size, surface_padding]
	if key == _selection_key:
		return _has_partial_coverage
	_selection_key = key
	var view := to_screen.affine_inverse() * _screen_rect.grow(surface_padding)
	var regions := _visible_regions(view, to_screen, world, fog._hex_size, surface_padding)
	_has_partial_coverage = not regions.is_empty()
	if not _has_partial_coverage:
		return false
	if regions != _regions or land.mesh != _land_source or water.mesh != _water_source:
		_land_source = land.mesh
		_water_source = water.mesh
		_regions = regions
		_land_cut = TerrainFogMesh.clip(host._coverage_mesh_result["land_vertices"], regions)
		_water_cut = TerrainFogMesh.clip(host._coverage_mesh_result["water_vertices"], regions)
	return true


func _visible_regions(view: Rect2, to_screen: Transform2D, world: WorldData,
		hex_size: float, surface_padding: float) -> Array[Rect2]:
	# Use larger world tiles when zoomed far out. World-aligned edges let the
	# draw meshes survive small camera movements without a geometry upload.
	var tile := MIN_TILE_SIZE
	while maxf(view.size.x, view.size.y) > tile * TILES_ACROSS_VIEW:
		tile *= 2.0
	var origin := Vector2(0.0, world.world_bounds.position.y)
	var first := Vector2i(((view.position - origin) / tile).floor())
	var end := Vector2i(((view.end - origin) / tile).ceil())
	var kept: Array[Rect2] = []
	var removed := false
	for y in range(first.y, end.y):
		var start := first.x
		for x in range(first.x, end.x):
			var rect := Rect2(origin + Vector2(x, y) * tile, Vector2.ONE * tile)
			var samples := (to_screen * rect).grow(surface_padding).intersection(_screen_rect)
			if samples.has_area() and _covers_screen(samples, world, hex_size):
				if x > start:
					kept.append(Rect2(origin + Vector2(start, y) * tile, Vector2(x - start, 1) * tile))
				start = x + 1
				removed = true
		if end.x > start:
			kept.append(Rect2(origin + Vector2(start, y) * tile, Vector2(end.x - start, 1) * tile))
	if removed:
		return kept
	return []


func _covers_screen(screen_region: Rect2, world: WorldData, hex_size: float) -> bool:
	var samples := (_screen_to_buffer * screen_region).grow(_sample_padding)
	if _uses_blit:
		samples = samples.intersection(_buffer_rect)
	var world_samples := _buffer_to_world * samples
	return _fog_bounds.encloses(world_samples) and world.fog_covers_surface(world_samples, hex_size)


## Only the cell-field path has a bounded set of candidate cells in world space.
## Use its published texture bytes and the canvas transforms for the upcoming draw.
func _prepare_fog_view(fog: FogOfWarLayer, world: WorldData) -> bool:
	var previous_buffer_size := _last_visible_fog_buffer_size
	_last_visible_fog_buffer_size = Vector2i.ZERO
	if fog == null or not fog.is_visible_in_tree() or not fog._built_cell_field or world == null \
			or not world.cell_table_bound \
			or not fog._cell_field_sig.get("bound", false) \
			or fog._cell_field_sig.get("table") != world.cell_table_tex \
			or fog._cell_field_sig.get("dims") != world.cell_table_dims:
		return false
	if fog._shader_mat == null or fog._mesh_inst == null or fog._mesh_inst.mesh == null \
			or fog._mesh_inst.material != fog._shader_mat or not fog._mesh_inst.is_visible_in_tree():
		return false
	if fog._mesh_inst.modulate.a != 1.0 or fog._mesh_inst.self_modulate.a != 1.0 \
			or fog.modulate.a != 1.0:
		return false
	var debug_view: Variant = fog._shader_mat.get_shader_parameter("fog_debug_view")
	if debug_view != null and int(debug_view) != 0:
		return false

	var viewport := fog.get_viewport()
	var fog_viewport := fog._mesh_inst.get_viewport()
	if viewport == null or fog_viewport == null \
			or (fog._mesh_inst.visibility_layer & fog_viewport.canvas_cull_mask) == 0:
		return false
	_screen_rect = viewport.get_visible_rect()
	if not _screen_rect.has_area():
		return false
	_screen_to_buffer = Transform2D.IDENTITY
	_sample_padding = 1.0
	_uses_blit = fog._sub_viewport != null
	_buffer_rect = fog_viewport.get_visible_rect()
	if _uses_blit:
		if fog._blit_sprite == null or not fog._blit_sprite.is_visible_in_tree() \
				or (fog._blit_sprite.visibility_layer & viewport.canvas_cull_mask) == 0 \
				or fog._blit_sprite.modulate.a != 1.0 or fog._blit_sprite.self_modulate.a != 1.0:
			return false
		var blit_to_screen := viewport.get_global_canvas_transform() \
			* fog._blit_sprite.get_global_transform_with_canvas()
		if not blit_to_screen.is_finite() or blit_to_screen.x.x <= 0.0 or blit_to_screen.y.y <= 0.0 \
				or blit_to_screen.x.y != 0.0 or blit_to_screen.y.x != 0.0 \
				or not (blit_to_screen * fog._blit_sprite.get_rect()).encloses(_screen_rect.grow(-0.001)):
			return false
		# UPDATE_WHEN_VISIBLE starts drawing after the parent has used the texture.
		# Keep the ground for the first blit and whenever the target has been resized.
		_last_visible_fog_buffer_size = fog._sub_viewport.size
		if fog._sub_viewport.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
			if fog._sub_viewport.render_target_update_mode != SubViewport.UPDATE_WHEN_VISIBLE \
					or previous_buffer_size != fog._sub_viewport.size:
				return false
		_screen_to_buffer = blit_to_screen.affine_inverse()
	else:
		var scale := viewport.get_stretch_transform().get_scale().abs()
		var min_scale := minf(scale.x, scale.y)
		if min_scale <= 0.0:
			return false
		_sample_padding = maxf(1.0, 1.0 / min_scale)

	var fog_to_screen := fog_viewport.get_global_canvas_transform() \
		* fog._mesh_inst.get_global_transform_with_canvas()
	if not fog_to_screen.is_finite() or is_zero_approx(fog_to_screen.determinant()):
		return false
	_buffer_to_world = fog_to_screen.affine_inverse()
	_fog_bounds = fog._bounds
	if fog._wrap_period_x > 0.0001:
		if not is_equal_approx(fog._wrap_period_x, HexUtils.wrap_period_x(world.cell_table_dims.x, fog._hex_size)):
			return false
		_fog_bounds.position.x = -fog._wrap_period_x
		_fog_bounds.size.x = 3.0 * fog._wrap_period_x
	return true
