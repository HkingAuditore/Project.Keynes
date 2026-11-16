extends SceneTree

const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Geometry = preload("res://scripts/rendering/resource_visual_geometry.gd")
const Inputs = preload("res://scripts/rendering/resource_visual_chunk_inputs.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var map := Fixtures.make_map(4, 2)
	var inputs := Inputs.new()
	var near: Array[int] = [0, 1, 2, 3]
	var keys: Array[Vector2i] = [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ONE, Vector2i.ONE]
	map.visible_arr[1] = 0
	var unknown := inputs.prepare_view(map, near, keys, {2: {}}, true)
	_expect("only visible unknown rows delay their own chunk", inputs.pending_cells() == 2 and unknown == PackedInt32Array([0, 1, 3]) and not inputs.ready(Vector2i.ZERO) and not inputs.ready(Vector2i.ONE))
	inputs.complete(0)
	inputs.complete(0)
	_expect("completed rows release exactly once without waiting for world", inputs.ready(Vector2i.ZERO) and not inputs.ready(Vector2i.ONE) and inputs.pending_cells() == 1)
	var layer := Layer.new()
	layer._chunk_inputs = inputs
	layer._active = {Vector2i.ONE: true, Vector2i.ZERO: true}
	layer._dirty = layer._active.duplicate()
	_expect("pending nearer chunk preserves cap priority over ready farther chunk", Geometry._next_dirty_chunk(layer) == null)
	inputs.complete(3)
	_expect("ready closest chunk becomes selectable immediately", Geometry._next_dirty_chunk(layer) == Vector2i.ONE)
	layer.free()
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var world := WorldData.new()
	world.world_bounds = Rect2(-40, -40, 200, 200)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	layer = Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	layer.configure(map, world, 22.0, intel)
	layer.set_camera_view(world.world_bounds, Vector2(50, 50), 2.0)
	_expect("initial view waits on unknown visible inputs", layer._chunk_inputs.pending_cells() == 7)
	layer._build_until(Time.get_ticks_usec() + 1000000)
	_expect("no empty first job starts before inputs are ready", layer._job.is_empty() and layer._uploads.is_empty())
	map.visible_arr[0] = 0
	layer._observe_until(Time.get_ticks_usec() + 1000000)
	_expect("cell hidden before service releases pending without sampling it", layer._chunk_inputs.pending_cells() == 0 and not intel.resource_observations.rows.has(0))
	layer.set_context(false, 20261016)
	_expect("GM reveal rebuilds pending inputs", layer._chunk_inputs.pending_cells() == 2)
	layer._observe_until(Time.get_ticks_usec() + 1000000)
	_expect("GM observes and completes hidden inputs", layer._chunk_inputs.pending_cells() == 0 and intel.resource_observations.rows.size() == 8)
	var saved := {"version": 4}
	saved.merge(intel.to_pkfg_fields())
	_expect("fixture restores observation memory", bool(intel.restore_pkfg(saved).ok))
	layer._sync_restored_memory()
	_expect("restore uses known memory without waiting for reobservation", layer._chunk_inputs.pending_cells() == 0)
	layer._map.visible_arr.fill(1)
	var fresh := Intel.new()
	fresh.configure(map.cell_count())
	layer.configure(map, world, 22.0, fresh)
	_expect("reconfigure replaces pending membership for fresh memory", layer._chunk_inputs.pending_cells() == 8)
	layer.queue_free()
	await process_frame
	print("resource visual chunk inputs: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
