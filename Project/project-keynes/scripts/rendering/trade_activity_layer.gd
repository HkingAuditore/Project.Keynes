extends Node2D
class_name TradeActivityLayer

## Bounded read-only observer. Two fixed batches sharing one MultiMesh, no per-order nodes or CPU animation.
const VEHICLES: Texture2D = preload("res://assets/vfx/trade/vehicles_topdown_v2.png")
const VEHICLE_SHADER: Shader = preload("res://shaders/trade_vehicle.gdshader")
const PATH_WIDTH := 1024
const INTEREST_CAP := 4096
# Six style pairs, indexed by the authoritative eleven-era catalog.
const ERA_ROWS := [0, 2, 2, 2, 4, 4, 6, 8, 10, 10, 10]

var _map: MapData
var _camera: Camera2D
var _host
var _player
var _economy
var _clock: WorldClock
var _hex_size := 22.0
var _wrap := 0.0
var _quality := 2
var _material: ShaderMaterial
var _shadow_material: ShaderMaterial
var _shadow_batch: MultiMeshInstance2D
var _lighting_values: Dictionary = {}
var _shader_tiled := false
var _batch: MultiMeshInstance2D
var _paths: ImageTexture
var _visibility: ImageTexture
var _records: Dictionary = {}
var _row_keys: Array[String] = []
var _info := PackedVector4Array()
var _vision_revision := -1
var _fog_enabled := false
var _wall_time := 0.0
var _visual_time := 0.0
var _next_refresh := 0.0
var _subscribed := false
var _serial := -1
var _last_topology := -1
var _last_country_topology := -1
var _last_selected := -1
var _interest := PackedInt32Array()
var _last_view := Rect2()
var _bounds_rect := Rect2()
var _camera_rect := Rect2()
var _camera_center := Vector2.ZERO
var _camera_zoom := 1.0
var _external_camera := false
var _stats := {"vehicle_count": 0, "route_count": 0, "query_usec": 0,
	"upload_bytes": 0, "native_usec": 0, "memory_bytes": 0,
	"scanned_orders": 0, "expanded_nodes": 0, "cache_hits": 0, "pending_routes": 0}


func _ready() -> void:
	_ensure_batch()
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func configure(map: MapData, camera: Camera2D, host, player, economy,
		clock: WorldClock) -> void:
	clear()
	_map = map
	_camera = camera
	_host = host
	_player = player
	_economy = economy
	_clock = clock
	_hex_size = float(host.hex_size)
	_wrap = float(host.map_wrap_period_x())
	_ensure_batch()
	_set_parameter("map_width", float(map.width))
	_set_parameter("wrap_period", _wrap)
	set_process(true)


func clear() -> void:
	_unsubscribe()
	_records.clear()
	_row_keys.clear()
	_interest.clear()
	_serial = -1
	_last_topology = -1
	_last_country_topology = -1
	_vision_revision = -1
	_wall_time = 0.0
	_visual_time = 0.0
	_next_refresh = 0.0
	_last_view = Rect2()
	_bounds_rect = Rect2()
	_external_camera = false
	_map = null
	_lighting_values.clear()
	for name in ["terrain_normal_tex", "terrain_horizon_tex", "visual_horizon_tiles", "visual_terrain_normal_tiles"]:
		_set_parameter(name, null)
	for name in ["terrain_normal_tex_bound", "terrain_horizon_tex_bound", "gi_lut_bound"]:
		_set_parameter(name, false)
	if _batch != null:
		_batch.multimesh.visible_instance_count = 0
		_batch.visible = false
		_shadow_batch.visible = false
	_stats.vehicle_count = 0
	_stats.route_count = 0


func _exit_tree() -> void:
	_unsubscribe()


func _unsubscribe() -> void:
	if _subscribed and is_instance_valid(_economy):
		_economy.trade_visual_snapshot(PackedInt32Array(), PackedByteArray(), 0, -1, false)
	_subscribed = false


func set_quality(quality: int) -> void:
	_quality = clampi(quality, 0, 2)
	_set_parameter("visual_quality", _quality)
	if _shadow_batch != null:
		_shadow_batch.visible = _batch.visible and _quality >= 2 and not OS.has_feature("web")
	_next_refresh = 0.0
	if _material != null and not _records.is_empty():
		_rebuild_upload()


func set_camera_view(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	_camera_rect = world_rect
	_camera_center = center
	_camera_zoom = zoom_value
	_external_camera = true


func _low_quality() -> bool:
	return _quality == 0 or OS.has_feature("mobile") or OS.has_feature("web")


func _route_cap() -> int:
	return UITokens.TRADE_LOW_ROUTE_CAP if _low_quality() else UITokens.TRADE_ROUTE_CAP


func _vehicle_cap() -> int:
	return UITokens.TRADE_LOW_VEHICLE_CAP if _low_quality() else UITokens.TRADE_VEHICLE_CAP


func _ensure_batch() -> void:
	if _batch != null:
		return
	_material = ShaderMaterial.new()
	_material.shader = VEHICLE_SHADER
	_shadow_material = ShaderMaterial.new()
	_shadow_material.shader = VEHICLE_SHADER
	_shadow_material.set_shader_parameter("shadow_pass", true)
	_set_parameter("visual_quality", _quality)
	_set_parameter("shadow_strength", UITokens.TRADE_SHADOW_STRENGTH)
	_set_parameter("shadow_color", UITokens.TRADE_SHADOW_COLOR)
	_set_parameter("shadow_height_ratio", UITokens.TRADE_SHADOW_HEIGHT_RATIO)
	_set_parameter("shadow_max_length_ratio", UITokens.TRADE_SHADOW_MAX_LENGTH_RATIO)
	_set_parameter("shadow_shapes", PackedVector4Array(UITokens.TRADE_SHADOW_SHAPES))
	_set_parameter("shadow_heights", PackedFloat32Array(UITokens.TRADE_SHADOW_HEIGHTS))
	_set_parameter("shadow_footprint", UITokens.TRADE_SHADOW_FOOTPRINT)
	_set_parameter("shadow_edge_softness", UITokens.TRADE_SHADOW_EDGE_SOFTNESS)
	_set_parameter("vehicle_atlas", VEHICLES)
	_set_parameter("travel_speed", UITokens.TRADE_SPEED)
	_set_parameter("stale_fade_seconds", UITokens.TRADE_FADE_SECONDS)
	_info.resize(UITokens.TRADE_ROUTE_CAP)
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE
	var instances := MultiMesh.new()
	instances.transform_format = MultiMesh.TRANSFORM_2D
	instances.use_custom_data = true
	instances.mesh = mesh
	instances.instance_count = UITokens.TRADE_VEHICLE_CAP
	instances.visible_instance_count = 0
	_batch = MultiMeshInstance2D.new()
	_batch.name = "TradeVehicles"
	_batch.multimesh = instances
	_batch.texture = VEHICLES
	_batch.material = _material
	_shadow_batch = MultiMeshInstance2D.new()
	_shadow_batch.name = "TradeShadows"
	_shadow_batch.multimesh = instances
	_shadow_batch.texture = VEHICLES
	_shadow_batch.material = _shadow_material
	_shadow_batch.z_index = -1
	add_child(_shadow_batch)
	add_child(_batch)


func _set_parameter(name: String, value: Variant) -> void:
	if _material != null:
		_material.set_shader_parameter(name, value)
	if _shadow_material != null:
		_shadow_material.set_shader_parameter(name, value)


## Called by HexRenderer when daylight state changes, never by per-vehicle CPU work.
func set_daylight_parameters(values: Dictionary) -> void:
	_ensure_batch()
	for name in values:
		if not _lighting_values.has(name) or _lighting_values[name] != values[name]:
			_lighting_values[name] = values[name]
			_set_parameter(name, values[name])


## Static shared map fields; rebinding and asynchronous bake completion use this boundary.
func set_terrain_lighting(world: WorldData, source: ShaderMaterial) -> void:
	_ensure_batch()
	if world == null:
		for name in ["terrain_normal_tex_bound", "terrain_horizon_tex_bound", "gi_lut_bound"]:
			_set_parameter(name, false)
		return
	_set_parameter("world_origin", world.world_bounds.position)
	_set_parameter("world_size", world.world_bounds.size.max(Vector2(0.0001, 0.0001)))
	_set_parameter("wrap_origin_x", 0.0)
	_set_parameter("wrap_period_x", world.wrap_period_x)
	var tiles: Variant = world.visual_tiles
	var tiled := tiles != null and bool(tiles.ready) and String(tiles.layout.mode) == "tiled"
	if tiled != _shader_tiled:
		_shader_tiled = tiled
		var variant := Shader.new()
		variant.code = ("#define MAP_VISUAL_TILED\n" if tiled else "") + VEHICLE_SHADER.code
		_material.shader = variant
		_shadow_material.shader = variant
		_shadow_material.set_shader_parameter("shadow_pass", true)
	if tiled:
		_set_parameter("visual_horizon_tiles", tiles.horizon)
		_set_parameter("visual_terrain_normal_tiles", tiles.terrain_normal)
		var layout: Variant = tiles.layout
		_set_parameter("visual_domain_origin", layout.visual_domain.position)
		_set_parameter("visual_domain_size", layout.visual_domain.size)
		for pair in [["visual_grid_size", layout.grid_size],
				["visual_interior_size", layout.interior_size],
				["visual_layer_size", layout.layer_size],
				["visual_logical_resolution", layout.logical_size]]:
			_set_parameter(pair[0], Vector2(pair[1]))
		_set_parameter("visual_gutter_px", float(layout.gutter_px))
	else:
		_set_parameter("terrain_horizon_tex", world.terrain_horizon_tex)
		_set_parameter("terrain_normal_tex", world.terrain_normal_tex)
	_set_parameter("terrain_horizon_tex_bound",
		bool(tiles.horizon_ready) if tiled else world.terrain_horizon_tex != null)
	_set_parameter("terrain_normal_tex_bound",
		tiles.terrain_normal != null if tiled else world.terrain_normal_tex != null)
	if source != null:
		for name in ["terrain_horizon_strength", "terrain_horizon_softness", "terrain_horizon_max_angle",
				"terrain_normal_influence", "gi_horizon_lut", "gi_lut_bound", "gi_ao_strength",
				"gi_ao_floor", "gi_ao_smoothing", "gi_bent_strength", "gi_normal_floor"]:
			var value: Variant = source.get_shader_parameter(name)
			if value != null:
				_set_parameter(name, value)


func _process(delta: float) -> void:
	if _map == null or not is_instance_valid(_camera) or not is_instance_valid(_economy):
		return
	_wall_time += delta
	if not _external_camera:
		var inverse := get_viewport().get_canvas_transform().affine_inverse()
		_camera_rect = Rect2(inverse * Vector2.ZERO,
			inverse.basis_xform(get_viewport_rect().size))
		_camera_center = _camera_rect.get_center()
		_camera_zoom = _camera.zoom.x
	if _camera_zoom < UITokens.TRADE_MIN_ZOOM:
		_batch.visible = false
		_shadow_batch.visible = false
		_unsubscribe()
		return
	_batch.visible = true
	_shadow_batch.visible = _quality >= 2 and not OS.has_feature("web")
	_update_bounds()
	if _clock == null or not _clock.paused:
		_visual_time += delta
	_sync_visibility()
	if not _batch.visible:
		return
	_set_parameter("visual_seconds", _visual_time)
	_set_parameter("wall_seconds", _wall_time)
	_set_parameter("camera_x", _camera_center.x)
	_set_parameter("reduced_motion", UIAnimation.reduced_motion())
	_set_parameter("layer_alpha", smoothstep(
		UITokens.TRADE_MIN_ZOOM, UITokens.TRADE_FULL_ZOOM, _camera_zoom))
	_set_parameter("vehicle_size", minf(UITokens.TRADE_VEHICLE_WORLD_SIZE,
		UITokens.TRADE_VEHICLE_SCREEN_CAP / maxf(0.01, _camera_zoom)))
	if _wall_time >= _next_refresh:
		_next_refresh = _wall_time + (UITokens.TRADE_LOW_REFRESH_SECONDS
			if _low_quality() else UITokens.TRADE_REFRESH_SECONDS)
		_refresh()


func _sync_visibility() -> void:
	var fog: bool = bool(_host.is_fog_of_war_enabled()) and _map.fog_solved
	if fog and _map.visible_arr.size() != _map.width * _map.height:
		_batch.visible = false
		_shadow_batch.visible = false
		_vision_revision = -1
		return
	if _vision_revision == _map.vision_revision and _fog_enabled == fog:
		return
	_vision_revision = _map.vision_revision
	_fog_enabled = fog
	_set_parameter("fog_enabled", fog)
	if not fog:
		return
	var image := Image.create_from_data(_map.width, _map.height, false,
		Image.FORMAT_R8, _map.visible_arr)
	if _visibility == null or _visibility.get_width() != _map.width \
			or _visibility.get_height() != _map.height:
		_visibility = ImageTexture.create_from_image(image)
		_set_parameter("visibility_texture", _visibility)
	else:
		_visibility.update(image)


func _selected_cell() -> int:
	if _player == null:
		return -1
	var cell = _player.selected_cell()
	return int(cell.index) if cell != null else -1


func _visible(cell: int) -> bool:
	return cell >= 0 and cell < _map.cell_count() and (not _fog_enabled or
		(cell < _map.visible_arr.size() and _map.visible_arr[cell] != 0))


func _interest_cells() -> PackedInt32Array:
	var rect := _camera_rect.grow(_hex_size * 2.0)
	if rect == _last_view and _interest.size() > 0:
		return _interest
	_last_view = rect
	_interest.clear()
	var step_x := sqrt(3.0) * _hex_size
	var row_first := maxi(0, floori(rect.position.y / (_hex_size * 1.5)) - 1)
	var row_last := mini(_map.height - 1, ceili(rect.end.y / (_hex_size * 1.5)) + 1)
	# Sampling a huge viewport remains bounded; this is visual interest, not a
	# claim that every market was inspected. The native scan has its own cap.
	var columns := maxi(1, ceili(rect.size.x / step_x) + 3)
	var stride := maxi(1, ceili(sqrt(float(maxi(0, row_last - row_first + 1) * columns)
		/ float(INTEREST_CAP))))
	for row in range(row_first, row_last + 1, stride):
		var first := floori(rect.position.x / step_x - 0.5 * (row & 1)) - 1
		for col in range(first, first + mini(columns, _map.width), stride):
			_interest.append(row * _map.width + posmod(col, _map.width))
			if _interest.size() >= INTEREST_CAP:
				return _interest
	return _interest


func _refresh() -> void:
	var started := Time.get_ticks_usec()
	var mask := _map.visible_arr if _fog_enabled else PackedByteArray()
	var snapshot: Dictionary = _economy.trade_visual_snapshot(_interest_cells(), mask,
		_map.vision_revision * 2 + int(_fog_enabled), _selected_cell(), true)
	_subscribed = true
	_stats.query_usec = Time.get_ticks_usec() - started
	if bool(snapshot.get("ok", false)):
		for key in ["native_usec", "memory_bytes", "scanned_orders", "expanded_nodes",
			"cache_hits", "pending_routes", "snapshot_day"]:
			_stats[key] = int(snapshot.get(key, 0))
		apply_snapshot(snapshot)
	else:
		_expire_records()


## Public for fixture tests; production only supplies native committed views.
func apply_snapshot(snapshot: Dictionary) -> void:
	if not bool(snapshot.get("ok", false)) or _map == null:
		return
	var serial := int(snapshot.get("serial", -1))
	if serial == _serial:
		_expire_records()
		return
	_serial = serial
	var topology := int(snapshot.get("topology_hash", 0))
	var countries := int(snapshot.get("country_topology_hash", 0))
	var rebuild := _selected_cell() != _last_selected
	if topology != _last_topology or countries != _last_country_topology:
		_records.clear()
		rebuild = true
		_last_topology = topology
		_last_country_topology = countries
	var sources: PackedInt32Array = snapshot.get("source_cells", PackedInt32Array())
	var destinations: PackedInt32Array = snapshot.get("destination_cells", PackedInt32Array())
	var offsets: PackedInt32Array = snapshot.get("route_offsets", PackedInt32Array())
	var cells: PackedInt32Array = snapshot.get("route_cells", PackedInt32Array())
	var modes: PackedByteArray = snapshot.get("edge_modes", PackedByteArray())
	var eras: PackedInt32Array = snapshot.get("era_indices", PackedInt32Array())
	var intensity: PackedInt32Array = snapshot.get("intensity", PackedInt32Array())
	var capabilities: PackedByteArray = snapshot.get("capabilities", PackedByteArray())
	if destinations.size() != sources.size() or offsets.size() != sources.size() + 1 \
			or modes.size() != cells.size() or eras.size() != sources.size() \
			or intensity.size() != sources.size():
		return
	for record in _records.values():
		if bool(record.active):
			record.seen = _wall_time
			record.active = false
	for i in mini(sources.size(), _route_cap()):
		var a := sources[i]
		var b := destinations[i]
		var begin := offsets[i]
		var end := offsets[i + 1]
		if not _visible(a) or not _visible(b) or begin < 0 or end > cells.size() \
				or end - begin < 2 or end - begin > PATH_WIDTH:
			continue
		var key := "%d:%d" % [a, b]
		var cap := int(capabilities[i]) if i < capabilities.size() else 0
		var old: Dictionary = _records.get(key, {})
		if old.is_empty() or int(old.get("capability", -1)) != cap:
			_records[key] = {"source": a, "destination": b, "era": clampi(eras[i], 0, 10),
				"capability": cap, "intensity": clampi(intensity[i], 1, 3),
				"cells": cells.slice(begin, end), "modes": modes.slice(begin, end),
				"seen": _wall_time, "active": true}
			rebuild = true
		else:
			var era := clampi(eras[i], 0, 10)
			var strength := clampi(intensity[i], 1, 3)
			rebuild = rebuild or int(old.era) != era or int(old.intensity) != strength
			old.era = era
			old.intensity = strength
			old.active = true
			old.seen = _wall_time
	var before_count := _records.size()
	_expire_records(false)
	if rebuild or before_count != _records.size():
		_rebuild_upload()
	else:
		# Same route key + topology + capability means identical geometry. Only
		# refresh liveness; never upload 512 KiB for an unchanged economic day.
		for row in _row_keys.size():
			var record: Dictionary = _records[_row_keys[row]]
			var info := _info[row]
			info.z = float(record.seen)
			info.w = float(record.active)
			_info[row] = info
		_set_parameter("route_info", _info)
		_stats.upload_bytes = 0


func _expire_records(upload: bool = true) -> void:
	var changed := false
	for key in _records.keys():
		var record: Dictionary = _records[key]
		if not _visible(int(record.source)) or not _visible(int(record.destination)) \
				or (not bool(record.active) and _wall_time - float(record.seen) >= UITokens.TRADE_FADE_SECONDS):
			_records.erase(key)
			changed = true
	if changed and upload:
		_rebuild_upload()


func _rebuild_upload() -> void:
	if _map == null or _economy == null:
		return
	if _records.is_empty():
		_row_keys.clear()
		_batch.multimesh.visible_instance_count = 0
		_stats.vehicle_count = 0
		_stats.route_count = 0
		_stats.upload_bytes = 0
		return
	var selected := _selected_cell()
	_last_selected = selected
	var keys: Array = _records.keys()
	keys.sort_custom(func(a, b):
		var ra: Dictionary = _records[a]
		var rb: Dictionary = _records[b]
		var ap: bool = ra.source == selected or ra.destination == selected
		var bp: bool = rb.source == selected or rb.destination == selected
		return ap if ap != bp else String(a) < String(b))
	_row_keys.clear()
	var cells := PackedInt32Array()
	var modes := PackedByteArray()
	var offsets := PackedInt32Array([0])
	for key in keys:
		if _row_keys.size() >= _route_cap():
			break
		_row_keys.append(String(key))
		cells.append_array(_records[key].cells)
		modes.append_array(_records[key].modes)
		offsets.append(cells.size())
	var baked: Dictionary = _economy.bake_trade_visual_paths({"route_cells": cells,
		"edge_modes": modes, "route_offsets": offsets}, _map.width, _hex_size)
	if not bool(baked.get("ok", false)):
		_batch.multimesh.visible_instance_count = 0
		return
	var bytes: PackedByteArray = baked.path_bytes
	var image := Image.create_from_data(PATH_WIDTH, UITokens.TRADE_ROUTE_CAP,
		false, Image.FORMAT_RGBAF, bytes)
	if _paths == null:
		_paths = ImageTexture.create_from_image(image)
		_set_parameter("path_texture", _paths)
	else:
		_paths.update(image)
	var counts: PackedInt32Array = baked.point_counts
	var lengths: PackedFloat32Array = baked.path_lengths
	_info.fill(Vector4(2.0, 1.0, -100.0, 0.0))
	var vehicle := 0
	for row in _row_keys.size():
		var key := _row_keys[row]
		var record: Dictionary = _records[key]
		_info[row] = Vector4(float(counts[row]), lengths[row], float(record.seen), float(record.active))
		var count := mini(int(record.intensity), maxi(1,
			(_vehicle_cap() - vehicle) / maxi(1, _row_keys.size() - row)))
		count = mini(count, maxi(1, floori(lengths[row] / (UITokens.TRADE_VEHICLE_WORLD_SIZE * 1.6))))
		for index in count:
			# Stable route-derived phase survives insertion/removal/reordering.
			var phase := fposmod(float(absi(key.hash()) % 1009) / 1009.0 + float(index) / float(count), 1.0)
			_batch.multimesh.set_instance_transform_2d(vehicle, Transform2D.IDENTITY)
			_batch.multimesh.set_instance_custom_data(vehicle, Color(float(row), phase,
				float(ERA_ROWS[int(record.era)]), 0.0))
			vehicle += 1
	_set_parameter("route_info", _info)
	_update_bounds()
	_batch.multimesh.visible_instance_count = vehicle
	_stats.vehicle_count = vehicle
	_stats.route_count = _row_keys.size()
	_stats.upload_bytes = bytes.size()


func _update_bounds() -> void:
	if _bounds_rect == _camera_rect or _batch == null or _map == null:
		return
	_bounds_rect = _camera_rect
	# GPU moves vertices to the nearest camera copy. Update the CPU culling
	# box when panning, including when cached geometry needs no new upload.
	var padding := _hex_size * 4.0
	_batch.multimesh.custom_aabb = AABB(Vector3(_camera_rect.position.x - padding,
		-padding, -1.0), Vector3(maxf(_wrap, _camera_rect.size.x) + padding * 2.0,
		float(_map.height) * _hex_size * 1.5 + padding * 2.0, 2.0))


func debug_snapshot() -> Dictionary:
	var out := _stats.duplicate()
	out["visual_seconds"] = _visual_time
	out["wall_seconds"] = _wall_time
	out["subscribed"] = _subscribed
	out["visible"] = _batch != null and _batch.visible
	out["record_count"] = _records.size()
	out["shadow_visible"] = _shadow_batch != null and _shadow_batch.visible
	out["terrain_tiled"] = _shader_tiled
	return out
