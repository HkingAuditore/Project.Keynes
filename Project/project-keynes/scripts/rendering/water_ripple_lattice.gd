extends "res://scripts/rendering/render_data_table.gd"

const PAGE_SIDE := 256
const DIMENSIONS := Vector2i(PAGE_SIDE, PAGE_SIDE * 3)
const PROGRAM := preload("res://shaders/water_ripple_lattice.gdshader")

var _cycles := Vector4.ZERO
var _pending_region := Rect2i()


func setup(parent: Node) -> void:
	configure(parent, DIMENSIONS, PROGRAM)


func update_cycles(cycles: Vector4) -> void:
	if cycles == _cycles:
		return
	var first_changed := cycles.x != _cycles.x or cycles.y != _cycles.y
	var second_changed := cycles.z != _cycles.z or cycles.w != _cycles.w
	_cycles = cycles
	material.set_shader_parameter("cycles", cycles)
	var top := 0 if first_changed else PAGE_SIDE
	var height := PAGE_SIDE * (2 if first_changed and second_changed else 1)
	var region := Rect2i(0, top, PAGE_SIDE, height)
	# Keep earlier requests in the same draw, including the initial full fill.
	if _pending_region.has_area():
		region = _pending_region.merge(region)
	if region != _pending_region:
		_queue_refresh(region)


func refresh() -> void:
	# The base table requests a full fill on tree entry and resize.
	_queue_refresh(Rect2i(Vector2i.ZERO, size))


func _queue_refresh(region: Rect2i) -> void:
	var needs_draw := not _pending_region.has_area()
	_pending_region = region
	# FRAGCOORD still addresses the complete texture. CLEAR_MODE_NEVER keeps
	# the other rows in place while this one rectangle is rasterized.
	_quad.position = Vector2(region.position)
	_quad.size = Vector2(region.size)
	if needs_draw:
		# Close the batch when the main thread hands the frame to the renderer.
		RenderingServer.frame_pre_draw.connect(_begin_draw, CONNECT_ONE_SHOT)
		super.refresh()


func _begin_draw() -> void:
	_pending_region = Rect2i()
