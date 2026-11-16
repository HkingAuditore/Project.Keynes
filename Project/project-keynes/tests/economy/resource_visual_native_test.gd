extends SceneTree

const Fixtures = preload("res://tests/economy/resource_visual_layer_test.gd")
const Layer = preload("res://scripts/rendering/resource_visual_layer.gd")
const Geometry = preload("res://scripts/rendering/resource_visual_geometry.gd")
const NativeSlice = preload("res://scripts/rendering/resource_visual_native_slice.gd")
const Intel = preload("res://scripts/rendering/building_visual_intel_cache.gd")
var checks := 0
var failures := 0
var native_cells := 0
var native_styles := 0

func _init() -> void:
	call_deferred("run")

func run() -> void:
	_expect("native pure builder is registered", ClassDB.class_exists("NativeResourceVisualBuilder"))
	if failures != 0:
		_finish()
		return
	var map := Fixtures.make_map(8, 6)
	var intel := Intel.new()
	intel.configure(map.cell_count())
	var world := WorldData.new()
	world.world_bounds = Rect2(-40, -40, 400, 300)
	world.lut_dims = Vector2i(map.cell_count(), 1)
	var layer := Layer.new()
	root.add_child(layer)
	layer.profile = load("res://data/visual/resource_default.tres").duplicate(true)
	_expect("layer configures", bool(layer.configure(map, world, 22.0, intel).ok))
	layer.set_context(true, 20261016)
	layer.set_quality(2)
	var bands := PackedByteArray()
	bands.resize(layer._styles.size())
	for cell in map.cell_count():
		for style in bands.size():
			bands[style] = 1 + (cell + style) % 4
		intel.resource_observations.rows[cell] = {"bands": bands.duplicate(), "climate": Color(0.6, 0.6, 0, 1)}
	for seed in [0, 20261016, -934655, 9223372036854775800, -9223372036854775807]:
		layer._layout_seed = seed
		_compare(layer, "land seed %d" % seed)
	layer._layout_seed = 20261016
	for quality in 3:
		layer.set_quality(quality)
		layer.profile.cluster_spread = 0.1 + quality * 0.37
		layer.profile.density_scale = 0.6 + quality * 0.5
		layer.profile.style_overrides = {"gold_ore": {"priority": 9.7, "size_scale": 1.231}}
		layer.set_filter("resource.gold_ore" if quality == 1 else "")
		_compare(layer, "direct profile quality %d" % quality)
	layer.profile.style_overrides.clear()
	layer.set_filter("")
	layer.set_quality(2)
	layer.set_lens(true)
	_compare(layer, "lens and all selected style layouts", true)
	world.derived_size = Vector2i(7, 5)
	world.flow_buffer.resize(35)
	world.biome_buffer.resize(35)
	var terrains := [TerrainType.TERRAIN.OCEAN, TerrainType.TERRAIN.COAST, TerrainType.TERRAIN.LAKE,
		TerrainType.TERRAIN.SEA_ICE, TerrainType.TERRAIN.FOREST]
	for pixel in 35:
		world.flow_buffer[pixel] = float(pixel % 7) / 6.0
		world.biome_buffer[pixel] = terrains[pixel % terrains.size()]
	for cell in map.cell_count():
		map.is_water_arr[cell] = cell % 2
		map.elevation_arr[cell] = float(cell % 11) / 20.0
	for wrap in [0.0, 400.0]:
		world.wrap_period_x = wrap
		_compare(layer, "mixed biome/flow wrap %.0f" % wrap, true)
	world.biome_buffer = PackedByteArray()
	world.flow_buffer.fill(0.9)
	_test_owner_inputs(layer, world)
	_test_exceptional_selection(layer)
	_test_continuation(layer)
	_test_rejected_inputs(layer)
	_expect("native cells and single-style steps were actually exercised", native_cells > 500 and native_styles > 1000)
	layer.queue_free()
	await process_frame
	_finish()

func _compare(layer, label: String, every_style: bool = false, expect_native: bool = true) -> void:
	var native := Geometry.Context.new(layer)
	var script := Geometry.Context.new(layer, false)
	var same := (native.native != null) == expect_native and script.native == null
	if not same:
		_expect(label + " has native slice", false)
		return
	for cell in layer._map.cell_count():
		var actual := Geometry._new_cell(native, cell)
		var expected := Geometry._new_cell(script, cell)
		native_cells += 1
		if actual.selected != expected.selected:
			print("selection mismatch ", label, " cell=", cell, " native=", actual.selected, " script=", expected.selected)
			same = false
			break
		if every_style:
			actual.selected = PackedInt32Array(range(layer._styles.size()))
			expected.selected = actual.selected.duplicate()
		var actual_buffers: Array = [[], [], [], [], []]
		var expected_buffers: Array = [[], [], [], [], []]
		while actual.rank < actual.selected.size():
			if native.native != null:
				var used: bool = native.native.call("append_style", actual.cell, actual.bands,
					actual.selected[actual.rank], actual.rank, actual.core, actual.center,
					actual.source_water, actual.occupied, actual_buffers)
				if not used:
					print("unexpected unsupported native style ", label, " cell=", cell)
					same = false
					break
			else:
				Geometry._append_style(native, actual, actual_buffers)
			Geometry._append_style(script, expected, expected_buffers)
			native_styles += 1
			if var_to_bytes(actual.occupied) != var_to_bytes(expected.occupied) or not _same_buffers(actual_buffers, expected_buffers):
				print("layout mismatch ", label, " cell=", cell, " rank=", actual.rank, " style=", actual.selected[actual.rank])
				_dump_difference(actual_buffers, expected_buffers)
				same = false
				break
			actual.rank += 1
			expected.rank += 1
		if not same:
			break
	_expect(label + " selection, occupancy and all float32 buffer bytes match", same)

func _test_owner_inputs(layer, world: WorldData) -> void:
	var cells: Array = [HexCell.new(), HexCell.new(), null, HexCell.new()]
	cells[0].index = 0
	cells[1].index = -1
	cells[3].index = 1000000
	var p2c := PackedInt32Array()
	p2c.resize(35)
	for pixel in p2c.size():
		p2c[pixel] = pixel % 5 # Includes out-of-range owner, null and nonnull invalid index.
	world.publish_pixel_lookup_indices(p2c, cells, 35)
	_expect("null owner and nonnull invalid owner remain distinct", world.pixel_owner_present[1] == 1 and world.pixel_owner_indices[1] == -1 and world.pixel_owner_present[2] == 0 and world.pixel_owner_present[3] == 1 and world.pixel_owner_indices[3] == 1000000)
	_compare(layer, "published lookup null/invalid owner and river", true)
	p2c.fill(3)
	world.publish_pixel_lookup_indices(p2c, cells, 35)
	_compare(layer, "rebake replaces complete owner publication", true)
	world.pixel_to_cell_lookup[0] = cells[0]
	world.invalidate_pixel_owner_snapshot()
	_expect("explicit invalidation supports in-place lookup edits", world.pixel_owner_indices.is_empty() and world.pixel_owner_present.is_empty())
	_compare(layer, "explicitly invalidated lookup uses complete script path", true, false)
	world.publish_pixel_lookup_indices(p2c, cells, 35)
	p2c.resize(7)
	world.publish_pixel_lookup_indices(p2c, cells, 7)
	_compare(layer, "short owner lookup rejects uncovered pixels", true)
	world.pixel_to_cell_lookup = [cells[1]]
	_expect("direct lookup replacement invalidates pure owner snapshot", world.pixel_owner_indices.is_empty() and world.pixel_owner_present.is_empty())
	_compare(layer, "custom lookup without publication preserves full script output", true, false)
	world.publish_pixel_lookup_indices(PackedInt32Array([0]), cells, 35)
	_expect("short p2c publishes all null owners", world.pixel_owner_present.count(0) == 35 and world.pixel_to_cell_lookup.count(null) == 35)
	_compare(layer, "short p2c uses published null ownership", true)
	world.pixel_to_cell_lookup = []
	world.pixel_owner_indices = PackedInt64Array()
	world.pixel_owner_present = PackedByteArray()
	world.flow_buffer = PackedFloat32Array()
	_compare(layer, "restored world before rebake uses source domain", true)

func _test_exceptional_selection(layer) -> void:
	var context := Geometry.Context.new(layer, false)
	context.lens = true
	context.allowed.fill(1)
	context.priorities = context.priorities.duplicate()
	var bands: PackedByteArray = context.rows[0].bands
	for style in context.priorities.size():
		context.priorities[style] = -(float(bands[style]) * 0.18 + Geometry.Plan._hash(0, style))
	# Force exactly equal scores by using zero band multiplier on two copies of
	# an otherwise identical style in the pure input, while reference keeps the
	# original comparator for the actual catalog's non-finite overrides below.
	var input := NativeSlice.inputs(context)
	input.priorities.fill(NAN)
	var builder: RefCounted = ClassDB.instantiate("NativeResourceVisualBuilder")
	_expect("nonfinite priority input itself remains supported", bool(builder.call("configure_slice", input).ok))
	_expect("nonfinite candidate requests original sorting", builder.call("select_cell", 0, bands, false) == null)
	for value in [NAN, INF, -INF]:
		layer.profile.style_overrides = {"gold_ore": {"priority": value}}
		_compare(layer, "nonfinite priority %.0f preserves original sort" % value)
	layer.profile.style_overrides.clear()
	# Construct exact ties at score=0 using per-style compensation (same left
	# associated additions as production). Validate the actual fallback result.
	context = Geometry.Context.new(layer, false)
	context.lens = true
	context.priorities = context.priorities.duplicate()
	for style in context.priorities.size():
		context.priorities[style] = -float(bands[style]) * 0.18
	input = NativeSlice.inputs(context)
	input.priorities[0] = 0.0
	input.priorities[1] = 0.0
	# The direct two identical style rows are not needed to exercise sort ties:
	# choose cell=-1 and identical band/priority/hash compensated double values.
	var tied_bands := bands.duplicate()
	for style in input.priorities.size():
		tied_bands[style] = 1
		input.priorities[style] = -Geometry.Plan._hash(0, style) * 0.08
	# Explicit exact tie is checked by searching subtraction rounding below.
	var scores := {}
	var has_tie := false
	for style in input.priorities.size():
		var score: float = input.priorities[style] + 0.18 + Geometry.Plan._hash(0, style) * 0.08
		has_tie = has_tie or scores.has(score)
		scores[score] = true
	_expect("tie fixture contains exact double ties", has_tie)
	_expect("tie inputs configure", bool(builder.call("configure_slice", input).ok))
	_expect("exact ties request original sorting", builder.call("select_cell", 0, tied_bands, false) == null)

func _test_continuation(layer) -> void:
	var native := Geometry.Context.new(layer)
	var script := Geometry.Context.new(layer, false)
	var actual := Geometry._new_cell(native, 0)
	var expected := Geometry._new_cell(script, 0)
	var buffers_a: Array = [[], [], [], [], []]
	var buffers_b: Array = [[], [], [], [], []]
	if actual.selected.size() > 1:
		Geometry._append_style(native, actual, buffers_a)
		Geometry._append_style(script, expected, buffers_b)
		actual.rank += 1
		expected.rank += 1
		var id: String = layer._styles[actual.selected[1]].id
		layer.profile.style_overrides = {id: {"priority": 9.25, "size_scale": 1.731}}
		# New slice refreshes live profile values while the small cell work keeps
		# its original selection, bands, rank and collision positions.
		native = Geometry.Context.new(layer)
		script = Geometry.Context.new(layer, false)
		while actual.rank < actual.selected.size():
			Geometry._append_style(native, actual, buffers_a)
			Geometry._append_style(script, expected, buffers_b)
			actual.rank += 1
			expected.rank += 1
	_expect("profile edit between style slices keeps selection and exact buffers", actual.selected.size() > 1 and native.native != null and actual.selected == expected.selected and var_to_bytes(actual.occupied) == var_to_bytes(expected.occupied) and _same_buffers(buffers_a, buffers_b))
	layer.profile.style_overrides.clear()

func _test_rejected_inputs(layer) -> void:
	var context := Geometry.Context.new(layer, false)
	var input := NativeSlice.inputs(context)
	var original_map: MapData = context.map
	context.map = null
	_expect("optional builder preserves map-null script helper boundary", NativeSlice.create(context) == null and Geometry._transmission(context, 0) == 1.0)
	context.map = original_map
	var builder: RefCounted = ClassDB.instantiate("NativeResourceVisualBuilder")
	_expect("complete inputs configure", bool(builder.call("configure_slice", input).ok))
	_expect("missing inputs reset and reject previous slice", not bool(builder.call("configure_slice", {}).ok))
	var bad := input.duplicate()
	bad.flow = PackedFloat32Array([0.5])
	bad.derived = Vector2i(7, 5)
	_expect("short nonempty flow rejects before indexed reads", not bool(builder.call("configure_slice", bad).ok))
	bad = input.duplicate()
	bad.biome = PackedByteArray([0])
	bad.derived = Vector2i(7, 5)
	_expect("short nonempty biome rejects before indexed reads", not bool(builder.call("configure_slice", bad).ok))
	for family in [-1, 4]:
		bad = input.duplicate(true)
		bad.families = input.families.duplicate()
		bad.families[0] = family
		_expect("out of range family %d rejects" % family, not bool(builder.call("configure_slice", bad).ok))
	bad = input.duplicate()
	bad.biome = PackedByteArray([0])
	bad.derived = Vector2i.ZERO
	_expect("nonempty biome with invalid dimensions rejects", not bool(builder.call("configure_slice", bad).ok))
	bad = input.duplicate()
	bad.water = PackedByteArray()
	_expect("water/elevation mismatch may be validated per accessed cell", bool(builder.call("configure_slice", bad).ok))
	var buffers: Array = [[], [], [], [], []]
	var occupied: Array[Vector3] = []
	_expect("missing water for existing elevation returns unsupported without mutation", not bool(builder.call("append_style", 0, context.rows[0].bands, 0, 0, 0, Vector2.ZERO, false, occupied, buffers)) and occupied.is_empty() and _same_buffers(buffers, [[], [], [], [], []]))

func _same_buffers(a: Array, b: Array) -> bool:
	for family in 5:
		if PackedFloat32Array(a[family]).to_byte_array() != PackedFloat32Array(b[family]).to_byte_array():
			return false
	return true

func _dump_difference(a: Array, b: Array) -> void:
	for family in 5:
		if a[family].size() != b[family].size():
			print("family=", family, " sizes ", a[family].size(), " / ", b[family].size())
		for index in mini(a[family].size(), b[family].size()):
			if PackedFloat32Array([a[family][index]]).to_byte_array() != PackedFloat32Array([b[family][index]]).to_byte_array():
				print("first float mismatch family=", family, " index=", index, " native=", a[family][index], " script=", b[family][index])
				return

func _expect(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("[FAIL] " + label)

func _finish() -> void:
	print("resource visual native: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
