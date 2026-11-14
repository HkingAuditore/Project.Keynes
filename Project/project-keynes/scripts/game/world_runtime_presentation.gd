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


## G4 moved host responsibilities
func on_season_changed(host, season_idx: int) -> void:
	if host._generator == null or host._current_map == null or host._world_data == null:
		return
	var cp = host._generator._c() if host._generator.has_method("_c") else null
	host.mark_map_overlay_dirty(&"season_changed")
	var use_legacy = false
	if cp != null and "season_refresh_legacy_signal" in cp:
		use_legacy = bool(cp.season_refresh_legacy_signal)
	if not use_legacy:
		return
	if host._generator.has_method("queue_season_refresh"):
		host._generator.queue_season_refresh(season_idx)
	else:
		host._generator.refresh_seasonal(host._current_map, host._world_data, season_idx)


func on_year_changed(host, _year_idx: int) -> void:
	if host._generator != null and host._current_map != null and host._world_data != null:
		host._generator.refresh_yearly(host._current_map, host._world_data)
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
