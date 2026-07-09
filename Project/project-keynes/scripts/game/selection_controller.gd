extends Node
class_name SelectionController

signal selection_changed(cell: HexCell)

var _highlight: CellHighlight = null
var _camera: MapCamera = null
var _runtime_host: WorldRuntimeHost = null
var _ui_manager: GameUIManager = null
var _selected_cell: HexCell = null


func configure(
		highlight: CellHighlight,
		camera: MapCamera,
		runtime_host: WorldRuntimeHost,
		ui_manager: GameUIManager
) -> void:
	_highlight = highlight
	_camera = camera
	_runtime_host = runtime_host
	_ui_manager = ui_manager


func selected_cell() -> HexCell:
	return _selected_cell


func select_cell(cell: HexCell) -> void:
	if cell == null:
		clear_selection()
		return
	_selected_cell = cell
	var display_world := _cell_display_world(cell)
	var wrap_period := _runtime_host.map_wrap_period_x() if _runtime_host != null else 0.0
	if _highlight != null:
		_highlight.set_cell_display(cell, _runtime_host.hex_size if _runtime_host != null else 22.0, display_world, wrap_period)
	if _ui_manager != null:
		_ui_manager.show_cell_panel(cell)
	if _camera != null and _ui_manager != null:
		_camera.ensure_point_visible(display_world, _ui_manager.map_safe_area())
	selection_changed.emit(cell)


func clear_selection() -> void:
	_selected_cell = null
	if _highlight != null:
		_highlight.clear()
	if _ui_manager != null:
		_ui_manager.hide_cell_panel()
	selection_changed.emit(null)


func _cell_display_world(cell: HexCell) -> Vector2:
	if cell == null:
		return Vector2.ZERO
	var hex_size := _runtime_host.hex_size if _runtime_host != null else 22.0
	var canonical := HexUtils.cube_to_world(cell.q, cell.r, hex_size)
	var ref_x := _camera.position.x if _camera != null else canonical.x
	var wrap_period := _runtime_host.map_wrap_period_x() if _runtime_host != null else 0.0
	return HexUtils.nearest_display_world(canonical, ref_x, wrap_period)
