extends Node2D
class_name SettlementLabelLayer

const DESKTOP_CAP := 128
const MOBILE_CAP := 64
const LABEL_SIZE := Vector2(176.0, 24.0)

var _map: MapData
var _camera: Camera2D
var _facade
var _hex_size := 22.0
var _wrap_period_x := 0.0
var _fog_enabled := false
var _revision := -1
var _settlements: Dictionary = {}
var _row_cells: Dictionary = {}
var _pool: Array[Label] = []
var _last_camera_position := Vector2.INF
var _last_zoom := -1.0
var _dirty := true
# 帧尾诊断：最近一次 _rebuild_visible_labels 墙钟（毫秒）。tick 日 sync_from_runtime
# 会无条件置 dirty，所以重建成本逐日计入 perf 的 tail_label_ms 列。
var _last_rebuild_ms: float = 0.0
var _last_rebuild_label_count: int = 0


func configure(map: MapData, camera: Camera2D, facade, hex_size: float,
		wrap_period_x: float, fog_enabled: bool) -> void:
	_map = map
	_camera = camera
	_facade = facade
	_hex_size = hex_size
	_wrap_period_x = wrap_period_x
	_fog_enabled = fog_enabled
	_ensure_pool(MOBILE_CAP if OS.has_feature("mobile") else DESKTOP_CAP)
	sync_from_runtime(true)
	set_process(true)


func set_fog_enabled(enabled: bool) -> void:
	if _fog_enabled == enabled:
		return
	_fog_enabled = enabled
	_dirty = true


func mark_visibility_dirty() -> void:
	_dirty = true


func sync_from_runtime(force_full: bool = false) -> void:
	if _facade == null:
		return
	var packet: Dictionary
	if force_full or _revision < 0:
		packet = _facade.named_settlement_snapshot()
	else:
		packet = _facade.settlement_delta(_revision)
	if not bool(packet.get("ok", false)):
		return
	if bool(packet.get("full_snapshot", false)):
		_settlements.clear()
		_row_cells.clear()
	var cells: PackedInt32Array = packet.get("cell_indices", PackedInt32Array())
	var tiers: PackedByteArray = packet.get("prosperity_tiers", PackedByteArray())
	var active: PackedByteArray = packet.get("name_active", PackedByteArray())
	var names: PackedStringArray = packet.get("settlement_names", PackedStringArray())
	for index in range(cells.size()):
		var cell := int(cells[index])
		if index >= active.size() or active[index] == 0:
			_remove_from_row(cell)
			_settlements.erase(cell)
		elif index < tiers.size() and index < names.size():
			_settlements[cell] = {
				"tier": int(tiers[index]),
				"name": String(names[index]),
			}
			_add_to_row(cell)
	_revision = int(packet.get("revision", _revision))
	_dirty = true


func _process(_delta: float) -> void:
	if _camera == null or _map == null:
		return
	var zoom_value := _camera.zoom.x
	if _camera.position.distance_squared_to(_last_camera_position) > 4.0 \
			or not is_equal_approx(zoom_value, _last_zoom):
		_last_camera_position = _camera.position
		_last_zoom = zoom_value
		_dirty = true
	if _dirty:
		var rebuild_started_usec := Time.get_ticks_usec()
		_rebuild_visible_labels()
		_last_rebuild_ms = float(Time.get_ticks_usec() - rebuild_started_usec) / 1000.0


func get_last_rebuild_ms() -> float:
	return _last_rebuild_ms


func get_last_rebuild_label_count() -> int:
	return _last_rebuild_label_count


func _rebuild_visible_labels() -> void:
	_dirty = false
	for label in _pool:
		label.visible = false
	var zoom_value := maxf(_camera.zoom.x, 0.001)
	var minimum_tier := 5 if zoom_value < 0.45 else (
		4 if zoom_value < 0.75 else (3 if zoom_value < 1.2 else 2))
	var viewport_rect := get_viewport_rect().grow(48.0)
	var canvas_transform := get_viewport().get_canvas_transform()
	var candidates: Array[Dictionary] = []
	var half_world_height := viewport_rect.size.y * 0.5 / zoom_value
	var row_step := maxf(1.0, _hex_size * 1.5)
	var first_row := clampi(floori(
		(_camera.position.y - half_world_height) / row_step) - 2,
		0, maxi(0, _map.height - 1))
	var last_row := clampi(ceili(
		(_camera.position.y + half_world_height) / row_step) + 2,
		first_row, maxi(first_row, _map.height - 1))
	var visible_cells: Array[int] = []
	for map_row in range(first_row, last_row + 1):
		var row_bucket: Dictionary = _row_cells.get(map_row, {})
		for raw_cell in row_bucket:
			visible_cells.append(int(raw_cell))
	for cell_idx in visible_cells:
		var row: Dictionary = _settlements[cell_idx]
		var tier := int(row.tier)
		if tier < minimum_tier or (_fog_enabled and (
				cell_idx >= _map.visible_arr.size() or
				_map.visible_arr[cell_idx] == 0)):
			continue
		var cell := _map.cell_at(cell_idx)
		if cell == null:
			continue
		var world_position := HexUtils.cube_to_world(cell.q, cell.r, _hex_size)
		world_position = HexUtils.nearest_display_world(
			world_position, _camera.position.x, _wrap_period_x)
		var copy_offsets := PackedFloat32Array([0.0])
		if _wrap_period_x > 0.001:
			copy_offsets = PackedFloat32Array(
				[-_wrap_period_x, 0.0, _wrap_period_x])
		for copy_index in range(copy_offsets.size()):
			var display_position := world_position + Vector2(
				copy_offsets[copy_index], 0.0)
			var screen_position: Vector2 = canvas_transform * display_position
			if not viewport_rect.has_point(screen_position):
				continue
			candidates.append({
				"cell": cell_idx,
				"copy": copy_index,
				"tier": tier,
				"name": String(row.name),
				"world": display_position,
				"screen": screen_position,
				"distance": display_position.distance_squared_to(
					_camera.position),
			})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.tier) != int(b.tier):
			return int(a.tier) > int(b.tier)
		if not is_equal_approx(float(a.distance), float(b.distance)):
			return float(a.distance) < float(b.distance)
		if int(a.cell) != int(b.cell):
			return int(a.cell) < int(b.cell)
		return int(a.copy) < int(b.copy))
	var occupied: Array[Rect2] = []
	var used := 0
	for candidate in candidates:
		if used >= _pool.size():
			break
		var rect := Rect2(
			Vector2(candidate.screen) - LABEL_SIZE * 0.5, LABEL_SIZE)
		var overlaps := false
		for other in occupied:
			if rect.intersects(other):
				overlaps = true
				break
		if overlaps:
			continue
		occupied.append(rect)
		var label := _pool[used]
		label.text = String(candidate.name)
		label.position = Vector2(candidate.world) - LABEL_SIZE * 0.5 / zoom_value
		label.scale = Vector2.ONE / zoom_value
		label.visible = true
		used += 1
	_last_rebuild_label_count = used


func _ensure_pool(capacity: int) -> void:
	while _pool.size() < capacity:
		var label := Label.new()
		label.size = LABEL_SIZE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", Color(0.96, 0.93, 0.82))
		label.add_theme_color_override("font_outline_color", Color(0.04, 0.05, 0.07, 0.92))
		label.add_theme_constant_override("outline_size", 4)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.visible = false
		add_child(label)
		_pool.append(label)


func _add_to_row(cell_idx: int) -> void:
	if _map == null:
		return
	var cell := _map.cell_at(cell_idx)
	if cell == null:
		return
	var row_bucket: Dictionary = _row_cells.get(cell.r, {})
	row_bucket[cell_idx] = true
	_row_cells[cell.r] = row_bucket


func _remove_from_row(cell_idx: int) -> void:
	if _map == null:
		return
	var cell := _map.cell_at(cell_idx)
	if cell == null or not _row_cells.has(cell.r):
		return
	var row_bucket: Dictionary = _row_cells[cell.r]
	row_bucket.erase(cell_idx)
	if row_bucket.is_empty():
		_row_cells.erase(cell.r)
	else:
		_row_cells[cell.r] = row_bucket
