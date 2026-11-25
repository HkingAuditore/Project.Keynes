extends SubViewport

## WorldRoot is rendered here. The single player camera and input stay on the
## window. Its CanvasLayer composites the last texture under the native-size UI.
const DrawnFrame := preload("res://scripts/rendering/map_drawn_frame.gd")
signal map_view_drawn(day: int)

var draw_enabled := true
var draw_count := 0
var _frame := DrawnFrame.new()
var _source: Viewport
var _output: TextureRect
var _map: MapData
var _camera: MapCamera
var _drawing := false
@onready var _world_root = $WorldRoot


func _enter_tree() -> void:
	# Set the transform and visibility before nested terrain and fog prepare their draws.
	if DisplayServer.get_name() == "headless":
		return
	_source = get_parent().get_viewport()
	RenderingServer.frame_pre_draw.connect(_prepare_draw)
	RenderingServer.frame_post_draw.connect(_finish_draw)


func configure(output: TextureRect, camera: MapCamera) -> void:
	_output = output
	_camera = camera
	# Apply camera motion, then copy its transform before world layers cull.
	camera.process_priority = -2
	process_priority = -1
	output.hide()
	if _source != null:
		output.texture = get_texture()


func bind_map(map: MapData, initial_day: int) -> void:
	reset()
	if DisplayServer.get_name() == "headless":
		return
	_map = map
	_frame.attach(map)
	_camera.drawn_frame = _frame
	_frame.received_day = initial_day
	_frame.staged_day = initial_day
	_frame.stage_vision(map.vision_revision, map.visible_arr, map.explored_arr)


func receive_day(day: int) -> void:
	if _map != null:
		_frame.received_day = day

func stage_map(day: int) -> void:
	if _map != null:
		if day >= 0:
			_frame.staged_day = day
		_frame.stage_vision(_map.vision_revision, _map.visible_arr, _map.explored_arr)

func _process(_delta: float) -> void:
	if _source != null and _map != null and draw_enabled:
		_camera.force_update_scroll()
		_sync_view_geometry(_source.get_visible_rect().size)

func _sync_view_geometry(view_size: Vector2) -> void:
	if view_size.x <= 0 or view_size.y <= 0:
		return
	canvas_transform = _source.canvas_transform
	var pixels := Vector2i((view_size * _source.get_stretch_transform().get_scale().abs()).round())
	if size != pixels:
		size = pixels
	var logical := Vector2i(view_size.round())
	if size_2d_override != logical:
		size_2d_override = logical

func reset() -> void:
	if _map != null:
		_frame.detach(_map)
		_map = null
	if is_instance_valid(_camera):
		_camera.drawn_frame = null
	_frame = DrawnFrame.new()
	_drawing = false
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_output):
		_output.hide()


func _prepare_draw() -> void:
	_drawing = false
	if not is_instance_valid(_output):
		return
	var uncovered: bool = not _world_root.covered_by_ui()
	_output.visible = uncovered and _frame.valid
	_world_root.visible = uncovered and draw_enabled
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _map == null or not _world_root.visible or not DisplayServer.window_can_draw(get_window().get_window_id()):
		return
	var view_size := _source.get_visible_rect().size
	if view_size.x <= 0 or view_size.y <= 0:
		return
	_sync_view_geometry(view_size)
	msaa_2d = _source.msaa_2d
	use_hdr_2d = _source.use_hdr_2d
	canvas_item_default_texture_filter = _source.canvas_item_default_texture_filter
	canvas_item_default_texture_repeat = _source.canvas_item_default_texture_repeat
	render_target_update_mode = SubViewport.UPDATE_ONCE
	# The root samples this update in the same render pass, including on the first frame.
	_output.show()
	_frame.submit(canvas_transform, view_size)
	_drawing = true


func _finish_draw() -> void:
	if not _drawing:
		return
	_drawing = false
	if not DisplayServer.window_can_draw(get_window().get_window_id()):
		return
	draw_count += 1
	if _frame.present():
		map_view_drawn.emit(_frame.day)


func _exit_tree() -> void:
	if _source != null:
		RenderingServer.frame_pre_draw.disconnect(_prepare_draw)
		RenderingServer.frame_post_draw.disconnect(_finish_draw)
	reset()
