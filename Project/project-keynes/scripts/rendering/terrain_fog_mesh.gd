extends RefCounted

## Build a draw mesh from the intersections of the original quads and the
## disjoint regions that may show through the fog.
static func clip(vertices: PackedVector2Array, regions: Array[Rect2],
		source_uvs: PackedVector2Array = PackedVector2Array()) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if vertices.is_empty() or regions.is_empty():
		return mesh
	var bounds := regions[0]
	for region in regions:
		bounds = bounds.merge(region)
	var kept := PackedVector2Array()
	var uvs := PackedVector2Array()
	var keep_uvs := source_uvs.size() == vertices.size()
	var indices := PackedInt32Array()
	for offset in range(0, vertices.size(), 4):
		var first := vertices[offset]
		var last := vertices[offset + 2]
		var quad := Rect2(first, last - first)
		if not quad.intersects(bounds):
			continue
		for region in regions:
			var rect := quad.intersection(region)
			if not rect.has_area():
				continue
			var start := kept.size()
			kept.push_back(rect.position)
			kept.push_back(Vector2(rect.end.x, rect.position.y))
			kept.push_back(rect.end)
			kept.push_back(Vector2(rect.position.x, rect.end.y))
			if keep_uvs:
				var uv_start := source_uvs[offset]
				var uv_size := source_uvs[offset + 2] - uv_start
				for vertex in range(start, start + 4):
					uvs.append(uv_start + uv_size * (kept[vertex] - first) / quad.size)
			indices.push_back(start)
			indices.push_back(start + 1)
			indices.push_back(start + 2)
			indices.push_back(start)
			indices.push_back(start + 2)
			indices.push_back(start + 3)
	if not kept.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = kept
		arrays[Mesh.ARRAY_INDEX] = indices
		if keep_uvs:
			arrays[Mesh.ARRAY_TEX_UV] = uvs
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Keep MeshInstance2D's geometry, material and draw order authoritative.
## Replace its draw command immediately when the fog mask changes. A queued
## redraw from MeshInstance2D would only take effect on the following frame.
class DrawCommand:
	var _item: MeshInstance2D
	var _override: Mesh
	var _redrawn := false

	func submit(item: MeshInstance2D, cut_mesh: Mesh, refresh: bool = false) -> void:
		if _item != item:
			detach()
			_item = item
			if _item != null:
				_item.draw.connect(_mark_redrawn)
		if _item == null:
			return
		if refresh or cut_mesh != _override or (_redrawn and cut_mesh != null):
			_replace(cut_mesh if cut_mesh != null else _item.mesh)
		_override = cut_mesh
		_redrawn = false

	func detach() -> void:
		if is_instance_valid(_item):
			_item.draw.disconnect(_mark_redrawn)
			if _override != null:
				_replace(_item.mesh)
		_item = null
		_override = null
		_redrawn = false

	func _mark_redrawn() -> void:
		_redrawn = true

	func _replace(mesh: Mesh) -> void:
		var canvas_item := _item.get_canvas_item()
		RenderingServer.canvas_item_clear(canvas_item)
		if mesh != null and mesh.get_surface_count() > 0:
			var texture := _item.texture.get_rid() if _item.texture != null else RID()
			RenderingServer.canvas_item_add_mesh(
				canvas_item, mesh.get_rid(), Transform2D.IDENTITY, Color.WHITE, texture)
