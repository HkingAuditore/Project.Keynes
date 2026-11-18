extends SubViewport

## A small numerical texture rendered on the GPU. The owner controls when its
## inputs change. Its private canvas never inherits the game camera or UI.
var material := ShaderMaterial.new()
var _quad := ColorRect.new()

func configure(parent: Node, dimensions: Vector2i, program: Shader) -> void:
	disable_3d = true
	gui_disable_input = true
	world_2d = World2D.new()
	transparent_bg = true
	use_hdr_2d = true
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	render_target_clear_mode = SubViewport.CLEAR_MODE_NEVER
	size = dimensions
	material.shader = program
	_quad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_quad.size = Vector2(dimensions)
	_quad.material = material
	add_child(_quad)
	parent.add_child(self)

func _enter_tree() -> void:
	# Reparenting the surface can recreate its viewport attachments at the same input time.
	refresh()

func resize_table(dimensions: Vector2i) -> void:
	if dimensions != size:
		size = dimensions
		_quad.size = Vector2(dimensions)
		refresh()

func refresh() -> void:
	render_target_update_mode = SubViewport.UPDATE_ONCE
