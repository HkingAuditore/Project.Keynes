# S12 frozen host implementation, before extraction; test only.
extends RefCounted

# No process callback of its own; the host schedules and releases this cache.
const MAP_OVERLAY_REFRESH_INTERVAL_MSEC: int = 100
const MAP_OVERLAY_MAX_REFRESH_INTERVAL_MSEC: int = 750
const MAP_OVERLAY_DUTY: float = 0.05
var _renderer: Object = null
var _map_overlay_layer: Object = null
var _current_map: MapData = null
var _world_data: WorldData = null
var _view_adapter: DCViewAdapter = null
var _generator: Object = null
var _world_clock: WorldClock = null
var _runtime_ready_for_ticks: bool = false
var _process_request: Callable

var _map_overlay_request: Dictionary = {}
var _map_overlay_tex: ImageTexture = null
var _map_overlay_image: Image = null
var _map_overlay_buf: PackedByteArray = PackedByteArray()
var _map_overlay_dirty: bool = false
var _map_overlay_last_refresh_msec: int = 0
var _map_overlay_refresh_count: int = 0
var _map_overlay_merged_dirty_count: int = 0
var _map_overlay_last_result: Dictionary = {}
var _map_overlay_last_bake_ms: float = 0.0
var _overlay_bake_ms_accum: float = 0.0

func set_process(enabled: bool) -> void:
	_process_request.call(enabled)

func set_map_overlay(request: Dictionary) -> void:
	var mode := int(request.get("mode", OverlayMode.MODE.NONE))
	if mode == OverlayMode.MODE.NONE:
		clear_map_overlay()
		return
	var signal_id := StringName(request.get("signal_id", &""))
	var occupancy_bit := -1
	if mode == OverlayMode.MODE.BIO_OCCUPANCY:
		occupancy_bit = ResearchSignalCatalog.occupancy_bit_for_signal(
			ResearchSignalCatalog.compile_native_catalog(), signal_id)
		if occupancy_bit < 0:
			clear_map_overlay()
			return
	_map_overlay_request = {
		"mode": mode,
		"resource_id": StringName(request.get("resource_id", &"")),
		"signal_id": signal_id,
		"occupancy_bit": occupancy_bit,
	}
	_map_overlay_dirty = true
	if _renderer != null and _renderer.has_method("set_resource_visual_filter"):
		_renderer.set_resource_visual_filter(String(signal_id) if mode == OverlayMode.MODE.BIO_OCCUPANCY \
			else String(request.get("resource_id", "")) if mode == OverlayMode.MODE.RESOURCE_RESERVE else "")
	set_process(true)
	_refresh_map_overlay(true)


func clear_map_overlay() -> void:
	if _renderer != null and _renderer.has_method("set_resource_visual_filter"):
		_renderer.set_resource_visual_filter("")
	_map_overlay_request.clear()
	_map_overlay_dirty = false
	set_process(_runtime_ready_for_ticks)
	if _map_overlay_layer != null:
		_map_overlay_layer.hide_animated()


func mark_map_overlay_dirty(_reason: StringName = &"runtime") -> void:
	if _map_overlay_request.is_empty():
		return
	if _map_overlay_dirty:
		_map_overlay_merged_dirty_count += 1
	_map_overlay_dirty = true
	set_process(true)


func map_overlay_diagnostics() -> Dictionary:
	return {
		"active": not _map_overlay_request.is_empty(),
		"request": _map_overlay_request.duplicate(),
		"refresh_count": _map_overlay_refresh_count,
		"merged_dirty_count": _map_overlay_merged_dirty_count,
		"last_bake_ms": _map_overlay_last_bake_ms,
		"refresh_interval_msec": _map_overlay_refresh_interval_msec(),
		"last_result": _map_overlay_last_result.duplicate(),
	}


func _map_overlay_refresh_interval_msec() -> int:
	if _map_overlay_last_bake_ms <= 0.0:
		return MAP_OVERLAY_REFRESH_INTERVAL_MSEC
	return clampi(int(ceil(_map_overlay_last_bake_ms / MAP_OVERLAY_DUTY)),
		MAP_OVERLAY_REFRESH_INTERVAL_MSEC, MAP_OVERLAY_MAX_REFRESH_INTERVAL_MSEC)


func _refresh_map_overlay(force: bool) -> void:
	if _map_overlay_layer == null or _current_map == null or _world_data == null \
			or _view_adapter == null or _map_overlay_request.is_empty():
		return
	var now := Time.get_ticks_msec()
	if not force and now - _map_overlay_last_refresh_msec < _map_overlay_refresh_interval_msec():
		return
	var mode := int(_map_overlay_request.get("mode", OverlayMode.MODE.NONE))
	var resource_profile: ResourceProfile = null
	if mode == OverlayMode.MODE.RESOURCE_RESERVE:
		var wanted := StringName(_map_overlay_request.get("resource_id", &""))
		for profile in ResourceProfileRegistry.ordered():
			if profile != null and profile.id == wanted:
				resource_profile = profile
				break
		if resource_profile == null:
			clear_map_overlay()
			return
	var occupancy_bit := int(_map_overlay_request.get("occupancy_bit", -1))
	if mode == OverlayMode.MODE.BIO_OCCUPANCY and occupancy_bit < 0:
		clear_map_overlay()
		return
	var climate = _generator._c() if _generator != null and _generator.has_method("_c") else null
	var phase := _world_clock.season_phase() if _world_clock != null else 0.0
	var started := Time.get_ticks_usec()
	var result := DataOverlayBaker.bake_cell_lut(
		_current_map, _world_data, mode, climate, phase, _view_adapter,
		resource_profile, _map_overlay_tex, _map_overlay_buf, _map_overlay_image,
		occupancy_bit
	)
	_map_overlay_tex = result.get("texture") as ImageTexture
	_map_overlay_image = result.get("image") as Image
	_map_overlay_buf = result.get("buf", PackedByteArray())
	_map_overlay_layer.set_cell_lut_texture(_map_overlay_tex)
	_map_overlay_layer.show_mode_animated(mode)
	_map_overlay_dirty = false
	set_process(_runtime_ready_for_ticks)
	_map_overlay_last_refresh_msec = now
	_map_overlay_refresh_count += 1
	_map_overlay_last_result = {
		"path": result.get("path", ""),
		"upload_bytes": int(result.get("upload_bytes", 0)),
		"encode_upload_ms": (Time.get_ticks_usec() - started) / 1000.0,
		"stats": result.get("stats", {}),
	}
	_map_overlay_last_bake_ms = float(
		_map_overlay_last_result.get("encode_upload_ms", 0.0))
	_overlay_bake_ms_accum += _map_overlay_last_bake_ms
