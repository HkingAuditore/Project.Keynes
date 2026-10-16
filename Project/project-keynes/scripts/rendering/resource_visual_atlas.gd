class_name ResourceVisualAtlas
extends RefCounted

# Dual-channel pre-baked material, micro-normal, height relief & anatomical/mineral
# profile atlas for all 51 resource and species styles.
# Built once per process and cached statically so ResourceVisualLayer.configure()
# remains sub-millisecond on repeated calls.

const WIDTH := 128
const HEIGHT := 64

static var _cached_albedo_mat: ImageTexture = null
static var _cached_normal_height: ImageTexture = null
static var _cached_style_count := 0

static func get_or_build(styles: Array[Dictionary], overrides: Dictionary = {}) -> Dictionary:
	if _cached_albedo_mat != null and _cached_normal_height != null and _cached_style_count == styles.size() and overrides.is_empty():
		return {
			"albedo_mat": _cached_albedo_mat,
			"normal_height": _cached_normal_height,
		}
	var albedo_bytes := PackedByteArray()
	var normal_bytes := PackedByteArray()
	albedo_bytes.resize(WIDTH * HEIGHT * 4)
	normal_bytes.resize(WIDTH * HEIGHT * 4)

	for row in styles.size():
		if row >= HEIGHT:
			break
		var entry: Dictionary = styles[row]
		var id := String(entry.get("id", ""))
		var override: Dictionary = overrides.get(id, {})
		var base_col: Color = override.get("color", entry.get("color", Color(0.5, 0.5, 0.5)))
		var secondary_col: Color = entry.get("secondary_color", base_col.darkened(0.22))
		var accent_col: Color = entry.get("accent_color", base_col.lightened(0.28))
		var spec_strength := float(entry.get("specular", 0.18))
		var metallic := float(entry.get("metallic", 0.0))
		var roughness := float(entry.get("roughness", 0.65))
		var family := int(entry.get("family", 0))
		var form := int(entry.get("form", 0))
		var sub_style := int(entry.get("sub_style", 0))

		for x in WIDTH:
			var u := (float(x) + 0.5) / float(WIDTH)
			var idx := (row * WIDTH + x) * 4

			# Smooth multi-frequency organic wave for coat spots, mineral veins, bark & grain
			var w1 := sin(u * TAU * 3.0 + float(row) * 1.37)
			var w2 := cos(u * TAU * 7.0 + float(row) * 2.91)
			var w3 := sin(u * TAU * 15.0 + float(row) * 4.13)
			var pattern := clampf(0.5 + 0.28 * w1 + 0.15 * w2 + 0.07 * w3, 0.0, 1.0)

			var col := base_col
			var spec := spec_strength
			var nx := 0.0
			var ny := 0.0
			var h_relief := 0.5
			var sdf_mod := 0.5

			if family == 1:
				# Livestock coat / fleece / hide micro-texture & anatomical profile
				var spot_mask := smoothstep(0.42, 0.64, pattern)
				if form == 11: # Cattle piebald / rich hide patches
					col = base_col.lerp(secondary_col, spot_mask * 0.85)
					col = col.lerp(accent_col, smoothstep(0.75, 0.92, pattern) * 0.35)
				elif form == 9: # Sheep fleece scalloped wool curls
					var curl := 0.5 + 0.5 * sin(u * TAU * 11.0 + w1 * 1.5)
					col = secondary_col.lerp(base_col.lightened(0.12), curl)
					nx = cos(u * TAU * 11.0) * 0.35
					ny = sin(u * TAU * 7.0) * 0.35
					h_relief = 0.45 + 0.45 * curl
				elif form == 12: # Pig warm pink-roan skin & mud-shaded belly
					col = base_col.lerp(secondary_col, (1.0 - u) * 0.45 + spot_mask * 0.25)
					spec = 0.32
				elif form == 8: # Horse sleek muscular sheen & dapple
					col = base_col.lerp(secondary_col, spot_mask * 0.40).lerp(accent_col, pow(pattern, 3.0) * 0.30)
					spec = 0.38
				elif form == 14: # Yak shaggy layered highland coat
					var strand := 0.5 + 0.5 * sin(u * TAU * 16.0 + w2)
					col = base_col.lerp(secondary_col, strand * 0.65)
					nx = sin(u * TAU * 16.0) * 0.42
					h_relief = 0.35 + 0.50 * strand
				else: # Goat / Camel warm coat gradations
					col = base_col.lerp(secondary_col, spot_mask * 0.50).lerp(accent_col, u * 0.25)
				sdf_mod = clampf(0.5 + 0.35 * sin(u * TAU * 2.0 + float(sub_style)), 0.0, 1.0)
			elif family == 0:
				# Crops, botanical foliage, blossoms, bolls, bark & timber rings
				var leaf_vein := 0.5 + 0.5 * sin(u * TAU * 9.0 + w1)
				col = secondary_col.lerp(base_col, smoothstep(0.2, 0.8, pattern))
				col = col.lerp(accent_col, smoothstep(0.62, 0.90, leaf_vein) * 0.65)
				nx = cos(u * TAU * 9.0) * 0.28
				ny = sin(u * TAU * 5.0) * 0.25
				h_relief = clampf(0.35 + 0.55 * pattern, 0.0, 1.0)
				sdf_mod = leaf_vein
			else:
				# Geology, ores, crystals, soils, oil & gas
				var vein_band := smoothstep(0.52, 0.76, pattern)
				var crystal_facet := 1.0 if (0.5 + 0.5 * sin(u * TAU * 8.0 + float(row))) >= 0.66 else 0.0
				col = secondary_col.lerp(base_col, smoothstep(0.18, 0.72, pattern))
				col = col.lerp(accent_col, maxf(vein_band * 0.85, crystal_facet * metallic * 0.75))
				spec = clampf(spec_strength + vein_band * metallic * 0.45 + crystal_facet * 0.25, 0.0, 1.0)
				nx = clampf(w1 * 0.45 + (crystal_facet - 0.5) * 0.40, -0.95, 0.95)
				ny = clampf(w2 * 0.45, -0.95, 0.95)
				h_relief = clampf(0.25 + 0.55 * pattern + 0.20 * crystal_facet, 0.0, 1.0)
				sdf_mod = clampf(0.5 + 0.4 * (1.0 - roughness) + 0.1 * w3, 0.0, 1.0)

			albedo_bytes[idx + 0] = clampi(roundi(col.r * 255.0), 0, 255)
			albedo_bytes[idx + 1] = clampi(roundi(col.g * 255.0), 0, 255)
			albedo_bytes[idx + 2] = clampi(roundi(col.b * 255.0), 0, 255)
			albedo_bytes[idx + 3] = clampi(roundi(spec * 255.0), 0, 255)

			normal_bytes[idx + 0] = clampi(roundi((nx * 0.5 + 0.5) * 255.0), 0, 255)
			normal_bytes[idx + 1] = clampi(roundi((ny * 0.5 + 0.5) * 255.0), 0, 255)
			normal_bytes[idx + 2] = clampi(roundi(h_relief * 255.0), 0, 255)
			normal_bytes[idx + 3] = clampi(roundi(sdf_mod * 255.0), 0, 255)

	var albedo_img := Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8, albedo_bytes)
	var normal_img := Image.create_from_data(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8, normal_bytes)
	var albedo_tex := ImageTexture.create_from_image(albedo_img)
	var normal_tex := ImageTexture.create_from_image(normal_img)

	if overrides.is_empty():
		_cached_albedo_mat = albedo_tex
		_cached_normal_height = normal_tex
		_cached_style_count = styles.size()

	return {
		"albedo_mat": albedo_tex,
		"normal_height": normal_tex,
	}
