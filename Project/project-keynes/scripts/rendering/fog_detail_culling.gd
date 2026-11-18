extends RefCounted

const FogMesh = preload("res://scripts/rendering/terrain_fog_mesh.gd")
const Bounds = preload("res://scripts/rendering/fog_draw_bounds.gd")

var _hidden: Dictionary[int, bool] = {}
var _next_hidden: Dictionary[int, bool] = {}
var _ground := ClippedOverlay.new()
var _macro := ClippedOverlay.new()


func update(host, fog_draw: CanvasItem, screen: Rect2, covers: Callable,
		whole_screen: bool, terrain: MeshInstance2D = null,
		kept: Array[Rect2] = []) -> void:
	if not _unclipped_fog(fog_draw):
		clear()
		return
	_next_hidden.clear()
	var fog_z := _draw_z(fog_draw)
	for layer in host._detail_layers:
		_consider_batches(layer, fog_draw, fog_z, screen, covers, whole_screen)
	_consider_batches(host._detail_family_layer, fog_draw, fog_z, screen, covers, whole_screen)
	_consider_batches(host._resource_visual_layer, fog_draw, fog_z, screen, covers, whole_screen)
	_consider_batches(host._building_visual_layer, fog_draw, fog_z, screen, covers, whole_screen)
	var cover: MeshInstance2D
	var macro: MeshInstance2D
	if host._resource_visual_layer != null:
		var ground_cover = host._resource_visual_layer.ground_cover()
		if ground_cover != null:
			cover = ground_cover._mesh_inst
	if host._building_visual_layer != null:
		macro = host._building_visual_layer._macro_quad
	_update_plane(_ground, cover, fog_draw, fog_z, whole_screen, terrain, kept)
	_update_plane(_macro, macro, fog_draw, fog_z, whole_screen, terrain, kept)
	for id in _hidden:
		if not _next_hidden.has(id):
			_restore(id)
	var previous := _hidden
	_hidden = _next_hidden
	_next_hidden = previous


func clear() -> void:
	_ground.clear()
	_macro.clear()
	for id in _hidden:
		_restore(id)
	_hidden.clear()
	_next_hidden.clear()


func _consider_batches(layer: Node2D, fog_draw: CanvasItem, fog_z: int,
		screen: Rect2, covers: Callable, whole_screen: bool) -> void:
	if layer == null or not layer.is_visible_in_tree():
		return
	for item in layer.get_children():
		if item is MultiMeshInstance2D:
			_consider(item, fog_draw, fog_z, screen, covers, whole_screen)


func _consider(item: CanvasItem, fog_draw: CanvasItem, fog_z: int, screen: Rect2,
		covers: Callable, whole_screen: bool) -> void:
	if not _below_fog(item, fog_draw, fog_z):
		return
	if not whole_screen:
		var local := Bounds.local_rect(item)
		if not local.has_area():
			return
		var to_screen := item.get_viewport().get_global_canvas_transform() \
			* item.get_global_transform_with_canvas()
		var pixels := (to_screen * local).intersection(screen)
		if not pixels.has_area() or not covers.call(pixels):
			return
	_hide(item)


func _update_plane(plane: ClippedOverlay, item: MeshInstance2D, fog: CanvasItem, fog_z: int,
		whole_screen: bool, terrain: MeshInstance2D, kept: Array[Rect2]) -> void:
	if not _below_fog(item, fog, fog_z):
		plane.clear()
	elif whole_screen:
		plane.clear()
		_hide(item)
	elif terrain != null and item.get_viewport() == terrain.get_viewport():
		plane.clip(item, terrain, kept)
	else:
		plane.clear()


func _hide(item: CanvasItem) -> void:
	# The layer retains ownership of Node.visible and its LOD counts. Apply
	# the extra visibility filter after it has prepared this frame's drawing.
	RenderingServer.canvas_item_set_visible(item.get_canvas_item(), false)
	_next_hidden[item.get_instance_id()] = true


static func _below_fog(item: CanvasItem, fog_draw: CanvasItem, fog_z: int) -> bool:
	return item != null and item.is_visible_in_tree() and item.get_viewport() == fog_draw.get_viewport() \
		and item.get_canvas() == fog_draw.get_canvas() and _draw_z(item) < fog_z


static func _unclipped_fog(item: CanvasItem) -> bool:
	while item != null:
		if item.modulate.a != 1.0 or item.clip_children != CanvasItem.CLIP_CHILDREN_DISABLED:
			return false
		item = item.get_parent() as CanvasItem
	return true


static func _draw_z(item: CanvasItem) -> int:
	var z := item.z_index
	var parent := item.get_parent() as CanvasItem
	if item.z_as_relative and not item.top_level and parent != null:
		z += _draw_z(parent)
	return clampi(z, RenderingServer.CANVAS_ITEM_Z_MIN, RenderingServer.CANVAS_ITEM_Z_MAX)


static func _restore(id: int) -> void:
	var item := instance_from_id(id) as CanvasItem
	if item != null and item.is_inside_tree():
		RenderingServer.canvas_item_set_visible(item.get_canvas_item(), item.is_visible_in_tree())


## The ground cover and map-wide building pass are subdivided by the same
## exposed regions as terrain. Only their geometry changes, including UVs.
class ClippedOverlay:
	var _draw := FogMesh.DrawCommand.new()
	var _source: Mesh
	var _cropped: Mesh
	var _kept: Array[Rect2] = []
	var _offset: Vector2

	func clear() -> void:
		_draw.detach()

	func clip(item: MeshInstance2D, terrain: MeshInstance2D, kept: Array[Rect2]) -> void:
		var target := item.get_global_transform_with_canvas()
		var source := terrain.get_global_transform_with_canvas()
		if target.x != source.x or target.y != source.y or not target.is_finite() \
				or not source.is_finite() or is_zero_approx(target.determinant()):
			clear()
			return
		var offset := target.affine_inverse() * source.origin
		if item.mesh != _source or offset != _offset or kept != _kept:
			_source = item.mesh
			_offset = offset
			_kept = kept
			_cropped = _crop(_source, kept, _offset)
		_draw.submit(item, _cropped)

	static func _crop(mesh: Mesh, kept: Array[Rect2], offset: Vector2) -> Mesh:
		if mesh == null or mesh.get_surface_count() != 1:
			return null
		var arrays := mesh.surface_get_arrays(0)
		if not arrays[Mesh.ARRAY_TEX_UV] is PackedVector2Array:
			return null
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var vertices := PackedVector2Array()
		if mesh is QuadMesh:
			# Use the source primitive's UV orientation, including flipped V.
			var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var bounds := mesh.get_aabb()
			var first := Vector2(bounds.position.x, bounds.position.y)
			var last := Vector2(bounds.end.x, bounds.end.y)
			vertices = PackedVector2Array([first, Vector2(last.x, first.y),
				last, Vector2(first.x, last.y)])
			var ordered := PackedVector2Array()
			for corner in vertices:
				var index := positions.find(Vector3(corner.x, corner.y, 0.0))
				if index < 0 or index >= uvs.size():
					return null
				ordered.append(uvs[index])
			uvs = ordered
		elif arrays[Mesh.ARRAY_VERTEX] is PackedVector2Array:
			vertices = arrays[Mesh.ARRAY_VERTEX]
		if vertices.is_empty() or vertices.size() % 4 != 0 or vertices.size() != uvs.size():
			return null
		var regions: Array[Rect2] = []
		for region in kept:
			regions.append(Rect2(region.position + offset, region.size))
		return FogMesh.clip(vertices, regions, uvs)
