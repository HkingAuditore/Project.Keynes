extends Node

## Renders the terrain surfaces at a smaller size while the camera, map input,
## overlays and UI keep using the window's canvas.
var _land: MeshInstance2D
var _water: MeshInstance2D
var _surface_parent: Node2D
var _target: SubViewport
var _blit: Sprite2D
var _percent := 100


func apply(land: MeshInstance2D, percent: int, msaa: Viewport.MSAA) -> void:
	if not is_instance_valid(land):
		return
	_land = land
	_percent = percent
	if _percent >= 100:
		_restore_direct_drawing()
		return
	if _target == null:
		_create_target(msaa)
	_target.msaa_2d = msaa
	_sync_target()


func surface_parent() -> Node:
	return _target if _target != null else _land.get_parent()


func main_canvas_parent(surface: MeshInstance2D) -> Node2D:
	if _target == null or surface.get_parent() != _target:
		return null
	# Fog coverage is checked before drawing and may run before our pre-draw signal.
	_sync_target()
	return _surface_parent


func attach_water(water: MeshInstance2D) -> void:
	if not is_instance_valid(water):
		_water = null
		return
	_water = water
	var parent := surface_parent()
	if _water.get_parent() == null:
		parent.add_child(_water)
	elif _water.get_parent() != parent:
		_water.reparent(parent, false)
	parent.move_child(_water, mini(_land.get_index() + 1, parent.get_child_count() - 1))


func _create_target(msaa: Viewport.MSAA) -> void:
	_surface_parent = _land.get_parent() as Node2D
	_target = SubViewport.new()
	_target.name = "TerrainViewport"
	_target.disable_3d = true
	_target.transparent_bg = true
	_target.gui_disable_input = true
	_target.msaa_2d = msaa
	# This viewport supplies the map on the same frame the setting is applied.
	_target.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_target)

	_blit = Sprite2D.new()
	_blit.name = "TerrainBlit"
	_blit.centered = false
	_blit.z_index = _land.z_index
	_blit.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_blit.texture = _target.get_texture()
	var material := CanvasItemMaterial.new()
	material.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	_blit.material = material
	_surface_parent.add_child(_blit)
	_surface_parent.move_child(_blit, _land.get_index())
	_land.reparent(_target, false)
	RenderingServer.frame_pre_draw.connect(_sync_target)


func _restore_direct_drawing() -> void:
	if _target == null:
		return
	RenderingServer.frame_pre_draw.disconnect(_sync_target)
	var index := _blit.get_index()
	_land.reparent(_surface_parent, false)
	_surface_parent.move_child(_land, index)
	# Water may have been replaced since the last resize or graphics change.
	if is_instance_valid(_water) and not _water.is_queued_for_deletion():
		_water.reparent(_surface_parent, false)
		_surface_parent.move_child(_water, _land.get_index() + 1)
	_blit.texture = null
	_surface_parent.remove_child(_blit)
	_blit.queue_free()
	remove_child(_target)
	_target.queue_free()
	_blit = null
	_target = null
	_surface_parent = null


func _sync_target() -> void:
	var source := get_viewport()
	var view := source.get_visible_rect()
	if view.size.x <= 0.0 or view.size.y <= 0.0:
		return
	var physical_size := view.size * source.get_stretch_transform().get_scale().abs()
	var target_size := Vector2i(physical_size * (_percent / 100.0)).max(Vector2i(2, 2))
	if _target.size != target_size:
		_target.size = target_size
	var ratio := Vector2(target_size) / view.size
	var to_target := Transform2D(Vector2(ratio.x, 0.0), Vector2(0.0, ratio.y), -view.position * ratio)
	var to_canvas := _surface_parent.get_global_transform_with_canvas()
	var canvas := to_target * to_canvas
	if _target.canvas_transform != canvas:
		_target.canvas_transform = canvas
	var blit_transform := to_canvas.affine_inverse() * to_target.affine_inverse()
	if _blit.transform != blit_transform:
		_blit.transform = blit_transform
