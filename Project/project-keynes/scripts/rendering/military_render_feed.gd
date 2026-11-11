extends RefCounted
class_name MilitaryRenderFeed
## Military map-layer feed: ONE poll of `get_military_render_snapshot(revision)` per
## frame for every `military_*_layer.gd` node.
##
## Why a hub instead of a poll per layer: seven layers reading the same frozen
## dictionary would each pay a native call (and each call is itself O(armies)),
## which breaks the ~0.5 ms/frame render budget. The hub also owns the three
## revision waterfalls the design needs (control_revision -> occupation hatch
## upload, front_revision -> front ribbon rebuild, army cell/flag signature ->
## token instance rewrite) and the fog rule (foreign armies / engagements /
## convoys only on FOG_VISIBLE cells).
##
## Data source (see docs/cpp-dots-runtime/military-runtime.md and §14.1 of the
## design): DCWorldExt.get_military_render_snapshot(after_revision) returns
##   revision, armies:{handle, owner_slot, cell, prev_cell, moved_day, unit_class,
##   headcount, flags, [composition_offsets, composition_unit,
##   composition_weight, heading_q16, attack_seq, hit_seq]},
##   engagements:{cell_a, cell_b, progress_q16, attacker_slot},
##   convoys:{current_cell, dest_cell, country_slot, risk_q16},
##   control_revision, controller_cells, controller_slots,
##   front_revision, front_edges (key = cell*6+dir)
## with flat Packed arrays (one entry per row) or per-row Packed arrays. Both
## shapes are accepted; the current layer code uses the GDScript adapter below
## (`_unpack_sidecar`) so rendering is not blocked on the native accessor.
##
## Hot-path rules: no Dictionary/String/Variant allocation per row. Rows are
## appended into reused Packed arrays (stamp-invalidated), never into Array.

const MODE_DEFAULT := 0

var revision: int = -1
var control_revision: int = 0
var front_revision: int = 0
var day: int = 0
var visual_day: float = 0.0
var player_slot: int = -1
var ok: bool = false

## Frozen army rows, SoA, one index per live army (0..army_count-1).
var army_count: int = 0
var army_handle: PackedInt64Array = PackedInt64Array()
var army_owner: PackedInt32Array = PackedInt32Array()
var army_cell: PackedInt32Array = PackedInt32Array()
var army_prev_cell: PackedInt32Array = PackedInt32Array()
var army_moved_day: PackedInt32Array = PackedInt32Array()
var army_class: PackedByteArray = PackedByteArray()
var army_headcount: PackedInt64Array = PackedInt64Array()
var army_flags: PackedInt32Array = PackedInt32Array()
## Optional M1 visual projection. Empty arrays preserve compatibility with DLLs
## that predate these fields; accessors below apply the east/zero defaults.
var army_composition_offsets: PackedInt32Array = PackedInt32Array()
var army_composition_unit: PackedInt32Array = PackedInt32Array()
var army_composition_weight: PackedInt64Array = PackedInt64Array()
var army_heading_q16: PackedInt32Array = PackedInt32Array()
var army_attack_seq: PackedInt32Array = PackedInt32Array()
var army_hit_seq: PackedInt32Array = PackedInt32Array()
var army_visible: PackedByteArray = PackedByteArray()
var army_cell_key: PackedInt64Array = PackedInt64Array()
## Selected army (player) handle; its area gets a dashed ribbon.
var selected_army: int = 0
var selected_area_cells: PackedInt32Array = PackedInt32Array()

var engagement_count: int = 0
var engagement_cell_a: PackedInt32Array = PackedInt32Array()
var engagement_cell_b: PackedInt32Array = PackedInt32Array()
var engagement_progress: PackedInt32Array = PackedInt32Array()
var engagement_side: PackedInt32Array = PackedInt32Array()
var engagement_battle: PackedByteArray = PackedByteArray()
## Optional: attacker-side cell per engagement (fog裁剪用). Empty = use cell_a.
var attacker_cell_cells: PackedInt32Array = PackedInt32Array()

var convoy_count: int = 0
var convoy_current: PackedInt32Array = PackedInt32Array()
var convoy_dest: PackedInt32Array = PackedInt32Array()
var convoy_country: PackedInt32Array = PackedInt32Array()
var convoy_risk: PackedInt32Array = PackedInt32Array()

## Controller hatch source (cell + occupier slot), rebuilt only on control_revision.
var controller_count: int = 0
var controller_cells: PackedInt32Array = PackedInt32Array()
var controller_slots: PackedInt32Array = PackedInt32Array()
var controller_snapshot_revision: int = -1

## Front edges (key = cell*6+dir, progress in low 8 bits of the second array).
var front_edge_count: int = 0
var front_edge_key: PackedInt32Array = PackedInt32Array()
var front_edge_progress: PackedByteArray = PackedByteArray()
var front_snapshot_revision: int = -1

## Army instance rewrite signature. Equal signature => keep MultiMesh instances.
var army_signature: int = 0
## Composition/heading-only signature for the optional formation backend. Cue
## changes deliberately stay out of this value so they can update per-member
## custom data without rebuilding every army's layout.
var army_formation_signature: int = 0

var _scratch_cell: PackedInt32Array = PackedInt32Array()
var _scratch_slot: PackedInt32Array = PackedInt32Array()
var _sig_acc: int = 0
var _poll_usec: int = 0


func set_clock(clock) -> void:
	if clock != null:
		day = int(clock.day_index())
		visual_day = float(day) + _day_fraction(clock)


func _day_fraction(clock) -> float:
	# Visual day = whole simulated day + intra-day phase, so token interpolation
	# (t0_day -> t1_day) eases between day boundaries at every clock speed.
	var phase := float(clock.day_phase()) if clock.has_method("day_phase") else 0.25
	return clampf((phase - 0.25) / 1.0, 0.0, 0.999)


## Polls the native snapshot. `after_revision` is the last accepted revision, so
## an unchanged world costs one native call that returns the same revision and
## no work is done below it.
func poll(ext, after_revision: int, player_slot_value: int) -> void:
	var started := Time.get_ticks_usec()
	player_slot = player_slot_value
	if ext == null:
		ok = false
		_poll_usec = Time.get_ticks_usec() - started
		return
	var snap: Variant = {}
	snap = ext.get_military_render_snapshot(after_revision)
	if snap is Dictionary and not (snap as Dictionary).is_empty():
		_apply(snap as Dictionary, after_revision)
	else:
		ok = false
	_poll_usec = Time.get_ticks_usec() - started


func _apply(snap: Dictionary, after_revision: int) -> void:
	if not bool(snap.get("ok", true)) or not bool(snap.get("available", true)):
		ok = false
		return
	var new_revision := int(snap.get("revision", after_revision))
	var fresh := new_revision != revision or not ok
	ok = true
	if fresh:
		revision = new_revision
		_unpack_armies(snap)
		_unpack_engagements(snap)
		_unpack_convoys(snap)
	# Waterfalls: the two expensive consumers only re-upload on their own
	# revision, which is exactly what the design asks for.
	var control := int(snap.get("control_revision", control_revision))
	if control != control_revision or controller_snapshot_revision < 0:
		control_revision = control
		_unpack_controllers(snap)
	var front := int(snap.get("front_revision", front_revision))
	if front != front_revision or front_snapshot_revision < 0:
		front_revision = front
		_unpack_front(snap)


func poll_usec() -> int:
	return _poll_usec


## Test / tooling entry: push a snapshot dictionary straight through the same
## unpack path the native accessor uses. Production never calls this.
func apply_synthetic(snap: Dictionary, after_revision: int) -> void:
	_apply(snap, after_revision)


func _int_array(value: Variant) -> PackedInt32Array:
	return value as PackedInt32Array if value is PackedInt32Array else PackedInt32Array()


func _long_array(value: Variant) -> PackedInt64Array:
	return value as PackedInt64Array if value is PackedInt64Array else PackedInt64Array()


func _byte_array(value: Variant) -> PackedByteArray:
	return value as PackedByteArray if value is PackedByteArray else PackedByteArray()


## Safe per-row accessors. Missing visual fields and old native snapshots default
## to east (q16 zero) and no attack/hit cue.
func army_heading_for_row(row: int) -> int:
	if row < 0 or row >= army_count or row >= army_heading_q16.size():
		return 0
	return int(army_heading_q16[row]) & 0xFFFF


func army_attack_seq_for_row(row: int) -> int:
	if row < 0 or row >= army_count or row >= army_attack_seq.size():
		return 0
	return int(army_attack_seq[row])


func army_hit_seq_for_row(row: int) -> int:
	if row < 0 or row >= army_count or row >= army_hit_seq.size():
		return 0
	return int(army_hit_seq[row])


## Returns [start, end) into army_composition_unit/weight, or (0, 0) when the
## optional composition CSR is absent, malformed, or the row is out of range.
func get_army_composition_range(row: int) -> Vector2i:
	if row < 0 or row >= army_count:
		return Vector2i.ZERO
	if army_composition_offsets.size() != army_count + 1:
		return Vector2i.ZERO
	if army_composition_unit.size() != army_composition_weight.size():
		return Vector2i.ZERO
	var begin := int(army_composition_offsets[row])
	var end := int(army_composition_offsets[row + 1])
	if begin < 0 or end < begin or end > army_composition_unit.size():
		return Vector2i.ZERO
	return Vector2i(begin, end)


## Formation-backend helper: returns up to three {unit, weight} dictionaries in
## weight-descending / dense-unit-id-ascending order. Empty means old DLL data.
func get_army_top3_composition(row: int, max_entries: int = 3) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var limit := clampi(max_entries, 0, 3)
	if limit == 0:
		return out
	var bounds := get_army_composition_range(row)
	if bounds.x == bounds.y:
		return out
	var picked_unit: Array[int] = []
	var picked_weight: Array[int] = []
	for index in range(bounds.x, bounds.y):
		var unit := int(army_composition_unit[index])
		var weight := int(army_composition_weight[index])
		var insert_at := picked_weight.size()
		for picked_index in picked_weight.size():
			var other_weight := int(picked_weight[picked_index])
			var other_unit := int(picked_unit[picked_index])
			if weight > other_weight or (weight == other_weight and unit < other_unit):
				insert_at = picked_index
				break
		if insert_at >= limit:
			continue
		picked_unit.insert(insert_at, unit)
		picked_weight.insert(insert_at, weight)
		if picked_unit.size() > limit:
			picked_unit.pop_back()
			picked_weight.pop_back()
	for index in picked_unit.size():
		out.append({"unit": int(picked_unit[index]), "weight": int(picked_weight[index])})
	return out


func _ensure_army_capacity(count: int) -> void:
	if army_handle.size() >= count:
		return
	army_handle.resize(count)
	army_owner.resize(count)
	army_cell.resize(count)
	army_prev_cell.resize(count)
	army_moved_day.resize(count)
	army_class.resize(count)
	army_headcount.resize(count)
	army_flags.resize(count)
	army_visible.resize(count)
	army_cell_key.resize(count)


func _valid_composition_csr(offsets: PackedInt32Array, units: PackedInt32Array,
		weights: PackedInt64Array, count: int) -> bool:
	if offsets.size() != count + 1 or units.size() != weights.size():
		return false
	if offsets.is_empty() or int(offsets[0]) != 0:
		return false
	if int(offsets[offsets.size() - 1]) != units.size():
		return false
	var previous := 0
	for row in count:
		var begin := int(offsets[row])
		var end := int(offsets[row + 1])
		if begin < previous or end < begin or end > units.size():
			return false
		if end - begin > 3:
			return false
		for index in range(begin, end):
			if int(units[index]) < 0 or int(weights[index]) <= 0:
				return false
		previous = end
	return true


func _unpack_army_visual_fields(armies: Dictionary, count: int) -> void:
	var offsets := _int_array(armies.get("composition_offsets", PackedInt32Array()))
	var units := _int_array(armies.get("composition_unit", PackedInt32Array()))
	var weights := _long_array(armies.get("composition_weight", PackedInt64Array()))
	if _valid_composition_csr(offsets, units, weights, count):
		army_composition_offsets = offsets
		army_composition_unit = units
		army_composition_weight = weights
	else:
		army_composition_offsets = PackedInt32Array()
		army_composition_unit = PackedInt32Array()
		army_composition_weight = PackedInt64Array()
	var heading := _int_array(armies.get("heading_q16", PackedInt32Array()))
	army_heading_q16 = heading if heading.size() == count else PackedInt32Array()
	var attack := _int_array(armies.get("attack_seq", PackedInt32Array()))
	army_attack_seq = attack if attack.size() == count else PackedInt32Array()
	var hit := _int_array(armies.get("hit_seq", PackedInt32Array()))
	army_hit_seq = hit if hit.size() == count else PackedInt32Array()


func _unpack_armies(snap: Dictionary) -> void:
	var armies: Dictionary = snap.get("armies", {})
	if armies.is_empty():
		army_count = 0
		army_signature = 0
		army_formation_signature = 0
		selected_army = 0
		selected_area_cells = PackedInt32Array()
		army_composition_offsets = PackedInt32Array()
		army_composition_unit = PackedInt32Array()
		army_composition_weight = PackedInt64Array()
		army_heading_q16 = PackedInt32Array()
		army_attack_seq = PackedInt32Array()
		army_hit_seq = PackedInt32Array()
		return
	var handles := _long_array(armies.get("handle", PackedInt64Array()))
	var owner := _flat_int(armies.get("owner_slot", PackedInt32Array()))
	var count := handles.size()
	if count == 0:
		# Legacy snapshots without handles still carry PackedInt32Array owners.
		count = owner.size()
	_ensure_army_capacity(count)
	var cell := _int_array(armies.get("cell", PackedInt32Array()))
	var prev := _int_array(armies.get("prev_cell", PackedInt32Array()))
	var moved := _int_array(armies.get("moved_day", PackedInt32Array()))
	var klass := _byte_array(armies.get("unit_class", PackedByteArray()))
	var head := _long_array(armies.get("headcount", PackedInt64Array()))
	var flags := _int_array(armies.get("flags", PackedInt32Array()))
	# Alternative shape: one flat row per army field (row-major arrays).
	army_count = mini(count, 2048)
	_unpack_army_visual_fields(armies, army_count)
	_sig_acc = army_count
	var formation_sig_acc := army_count
	for i in army_count:
		army_handle[i] = handles[i] if i < handles.size() else 0
		army_owner[i] = owner[i] if i < owner.size() else 0
		army_cell[i] = cell[i] if i < cell.size() else -1
		army_prev_cell[i] = prev[i] if i < prev.size() else army_cell[i]
		army_moved_day[i] = moved[i] if i < moved.size() else 0
		army_class[i] = klass[i] if i < klass.size() else 0
		army_headcount[i] = head[i] if i < head.size() else 0
		army_flags[i] = flags[i] if i < flags.size() else 0
		army_visible[i] = 1
		army_cell_key[i] = (int(army_cell[i]) << 24) | (int(army_flags[i]) << 4) \
			| (int(army_class[i]) & 0x0F)
		_sig_acc = _mix_signature(_sig_acc, int(army_handle[i]))
		_sig_acc = _mix_signature(_sig_acc, int(army_owner[i]))
		_sig_acc = _mix_signature(_sig_acc, int(army_cell_key[i]))
		_sig_acc = _mix_signature(_sig_acc, int(army_headcount[i]))
		# The optional M1 visual projection participates in the same rewrite
		# signature only for composition/heading; cue updates are incremental.
		formation_sig_acc = _mix_army_formation_signature(formation_sig_acc, i)
	army_signature = _sig_acc
	army_formation_signature = formation_sig_acc
	_sig_acc = 0
	selected_army = int(snap.get("selected_army", selected_army))
	var area = snap.get("selected_area_cells", null)
	selected_area_cells = area as PackedInt32Array if area is PackedInt32Array else PackedInt32Array()


func _mix_army_formation_signature(seed: int, row: int) -> int:
	var mixed := seed
	mixed = _mix_signature(mixed, int(army_handle[row]))
	mixed = _mix_signature(mixed, int(army_owner[row]))
	var bounds := get_army_composition_range(row)
	for index in range(bounds.x, bounds.y):
		mixed = _mix_signature(mixed, int(army_composition_unit[index]))
		mixed = _mix_signature(mixed, int(army_composition_weight[index]))
	mixed = _mix_signature(mixed, army_heading_for_row(row))
	return mixed


func _mix_signature(seed: int, value: int) -> int:
	return int((seed * 1000003 + value) & 0x7FFFFFFFFFFFFFFF)


func _unpack_engagements(snap: Dictionary) -> void:
	var rows: Dictionary = snap.get("engagements", {})
	# Rows may come as flat Packed arrays (one slot per engagement, the current
	# contract) or as one Packed array per field nested inside the dictionary.
	# Normalise both here so the layers only ever see flat SoA.
	var a := _flat_int(rows.get("cell_a", PackedInt32Array()))
	var b := _flat_int(rows.get("cell_b", PackedInt32Array()))
	if a.is_empty() and b.size() >= 2:
		# pairs (a0,b0,a1,b1,...) shape
		var n := b.size() / 2
		a.resize(n)
		var pairs := PackedInt32Array()
		pairs.resize(n)
		for i in n:
			a[i] = b[i * 2]
			pairs[i] = b[i * 2 + 1]
		b = pairs
	engagement_cell_a = a
	engagement_cell_b = b
	engagement_progress = _flat_int(rows.get("progress_q16", PackedInt32Array()))
	engagement_side = _flat_int(rows.get("attacker_slot", PackedInt32Array()))
	engagement_battle = _flat_int_byte(rows.get("battle", PackedByteArray()))
	attacker_cell_cells = _flat_int(rows.get("attacker_cell", PackedInt32Array()))
	engagement_count = a.size()


func _flat_int(value: Variant) -> PackedInt32Array:
	if value is PackedInt32Array:
		return value
	if value is PackedInt64Array:
		var src64 := value as PackedInt64Array
		var out := PackedInt32Array()
		out.resize(src64.size())
		for i in src64.size():
			out[i] = int(src64[i])
		return out
	return PackedInt32Array()


func _flat_int_byte(value: Variant) -> PackedByteArray:
	if value is PackedByteArray:
		return value
	if value is PackedInt32Array:
		var src := value as PackedInt32Array
		var out := PackedByteArray()
		out.resize(src.size())
		for i in src.size():
			out[i] = int(src[i]) & 0xFF
		return out
	return PackedByteArray()


func _unpack_convoys(snap: Dictionary) -> void:
	var rows: Dictionary = snap.get("convoys", {})
	var cur := _int_array(rows.get("current_cell", PackedInt32Array()))
	convoy_current = cur
	convoy_dest = _int_array(rows.get("dest_cell", PackedInt32Array()))
	convoy_country = _int_array(rows.get("country_slot", PackedInt32Array()))
	convoy_risk = _int_array(rows.get("risk_q16", PackedInt32Array()))
	convoy_count = cur.size()


func _unpack_controllers(snap: Dictionary) -> void:
	var cells := _int_array(snap.get("controller_cells", PackedInt32Array()))
	var slots := _int_array(snap.get("controller_slots", PackedInt32Array()))
	if cells.size() != slots.size():
		controller_count = 0
		return
	# Sparse control rows (occupier differs from owner) become a dense per-cell
	# slot LUT; the occupation layer only ever uploads on control_revision.
	_scratch_cell = cells
	_scratch_slot = slots
	controller_cells = cells
	controller_slots = slots
	controller_count = cells.size()
	controller_snapshot_revision = revision


func _unpack_front(snap: Dictionary) -> void:
	var keys := _int_array(snap.get("front_edges", PackedInt32Array()))
	var progress := _byte_array(snap.get("front_progress", PackedByteArray()))
	if progress.size() != keys.size():
		progress = PackedByteArray()
		progress.resize(keys.size())
		progress.fill(128)
	front_edge_key = keys
	front_edge_progress = progress
	front_edge_count = keys.size()
	front_snapshot_revision = revision


## Fog rule from §8/§14.1: foreign armies, engagements and enemy convoys only on
## FOG_VISIBLE cells. Own (player) armies always render: the player always knows
## where his own troops are. `visible_arr` empty => fog not solved => full vision.
func apply_fog(map, fog_enabled: bool) -> void:
	var visible: PackedByteArray = map.visible_arr if map != null else PackedByteArray()
	var fog := fog_enabled and visible.size() > 0
	for i in army_count:
		if not fog:
			army_visible[i] = 1
			continue
		var own := int(army_owner[i]) == player_slot and player_slot >= 0
		var cell := int(army_cell[i])
		army_visible[i] = 1 if own else (
			1 if cell >= 0 and cell < visible.size() and visible[cell] != 0 else 0)


func cell_visible(cell: int) -> bool:
	if map_visible_hint.is_empty():
		return true
	return cell >= 0 and cell < map_visible_hint.size() and map_visible_hint[cell] != 0


## Set by the manager each frame from MapData.visible_arr (no copy).
var map_visible_hint: PackedByteArray = PackedByteArray()
var fog_active: bool = false
