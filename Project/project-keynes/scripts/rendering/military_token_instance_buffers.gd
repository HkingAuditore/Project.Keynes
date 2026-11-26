extends RefCounted

## Maintains token instance storage and publishes movement and attack cues.

static func _ensure_capacity(layer: MilitaryArmyTokenLayer, count: int) -> void:
	var cap := maxi(count, MilitaryArmyTokenLayer.INSTANCE_CAP)
	if layer._ax.size() >= cap:
		return
	layer._ax.resize(cap)
	layer._ay.resize(cap)
	layer._fx.resize(cap)
	layer._fy.resize(cap)
	layer._tx.resize(cap)
	layer._ty.resize(cap)
	layer._t0.resize(cap)
	layer._cell.resize(cap)
	layer._slot.resize(cap)
	layer._klass.resize(cap)
	layer._heads.resize(cap)
	layer._flags.resize(cap)
	layer._vis.resize(cap)
	layer._hidden.resize(cap)
	layer._position_initialized.resize(cap)
	layer._row.resize(cap)
	layer._handle.resize(cap)
	layer._heading.resize(cap)
	layer._attack_seq.resize(cap)
	layer._hit_seq.resize(cap)
	layer._last_attack_seq.resize(cap)
	layer._last_hit_seq.resize(cap)
	layer._attack_started.resize(cap)
	layer._hit_started.resize(cap)
	layer._formed_start.resize(cap)
	layer._formed_count.resize(cap)
	layer._formed_proto.resize(cap * 5)
	layer._formed_dx.resize(cap * 5)
	layer._formed_dy.resize(cap * 5)
	layer._formed_scale.resize(cap * 5)
	for index in range(cap):
		layer._row[index] = -1
		layer._formed_start[index] = -1
		layer._formed_count[index] = 0
		layer._attack_started[index] = -1.0
		layer._hit_started[index] = -1.0
	for index in range(cap * 5):
		layer._formed_proto[index] = 0
		layer._formed_dx[index] = 0.0
		layer._formed_dy[index] = 0.0
		layer._formed_scale[index] = 0.0


static func _cell_world(layer: MilitaryArmyTokenLayer, cell: int, ref_x: float) -> Vector2:
	var cell_obj = layer._map.cell_at(cell) if layer._map != null else null
	if cell_obj == null:
		return Vector2(NAN, NAN)
	var p := HexUtils.cube_to_world(cell_obj.q, cell_obj.r, layer._hex_size)
	if layer._wrap > 0.0001:
		if not is_nan(ref_x):
			p = HexUtils.nearest_display_world(p, ref_x, layer._wrap)
	return p


static func _camera_x(layer: MilitaryArmyTokenLayer) -> float:
	if layer._camera != null and is_instance_valid(layer._camera):
		return layer._camera.global_position.x
	return NAN


static func _rebuild(layer: MilitaryArmyTokenLayer, feed, count: int) -> void:
	layer._ensure_capacity(count)
	layer._sync_cues(feed, false)
	var ref_x := layer._camera_x()
	var started := Time.get_ticks_usec()
	for i in count:
		var cell: int = feed.army_cell[i]
		var prev: int = feed.army_prev_cell[i]
		var to := layer._cell_world(cell, ref_x)
		var from := to
		if prev >= 0 and prev != cell:
			var f := layer._cell_world(prev, to.x if not is_nan(to.x) else ref_x)
			if not is_nan(f.x):
				from = f
		layer._cell[i] = cell
		layer._slot[i] = feed.army_owner[i]
		layer._klass[i] = feed.army_class[i]
		layer._heads[i] = feed.army_headcount[i]
		layer._flags[i] = feed.army_flags[i]
		layer._vis[i] = feed.army_visible[i]
		layer._heading[i] = feed.army_heading_for_row(i)
		var is_new := layer._position_initialized[i] == 0
		if is_new or prev == cell:
			# 新棋子 / 没换格：直接落在目标位置。
			layer._ax[i] = to.x
			layer._ay[i] = to.y
			layer._fx[i] = to.x
			layer._fy[i] = to.y
			layer._tx[i] = to.x
			layer._ty[i] = to.y
			layer._t0[i] = -100.0
		else:
			# 换格：从上一格出发，MOVE_ANIM_SECONDS 内插值到新格。
			layer._fx[i] = layer._ax[i] if layer._ax[i] != 0.0 else from.x
			layer._fy[i] = layer._ay[i] if layer._ay[i] != 0.0 else from.y
			layer._tx[i] = to.x
			layer._ty[i] = to.y
			layer._t0[i] = layer._wall_time
		layer._position_initialized[i] = 1
	layer._army_count = count
	layer._dirty = true
	layer._write_instances()
	layer._stats["write_usec"] = Time.get_ticks_usec() - started


static func _sync_cues(layer: MilitaryArmyTokenLayer, feed, initial: bool) -> PackedInt32Array:
	var changed := PackedInt32Array()
	var count := mini(int(feed.army_count), layer._handle.size())
	if count == 0:
		layer._cue_initialized = true
		return changed
	var previous_count := layer._army_count
	for i in count:
		var new_handle := int(feed.army_handle[i])
		var new_attack := int(feed.army_attack_seq_for_row(i))
		var new_hit := int(feed.army_hit_seq_for_row(i))
		var same_army := layer._cue_initialized and not initial and i < previous_count \
			and layer._handle[i] == new_handle
		if same_army and new_attack != int(layer._last_attack_seq[i]):
			layer._attack_started[i] = layer._wall_time
			changed.append(i)
		if same_army and new_hit != int(layer._last_hit_seq[i]):
			layer._hit_started[i] = layer._wall_time
			if changed.is_empty() or changed[changed.size() - 1] != i:
				changed.append(i)
		if not same_army:
			layer._attack_started[i] = -1.0
			layer._hit_started[i] = -1.0
			# Native compacts army rows. A new handle in the same row must snap
			# to its own cell instead of inheriting the previous army's tween.
			layer._position_initialized[i] = 0
		layer._handle[i] = new_handle
		layer._last_attack_seq[i] = new_attack
		layer._last_hit_seq[i] = new_hit
		layer._attack_seq[i] = new_attack
		layer._hit_seq[i] = new_hit
	layer._cue_initialized = true
	return changed
