extends Node
class_name MapInteractionController

signal cell_selected(cell: HexCell)

var _camera: MapCamera = null
var _runtime_host: WorldRuntimeHost = null


func configure(camera: MapCamera, runtime_host: WorldRuntimeHost) -> void:
	_camera = camera
	_runtime_host = runtime_host
	if _camera != null and not _camera.tile_tapped.is_connected(_on_tile_tapped):
		_camera.tile_tapped.connect(_on_tile_tapped)


func _on_tile_tapped(world_pos: Vector2) -> void:
	if _runtime_host == null or _runtime_host.current_map() == null:
		return
	var cell = HexUtils.world_to_wrapped_cell(
		_runtime_host.current_map(),
		world_pos,
		_runtime_host.hex_size
	)
	if cell == null:
		return
	cell_selected.emit(cell)
