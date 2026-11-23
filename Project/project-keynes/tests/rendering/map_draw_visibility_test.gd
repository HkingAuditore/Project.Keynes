extends SceneTree

const MapDrawVisibility := preload("res://scripts/rendering/map_draw_visibility.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var parent := Node2D.new()
	root.add_child(parent)
	var backdrop := ColorRect.new()
	backdrop.position = Vector2.ZERO
	backdrop.size = root.get_visible_rect().size
	parent.add_child(backdrop)
	var visibility := MapDrawVisibility.new()
	root.add_child(visibility)
	var solid_fills_view := visibility._covers_viewport(backdrop)
	backdrop.color.a = 0.5
	var transparent_is_rejected := not visibility._covers_viewport(backdrop)
	visibility.queue_free()
	parent.queue_free()
	print("map draw visibility: ", solid_fills_view and transparent_is_rejected)
	quit(0 if solid_fills_view and transparent_is_rejected else 1)
