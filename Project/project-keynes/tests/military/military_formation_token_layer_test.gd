extends SceneTree

## Synthetic-feed tests for the production MilitaryArmyTokenLayer M2 backend.
## No native military DLL rebuild is required: dense ids are injected with the
## same stable-id order used by MilitaryCatalogCompiler.

const FEED_SCRIPT := preload("res://scripts/rendering/military_render_feed.gd")
const TOKEN_SCRIPT := preload("res://scripts/rendering/military_army_token_layer.gd")
const FORMATION_CATALOG_SCRIPT := preload(
	"res://scripts/rendering/military_formation_catalog.gd")
const MILITARY_CATALOG_PATH := "res://data/military/military_catalog.json"

var _failures := PackedStringArray()
var _dense_units: Array = []
var _dense_ids: PackedStringArray = PackedStringArray()


class FakeCell:
	var q: int
	var r: int

	func _init(q_value: int, r_value: int) -> void:
		q = q_value
		r = r_value


class FakeMap:
	var cells: Dictionary = {}
	var visible_arr: PackedByteArray = PackedByteArray()

	func _init() -> void:
		cells[10] = FakeCell.new(0, 0)
		cells[11] = FakeCell.new(1, 0)
		cells[12] = FakeCell.new(2, 0)
		cells[13] = FakeCell.new(3, 0)
		cells[14] = FakeCell.new(4, 0)
		cells[15] = FakeCell.new(5, 0)
		cells[16] = FakeCell.new(6, 0)
		visible_arr.resize(17)
		visible_arr.fill(1)

	func cell_at(cell: int):
		return cells.get(cell)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_dense_catalog()
	_test_catalog_mapping()
	_test_lod_hysteresis()
	await _test_token_layer_backend()
	await _test_handle_replacement_resets_position()
	await _test_aggregate_signature_covers_visible_row_state()
	_finish()


func _build_dense_catalog() -> void:
	var parsed: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(MILITARY_CATALOG_PATH))
	if not (parsed is Dictionary):
		_expect(false, "military catalog parses")
		return
	var ids: Array[String] = []
	for row_value in (parsed as Dictionary).get("units", []) as Array:
		ids.append(String((row_value as Dictionary).get("id", "")))
	ids.sort()
	_dense_ids = PackedStringArray(ids)
	for index in ids.size():
		_dense_units.append({"index": index, "id": ids[index]})
	_expect(_dense_units.size() > 0, "dense fixture contains catalog units")


func _test_catalog_mapping() -> void:
	var catalog = FORMATION_CATALOG_SCRIPT.new()
	_expect(catalog.load_catalog(), "formation visual catalog loads")
	var report: Dictionary = catalog.bind_dense_units(_dense_units)
	_expect(bool(report.get("ok", false)), "dense visual mapping binds")
	_expect(int(report.get("mapped", 0)) > 0
		and int(report.get("mapped", 0)) <= _dense_units.size(),
		"mapped dense units stay within the catalog")
	_expect(catalog.prototype_row_for_unit(_unit_index("cavalry")) == 1,
		"cavalry uses the mounted rig")
	_expect(catalog.prototype_row_for_unit(_unit_index("field_artillery")) == 2,
		"field artillery uses the artillery rig")
	_expect(catalog.prototype_row_for_unit(_unit_index("tank_corps")) == 3,
		"tank corps uses the armored rig, not the mounted class")
	_expect(catalog.member_count_for_headcount(299) == 1,
		"299 heads keep one member")
	_expect(catalog.member_count_for_headcount(300) == 2,
		"300 heads use two members")
	_expect(catalog.member_count_for_headcount(8000) == 5,
		"8000 heads use five members")
	var buckets: PackedInt32Array = catalog.allocate_member_buckets(
		[50.0, 30.0, 20.0], 5)
	_expect(buckets == PackedInt32Array([2, 2, 1]),
		"50/30/20 allocates 2/2/1 members")


func _test_lod_hysteresis() -> void:
	_expect(TOKEN_SCRIPT.lod_for_zoom_with_hysteresis(0.36, 0) == 0,
		"aggregate does not exit before 0.37")
	_expect(TOKEN_SCRIPT.lod_for_zoom_with_hysteresis(0.38, 0) == 1,
		"aggregate exits to representative above 0.37")
	_expect(TOKEN_SCRIPT.lod_for_zoom_with_hysteresis(0.32, 1) == 0,
		"representative re-enters aggregate below 0.33")
	_expect(TOKEN_SCRIPT.lod_for_zoom_with_hysteresis(0.71, 1) == 1,
		"representative waits before formation at 0.72")
	_expect(TOKEN_SCRIPT.lod_for_zoom_with_hysteresis(0.73, 1) == 2,
		"representative enters formation above 0.72")
	_expect(TOKEN_SCRIPT.lod_for_zoom_with_hysteresis(0.67, 2) == 1,
		"formation exits below 0.68")
	_expect(is_equal_approx(TOKEN_SCRIPT.one_shot_member_start(10.0, 0), 10.0),
		"first formation member begins a one-shot action immediately")
	_expect(TOKEN_SCRIPT.one_shot_member_start(10.0, 4) > 10.0,
		"formation members stagger later instead of starting the action early")


func _test_token_layer_backend() -> void:
	var layer = TOKEN_SCRIPT.new()
	get_root().add_child(layer)
	await process_frame
	layer.configure(FakeMap.new(), null, 22.0, 0.0)
	var catalog_report: Dictionary = layer.configure_formation_catalog(_dense_units)
	_expect(bool(catalog_report.get("ok", false)),
		"token layer accepts the dense visual mapping")
	_expect(layer.formation_catalog_ready(),
		"token layer reports formation catalog readiness")
	_expect(layer._formation_batch != null
		and layer._formation_batch.multimesh.custom_aabb.size.x >= 100000.0,
		"formation MultiMesh has a world-sized culling AABB")
	layer.set_formation_allow_all_for_tests(true)

	var feed = FEED_SCRIPT.new()
	feed.apply_synthetic(
		_snapshot_with_six_armies([0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]), -1)
	layer.set_lod_override_for_tests(2)
	layer.set_zoom_override_for_tests(1.0)
	layer.set_armies(feed)
	var formation: Dictionary = layer.debug_snapshot()
	_expect(String(formation.get("lod", "")) == "formation",
		"formation override selects formation LOD")
	_expect(int(formation.get("formation_instances", 0)) == 15,
		"1-5 member bands emit 1+2+3+4+5 formation sprites")
	_expect(int(formation.get("paper_instances", 0)) == 1,
		"army without composition falls back to one paper token")
	_expect(int(formation.get("formation_armies", 0)) == 5,
		"five mapped armies cover every member band")
	layer.set_selected_cell(12)
	_expect(layer._selection.points.size() == 25,
		"selection changes refresh the ring immediately")
	layer.set_selected_cell(-1)

	layer.set_player_slot(0)
	await process_frame
	var player_only: Dictionary = layer.debug_snapshot()
	_expect(int(player_only.get("formation_instances", 0)) == 1,
		"M2 player-only rollout emits only the player's formation")
	_expect(int(player_only.get("paper_instances", 0)) == 5,
		"visible foreign armies stay on paper fallback in M2")
	layer.set_player_slot(-1)
	await process_frame

	layer.set_lod_override_for_tests(1)
	await process_frame
	var representative: Dictionary = layer.debug_snapshot()
	_expect(int(representative.get("formation_instances", 0)) == 5,
		"representative LOD emits one sprite per mapped army")
	_expect(int(representative.get("paper_instances", 0)) == 1,
		"representative LOD preserves missing-data fallback")

	layer.set_lod_override_for_tests(0)
	await process_frame
	var aggregate: Dictionary = layer.debug_snapshot()
	_expect(int(aggregate.get("paper_instances", 0)) == 6,
		"aggregate LOD uses one paper token per occupied cell")
	_expect(int(aggregate.get("formation_instances", 0)) == 0,
		"aggregate LOD emits no formation sprites")

	layer.set_lod_override_for_tests(2)
	await process_frame
	# set_player_slot(-1) intentionally invalidates signatures so M2 rollout can
	# be re-evaluated. Reapply a baseline feed before checking cue-only updates.
	layer.set_armies(feed)
	await process_frame
	var before_cue: int = int(layer.debug_snapshot().get("uploads", 0))
	var before_cue_signature: int = int(layer._last_signature)
	var before_cue_formation: int = int(layer._last_formation_signature)
	var cue_feed = FEED_SCRIPT.new()
	cue_feed.apply_synthetic(
		_snapshot_with_six_armies([1, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], 2), -1)
	layer.set_armies(cue_feed)
	_expect(layer.debug_army_action(0) == "attack",
		"attack cue changes only the mapped army action")
	_expect(int(layer.debug_snapshot().get("uploads", 0)) == before_cue,
		"cue-only change avoids a full formation upload (uploads %d -> %d, sig %d -> %d, formation %d -> %d)" % [
			before_cue, int(layer.debug_snapshot().get("uploads", 0)),
			before_cue_signature, int(layer._last_signature),
			before_cue_formation, int(layer._last_formation_signature)])

	await create_timer(1.15).timeout
	var movement_snapshot := _snapshot_with_six_armies(
		[1, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], 3)
	var movement_armies := movement_snapshot["armies"] as Dictionary
	var moved_cells := (movement_armies["cell"] as PackedInt32Array).duplicate()
	moved_cells[0] = 16
	movement_armies["cell"] = moved_cells
	var moved_prev := (movement_armies["prev_cell"] as PackedInt32Array).duplicate()
	moved_prev[0] = 10
	movement_armies["prev_cell"] = moved_prev
	cue_feed.apply_synthetic(movement_snapshot, 2)
	layer.set_armies(cue_feed)
	_expect(layer.debug_army_action(0) == "move",
		"cross-cell movement selects the move action after attack expires")

	var fog_map := FakeMap.new()
	fog_map.visible_arr[11] = 0
	cue_feed.player_slot = 0
	layer.set_player_slot(0)
	layer.set_lod_override_for_tests(2)
	await process_frame
	cue_feed.apply_fog(fog_map, true)
	layer.set_armies(cue_feed)
	var fogged: Dictionary = layer.debug_snapshot()
	_expect(int(fogged.get("formation_instances", 0)) == 1,
		"fog leaves the player's formation visible")
	_expect(int(fogged.get("paper_instances", 0)) == 4,
		"fog removes the hidden foreign paper fallback")
	_expect(bool(fogged.get("visible_layer", false)),
		"formation-only armies keep the layer visible")
	cue_feed.apply_fog(fog_map, false)
	layer.set_armies(cue_feed)
	_expect(int(layer.debug_snapshot().get("paper_instances", 0)) == 5,
		"restoring fog visibility restores the hidden foreign fallback")

	var unbound_layer = TOKEN_SCRIPT.new()
	get_root().add_child(unbound_layer)
	await process_frame
	unbound_layer.configure(FakeMap.new(), null, 22.0, 0.0)
	unbound_layer.configure_formation_catalog(_dense_units)
	unbound_layer.set_lod_override_for_tests(2)
	unbound_layer.set_zoom_override_for_tests(1.0)
	var unbound_feed = FEED_SCRIPT.new()
	unbound_feed.apply_synthetic(_snapshot_with_six_armies(
		[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0]), -1)
	unbound_layer.set_armies(unbound_feed)
	var unbound: Dictionary = unbound_layer.debug_snapshot()
	_expect(int(unbound.get("formation_instances", 0)) == 0,
		"unbound player slot fails closed instead of rendering every country")
	_expect(int(unbound.get("paper_instances", 0)) == 6,
		"unbound player slot keeps all armies on paper fallback")

	var fallback_layer = TOKEN_SCRIPT.new()
	get_root().add_child(fallback_layer)
	await process_frame
	fallback_layer.configure(FakeMap.new(), null, 22.0, 0.0)
	fallback_layer.set_lod_override_for_tests(2)
	fallback_layer.set_zoom_override_for_tests(1.0)
	var old_feed = FEED_SCRIPT.new()
	old_feed.apply_synthetic(_snapshot_without_visual_fields(), -1)
	fallback_layer.set_armies(old_feed)
	var fallback: Dictionary = fallback_layer.debug_snapshot()
	_expect(int(fallback.get("formation_instances", 0)) == 0,
		"old DLL snapshots never emit formation sprites")
	_expect(int(fallback.get("paper_instances", 0)) == 2,
		"old DLL snapshots keep the original paper-token path")

	layer.clear()
	unbound_layer.clear()
	fallback_layer.clear()
	_expect(int(layer.debug_snapshot().get("formation_instances", 0)) == 0,
		"clear removes formation instances")
	layer.queue_free()
	unbound_layer.queue_free()
	fallback_layer.queue_free()
	await process_frame


func _test_handle_replacement_resets_position() -> void:
	var layer = TOKEN_SCRIPT.new()
	get_root().add_child(layer)
	await process_frame
	layer.configure(FakeMap.new(), null, 22.0, 0.0)
	layer.configure_formation_catalog(_dense_units)
	layer.set_lod_override_for_tests(2)
	layer.set_zoom_override_for_tests(1.0)

	var feed = FEED_SCRIPT.new()
	feed.apply_synthetic(_snapshot_with_six_armies(
		[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], 1), -1)
	layer.set_armies(feed)
	var moving_snap := _snapshot_with_six_armies(
		[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], 2)
	var moving_armies := moving_snap["armies"] as Dictionary
	var moving_cells := (moving_armies["cell"] as PackedInt32Array).duplicate()
	moving_cells[0] = 16
	moving_armies["cell"] = moving_cells
	var moving_prev := (moving_armies["prev_cell"] as PackedInt32Array).duplicate()
	moving_prev[0] = 10
	moving_armies["prev_cell"] = moving_prev
	feed.apply_synthetic(moving_snap, 1)
	layer.set_armies(feed)
	_expect(layer._t0[0] > -50.0, "cross-cell update starts a position tween")

	var replacement := _snapshot_with_six_armies(
		[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], 3)
	var replacement_armies := replacement["armies"] as Dictionary
	var replacement_handles := (
		replacement_armies["handle"] as PackedInt64Array).duplicate()
	replacement_handles[0] = 901
	replacement_armies["handle"] = replacement_handles
	var replacement_cells := (
		replacement_armies["cell"] as PackedInt32Array).duplicate()
	replacement_cells[0] = 12
	replacement_armies["cell"] = replacement_cells
	var replacement_prev := (
		replacement_armies["prev_cell"] as PackedInt32Array).duplicate()
	replacement_prev[0] = 10
	replacement_armies["prev_cell"] = replacement_prev
	feed.apply_synthetic(replacement, 2)
	layer.set_armies(feed)
	_expect(layer._handle[0] == 901, "compacted row adopts the replacement handle")
	_expect(layer._t0[0] <= -50.0,
		"replacement handle snaps to its own cell instead of inheriting the tween")

	layer.clear()
	layer.queue_free()
	await process_frame


func _test_aggregate_signature_covers_visible_row_state() -> void:
	var layer = TOKEN_SCRIPT.new()
	get_root().add_child(layer)
	await process_frame
	layer.configure(FakeMap.new(), null, 22.0, 0.0)
	layer.set_lod_override_for_tests(0)
	layer.set_zoom_override_for_tests(0.2)

	var feed = FEED_SCRIPT.new()
	var base := _snapshot_with_six_armies(
		[0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0], 1)
	feed.apply_synthetic(base, -1)
	layer.set_armies(feed)
	var base_signature: int = int(layer._agg_sig)

	var owner_snap := base.duplicate(true)
	var owner_armies := owner_snap["armies"] as Dictionary
	var owner_slots := (owner_armies["owner_slot"] as PackedInt32Array).duplicate()
	owner_slots[0] = 9
	owner_armies["owner_slot"] = owner_slots
	owner_snap["revision"] = 2
	feed.apply_synthetic(owner_snap, 1)
	layer.set_armies(feed)
	_expect(layer._agg_sig != base_signature,
		"aggregate cache invalidates when owner changes")
	var owner_signature: int = int(layer._agg_sig)

	var flags_snap := owner_snap.duplicate(true)
	var flags_armies := flags_snap["armies"] as Dictionary
	var flag_rows := (flags_armies["flags"] as PackedInt32Array).duplicate()
	flag_rows[0] = 1
	flags_armies["flags"] = flag_rows
	flags_snap["revision"] = 3
	feed.apply_synthetic(flags_snap, 2)
	layer.set_armies(feed)
	_expect(layer._agg_sig != owner_signature,
		"aggregate cache invalidates when flags change")
	var flags_signature: int = int(layer._agg_sig)

	var head_snap := flags_snap.duplicate(true)
	var head_armies := head_snap["armies"] as Dictionary
	var heads := (head_armies["headcount"] as PackedInt64Array).duplicate()
	heads[0] = 65636
	head_armies["headcount"] = heads
	head_snap["revision"] = 4
	feed.apply_synthetic(head_snap, 3)
	layer.set_armies(feed)
	_expect(layer._agg_sig != flags_signature,
		"aggregate cache uses the full headcount instead of low 16 bits")

	layer.clear()
	layer.queue_free()
	await process_frame


func _snapshot_with_six_armies(attack_seq: Array, hit_seq: Array,
		revision: int = 1) -> Dictionary:
	var spear := _unit_index("bronze_spearmen")
	var cavalry := _unit_index("cavalry")
	var artillery := _unit_index("field_artillery")
	return {
		"revision": revision,
		"armies": {
			"handle": PackedInt64Array([101, 102, 103, 104, 105, 106]),
			"owner_slot": PackedInt32Array([0, 1, 2, 3, 4, 5]),
			"cell": PackedInt32Array([10, 11, 12, 13, 14, 15]),
			"prev_cell": PackedInt32Array([10, 11, 12, 13, 14, 15]),
			"moved_day": PackedInt32Array([0, 0, 0, 0, 0, 0]),
			"unit_class": PackedByteArray([0, 1, 2, 0, 1, 2]),
			"headcount": PackedInt64Array([100, 500, 1000, 4000, 8000, 1000]),
			"flags": PackedInt32Array([0, 0, 0, 0, 0, 0]),
			"composition_offsets": PackedInt32Array([0, 3, 6, 9, 12, 15, 15]),
			"composition_unit": PackedInt32Array([
				spear, cavalry, artillery,
				spear, cavalry, artillery,
				spear, cavalry, artillery,
				spear, cavalry, artillery,
				spear, cavalry, artillery,
			]),
			"composition_weight": PackedInt64Array([
				50, 30, 20,
				50, 30, 20,
				50, 30, 20,
				50, 30, 20,
				50, 30, 20,
			]),
			"heading_q16": PackedInt32Array([0, 8192, 16384, 24576, 32768, 49152]),
			"attack_seq": PackedInt32Array(attack_seq),
			"hit_seq": PackedInt32Array(hit_seq),
		},
	}


func _snapshot_without_visual_fields() -> Dictionary:
	return {
		"revision": 1,
		"armies": {
			"handle": PackedInt64Array([201, 202]),
			"owner_slot": PackedInt32Array([0, 1]),
			"cell": PackedInt32Array([10, 11]),
			"prev_cell": PackedInt32Array([10, 11]),
			"moved_day": PackedInt32Array([0, 0]),
			"unit_class": PackedByteArray([0, 1]),
			"headcount": PackedInt64Array([1000, 1000]),
			"flags": PackedInt32Array([0, 0]),
		},
	}


func _unit_index(unit_id: String) -> int:
	for index in _dense_ids.size():
		if _dense_ids[index] == unit_id:
			return index
	_expect(false, "dense unit exists: %s" % unit_id)
	return -1


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures.append(message)
	push_error(message)


func _finish() -> void:
	print("=== military formation token layer test: %d failures ===" % _failures.size())
	for failure in _failures:
		print("  FAILED: " + failure)
	quit(0 if _failures.is_empty() else 1)
