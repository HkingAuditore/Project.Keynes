extends SceneTree

const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var large := OS.get_cmdline_user_args().has("--large")
	var width := 500 if large else 100
	var height := 400 if large else 80
	var begin := Time.get_ticks_usec()
	var map := Fixtures.make_map(width, height)
	var styles := Catalog.entries()
	var allowed := Catalog.presence_mask(styles)
	# All seven mammals, two cereals and diverse minerals on fertile land.
	for cell in map.cell_count():
		map.bio_occupancy_bits_arr[cell] = (1 << 20) - 1
		map.res_iron_ore_reserve_arr[cell] = 1000000.0
		map.res_coal_reserve_arr[cell] = 1000000.0
	map.visible_arr.fill(0)
	# A visible region near the end catches row-order starvation regressions.
	for cell in range(maxi(0, map.cell_count() - 4000), map.cell_count()):
		map.visible_arr[cell] = 1
	var fixture_ms := float(Time.get_ticks_usec() - begin) / 1000.0
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var world := WorldData.new()
	world.lut_dims = Vector2i(mini(2048, map.cell_count()), ceili(float(map.cell_count()) / 2048.0))
	world.world_bounds = Rect2(-30, -30, width * 38.2, height * 33.0)
	var layer := Layer.new()
	root.add_child(layer)
	begin = Time.get_ticks_usec()
	layer.configure(map, world, 22.0, intel)
	var configure_ms := float(Time.get_ticks_usec() - begin) / 1000.0
	layer.set_quality(2)
	layer.set_context(true, 20261016)
	var center := layer.cell_position(map.cell_count() - width * 4 - 20)
	layer.set_camera_view(Rect2(center - Vector2(960, 540), Vector2(1920, 1080)), center, 1.0)
	var times := []
	var first_observed_frame := -1
	for frame in 600:
		begin = Time.get_ticks_usec()
		layer.prepare_frame(float(frame) / 60.0, Vector3(0.4, -0.5, 0.8), {})
		layer.drain_one_upload()
		var elapsed := float(Time.get_ticks_usec() - begin) / 1000.0
		if frame >= 20:
			times.append(elapsed)
		if first_observed_frame < 0 and not intel.resource_observations.rows.is_empty():
			first_observed_frame = frame
		await process_frame
	times.sort()
	var report := {"cells": map.cell_count(), "fixture_ms": fixture_ms, "configure_ms": configure_ms,
		"first_observed_frame": first_observed_frame, "p50_ms": times[times.size() / 2],
		"p95_ms": times[floori(times.size() * 0.95)], "max_ms": times[-1], "layer": layer.diagnostics()}
	print("resource visual CPU perf: ", JSON.stringify(report))
	var output := "res://tmp/resource_visual_qa"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var file := FileAccess.open(output + "/cpu_%d.json" % map.cell_count(), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	var passed := int(layer.diagnostics().instances) > 0 and int(layer.diagnostics().instances) <= 20000 \
		and first_observed_frame <= 1 and float(report.p95_ms) <= 1.0
	layer.queue_free()
	await process_frame
	quit(0 if passed else 1)
