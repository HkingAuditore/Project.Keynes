extends SceneTree

# Headless:
#   godot --headless --path Project/project-keynes --script res://tests/detail_scatter_wrap_mirror_test.gd

const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")

var _checks: int = 0
var _failures: int = 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var layer = ShrubLayerScript.new()
	layer._map = MapData.new(12, 8)
	layer._hex_size = 10.0

	var source := _make_source("SingleSource")
	layer.add_child(source)
	layer._mmi = source
	layer._sync_single_wrap_nodes()
	_assert_wrap_pair("single", source, layer._single_wrap_nodes, layer._wrap_period_x())

	var chunk_source := _make_source("ChunkSource")
	layer.add_child(chunk_source)
	layer._chunk_nodes[42] = chunk_source
	layer._sync_chunk_wrap_nodes(42)
	_assert_wrap_pair("chunk", chunk_source, layer._chunk_wrap_nodes.get(42, []), layer._wrap_period_x())

	var shadow_source := _make_source("ShadowSource")
	shadow_source.z_index = -1
	layer.add_child(shadow_source)
	layer._shadow_chunk_nodes[42] = shadow_source
	layer._sync_shadow_chunk_wrap_nodes(42)
	_assert_wrap_pair("shadow chunk", shadow_source,
		layer._shadow_chunk_wrap_nodes.get(42, []), layer._wrap_period_x())

	layer._clear_chunk_nodes()
	_expect("chunk mirror registries clear with source chunks",
		layer._chunk_wrap_nodes.is_empty() and layer._shadow_chunk_wrap_nodes.is_empty())
	layer.free()
	print("=== detail scatter wrap mirror: %d checks, %d failures ===" % [_checks, _failures])


func _make_source(node_name: String) -> MultiMeshInstance2D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.mesh = QuadMesh.new()
	mm.instance_count = 1
	mm.visible_instance_count = 1
	var node := MultiMeshInstance2D.new()
	node.name = node_name
	node.multimesh = mm
	node.visible = true
	return node


func _assert_wrap_pair(label: String, source: MultiMeshInstance2D, nodes: Array,
		period_x: float) -> void:
	_expect("%s creates two wrap nodes" % label, nodes.size() == 2)
	if nodes.size() != 2:
		return
	var left := nodes[0] as MultiMeshInstance2D
	var right := nodes[1] as MultiMeshInstance2D
	_expect("%s offsets match cylindrical period" % label,
		is_equal_approx(left.position.x, -period_x) and
		is_equal_approx(right.position.x, period_x))
	_expect("%s shares the source MultiMesh buffer" % label,
		left.multimesh == source.multimesh and right.multimesh == source.multimesh)
	_expect("%s mirrors source visibility" % label, left.visible and right.visible)


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
