extends Node2D

## Only solid UI backdrops explicitly registered by the player scene can hide the map.
var backdrops: Array[ColorRect] = []


func _enter_tree() -> void:
	# Run before the child renderers prepare their offscreen textures for this draw.
	RenderingServer.frame_pre_draw.connect(_prepare)


func _exit_tree() -> void:
	RenderingServer.frame_pre_draw.disconnect(_prepare)


func _prepare() -> void:
	for backdrop in backdrops:
		if backdrop.is_visible_in_tree() and _covers_viewport(backdrop):
			visible = false
			return
	visible = true


func _covers_viewport(backdrop: ColorRect) -> bool:
	var canvas_layer := backdrop.get_canvas_layer_node()
	if canvas_layer != null and not canvas_layer.visible:
		return false
	if backdrop.color.a < 1.0 or backdrop.self_modulate.a < 1.0 or backdrop.material != null:
		return false
	var view := get_viewport_rect()
	var item: CanvasItem = backdrop
	while item != null:
		if item.modulate.a < 1.0:
			return false
		if item == backdrop or (item is Control and item.clip_contents):
			var to_screen := item.get_global_transform_with_canvas()
			if to_screen.x.y != 0.0 or to_screen.y.x != 0.0 or not (
					to_screen * Rect2(Vector2.ZERO, item.size)).encloses(view):
				return false
		item = item.get_parent() as CanvasItem
	return true
