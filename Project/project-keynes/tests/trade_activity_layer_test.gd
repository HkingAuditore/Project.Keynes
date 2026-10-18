extends SceneTree

const Lighting = preload("res://tests/trade_lighting_fixture.gd")
const Layer = preload("res://scripts/rendering/trade_activity_layer.gd")

class HostStub extends Node:
	var hex_size := 22.0
	var fog := true
	func map_wrap_period_x() -> float: return 80.0 * sqrt(3.0) * hex_size
	func is_fog_of_war_enabled() -> bool: return fog

class PlayerStub extends RefCounted:
	var cell: HexCell
	func selected_cell(): return cell

class EconomyStub extends RefCounted:
	var queries := 0
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	func trade_visual_snapshot(_cells: PackedInt32Array, _visible: PackedByteArray,
			_revision: int, _selected: int, enabled: bool) -> Dictionary:
		if enabled: queries += 1
		return {"ok": false}
	func bake_trade_visual_paths(snapshot: Dictionary, width: int, size: float) -> Dictionary:
		return ext.bake_trade_visual_paths(snapshot, width, size)

var failures := 0
var checks := 0
var _capture := ""

func _init() -> void:
	call_deferred("_run")

func expect(label: String, passed: bool) -> void:
	checks += 1
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed: failures += 1

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture_dir="):
			_capture = argument.trim_prefix("capture_dir=")
	root.size = Vector2i(1280, 720)
	var holder := Node2D.new()
	root.add_child(holder)
	var map := MapData.new(80, 5)
	for row in 5:
		for col in 80:
			var cube := HexUtils.offset_to_cube(col, row)
			map.set_cell(HexCell.new(cube.x, cube.y))
	map._build_indices()
	map.visible_arr.resize(400)
	map.visible_arr.fill(1)
	map.fog_solved = true
	var camera := Camera2D.new()
	holder.add_child(camera)
	camera.position = Vector2(550, 70)
	camera.zoom = Vector2(1.0, 1.0)
	camera.make_current()
	var host := HostStub.new()
	holder.add_child(host)
	var player := PlayerStub.new()
	var economy := EconomyStub.new()
	var clock := WorldClock.new()
	holder.add_child(clock)
	clock.set_process(false)
	var layer := Layer.new()
	holder.add_child(layer)
	layer.configure(map, camera, host, player, economy, clock)
	layer.set_process(false)
	await process_frame
	layer.set_camera_view(Rect2(-90, -150, 1280, 720), camera.position, 1.0)
	layer._process(0.01)
	layer.apply_snapshot(snapshot(50))
	expect("desktop route and vehicle counts are bounded", layer.debug_snapshot().route_count == 32
		and layer.debug_snapshot().vehicle_count <= 96 and layer.debug_snapshot().vehicle_count > 0)
	expect("two fixed passes share one MultiMesh, no per-vehicle nodes", layer.get_child_count() == 2
		and layer._batch.multimesh == layer._shadow_batch.multimesh)
	expect("fixed upload size", layer.debug_snapshot().upload_bytes == 524288)
	var unchanged := snapshot(32)
	unchanged.serial = 2
	layer.apply_snapshot(unchanged)
	expect("unchanged paths do not upload again", layer.debug_snapshot().upload_bytes == 0)
	var old_bounds: AABB = layer._batch.multimesh.custom_aabb
	layer.set_camera_view(Rect2(4000, -150, 1280, 720), Vector2(4600, 70), 1.0)
	layer._process(0.01)
	expect("panning updates culling bounds without path uploads",
		layer._batch.multimesh.custom_aabb.position.x > old_bounds.position.x)
	layer.set_camera_view(Rect2(-90, -150, 1280, 720), camera.position, 1.0)
	player.cell = map.cell_at(62)
	layer._rebuild_upload()
	expect("selected cell is prioritized", layer._row_keys[0] == "62:63")
	layer.set_quality(0)
	expect("low-quality/mobile caps", layer.debug_snapshot().route_count == 12
		and layer.debug_snapshot().vehicle_count <= 24)
	layer.set_quality(2)
	var visual_before: float = layer.debug_snapshot().visual_seconds
	clock.paused = true
	layer._process(0.1)
	expect("pause freezes motion", is_equal_approx(visual_before, layer.debug_snapshot().visual_seconds))
	clock.paused = false
	clock.speed_multiplier = 100.0
	layer._process(0.1)
	expect("fast-forward keeps wall-clock animation speed",
		is_equal_approx(float(layer.debug_snapshot().visual_seconds) - visual_before, 0.1))
	var queries: int = economy.queries
	layer.set_camera_view(Rect2(-90, -150, 1280, 720), camera.position, 0.2)
	layer._process(0.1)
	expect("far zoom stops drawing and new queries", not bool(layer.debug_snapshot().visible)
		and not layer._shadow_batch.visible
		and economy.queries == queries and not bool(layer.debug_snapshot().subscribed))
	layer.set_camera_view(Rect2(-90, -150, 1280, 720), camera.position, 1.0)
	layer._process(0.01)
	map.visible_arr[63] = 0
	map.vision_revision += 1
	layer._process(0.01)
	expect("vision texture updates immediately without economy refresh", layer._vision_revision == map.vision_revision)
	layer._expire_records()
	expect("hidden endpoint discards the selected route", not layer._records.has("62:63"))
	map.visible_arr[63] = 1
	map.vision_revision += 1
	layer._process(0.01)
	var next: Dictionary = snapshot(1)
	next.serial = 3
	layer.apply_snapshot(next)
	expect("stopping routes retain only a bounded fade", layer.debug_snapshot().record_count <= 32)
	layer._wall_time += 2.01
	layer._expire_records()
	expect("stopped traffic expires within two seconds", layer.debug_snapshot().record_count == 1)
	for era in 11:
		expect("era %d has a land/water sprite pair" % era, Layer.ERA_ROWS[era] >= 0
			and Layer.ERA_ROWS[era] <= 10 and Layer.ERA_ROWS[era] % 2 == 0)
	layer.clear()
	expect("rebind clears old buffers and subscriptions", layer.debug_snapshot().record_count == 0
		and layer.debug_snapshot().vehicle_count == 0 and not bool(layer.debug_snapshot().subscribed))
	layer.configure(map, camera, host, player, economy, clock)
	layer.set_process(false)
	layer.set_camera_view(Rect2(-90, -150, 1280, 720), camera.position, 1.0)
	layer._process(0.01)
	var demo := snapshot(12)
	for i in 12:
		demo.era_indices[i] = [0, 1, 4, 6, 7, 8][i / 2]
		var begin: int = demo.route_offsets[i]
		demo.edge_modes[begin] = i % 2
	layer.apply_snapshot(demo)
	Lighting.bind(layer, 80, 5)
	await _save("all_styles")
	var material: ShaderMaterial = layer._material
	material.set_shader_parameter("reduced_motion", true)
	await _save("reduced_motion")
	print("=== trade activity layer: %d checks, %d failures ===" % [checks, failures])
	holder.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func snapshot(count: int) -> Dictionary:
	var out := {"ok": true, "serial": 1, "topology_hash": 1, "country_topology_hash": 1,
		"source_cells": PackedInt32Array(), "destination_cells": PackedInt32Array(),
		"route_offsets": PackedInt32Array([0]), "route_cells": PackedInt32Array(),
		"edge_modes": PackedByteArray(), "era_indices": PackedInt32Array(),
		"intensity": PackedInt32Array()}
	for i in count:
		out.source_cells.append(i * 2)
		out.destination_cells.append(i * 2 + 1)
		out.route_cells.append_array(PackedInt32Array([i * 2, i * 2 + 1]))
		out.edge_modes.append_array(PackedByteArray([0, 0]))
		out.route_offsets.append(out.route_cells.size())
		out.era_indices.append(i % 11)
		out.intensity.append(3)
	return out

func _save(label: String) -> void:
	if _capture.is_empty() or DisplayServer.get_name() == "headless": return
	for frame in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(_capture)
	root.get_texture().get_image().save_png(_capture.path_join(label + ".png"))
