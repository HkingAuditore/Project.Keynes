extends RefCounted

## Builds building shaders, shared pass meshes and macro texture bytes. Owns no scene or simulation state.

const PK_WEB_BUILDING_MIN_PREFIX := "#define PK_WEB_BUILDING_MIN\n"

static func web_building_min_active() -> bool:
	if not OS.has_feature("web"):
		return false
	if not DCFeatureFlags.is_compatibility_renderer():
		return false
	return not DCFeatureFlags.terrain_horizon_gpu_bake_active()


static func compose_shader_code(source: Shader, tiled: bool,
		cloud_shadow_direct: bool = false) -> String:
	if source == null:
		return ""
	var prefix := ""
	if web_building_min_active():
		prefix += PK_WEB_BUILDING_MIN_PREFIX
	if tiled:
		prefix += "#define MAP_VISUAL_TILED\n"
	if cloud_shadow_direct:
		prefix += "#define PK_CLOUD_SHADOW_DIRECT\n"
	return prefix + source.code


static func _shader_material(path: String) -> ShaderMaterial:
	var shader := load(path) as Shader
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


static func _make_quad_mesh() -> ArrayMesh:
	var vertices := PackedVector2Array([
		Vector2(-1.0, -1.0), Vector2(1.0, -1.0),
		Vector2(1.0, 1.0), Vector2(-1.0, 1.0),
	])
	var uv := PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(1.0, 0.0),
		Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _make_shadow_hull_mesh() -> ArrayMesh:
	var vertices := PackedVector2Array([Vector2.ZERO])
	var normals := PackedVector2Array([Vector2.ZERO])
	var corners := [Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1)]
	var edge_normals := [Vector2(1, 0), Vector2(0, 1), Vector2(-1, 0), Vector2(0, -1)]
	for k in 4:
		vertices.append(corners[k])
		normals.append(edge_normals[(k + 3) % 4])
		vertices.append(corners[k])
		normals.append(edge_normals[k])
	var indices := PackedInt32Array()
	for k in 8:
		indices.append_array([0, 1 + k, 1 + (k + 1) % 8])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _encode_macro_index_high_bytes(cell_count: int,
		first: PackedInt32Array, counts: PackedInt32Array,
		flat: PackedInt32Array, pixel_count: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(maxi(0, pixel_count))
	bytes.fill(255) # map-outside sentinel, combined value 0xFFFFFF
	if cell_count > 0 and first.size() >= cell_count \
			and counts.size() >= cell_count:
		for cell in cell_count:
			var begin: int = first[cell]
			var count: int = counts[cell]
			if begin < 0 or count <= 0 or begin + count > flat.size():
				continue
			var high := (cell >> 16) & 0xFF
			for edge in range(begin, begin + count):
				var pixel: int = flat[edge]
				if pixel >= 0 and pixel < pixel_count:
					bytes[pixel] = high
	return bytes
