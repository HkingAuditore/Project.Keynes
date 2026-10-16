extends SceneTree

const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Observations = preload("res://scripts/rendering/resource_visual_observations.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const Signals = preload("res://scripts/research/research_signal_catalog.gd")
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var styles := Catalog.entries()
	_expect("complete compiled catalog: 20 species and 31 reserves", bool(Catalog.audit(styles).get("ok", false)) and styles.size() == 51)
	var names := PackedStringArray()
	for e in styles:
		if e.family == 1:
			names.append(e.id)
	_expect("seven distinct mammals including cattle sheep and pig", names.size() == 7 and names.has("bio.cattle") and names.has("bio.sheep") and names.has("bio.pig"))
	var missing := styles.duplicate()
	missing.remove_at(12)
	_expect("audit catches a missing extended species", not bool(Catalog.audit(missing).ok))
	var map := make_map(8, 6)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var observations = intel.resource_observations
	var allowed := Catalog.presence_mask(styles)
	var wheat := _index(styles, "bio.wheat")
	var cattle := _index(styles, "bio.cattle")
	var gold := _index(styles, "gold_ore")
	map.bio_occupancy_bits_arr[0] = (1 << int(styles[wheat].bit)) | (1 << int(styles[cattle].bit))
	map.res_gold_ore_reserve_arr[0] = ResourceProfileRegistry.reference_reserve(styles[gold].profile)
	_expect("visible observation detects actual occupancy and reserve", observations.observe(map, 0, allowed))
	_expect("individual cattle and wheat do not come from pasture alone", observations.rows[0].bands[cattle] > 0 and observations.rows[0].bands[wheat] > 0)
	_expect("gold abundance comes from existing reference reserve", observations.rows[0].bands[gold] == 3)
	map.visible_arr[0] = 0
	map.res_gold_ore_reserve_arr[0] = 0.0
	map.bio_occupancy_bits_arr[0] = 0
	_expect("hidden cell refuses current data and keeps last-seen state", not observations.observe(map, 0, allowed) and observations.rows[0].bands[gold] == 3 and observations.rows[0].bands[cattle] > 0)
	map.visible_arr[0] = 1
	_expect("re-observation removes exhausted deposits and extinct species", observations.observe(map, 0, allowed) and observations.rows[0].bands[gold] == 0 and observations.rows[0].bands[cattle] == 0)
	map.res_gold_ore_reserve_arr[0] = ResourceProfileRegistry.reference_reserve(styles[gold].profile)
	observations.observe(map, 0, allowed)
	_expect("unidentified minerals remain objectively visible", observations.rows[0].bands[gold] > 0)
	_expect("hysteresis holds a boundary bucket", Observations.abundance_band(0.69, 3) == 3 and Observations.abundance_band(0.5, 3) == 2)
	observations.observe(map, 0, allowed)
	var payload := {"version": 4}
	payload.merge(intel.to_pkfg_fields())
	var restored := Intel.new()
	restored.configure(map.cell_count())
	_expect("PKFG v4 resource memory round-trips", bool(restored.restore_pkfg(payload).ok) and restored.resource_observations.rows[0].bands == observations.rows[0].bands)
	var bad := payload.duplicate(true)
	bad.resource_intel_bands = PackedByteArray([5])
	var before := var_to_bytes(restored.to_pkfg_fields())
	_expect("corrupt PKFG resource columns fail atomically", not bool(restored.restore_pkfg(bad).ok) and before == var_to_bytes(restored.to_pkfg_fields()))
	var missing_fields := payload.duplicate(true)
	missing_fields.erase("resource_intel_climates")
	_expect("truncated v4 memory is rejected", not bool(restored.restore_pkfg(missing_fields).ok))
	var old := payload.duplicate(true)
	old.version = 3
	_expect("v3 migration leaves resource memory unknown", bool(restored.restore_pkfg(old).ok) and restored.resource_observations.rows.is_empty())
	var bad_climate := payload.duplicate(true)
	bad_climate.resource_intel_climates = PackedColorArray([Color(NAN, 0, 0, 1)])
	_expect("non-finite climate is rejected", not bool(restored.restore_pkfg(bad_climate).ok))
	var bad_type := payload.duplicate(true)
	bad_type.resource_intel_cells = "corrupt"
	_expect("wrong column types fail without conversion side effects", not bool(restored.restore_pkfg(bad_type).ok))
	_test_save_provider(map, observations.rows)
	_test_world_density(styles)

	var layer := Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	var world := WorldData.new()
	world.world_bounds = Rect2(-30, -30, 400, 250)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	_expect("resource layer configures", bool(layer.configure(map, world, 22.0, intel).ok))
	_expect("resource root shares the terrain draw subtree", layer.z_index == 0 and not layer.top_level and layer.z_as_relative)
	layer.set_context(false, 7383)
	layer.set_quality(2)
	layer.set_camera_view(world.world_bounds, world.world_bounds.get_center(), 3.0)
	var test_bands := PackedByteArray()
	test_bands.resize(styles.size())
	test_bands.fill(4)
	observations.rows[0] = {"bands": test_bands, "climate": Color(0.6, 0.6, 0.0, 1.0)}
	var selected: PackedInt32Array = layer.selected_styles(0)
	var families := {}
	for index in selected:
		families[styles[index].family] = true
	_expect("default selects at most three balanced families", selected.size() == 3 and families.size() == 3)
	layer.set_filter("gold_ore")
	_expect("selected resource wins its family slot", layer.selected_styles(0).has(gold))
	layer.set_filter("bio.pig")
	_expect("selected species wins its family slot", layer.selected_styles(0).has(_index(styles, "bio.pig")))
	var buffers: Array = [[], [], [], [], []]
	layer._append_cell(0, buffers)
	var again: Array = [[], [], [], [], []]
	layer._append_cell(0, again)
	_expect("deterministic candidate placement and ABI", buffers == again and _count(buffers) <= 6)
	_expect("at most one decal and one prop per selected resource", _count(buffers) <= selected.size() * 2 and _count_kind(buffers, Layer.KIND_PROP) <= selected.size())
	_expect("ground decals live in their own batch drawn under props", _all_kind(buffers[Layer.DECAL_BATCH], Layer.KIND_DECAL))
	var carriers := 0
	for buffer in buffers:
		for base in range(0, buffer.size(), 16):
			carriers += 1 if fposmod(float(buffer[base + 11]), 1.0) < 0.25 else 0
	_expect("each placed resource owns exactly one lens badge", carriers == _placed_resources(buffers))
	var deposit := {"family": 2, "form": 17}
	var soil := {"family": 2, "form": 22}
	_expect("deposits become scar decal plus small prop", Layer.visual_plan(deposit, false) == (Layer.PLAN_DECAL | Layer.PLAN_PROP))
	_expect("land qualities are pure ground decals", Layer.visual_plan(soil, false) == Layer.PLAN_DECAL)
	_expect("timber only keeps its lens badge", Layer.visual_plan({"family": 0, "form": 26}, false) == Layer.PLAN_BADGE)
	_expect("props are decoration-sized", float(layer.profile.patch_diameter_hex) <= 0.4 and float(layer.profile.outline_strength) == 0.0 and float(layer.profile.cast_shadow) == 0.0)
	var upright := true
	for buffer in buffers:
		for base in range(0, buffer.size(), 16):
			upright = upright and is_zero_approx(float(buffer[base + 1])) and is_zero_approx(float(buffer[base + 4])) and float(buffer[base]) > 0.0
	_expect("45-degree subjects keep their feet downward", upright)
	var within := true
	for buffer in buffers:
		for base in range(0, buffer.size(), 16):
			within = within and Vector2(buffer[base + 3], buffer[base + 7]).distance_to(layer.cell_position(0)) <= 22.0 * 0.73
	_expect("candidate positions use renderer hex scale", within and _count(buffers) > 0)
	layer.set_quality(0, 2)
	_expect("mobile tier remains independent of terrain quality", layer.quality() == 2 and layer.profile.instance_cap(layer.quality(), true) == 4000)
	layer.profile.mobile_instance_caps = PackedInt32Array([2, 2, 2])
	for frame in 40:
		layer._build_until(Time.get_ticks_usec() + 10000)
		layer.drain_one_upload()
	_expect("hard global instance cap", int(layer.diagnostics().instances) <= 2)
	var below_canopy := true
	for families_row in layer._resident.values():
		for node in families_row.values():
			below_canopy = below_canopy and node.z_as_relative and node.z_index == 1
	_expect("resource draw batches share vegetation-relative ground z", below_canopy)
	map.is_water_arr[0] = 1
	observations.rows[0] = {"bands": test_bands, "climate": Color(0.6, 0.6, 0, 1)}
	var water_buffers: Array = [[], [], [], [], []]
	layer._append_cell(0, water_buffers)
	_expect("water cells only create submerged cues", _count(water_buffers) > 0 and _count(water_buffers) == water_buffers[3].size() / 16 and _all_kind(water_buffers[3], Layer.KIND_SUBMERGED))
	var submerged_ids := {}
	for base in range(0, water_buffers[3].size(), 16):
		submerged_ids[String(styles[int(water_buffers[3][base + 13])].id)] = true
	var underwater_only := true
	for id in submerged_ids:
		underwater_only = underwater_only and id in ["oil", "natural_gas", "marine_fish", "freshwater_fish"]
	_expect("oil, gas and fish render as MultiMesh cues, not terrain shader", underwater_only and not layer.has_method("floor_texture"))
	map.is_water_arr[0] = 0
	layer.profile.enabled = false
	layer.prepare_frame(0.0, Vector3.UP, {})
	var hidden := true
	for families_row in layer._resident.values():
		for node in families_row.values():
			hidden = hidden and not node.visible
	_expect("profile enabled switch hides existing draw batches", hidden)
	layer.profile.enabled = true
	# A resource filter turns the lens on, which bypasses the zoom cull by design.
	layer.set_filter("")
	layer._lens_amount = 0.0
	layer.prepare_frame(0.0, Vector3.UP, {})
	layer.set_camera_view(world.world_bounds, world.world_bounds.get_center(), 0.1)
	var far_hidden := true
	for families_row in layer._resident.values():
		for node in families_row.values():
			far_hidden = far_hidden and not node.visible
	_expect("subpixel overview submits no visible detail batches", far_hidden)
	layer.set_camera_view(Rect2(100000, 100000, 100, 100), Vector2(100000, 100000), 1.0)
	_expect("offscreen chunks are evicted", int(layer.diagnostics().instances) == 0)
	intel.restore_pkfg(old)
	layer._sync_restored_memory()
	_expect("old-save restore leaves no stale resource geometry", int(layer.diagnostics().instances) == 0)
	_test_water_rejection(layer)
	print("resource visual: %d checks, %d failures" % [checks, failures])
	layer.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _test_water_rejection(layer: Node2D) -> void:
	var world := WorldData.new()
	world.world_bounds = Rect2(0, 0, 100, 100)
	world.derived_size = Vector2i(2, 2)
	world.biome_buffer = PackedByteArray([0, 0, 0, 0])
	world.flow_buffer = PackedFloat32Array([0, 0, 0, 0])
	layer._world = world
	_expect("land resources reject ocean pixels", not layer.candidate_allowed(Vector2(50, 50), 0))
	_expect("fish accepts water pixels", layer.candidate_allowed(Vector2(50, 50), 3))
	world.biome_buffer.fill(TerrainType.TERRAIN.PLAIN)
	world.flow_buffer.fill(1.0)
	_expect("land resources reject actual river body", not layer.candidate_allowed(Vector2(50, 50), 1))
	world.flow_buffer.fill(0.0)
	_expect("fish rejects dry land", not layer.candidate_allowed(Vector2(50, 50), 3))
	world.biome_buffer = PackedByteArray()
	_expect("retired biome atlas still respects source water domain", not layer.candidate_allowed(Vector2(50, 50), 1, 1) and layer.candidate_allowed(Vector2(50, 50), 3, 1))

func _test_world_density(styles: Array[Dictionary]) -> void:
	var layer := Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	var map := make_map(1, 1)
	var intel := Intel.new()
	intel.configure(1)
	layer.configure(map, WorldData.new(), 22.0, intel)
	layer.set_context(false, 7383)
	var gold := _index(styles, "gold_ore")
	var cattle := _index(styles, "bio.cattle")
	var wheat := _index(styles, "bio.wheat")
	var soil := _index(styles, "fertile_soil")
	var minerals := 0
	var animals := 0
	var plants := 0
	var fertile := 0
	var stable := true
	for cell in 1024:
		var present: bool = layer.world_presence_allowed(cell, gold, 4)
		minerals += 1 if present else 0
		animals += 1 if layer.world_presence_allowed(cell, cattle, 2) else 0
		plants += 1 if layer.world_presence_allowed(cell, wheat, 2) else 0
		fertile += 1 if layer.world_presence_allowed(cell, soil, 1) else 0
		stable = stable and present == layer.world_presence_allowed(cell, gold, 4)
	_expect("object scenery is sparse while plants and fertility remain available", minerals > 200 and minerals < 440 and animals > 280 and animals < 540 and plants == 1024 and fertile == 1024)
	_expect("scenery sampling is stable across repeated queries", stable)
	_expect("low-abundance mineral does not create scenery", not layer.world_presence_allowed(0, gold, 2))
	var bands := PackedByteArray()
	bands.resize(styles.size())
	bands[gold] = 1
	intel.resource_observations.rows[0] = {"bands": bands, "climate": Color(0.6, 0.6, 0, 1)}
	_expect("world omits a small deposit", layer.selected_styles(0).is_empty())
	layer.set_lens(true)
	_expect("manual resource lens finds a deposit below scenery threshold", layer.selected_styles(0).has(gold))
	layer.set_lens(false)
	layer.set_filter("gold_ore")
	_expect("resource filter bypasses scenery threshold", layer.selected_styles(0).has(gold))
	_expect("display threshold never changes observed reserves", intel.resource_observations.rows[0].bands[gold] == 1)
	layer.queue_free()

func _test_save_provider(map: MapData, observed_rows: Dictionary) -> void:
	var save := root.get_node_or_null("GameSave")
	_expect("production save provider is available", save != null)
	if save == null:
		return
	var host := WorldRuntimeHost.new()
	host.set("_current_map", map)
	var intel := host.building_visual_intel_cache()
	intel.configure(map.cell_count())
	intel.resource_observations.rows = observed_rows.duplicate(true)
	var captured: Dictionary = save.call("_write_vision_provider", {"host": host})
	_expect("production provider captures PKFG v4 resource memory", bool(captured.get("ok", false)) and int(captured.sections.pkfg.version) == 4 and not captured.sections.pkfg.resource_intel_cells.is_empty())
	var restored: Dictionary = save.call("_restore_vision_provider", captured.sections, {"host": host})
	_expect("production provider restores v4", bool(restored.get("ok", false)))
	var bad: Dictionary = captured.sections.duplicate(true)
	bad.pkfg.explored = PackedByteArray()
	bad.pkfg.explored.resize(map.cell_count())
	bad.pkfg.resource_intel_bands = PackedByteArray([255])
	var before := map.explored_arr.duplicate()
	var rejected: Dictionary = save.call("_restore_vision_provider", bad, {"host": host})
	_expect("production provider rejects bad memory before committing exploration", not bool(rejected.get("ok", false)) and map.explored_arr == before)
	host.free()

static func make_map(width: int, height: int) -> MapData:
	var map := MapData.new(width, height)
	for row in height:
		for col in width:
			var cube := HexUtils.offset_to_cube(col, row)
			var cell := HexCell.new(cube.x, cube.y)
			cell.terrain = TerrainType.TERRAIN.PLAIN
			cell.landform = LandformType.LF.PLAIN
			map.set_cell(cell)
	map._build_indices()
	map.init_soa_from_bake()
	map.visible_arr.fill(1)
	map.explored_arr.fill(1)
	map.resource_habitat_mask_arr.fill(255)
	map.temp_arr.fill(0.6)
	map.moisture_arr.fill(0.6)
	map.vegetation_vitality_arr.fill(1.0)
	return map

func _index(styles: Array[Dictionary], id: String) -> int:
	for i in styles.size():
		if styles[i].id == id:
			return i
	return -1

func _count(buffers: Array) -> int:
	var total := 0
	for buffer in buffers:
		total += buffer.size() / 16
	return total

func _count_kind(buffers: Array, kind: float) -> int:
	var total := 0
	for buffer in buffers:
		for base in range(0, buffer.size(), 16):
			total += 1 if floorf(float(buffer[base + 11]) + 0.01) == kind else 0
	return total

func _all_kind(buffer: Array, kind: float) -> bool:
	for base in range(0, buffer.size(), 16):
		if floorf(float(buffer[base + 11]) + 0.01) != kind:
			return false
	return true

func _placed_resources(buffers: Array) -> int:
	var styles_seen := {}
	for buffer in buffers:
		for base in range(0, buffer.size(), 16):
			styles_seen[int(buffer[base + 13])] = true
	return styles_seen.size()

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])
