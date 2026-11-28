class_name ForestCanopyMesh
extends RefCounted

## Builds static per-chunk canopy ArrayMeshes from a baked coverage page.
##
## Supports two geometry modes sharing the exact same coverage field for A/B
## comparison:
##   - MODE_COARSE_MERGED (default): divides the 16x16 chunk into 8x8 coarse
##     cells (2x2 hexes each), skips empty cells, and merges horizontal runs
##     into minimal rectangles (same strategy as TerrainCoverageMesh).
##   - MODE_CHUNK_QUAD (baseline): emits a single quad covering the whole chunk
##     whenever the chunk contains any forest.

const MODE_COARSE_MERGED := 0
const MODE_CHUNK_QUAD := 1

const COARSE_SUBDIV := 8
const COVERAGE_BYTE_THRESHOLD := 5


static func build_from_coverage(
		chunk_rect: Rect2,
		coverage_bytes: PackedByteArray,
		page_texels: int,
		halo_texels: int,
		mode: int = MODE_COARSE_MERGED,
		margin_world: float = 0.0) -> Dictionary:
	var t0_us := Time.get_ticks_usec()
	var inner_texels := page_texels - halo_texels * 2
	if inner_texels <= 0 or coverage_bytes.size() < page_texels * page_texels * 4:
		return _empty_result(mode, t0_us, false)

	var uv_min := float(halo_texels) / float(page_texels)
	var uv_span := float(inner_texels) / float(page_texels)

	var rects: Array[Rect2] = []
	var active_coarse := 0
	var total_coarse := COARSE_SUBDIV * COARSE_SUBDIV

	if mode == MODE_CHUNK_QUAD:
		if _page_has_interior_forest(coverage_bytes, page_texels, halo_texels, inner_texels):
			rects.append(Rect2(Vector2.ZERO, Vector2.ONE))
			active_coarse = total_coarse
	else:
		var occupied := PackedByteArray()
		occupied.resize(total_coarse)
		var step := float(inner_texels) / float(COARSE_SUBDIV)
		for cy in range(COARSE_SUBDIV):
			var py0 := clampi(halo_texels + int(floor(float(cy) * step)) - 1, 0, page_texels - 1)
			var py1 := clampi(halo_texels + int(ceil(float(cy + 1) * step)) + 1, 0, page_texels)
			for cx in range(COARSE_SUBDIV):
				var px0 := clampi(halo_texels + int(floor(float(cx) * step)) - 1, 0, page_texels - 1)
				var px1 := clampi(halo_texels + int(ceil(float(cx + 1) * step)) + 1, 0, page_texels)
				if _region_has_forest(coverage_bytes, page_texels, px0, py0, px1, py1):
					occupied[cy * COARSE_SUBDIV + cx] = 1

		# Dilate occupied coarse cells by 1 ring (8-neighbourhood) so ragged
		# crown silhouettes never get hard-clipped by rectangular mesh edges.
		var dilated := occupied.duplicate()
		for cy in range(COARSE_SUBDIV):
			for cx in range(COARSE_SUBDIV):
				if occupied[cy * COARSE_SUBDIV + cx] == 0:
					continue
				for dy in range(-1, 2):
					var ny := cy + dy
					if ny < 0 or ny >= COARSE_SUBDIV:
						continue
					for dx in range(-1, 2):
						var nx := cx + dx
						if nx >= 0 and nx < COARSE_SUBDIV:
							dilated[ny * COARSE_SUBDIV + nx] = 1
		occupied = dilated
		for cell_flag in occupied:
			if cell_flag != 0:
				active_coarse += 1

		# Merge horizontal runs per row into minimal rectangles.
		var inv_sub := 1.0 / float(COARSE_SUBDIV)
		for cy in range(COARSE_SUBDIV):
			var run_start := -1
			for cx in range(COARSE_SUBDIV + 1):
				var is_on := cx < COARSE_SUBDIV and occupied[cy * COARSE_SUBDIV + cx] != 0
				if is_on and run_start < 0:
					run_start = cx
				elif not is_on and run_start >= 0:
					rects.append(Rect2(
						float(run_start) * inv_sub,
						float(cy) * inv_sub,
						float(cx - run_start) * inv_sub,
						inv_sub
					))
					run_start = -1

	if rects.is_empty():
		return _empty_result(mode, t0_us, true)

	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var quad_count := rects.size()
	verts.resize(quad_count * 4)
	uvs.resize(quad_count * 4)
	indices.resize(quad_count * 6)

	var covered_norm_area := 0.0
	var pad_u := margin_world / maxf(chunk_rect.size.x, 1.0)
	var pad_v := margin_world / maxf(chunk_rect.size.y, 1.0)
	var max_pad := float(halo_texels) / float(inner_texels) * 0.75
	pad_u = clampf(pad_u, 0.0, max_pad)
	pad_v = clampf(pad_v, 0.0, max_pad)

	for i in range(quad_count):
		var r := rects[i]
		covered_norm_area += r.size.x * r.size.y
		var x0 := r.position.x - pad_u
		var y0 := r.position.y - pad_v
		var x1 := r.end.x + pad_u
		var y1 := r.end.y + pad_v

		var wx0 := chunk_rect.position.x + x0 * chunk_rect.size.x
		var wy0 := chunk_rect.position.y + y0 * chunk_rect.size.y
		var wx1 := chunk_rect.position.x + x1 * chunk_rect.size.x
		var wy1 := chunk_rect.position.y + y1 * chunk_rect.size.y

		var u0 := uv_min + x0 * uv_span
		var v0 := uv_min + y0 * uv_span
		var u1 := uv_min + x1 * uv_span
		var v1 := uv_min + y1 * uv_span

		var vb := i * 4
		verts[vb] = Vector2(wx0, wy0)
		verts[vb + 1] = Vector2(wx1, wy0)
		verts[vb + 2] = Vector2(wx1, wy1)
		verts[vb + 3] = Vector2(wx0, wy1)

		uvs[vb] = Vector2(u0, v0)
		uvs[vb + 1] = Vector2(u1, v0)
		uvs[vb + 2] = Vector2(u1, v1)
		uvs[vb + 3] = Vector2(u0, v1)

		var ib := i * 6
		indices[ib] = vb
		indices[ib + 1] = vb + 1
		indices[ib + 2] = vb + 2
		indices[ib + 3] = vb
		indices[ib + 4] = vb + 2
		indices[ib + 5] = vb + 3

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var elapsed_ms := float(Time.get_ticks_usec() - t0_us) / 1000.0
	return {
		"ok": true,
		"empty": false,
		"mode": mode,
		"mesh": mesh,
		"quad_count": quad_count,
		"tri_count": quad_count * 2,
		"active_coarse": active_coarse,
		"total_coarse": total_coarse,
		"covered_area_ratio": clampf(covered_norm_area, 0.0, 1.0),
		"build_ms": elapsed_ms,
	}


static func build_shadow_receiver_quad(chunk_rect: Rect2, page_texels: int, halo_texels: int) -> ArrayMesh:
	var inner_texels := page_texels - halo_texels * 2
	var uv_min := float(halo_texels) / float(page_texels)
	var uv_max := float(halo_texels + inner_texels) / float(page_texels)

	var verts := PackedVector2Array([
		Vector2(chunk_rect.position.x, chunk_rect.position.y),
		Vector2(chunk_rect.end.x, chunk_rect.position.y),
		Vector2(chunk_rect.end.x, chunk_rect.end.y),
		Vector2(chunk_rect.position.x, chunk_rect.end.y),
	])
	var uvs := PackedVector2Array([
		Vector2(uv_min, uv_min),
		Vector2(uv_max, uv_min),
		Vector2(uv_max, uv_max),
		Vector2(uv_min, uv_max),
	])
	var indices := PackedInt32Array([0, 1, 2, 0, 2, 3])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _page_has_interior_forest(
		bytes: PackedByteArray, page_texels: int, halo: int, inner: int) -> bool:
	return _region_has_forest(bytes, page_texels, halo, halo, halo + inner, halo + inner)


static func _region_has_forest(
		bytes: PackedByteArray, page_texels: int,
		x0: int, y0: int, x1: int, y1: int) -> bool:
	for py in range(y0, y1):
		var row := py * page_texels
		for px in range(x0, x1):
			if int(bytes[(row + px) * 4]) >= COVERAGE_BYTE_THRESHOLD:
				return true
	return false


static func _empty_result(mode: int, t0_us: int, ok: bool) -> Dictionary:
	return {
		"ok": ok,
		"empty": true,
		"mode": mode,
		"mesh": null,
		"quad_count": 0,
		"tri_count": 0,
		"active_coarse": 0,
		"total_coarse": COARSE_SUBDIV * COARSE_SUBDIV,
		"covered_area_ratio": 0.0,
		"build_ms": float(Time.get_ticks_usec() - t0_us) / 1000.0,
	}
