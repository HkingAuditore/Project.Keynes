extends SceneTree

const Bounds = preload("res://scripts/rendering/fog_draw_bounds.gd")
const DetailCulling = preload("res://scripts/rendering/fog_detail_culling.gd")
const SCREEN := Rect2(0.0, 0.0, 400.0, 200.0)

class DrawLayers:
	var _detail_layers: Array[Node2D] = []
	var _detail_family_layer: Node2D
	var _resource_visual_layer: Node2D
	var _building_visual_layer: Node2D

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var layers := DrawLayers.new()
	var items := Node2D.new()
	var fog := Node2D.new()
	fog.z_index = 12
	root.add_child(items)
	root.add_child(fog)
	layers._detail_layers.append(items)
	var culling := DetailCulling.new()
	var obscured := Rect2(0.0, 0.0, 200.0, 200.0)
	var covers := func(samples: Rect2) -> bool: return obscured.encloses(samples)
	var inside := _batch(items, Bounds.Kind.VEGETATION, Vector2(60.0, 100.0))
	var edge := _batch(items, Bounds.Kind.BUILDING_SHADOW, Vector2(199.0, 100.0))
	var above := _batch(items, Bounds.Kind.RESOURCE, Vector2(60.0, 100.0))
	above.z_index = 13
	var unknown := _batch(items, Bounds.Kind.RESOURCE, Vector2(60.0, 100.0))
	unknown.multimesh.remove_meta(Bounds.PASS)
	var hidden := _batch(items, Bounds.Kind.RESOURCE, Vector2(60.0, 100.0))
	hidden.visible = false
	culling.update(layers, fog, SCREEN, covers, false)
	_expect(culling._hidden.has(inside.get_instance_id()), "an entirely covered plant batch is omitted")
	_expect(inside.is_visible_in_tree(), "culling preserves the layer's own visibility")
	_expect(not culling._hidden.has(edge.get_instance_id()), "a shadow that can reach beyond the fog is kept")
	_expect(not culling._hidden.has(above.get_instance_id()), "a batch drawn above fog is kept")
	_expect(not culling._hidden.has(unknown.get_instance_id()), "unbounded geometry is kept in mixed fog")
	_expect(not culling._hidden.has(hidden.get_instance_id()), "an already hidden batch stays under its owner's control")

	inside.position.x += 200.0
	Bounds.upload(edge.multimesh, _buffer(Vector2(60.0, 100.0)), Bounds.Kind.BUILDING_SHADOW)
	culling.update(layers, fog, SCREEN, covers, false)
	_expect(not culling._hidden.has(inside.get_instance_id()), "a moved copy resumes in the same update")
	_expect(culling._hidden.has(edge.get_instance_id()), "updated instance bounds take effect in the same update")
	culling.update(layers, fog, SCREEN, covers, true)
	_expect(culling._hidden.has(unknown.get_instance_id()), "the whole fogged screen can hide an unbounded batch")
	_expect(not culling._hidden.has(above.get_instance_id()), "whole-screen coverage still respects draw order")

	edge.free()
	fog.modulate.a = 0.8
	culling.update(layers, fog, SCREEN, covers, true)
	_expect(culling._hidden.is_empty(), "a faded fog draw cannot hide any geometry")
	culling.clear()
	_expect(culling._hidden.is_empty() and inside.visible and not hidden.visible,
		"clearing the draw filter preserves owner visibility")
	_check_clipped_overlay_uvs()
	items.free()
	fog.free()
	print("detail fog culling: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_clipped_overlay_uvs() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(20.0, 10.0)
	var retained: Array[Rect2] = [Rect2(0.0, -5.0, 10.0, 10.0)]
	var clipped := DetailCulling.ClippedOverlay._crop(quad, retained, Vector2.ZERO)
	_expect(clipped != null and clipped.get_surface_count() == 1,
		"the retained half of a map-wide quad stays drawable")
	if clipped == null or clipped.get_surface_count() == 0:
		return
	var arrays := clipped.surface_get_arrays(0)
	_expect(arrays[Mesh.ARRAY_TEX_UV] == PackedVector2Array([
		Vector2(0.5, 1.0), Vector2(1.0, 1.0), Vector2(1.0, 0.0), Vector2(0.5, 0.0)]),
		"the crop preserves the original UVs and their vertical orientation")


func _batch(parent: Node2D, kind: int, center: Vector2) -> MultiMeshInstance2D:
	var node := MultiMeshInstance2D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = 1
	Bounds.upload(mm, _buffer(center), kind)
	node.multimesh = mm
	node.material = ShaderMaterial.new()
	parent.add_child(node)
	return node


func _buffer(center: Vector2) -> PackedFloat32Array:
	return PackedFloat32Array([3.0, 0.0, 0.0, center.x,
		0.0, 2.0, 0.0, center.y, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0])


func _expect(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(message)
