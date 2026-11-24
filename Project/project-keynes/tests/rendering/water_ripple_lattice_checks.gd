extends RefCounted

const Water = preload("res://scripts/rendering/renderer_shader_water.gd")
const Table = preload("res://scripts/rendering/render_data_table.gd")
const Lattice = Water.WaterRippleLattice
const FULL := Rect2i(0, 0, 256, 768)
const PAGE_ONE := Rect2i(0, 0, 256, 256)
const PAGE_TWO := Rect2i(0, 256, 256, 256)
const DYNAMIC := Rect2i(0, 0, 256, 512)
const WATER_ONLY := "#define PK_WATER_ONLY\n"
const MOBILE_HIGH := "#define MOBILE_QUALITY_HIGH\n" + WATER_ONLY


static func run(tree: SceneTree, check: Callable, can_read_pixels: bool) -> void:
	var renderer := HexRenderer.new()
	tree.root.add_child(renderer)
	renderer.set_process(false)
	renderer.water_flow_advection = 2.28
	_check_variants(renderer, check)
	Water._create_water_quad(renderer, MOBILE_HIGH, "split")
	var table := renderer._ripple_table
	if table == null:
		check.call(false, "high water binds its numerical texture")
		renderer.queue_free()
		return

	var reference: SubViewport
	var coverage: Lattice
	if can_read_pixels:
		# The unchanged table renders all three pages for the same cycle vector.
		reference = Table.new()
		reference.configure(tree.root, FULL.size, Lattice.PROGRAM)
		# Changing this value on every step reveals every pixel actually drawn,
		# including pixels whose real seed would yield the same color.
		var marker := Shader.new()
		marker.code = """shader_type canvas_item;
render_mode unshaded, blend_disabled;
uniform vec4 cycles;
uniform float mark;
void fragment() { COLOR = vec4(mark, 0.0, 0.0, 1.0); }"""
		coverage = Lattice.new()
		coverage.configure(tree.root, FULL.size, marker)

	var steps := [
		[[0.0], Vector4.ZERO, FULL, "initial fill"],
		[[4.3], Vector4(0, 0, 0, 1), PAGE_TWO, "only second page"],
		[[5.0], Vector4(0, 0, 0, 1), Rect2i(), "no cycle changed"],
		[[6.4], Vector4(0, 1, 0, 1), PAGE_ONE, "only first page"],
		[[8.5], Vector4(0, 1, 1, 1), PAGE_TWO, "only second page again"],
		[[12.7], Vector4(1, 1, 1, 2), DYNAMIC, "both pages in one request"],
		[[16.9, 19.0], Vector4(1, 2, 2, 2), DYNAMIC, "two requests before the same draw"],
	]
	var page_updates := Vector3i.ZERO
	var page_marks := Vector3.ZERO
	for i in steps.size():
		var step: Array = steps[i]
		for time: float in step[0]:
			renderer._world_time = time
			Water.sync_ripple_lattice(renderer)
			if can_read_pixels:
				coverage.update_cycles(table._cycles)
		var rect: Rect2i = step[2]
		var label: String = step[3]
		check.call(table._cycles == step[1], "%s uses the recorded cycles" % label)
		_check_rect(table, rect, label, check)
		var mark := float(i + 1) / 8.0
		for page in 3:
			if table._pending_region.intersects(_page_rect(page)):
				page_updates[page] += 1
			if rect.intersects(_page_rect(page)):
				page_marks[page] = mark
		if can_read_pixels:
			reference.material.set_shader_parameter("cycles", step[1])
			reference.refresh()
			coverage.material.set_shader_parameter("mark", mark)
		await _draw(can_read_pixels)
		check.call(not table._pending_region.has_area(), "%s consumes the queued draw" % label)
		if can_read_pixels:
			_check_pixels(table, reference, label, check)
			_check_drawn_pages(coverage, page_marks, label, check)
	check.call(page_updates == Vector3i(4, 5, 1), "submitted page counts are %s" % page_updates)

	for percent in [75, 100]:
		renderer.set_terrain_render_scale(percent, Viewport.MSAA_DISABLED)
		var expected: Viewport = tree.root if percent == 100 else renderer._graphics_details._terrain_scale._target
		var label := "map scale %d%%" % percent
		check.call(renderer._ripple_table == table and table.get_parent() == renderer._water_quad
			and renderer._water_quad.get_viewport() == expected, "%s keeps the table with its consumer" % label)
		_check_rect(table, FULL, label, check)
		await _draw(can_read_pixels)
		if can_read_pixels:
			_check_pixels(table, reference, label, check)

	Water._drop_water_quad(renderer)
	Water._create_water_quad(renderer, "#define MOBILE_QUALITY_LOW\n" + WATER_ONLY, "split")
	check.call(table.is_queued_for_deletion() and renderer._ripple_table == null,
		"low quality releases the old table")
	Water._drop_water_quad(renderer)
	Water._create_water_quad(renderer, MOBILE_HIGH, "split")
	var replacement := renderer._ripple_table
	check.call(replacement != null and replacement != table and replacement._cycles == steps[-1][1]
		and renderer._water_mat.get_shader_parameter(&"water_ripple_lattice") == replacement.get_texture(),
		"high quality rebuilds and binds the table at the same cycle")
	if replacement != null:
		_check_rect(replacement, FULL, "rebuilt table", check)
		await _draw(can_read_pixels)
		if can_read_pixels:
			_check_pixels(replacement, reference, "rebuilt table", check)
	if can_read_pixels:
		reference.queue_free()
		coverage.queue_free()
	renderer.queue_free()
	await tree.process_frame


static func _check_variants(renderer: HexRenderer, check: Callable) -> void:
	for variant in [
		["desktop split", WATER_ONLY, "split", true],
		["mobile medium", "#define MOBILE_QUALITY_MID\n" + WATER_ONLY, "split", true],
		["mobile low", "#define MOBILE_QUALITY_LOW\n" + WATER_ONLY, "split", false],
		["Compatibility split", Water.PK_WEB_TEXTURE_BUDGET_DEFINE + WATER_ONLY, "split", false],
		["Web compact", "", "web_min", false],
		["Web PC High", Water.WATER_WEB_HIGH_PREFIX, "high", false],
	]:
		Water._create_water_quad(renderer, variant[1], variant[2])
		check.call(renderer._water_mat != null and (renderer._ripple_table != null) == variant[3]
			and renderer._water_uniform_names.has(&"water_ripple_lattice") == variant[3],
			"%s preserves its water table binding" % variant[0])
		Water._drop_water_quad(renderer)
	var combined := load(renderer.WORLD_MAP_SHADER_PATH) as Shader
	check.call(not combined.get_shader_uniform_list().any(
		func(param: Dictionary) -> bool: return param.name == &"water_ripple_lattice"),
		"combined land and water still has no table sampler")


static func _check_rect(table: Lattice, rect: Rect2i, label: String, check: Callable) -> void:
	check.call(table._pending_region == rect and (not rect.has_area() or Rect2i(table._quad.get_rect()) == rect),
		"%s submits %s" % [label, rect])


static func _draw(can_read_pixels: bool) -> void:
	if can_read_pixels:
		await RenderingServer.frame_post_draw
	else:
		RenderingServer.force_draw(false)


static func _page_rect(page: int) -> Rect2i:
	return Rect2i(0, 256 * page, 256, 256)


static func _check_pixels(table: SubViewport, reference: SubViewport, label: String, check: Callable) -> void:
	var actual := table.get_texture().get_image()
	var full := reference.get_texture().get_image()
	if actual == null or full == null or actual.get_size() != FULL.size or full.get_size() != FULL.size:
		check.call(false, "%s reads both complete textures" % label)
		return
	for page in 3:
		var region := _page_rect(page)
		check.call(actual.get_region(region).get_data() == full.get_region(region).get_data(),
			"%s page %d matches the full draw byte for byte" % [label, page + 1])


static func _check_drawn_pages(coverage: Lattice, marks: Vector3, label: String, check: Callable) -> void:
	var image := coverage.get_texture().get_image()
	if image == null or image.get_size() != FULL.size:
		check.call(false, "%s reads actual draw coverage" % label)
		return
	for page in 3:
		var region := _page_rect(page)
		var expected := Image.create_empty(256, 256, false, image.get_format())
		expected.fill(Color(marks[page], 0, 0, 1))
		check.call(image.get_region(region).get_data() == expected.get_data(),
			"%s GPU draw coverage matches page %d" % [label, page + 1])
