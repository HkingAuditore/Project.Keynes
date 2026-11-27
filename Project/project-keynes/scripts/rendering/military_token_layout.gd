extends RefCounted

## Lays out individual formations and aggregate army tokens.

static func _write_instances(layer: MilitaryArmyTokenLayer) -> void:
	if layer._batch == null:
		return
	var mm := layer._batch.multimesh
	var size := layer._token_world_size()
	if layer._material != null:
		layer._material.set_shader_parameter("aggregate_mode", layer._lod_mode == MilitaryArmyTokenLayer.LOD_AGGREGATE)
		layer._material.set_shader_parameter("hex_size", layer._hex_size)
		layer._material.set_shader_parameter("layer_alpha", 1.0)
	if layer._formation_material != null:
		layer._set_formation_parameter("visual_seconds", layer._wall_time)
		layer._set_formation_parameter("layer_alpha", 1.0)
	for row in layer._row.size():
		layer._row[row] = -1
		layer._formed_start[row] = -1
		layer._formed_count[row] = 0
	layer._formation_write_count = 0
	var paper_emitted := 0
	var formation_emitted := 0
	var formation_armies := 0
	var paper_fallback := 0
	if layer._lod_mode == MilitaryArmyTokenLayer.LOD_AGGREGATE:
		paper_emitted = layer._write_aggregated(mm, size)
	else:
		for row in layer._priority_army_order():
			if paper_emitted + formation_emitted >= MilitaryArmyTokenLayer.INSTANCE_CAP:
				break
			if layer._vis[row] == 0 or is_nan(layer._ax[row]):
				continue
			var pos := Vector2(layer._ax[row], layer._ay[row])
			var prototypes := layer._composition_prototypes(layer._army_feed, row)
			var wants_formation := layer._lod_mode == MilitaryArmyTokenLayer.LOD_FORMATION \
				and layer._has_formation_backend and not prototypes.is_empty()
			if wants_formation:
				var member_protos := layer._member_prototypes_for_row(layer._army_feed, row, prototypes)
				if not member_protos.is_empty() \
						and paper_emitted + formation_emitted + member_protos.size() <= MilitaryArmyTokenLayer.INSTANCE_CAP:
					var written := layer._write_formation_members(row, pos, member_protos)
					if written > 0:
						formation_emitted += written
						formation_armies += 1
						continue
				# Never draw a partial formation. If the five-member layout does
				# not fit, this army falls back to one representative sprite.
				if paper_emitted + formation_emitted + 1 <= MilitaryArmyTokenLayer.INSTANCE_CAP:
					formation_emitted += layer._write_representative(
						row, pos, int(prototypes[0]))
					formation_armies += 1
					paper_fallback += 1
					continue
			elif layer._lod_mode == MilitaryArmyTokenLayer.LOD_REPRESENTATIVE \
					and layer._has_formation_backend and not prototypes.is_empty():
				if paper_emitted + formation_emitted + 1 <= MilitaryArmyTokenLayer.INSTANCE_CAP:
					formation_emitted += layer._write_representative(
						row, pos, int(prototypes[0]))
					formation_armies += 1
					continue
			if paper_emitted >= MilitaryArmyTokenLayer.INSTANCE_CAP - formation_emitted:
				break
			layer._write_paper_individual(mm, row, size, paper_emitted)
			paper_emitted += 1
			paper_fallback += 1
	if layer._formation_batch != null:
		layer._formation_batch.multimesh.visible_instance_count = formation_emitted
	mm.visible_instance_count = paper_emitted
	layer._stats["instances"] = paper_emitted + formation_emitted
	layer._stats["paper_instances"] = paper_emitted
	layer._stats["formation_instances"] = formation_emitted
	layer._stats["formation_armies"] = formation_armies
	layer._stats["paper_fallback"] = paper_fallback
	layer._stats["catalog_units"] = layer._formation_catalog.dense_unit_count()
	layer._stats["catalog_mapped"] = layer._formation_catalog.mapped_unit_count()
	layer._stats["armies"] = layer._army_count
	layer._stats["aggregate"] = layer._lod_mode == MilitaryArmyTokenLayer.LOD_AGGREGATE
	layer._stats["lod"] = MilitaryArmyTokenLayer._lod_name(layer._lod_mode)
	layer._stats["uploads"] = int(layer._stats["uploads"]) + 1
	layer._update_selection_ring()
	layer._update_visibility()
	layer._dirty = false


static func _token_world_size(layer: MilitaryArmyTokenLayer) -> float:
	var world := layer._hex_size * MilitaryArmyTokenLayer.TOKEN_HEX_RATIO
	if layer._camera_zoom > 0.0001:
		world = minf(world, MilitaryArmyTokenLayer.TOKEN_SCREEN_MAX / layer._camera_zoom)
		world = maxf(world, MilitaryArmyTokenLayer.TOKEN_SCREEN_MIN / layer._camera_zoom)
	return world


static func _priority_army_order(layer: MilitaryArmyTokenLayer) -> Array[int]:
	var order: Array[int] = []
	if layer._selected_cell >= 0:
		for row in layer._army_count:
			if layer._vis[row] != 0 and layer._cell[row] == layer._selected_cell:
				order.append(row)
	for row in layer._army_count:
		if layer._selected_cell >= 0 and layer._cell[row] == layer._selected_cell:
			continue
		order.append(row)
	return order


static func _write_paper_individual(layer: MilitaryArmyTokenLayer, mm: MultiMesh, row: int, size: float,
		instance_index: int) -> void:
	var scale := size * (1.12 if layer._cell[row] == layer._selected_cell else 1.0)
	var tx := Transform2D(0.0, Vector2(scale, scale), 0.0,
		Vector2(layer._ax[row], layer._ay[row]))
	mm.set_instance_transform_2d(instance_index, tx)
	mm.set_instance_custom_data(instance_index, Color(float(layer._slot[row]),
		float(layer._klass[row]), float(layer._heads[row]), float(layer._flags[row])))
	layer._row[row] = instance_index


static func _write_aggregated(layer: MilitaryArmyTokenLayer, mm: MultiMesh, size: float) -> int:
	# 按格聚合：格子签名不变就复用上一轮的聚合结果，避免每帧 O(n) 重算。
	if layer._army_count == 0:
		layer._agg_cell.clear()
		layer._agg_slot.clear()
		layer._agg_klass.clear()
		layer._agg_heads.clear()
		layer._agg_flags.clear()
		layer._agg_count = 0
		layer._agg_sig = -1
		return 0
	var sig := layer._army_count
	for i in layer._army_count:
		if layer._vis[i] != 0:
			sig = layer._mix_aggregate_signature(sig, int(layer._handle[i]))
			sig = layer._mix_aggregate_signature(sig, int(layer._slot[i]))
			sig = layer._mix_aggregate_signature(sig, int(layer._cell[i]))
			sig = layer._mix_aggregate_signature(sig, int(layer._klass[i]))
			sig = layer._mix_aggregate_signature(sig, int(layer._heads[i]))
			sig = layer._mix_aggregate_signature(sig, int(layer._flags[i]))
	if sig != layer._agg_sig:
		layer._build_aggregate()
		layer._agg_sig = sig
	var emitted := 0
	for i in layer._agg_count:
		if emitted >= MilitaryArmyTokenLayer.INSTANCE_CAP:
			break
		var pos := layer._cell_world(layer._agg_cell[i], layer._camera_x())
		if is_nan(pos.x):
			continue
		var scale := size * (1.10 if layer._agg_cell[i] == layer._selected_cell else 1.0)
		var tx := Transform2D(0.0, Vector2(scale, scale), 0.0, pos)
		mm.set_instance_transform_2d(emitted, tx)
		mm.set_instance_custom_data(emitted, Color(float(layer._agg_slot[i]),
			float(layer._agg_klass[i]), float(layer._agg_heads[i]), float(layer._agg_flags[i])))
		emitted += 1
	return emitted


static func _mix_aggregate_signature(layer: MilitaryArmyTokenLayer, seed: int, value: int) -> int:
	return int((seed * 1000003 + value) & 0x7FFFFFFFFFFFFFFF)


static func _formation_representative_size(layer: MilitaryArmyTokenLayer, prototype_row: int) -> float:
	var world := layer._hex_size * 0.94 * layer._formation_catalog.sprite_scale(prototype_row)
	if layer._camera_zoom > 0.0001:
		world = minf(world, MilitaryArmyTokenLayer.TOKEN_SCREEN_MAX / layer._camera_zoom)
		world = maxf(world, MilitaryArmyTokenLayer.TOKEN_SCREEN_MIN / layer._camera_zoom)
	return world


static func _formation_member_size(layer: MilitaryArmyTokenLayer, prototype_row: int) -> float:
	var world := layer._hex_size * MilitaryArmyTokenLayer.FORMATION_MEMBER_HEX_RATIO \
		* layer._formation_catalog.sprite_scale(prototype_row)
	if layer._camera_zoom > 0.0001:
		world = minf(world, MilitaryArmyTokenLayer.FORMATION_MEMBER_SCREEN_MAX / layer._camera_zoom)
		world = maxf(world, MilitaryArmyTokenLayer.FORMATION_MEMBER_SCREEN_MIN / layer._camera_zoom)
	return world


static func _write_representative(layer: MilitaryArmyTokenLayer, row: int, pos: Vector2, prototype_row: int) -> int:
	var instance_index := layer._next_formation_instance()
	var scale := layer._formation_representative_size(prototype_row)
	layer._store_formation_member(row, 0, prototype_row, 0.0, 0.0, scale)
	layer._set_formation_instance(instance_index, row, 0, prototype_row, pos,
		0.0, 0.0, scale)
	layer._formed_start[row] = instance_index
	layer._formed_count[row] = 1
	layer._formation_write_count = instance_index + 1
	return 1


static func _write_formation_members(layer: MilitaryArmyTokenLayer, row: int, pos: Vector2,
		prototypes: PackedByteArray) -> int:
	var dominant := int(prototypes[0])
	var layout := layer._formation_catalog.layout_for(dominant, prototypes.size())
	if layout.is_empty():
		return 0
	var start := layer._next_formation_instance()
	for member in prototypes.size():
		var pair := layout[member] as Array
		var scale := layer._formation_member_size(int(prototypes[member]))
		var offset := Vector2(float(pair[0]), float(pair[1])) \
			* scale * MilitaryArmyTokenLayer.FORMATION_LAYOUT_SPACING
		layer._store_formation_member(row, member, int(prototypes[member]),
			offset.x, offset.y, scale)
		layer._set_formation_instance(start + member, row, member,
			int(prototypes[member]), pos, offset.x, offset.y, scale)
	layer._formed_start[row] = start
	layer._formed_count[row] = prototypes.size()
	layer._formation_write_count = start + prototypes.size()
	return prototypes.size()


static func _next_formation_instance(layer: MilitaryArmyTokenLayer) -> int:
	return layer._formation_write_count


static func _store_formation_member(layer: MilitaryArmyTokenLayer, row: int, member: int, prototype_row: int,
		dx: float, dy: float, scale: float) -> void:
	var index := row * 5 + member
	layer._formed_proto[index] = prototype_row
	layer._formed_dx[index] = dx
	layer._formed_dy[index] = dy
	layer._formed_scale[index] = scale


static func _set_formation_instance(layer: MilitaryArmyTokenLayer, instance_index: int, row: int, member: int,
		prototype_row: int, pos: Vector2, dx: float, dy: float,
		scale: float) -> void:
	var angle := layer._heading_radians(row)
	var member_pos := pos + Vector2(dx, dy).rotated(angle)
	var tx := Transform2D(angle, Vector2(scale, scale), 0.0, member_pos)
	var mm := layer._formation_batch.multimesh
	mm.set_instance_transform_2d(instance_index, tx)
	mm.set_instance_custom_data(instance_index,
		layer._formation_custom(row, member, prototype_row))
	mm.set_instance_color(instance_index, layer._owner_tint(layer._slot[row]))


static func _formation_custom(layer: MilitaryArmyTokenLayer, row: int, member: int, prototype_row: int) -> Color:
	var action := layer._action_for_row(row)
	var phase := 0.0
	if action <= MilitaryArmyTokenLayer.ACTION_MOVE:
		phase = fposmod(float(layer._handle[row]) * 0.137
			+ float(member) * 0.113, 1.0)
	elif action == MilitaryArmyTokenLayer.ACTION_HIT:
		phase = MilitaryArmyTokenLayer.one_shot_member_start(layer._hit_started[row], member)
	else:
		phase = MilitaryArmyTokenLayer.one_shot_member_start(layer._attack_started[row], member)
	return Color(float(prototype_row), float(action), phase, float(member))


static func one_shot_member_start(started: float, member: int) -> float:
	return maxf(0.0, started
		+ float(maxi(0, member)) * MilitaryArmyTokenLayer.ONE_SHOT_MEMBER_STAGGER_SECONDS)


static func _action_for_row(layer: MilitaryArmyTokenLayer, row: int) -> int:
	var elapsed := layer._wall_time
	if layer._hit_started[row] >= 0.0 \
			and elapsed - layer._hit_started[row] < MilitaryArmyTokenLayer.ONE_SHOT_ACTION_SECONDS:
		return MilitaryArmyTokenLayer.ACTION_HIT
	if layer._attack_started[row] >= 0.0 \
			and elapsed - layer._attack_started[row] < MilitaryArmyTokenLayer.ONE_SHOT_ACTION_SECONDS:
		return MilitaryArmyTokenLayer.ACTION_ATTACK
	return MilitaryArmyTokenLayer.ACTION_MOVE if layer._is_moving(row) else MilitaryArmyTokenLayer.ACTION_IDLE


static func _is_moving(layer: MilitaryArmyTokenLayer, row: int) -> bool:
	return row >= 0 and row < layer._t0.size() and layer._t0[row] > -50.0


static func _heading_radians(layer: MilitaryArmyTokenLayer, row: int) -> float:
	var q16 := int(layer._heading[row]) & 0xFFFF if row < layer._heading.size() else 0
	return TAU * float(q16) / 65536.0


static func _owner_tint(layer: MilitaryArmyTokenLayer, slot: int) -> Color:
	var hue := fposmod(float(slot) * 0.61803398875 + 0.04, 1.0)
	return Color.from_hsv(hue, 0.46, 0.82)


static func _composition_prototypes(layer: MilitaryArmyTokenLayer, feed, row: int) -> PackedByteArray:
	var out := PackedByteArray()
	if not layer._has_formation_backend or feed == null:
		return out
	# M2 rollout is player-only. During late binding the production player slot
	# is -1; fail closed to paper rather than treating every country as the player.
	# Explicit harness/debug fixtures may opt into all-row rendering.
	if layer._player_slot >= 0:
		if layer._slot[row] != layer._player_slot:
			return out
	elif not layer._formation_allow_all_for_tests:
		return out
	var composition: Array[Dictionary] = feed.get_army_top3_composition(row)
	if composition.is_empty():
		return out
	for entry in composition:
		var prototype_row := layer._formation_catalog.prototype_row_for_unit(
			int(entry.get("unit", -1)))
		if prototype_row < 0:
			out.clear()
			return out
		out.append(prototype_row)
	return out


static func _member_prototypes_for_row(layer: MilitaryArmyTokenLayer, feed, row: int,
		composition_prototypes: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	if composition_prototypes.is_empty():
		return out
	var composition: Array[Dictionary] = feed.get_army_top3_composition(row)
	var weights: Array = []
	for entry in composition:
		weights.append(float(entry.get("weight", 0)))
	var member_count := layer._formation_catalog.member_count_for_headcount(
		int(layer._heads[row]))
	var buckets := layer._formation_catalog.allocate_member_buckets(weights, member_count)
	var max_bucket := 0
	for value in buckets:
		max_bucket = maxi(max_bucket, int(value))
	for rank in max_bucket:
		for index in buckets.size():
			if int(buckets[index]) <= rank:
				continue
			out.append(int(composition_prototypes[index]))
	if out.size() != member_count:
		out.clear()
	return out


static func _update_row_formation_custom(layer: MilitaryArmyTokenLayer, row: int) -> void:
	if layer._formation_batch == null or row < 0 or row >= layer._army_count:
		return
	var start := layer._formed_start[row]
	var count := int(layer._formed_count[row])
	if start < 0 or count <= 0:
		return
	var mm := layer._formation_batch.multimesh
	for member in count:
		var prototype_row := int(layer._formed_proto[row * 5 + member])
		mm.set_instance_custom_data(start + member,
			layer._formation_custom(row, member, prototype_row))


static func _update_row_instance_transforms(layer: MilitaryArmyTokenLayer, row: int, paper_size: float) -> void:
	if row < 0 or row >= layer._army_count:
		return
	var pos := Vector2(layer._ax[row], layer._ay[row])
	if layer._row[row] >= 0 and layer._batch != null:
		var paper_scale := paper_size * (1.12 if layer._cell[row] == layer._selected_cell else 1.0)
		layer._batch.multimesh.set_instance_transform_2d(layer._row[row],
			Transform2D(0.0, Vector2(paper_scale, paper_scale), 0.0, pos))
	var count := int(layer._formed_count[row])
	if count <= 0 or layer._formation_batch == null:
		return
	var start := layer._formed_start[row]
	var angle := layer._heading_radians(row)
	for member in count:
		var index := row * 5 + member
		var member_pos := pos + Vector2(layer._formed_dx[index], layer._formed_dy[index]).rotated(angle)
		var scale := layer._formed_scale[index]
		layer._formation_batch.multimesh.set_instance_transform_2d(start + member,
			Transform2D(angle, Vector2(scale, scale), 0.0, member_pos))


static func _build_aggregate(layer: MilitaryArmyTokenLayer) -> void:
	# 稀疏累加（Dictionary 只出现在 zoom<0.35 的聚合分支，且格子签名不变不重跑）。
	var by_cell := {}
	for i in layer._army_count:
		if layer._vis[i] == 0:
			continue
		var cell: int = layer._cell[i]
		if not by_cell.has(cell):
			by_cell[cell] = [i]
		else:
			(by_cell[cell] as Array).append(i)
	layer._agg_cell.clear()
	layer._agg_slot.clear()
	layer._agg_klass.clear()
	layer._agg_heads.clear()
	layer._agg_flags.clear()
	for cell in by_cell:
		var rows: Array = by_cell[cell]
		var best := int(rows[0])
		var heads := 0
		var flags := 0
		var slot := layer._slot[best]
		for row in rows:
			heads += int(layer._heads[row])
			flags |= layer._flags[row]
			if layer._heads[row] > layer._heads[best]:
				best = row
				slot = layer._slot[best]
		layer._agg_cell.append(int(cell))
		layer._agg_slot.append(slot)
		layer._agg_klass.append(layer._klass[best])
		layer._agg_heads.append(heads)
		layer._agg_flags.append(flags)
	layer._agg_count = layer._agg_cell.size()
