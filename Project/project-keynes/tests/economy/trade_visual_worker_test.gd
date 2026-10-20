extends SceneTree

const Fixture = preload("res://tests/economy/trade_visual_fixture.gd")
const Layer = preload("res://scripts/rendering/trade_activity_layer.gd")
class HostStub extends Node:
	var hex_size := 22.0
	func map_wrap_period_x() -> float: return 0.0
	func is_fog_of_war_enabled() -> bool: return false
var failures := 0
func _init() -> void: call_deferred("_run")
func expect(label: String, passed: bool) -> void:
	print("[%s] %s" % ["PASS" if passed else "FAIL", label])
	if not passed: failures += 1

func _run() -> void:
	var context := Fixture.make(8)
	expect("real trade fixture configures", bool(context.get("ok", false)))
	if not bool(context.get("ok", false)):
		quit(1)
		return
	var ext: Object = context.ext
	var day: int = Fixture.find_trade(context)
	expect("orders exist before worker ownership transfer", day >= 0)
	# The economic fixture does not tick Country. Bring its contiguous day
	# watermark to the same boundary before handing both domains to the worker.
	for country_day in range(day + 1):
		ext.run_country_slice({"day_index": country_day})
	var captured_catalog: Dictionary = ext.capture_country_pod_catalog()
	var captured_country: Dictionary = ext.capture_country_runtime_snapshot()
	expect("Country committed inputs publish", bool(captured_catalog.get("ok", false))
		and bool(captured_country.get("ok", false)))
	var terrain := PackedByteArray()
	terrain.resize(8)
	terrain.fill(2)
	var temperatures := PackedFloat32Array()
	temperatures.resize(8)
	temperatures.fill(15.0)
	var moisture := PackedFloat32Array()
	moisture.resize(8)
	moisture.fill(0.5)
	var offsets := PackedInt32Array()
	offsets.resize(9)
	var inputs: Dictionary = ext.capture_runtime_inputs({"generation": 1, "day": day,
		"terrain": terrain, "neighbor_offsets": offsets, "neighbor_indices": PackedInt32Array(),
		"cell_temp": temperatures, "cell_moisture": moisture, "cell_plant_available_water": moisture})
	expect("worker environment inputs publish", bool(inputs.get("ok", false)))
	ext.configure_runtime_graph({"enabled": true, "day": day})
	var started: Dictionary = ext.start_runtime_worker({"simulation_thread_mode": "ACTIVE",
		"graph_coverage_complete": true, "authoritative_domain_mask": 0x104,
		"economy_production_writer": "compact_slice", "day": day,
		"speed_days_per_second": 4.0, "paused": false})
	expect("Country/Economy ACTIVE worker starts", bool(started.get("ok", false)))
	if not bool(started.get("ok", false)):
		print(started)
		quit(1)
		return
	var facade := EconomyFacade.new()
	facade._configured = true
	facade._world_ext = ext
	var map := MapData.new(8, 1)
	for col in 8:
		map.set_cell(HexCell.new(col, 0))
	map._build_indices()
	var camera := Camera2D.new()
	root.add_child(camera)
	camera.position = Vector2(120, 0)
	camera.make_current()
	var host := HostStub.new()
	root.add_child(host)
	var layer := Layer.new()
	root.add_child(layer)
	layer.configure(map, camera, host, null, facade, null)
	var deadline := Time.get_ticks_msec() + 12000
	var observed := false
	var ready := false
	while Time.get_ticks_msec() < deadline:
		ext.capture_economy_day_inputs(-1)
		ext.advance_runtime_pulse(day, 0.0, 1.0, 4000)
		var runtime: Dictionary = ext.get_runtime_thread_report()
		ready = (int(runtime.get("authoritative_domain_mask", 0)) & 0x104) == 0x104
		if int(layer.debug_snapshot().vehicle_count) > 0:
			observed = true
		if observed and ready and int(layer.debug_snapshot().get("snapshot_day", -1)) > day:
			break
		await create_timer(0.01).timeout
	expect("native worker owns the tested domains", ready)
	expect("real in-flight orders drive the production facade and batch", observed)
	expect("worker publishes a later committed visual view",
		int(layer.debug_snapshot().get("snapshot_day", -1)) > day)
	print("[trade-worker] ", layer.debug_snapshot())
	var report: Dictionary = ext.get_runtime_thread_report()
	print("[trade-worker-status] ", {"mask": report.get("authoritative_domain_mask", 0),
		"blocker": report.get("simulation_worker_blocker", ""), "day": report.get("simulation_committed_day", -1)})
	expect("observer does not fault worker", not bool(report.get("fatal", false)))
	ext.set_runtime_clock(true, 0.0)
	ext.request_runtime_stop()
	layer.queue_free()
	host.queue_free()
	camera.queue_free()
	await process_frame
	print("=== trade visual ACTIVE worker: %d failures ===" % failures)
	quit(0 if failures == 0 else 1)
