extends SceneTree

const Layer = preload("res://scripts/rendering/trade_activity_layer.gd")
const Lighting = preload("res://tests/trade_lighting_fixture.gd")
class TestMap extends MapData:
	func _init() -> void: super(40, 24)
	func cell_count() -> int: return width * height
class Host extends Node:
	var hex_size := 22.0
	func map_wrap_period_x() -> float: return 40 * sqrt(3.0) * hex_size
	func is_fog_of_war_enabled() -> bool: return false
class Economy extends RefCounted:
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	func trade_visual_snapshot(_a, _b, _c, _d, _enabled) -> Dictionary: return {"ok": false}
	func bake_trade_visual_paths(snapshot: Dictionary, width: int, size: float) -> Dictionary:
		return ext.bake_trade_visual_paths(snapshot, width, size)

var failures := 0
var checks := 0
var capture_dir := "res://tmp/trade_activity_qa/lighting"
var layer: TradeActivityLayer

func _init() -> void: call_deferred("_run")
func expect(label: String, passed: bool) -> void:
	checks += 1
	if not passed: failures += 1
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])

func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("capture_dir="): capture_dir = argument.trim_prefix("capture_dir=")
	root.size = Vector2i(1280, 900)
	root.transparent_bg = true
	var map := TestMap.new()
	var camera := Camera2D.new()
	root.add_child(camera)
	camera.position = Vector2(760, 396)
	camera.zoom = Vector2(0.75, 0.75)
	camera.make_current()
	var host := Host.new()
	root.add_child(host)
	var economy := Economy.new()
	layer = Layer.new()
	root.add_child(layer)
	layer.configure(map, camera, host, null, economy, null)
	layer.set_process(false)
	await process_frame
	layer.set_camera_view(Rect2(-100, -200, 1720, 1200), camera.position, 0.75)
	layer._process(0.01)
	var context := Lighting.bind(layer, 40, 24, false, Color(0.5, 0.5, 0, 1), 0)
	layer.set_daylight_parameters({"day_night_enabled": false, "tod_debug_sun_position_enabled": true,
		"tod_sun_dir": Vector3(0.75, -0.25, 0.61).normalized(), "tod_exposure": 1.0})
	layer._set_parameter("reduced_motion", true)
	layer._set_parameter("vehicle_size", 180.0) # Enlarged art QA only.
	layer.apply_snapshot(_snapshot(true))
	expect("both passes share geometry, paths and visibility", layer._batch.multimesh == layer._shadow_batch.multimesh
		and layer._material.get_shader_parameter("path_texture") == layer._shadow_material.get_shader_parameter("path_texture"))
	expect("legacy terrain fields are bound", bool(layer._material.get_shader_parameter("terrain_normal_tex_bound"))
		and bool(layer._material.get_shader_parameter("terrain_horizon_tex_bound")))
	if DisplayServer.get_name() == "headless":
		print("[SKIP] pixel checks require a graphical renderer")
	else:
		await _image("all_styles_topdown")
		# Switch to one central vehicle to isolate local daylight and terrain.
		var single := _snapshot(false)
		layer.apply_snapshot(single)
		layer._wall_time += 3.0
		layer._expire_records()
		layer._shadow_batch.visible = false
		var day := _metrics(await _image("day"))
		layer.set_daylight_parameters({"day_night_enabled": true, "day_phase": 0.95, "tod_debug_sun_position_enabled": false})
		var night := _metrics(await _image("night"))
		expect("local TOD darkens the same stationary vehicle at night", night.luma < day.luma * 0.65)
		layer.set_daylight_parameters({"day_night_enabled": false, "tod_debug_sun_position_enabled": true})
		context = Lighting.bind(layer, 40, 24, false, Color(0.95, 0.5, 0, 1), 0)
		var toward := _metrics(await _image("slope_toward_sun"))
		context = Lighting.bind(layer, 40, 24, false, Color(0.05, 0.5, 0, 1), 0)
		var away := _metrics(await _image("slope_away_from_sun"))
		expect("center terrain normal responds to sun direction", toward.luma > away.luma * 1.15)
		context = Lighting.bind(layer, 40, 24, false, Color(0.5, 0.5, 0, 1), 0xDD)
		var blocked := _metrics(await _image("horizon_occluded"))
		expect("terrain horizon occludes direct sun and sky", blocked.luma < day.luma * 0.8)
		layer.set_daylight_parameters({"tod_sun_dir": Vector3(0, 0, 1)})
		layer._set_parameter("gi_lut_bound", false)
		var no_gi := _metrics(await _image("sky_gi_off"))
		layer._set_parameter("gi_lut_bound", true)
		var gi := _metrics(await _image("sky_gi_on"))
		expect("Horizon GI reduces sky light independently of direct sun", gi.luma < no_gi.luma * 0.97)
		layer.set_daylight_parameters({"tod_sun_dir": Vector3(0.75, -0.25, 0.61).normalized()})
		context = Lighting.bind(layer, 40, 24, true, Color(0.5, 0.5, 0, 1), 0xDD)
		var tiled := _metrics(await _image("tiled_occluded"))
		expect("tiled shader matches legacy horizon decoding", absf(tiled.luma - blocked.luma) < 0.01)
		expect("tiled shader and both materials use the map arrays", layer._shader_tiled
			and layer._shadow_material.get_shader_parameter("visual_horizon_tiles") != null)
		layer.set_quality(1)
		var medium_blocked := _metrics(await _image("medium_occluded"))
		context = Lighting.bind(layer, 40, 24, true, Color(0.95, 0.05, 0, 1), 0)
		var medium_open := _metrics(await _image("medium_open"))
		expect("medium quality skips terrain normal and GI sampling", absf(medium_open.luma - medium_blocked.luma) < 0.005)
		expect("medium quality disables the shadow batch", not layer._shadow_batch.visible)
		layer.set_quality(2)
		context = Lighting.bind(layer, 40, 24, true, Color(0.5, 0.5, 0, 1), 0)
		var shadow := _metrics(await _image("cast_shadow"))
		layer._batch.visible = false
		var ellipse := await _image("ellipse_only")
		var ellipse_metrics := _metrics(ellipse)
		expect("shadow is one continuous soft ellipse without repeated silhouettes", _single_ellipse(ellipse))
		layer._batch.visible = true
		layer._shadow_batch.visible = false
		var no_shadow := _metrics(await _image("no_shadow"))
		expect("high quality shadow adds soft ellipse coverage", shadow.pixels > no_shadow.pixels + 20)
		layer._shadow_batch.visible = true
		layer.set_daylight_parameters({"tod_sun_dir": Vector3(-0.75, -0.25, 0.61).normalized()})
		await _image("opposite_sun_shadow")
		layer._batch.visible = false
		var opposite_ellipse := _metrics(await _image("opposite_ellipse_only"))
		layer._batch.visible = true
		expect("ellipse shadow follows sun azimuth", float(opposite_ellipse.center_x) - float(ellipse_metrics.center_x) > 5.0)
		layer.set_daylight_parameters({"day_night_enabled": true, "day_phase": 0.95, "tod_debug_sun_position_enabled": false})
		var night_shadow := _metrics(await _image("night_with_shadow"))
		layer._shadow_batch.visible = false
		var night_no_shadow := _metrics(await _image("night_without_shadow"))
		expect("sun cast shadows vanish at night", absi(int(night_shadow.pixels) - int(night_no_shadow.pixels)) < 3)
		# Calibrate against people and carts, separately from trucks. Zenith sun
		# isolates footprint size; low-sun stretching is checked independently.
		for style in [0, 2, 4, 10]:
			await _check_style_footprint(style)
		# A north/south route must rotate the canonical east-facing asset.
		var vertical := _snapshot(false)
		vertical.serial = 3
		vertical.destination_cells[0] = vertical.source_cells[0] + 40 * 4
		vertical.route_cells[1] = vertical.destination_cells[0]
		layer.apply_snapshot(vertical)
		layer._wall_time += 3.0
		layer._expire_records()
		var heading := _metrics(await _image("vertical_heading"))
		expect("top-down vehicle rotates with the route without stretching", heading.height > heading.width * 2)
		print("[trade-lighting-pixels] ", {"day": day, "night": night, "toward": toward,
			"away": away, "blocked": blocked, "gi_off": no_gi, "gi_on": gi,
			"tiled": tiled, "shadow": shadow, "no_shadow": no_shadow})
		# Ground-colour art preview, captured after all alpha-based pixel checks.
		root.transparent_bg = false
		RenderingServer.set_default_clear_color(Color(0.50, 0.54, 0.33))
		layer.set_daylight_parameters({"day_night_enabled": false, "tod_debug_sun_position_enabled": true,
			"tod_sun_dir": Vector3(0.75, -0.25, 0.61).normalized()})
		layer._shadow_batch.visible = true
		await _image("ellipse_preview")
		var overview := _snapshot(true)
		overview.serial = 900
		layer.apply_snapshot(overview)
		layer._wall_time += 3.0
		layer._expire_records()
		await _image("all_objects_preview")
	layer.clear()
	expect("clear releases previous map lighting fields", not bool(layer._material.get_shader_parameter("terrain_normal_tex_bound"))
		and layer._shadow_material.get_shader_parameter("visual_horizon_tiles") == null)
	print("=== trade lighting: %d checks, %d failures ===" % [checks, failures])
	context.clear()
	layer.queue_free()
	host.queue_free()
	camera.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _snapshot(all_styles: bool) -> Dictionary:
	var out := {"ok": true, "serial": 1 if all_styles else 2, "topology_hash": 1, "country_topology_hash": 1,
		"source_cells": PackedInt32Array(), "destination_cells": PackedInt32Array(),
		"route_offsets": PackedInt32Array([0]), "route_cells": PackedInt32Array(),
		"edge_modes": PackedByteArray(), "era_indices": PackedInt32Array(), "intensity": PackedInt32Array()}
	for i in (12 if all_styles else 1):
		var source := (4 + i / 2 * 3) * 40 + (4 if i % 2 == 0 else 22) if all_styles else 12 * 40 + 15
		var destination := source + 8
		out.source_cells.append(source)
		out.destination_cells.append(destination)
		out.route_cells.append_array(PackedInt32Array([source, destination]))
		out.edge_modes.append_array(PackedByteArray([i % 2, i % 2]))
		out.route_offsets.append(out.route_cells.size())
		out.era_indices.append([0, 1, 4, 6, 7, 8][i / 2] if all_styles else 8)
		out.intensity.append(1)
	return out

func _image(label: String) -> Image:
	for frame in 6: await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(capture_dir)
	image.save_png(capture_dir.path_join(label + ".png"))
	return image

func _metrics(image: Image) -> Dictionary:
	var total := 0.0
	var opaque := 0
	var pixels := 0
	var bounds := Rect2i()
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a > 0.05:
				bounds = Rect2i(x, y, 1, 1) if pixels == 0 else bounds.merge(Rect2i(x, y, 1, 1))
				pixels += 1
			if color.a < 0.5: continue
			total += color.get_luminance()
			opaque += 1
	return {"luma": total / maxf(1.0, opaque), "pixels": pixels, "opaque": opaque,
		"width": bounds.size.x, "height": bounds.size.y, "center_x": bounds.get_center().x}


# A convex ellipse has one connected interval on every horizontal scan line;
# its alpha increases to one peak/plateau then decreases (no ghost copies).
func _single_ellipse(image: Image) -> bool:
	var seen := false
	for y in image.get_height():
		var descending := false
		var previous := 0.0
		for x in image.get_width():
			var alpha := image.get_pixel(x, y).a
			seen = seen or alpha > 0.05
			if alpha < previous - 0.005:
				descending = true
			if descending and alpha > previous + 0.005:
				return false
			previous = alpha
	return seen


func _check_style_footprint(style: int) -> void:
	var name: String = {0: "porters", 2: "horse_cart", 4: "covered_wagon", 10: "truck"}[style]
	var sample := _snapshot(false)
	sample.serial = 100 + style
	sample.era_indices[0] = {0: 0, 2: 1, 4: 4, 10: 8}[style]
	layer.apply_snapshot(sample)
	layer.set_daylight_parameters({"day_night_enabled": false, "tod_debug_sun_position_enabled": true,
		"tod_sun_dir": Vector3(0, 0, 1)})
	layer._batch.visible = true
	layer._shadow_batch.visible = false
	var body := _metrics(await _image(name + "_body"))
	layer._batch.visible = false
	layer._shadow_batch.visible = true
	var footprint := _metrics(await _image(name + "_footprint"))
	expect(name + " ellipse fits the actual art without transparent padding", footprint.width <= body.width * 1.10
		and footprint.height <= body.height * 1.10 and footprint.width >= body.width * 0.55
		and footprint.height >= body.height * 0.55)
	layer.set_daylight_parameters({"tod_sun_dir": Vector3(0.96, 0.0, 0.28).normalized()})
	var low_sun := _metrics(await _image(name + "_low_sun"))
	expect(name + " low sun still stretches the shadow", low_sun.width > footprint.width * 1.15)
	layer._batch.visible = true
	layer.set_daylight_parameters({"tod_sun_dir": Vector3(0, 0, 1)})
	root.transparent_bg = false
	RenderingServer.set_default_clear_color(Color(0.50, 0.54, 0.33))
	await _image(name + "_preview")
	root.transparent_bg = true
	print("[trade-footprint] ", {"style": name, "body": body, "footprint": footprint, "low_sun": low_sun})
