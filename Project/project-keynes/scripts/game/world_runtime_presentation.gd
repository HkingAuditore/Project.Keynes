extends RefCounted

# Passive presentation adapter. The session owns scheduling and cancellation.
const SettlementLabelLayerScript = preload("res://scripts/rendering/settlement_label_layer.gd")
const BuildingVisualIntelCacheScript = preload("res://scripts/rendering/building_visual_intel_cache.gd")

var _renderer: Object = null
var _camera: MapCamera = null
var _generator: Object = null
var _current_map: MapData = null
var _fog_of_war_enabled: bool = false
var hex_size: float = 22.0
var _wrap_period: float = 0.0
var _settlement_label_layer: SettlementLabelLayer = null
var _building_visual_intel: BuildingVisualIntelCache = BuildingVisualIntelCacheScript.new()
var _building_visual_type_count: int = -1
var _building_visual_force_full_refresh: bool = false
var _building_visual_diag_logged: bool = false
var ui_refresh_enabled := true
var _held_ui_refreshes: Dictionary[Callable, bool] = {}
var _ui_from_day := -1
var ui_presented_day := -1
var _ui_day := -1
var _ui_generation := 0
var _presented_day := -1
var _pending_from_day := -1
var _pending_day := -1
var _pending_generation := 0
var _pending_map_day := -1
var _map_updates := preload("res://scripts/game/world_runtime_map_updates.gd").new()

## Display can skip dates. Keep the first source date until the next application,
## independently from the notification sent for every settled day.
func queue_worker_commit(from_day: int, day: int, generation: int, visual_commit: Dictionary = {}) -> void:
	# A restarted executor can publish a lower generation in the same world.
	if day <= maxi(_presented_day, _pending_day):
		return
	if _ui_day < 0:
		_ui_from_day = from_day
	_ui_day = day
	_ui_generation = generation
	if _pending_day < 0:
		_pending_from_day = _presented_day if _presented_day >= 0 else from_day
	_pending_day = day
	_pending_generation = generation
	if _map_updates.queue(visual_commit):
		_pending_map_day = day

func publish_ui_view(publish: Callable) -> void:
	if not ui_refresh_enabled:
		return
	if _ui_day >= 0:
		ui_presented_day = _ui_day
		_ui_day = -1
		publish.call(_ui_from_day, ui_presented_day, _ui_generation)
	if not _held_ui_refreshes.is_empty():
		var held := _held_ui_refreshes
		_held_ui_refreshes = {}
		for refresh: Callable in held:
			if refresh.is_valid():
				refresh.call()

## Passive panel timers can expire during a hold, including on a paused day.
func defer_ui_refresh(refresh: Callable) -> bool:
	if not ui_refresh_enabled:
		_held_ui_refreshes[refresh] = true
	return not ui_refresh_enabled

func publish_worker_view(publish: Callable) -> void:
	if _pending_day < 0 or (_map_updates.has_pending() and not _map_updates.needs_recovery):
		return
	_presented_day = _pending_day
	_pending_day = -1
	publish.call(_pending_from_day, _presented_day, _pending_generation)

func begin_frame() -> void:
	_map_updates.start_frame(Time.get_ticks_usec())

func observe_draw() -> void:
	_map_updates.observe_draw(Time.get_ticks_usec(), Engine.max_fps)

func apply_pending_worker_map(vision_dirty: PackedInt32Array, publish_map: Callable) -> void:
	if not _map_updates.has_pending():
		return
	var frame := Engine.get_process_frames()
	var started := Time.get_ticks_usec()
	if vision_dirty.is_empty() and not _map_updates.can_apply(frame, started, Engine.max_fps):
		return
	if not publish_map.call(_map_updates.collect(vision_dirty), _pending_map_day, started):
		_map_updates.reject()
		return
	_map_updates.applied(frame, Time.get_ticks_usec() - started)

func presented_worker_day() -> int:
	return _presented_day

func reset_worker_views() -> void:
	_held_ui_refreshes.clear()
	ui_presented_day = -1
	_ui_day = -1
	_ui_from_day = -1
	_ui_generation = 0
	_presented_day = -1
	_pending_from_day = -1
	_pending_day = -1
	_pending_generation = 0
	_pending_map_day = -1
	_map_updates.reset()

func map_wrap_period_x() -> float:
	return _wrap_period

func bind_resources(map: MapData, generator: Object, renderer: Object,
		camera: MapCamera, fog: bool, size: float, wrap: float) -> void:
	_current_map = map
	_generator = generator
	_renderer = renderer
	_camera = camera
	_fog_of_war_enabled = fog
	hex_size = size
	_wrap_period = wrap

func release_resources() -> void:
	reset_worker_views()
	_current_map = null
	_generator = null
	_renderer = null
	_camera = null

func refresh_building_visual_catalog() -> Dictionary:
	if _generator == null or not _generator.has_method("get_economy_facade"):
		return {"ok": false, "deferred": true,
			"reason": "building_visual_economy_facade_unavailable"}
	var economy_facade = _generator.get_economy_facade()
	if economy_facade == null or not economy_facade.has_method("building_visual_catalog"):
		return {"ok": false, "deferred": true,
			"reason": "building_visual_catalog_unavailable"}
	var visual_catalog: Dictionary = economy_facade.building_visual_catalog()
	var ids := PackedStringArray(
		visual_catalog.get("building_type_ids", PackedStringArray()))
	if ids.is_empty():
		_building_visual_type_count = -1
		return {"ok": false, "deferred": true,
			"reason": "building_visual_catalog_not_ready"}
	_building_visual_type_count = ids.size()
	# Headless binding intentionally creates no renderer map. Keep the catalog
	# for PKFG validation, but do not configure visual layers with null context.
	if DisplayServer.get_name() == "headless":
		return {"ok": true, "headless": true, "type_count": ids.size()}
	if _renderer == null or not _renderer.has_method("configure_building_visuals"):
		return {"ok": false, "reason": "building_visual_renderer_unavailable"}
	return _renderer.configure_building_visuals(
		visual_catalog, _building_visual_intel)


func _refresh_building_visual_intel(vision_report: Dictionary) -> Dictionary:
	if _current_map == null or _generator == null:
		return {"ok": false, "reason": "building_visual_world_unavailable"}
	if _building_visual_type_count < 0:
		var catalog_setup := refresh_building_visual_catalog()
		if not bool(catalog_setup.get("ok", false)):
			return {"ok": false, "reason": String(catalog_setup.get(
				"reason", "building_visual_catalog_not_ready"))}
	var ext = _generator.get_data_core_world_ext() \
		if _generator.has_method("get_data_core_world_ext") else null
	if ext == null :
		return {"ok": false, "reason": "building_visual_native_api_unavailable"}
	var requested := PackedInt32Array(
		vision_report.get("newly_visible_cells", PackedInt32Array()))
	# In sandbox/debug sessions fog is disabled and the native vision pass may
	# legitimately report an empty physical array (there is no player sensor).
	# Rendering visibility is nevertheless full-map in this mode, so seed the
	# visual intel cache once instead of silently filtering every cell out.
	if not _fog_of_war_enabled and _building_visual_intel.known_cells().is_empty():
		for cell in _current_map.cell_count():
			requested.append(cell)
	var building_dirty: Dictionary = ext.consume_building_visual_dirty_cells()
	requested.append_array(PackedInt32Array(
		building_dirty.get("dirty_cells", PackedInt32Array())))
	var era_dirty: Dictionary = ext.consume_country_visual_era_dirty_slots()
	var dirty_slots := {}
	for slot in PackedInt32Array(era_dirty.get("country_slots", PackedInt32Array())):
		dirty_slots[int(slot)] = true
	if not dirty_slots.is_empty():
		for cell in _building_visual_intel.known_cells():
			var cell_visible := not _fog_of_war_enabled or (
				cell < _current_map.visible_arr.size()
				and _current_map.visible_arr[cell] != 0)
			if cell_visible \
					and cell < _current_map.country_slot_arr.size() \
					and dirty_slots.has(int(_current_map.country_slot_arr[cell])):
				requested.append(cell)
	if _building_visual_force_full_refresh:
		for cell in _current_map.cell_count():
			requested.append(cell)
	if requested.is_empty():
		return {"ok": true, "changed_cells": PackedInt32Array()}
	var visibility := _current_map.visible_arr
	if not _fog_of_war_enabled:
		visibility = PackedByteArray()
		visibility.resize(_current_map.cell_count())
		visibility.fill(1)
	var refreshed := _building_visual_intel.refresh_visible_cells(
		ext, requested, visibility)
	if bool(refreshed.get("ok", false)):
		_building_visual_force_full_refresh = false
	if _renderer != null and _renderer.has_method("update_building_visual_intel"):
		_renderer.update_building_visual_intel(
			_building_visual_intel,
			PackedInt32Array(refreshed.get("changed_cells", PackedInt32Array())))
		if not _building_visual_diag_logged and bool(refreshed.get("ok", false)):
			var visual_diag: Dictionary = _renderer.building_visual_diagnostics() \
				if _renderer.has_method("building_visual_diagnostics") else {}
			print((
				"[building-visual] intel_refresh requested=%d changed=%d known=%d "
				+ "catalog=%d resident=%d body=%d queued=%d zoom=%.3f"
			) % [
				requested.size(),
				PackedInt32Array(refreshed.get("changed_cells", PackedInt32Array())).size(),
				_building_visual_intel.known_cells().size(),
				int(visual_diag.get("catalog_types", _building_visual_type_count)),
				int(visual_diag.get("resident_chunks", 0)),
				int(visual_diag.get("body_instances", 0)),
				int(visual_diag.get("queued_chunks", 0)),
				float(visual_diag.get("camera_zoom", -1.0)),
			])
			_building_visual_diag_logged = true
	return refreshed


func _bind_settlement_labels() -> void:
	if _renderer == null or _camera == null or _current_map == null \
			or _generator == null or not _generator.has_method(
				"get_economy_facade"):
		return
	if _settlement_label_layer != null and is_instance_valid(
			_settlement_label_layer):
		_settlement_label_layer.queue_free()
	_settlement_label_layer = SettlementLabelLayerScript.new()
	_renderer.add_child(_settlement_label_layer)
	_settlement_label_layer.configure(
		_current_map, _camera, _generator.get_economy_facade(), hex_size,
		map_wrap_period_x(), _fog_of_war_enabled)


func sync_settlement_labels(force_full: bool = false) -> void:
	if _settlement_label_layer != null:
		_settlement_label_layer.sync_from_runtime(force_full)


func set_player_capital_cell(cell_index: int) -> void:
	if _settlement_label_layer != null:
		_settlement_label_layer.set_player_capital_cell(cell_index)


## G4 moved host responsibilities
func on_season_changed(host, _season_idx: int) -> void:
	if host._generator == null or host._current_map == null or host._world_data == null:
		return
	host.mark_map_overlay_dirty(&"season_changed")
func on_year_changed(host, _year_idx: int) -> void:
	if host._generator != null and host._current_map != null and host._world_data != null:
		host.mark_map_overlay_dirty(&"year_changed")


func fit_camera(host, safe_area: Rect2 = Rect2()) -> void:
	if host._camera != null:
		host._camera.fit_to_viewport(1.0, safe_area, true)


func cell_display_centers(host, cells: PackedInt32Array, ref_x: float) -> PackedVector2Array:
	var out = PackedVector2Array()
	if host._current_map == null or cells.is_empty():
		return out
	var wrap_period = host.map_wrap_period_x()
	out.resize(cells.size())
	var kept = 0
	for index in range(cells.size()):
		var cell = host._current_map.cell_at(int(cells[index]))
		if cell == null:
			continue
		var canonical = HexUtils.cube_to_world(cell.q, cell.r, host.hex_size)
		out[kept] = HexUtils.nearest_display_world(canonical, ref_x, wrap_period)
		kept += 1
	if kept != out.size():
		out.resize(kept)
	return out


# Visual/vision methods delegate to the passive adapter.
