extends SceneTree

## Renderer/upload stress, independent of map generation and economic scale.
## 500x400 cell address space, maximum 32x1024 path points and 96 vehicles.
const Lighting = preload("res://tests/economy/trade_lighting_fixture.gd")
const Layer = preload("res://scripts/rendering/trade_activity_layer.gd")
class StressMap extends MapData:
	func _init(w: int, h: int) -> void: super(w, h)
	func cell_count() -> int: return width * height
class HostStub extends Node:
	var hex_size := 22.0
	var width := 500
	func map_wrap_period_x() -> float: return float(width) * sqrt(3.0) * hex_size
	func is_fog_of_war_enabled() -> bool: return false
class EconomyStub extends RefCounted:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	var source: Dictionary
	var serial := 0
	func trade_visual_snapshot(_cells: PackedInt32Array, _visible: PackedByteArray,
			_revision: int, _selected: int, enabled: bool) -> Dictionary:
		if not enabled: return {"ok": false}
		serial += 1
		source.serial = serial
		return source
	func bake_trade_visual_paths(snapshot: Dictionary, width: int, size: float) -> Dictionary:
		return ext.bake_trade_visual_paths(snapshot, width, size)

var _width := 500
var _height := 400
var _point_count := 1024
func _init() -> void: call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	if OS.get_cmdline_user_args().has("normal"):
		_width = 60
		_height = 40
		_point_count = 32
	var map := StressMap.new(_width, _height)
	var camera := Camera2D.new()
	root.add_child(camera)
	camera.position = Vector2(float(_width) * 19.0, 500)
	camera.zoom = Vector2(0.7, 0.7)
	camera.make_current()
	var host := HostStub.new()
	host.width = _width
	root.add_child(host)
	var economy := EconomyStub.new()
	economy.source = _maximum_paths()
	var layer := Layer.new()
	root.add_child(layer)
	layer.configure(map, camera, host, null, economy, null)
	layer.set_process(false)
	var lighting: Dictionary = Lighting.bind(layer, _width, _height, true)
	layer.set_daylight_parameters({"day_night_enabled": false, "tod_debug_sun_position_enabled": true, "tod_sun_dir": Vector3(0.7, -0.4, 0.65).normalized()})
	await process_frame
	layer.set_camera_view(Rect2(camera.position - Vector2(1500, 800), Vector2(3000, 1600)), camera.position, 0.7)
	layer._process(0.01)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	for frame in 60: await process_frame
	var frames := PackedFloat64Array()
	var refreshes := PackedFloat64Array()
	var gpu_on := PackedFloat64Array()
	var gpu_off := PackedFloat64Array()
	var upload := PackedFloat64Array()
	for frame in 360:
		if frame % 45 == 0:
			camera.position.x += host.map_wrap_period_x() / 3.0
			camera.force_update_scroll()
			layer.set_camera_view(Rect2(camera.position - Vector2(1500, 800), Vector2(3000, 1600)), camera.position, 0.7)
		var started := Time.get_ticks_usec()
		# Include the renderer's event-driven daylight push in observer CPU cost.
		layer.set_daylight_parameters({"season_phase": 1.0 + frame * 0.0001,
			"day_phase": float(frame) / 1000.0, "axial_tilt_rad": 0.4101523,
			"day_night_enabled": false, "tod_debug_sun_position_enabled": true,
			"tod_debug_sun_uv": Vector2(0.25, 0.5), "tod_debug_sun_height_scale": 1.0,
			"tod_sun_dir": Vector3(0.7, -0.4, 0.65).normalized(), "tod_exposure": 1.0})
		layer._process(1.0 / 60.0)
		var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
		frames.append(elapsed)
		if frame % 30 == 0:
			started = Time.get_ticks_usec()
			layer._refresh()
			refreshes.append(float(Time.get_ticks_usec() - started) / 1000.0)
		await process_frame
		gpu_on.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
	layer.visible = false
	for frame in 30: await process_frame
	for frame in 240:
		await process_frame
		gpu_off.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
	for i in 100:
		var started := Time.get_ticks_usec()
		economy.ext.bake_trade_visual_paths(economy.source, _width, 22.0)
		upload.append(float(Time.get_ticks_usec() - started) / 1000.0)
	var out := {"kind": "renderer_geometry_stress", "lighting": "center_TOD_normal_horizon_GI_tiled_with_shadows", "map_dimensions": [_width, _height],
		"renderer": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name(),
		"device": RenderingServer.get_video_adapter_name(),
		"cpu_frame_ms": _metrics(frames), "cpu_refresh_ms": _metrics(refreshes),
		"native_upload_bake_ms": _metrics(upload), "gpu_on_ms": _metrics(gpu_on),
		"gpu_off_ms": _metrics(gpu_off), "visual": layer.debug_snapshot()}
	out["gpu_p95_increment_ms"] = maxf(0.0, float(out.gpu_on_ms.p95) - float(out.gpu_off_ms.p95))
	out["passes"] = float(out.cpu_frame_ms.p95) <= 0.3 and float(out.native_upload_bake_ms.p95) <= 0.5 \
		and float(out.gpu_p95_increment_ms) <= 0.5
	DirAccess.make_dir_recursive_absolute("res://tmp/trade_activity_qa")
	var suffix := "_normal" if _width == 60 else ""
	var file := FileAccess.open("res://tmp/trade_activity_qa/perf_%s%s.json" % [out.driver, suffix], FileAccess.WRITE)
	file.store_string(JSON.stringify(out, "\t"))
	file.close()
	print("[trade-visual-perf] ", JSON.stringify(out))
	lighting.clear()
	layer.queue_free()
	host.queue_free()
	camera.queue_free()
	await process_frame
	quit(0 if bool(out.passes) else 1)

func _metrics(values: PackedFloat64Array) -> Dictionary:
	values.sort()
	var total := 0.0
	for value in values: total += value
	return {"avg": total / maxf(1, values.size()), "p95": values[maxi(0, ceili(values.size() * 0.95) - 1)],
		"max": values[-1], "samples": values.size()}

func _maximum_paths() -> Dictionary:
	var out := {"ok": true, "serial": 1, "topology_hash": 1, "country_topology_hash": 1,
		"source_cells": PackedInt32Array(), "destination_cells": PackedInt32Array(),
		"route_offsets": PackedInt32Array([0]), "route_cells": PackedInt32Array(),
		"edge_modes": PackedByteArray(), "era_indices": PackedInt32Array(), "intensity": PackedInt32Array()}
	for row in 32:
		var source := row * _width
		out.source_cells.append(source)
		out.destination_cells.append(source + _point_count - 1)
		for point in _point_count:
			out.route_cells.append(source + point)
			out.edge_modes.append(row % 2)
		out.route_offsets.append(out.route_cells.size())
		out.era_indices.append(row % 11)
		out.intensity.append(3)
	return out
