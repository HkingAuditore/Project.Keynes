extends SceneTree

const CoverageMesh = preload("res://scripts/rendering/terrain_coverage_mesh.gd")
const FogCoverage = preload("res://scripts/rendering/fog_terrain_coverage.gd")
const FogMesh = preload("res://scripts/rendering/terrain_fog_mesh.gd")

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_check_rectangles()
	_check_fog_coverage()
	_check_partial_mesh()
	print("terrain draw coverage: %d checks, %d failures" % [_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _check_rectangles() -> void:
	var mask := PackedByteArray([1, 1, 0, 1, 1, 0, 0, 1, 1, 1])
	var offsets := PackedFloat32Array([-72.0, 0.0, 72.0])
	var result := CoverageMesh._emit_mesh(mask, 5, 2, 0.0, -2.0, 72.0, 19.0, 16.0, offsets)
	_expect(result.ok and result.blocks == 7, "merging preserves the coverage block count")
	_expect(result.triangles == 18, "three runs, two triangles each, three wrap copies")
	var arrays: Array = result.mesh.surface_get_arrays(0)
	var vertices: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	_expect(indices.size() == result.triangles * 3, "stats report actual index count")
	var runs: Array[Rect2] = [
		Rect2(0.0, -2.0, 32.0, 16.0),
		Rect2(48.0, -2.0, 24.0, 16.0),
		Rect2(32.0, 14.0, 40.0, 3.0),
	]
	for copy in range(offsets.size()):
		for run in range(runs.size()):
			var rect := runs[run]
			rect.position.x += offsets[copy]
			var index := 4 * (copy * runs.size() + run)
			_expect(vertices[index] == rect.position and vertices[index + 2] == rect.end,
				"run %d/%d preserves the hole and clipped edge" % [copy, run])
	var empty := CoverageMesh._emit_mesh(PackedByteArray([0]), 1, 1, 0.0, 0.0,
		16.0, 16.0, 16.0, PackedFloat32Array([0.0]))
	_expect(empty.triangles == 0 and empty.mesh.get_surface_count() == 0, "empty layer submits no mesh")


func _check_fog_coverage() -> void:
	const DIMS := Vector2i(16, 12)
	const HEX_SIZE := 22.0
	var aux := PackedByteArray()
	aux.resize(DIMS.x * DIMS.y * 4)
	var center := HexUtils.cube_to_world(3, 6, HEX_SIZE)
	var view := Rect2(center - Vector2(15.0, 15.0), Vector2(30.0, 30.0))
	var target := (6 * DIMS.x + 6) * 4
	aux[target] = 12
	aux[target + 1] = 255
	_expect(FogCoverage.new(aux, DIMS).covers(view, HEX_SIZE),
		"opaque fog accepts k=12 and ignores the water depth channel")
	aux[target] = 13
	_expect(not FogCoverage.new(aux, DIMS).covers(view, HEX_SIZE),
		"one partially transparent cell blocks skipping the ground")
	aux[target] = 0
	aux[(6 * DIMS.x + 8) * 4] = 255
	_expect(not FogCoverage.new(aux, DIMS).covers(view, HEX_SIZE),
		"a possible sample beyond the screen edge keeps the terrain")
	aux[(6 * DIMS.x + 8) * 4] = 0
	aux[(6 * DIMS.x + 15) * 4] = 255
	var coverage = FogCoverage.new(aux, DIMS)
	_expect(coverage.covers(view, HEX_SIZE), "an explored cell outside the candidate range is safe")
	var seam := Rect2(-24.0, center.y - 15.0, 48.0, 30.0)
	_expect(not coverage.covers(seam, HEX_SIZE), "the west edge can sample the last column")
	seam.position.x += HexUtils.wrap_period_x(DIMS.x, HEX_SIZE)
	_expect(not coverage.covers(seam, HEX_SIZE), "the east copy uses the same visibility bytes")
	_expect(coverage.covers(Rect2(0.0, -160.0, 30.0, 30.0), HEX_SIZE),
		"north padding beyond the candidate range is opaque")
	_expect(not FogCoverage.new(PackedByteArray(), DIMS).covers(view, HEX_SIZE),
		"until publication provides a complete table, draw the terrain")


func _check_partial_mesh() -> void:
	var vertices := PackedVector2Array([
		Vector2(-16.0, 0.0), Vector2(112.0, 0.0),
		Vector2(112.0, 16.0), Vector2(-16.0, 16.0),
	])
	var regions: Array[Rect2] = [
		Rect2(-32.0, -32.0, 64.0, 64.0),
		Rect2(80.0, 0.0, 64.0, 64.0),
	]
	var mesh := FogMesh.clip(vertices, regions)
	_expect(mesh.get_surface_count() == 1, "the exposed regions share one mesh")
	var arrays := mesh.surface_get_arrays(0)
	var kept: PackedVector2Array = arrays[Mesh.ARRAY_VERTEX]
	_expect(kept.size() == 8 and arrays[Mesh.ARRAY_INDEX].size() == 12,
		"one terrain quad yields two disjoint draw quads")
	_expect(kept[0] == Vector2(-16.0, 0.0) and kept[2] == Vector2(32.0, 16.0)
		and kept[4] == Vector2(80.0, 0.0) and kept[6] == Vector2(112.0, 16.0),
		"clipping keeps both exposed spans and removes the covered middle")
	_expect(FogMesh.clip(vertices, []).get_surface_count() == 0,
		"no exposed spans yields no draw")


func _expect(ok: bool, message: String) -> void:
	_checks += 1
	if not ok:
		_failures += 1
		push_error(message)
