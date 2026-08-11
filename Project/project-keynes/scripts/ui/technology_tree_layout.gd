class_name TechnologyTreeLayout
extends RefCounted

# Static geometry for the technology tree. Coordinates are computed once from the
# full catalog and never move afterwards, so fog can hide nodes without the
# remaining tree shifting under the player's cursor.

const NODE_SIZE := Vector2(152.0, 50.0)
const MILESTONE_SIZE := Vector2(208.0, 58.0)
const COLUMN_GAP := 26.0
const ROW_GAP := 44.0
const ERA_HEADER_HEIGHT := 30.0
const ERA_PADDING := 22.0
const ERA_GAP := 18.0
const EDGE_SEGMENTS := 14
const BARYCENTRE_PASSES := 3
const FALLBACK_DOMAIN_IDS := ["agriculture", "engineering", "science", "society"]


static func build(definitions: Array, eras: Array, domains: Array = [],
		visual_edges: Array = []) -> Dictionary:
	var count := definitions.size()
	if count == 0:
		return {"ok": false, "nodes": [], "edges": [], "bands": [],
			"parents": [], "children": [], "content_rect": Rect2()}
	var domain_indices := _domain_indices(definitions, domains)
	var lane_indices := _lane_indices(definitions, domain_indices)
	var index_by_id := {}
	for i in range(count):
		index_by_id[String((definitions[i] as Dictionary).get("id", ""))] = i
	var parents: Array[PackedInt32Array] = []
	var children: Array[PackedInt32Array] = []
	for i in range(count):
		parents.append(PackedInt32Array())
		children.append(PackedInt32Array())
	var edge_pairs: Array[Dictionary] = []
	# Packed arrays nested in an Array are copied on subscript, so every edge is
	# written back explicitly instead of mutating a temporary. Only hard edges
	# participate in dependency depth; the other kinds are cached drawing data.
	if not visual_edges.is_empty():
		for edge_value in visual_edges:
			var edge: Dictionary = edge_value
			var parent := int(index_by_id.get(String(edge.get("from", "")), -1))
			var child := int(index_by_id.get(String(edge.get("to", "")), -1))
			var kind := String(edge.get("kind", ""))
			if parent < 0 or child < 0 or parent == child \
					or kind not in ["hard", "alternative", "application", "milestone_candidate"]:
				continue
			edge_pairs.append({"from": parent, "to": child, "kind": kind})
			if kind != "hard":
				continue
			var child_parents: PackedInt32Array = parents[child]
			if not child_parents.has(parent):
				child_parents.append(parent)
				parents[child] = child_parents
			var parent_children: PackedInt32Array = children[parent]
			if not parent_children.has(child):
				parent_children.append(child)
				children[parent] = parent_children
	else:
		for child in range(count):
			var definition: Dictionary = definitions[child]
			var child_parents := PackedInt32Array()
			for source_id in definition.get("prerequisite_ids", PackedStringArray()):
				var parent := int(index_by_id.get(String(source_id), -1))
				if parent < 0 or parent == child or parent in child_parents:
					continue
				child_parents.append(parent)
				var parent_children: PackedInt32Array = children[parent]
				parent_children.append(child)
				children[parent] = parent_children
				edge_pairs.append({"from": parent, "to": child, "kind": "hard"})
			parents[child] = child_parents

	var era_order := _era_order(definitions, eras)
	var era_slot := {}
	for i in range(era_order.size()):
		era_slot[String(era_order[i].get("id", ""))] = i
	var members: Array[PackedInt32Array] = []
	for i in range(era_order.size()):
		members.append(PackedInt32Array())
	for i in range(count):
		var era_id := String((definitions[i] as Dictionary).get("era_id", ""))
		var owner_slot := int(era_slot.get(era_id, 0))
		var owner_members: PackedInt32Array = members[owner_slot]
		owner_members.append(i)
		members[owner_slot] = owner_members

	var positions := PackedVector2Array()
	positions.resize(count)
	var sizes := PackedVector2Array()
	sizes.resize(count)
	var layers := PackedInt32Array()
	layers.resize(count)
	var band_indices := PackedInt32Array()
	band_indices.resize(count)
	for i in range(count):
		sizes[i] = MILESTONE_SIZE if bool((definitions[i] as Dictionary).get(
			"is_milestone", false)) else NODE_SIZE

	var bands: Array[Dictionary] = []
	var band_top := 0.0
	for slot in range(era_order.size()):
		var band_members := members[slot]
		var rows := _band_rows(band_members, parents, definitions)
		var content_top := band_top + ERA_HEADER_HEIGHT
		var row_top := content_top
		for row_index in range(rows.size()):
			var row: PackedInt32Array = rows[row_index]
			var row_height := 0.0
			for node in row:
				row_height = maxf(row_height, sizes[node].y)
			for node in row:
				layers[node] = row_index
				band_indices[node] = slot
				positions[node] = Vector2(0.0, row_top + (row_height - sizes[node].y) * 0.5)
			row_top += row_height + ROW_GAP
		var band_bottom := row_top - (ROW_GAP if not rows.is_empty() else 0.0) + ERA_PADDING
		bands.append({
			"era_index": slot,
			"id": String(era_order[slot].get("id", "")),
			"display_name": String(era_order[slot].get("display_name", "")),
			"rows": rows,
			"top": band_top,
			"bottom": band_bottom,
			"content_top": content_top,
		})
		band_top = band_bottom + ERA_GAP

	_assign_columns(bands, positions, sizes, parents, children, lane_indices)

	var nodes: Array[Dictionary] = []
	var content_rect := Rect2()
	for i in range(count):
		var rect := Rect2(positions[i], sizes[i])
		nodes.append({
			"index": i,
			"rect": rect,
			"domain": domain_indices[i],
			"lane": lane_indices[i],
			"is_milestone": bool((definitions[i] as Dictionary).get("is_milestone", false)),
			"is_era_key": bool((definitions[i] as Dictionary).get("is_era_key", false)),
			"era_index": band_indices[i],
			"layer": layers[i],
		})
		content_rect = rect if i == 0 else content_rect.merge(rect)

	var edges: Array[Dictionary] = []
	for pair in edge_pairs:
		var from := int(pair.from)
		var to := int(pair.to)
		var edge_kind := String(pair.kind)
		var points := _edge_points(
			Rect2(positions[from], sizes[from]), Rect2(positions[to], sizes[to]))
		var bounds := Rect2(points[0], Vector2.ZERO)
		for point in points:
			bounds = bounds.expand(point)
		edges.append({
			"from": from,
			"to": to,
			"kind": edge_kind,
			"points": points,
			"bounds": bounds.grow(3.0),
		})

	for band in bands:
		var rect := Rect2(content_rect.position.x, float(band.top),
			content_rect.size.x, float(band.bottom) - float(band.top))
		band["rect"] = rect

	return {
		"ok": true,
		"nodes": nodes,
		"edges": edges,
		"bands": bands,
		"parents": parents,
		"children": children,
		"content_rect": content_rect,
	}


static func _domain_indices(definitions: Array, domains: Array) -> PackedInt32Array:
	var order: Array[String] = []
	for domain in domains:
		order.append(String((domain as Dictionary).get("id", "")))
	if order.is_empty():
		for domain_id in FALLBACK_DOMAIN_IDS:
			order.append(String(domain_id))
	var indices := PackedInt32Array()
	for definition in definitions:
		var data: Dictionary = definition
		var resolved := order.find(String(data.get("domain_id", "")))
		indices.append(maxi(0, resolved))
	return indices


static func _lane_indices(definitions: Array,
		fallback_indices: PackedInt32Array) -> PackedInt32Array:
	var lane_order := PackedStringArray()
	var indices := PackedInt32Array()
	for index in range(definitions.size()):
		var definition: Dictionary = definitions[index]
		var lane := String(definition.get("layout_lane", ""))
		if lane.is_empty():
			indices.append(fallback_indices[index])
			continue
		var lane_index := lane_order.find(lane)
		if lane_index < 0:
			lane_order.append(lane)
			lane_index = lane_order.size() - 1
		indices.append(lane_index)
	return indices


static func _era_order(definitions: Array, eras: Array) -> Array[Dictionary]:
	var order: Array[Dictionary] = []
	for era in eras:
		var data: Dictionary = era
		order.append({
			"id": String(data.get("id", "")),
			"display_name": String(data.get("display_name", String(data.get("id", "")))),
		})
	if not order.is_empty():
		return order
	# Catalog order is authoritative when no era metadata was supplied.
	for definition in definitions:
		var era_id := String((definition as Dictionary).get("era_id", ""))
		var known := false
		for entry in order:
			if String(entry.id) == era_id:
				known = true
				break
		if not known:
			order.append({"id": era_id, "display_name": era_id})
	return order


# Rows are the local dependency depth inside one era. The era milestone always
# terminates its band so the next era reads as a gated continuation.
static func _band_rows(band_members: PackedInt32Array,
		parents: Array[PackedInt32Array], definitions: Array) -> Array[PackedInt32Array]:
	var rows: Array[PackedInt32Array] = []
	if band_members.is_empty():
		return rows
	var in_band := {}
	for node in band_members:
		in_band[node] = true
	var depth := {}
	var milestone := -1
	var resolved := 0
	while resolved < band_members.size():
		var progressed := false
		for node in band_members:
			if depth.has(node):
				continue
			var node_depth := 0
			var ready := true
			for parent in parents[node]:
				if not in_band.has(parent):
					continue
				if not depth.has(parent):
					ready = false
					break
				node_depth = maxi(node_depth, int(depth[parent]) + 1)
			if not ready:
				continue
			depth[node] = node_depth
			resolved += 1
			progressed = true
		if not progressed:
			# Defensive: a malformed catalog cycle must not hang the layout.
			for node in band_members:
				if not depth.has(node):
					depth[node] = 0
					resolved += 1
			break
	var max_depth := 0
	for node in band_members:
		if bool((definitions[node] as Dictionary).get("is_milestone", false)):
			milestone = node
			continue
		max_depth = maxi(max_depth, int(depth[node]))
	if milestone >= 0:
		depth[milestone] = max_depth + 1
		max_depth += 1
	for row_index in range(max_depth + 1):
		var row := PackedInt32Array()
		for node in band_members:
			if int(depth[node]) == row_index:
				row.append(node)
		if not row.is_empty():
			rows.append(row)
	return rows


static func _assign_columns(bands: Array[Dictionary], positions: PackedVector2Array,
		sizes: PackedVector2Array, parents: Array[PackedInt32Array],
		children: Array[PackedInt32Array], domain_indices: PackedInt32Array) -> void:
	for pass_index in range(BARYCENTRE_PASSES):
		var downward := pass_index % 2 == 0
		var band_range := range(bands.size()) if downward \
			else range(bands.size() - 1, -1, -1)
		for band_index in band_range:
			var rows: Array = bands[band_index].rows
			var row_range := range(rows.size()) if downward \
				else range(rows.size() - 1, -1, -1)
			for row_index in row_range:
				var row: PackedInt32Array = rows[row_index]
				var ordered := _order_row(row, positions, sizes, parents, children,
					domain_indices, pass_index == 0, downward)
				_place_row(ordered, positions, sizes)


static func _order_row(row: PackedInt32Array, positions: PackedVector2Array,
		sizes: PackedVector2Array, parents: Array[PackedInt32Array],
		children: Array[PackedInt32Array], domain_indices: PackedInt32Array,
		first_pass: bool, downward: bool) -> Array:
	var keyed: Array = []
	for node in row:
		var relatives: PackedInt32Array = parents[node] if downward else children[node]
		var total := 0.0
		var samples := 0
		for relative in relatives:
			total += positions[relative].x + sizes[relative].x * 0.5
			samples += 1
		var domain := domain_indices[node]
		# The first pass has no useful parent positions yet, so the stable
		# domain order gives a deterministic starting permutation.
		var key := float(domain) * 1000.0 if first_pass and samples == 0 \
			else (total / float(samples) if samples > 0 else positions[node].x)
		keyed.append({"node": node, "key": key, "domain": domain})
	keyed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if not is_equal_approx(float(a.key), float(b.key)):
			return float(a.key) < float(b.key)
		if int(a.domain) != int(b.domain):
			return int(a.domain) < int(b.domain)
		return int(a.node) < int(b.node)
	)
	var ordered: Array = []
	for entry in keyed:
		ordered.append(int(entry.node))
	return ordered


static func _place_row(ordered: Array, positions: PackedVector2Array,
		sizes: PackedVector2Array) -> void:
	var total_width := 0.0
	for node in ordered:
		total_width += sizes[node].x
	total_width += COLUMN_GAP * maxf(0.0, float(ordered.size() - 1))
	var cursor := -total_width * 0.5
	for node in ordered:
		positions[node] = Vector2(cursor, positions[node].y)
		cursor += sizes[node].x + COLUMN_GAP


static func _edge_points(from_rect: Rect2, to_rect: Rect2) -> PackedVector2Array:
	var start := Vector2(from_rect.position.x + from_rect.size.x * 0.5,
		from_rect.position.y + from_rect.size.y)
	var end := Vector2(to_rect.position.x + to_rect.size.x * 0.5, to_rect.position.y)
	var reach := maxf(26.0, absf(end.y - start.y) * 0.46)
	var control_a := start + Vector2(0.0, reach)
	var control_b := end - Vector2(0.0, reach)
	var points := PackedVector2Array()
	for step in range(EDGE_SEGMENTS + 1):
		var t := float(step) / float(EDGE_SEGMENTS)
		points.append(start.bezier_interpolate(control_a, control_b, end, t))
	return points
