class_name ForestCanopyCityMask
extends RefCounted

## Per-chunk R8 city footprint mask for forest canopy and tree shadows.
##
## Consumes only player-known settlement core buckets (from
## BuildingVisualIntelCache), so hidden construction under fog of war never
## alters visible forest edges or tree shadows. Updates are strictly localised
## to affected chunk pages and never rebuild static forest meshes.

const CanopyField = preload("res://scripts/rendering/forest/forest_canopy_field.gd")

const SETTLEMENT_BUILDING_SPREAD_MIN := 0.24
const SETTLEMENT_BUILDING_SPREAD_MAX := 0.44
const SETTLEMENT_BUILDING_SCALE_MIN := 0.68
const SETTLEMENT_BUILDING_SCALE_MAX := 1.02
const SETTLEMENT_OUTER_RING_FACTOR := 1.08
const SETTLEMENT_ART_HALF_WIDTH := 0.22
const SETTLEMENT_BUILDING_VISUAL_SCALE := 0.85
const EDGE_FEATHER_HEX := 0.16

var _field: CanopyField = null
var _map: MapData = null
var _hex_size: float = 32.0
var _core_buckets: PackedByteArray = PackedByteArray()
var _prev_core_buckets: PackedByteArray = PackedByteArray()

# chunk_key (Vector2i) -> {image: Image, texture: ImageTexture, revision: int, non_zero: bool}
var _pages: Dictionary = {}
var _revision: int = 0
var _total_page_updates: int = 0
var _total_upload_bytes: int = 0


func configure(field: CanopyField, map: MapData, hex_size: float) -> void:
	_field = field
	_map = map
	_hex_size = maxf(hex_size, 1.0)
	_core_buckets = PackedByteArray()
	_prev_core_buckets = PackedByteArray()
	_pages.clear()
	_revision = 0
	_total_page_updates = 0
	_total_upload_bytes = 0


func revision() -> int:
	return _revision


func diagnostics() -> Dictionary:
	return {
		"revision": _revision,
		"resident_pages": _pages.size(),
		"total_page_updates": _total_page_updates,
		"total_upload_bytes": _total_upload_bytes,
	}


func settlement_core_radius(bucket: int) -> float:
	if bucket <= 0:
		return 0.0
	var density := clampf(float(mini(15, bucket)) / 15.0, 0.0, 1.0)
	var spread := lerpf(SETTLEMENT_BUILDING_SPREAD_MIN, SETTLEMENT_BUILDING_SPREAD_MAX, density)
	var scale := lerpf(SETTLEMENT_BUILDING_SCALE_MIN, SETTLEMENT_BUILDING_SCALE_MAX, density)
	return (SETTLEMENT_OUTER_RING_FACTOR * spread
		+ SETTLEMENT_ART_HALF_WIDTH * scale * SETTLEMENT_BUILDING_VISUAL_SCALE) * _hex_size


func set_core_buckets(buckets: PackedByteArray, changed_cells: PackedInt32Array = PackedInt32Array()) -> Array[Vector2i]:
	_prev_core_buckets = _core_buckets.duplicate()
	_core_buckets = buckets.duplicate()
	_revision += 1

	var affected: Array[Vector2i] = []
	if _field == null or _map == null or _pages.is_empty():
		return affected

	if changed_cells.is_empty():
		for key in _pages.keys():
			affected.append(key)
	else:
		var seen := {}
		var wrap_p := _field.wrap_period_x()
		var feather := EDGE_FEATHER_HEX * _hex_size
		var chunk_size := _field.chunk_world_size()
		var halo_world := float(CanopyField.HALO_TEXELS) / float(CanopyField.CHUNK_TEXELS) * chunk_size
		var bounds := _field.world_bounds()
		var grid := _field.chunk_grid_dimensions()

		var cell_total := _map.cell_count()
		for raw_idx in changed_cells:
			var idx := int(raw_idx)
			if idx < 0 or idx >= cell_total:
				continue
			var old_b := int(_prev_core_buckets[idx]) if idx < _prev_core_buckets.size() else 0
			var new_b := int(_core_buckets[idx]) if idx < _core_buckets.size() else 0
			var max_r := maxf(settlement_core_radius(old_b), settlement_core_radius(new_b)) + feather + halo_world
			if max_r <= 0.0:
				continue
			var cell = _map.cell_at(idx)
			if cell == null:
				continue
			var center := HexUtils.cube_to_world(int(cell.q), int(cell.r), _hex_size)
			if wrap_p > 0.001:
				center = _field.canonicalize_world_pos(center)
			var cx0 := int(floor((center.x - max_r - bounds.position.x) / chunk_size))
			var cx1 := int(floor((center.x + max_r - bounds.position.x) / chunk_size))
			var cy0 := clampi(int(floor((center.y - max_r - bounds.position.y) / chunk_size)), 0, grid.y - 1)
			var cy1 := clampi(int(floor((center.y + max_r - bounds.position.y) / chunk_size)), 0, grid.y - 1)
			for cy in range(cy0, cy1 + 1):
				for cx in range(cx0, cx1 + 1):
					var norm_cx := posmod(cx, grid.x) if wrap_p > 0.001 else clampi(cx, 0, grid.x - 1)
					var key := Vector2i(norm_cx, cy)
					if _pages.has(key) and not seen.has(key):
						seen[key] = true
						affected.append(key)

	for key in affected:
		_bake_page_into(key)
	return affected


func get_or_create_page(chunk_key: Vector2i) -> Dictionary:
	if _pages.has(chunk_key):
		var existing: Dictionary = _pages[chunk_key]
		if int(existing.get("revision", -1)) == _revision:
			return existing
	return _bake_page_into(chunk_key)


func evict_page(chunk_key: Vector2i) -> void:
	_pages.erase(chunk_key)


func _bake_page_into(chunk_key: Vector2i) -> Dictionary:
	var page_n := CanopyField.PAGE_TEXELS
	var halo_n := CanopyField.HALO_TEXELS
	var chunk_n := CanopyField.CHUNK_TEXELS
	var bytes := PackedByteArray()
	bytes.resize(page_n * page_n)

	var non_zero := false
	if _field != null and _map != null and not _core_buckets.is_empty():
		var rect := _field.chunk_rect(chunk_key.x, chunk_key.y)
		var chunk_size := _field.chunk_world_size()
		var texel_world := chunk_size / float(chunk_n)
		var halo_world := float(halo_n) * texel_world
		var feather := EDGE_FEATHER_HEX * _hex_size
		var wrap_p := _field.wrap_period_x()
		var expanded := rect.grow(halo_world + settlement_core_radius(15) + feather)

		# Collect active settlement circles intersecting this chunk + halo.
		var discs: Array[Vector3] = []
		var count := mini(_core_buckets.size(), _map.cell_count())
		for i in range(count):
			var b := int(_core_buckets[i])
			if b <= 0:
				continue
			var r := settlement_core_radius(b)
			if r <= 0.0:
				continue
			var cell = _map.cell_at(i)
			if cell == null:
				continue
			var c := HexUtils.cube_to_world(int(cell.q), int(cell.r), _hex_size)
			if wrap_p > 0.001:
				c = HexUtils.nearest_display_world(c, rect.get_center().x, wrap_p)
			if expanded.has_point(c):
				discs.append(Vector3(c.x, c.y, r))

		if not discs.is_empty():
			for py in range(page_n):
				var wy := rect.position.y + (float(py - halo_n) + 0.5) * texel_world
				var row := py * page_n
				for px in range(page_n):
					var wx := rect.position.x + (float(px - halo_n) + 0.5) * texel_world
					var mask_v := 0.0
					for d in discs:
						var dist := Vector2(wx - d.x, wy - d.y).length()
						var m := 1.0 - smoothstep(d.z - feather, d.z + feather, dist)
						if m > mask_v:
							mask_v = m
					if mask_v > 0.004:
						bytes[row + px] = clampi(int(round(mask_v * 255.0)), 0, 255)
						non_zero = true

	var img := Image.create_from_data(page_n, page_n, false, Image.FORMAT_R8, bytes)
	var entry: Dictionary = _pages.get(chunk_key, {})
	var tex: ImageTexture = entry.get("texture", null)
	if tex == null:
		tex = ImageTexture.create_from_image(img)
	else:
		tex.update(img)

	entry = {
		"image": img,
		"texture": tex,
		"bytes": bytes,
		"revision": _revision,
		"non_zero": non_zero,
	}
	_pages[chunk_key] = entry
	_total_page_updates += 1
	_total_upload_bytes += bytes.size()
	return entry
