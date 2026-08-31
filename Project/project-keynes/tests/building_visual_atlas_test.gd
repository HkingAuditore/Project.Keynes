extends SceneTree

## Guards the authored building atlas contract: the artwork must stay flat,
## strictly top-down, shadow-free, fully populated, and genuinely varied per
## (art era band, archetype, variant) slot. The style critique that motivated
## the authored atlas was "every building looks the same", so tile distinctness
## is asserted rather than assumed.

const LayerScript = preload("res://scripts/rendering/building_visual_layer.gd")
const MANIFEST_PATH := "res://assets/buildings/building_visual_manifest.json"
const ALBEDO_PATH := "res://assets/buildings/generated/building_albedo.png"
const SURFACE_PATH := "res://assets/buildings/generated/building_surface.png"

var _checks := 0
var _failures := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var manifest := _load_manifest()
	if manifest.is_empty():
		_expect("manifest parses", false)
		_finish()
		return
	var columns := int(manifest.get("atlas_columns", 0))
	var rows := int(manifest.get("atlas_rows", 0))
	var tile_size := int(manifest.get("tile_size", 0))
	var variants := int(manifest.get("variant_count", 0))
	var bands: Array = manifest.get("era_bands", [])
	var archetypes: Array = manifest.get("archetypes", [])
	var tiles: Array = manifest.get("tiles", [])

	_expect("variant count matches the runtime profile ABI",
		variants == LayerScript.VISUAL_PROFILE_COUNT)
	_expect("art era bands match the runtime band count",
		bands.size() == LayerScript.ART_ERA_BAND_COUNT)
	_expect("archetype list matches the renderer archetypes",
		archetypes.size() == LayerScript.ARCHETYPE_COUNT)
	_expect("atlas grid holds exactly one slot per tile",
		columns * rows == bands.size() * archetypes.size() * variants)
	_expect("every slot is authored", tiles.size() == columns * rows)
	_expect("artwork carries no baked shadow",
		not bool(manifest.get("baked_shadow", true)))
	_expect("orientation is documented as fixed top-down",
		String(manifest.get("orientation", "")).contains("top-down"))

	var era_map := PackedInt32Array(manifest.get("runtime_era_to_band", PackedInt32Array()))
	_expect("runtime era map covers all eleven eras", era_map.size() == 11)
	var era_map_agrees := era_map.size() == 11
	for era in era_map.size():
		if era_map[era] != LayerScript._art_era_band(era):
			era_map_agrees = false
	_expect("manifest era bands agree with the shader mapping", era_map_agrees)

	var seen := {}
	var index_ok := true
	for entry in tiles:
		var row: Dictionary = entry
		var era := bands.find(String(row.get("era_band", "")))
		var archetype := archetypes.find(String(row.get("archetype", "")))
		var variant := int(row.get("variant", -1))
		var index := int(row.get("index", -1))
		if era < 0 or archetype < 0 or variant < 0 or variant >= variants:
			index_ok = false
			continue
		if index != era * archetypes.size() * variants + archetype * variants + variant:
			index_ok = false
		if index != int(row.get("row", -1)) * columns + int(row.get("column", -1)):
			index_ok = false
		seen[index] = true
	_expect("tile indices follow the documented formula and grid order", index_ok)
	_expect("no slot is duplicated or missing", seen.size() == tiles.size())

	var albedo := ResourceLoader.load(ALBEDO_PATH, "Texture2D") as Texture2D
	var surface := ResourceLoader.load(SURFACE_PATH, "Texture2D") as Texture2D
	_expect("albedo atlas imports", albedo != null)
	_expect("surface atlas imports", surface != null)
	if albedo == null or surface == null:
		_finish()
		return
	var expected := Vector2(columns * tile_size, rows * tile_size)
	_expect("albedo atlas matches the manifest geometry", albedo.get_size() == expected)
	_expect("surface atlas matches the manifest geometry", surface.get_size() == expected)

	var albedo_image := albedo.get_image()
	var surface_image := surface.get_image()
	if albedo_image == null or surface_image == null:
		_expect("atlas images are readable", false)
		_finish()
		return
	albedo_image.decompress()
	surface_image.decompress()

	var full_signatures := {}
	var geometry_per_band := {}
	var min_coverage := 1.0
	var empty_tiles := 0
	var shadow_suspects := 0
	var roof_snow_ok := true
	var slots_per_band := archetypes.size() * variants
	for index in tiles.size():
		var column := index % columns
		var row_index := index / columns
		var origin := Vector2i(column * tile_size, row_index * tile_size)
		var stats := _tile_stats(albedo_image, surface_image, origin, tile_size)
		var coverage := float(stats.coverage)
		min_coverage = minf(min_coverage, coverage)
		if coverage < 0.06:
			empty_tiles += 1
		# A baked drop shadow would show up as a wide, low-alpha, dark skirt
		# outside the body. Authored tiles must leave that to the shadow pass.
		if float(stats.soft_dark_fringe) > 0.05:
			shadow_suspects += 1
		if float(stats.roof_snow_max) < 0.5:
			roof_snow_ok = false
		full_signatures[String(stats.signature)] = true
		var band := index / slots_per_band
		if not geometry_per_band.has(band):
			geometry_per_band[band] = {}
		geometry_per_band[band][String(stats.geometry)] = true

	_expect("every authored tile has a readable silhouette", empty_tiles == 0)
	_expect("silhouette coverage stays inside the tile budget", min_coverage > 0.05)
	_expect("no tile bakes a drop shadow into the artwork", shadow_suspects == 0)
	_expect("every tile exposes up-facing snow surface", roof_snow_ok)
	# Within one era band the player sees these side by side, so silhouettes
	# must differ on their own without leaning on the era palette.
	var band_geometry_ok := geometry_per_band.size() == bands.size()
	for band in geometry_per_band:
		if (geometry_per_band[band] as Dictionary).size() != slots_per_band:
			band_geometry_ok = false
	_expect("each era band has %d distinct silhouettes" % slots_per_band, band_geometry_ok)
	_expect("all %d slots are visually distinct" % tiles.size(),
		full_signatures.size() == tiles.size())

	var flatness := _flatness(albedo_image)
	_expect("artwork stays flat rather than gradient-shaded (%.3f distinct tone ratio)"
		% flatness, flatness < 0.06)

	# The layer must actually adopt the authored atlas, not silently keep the
	# procedural fallback that the style critique was about.
	var layer: BuildingVisualLayer = LayerScript.new()
	get_root().add_child(layer)
	var layer_diagnostics := layer.diagnostics()
	_expect("layer adopts the authored atlas (%s)"
		% String(layer_diagnostics.get("authored_atlas_reason", "")),
		bool(layer_diagnostics.get("authored_atlas", false)))
	_expect("layer sees every authored tile",
		int(layer_diagnostics.get("authored_atlas_tiles", 0)) == tiles.size())
	layer.queue_free()
	_finish()


func _load_manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return {}
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	return parsed as Dictionary if parsed is Dictionary else {}


func _tile_stats(albedo: Image, surface: Image, origin: Vector2i, size: int) -> Dictionary:
	var opaque := 0
	var fringe := 0
	var roof_snow_max := 0.0
	var colour_sum := Vector3.ZERO
	var rows_fill := PackedFloat32Array()
	var columns_fill := PackedFloat32Array()
	rows_fill.resize(8)
	rows_fill.fill(0.0)
	columns_fill.resize(8)
	columns_fill.fill(0.0)
	for y in size:
		for x in size:
			var albedo_px := albedo.get_pixel(origin.x + x, origin.y + y)
			if albedo_px.a > 0.85:
				opaque += 1
				rows_fill[clampi(y * 8 / size, 0, 7)] += 1.0
				columns_fill[clampi(x * 8 / size, 0, 7)] += 1.0
				colour_sum += Vector3(albedo_px.r, albedo_px.g, albedo_px.b)
				var surface_px := surface.get_pixel(origin.x + x, origin.y + y)
				roof_snow_max = maxf(roof_snow_max, surface_px.r)
			elif albedo_px.a > 0.10 and albedo_px.a < 0.70 \
					and albedo_px.get_luminance() < 0.22:
				fringe += 1
	var pixels := float(size * size)
	var occupied := maxf(1.0, float(opaque))
	var geometry := PackedStringArray()
	for band in rows_fill.size():
		geometry.append(String.num(rows_fill[band] / occupied, 2))
	for band in columns_fill.size():
		geometry.append(String.num(columns_fill[band] / occupied, 2))
	var geometry_key := ",".join(geometry)
	var mean := colour_sum / occupied
	return {
		"coverage": float(opaque) / pixels,
		"soft_dark_fringe": float(fringe) / pixels,
		"roof_snow_max": roof_snow_max,
		"geometry": geometry_key,
		"signature": "%s|%s" % [geometry_key,
			"%.3f,%.3f,%.3f" % [mean.x, mean.y, mean.z]],
	}


## Flat art reuses a small palette. A gradient-shaded or photographic tile would
## instead spread colour over a very large number of distinct tones.
func _flatness(albedo: Image) -> float:
	var tones := {}
	var samples := 0
	var width := albedo.get_width()
	var height := albedo.get_height()
	for y in range(0, height, 3):
		for x in range(0, width, 3):
			var px := albedo.get_pixel(x, y)
			if px.a < 0.85:
				continue
			samples += 1
			var key := (int(px.r * 31.0) << 10) | (int(px.g * 31.0) << 5) | int(px.b * 31.0)
			tones[key] = true
	return float(tones.size()) / maxf(1.0, float(samples))


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if condition:
		print("[ok] %s" % label)
	else:
		_failures += 1
		printerr("[fail] %s" % label)


func _finish() -> void:
	print("building visual atlas checks: %d, failures: %d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
