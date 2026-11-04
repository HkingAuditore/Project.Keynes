extends SceneTree

const GeneratorContext = preload("res://scripts/simulation/generator_context.gd")
const WeatherContext = preload("res://scripts/weather/weather_context.gd")
var checks := 0
var failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_borrowed_generator()
	_test_query_pool()
	_test_map_world_cycle()
	print("runtime resource lifetime: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _test_borrowed_generator() -> void:
	var owner := RefCounted.new()
	var context := GeneratorContext.new()
	var job := SusJob.new()
	var weather_context := WeatherContext.new()
	context._generator = owner
	job.generator = owner
	weather_context._weather_system = owner
	_expect("contexts can access a live owner", context._generator == owner and job.generator == owner)
	var released: WeakRef = weakref(owner)
	owner = null
	_expect("contexts do not keep the owner alive", released.get_ref() == null)
	_expect("borrowed links become null after owner release", context._generator == null and job.generator == null)
	_expect("weather helpers do not retain their owner", weather_context._weather_system == null)


func _test_query_pool() -> void:
	var world := DCWorld.new()
	world.create_entities(3)
	var query := world.query().build()
	var visited: Array[int] = []
	query.for_each_index(func(index: int) -> void: visited.append(index))
	_expect("query sees the live world's entities", visited == [0, 1, 2])
	world.release_query(query)
	_expect("released query is reused", world.query() == query)
	world.release_query(query)
	var released: WeakRef = weakref(world)
	world = null
	_expect("pooled query does not keep its world alive", released.get_ref() == null)
	_expect("query has no dangling world", query._world == null)


func _test_map_world_cycle() -> void:
	var map := MapData.new(1, 1)
	var cell := HexCell.new(0, 0)
	map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	var world := DCWorld.new()
	world.bind_map_data(map)
	cell.bind_world(world, true)
	_expect("world reads its bound map", world._map_data == map and world.is_bound())
	var released := [weakref(map), weakref(cell), weakref(world)]
	world = null
	cell = null
	map = null
	for index in released.size():
		_expect("map/cell/world cycle releases member %d" % index, released[index].get_ref() == null)


func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)
