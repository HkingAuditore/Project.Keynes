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
const FOCUS_COLUMNS := 4
const FOCUS_ROW_GAP := 30.0


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


# Produces a bounded working set for one route. The full graph remains the
# authority for parent/child relations, while the visible geometry contains at
# most one route across the previous, current and next visible eras.
static func build_focus(definitions: Array, eras: Array, domains: Array,
		visual_edges: Array, lane_id: String, focus_era: int,
		visible_nodes: PackedByteArray = PackedByteArray(),
		base_layout: Dictionary = {}) -> Dictionary:
	var full := base_layout if not base_layout.is_empty() \
		else build(definitions, eras, domains, visual_edges)
	if not bool(full.get("ok", false)) or definitions.is_empty():
		return {"ok": false, "nodes": [], "edges": [], "portals": [],
			"bands": [], "content_rect": Rect2()}
	var parents: Array = full.get("parents", [])
	var children: Array = full.get("children", [])
	var era_order := _era_order(definitions, eras)
	var era_by_id := {}
	for index in range(era_order.size()):
		era_by_id[String((era_order[index] as Dictionary).get("id", ""))] = index
	var clamped_era := clampi(focus_era, 0, maxi(0, era_order.size() - 1))
	var first_era := maxi(0, clamped_era - 1)
	var last_era := mini(era_order.size() - 1, clamped_era + 1)
	var members_by_era: Array[PackedInt32Array] = []
	for _era in range(era_order.size()):
		members_by_era.append(PackedInt32Array())
	var local_lookup := {}
	for index in range(definitions.size()):
		var definition: Dictionary = definitions[index]
		if bool(definition.get("is_milestone", false)):
			continue
		if String(definition.get("main_lane", definition.get("layout_lane", ""))) != lane_id:
			continue
		var era_index := int(era_by_id.get(String(definition.get("era_id", "")), -1))
		if era_index < first_era or era_index > last_era:
			continue
		if not visible_nodes.is_empty() \
				and (index >= visible_nodes.size() or visible_nodes[index] == 0):
			continue
		members_by_era[era_index].append(index)
		local_lookup[index] = true

	var nodes: Array[Dictionary] = []
	var rect_by_index := {}
	var bands: Array[Dictionary] = []
	var cursor_y := 0.0
	var content_rect := Rect2()
	var found := false
	for era_index in range(first_era, last_era + 1):
		var members := members_by_era[era_index]
		if members.is_empty():
			continue
		var ordered := Array(members)
		ordered.sort_custom(func(a: int, b: int) -> bool:
			var depth_a := _local_depth(a, members, parents)
			var depth_b := _local_depth(b, members, parents)
			if depth_a != depth_b:
				return depth_a < depth_b
			return a < b
		)
		var row_count := int(ceil(float(ordered.size()) / float(FOCUS_COLUMNS)))
		var band_top := cursor_y
		var body_top := band_top + ERA_HEADER_HEIGHT + 8.0
		for slot in range(ordered.size()):
			var technology := int(ordered[slot])
			var column := slot % FOCUS_COLUMNS
			var row := slot / FOCUS_COLUMNS
			var columns_in_row := mini(FOCUS_COLUMNS, ordered.size() - row * FOCUS_COLUMNS)
			var row_width := columns_in_row * NODE_SIZE.x \
				+ maxi(0, columns_in_row - 1) * COLUMN_GAP
			var x := -row_width * 0.5 + column * (NODE_SIZE.x + COLUMN_GAP)
			var rect := Rect2(Vector2(x, body_top + row * (NODE_SIZE.y + FOCUS_ROW_GAP)), NODE_SIZE)
			rect_by_index[technology] = rect
			nodes.append({
				"index": technology,
				"rect": rect,
				"domain": _domain_index(definitions[technology], domains),
				"era_index": era_index,
				"is_focus_era": era_index == clamped_era,
			})
			content_rect = rect if not found else content_rect.merge(rect)
			found = true
		var band_bottom := body_top + row_count * NODE_SIZE.y \
			+ maxi(0, row_count - 1) * FOCUS_ROW_GAP + ERA_PADDING
		bands.append({
			"era_index": era_index,
			"id": String((era_order[era_index] as Dictionary).get("id", "")),
			"display_name": String((era_order[era_index] as Dictionary).get("display_name", "")),
			"top": band_top,
			"bottom": band_bottom,
			"is_focus": era_index == clamped_era,
		})
		cursor_y = band_bottom + ERA_GAP

	var edges: Array[Dictionary] = []
	var portals: Array[Dictionary] = []
	for node_value in nodes:
		var node: Dictionary = node_value
		var technology := int(node.index)
		for parent in parents[technology]:
			if local_lookup.has(parent):
				var points := _edge_points(rect_by_index[parent], rect_by_index[technology])
				edges.append({"from": parent, "to": technology, "kind": "hard", "points": points})
			elif visible_nodes.is_empty() or (parent < visible_nodes.size() and visible_nodes[parent] != 0):
				portals.append({
					"owner": technology,
					"target": int(parent),
					"direction": "incoming",
				})
		for child in children[technology]:
			if local_lookup.has(child):
				continue
			if visible_nodes.is_empty() or (child < visible_nodes.size() and visible_nodes[child] != 0):
				portals.append({
					"owner": technology,
					"target": int(child),
					"direction": "outgoing",
				})
	var focus_index_by_id := {}
	for index in local_lookup:
		focus_index_by_id[String((definitions[index] as Dictionary).get("id", ""))] = int(index)
	for edge_value in visual_edges:
		var visual: Dictionary = edge_value
		if String(visual.get("kind", "")) != "application":
			continue
		var from := int(focus_index_by_id.get(String(visual.get("from", "")), -1))
		var to := int(focus_index_by_id.get(String(visual.get("to", "")), -1))
		if from < 0 or to < 0:
			continue
		edges.append({
			"from": from,
			"to": to,
			"kind": "application",
			"points": _edge_points(rect_by_index[from], rect_by_index[to]),
		})
	for band in bands:
		band["rect"] = Rect2(content_rect.position.x - VIEW_SIDE_PADDING,
			float(band.top), content_rect.size.x + VIEW_SIDE_PADDING * 2.0,
			float(band.bottom) - float(band.top))
	if found:
		content_rect = content_rect.grow(VIEW_SIDE_PADDING)
		content_rect.size.y = maxf(content_rect.size.y, cursor_y - content_rect.position.y)
	return {
		"ok": true,
		"nodes": nodes,
		"edges": edges,
		"portals": portals,
		"bands": bands,
		"parents": parents,
		"children": children,
		"content_rect": content_rect,
		"lane_id": lane_id,
		"focus_era": clamped_era,
	}


const VIEW_SIDE_PADDING := 44.0


static func _local_depth(node: int, members: PackedInt32Array,
		parents: Array) -> int:
	var member_lookup := {}
	for member in members:
		member_lookup[member] = true
	var depth := 0
	var frontier := PackedInt32Array([node])
	var visited := {}
	while not frontier.is_empty():
		var current := frontier[frontier.size() - 1]
		frontier.resize(frontier.size() - 1)
		for parent in parents[current]:
			if not member_lookup.has(parent) or visited.has(parent):
				continue
			visited[parent] = true
			depth += 1
			frontier.append(parent)
	return depth


static func _domain_index(definition: Dictionary, domains: Array) -> int:
	var domain_id := String(definition.get("domain_id", ""))
	for index in range(domains.size()):
		if String((domains[index] as Dictionary).get("id", "")) == domain_id:
			return index
	return maxi(0, FALLBACK_DOMAIN_IDS.find(domain_id))


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
	if absf((to_rect.position.y + to_rect.size.y * 0.5) \
			- (from_rect.position.y + from_rect.size.y * 0.5)) < NODE_SIZE.y * 0.65:
		var horizontal_start := Vector2(from_rect.end.x,
			from_rect.position.y + from_rect.size.y * 0.5)
		var horizontal_end := Vector2(to_rect.position.x,
			to_rect.position.y + to_rect.size.y * 0.5)
		if horizontal_end.x < horizontal_start.x:
			horizontal_start = Vector2(from_rect.position.x,
				from_rect.position.y + from_rect.size.y * 0.5)
			horizontal_end = Vector2(to_rect.end.x,
				to_rect.position.y + to_rect.size.y * 0.5)
		var horizontal_reach := maxf(18.0,
			absf(horizontal_end.x - horizontal_start.x) * 0.42)
		var horizontal_a := horizontal_start + Vector2(
			horizontal_reach if horizontal_end.x >= horizontal_start.x else -horizontal_reach, 0.0)
		var horizontal_b := horizontal_end - Vector2(
			horizontal_reach if horizontal_end.x >= horizontal_start.x else -horizontal_reach, 0.0)
		var horizontal_points := PackedVector2Array()
		for step in range(EDGE_SEGMENTS + 1):
			var horizontal_t := float(step) / float(EDGE_SEGMENTS)
			horizontal_points.append(horizontal_start.bezier_interpolate(
				horizontal_a, horizontal_b, horizontal_end, horizontal_t))
		return horizontal_points
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
