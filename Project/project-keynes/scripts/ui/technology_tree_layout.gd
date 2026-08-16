class_name TechnologyTreeLayout
extends RefCounted

# Static geometry for the technology tree. Coordinates are computed once from the
# full catalog and never move afterwards, so fog can hide nodes without the
# remaining tree shifting under the player's cursor.

const NODE_SIZE := Vector2(152.0, 50.0)
const MILESTONE_SIZE := Vector2(208.0, 66.0)
const COLUMN_GAP := 26.0
const ROW_GAP := 44.0
const ERA_HEADER_HEIGHT := 30.0
const ERA_PADDING := 22.0
const ERA_GAP := 18.0
const EDGE_SEGMENTS := 14
const BARYCENTRE_PASSES := 3
const FALLBACK_DOMAIN_IDS := ["agriculture", "engineering", "science", "society"]
const FOCUS_ROW_GAP := 34.0
const LANE_GAP := 14.0
const LANE_HEADER_HEIGHT := 22.0
const LANE_INSET := 10.0
const SIBLING_GAP := 12.0
const MIN_NODE_WIDTH := 32.0
const MAX_NODE_WIDTH := 184.0


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
					or kind not in ["hard", "alternative", "application", "branch",
						"milestone_candidate"]:
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


# Four research domains share one atlas. Fine-grained routes still determine
# ordering, but each domain occupies a single vertical lane sized to the centre
# canvas so the tree fills the window without overflowing it.
static func build_focus(definitions: Array, eras: Array, domains: Array,
		visual_edges: Array, domain_id: String, focus_era: int,
		visible_nodes: PackedByteArray = PackedByteArray(),
		base_layout: Dictionary = {},
		canvas_size: Vector2 = Vector2.ZERO) -> Dictionary:
	var full := base_layout if not base_layout.is_empty() \
		else build(definitions, eras, domains, visual_edges)
	if not bool(full.get("ok", false)) or definitions.is_empty():
		return {"ok": false, "nodes": [], "edges": [], "portals": [],
			"bands": [], "lanes": [], "content_rect": Rect2()}
	var parents: Array = full.get("parents", [])
	var children: Array = full.get("children", [])
	var era_order := _era_order(definitions, eras)
	var era_by_id := {}
	for index in range(era_order.size()):
		era_by_id[String((era_order[index] as Dictionary).get("id", ""))] = index
	var clamped_era := clampi(focus_era, 0, maxi(0, era_order.size() - 1))
	var first_era := maxi(0, clamped_era - 1)
	var last_era := mini(era_order.size() - 1, clamped_era + 1)
	var domain_ids := _focus_domain_ids(domains)
	var domain_names := _focus_domain_names(domains)
	var domain_count := domain_ids.size()
	var metrics := _lane_metrics(canvas_size, domain_count)
	var node_size := Vector2(float(metrics.node_w), NODE_SIZE.y)
	var members_by_era: Array[PackedInt32Array] = []
	for _era in range(era_order.size()):
		members_by_era.append(PackedInt32Array())
	var local_lookup := {}
	var index_by_id := {}
	for index in range(definitions.size()):
		var definition: Dictionary = definitions[index]
		index_by_id[String(definition.get("id", ""))] = index
		if bool(definition.get("is_milestone", false)):
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
	var canvas_w := float(metrics.canvas_w)
	var content_rect := Rect2(Vector2(-canvas_w * 0.5, 0.0), Vector2(canvas_w, 0.0))
	var found := false
	var lane_meta: Array = []
	for domain in range(domain_count):
		lane_meta.append({
			"domain": domain,
			"id": String(domain_ids[domain]),
			"display_name": String(domain_names[domain]),
		})
	for era_index in range(first_era, last_era + 1):
		var members := members_by_era[era_index]
		if members.is_empty():
			continue
		var milestone := _era_milestone_index(era_order[era_index], index_by_id)
		if milestone >= 0 and not local_lookup.has(milestone):
			members.append(milestone)
			local_lookup[milestone] = true
		var band_top := cursor_y
		var header_h := ERA_HEADER_HEIGHT + LANE_HEADER_HEIGHT
		var body_y := band_top + header_h + 8.0
		var rows := _band_rows(members, parents, definitions)
		var visual_layer := 0
		for row_index in range(rows.size()):
			var ordered := _ordered_focus_row(rows[row_index], definitions)
			if ordered.is_empty():
				continue
			var milestone_row := ordered.size() == 1 \
				and bool((definitions[int(ordered[0])] as Dictionary).get(
					"is_milestone", false))
			if milestone_row:
				var technology := int(ordered[0])
				var milestone_w := clampf(float(metrics.inner) * 0.38, 120.0,
					minf(MILESTONE_SIZE.x, float(metrics.inner) - 16.0))
				var placed := _place_focus_node(technology, -milestone_w * 0.5,
					body_y, Vector2(milestone_w, MILESTONE_SIZE.y),
					definitions[technology] as Dictionary, domains,
					era_index, clamped_era, row_index, visual_layer, true)
				rect_by_index[technology] = placed.rect
				nodes.append(placed)
				found = true
				body_y += MILESTONE_SIZE.y + FOCUS_ROW_GAP
				visual_layer += 1
				continue
			var buckets: Array = []
			for _domain in range(domain_count):
				buckets.append([])
			for slot in range(ordered.size()):
				var technology := int(ordered[slot])
				var domain := clampi(_domain_index(definitions[technology] as Dictionary,
					domains), 0, domain_count - 1)
				var bucket: Array = buckets[domain]
				bucket.append(technology)
				buckets[domain] = bucket
			var max_stack := 1
			for domain in range(domain_count):
				max_stack = maxi(max_stack, (buckets[domain] as Array).size())
			for domain in range(domain_count):
				var bucket: Array = buckets[domain]
				var x := _lane_node_x(metrics, domain)
				for stack_index in range(bucket.size()):
					var technology := int(bucket[stack_index])
					var y := body_y + float(stack_index) * (node_size.y + SIBLING_GAP)
					var placed := _place_focus_node(technology, x, y, node_size,
						definitions[technology] as Dictionary, domains, era_index,
						clamped_era, row_index, visual_layer, false)
					rect_by_index[technology] = placed.rect
					nodes.append(placed)
					found = true
			body_y += float(max_stack) * node_size.y \
				+ float(maxi(0, max_stack - 1)) * SIBLING_GAP + FOCUS_ROW_GAP
			visual_layer += 1
		var band_bottom := body_y - FOCUS_ROW_GAP + ERA_PADDING
		var lanes: Array = []
		for domain in range(domain_count):
			var lane_x := float(metrics.left) \
				+ float(domain) * (float(metrics.lane_w) + float(metrics.gap))
			lanes.append({
				"domain": domain,
				"id": String(domain_ids[domain]),
				"display_name": String(domain_names[domain]),
				"rect": Rect2(lane_x, band_top + ERA_HEADER_HEIGHT,
					float(metrics.lane_w), band_bottom - band_top - ERA_HEADER_HEIGHT),
			})
		bands.append({
			"era_index": era_index,
			"id": String((era_order[era_index] as Dictionary).get("id", "")),
			"display_name": String((era_order[era_index] as Dictionary).get("display_name", "")),
			"top": band_top,
			"bottom": band_bottom,
			"is_focus": era_index == clamped_era,
			"milestone_index": milestone,
			"lanes": lanes,
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
			elif _is_visible_index(parent, visible_nodes) \
					and _era_outside_window(definitions[parent] as Dictionary,
						era_by_id, first_era, last_era):
				portals.append({
					"owner": technology,
					"target": int(parent),
					"direction": "incoming",
				})
		for child in children[technology]:
			if local_lookup.has(child):
				continue
			if _is_visible_index(child, visible_nodes) \
					and _era_outside_window(definitions[child] as Dictionary,
						era_by_id, first_era, last_era):
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
		var visual_kind := String(visual.get("kind", ""))
		if visual_kind not in ["application", "branch"]:
			continue
		var from := int(focus_index_by_id.get(String(visual.get("from", "")), -1))
		var to := int(focus_index_by_id.get(String(visual.get("to", "")), -1))
		if from < 0 or to < 0:
			continue
		edges.append({
			"from": from,
			"to": to,
			"kind": visual_kind,
			"points": _edge_points(rect_by_index[from], rect_by_index[to]),
		})
	content_rect.size.y = maxf(content_rect.size.y, cursor_y)
	for band in bands:
		band["rect"] = Rect2(content_rect.position.x, float(band.top),
			content_rect.size.x, float(band.bottom) - float(band.top))
	return {
		"ok": found,
		"nodes": nodes,
		"edges": edges,
		"portals": portals,
		"bands": bands,
		"lanes": lane_meta,
		"parents": parents,
		"children": children,
		"content_rect": content_rect,
		"domain_id": domain_id,
		"focus_era": clamped_era,
		"fits_canvas": true,
		"canvas_size": Vector2(canvas_w, canvas_size.y),
	}


static func _lane_metrics(canvas_size: Vector2, domain_count: int) -> Dictionary:
	var count := maxi(1, domain_count)
	var canvas_w := canvas_size.x if canvas_size.x >= 200.0 else 720.0
	var inner := maxf(80.0, canvas_w - LANE_INSET * 2.0)
	if inner > canvas_w:
		inner = canvas_w
	var gap := LANE_GAP if count > 1 else 0.0
	var lane_w := maxf(8.0, (inner - gap * float(count - 1)) / float(count))
	var node_w := clampf(lane_w - 16.0, MIN_NODE_WIDTH, MAX_NODE_WIDTH)
	if node_w > lane_w - 6.0:
		node_w = maxf(24.0, lane_w - 6.0)
	return {
		"canvas_w": canvas_w,
		"inner": inner,
		"lane_w": lane_w,
		"node_w": node_w,
		"left": -inner * 0.5,
		"gap": gap,
	}


static func _lane_node_x(metrics: Dictionary, domain: int) -> float:
	return float(metrics.left) + float(domain) * (float(metrics.lane_w) + float(metrics.gap)) \
		+ (float(metrics.lane_w) - float(metrics.node_w)) * 0.5


static func _focus_domain_ids(domains: Array) -> PackedStringArray:
	var ids := PackedStringArray()
	for domain in domains:
		ids.append(String((domain as Dictionary).get("id", "")))
	if ids.is_empty():
		for domain_id in FALLBACK_DOMAIN_IDS:
			ids.append(String(domain_id))
	return ids


static func _focus_domain_names(domains: Array) -> PackedStringArray:
	var names := PackedStringArray()
	for domain in domains:
		var data: Dictionary = domain
		names.append(String(data.get("display_name", data.get("id", ""))))
	if names.is_empty():
		for domain_id in FALLBACK_DOMAIN_IDS:
			names.append(String(domain_id))
	return names


static func _is_visible_index(index: int, visible_nodes: PackedByteArray) -> bool:
	return visible_nodes.is_empty() \
		or (index >= 0 and index < visible_nodes.size() and visible_nodes[index] != 0)


static func _era_outside_window(definition: Dictionary, era_by_id: Dictionary,
		first_era: int, last_era: int) -> bool:
	var era_index := int(era_by_id.get(String(definition.get("era_id", "")), -1))
	return era_index < first_era or era_index > last_era


static func _era_milestone_index(era: Dictionary, index_by_id: Dictionary) -> int:
	return int(index_by_id.get(String(era.get("milestone_id", "")), -1))


static func _ordered_focus_row(row: PackedInt32Array, definitions: Array) -> Array:
	var ordered: Array = []
	for node in row:
		ordered.append(int(node))
	ordered.sort_custom(func(a: int, b: int) -> bool:
		var left: Dictionary = definitions[a]
		var right: Dictionary = definitions[b]
		var lane_a := String(left.get("branch_family_id", left.get("layout_lane", "")))
		var lane_b := String(right.get("branch_family_id", right.get("layout_lane", "")))
		if lane_a != lane_b:
			return lane_a < lane_b
		return a < b
	)
	return ordered


static func _place_focus_node(technology: int, x: float, y: float, size: Vector2,
		definition: Dictionary, domains: Array, era_index: int, clamped_era: int,
		depth: int, layer: int, is_milestone: bool) -> Dictionary:
	return {
		"index": technology,
		"rect": Rect2(Vector2(x, y), size),
		"domain": _domain_index(definition, domains),
		"lane_id": String(definition.get("branch_family_id", definition.get("layout_lane", ""))),
		"era_index": era_index,
		"depth": depth,
		"layer": layer,
		"is_focus_era": era_index == clamped_era,
		"is_milestone": is_milestone,
	}


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
			"milestone_id": String(data.get("milestone_id", "")),
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
		parents: Array, definitions: Array) -> Array[PackedInt32Array]:
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
