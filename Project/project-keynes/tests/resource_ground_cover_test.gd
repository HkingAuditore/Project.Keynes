extends SceneTree

# ResourceGroundCover: LUT encoding, fog-memory only writes, throttled uploads, art contract.
const Catalog = preload("res://scripts/rendering/resource_visual_catalog.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
const LayerTest = preload("res://tests/resource_visual_layer_test.gd")
var checks := 0
var failures := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var art := ResourceArtLibrary.shared()
	_expect("manifest v2 with 16 cover and 9 fauna layers", art.version >= 2 and art.cover_layer_count() == 16
		and art.cover_albedo != null and art.cover_albedo.get_layers() == 16 and art.cover_normal != null
		and art.fauna != null and art.fauna.get_layers() == 9 and art.fauna_count == 8)
	_expect("albedo array is imported as VRAM-compressed 2D array", art.cover_albedo is CompressedTexture2DArray)
	var styles := Catalog.entries()
	var every_plant := true
	for e in styles:
		if int(e.family) == 0 and int(e.form) != 26:
			every_plant = every_plant and art.cover_layer(e.id) >= 0 and art.cover_layer(e.id) < 13
	_expect("every wild plant species owns a generated community layer", every_plant)
	_expect("herds map to grazing traces, fish to none", art.trace_layer_for("bio.pig") == art.cover_layer("trace.mud")
		and art.trace_layer_for("bio.camel") == art.cover_layer("trace.sand")
		and art.trace_layer_for("bio.cattle") == art.cover_layer("trace.pasture") and art.trace_layer_for("marine_fish") < 0)

	var map: MapData = LayerTest.make_map(6, 4)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var layer := Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	var world := WorldData.new()
	world.world_bounds = Rect2(-30, -30, 300, 200)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	_expect("layer configures with ground cover", bool(layer.configure(map, world, 22.0, intel).ok))
	var cover: ResourceGroundCover = layer.ground_cover()
	_expect("cover sits below props in the same draw subtree", cover != null and layer.get_child(0) == cover and cover.z_index == 0 and not cover.top_level)
	layer.set_context(false, 11)
	var wheat := _index(styles, "bio.wheat")
	var maize := _index(styles, "bio.maize")
	var pig := _index(styles, "bio.pig")
	var bands := PackedByteArray()
	bands.resize(styles.size())
	bands[wheat] = 3
	bands[maize] = 2
	bands[pig] = 2
	var always := func(_s: int, _b: int) -> bool: return true
	var texel := cover.encode_cell(bands, false, 0, always)
	var r := texel.r8
	_expect("primary community is the most abundant species", r / 16 == art.cover_layer("bio.wheat") and r % 16 == art.cover_layer("bio.maize"))
	_expect("abundance channels are non-zero and ordered", texel.g8 > 0 and texel.b8 > 0 and texel.g8 >= texel.b8)
	_expect("pig herd leaves a mud trace", texel.a8 / 64 == art.cover_layer("trace.mud") - art.cover_layer("trace.pasture") + 1 and texel.a8 % 64 > 0)
	var never := func(_s: int, _b: int) -> bool: return false
	_expect("hidden herds leave no trace", cover.encode_cell(bands, false, 0, never).a8 == 0)
	_expect("water cells carry no ground cover", cover.encode_cell(bands, true, 0, always) == Color(0, 0, 0, 0))
	var cleared := cover.encode_cell(bands, false, 15, always)
	_expect("settlement core thins the wild cover", cleared.g8 < texel.g8 and cleared.g8 > 0)
	var single := PackedByteArray()
	single.resize(styles.size())
	single[maize] = 2
	var only := cover.encode_cell(single, false, 0, always)
	_expect("single species has no secondary weight", only.r8 / 16 == art.cover_layer("bio.maize") and only.b8 == 0)

	# Unobserved cells stay empty; observation writes exactly the observed cell.
	layer.prepare_frame(0.0, Vector3.UP, {})
	var empty := true
	for cell in map.cell_count():
		empty = empty and cover.read_cell(cell) == Color(0, 0, 0, 0)
	_expect("unobserved cells stay empty", empty)
	map.bio_occupancy_bits_arr[3] = 1 << int(styles[wheat].bit)
	for frame in 4:
		layer._observe_until(Time.get_ticks_usec() + 20000)
	_expect("observing a wheat cell writes its community", cover.read_cell(3).r8 / 16 == art.cover_layer("bio.wheat") and cover.read_cell(3).g8 > 0)
	_expect("neighbouring empty cell stays empty", cover.read_cell(2) == Color(0, 0, 0, 0))
	_expect("change marks the LUT dirty and a forced flush uploads", cover.dirty() and cover.flush(true) and not cover.dirty())
	var uploads := int(cover.diagnostics().uploads)
	for frame in 4:
		layer._observe_until(Time.get_ticks_usec() + 20000)
		cover.flush(true)
	_expect("no upload without an observation change", int(cover.diagnostics().uploads) == uploads)
	cover.write_cell(1, Color8(16, 200, 0, 0))
	_expect("uploads are throttled", not cover.flush() and cover.dirty())
	layer.set_context(true, 11)
	map.visible_arr[3] = 0
	map.bio_occupancy_bits_arr[3] = 0
	for frame in 3:
		layer._observe_until(Time.get_ticks_usec() + 20000)
		layer._drain_cover_pending(Time.get_ticks_usec() + 20000)
	_expect("hidden cell keeps remembered community under fog", cover.read_cell(3).g8 > 0)
	map.visible_arr[3] = 1
	for frame in 3:
		layer._observe_until(Time.get_ticks_usec() + 20000)
	_expect("re-observed extinct community is cleared", cover.read_cell(3).g8 == 0)
	layer.profile.ground_cover_enabled = false
	layer.prepare_frame(0.0, Vector3.UP, {})
	_expect("profile switch hides the cover", not cover.visible)
	var mesh := ResourceGroundCover.build_quad_mesh(Rect2(0, 0, 100, 50), 80.0)
	_expect("wrap copies: three quads", mesh.get_surface_count() == 1 and mesh.surface_get_array_len(0) == 12)
	print("resource ground cover: %d checks, %d failures" % [checks, failures])
	layer.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func _index(styles: Array[Dictionary], id: String) -> int:
	for i in styles.size():
		if styles[i].id == id:
			return i
	return -1

func _expect(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[%s] %s" % ["PASS" if ok else "FAIL", label])
