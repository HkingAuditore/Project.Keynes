extends SceneTree

const HexRendererScript := preload("res://scripts/rendering/hex_renderer.gd")
const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")
const ChangeSetScript := preload("res://scripts/data/detail_scatter_change_set.gd")

var _checks := 0
var _failures := 0


class FakeLayer extends ShrubLayer:
	var family_mask := 1
	var prefetch := true
	var refresh_count := 0
	var affected := true
	var last_dirty_indices := PackedInt32Array()

	func detail_render_family_mask() -> int:
		return family_mask

	func detail_change_affects_profile(
			_axis_mask: int,
			_old_veg: int, _new_veg: int,
			_old_lf: int, _new_lf: int,
			_old_cover: int, _new_cover: int
	) -> bool:
		return affected

	func detail_chunk_plan_for_indices(indices: PackedInt32Array) -> Array:
		return [{
			"chunk_id": 7,
			"cell_indices": PackedInt32Array([10, 11, 12]),
			"dirty_indices": indices,
			"dirty_cells": indices.size(),
		}]

	func detail_chunk_is_in_prefetch(_chunk_id: int) -> bool:
		return prefetch

	func detail_chunk_id_for_cell(_cell_idx: int) -> int:
		return 7

	func detail_chunk_cells(_chunk_id: int) -> PackedInt32Array:
		return PackedInt32Array([10, 11, 12])

	func begin_detail_chunk_refresh() -> void:
		pass

	func refresh_chunk_for_succession(
			_chunk_id: int,
			_chunk_cells: PackedInt32Array,
			_dirty_cell_count: int = 0,
			_dirty_indices: PackedInt32Array = PackedInt32Array()
	) -> bool:
		refresh_count += 1
		last_dirty_indices = _dirty_indices.duplicate()
		return true

	func set_camera_view(_world_rect: Rect2, _center: Vector2, _zoom_value: float) -> void:
		pass


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var changes = ChangeSetScript.new()
	changes.generation = 3
	changes.append_change(
		10,
		ChangeSetScript.AXIS_VEGETATION | ChangeSetScript.AXIS_COVER,
		2, 7, 4, 4, 0, 1
	)
	_expect("change set keeps aligned packed arrays", changes.is_well_formed() and changes.size() == 1)
	var copy = changes.duplicate_set()
	_expect("change set duplicate preserves generation and values",
		copy.generation == 3 and copy.cell_indices[0] == 10 and copy.new_vegetation[0] == 7)

	var renderer = HexRendererScript.new()
	renderer.detail_scatter_enqueue_coalesce_ms = 0.0
	renderer.detail_scatter_refresh_apply_budget_ms = 0.0
	renderer.detail_scatter_refresh_chunks_per_frame = 1
	var ground := FakeLayer.new()
	ground.family_mask = 1
	ground.affected = false
	ground.prefetch = false
	var canopy := FakeLayer.new()
	canopy.family_mask = 1 << 2
	canopy.affected = true
	canopy.prefetch = false
	var canopy_unaffected := FakeLayer.new()
	canopy_unaffected.family_mask = 1 << 2
	canopy_unaffected.affected = false
	canopy_unaffected.prefetch = false
	renderer.add_child(ground)
	renderer.add_child(canopy)
	renderer.add_child(canopy_unaffected)
	renderer._detail_layers = [ground, canopy, canopy_unaffected]

	renderer.queue_detail_scatter_changes(changes)
	var deferred: Dictionary = renderer.detail_scatter_refresh_report()
	_expect("offscreen chunk is stale without queued render work",
		int(deferred.get("stale_superchunks", 0)) == 1
		and int(deferred.get("queued_tasks", 0)) == 0
		and ground.refresh_count == 0 and canopy.refresh_count == 0
		and canopy_unaffected.refresh_count == 0)

	ground.prefetch = true
	canopy.prefetch = true
	canopy_unaffected.prefetch = true
	renderer.set_camera_view(Rect2(Vector2.ZERO, Vector2(640, 360)), Vector2(320, 180), 1.0)
	renderer._drain_detail_refresh_queue()
	_expect("entering prefetch rebuilds only the affected render family",
		ground.refresh_count == 0 and canopy.refresh_count == 1
		and canopy_unaffected.refresh_count == 0)
	_expect("same-family unaffected profile is not rebuilt",
		canopy_unaffected.refresh_count == 0)
	_expect("deferred superchunk is consumed once", renderer._detail_deferred_chunks.is_empty())

	renderer.queue_detail_scatter_changes(changes)
	var newer = changes.duplicate_set()
	newer.generation = 4
	renderer.queue_detail_scatter_changes(newer)
	renderer._drain_detail_refresh_queue()
	_expect("resident superchunk forwards only exact dirty cells",
		canopy.refresh_count == 2
		and canopy.last_dirty_indices == PackedInt32Array([10]))
	_expect("new generation arriving in-flight is retained for one latest-state rerun",
		not renderer._detail_refresh_batches.is_empty())
	renderer._drain_detail_refresh_queue()
	_expect("in-flight latest-state rerun executes exactly once",
		canopy.refresh_count == 3 and renderer._detail_refresh_batches.is_empty())

	renderer._detail_layers.clear()
	renderer.free()
	print("=== detail scatter visibility: %d checks, %d failures ===" % [_checks, _failures])


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
