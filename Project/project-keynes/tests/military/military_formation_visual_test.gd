extends SceneTree

## Headless contract checks for the isolated military formation prototype.
## Run:
##   godot --headless --path Project/project-keynes \
##     -s res://tests/military/military_formation_visual_test.gd

const CATALOG_PATH := "res://data/military/military_visual_catalog.json"
const MILITARY_CATALOG_PATH := "res://data/military/military_catalog.json"
const ATLAS_PATH := "res://assets/military/formations/prototype/military_formation_prototype_v4.png"
const ATLAS_IMPORT_PATH := \
	"res://assets/military/formations/prototype/military_formation_prototype_v4.png.import"
const SOURCE_SHEET_DIR := "res://assets/military/formations/prototype/source/v4/selected"
const SOURCE_MANIFEST_PATH := \
	"res://assets/military/formations/prototype/source/source_manifest_v4.json"
const SOURCE_PROTOTYPES := ["foot", "mounted", "artillery", "armored"]
const SOURCE_ACTIONS := ["idle", "move", "attack", "hit"]
const SOURCE_SHEET_COLUMNS := 4
const SOURCE_SHEET_ROWS := 2
const ALPHA_THRESHOLD := 0.03
const LAYER_SCRIPT_PATH := "res://scripts/rendering/military_formation_preview_layer.gd"
const SHADER_PATH := "res://shaders/military_formation_sprite.gdshader"
const PAPER_SHADER_PATH := "res://shaders/military_paper_sticker.gdshader"
const HARNESS_SCENE_PATH := "res://tests/military/military_formation_visual_harness.tscn"
const TOKEN_HARNESS_SCENE_PATH := \
	"res://tests/military/military_formation_token_harness.tscn"

var _failures := PackedStringArray()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := _load_json(CATALOG_PATH)
	var military_catalog := _load_json(MILITARY_CATALOG_PATH)
	var layer_script = load(LAYER_SCRIPT_PATH)
	var shader := load(SHADER_PATH) as Shader
	var paper_shader := load(PAPER_SHADER_PATH) as Shader
	var harness := load(HARNESS_SCENE_PATH) as PackedScene
	var token_harness := load(TOKEN_HARNESS_SCENE_PATH) as PackedScene

	_expect(layer_script != null, "formation preview layer loads")
	_expect(shader != null and not shader.code.is_empty(), "formation shader loads")
	_expect(shader != null
		and shader.code.contains("filter_linear")
		and not shader.code.contains("filter_linear_mipmap"),
		"formation atlas sampling cannot blend across mipmapped atlas cells")
	_expect(harness != null, "formation harness scene loads")
	_expect(token_harness != null, "production token harness scene loads")
	_expect(paper_shader != null and paper_shader.code.contains(
		"v_local = VERTEX * 2.0;"), "paper fallback uses unit-quad local space")
	if catalog.is_empty():
		_finish()
		return

	_expect(int(catalog.get("schema", 0)) == 1, "visual catalog schema is 1")
	_expect(String(catalog.get("status", "")) == "prototype_art",
		"visual catalog is explicitly marked prototype_art")
	var actions := catalog.get("actions", []) as Array
	var lods := catalog.get("lod", []) as Array
	var bands := catalog.get("headcount_bands", []) as Array
	var prototypes := catalog.get("prototypes", []) as Array
	_expect(actions.size() == 4, "catalog defines four action rows")
	_expect(lods.size() == 3, "catalog defines three LOD levels")
	_expect(bands.size() == 5, "catalog defines five member bands")
	_expect(prototypes.size() == 4, "catalog defines four action prototypes")

	var expected_actions := ["idle", "move", "attack", "hit"]
	for index in actions.size():
		var action := actions[index] as Dictionary
		_expect(String(action.get("id", "")) == expected_actions[index],
			"action row %d is %s" % [index, expected_actions[index]])
		_expect(int(action.get("row", -1)) == index,
			"action %s row index is stable" % String(action.get("id", "")))
		_expect(int(action.get("frames", 0)) == 8,
			"action %s has eight frames" % String(action.get("id", "")))

	var expected_prototypes := ["foot", "mounted", "artillery", "armored"]
	var mapped_units: Dictionary = {}
	for prototype_index in prototypes.size():
		var prototype := prototypes[prototype_index] as Dictionary
		_expect(String(prototype.get("id", "")) == expected_prototypes[prototype_index],
			"prototype row %d is %s" % [prototype_index, expected_prototypes[prototype_index]])
		_expect(int(prototype.get("atlas_row", -1)) == prototype_index,
			"prototype %s atlas row is stable" % String(prototype.get("id", "")))
		var layouts := prototype.get("layouts", []) as Array
		_expect(layouts.size() == 5, "prototype %s has layouts for 1-5 members" %
			String(prototype.get("id", "")))
		for member_count in layouts.size():
			var layout := layouts[member_count] as Array
			_expect(layout.size() == member_count + 1,
				"%s layout %d has %d offsets" %
				[String(prototype.get("id", "")), member_count + 1, member_count + 1])
		for unit_id in prototype.get("available_units", []) as Array:
			var key := String(unit_id)
			_expect(not mapped_units.has(key), "unit %s is mapped once" % key)
			mapped_units[key] = true

	var catalog_units := PackedStringArray()
	for row in military_catalog.get("units", []) as Array:
		catalog_units.append(String((row as Dictionary).get("id", "")))
	_expect(catalog_units.size() == 24, "military catalog still has 24 units")
	_expect(mapped_units.size() == catalog_units.size(),
		"formation mapping covers all 24 units")
	for unit_id in catalog_units:
		_expect(mapped_units.has(unit_id), "mapped unit %s exists in catalog" % unit_id)

	_validate_atlas(catalog)
	_validate_atlas_import()
	_validate_source_manifest()
	if layer_script != null:
		_validate_numeric_contracts(layer_script, lods, bands)
		await _validate_live_layer(layer_script)
	_finish()


func _validate_atlas(catalog: Dictionary) -> void:
	var atlas := catalog.get("atlas", {}) as Dictionary
	var image := Image.load_from_file(ProjectSettings.globalize_path(ATLAS_PATH))
	_expect(image != null and not image.is_empty(), "formation atlas image loads")
	if image == null or image.is_empty():
		return
	_expect(image.get_width() == int(atlas.get("width", -1)) and
		image.get_height() == int(atlas.get("height", -1)),
		"formation atlas dimensions match catalog")
	_expect(image.get_width() == 1024 and image.get_height() == 2048,
		"formation atlas is 1024x2048")
	_expect(image.get_format() == Image.FORMAT_RGBA8,
		"formation atlas decodes as RGBA8")
	var frame_w := int(atlas.get("frame_width", 128))
	var frame_h := int(atlas.get("frame_height", 128))
	for prototype_row in 4:
		for action_row in 4:
			var atlas_row := prototype_row * 4 + action_row
			var hashes: Dictionary = {}
			var bounds: Array[Rect2i] = []
			for frame_index in 8:
				var region := image.get_region(Rect2i(
					frame_index * frame_w,
					atlas_row * frame_h,
					frame_w,
					frame_h
				))
				var used := _alpha_used_rect(region)
				_expect(used.size.x > 8 and used.size.y > 8,
					"atlas cell prototype=%d action=%d frame=%d has art" %
					[prototype_row, action_row, frame_index])
				_expect(used.position.x >= 10 and used.position.y >= 10
					and used.end.x <= frame_w - 10
					and used.end.y <= frame_h - 10,
					"atlas frame has a transparent safety gutter p%d/a%d/f%d: %s" %
					[prototype_row, action_row, frame_index, str(used)])
				_expect(_border_alpha(region) <= ALPHA_THRESHOLD,
					"atlas frame never touches its boundary p%d/a%d/f%d" %
					[prototype_row, action_row, frame_index])
				bounds.append(used)
				hashes[_image_checksum(region)] = true
			_expect(hashes.size() >= 7,
				"atlas animation p%d/a%d has at least seven distinct frames (got %d)" %
				[prototype_row, action_row, hashes.size()])
			_expect(_frame_anchor_is_stable(bounds, frame_w, frame_h),
				"atlas animation p%d/a%d keeps a stable frame anchor" %
				[prototype_row, action_row])


func _validate_source_manifest() -> void:
	var manifest := _load_json(SOURCE_MANIFEST_PATH)
	if manifest.is_empty():
		return
	_expect(int(manifest.get("schema", 0)) == 4,
		"v4 source manifest schema is 4")
	_expect(String(manifest.get("status", "")) == "ready",
		"v4 source manifest build status is ready")
	_expect(bool(manifest.get("runtime_ready", false)),
		"v4 source manifest marks the atlas runtime-ready")
	_expect(String(manifest.get("build_mode", "")) == "strict",
		"v4 source manifest was built in strict mode")
	_expect((manifest.get("missing_sources", []) as Array).is_empty(),
		"v4 source manifest has no missing sources")
	_expect((manifest.get("source_failures", []) as Array).is_empty(),
		"v4 source manifest has no source failures")
	_expect((manifest.get("qc_failures", []) as Array).is_empty(),
		"v4 source manifest has no QC failures")

	var reports := manifest.get("action_reports", []) as Array
	_expect(reports.size() == 16, "v4 source manifest has 16 action reports")
	var seen: Dictionary = {}
	for report_value in reports:
		var report := report_value as Dictionary
		var key := "%s/%s" % [
			String(report.get("prototype", "")),
			String(report.get("action", "")),
		]
		_expect(not seen.has(key), "v4 source report %s is unique" % key)
		seen[key] = true
		var qc := report.get("qc", {}) as Dictionary
		_expect(String(qc.get("status", "")) == "pass",
			"v4 source report %s passed builder QC" % key)
		var grid := report.get("source_grid", {}) as Dictionary
		_expect(int(grid.get("columns", 0)) == SOURCE_SHEET_COLUMNS
			and int(grid.get("rows", 0)) == SOURCE_SHEET_ROWS
			and int(grid.get("frame_count", 0)) == 8,
			"v4 source report %s uses the fixed 4x2x8 grid" % key)
		var runtime := report.get("runtime_registration", {}) as Dictionary
		_expect(not bool(runtime.get("per_frame_recentering", true)),
			"v4 source report %s forbids per-frame recentering" % key)
		_expect(not bool(runtime.get("per_frame_rescaling", true)),
			"v4 source report %s forbids per-frame rescaling" % key)
		if key == "artillery/idle":
			var pair_qc := report.get("pair_registration_qc", {}) as Dictionary
			var allowed_range := float(pair_qc.get(
				"allowed_relative_range_px", 0.0))
			var x_range := float(pair_qc.get("relative_x_range_px", INF))
			var y_range := float(pair_qc.get("relative_y_range_px", INF))
			_expect(String(pair_qc.get("status", "")) == "pass",
				"v4 artillery idle passed dual-gun registration QC")
			_expect(allowed_range > 0.0
				and maxf(x_range, y_range) <= allowed_range,
				"v4 artillery idle keeps both guns within the shared lock range")
		var source := report.get("source", {}) as Dictionary
		var source_name := "%s/%s_%s.png" % [
			SOURCE_SHEET_DIR,
			String(report.get("prototype", "")),
			String(report.get("action", "")),
		]
		_expect(String(source.get("path", "")).ends_with(
			"source/v4/selected/%s_%s.png" % [
				String(report.get("prototype", "")),
				String(report.get("action", "")),
			]),
			"v4 source report %s points at the selected v4 sheet" % key)
		var image := Image.load_from_file(
			ProjectSettings.globalize_path(source_name))
		_expect(image != null and not image.is_empty(),
			"selected v4 source sheet loads: %s" % source_name)
		if image != null and not image.is_empty():
			_expect(image.get_format() == Image.FORMAT_RGBA8,
				"selected v4 source sheet is RGBA: %s" % source_name)
			_expect(image.get_width() == 1792 and image.get_height() == 896,
				"selected v4 source sheet is 1792x896: %s" % source_name)


func _validate_atlas_import() -> void:
	_expect(FileAccess.file_exists(ATLAS_IMPORT_PATH),
		"formation atlas import settings exist")
	if not FileAccess.file_exists(ATLAS_IMPORT_PATH):
		return
	var text := FileAccess.get_file_as_string(ATLAS_IMPORT_PATH)
	_expect(text.contains("mipmaps/generate=false"),
		"formation atlas disables mipmaps so atlas cells cannot bleed together")


func _alpha_used_rect(image: Image) -> Rect2i:
	var min_x := image.get_width()
	var min_y := image.get_height()
	var max_x := -1
	var max_y := -1
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a <= ALPHA_THRESHOLD:
				continue
			min_x = mini(min_x, x)
			min_y = mini(min_y, y)
			max_x = maxi(max_x, x)
			max_y = maxi(max_y, y)
	if max_x < min_x or max_y < min_y:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


func _border_alpha(image: Image) -> float:
	var maximum := 0.0
	for x in image.get_width():
		maximum = maxf(maximum, image.get_pixel(x, 0).a)
		maximum = maxf(maximum, image.get_pixel(x, image.get_height() - 1).a)
	for y in image.get_height():
		maximum = maxf(maximum, image.get_pixel(0, y).a)
		maximum = maxf(maximum, image.get_pixel(image.get_width() - 1, y).a)
	return maximum


func _frame_anchor_is_stable(bounds: Array[Rect2i], frame_w: int,
		frame_h: int) -> bool:
	if bounds.is_empty():
		return false
	var average := Vector2.ZERO
	for used in bounds:
		average += Vector2(used.get_center())
	average /= float(bounds.size())
	var allowed_center_drift := float(mini(frame_w, frame_h)) * 0.18
	var widths: Array[float] = []
	var heights: Array[float] = []
	for used in bounds:
		if used.get_center().distance_to(average) > allowed_center_drift:
			return false
		widths.append(float(used.size.x))
		heights.append(float(used.size.y))
	widths.sort()
	heights.sort()
	var median_width := widths[widths.size() / 2]
	var median_height := heights[heights.size() / 2]
	for used in bounds:
		if float(used.size.x) < median_width * 0.52 \
				or float(used.size.x) > median_width * 1.75:
			return false
		if float(used.size.y) < median_height * 0.52 \
				or float(used.size.y) > median_height * 1.75:
			return false
	return true


func _image_checksum(image: Image) -> int:
	var data := image.get_data()
	var checksum := 2166136261
	for index in range(0, data.size(), 17):
		checksum = ((checksum ^ int(data[index])) * 16777619) & 0x7FFFFFFF
	return checksum


func _validate_numeric_contracts(layer_script: Script, lods: Array, bands: Array) -> void:
	_expect(layer_script.member_count_for_headcount(1, bands) == 1,
		"headcount 1 maps to one member")
	_expect(layer_script.member_count_for_headcount(299, bands) == 1,
		"headcount 299 maps to one member")
	_expect(layer_script.member_count_for_headcount(300, bands) == 2,
		"headcount 300 maps to two members")
	_expect(layer_script.member_count_for_headcount(999, bands) == 2,
		"headcount 999 maps to two members")
	_expect(layer_script.member_count_for_headcount(1000, bands) == 3,
		"headcount 1000 maps to three members")
	_expect(layer_script.member_count_for_headcount(7999, bands) == 4,
		"headcount 7999 maps to four members")
	_expect(layer_script.member_count_for_headcount(8000, bands) == 5,
		"headcount 8000 maps to five members")
	_expect(layer_script.member_count_for_headcount(1000000, bands) == 5,
		"large headcount stays at five members")

	_expect(layer_script.lod_for_zoom(0.2, lods) == 0, "zoom 0.2 selects aggregate LOD")
	_expect(layer_script.lod_for_zoom(0.35, lods) == 1,
		"zoom 0.35 enters representative LOD")
	_expect(layer_script.lod_for_zoom(0.69, lods) == 1,
		"zoom 0.69 remains representative LOD")
	_expect(layer_script.lod_for_zoom(0.70, lods) == 2,
		"zoom 0.70 enters formation LOD")
	_expect(layer_script.lod_for_zoom(1.5, lods) == 2,
		"zoom 1.5 remains formation LOD")

	var weights := [50.0, 30.0, 20.0]
	for members in range(1, 6):
		var buckets: PackedInt32Array = layer_script.allocate_member_buckets(weights, members)
		var total := 0
		var non_zero := 0
		for value in buckets:
			total += value
			if value > 0:
				non_zero += 1
		_expect(total == members, "%d members conserve bucket count" % members)
		_expect(non_zero <= mini(3, members),
			"%d members use at most three unit types" % members)
	var five: PackedInt32Array = layer_script.allocate_member_buckets(weights, 5)
	_expect(five == PackedInt32Array([2, 2, 1]),
		"50/30/20 at five members allocates 2/2/1, got %s" % str(five))
	_expect(is_equal_approx(layer_script.one_shot_member_start(10.0, 0), 10.0),
		"first formation member starts the one-shot action immediately")
	_expect(layer_script.one_shot_member_start(10.0, 4) > 10.0,
		"later formation members are staggered forward in time")


func _validate_live_layer(layer_script: Script) -> void:
	var layer = layer_script.new()
	get_root().add_child(layer)
	await process_frame
	var snapshot: Dictionary = layer.debug_snapshot()
	_expect(int(snapshot.get("prototype_count", 0)) == 4,
		"live preview layer loads four prototypes")
	_expect(int(snapshot.get("visible_instances", 0)) == 60,
		"formation LOD emits 4x(1+2+3+4+5)=60 members")
	layer.set_lod_mode(0)
	_expect(int(layer.debug_snapshot().get("visible_instances", 0)) == 20,
		"aggregate LOD emits one token per sample")
	layer.set_lod_mode(1)
	_expect(int(layer.debug_snapshot().get("visible_instances", 0)) == 20,
		"representative LOD emits one sprite per sample")
	layer.set_action("attack")
	_expect(String(layer.active_action_id()) == "attack",
		"live layer accepts action selection")
	layer.set_paused(true)
	_expect(bool(layer.debug_snapshot().get("paused", false)),
		"live layer pause state is readable")
	layer.set_reduced_motion_override(1)
	_expect(bool(layer.debug_snapshot().get("reduced_motion", false)),
		"live layer reduced-motion override is readable")
	layer.set_heading_degrees(90.0)
	_expect(is_equal_approx(float(layer.heading_degrees()), 90.0),
		"live layer heading rotation is writable without simulation state")
	layer.queue_free()
	await process_frame


func _load_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		_expect(false, "missing JSON %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		_expect(false, "invalid JSON %s" % path)
		return {}
	return parsed as Dictionary


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)


func _finish() -> void:
	print("=== military formation visual test: %d failures ===" % _failures.size())
	quit(0 if _failures.is_empty() else 1)
