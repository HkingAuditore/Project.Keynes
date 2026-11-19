extends SceneTree

const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Queue = preload("res://scripts/rendering/resource_visual_work_queue.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Geometry = preload("res://scripts/rendering/resource_visual_geometry.gd")
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	_test_queue()
	_test_chunk_round()
	_test_native_publication()
	var map := Fixtures.make_map(16, 12)
	for cell in map.cell_count():
		map.bio_occupancy_bits_arr[cell] = (1 << 20) - 1
		map.res_iron_ore_reserve_arr[cell] = 1000000.0
		map.res_coal_reserve_arr[cell] = 1000000.0
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var world := WorldData.new()
	world.lut_dims = Vector2i(map.cell_count(), 1)
	world.world_bounds = Rect2(-40, -40, 700, 450)
	var layer := Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	layer.configure(map, world, 22.0, intel)
	layer.set_context(true, 20261016)
	layer.set_quality(2)
	layer.set_camera_view(world.world_bounds, world.world_bounds.get_center(), 2.0)
	await _settle(layer)
	_expect("initial scan observes every visible cell", intel.resource_observations.rows.size() == map.cell_count())
	_expect("all generated instance fields match complete rebuild", _geometry_matches(layer))
	_test_live_profile_inputs(layer)
	_test_frame_bindings(layer)
	_test_selection_reference(layer)
	_test_upload_budget(layer)
	_test_inflight_progress(layer)
	await _settle(layer)
	_expect("coalesced redo converges to all instance fields", _geometry_matches(layer))
	var observed := int(layer.diagnostics().observed_cells)
	var uploads := int(layer.diagnostics().uploads)
	var rebuilt := int(layer.diagnostics().rebuilt_chunks)
	for frame in 25:
		layer.prepare_frame(0.0, Vector3.UP, {})
		layer.drain_one_upload()
		await process_frame
	_expect("idle stops observation and geometry work", observed == int(layer.diagnostics().observed_cells) and uploads == int(layer.diagnostics().uploads) and rebuilt == int(layer.diagnostics().rebuilt_chunks))
	var old_bands: PackedByteArray = intel.resource_observations.rows[3].bands.duplicate()
	map.temp_arr[3] = 0.2
	map.publish_resource_visual_inputs(MapData.RESOURCE_VISUAL_CLIMATE, PackedInt32Array([3]))
	await _settle(layer)
	_expect("climate publication updates memory without sampling abundance", int(layer.diagnostics().observed_cells) == observed and intel.resource_observations.rows[3].bands == old_bands and is_equal_approx(intel.resource_observations.rows[3].climate.r, 0.2))
	_expect("climate publication keeps complete instance buffers", _geometry_matches(layer) and rebuilt == int(layer.diagnostics().rebuilt_chunks))
	map.bio_occupancy_bits_arr[4] = 0
	map.res_iron_ore_reserve_arr[4] = 0.0
	map.res_coal_reserve_arr[4] = 0.0
	map.publish_resource_visual_inputs(MapData.RESOURCE_VISUAL_BANDS, PackedInt32Array([4, 4]))
	await _settle(layer)
	_expect("one dirty cell is observed exactly once", int(layer.diagnostics().observed_cells) == observed + 1)
	_expect("targeted resource update converges to complete instance buffers", _geometry_matches(layer))
	# Freeze old geometry between construction and its five uploads, then publish
	# a new observation. No old batch may overwrite the replacement afterward.
	# Copy buffers already validated above, so staging does not depend on how
	# much CPU time one construction slice receives under concurrent load.
	var old_batches: Array[Dictionary] = _snapshot_uploads(layer, 4)
	layer._uploads.assign(old_batches)
	_expect("interrupted upload fixture has pending batches", layer._uploads.size() == Layer.BATCH_COUNT)
	map.bio_occupancy_bits_arr[4] = (1 << 20) - 1
	map.publish_resource_visual_inputs(MapData.RESOURCE_VISUAL_BANDS, PackedInt32Array([4]))
	await _settle(layer)
	_expect("new observation supersedes every pending old batch", _geometry_matches(layer))
	_test_interleaved_uploads(layer, old_batches)
	# Also model an old completed payload arriving after its replacement.
	# The upload boundary must reject its old revision without overwriting it.
	layer._uploads.assign(old_batches)
	await _settle(layer)
	_expect("late stale payloads cannot overwrite current instance buffers", _geometry_matches(layer))
	var remembered: Dictionary = intel.resource_observations.rows[5].duplicate(true)
	map.visible_arr[5] = 0
	map.bio_occupancy_bits_arr[5] = 0
	map.res_iron_ore_reserve_arr[5] = 0.0
	map.temp_arr[5] = 0.1
	map.publish_resource_visual_inputs(Queue.ALL, PackedInt32Array([5]))
	await _settle(layer)
	_expect("hidden resource and climate changes keep last seen memory", intel.resource_observations.rows[5] == remembered)
	map.visible_arr[5] = 1
	map.publish_resource_visual_inputs(Queue.ALL, PackedInt32Array([5]))
	await _settle(layer)
	_expect("reveal applies resource and climate changes", intel.resource_observations.rows[5] != remembered and is_equal_approx(intel.resource_observations.rows[5].climate.r, 0.1))
	_expect("reveal converges to complete instance buffers", _geometry_matches(layer))
	var saved := {"version": 4}
	saved.merge(intel.to_pkfg_fields())
	map.visible_arr.fill(0)
	map.bio_occupancy_bits_arr.fill(0)
	map.temp_arr.fill(0.9)
	_expect("resource memory restores", bool(intel.restore_pkfg(saved).ok))
	await _settle(layer)
	_expect("restore keeps remembered hidden climate", is_equal_approx(intel.resource_observations.rows[5].climate.r, 0.1))
	_expect("restore reconstructs every instance field from memory", _geometry_matches(layer))
	var pixels := layer._memory_image.get_data()
	var cover_pixels := layer.ground_cover()._image.get_data()
	layer._queue_cover_rewrite()
	await _settle(layer)
	_expect("memory and ground cover reconstruction are identical", pixels == layer._memory_image.get_data() and cover_pixels == layer.ground_cover()._image.get_data())
	var invalid: Dictionary = layer.configure(map, world, 22.0, null)
	_expect("failed reconfiguration releases publication listener", not bool(invalid.ok) and not map.resource_visual_inputs_changed.is_connected(layer.notify_resource_inputs))
	print("resource visual updates: %d checks, %d failures" % [checks, failures])
	layer.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _settle(layer) -> void:
	# This is a finite test bound, not a production fallback or a relaxed budget.
	for frame in 1000:
		layer.prepare_frame(0.0, Vector3.UP, {})
		layer.drain_one_upload()
		var active_dirty := false
		for key in layer._active:
			active_dirty = active_dirty or layer._dirty.has(key)
		if not layer._observation_queue.pending() and layer._job.is_empty() and layer._uploads.is_empty() and not active_dirty and layer._cover_pending.is_empty():
			return
		await process_frame
	_expect("pending work converges", false)

func _test_upload_budget(layer) -> void:
	var cover: ResourceGroundCover = layer.ground_cover()
	var saved := {"cover_dirty": cover._dirty, "cover_time": cover._last_upload_msec,
		"memory_dirty": layer._memory_dirty, "memory_time": layer._last_texture_msec,
		"budget_active": layer._frame_budget_active, "turn": layer._upload_turn}
	cover._dirty = false
	layer._memory_dirty = false
	_expect("an empty upload slot returns its reserved CPU to construction", layer._upload_reserve_usec(2000) == 0)
	cover._dirty = true
	cover._last_upload_msec = 2000
	_expect("cover below its unchanged upload interval reserves no CPU", not cover.can_flush(2000) and layer._upload_reserve_usec(2000) == 0)
	cover._last_upload_msec = 0
	_expect("due cover reserves CPU from the same frame allowance", cover.can_flush(2000) and layer._upload_reserve_usec(2000) == int(layer._frame_budget_usec * 0.20))
	cover._dirty = false
	layer._memory_dirty = true
	layer._last_texture_msec = 1900
	_expect("due climate memory also reserves an upload slot", layer._upload_reserve_usec(2000) == int(layer._frame_budget_usec * 0.20))
	# Every grant sees BOTH textures due. Five real resident geometry payloads
	# remain FIFO while all three lanes receive service without timed waits.
	layer._uploads.assign(_snapshot_uploads(layer, 4))
	layer._frame_budget_active = false
	layer._upload_turn = 0
	var cover_uploads := int(cover.diagnostics().uploads)
	var memory_uploads := 0
	var families: Array[int] = []
	for grant in 9:
		cover._dirty = true
		cover._last_upload_msec = Time.get_ticks_msec() - 1000
		layer._memory_dirty = true
		layer._last_texture_msec = Time.get_ticks_msec() - 1000
		var before: int = layer._uploads.size()
		var family := int(layer._uploads[0].family)
		layer.drain_one_upload()
		if not layer._memory_dirty:
			memory_uploads += 1
		if layer._uploads.size() < before:
			families.append(family)
	_expect("continuously due textures and geometry all receive upload grants", int(cover.diagnostics().uploads) - cover_uploads == 3 and memory_uploads == 3 and families == [0, 1, 2])
	layer._uploads.clear()
	cover._dirty = saved.cover_dirty
	cover._last_upload_msec = saved.cover_time
	layer._memory_dirty = saved.memory_dirty
	layer._last_texture_msec = saved.memory_time
	layer._frame_budget_active = saved.budget_active
	layer._upload_turn = saved.turn

func _test_frame_bindings(layer) -> void:
	var state := {"weather_wind_boost": 0.25}
	layer.prepare_frame(1.0, Vector3.UP, state)
	layer.prepare_frame(2.0, Vector3.UP, state)
	var cover: ShaderMaterial = layer.ground_cover().material()
	_expect("stable lighting keeps the cover clock moving", cover.get_shader_parameter("world_time") == 2.0)
	state.weather_wind_boost = 0.75
	layer.prepare_frame(3.0, Vector3.UP, state)
	for material in [layer._material, layer._material_geo, cover]:
		_expect("changed wind reaches each material", material.get_shader_parameter("weather_wind_boost") == 0.75)


func _test_live_profile_inputs(layer) -> void:
	var original: ResourceVisualProfile = layer.profile
	var original_selection: PackedInt32Array = layer.selected_styles(0)
	layer.profile = original.duplicate(true)
	layer.profile.resource_types_per_cell = PackedInt32Array([1, 1, 1])
	_expect("direct profile type cap applies on the next selection", layer.selected_styles(0).size() == 1)
	layer.profile.resource_types_per_cell = original.resource_types_per_cell
	var style := -1
	for candidate in original_selection:
		if int(layer._styles[candidate].family) == 0:
			style = candidate
	var id := String(layer._styles[style].id)
	layer.profile.style_overrides[id] = {"priority": -10000.0, "size_scale": 1.0}
	var lower: PackedInt32Array = layer.selected_styles(0)
	layer.profile.style_overrides[id]["priority"] = 10000.0
	var higher: PackedInt32Array = layer.selected_styles(0)
	_expect("nested profile priority edits are read without replacing the Resource", not lower.has(style) and higher[0] == style)
	var normal: Array = [[], [], [], [], []]
	layer._append_cell(0, normal)
	layer.profile.style_overrides[id]["size_scale"] = 1.25
	var enlarged: Array = [[], [], [], [], []]
	layer._append_cell(0, enlarged)
	_expect("nested profile size edits affect the next generated buffers", normal != enlarged)
	layer.profile = original
	_expect("temporary overrides cannot mutate compiled catalog values", layer.selected_styles(0) == original_selection)

func _test_selection_reference(layer) -> void:
	var profile: ResourceVisualProfile = layer.profile
	var bands: PackedByteArray = layer._intel.resource_observations.rows[0].bands
	var water := int(layer._map.is_water_arr[0])
	var filter_id: String = layer._filter
	var lens: bool = layer._lens_manual
	layer.profile = profile.duplicate(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261115
	var mismatches := 0
	for sample in 512:
		var row := PackedByteArray()
		for style in layer._styles.size():
			row.append(rng.randi_range(0, 4))
		layer._intel.resource_observations.rows[0].bands = row
		layer._map.is_water_arr[0] = rng.randi_range(0, 1)
		layer._filter = String(layer._styles[rng.randi_range(0, layer._styles.size() - 1)].id) if sample % 3 == 0 else ""
		if sample % 6 == 0:
			layer._filter = "resource." + layer._filter
		layer._lens_manual = sample % 2 == 0
		layer.profile.resource_types_per_cell = PackedInt32Array([1, 2, rng.randi_range(1, 3)])
		layer.profile.animal_presence = rng.randf()
		layer.profile.mineral_presence = rng.randf()
		layer.profile.style_overrides = {}
		for entry in 3:
			var id: String = layer._styles[rng.randi_range(0, layer._styles.size() - 1)].id
			layer.profile.style_overrides[id] = {"priority": rng.randf_range(-5.0, 5.0)}
		if layer.selected_styles(0) != _reference_selection(layer, 0):
			mismatches += 1
	_expect("numeric selection matches original sorting for 512 varied inputs", mismatches == 0)
	var full := PackedByteArray()
	full.resize(layer._styles.size())
	full.fill(4)
	layer._intel.resource_observations.rows[0].bands = full
	layer._map.is_water_arr[0] = 0
	layer._filter = ""
	layer._lens_manual = true
	layer.profile.style_overrides = {}
	var scores := {}
	var ties := 0
	for style in layer._styles.size():
		var priority := 100.0 - 4.0 * 0.18 - Layer._hash(0, style) * 0.08
		layer.profile.style_overrides[layer._styles[style].id] = {"priority": priority}
		var score := priority + 4.0 * 0.18 + Layer._hash(0, style) * 0.08
		if scores.has(score):
			ties += 1
		scores[score] = true
	_expect("exact-score ties retain the original comparator order", ties > 0 and layer.selected_styles(0) == _reference_selection(layer, 0))
	layer.profile.style_overrides[layer._styles[0].id] = {"priority": INF}
	layer.profile.style_overrides[layer._styles[1].id] = {"priority": NAN}
	_expect("non-finite profile overrides retain original selection", layer.selected_styles(0) == _reference_selection(layer, 0))
	layer.profile = profile
	layer._intel.resource_observations.rows[0].bands = bands
	layer._map.is_water_arr[0] = water
	layer._filter = filter_id
	layer._lens_manual = lens

func _reference_selection(host, cell: int) -> PackedInt32Array:
	var row: Dictionary = host._intel.resource_observations.rows.get(cell, {})
	var bands: PackedByteArray = row.get("bands", PackedByteArray())
	var source_water = cell < host._map.is_water_arr.size() and host._map.is_water_arr[cell] != 0
	var candidates: Array[Dictionary] = []
	for i in mini(bands.size(), host._styles.size()):
		if bands[i] == 0 or i >= host._allowed.size() or host._allowed[i] == 0:
			continue
		var e = host._styles[i]
		if host.visual_plan(e, source_water) == 0:
			continue
		if not host.lens_enabled() and not host.world_presence_allowed(cell, i, bands[i]):
			continue
		var override: Dictionary = host.profile.style_overrides.get(e.id, {})
		var score = float(override.get("priority", e.priority)) + float(bands[i]) * 0.18 + host._hash(cell, i) * 0.08
		if String(e.id) == host._filter or "resource." + String(e.id) == host._filter:
			score += 100.0
		candidates.append({"style": i, "family": int(e.family), "score": score})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.score) > float(b.score))
	var result = PackedInt32Array()
	var families = {}
	var limit: int = host.profile.type_cap(host.quality())
	for candidate in candidates:
		if result.size() >= limit:
			break
		if families.has(candidate.family):
			continue
		result.append(int(candidate.style))
		families[candidate.family] = true
	for candidate in candidates:
		if result.size() >= limit:
			break
		if not result.has(int(candidate.style)):
			result.append(int(candidate.style))
	return result

## Advance the production step directly, so no CPU-speed assumption determines
## whether the fixture really has an unfinished chunk when invalidation arrives.
func _test_inflight_progress(layer) -> void:
	var key: Vector2i = layer._active.keys()[0]
	var cells: Array = layer._chunks[key]
	layer._dirty.erase(key)
	layer._job = {"key": key, "cursor": 0, "buffers": [[], [], [], [], []],
		"revision": layer._revision, "chunk_revision": int(layer._chunk_revisions.get(key, 0))}
	var job: Dictionary = layer._job
	var context := Geometry.Context.new(layer)
	var steps := 0
	var retained := true
	while int(job.cursor) < cells.size():
		Geometry._build_step(context, job, cells)
		var cursor := int(job.cursor)
		var work: Geometry.CellWork = job.get("cell_work")
		# Settlement notifications use this same invalidation path even when the
		# visible core bucket is unchanged. Each one must preserve built work.
		layer.notify_cells(PackedInt32Array([int(cells[0])]))
		retained = retained and not layer._job.is_empty() and int(layer._job.get("cursor", -1)) == cursor and layer._job.get("cell_work") == work
		steps += 1
		if not retained:
			break
	_expect("sustained invalidation preserves every chunk build step", retained and int(job.get("cursor", -1)) == cells.size())
	_expect("style continuation completes without repeating a cell prefix", steps <= cells.size() * layer.profile.type_cap(layer.quality()))
	_expect("changes during construction coalesce into one redo", layer._dirty.has(key))
	var expected: Array = [[], [], [], [], []]
	for cell in cells:
		layer._append_cell(int(cell), expected)
	_expect("resumed style construction preserves complete buffer bytes", retained and job.get("buffers", []) == expected)
	# The completed job remains installed. The normal frame path publishes all
	# five batches and then consumes its queued redo in _settle.

func _test_interleaved_uploads(layer, old_batches: Array[Dictionary]) -> void:
	var current := _snapshot_uploads(layer, 4)
	var key: Vector2i = current[0].key
	# Recreate the display boundary immediately before the new generation's
	# first family, then inject late old families between its sibling batches.
	layer._published_chunk_revisions[key] = int(old_batches[0].chunk_revision)
	var first_installed := Geometry._install_upload(layer, current[0])
	var rejected := true
	for task in old_batches:
		rejected = not Geometry._install_upload(layer, task) and rejected
	var siblings_installed := true
	for family in range(1, Layer.BATCH_COUNT):
		siblings_installed = Geometry._install_upload(layer, current[family]) and siblings_installed
	_expect("first family publication rejects every older sibling payload", first_installed and rejected)
	_expect("equal-version families finish after interleaved stale payloads", siblings_installed and _geometry_matches(layer))

func _snapshot_uploads(layer, cell: int) -> Array[Dictionary]:
	var key: Vector2i = layer._cell_chunk[cell]
	var resident: Dictionary = layer._resident.get(key, {})
	var tasks: Array[Dictionary] = []
	for family in Layer.BATCH_COUNT:
		var buffer := PackedFloat32Array()
		if resident.has(family):
			buffer = resident[family].multimesh.buffer.duplicate()
		tasks.append({"key": key, "family": family, "buffer": buffer,
			"revision": layer._revision,
			"chunk_revision": int(layer._chunk_revisions.get(key, 0))})
	return tasks

func _geometry_matches(layer) -> bool:
	for key in layer._active:
		var expected: Array = [[], [], [], [], []]
		for cell in layer._chunks[key]:
			layer._append_cell(cell, expected)
		var resident: Dictionary = layer._resident.get(key, {})
		for family in Layer.BATCH_COUNT:
			var actual := PackedFloat32Array()
			if resident.has(family):
				actual = resident[family].multimesh.buffer
			if actual != PackedFloat32Array(expected[family]):
				return false
	return int(layer.diagnostics().instances) > 0

func _test_queue() -> void:
	var queue := Queue.new()
	queue.configure(64)
	queue.request(Queue.ALL)
	var visited := {}
	for iteration in 256:
		queue.request(Queue.BANDS, PackedInt32Array([0, 0]))
		var task := queue.take()
		visited[task.x] = true
	_expect("sustained sparse updates cannot starve the full scan", visited.size() == 64)
	while queue.pending():
		queue.take()
	_expect("drained queue stays idle", not queue.pending() and queue.take().x == -1)
	queue.configure(8)
	queue.request(Queue.BANDS)
	queue.take()
	queue.request(Queue.CLIMATE)
	var climate_cells := {}
	while queue.pending():
		var task := queue.take()
		if (task.y & Queue.CLIMATE) != 0:
			climate_cells[task.x] = true
	_expect("publication during a scan revisits its already processed prefix", climate_cells.size() == 8)

func _test_chunk_round() -> void:
	var layer := Layer.new()
	var keys := [Vector2i.ZERO, Vector2i(1, 0), Vector2i(2, 0)]
	for key in keys:
		layer._active[key] = true
	for index in range(keys.size() - 1, -1, -1):
		layer._dirty[keys[index]] = true
	var actual: Array = []
	for step in 4:
		var key: Vector2i = Geometry._next_dirty_chunk(layer)
		actual.append(key)
		layer._build_round[key] = true
		# Keep every chunk dirty, as if each received another change in flight.
	_expect("continuous redo retains camera priority without starving other chunks", actual == [keys[0], keys[1], keys[2], keys[0]])
	layer.free()

func _test_native_publication() -> void:
	var map := Fixtures.make_map(2, 2)
	var ext := DCWorldExt.new()
	_expect("native visual publication fixture binds", bool(ext.bind_map_data(map)))
	var publications: Array = []
	var on_publication := func(flags: int, cells: PackedInt32Array) -> void:
		publications.append([flags, cells, map.temp_arr[0]])
	map.resource_visual_inputs_changed.connect(on_publication)
	var temperature := ext.component_id(&"cell_temp")
	ext.write_f32_range(temperature, 0, PackedFloat32Array([0.25]))
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_temp"]))
	_expect("native climate publication follows installed array", publications.size() == 1 and publications[0][0] == Queue.CLIMATE and publications[0][1].is_empty() and is_equal_approx(publications[0][2], 0.25))
	publications.clear()
	ext.flush_slots_to_map_keys(PackedStringArray(["cell_res_iron_ore_reserve"]))
	_expect("native resource publication marks abundance", publications.size() == 1 and publications[0][0] == Queue.BANDS)
	map.resource_visual_inputs_changed.disconnect(on_publication)

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[%s] %s" % ["PASS" if condition else "FAIL", label])
