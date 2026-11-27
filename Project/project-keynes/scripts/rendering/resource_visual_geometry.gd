extends RefCounted

## Resource placement, resumable chunk construction and GPU publication.
const FogDrawBounds = preload("res://scripts/rendering/fog_draw_bounds.gd")
const NativeSlice = preload("res://scripts/rendering/resource_visual_native_slice.gd")
const Plan = preload("res://scripts/rendering/resource_instance_plan.gd")
const INSTANCE_SCALE_MIN := 0.82
const INSTANCE_SCALE_MAX := 1.22
const INSTANCE_ASPECT_MIN := 0.78
const INSTANCE_ASPECT_MAX := 1.28
const DECAL_BATCH := 4
const KIND_PROP := 1.0
const KIND_DECAL := 2.0
const KIND_SUBMERGED := 3.0
const KIND_BADGE_ONLY := 4.0
const NON_CARRIER := 0.5

## Immutable catalog data only. Profile scalars and overrides are refreshed for
## every synchronous slice, including direct Resource edits between frames.
class StyleInputs:
	extends RefCounted
	var families := PackedInt32Array()
	var forms := PackedInt32Array()
	var land_plans := PackedInt32Array()
	var water_plans := PackedInt32Array()
	var priorities := PackedFloat64Array()
	var unit_scales := PackedFloat64Array()
	var indices: Dictionary = {}

	func _init(styles: Array[Dictionary]) -> void:
		for index in styles.size():
			var entry: Dictionary = styles[index]
			families.append(int(entry.family))
			forms.append(int(entry.form))
			land_plans.append(Plan.visual_plan(entry, false))
			water_plans.append(Plan.visual_plan(entry, true))
			priorities.append(float(entry.priority))
			unit_scales.append(1.0)
			indices[entry.id] = index

## Lifetime is one synchronous construction slice. Never store this on the job:
## keeping world-sized PackedArrays across frames would force observation COW.
class Context:
	extends RefCounted
	var map: MapData
	var world: WorldData
	var profile: ResourceVisualProfile
	var inputs: StyleInputs
	var priorities: PackedFloat64Array
	var size_scales: PackedFloat64Array
	var cell_cap: int
	var type_cap: int
	var filter_direct: int
	var filter_prefixed: int
	var animal_presence: float
	var mineral_presence: float
	var mineral_min_band: int
	var plant_diameter: float
	var patch_diameter: float
	var fertility_diameter: float
	var decal_diameter: float
	var cluster_spread: float
	var patch_noise_strength: float
	var density_scale: float
	var shoal_density: float
	var allowed: PackedByteArray
	var cores: PackedByteArray
	var rows: Dictionary
	var seed: int
	var hex: float
	var quality: int
	var filter_id: String
	var lens: bool
	var herd_radius: float
	var native: RefCounted

	func _init(host, use_native: bool = true) -> void:
		map = host._map
		world = host._world
		profile = host.profile
		inputs = host._geometry_styles
		allowed = host._allowed
		cores = host._intel.settlement_core_buckets()
		rows = host._intel.resource_observations.rows
		seed = host._layout_seed
		hex = host._hex
		quality = host.density_quality()
		filter_id = host._filter
		lens = host.lens_enabled()
		herd_radius = host.herd_radius_hex()
		cell_cap = profile.cell_cap(quality)
		type_cap = profile.type_cap(quality)
		animal_presence = float(profile.animal_presence)
		mineral_presence = float(profile.mineral_presence)
		mineral_min_band = int(profile.mineral_min_abundance_band)
		plant_diameter = float(profile.plant_diameter_hex)
		patch_diameter = float(profile.patch_diameter_hex)
		fertility_diameter = float(profile.fertility_diameter_hex)
		decal_diameter = float(profile.decal_diameter_hex)
		cluster_spread = float(profile.cluster_spread)
		patch_noise_strength = float(profile.patch_noise_strength)
		density_scale = float(profile.density_scale)
		shoal_density = float(profile.shoal_density)
		priorities = inputs.priorities
		size_scales = inputs.unit_scales
		# Packed arrays remain shared and read-only in the empty-override case.
		# GDScript assignment aliases a PackedArray; copy before applying edits.
		if not profile.style_overrides.is_empty():
			priorities = priorities.duplicate()
			size_scales = size_scales.duplicate()
		# A direct nested override edit is read on the very next slice.
		for id in profile.style_overrides:
			var index := int(inputs.indices.get(id, -1))
			if index < 0:
				continue
			var override: Dictionary = profile.style_overrides[id]
			priorities[index] = float(override.get("priority", inputs.priorities[index]))
			size_scales[index] = float(override.get("size_scale", 1.0))
		filter_direct = int(inputs.indices.get(filter_id, -1))
		filter_prefixed = int(inputs.indices.get(filter_id.trim_prefix("resource."), -1)) if filter_id.begins_with("resource.") else -1
		if use_native:
			native = NativeSlice.create(self)

## Only one cell's small observed band row and placement progress cross frames.
class CellWork:
	extends RefCounted
	var cell: int
	var selected: PackedInt32Array
	var bands: PackedByteArray
	var core: int
	var center: Vector2
	var source_water: bool
	var rank := 0
	var occupied: Array[Vector3] = []

static func _build_until(host, deadline: int) -> void:
	if not host._detail_visible() or not host._uploads.is_empty():
		return
	if host._job.is_empty():
		var key = _next_dirty_chunk(host)
		if key != null:
			host._job = {"key": key, "cursor": 0, "buffers": [[], [], [], [], []], "packed": [],
				"revision": host._revision, "chunk_revision": int(host._chunk_revisions.get(key, 0))}
			host._dirty.erase(key)
			host._build_round[key] = true
	if host._job.is_empty() or Time.get_ticks_usec() >= deadline:
		return
	var context := Context.new(host)
	var job: Dictionary = host._job
	var cells: Array = host._chunks[job.key]
	var start_cursor := int(job.cursor)
	var steps := 0
	var packed := 0
	if not job.has("packed"):
		job.packed = []
	while Time.get_ticks_usec() < deadline:
		if int(job.cursor) < cells.size():
			_build_step(context, job, cells)
			steps += 1
		elif job.packed.size() < 5:
			# Packing a complete chunk used to run all five conversions after the
			# deadline. Each family now keeps its progress like a cell/style step.
			var family: int = job.packed.size()
			job.packed.append({"key": job.key, "family": family,
				"buffer": PackedFloat32Array(job.buffers[family]), "revision": job.revision,
				"chunk_revision": job.chunk_revision})
			packed += 1
		else:
			break
	host._stats.built_cells = int(host._stats.built_cells) + int(job.cursor) - start_cursor
	host._stats.last_built_cells = int(job.cursor) - start_cursor
	host._stats.last_build_steps = steps
	host._stats.last_packed_batches = packed
	if job.packed.size() == 5:
		host._uploads.append_array(job.packed)
		host._job.clear()
		host._stats.rebuilt_chunks = int(host._stats.rebuilt_chunks) + 1

static func _next_dirty_chunk(host):
	# Retain camera-distance order (also the order used by the global cap).
	# A chunk already started this round waits until the other dirty chunks
	# get their turn. Continued changes therefore cannot monopolize the queue.
	for key in host._active:
		if host._dirty.has(key) and not host._build_round.has(key):
			# Preserve the current camera/cap order. Only this chunk's first
			# visible inputs may delay it, never the complete world sweep.
			return key if host._chunk_inputs.ready(key) else null
	host._build_round.clear()
	for key in host._active:
		if host._dirty.has(key):
			return key if host._chunk_inputs.ready(key) else null
	return null

## One selected style at a time, retaining a cell's spacing and candidate order.
## The same primitive is used by the deterministic progress fixture.
static func _build_step(context: Context, job: Dictionary, cells: Array) -> void:
	var work: CellWork = job.get("cell_work")
	if work == null:
		work = _new_cell(context, int(cells[int(job.cursor)]))
		job.cell_work = work
	if work.rank < work.selected.size() and work.occupied.size() < context.cell_cap:
		_append_style(context, work, job.buffers)
		work.rank += 1
	if work.rank >= work.selected.size() or work.occupied.size() >= context.cell_cap:
		job.erase("cell_work")
		job.cursor = int(job.cursor) + 1

static func selected_styles(host, cell: int) -> PackedInt32Array:
	return _selected_styles(Context.new(host), cell)

static func world_presence_allowed(host, cell: int, style: int, band: int) -> bool:
	var profile: ResourceVisualProfile = host.profile
	var styles: Array[Dictionary] = host._styles
	return _presence(profile, styles, int(host._layout_seed), cell, style, band)

static func _append_cell(host, cell: int, buffers: Array) -> void:
	var context := Context.new(host)
	var work := _new_cell(context, cell)
	while work.rank < work.selected.size() and work.occupied.size() < context.cell_cap:
		_append_style(context, work, buffers)
		work.rank += 1

static func _instance_scale(_host, cell: int, style: int, family: int) -> Vector2:
	return _scale(cell, style, family)

static func _water_transmission(host, cell: int) -> float:
	return _transmission(Context.new(host), cell)

static func candidate_allowed(host, point: Vector2, family: int, source_domain: int = -1) -> bool:
	return _candidate_allowed(Context.new(host), point, family, source_domain)

static func _patch_noise(host, point: Vector2) -> float:
	return _noise(Context.new(host), point)

static func _selected_styles(context: Context, cell: int) -> PackedInt32Array:
	var row: Dictionary = context.rows.get(cell, {})
	var bands: PackedByteArray = row.get("bands", PackedByteArray())
	var source_water := cell < context.map.is_water_arr.size() and context.map.is_water_arr[cell] != 0
	if context.native != null:
		var selection: Variant = context.native.call("select_cell", cell, bands, source_water)
		if selection is PackedInt32Array:
			return selection
	var inputs := context.inputs
	var plans := inputs.water_plans if source_water else inputs.land_plans
	var families := inputs.families
	var forms := inputs.forms
	var allowed := context.allowed
	var priorities := context.priorities
	var seed := context.seed
	var lens := context.lens
	var candidate_styles := PackedInt32Array()
	var scores := PackedFloat64Array()
	var style_for_score: Dictionary = {}
	var needs_original_sort := false
	for i in mini(bands.size(), families.size()):
		if bands[i] == 0 or i >= allowed.size() or allowed[i] == 0 or plans[i] == 0:
			continue
		var family := families[i]
		if not lens and family != 0 and family != 3 and forms[i] != 22:
			if family == 2 and bands[i] < context.mineral_min_band:
				continue
			var probability := context.animal_presence if family == 1 else context.mineral_presence
			if not (Plan._hash(cell, i * 211 + seed + 4217) < probability):
				continue
		var score := priorities[i] + float(bands[i]) * 0.18 + Plan._hash(cell, i) * 0.08
		if i == context.filter_direct or i == context.filter_prefixed:
			score += 100.0
		candidate_styles.append(i)
		scores.append(score)
		if not is_finite(score) or style_for_score.has(score):
			needs_original_sort = true
		else:
			style_for_score[score] = i
	if needs_original_sort:
		return _select_with_original_sort(candidate_styles, scores, families, context.type_cap)
	# Every key is unique and finite, so numeric sorting has the exact same
	# descending order as the original callback. No tie-breaking rule is added.
	scores.sort()
	var result := PackedInt32Array()
	var selected_families := 0
	for offset in scores.size():
		if result.size() >= context.type_cap:
			break
		var style := int(style_for_score[scores[scores.size() - 1 - offset]])
		var bit := 1 << families[style]
		if (selected_families & bit) != 0:
			continue
		result.append(style)
		selected_families |= bit
	for offset in scores.size():
		if result.size() >= context.type_cap:
			break
		var style := int(style_for_score[scores[scores.size() - 1 - offset]])
		if not result.has(style):
			result.append(style)
	return result

## Ties and non-finite overrides retain the original comparator and input order.
static func _select_with_original_sort(styles: PackedInt32Array, scores: PackedFloat64Array,
		families: PackedInt32Array, limit: int) -> PackedInt32Array:
	var candidates: Array[Dictionary] = []
	for index in styles.size():
		var style := styles[index]
		candidates.append({"style": style, "family": families[style], "score": scores[index]})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.score) > float(b.score))
	var result := PackedInt32Array()
	var selected_families := {}
	for candidate in candidates:
		if result.size() >= limit:
			break
		if selected_families.has(candidate.family):
			continue
		result.append(int(candidate.style))
		selected_families[candidate.family] = true
	for candidate in candidates:
		if result.size() >= limit:
			break
		if not result.has(int(candidate.style)):
			result.append(int(candidate.style))
	return result

static func _presence(profile: ResourceVisualProfile, styles: Array[Dictionary], seed: int, cell: int, style: int, band: int) -> bool:
	if band <= 0:
		return false
	var e: Dictionary = styles[style]
	if int(e.family) == 0 or int(e.family) == 3 or int(e.form) == 22:
		return true
	var probability := float(profile.animal_presence) if int(e.family) == 1 else float(profile.mineral_presence)
	if int(e.family) == 2 and band < int(profile.mineral_min_abundance_band):
		return false
	return Plan._hash(cell, style * 211 + seed + 4217) < probability

static func _new_cell(context: Context, cell: int) -> CellWork:
	var work := CellWork.new()
	work.cell = cell
	work.selected = _selected_styles(context, cell)
	var row: Dictionary = context.rows.get(cell, {})
	work.bands = row.get("bands", PackedByteArray())
	work.core = int(context.cores[cell])
	work.center = Vector2(context.map.cell_pos_x_arr[cell], context.map.cell_pos_y_arr[cell]) * context.hex
	work.source_water = cell < context.map.is_water_arr.size() and context.map.is_water_arr[cell] != 0
	return work

static func _append_style(context: Context, work: CellWork, buffers: Array) -> void:
	if context.native != null and bool(context.native.call("append_style", work.cell, work.bands,
			work.selected[work.rank], work.rank, work.core, work.center, work.source_water, work.occupied, buffers)):
		return
	_append_style_script(context, work, buffers)

## Complete reference path: unsupported platforms and explicit equivalence tests.
static func _append_style_script(context: Context, work: CellWork, buffers: Array) -> void:
	var cell := work.cell
	var rank := work.rank
	var style := work.selected[rank]
	var inputs := context.inputs
	var form := inputs.forms[style]
	var plan := inputs.water_plans[style] if work.source_water else inputs.land_plans[style]
	if plan == 0:
		return
	var render_family := inputs.families[style]
	var size_scale := context.size_scales[style]
	var prop_diameter := context.plant_diameter if render_family == 0 and form != 26 else context.patch_diameter
	var ground_diameter := context.fertility_diameter if form == 22 else context.decal_diameter
	var variation := Plan._hash(cell, style)
	var instance_scale := _scale(cell, style, render_family)
	var prop_radius := Vector2.ONE * context.hex * prop_diameter * 0.5 * size_scale * instance_scale
	if render_family == 1:
		# Real-scale herd: the quad only has to contain herd_size_max animals.
		prop_radius = Vector2.ONE * context.hex * context.herd_radius * size_scale * instance_scale
	var decal_radius := Vector2.ONE * context.hex * ground_diameter * 0.5 * size_scale * instance_scale
	var submerged := (plan & Plan.PLAN_SUBMERGED) != 0
	var has_prop := (plan & (Plan.PLAN_PROP | Plan.PLAN_BADGE)) != 0
	var prop_foot := maxf(prop_radius.x, prop_radius.y)
	var decal_foot := maxf(decal_radius.x, decal_radius.y)
	var foot := prop_foot if has_prop else decal_foot * 0.55
	var domain_family := 3 if submerged else render_family
	var accepted := false
	var point := work.center
	var point_noise := 0.0
	var hex := context.hex
	var seed := context.seed
	var noise_strength := context.patch_noise_strength
	for attempt in 8:
		var seed_value := style * 211 + attempt * 17 + seed
		var angle := Plan._hash(cell, seed_value) * TAU
		var radial := sqrt(Plan._hash(cell, seed_value + 1)) * hex * (0.40 + context.cluster_spread * 0.45)
		point = work.center + Vector2.from_angle(angle) * radial
		if work.core > 0 and point.distance_to(work.center) < hex * (0.32 + minf(work.core / 15.0, 1.0) * 0.25) + foot:
			continue
		var collides := false
		for other in work.occupied:
			if Vector2(other.x, other.y).distance_to(point) < (foot + other.z) * 0.82:
				collides = true
				break
		if collides or not _candidate_allowed(context, point, domain_family, 1 if work.source_water else 0):
			continue
		point_noise = _noise(context, point)
		var patch := 1.0 - noise_strength + noise_strength * point_noise
		if Plan._hash(cell, seed_value + 5) > minf(1.0, context.density_scale * patch):
			continue
		accepted = true
		break
	if not accepted:
		return
	work.occupied.append(Vector3(point.x, point.y, foot))
	var importance := (3.0 - float(rank)) * 2.0 + float(work.bands[style]) * 0.2 + point_noise
	if submerged:
		# Fish are everywhere at sea; only a few cells show a shoal.
		if render_family == 3 and Plan._hash(cell, style + 577) > context.shoal_density:
			return
		var transmission := _transmission(context, cell)
		if transmission < 0.06:
			return
		_emit(null, buffers[3], point, decal_radius, rank, cell, style, variation, work.bands[style], importance, KIND_SUBMERGED, transmission)
		return
	if (plan & Plan.PLAN_DECAL) != 0:
		var kind := KIND_DECAL + (NON_CARRIER if has_prop else 0.0)
		_emit(null, buffers[DECAL_BATCH], point, decal_radius, rank, cell, style, variation, work.bands[style], importance, kind)
	if (plan & Plan.PLAN_PROP) != 0:
		# Pebbles sit slightly off-centre on their own scar, never dead centre.
		var offset := Vector2.from_angle(Plan._hash(cell, style + 913) * TAU) * decal_foot * 0.12
		_emit(null, buffers[render_family], point + offset, prop_radius, rank, cell, style, variation, work.bands[style], importance + 0.5, KIND_PROP)
	elif (plan & Plan.PLAN_BADGE) != 0:
		_emit(null, buffers[render_family], point, prop_radius, rank, cell, style, variation, work.bands[style], importance, KIND_BADGE_ONLY)


static func _emit(_host, buffer: Array, point: Vector2, radius: Vector2, rank: int, cell: int, style: int,
		variation: float, band: int, importance: float, kind: float, transmission: float = 1.0) -> void:
	buffer.append_array([radius.x, 0.0, 0.0, point.x, 0.0, radius.y, 0.0, point.y,
		float(rank), transmission, importance, kind,
		float(cell), float(style), variation, float(band)])

static func _scale(cell: int, style: int, family: int) -> Vector2:
	var size_scale := lerpf(INSTANCE_SCALE_MIN, INSTANCE_SCALE_MAX,
		Plan._hash(cell, style * 457 + 1223))
	if family == 1:
		return Vector2.ONE * size_scale
	var aspect := lerpf(INSTANCE_ASPECT_MIN, INSTANCE_ASPECT_MAX,
		Plan._hash(cell, style * 719 + 1571))
	var axis := sqrt(aspect)
	return Vector2(size_scale * axis, size_scale / axis)

static func _transmission(context: Context, cell: int) -> float:
	if context.map == null or cell >= context.map.elevation_arr.size() or context.map.is_water_arr[cell] == 0:
		return 1.0
	var sea := clampf(context.world.sea_level if context.world != null else 0.42, 0.01, 1.0)
	var depth := clampf((sea - context.map.elevation_arr[cell]) / sea, 0.0, 1.0)
	return exp(-depth * float(context.profile.water_depth_falloff))

static func _candidate_allowed(context: Context, point: Vector2, family: int, source_domain: int = -1) -> bool:
	var flow := context.world.sample_flow(point) if context.world != null else 0.0
	var water := source_domain == 1
	if context.world != null and not context.world.biome_buffer.is_empty():
		var terrain := context.world.sample_biome(point)
		water = terrain in [TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.COAST,
			TerrainType.TERRAIN.LAKE, TerrainType.TERRAIN.SEA_ICE]
	elif context.world != null and (not context.world.pixel_owner_indices.is_empty() \
			or not context.world.pixel_to_cell_lookup.is_empty()):
		# Active tiled rendering can retire biome_buffer. Its static pixel→cell
		# lookup (or compact numeric owner snapshot) is still authoritative;
		# an empty old atlas never means all land.
		var uv := context.world._world_to_uv(point)
		var x := clampi(roundi(uv.x * float(context.world.derived_size.x - 1)), 0, context.world.derived_size.x - 1)
		var y := clampi(roundi(uv.y * float(context.world.derived_size.y - 1)), 0, context.world.derived_size.y - 1)
		var index := y * context.world.derived_size.x + x
		var owner_index := -1
		if not context.world.pixel_owner_indices.is_empty():
			if index < 0 or index >= context.world.pixel_owner_indices.size():
				return false
			if index < context.world.pixel_owner_present.size() \
					and context.world.pixel_owner_present[index] == 0:
				return false
			owner_index = int(context.world.pixel_owner_indices[index])
		else:
			if index < 0 or index >= context.world.pixel_to_cell_lookup.size():
				return false
			var owner_cell: HexCell = context.world.pixel_to_cell_lookup[index]
			if owner_cell == null:
				return false
			owner_index = int(owner_cell.index)
		water = owner_index >= 0 and owner_index < context.map.is_water_arr.size() and context.map.is_water_arr[owner_index] != 0
	if family == 3:
		return water or flow > 0.78
	return not water and flow < float(context.profile.river_clear_threshold)

static func _noise(context: Context, point: Vector2) -> float:
	var p := point / (context.hex * 5.0)
	var x := floori(p.x)
	var y := floori(p.y)
	var f := Vector2(p.x - float(x), p.y - float(y))
	f = f * f * (Vector2(3.0, 3.0) - f * 2.0)
	return lerpf(lerpf(Plan._hash(x, y + context.seed), Plan._hash(x + 1, y + context.seed), f.x),
		lerpf(Plan._hash(x, y + 1 + context.seed), Plan._hash(x + 1, y + 1 + context.seed), f.x), f.y)

static func _drain_one_upload(host) -> bool:
	# One grant, three FIFO lanes. Continuously due cover or memory must not
	# prevent completed geometry from reaching the display (and vice versa).
	var turn := int(host._upload_turn)
	for offset in 3:
		var lane := (turn + offset) % 3
		if lane == 0:
			if host._cover != null and host._cover.flush():
				host._upload_turn = 1
				return true
		elif lane == 1:
			if host._memory_dirty and Time.get_ticks_msec() - host._last_texture_msec >= 100:
				host._memory_texture.update(host._memory_image)
				host._memory_dirty = false
				host._last_texture_msec = Time.get_ticks_msec()
				host._upload_turn = 2
				return true
		elif not host._uploads.is_empty() and host._detail_visible():
			var task: Dictionary = host._uploads.pop_front()
			host._upload_turn = 0
			return _install_upload(host, task)
	return false

static func _install_upload(host, task: Dictionary) -> bool:
	if int(task.revision) != host._revision or not host._active.has(task.key) \
			or int(task.get("chunk_revision", 0)) < int(host._published_chunk_revisions.get(task.key, -1)):
		return false
	var key: Vector2i = task.key
	# Advance on the FIRST family, even an empty one. Equal-version sibling
	# batches are accepted, but no older family can overwrite this generation.
	host._published_chunk_revisions[key] = int(task.get("chunk_revision", 0))
	var family = int(task.family)
	if not host._resident.has(key):
		host._resident[key] = {}
	var family_nodes: Dictionary = host._resident[key]
	var previous = 0
	if family_nodes.has(family):
		previous = family_nodes[family].multimesh.instance_count
	var buffer: PackedFloat32Array = task.buffer
	var remaining: int = host.profile.instance_cap(host.density_quality(), host._mobile_tier >= 0) - host._instance_count + previous
	var count = mini(buffer.size() / host.STRIDE, maxi(0, remaining))
	if count > 0 and count < buffer.size() / host.STRIDE:
		buffer = host._keep_important_instances(buffer, count)
	else:
		buffer.resize(count * host.STRIDE)
	if count == 0:
		if family_nodes.has(family):
			host._remove_node(family_nodes[family])
			family_nodes.erase(family)
		host._instance_count -= previous
		return true
	var node: MultiMeshInstance2D
	if family_nodes.has(family):
		node = family_nodes[family]
	else:
		node = MultiMeshInstance2D.new()
		node.name = "Resource_%d_%d_%d" % [key.x, key.y, family]
		node.z_index = host.RESOURCE_Z
		node.material = host._material_for(family)
		var mm = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = host._mesh
		node.multimesh = mm
		host.add_child(node)
		if family == host.DECAL_BATCH:
			host.move_child(node, 0)
		family_nodes[family] = node
		var copies: Array[MultiMeshInstance2D] = []
		if host._world != null and host._world.wrap_period_x > 0.0:
			for side in [-1, 1]:
				var copy = MultiMeshInstance2D.new()
				copy.z_index = host.RESOURCE_Z
				copy.material = host._material_for(family)
				copy.multimesh = mm
				copy.position.x = float(side) * host._world.wrap_period_x
				host.add_child(copy)
				if family == host.DECAL_BATCH:
					host.move_child(copy, 0)
				copies.append(copy)
		node.set_meta("wraps", copies)
	node.multimesh.instance_count = count
	FogDrawBounds.upload(node.multimesh, buffer, FogDrawBounds.Kind.RESOURCE)
	host._instance_count += count - previous
	host._sync_wrap_visibility(key)
	host._stats.uploads = int(host._stats.uploads) + 1
	return true

static func _sync_wrap_visibility(host, key: Vector2i) -> void:
	var size = Vector2(host._hex * 16.0 * sqrt(3.0), host._hex * 24.0)
	var bounds = Rect2(Vector2(key) * size, size).grow(host._hex)
	for node in host._resident[key].values():
		node.visible = host._detail_visible() and host._camera.intersects(bounds)
		for copy in node.get_meta("wraps", []):
			copy.visible = host._detail_visible() and host._camera.intersects(Rect2(bounds.position + copy.position, bounds.size))

static func _detail_visible(host) -> bool:
	if not host.profile.enabled:
		return false
	if host._lens_amount > 0.001:
		return true
	var diameter = maxf(maxf(float(host.profile.patch_diameter_hex), float(host.profile.decal_diameter_hex)),
		maxf(float(host.profile.plant_diameter_hex), float(host.profile.fertility_diameter_hex)))
	return host._hex * diameter * 0.5 * host._max_style_scale * host._zoom > float(host.profile.fade_pixels)

static func _remove_node(host, node: MultiMeshInstance2D) -> void:
	for copy in node.get_meta("wraps", []):
		copy.visible = false
		copy.queue_free()
	node.visible = false
	node.queue_free()

static func _evict(host, key: Vector2i) -> void:
	for node in host._resident[key].values():
		host._instance_count -= node.multimesh.instance_count
		host._remove_node(node)
	host._resident.erase(key)

static func _clear_geometry(host) -> void:
	for key in host._resident.keys():
		host._evict(key)
	host._job.clear()
	host._uploads.clear()
	host._dirty.clear()
	host._build_round.clear()
	host._chunk_revisions.clear()
	host._published_chunk_revisions.clear()
	host._instance_count = 0
	host._revision += 1
