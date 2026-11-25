extends Node2D

## Only solid UI backdrops explicitly registered by the player scene can hide the map.
var backdrops: Array[ColorRect] = []


func covered_by_ui() -> bool:
	for backdrop in backdrops:
		if backdrop.is_visible_in_tree() and _covers_viewport(backdrop):
			return true
	return false


func _covers_viewport(backdrop: ColorRect) -> bool:
	var canvas_layer := backdrop.get_canvas_layer_node()
	if canvas_layer != null and not canvas_layer.visible:
		return false
	if backdrop.color.a < 1.0 or backdrop.self_modulate.a < 1.0 or backdrop.material != null:
		return false
	var view := backdrop.get_viewport_rect()
	var item: CanvasItem = backdrop
	while item != null:
		if item.modulate.a < 1.0:
			return false
		if item == backdrop or (item is Control and item.clip_contents):
			var control := item as Control
			var to_screen := item.get_global_transform_with_canvas()
			if to_screen.x.y != 0.0 or to_screen.y.x != 0.0 or not (
					to_screen * Rect2(Vector2.ZERO, control.size)).encloses(view):
				return false
		item = item.get_parent() as CanvasItem
	return true
