extends RefCounted

## Manages macro settlement data and uploads bounded resident chunk geometry.

static func _configure_macro(layer: BuildingVisualLayer) -> void:
	if layer._world == null or layer._macro_quad == null:
		return
	var bounds := layer._world.world_bounds
	var quad := QuadMesh.new()
	quad.size = bounds.size
	layer._macro_quad.mesh = quad
	layer._macro_quad.position = bounds.get_center()
	var dims := layer._world.lut_dims
	if dims.x <= 0 or dims.y <= 0:
		dims = Vector2i(maxi(1, mini(layer._map.cell_count(), 2048)),
			maxi(1, ceili(float(layer._map.cell_count()) / 2048.0)))
	layer._macro_image = Image.create(dims.x, dims.y, false, Image.FORMAT_RGBA8)
	layer._macro_image.fill(Color.TRANSPARENT)
	layer._macro_texture = ImageTexture.create_from_image(layer._macro_image)
	layer._macro_material.set_shader_parameter("building_macro_lut", layer._macro_texture)
	layer._macro_material.set_shader_parameter("world_size", bounds.size)
	layer._macro_material.set_shader_parameter("hex_size", layer._hex_size)
	layer._configure_macro_index_high_texture()


## The shared map index atlas stores only the low 16 bits in G/B. Building Macro
## supports the 500x400 target by adding one R8 high-byte texture. The source is
## the bake-time cell CSR, so this cold build never scans HexCell objects.


static func _configure_macro_index_high_texture(layer: BuildingVisualLayer) -> void:
	if layer._world == null or layer._world.derived_size.x <= 0 or layer._world.derived_size.y <= 0:
		return
	var pixel_count := layer._world.derived_size.x * layer._world.derived_size.y
	var first := layer._world.cell_first_px_arr
	var counts := layer._world.cell_px_count_arr
	var flat := layer._world.flat_px_indices_arr
	var cell_count := layer._map.cell_count() if layer._map != null else 0
	var bytes := BuildingVisualLayer._encode_macro_index_high_bytes(
		cell_count, first, counts, flat, pixel_count)
	var image := Image.create_from_data(layer._world.derived_size.x,
		layer._world.derived_size.y, false, Image.FORMAT_R8, bytes)
	layer._macro_index_high_texture = ImageTexture.create_from_image(image)
	if layer._macro_material != null:
		layer._macro_material.set_shader_parameter(
			"cell_index_high_atlas", layer._macro_index_high_texture)


static func _encode_macro_index_high_bytes(cell_count: int,
		first: PackedInt32Array, counts: PackedInt32Array,
		flat: PackedInt32Array, pixel_count: int) -> PackedByteArray:
	return BuildingVisualLayer.BuildingVisualAssets._encode_macro_index_high_bytes(cell_count, first, counts, flat, pixel_count)


static func _update_macro_cell(layer: BuildingVisualLayer, cell: int, row: Dictionary) -> void:
	if layer._macro_image == null or layer._world == null:
		return
	var dims := layer._world.lut_dims
	if dims.x <= 0 or dims.y <= 0:
		return
	var x := cell % dims.x
	var y := cell / dims.x
	if row.is_empty():
		layer._macro_image.set_pixel(x, y, Color.TRANSPARENT)
		return
	var aggregate := layer._aggregate_archetypes(row)
	var counts: PackedInt64Array = aggregate.counts
	var total: int = int(aggregate.total)
	var dominant := 0
	for a in range(1, BuildingVisualLayer.ARCHETYPE_COUNT):
		if counts[a] > counts[dominant]:
			dominant = a
	var density := clampf(float(BuildingVisualLayer._floor_log2(1 + total)) / 15.0, 0.0, 1.0)
	var tier := int(row.get("settlement_tier", 255))
	if tier >= 1 and tier <= 7:
		density = maxf(density, float(tier) / 8.0)
	var era := clampi(int(row.get("observed_era_index", -1)), 0, 10)
	layer._macro_image.set_pixel(x, y, Color(density, float(dominant) / 255.0,
		float(era) / 255.0, 1.0))


## Residency is chosen natively from per-chunk bounds of non-empty chunks, so a
## camera move costs one call instead of a scan over every known cell.


static func _refresh_resident_chunks(layer: BuildingVisualLayer) -> void:
	if layer._map == null or layer._visual_cache == null or layer._camera_rect.size == Vector2.ZERO:
		return
	if layer._camera_zoom < 0.46:
		layer._clear_chunks()
		return
	var limit := BuildingVisualLayer.MAX_RESIDENT_WEB if DCFeatureFlags.is_mobile_web() else BuildingVisualLayer.MAX_RESIDENT_DESKTOP
	var ordered: PackedInt32Array = layer._visual_cache.chunks_in_rect(
		layer._camera_rect.grow(layer._hex_size * 18.0), layer._camera_center, limit)
	var wanted := {}
	for chunk_id in ordered:
		wanted[chunk_id] = true
		if not layer._chunk_nodes.has(chunk_id):
			layer._enqueue_upload(chunk_id)
	for raw_chunk in layer._chunk_nodes.keys():
		if not wanted.has(int(raw_chunk)):
			layer._remove_chunk(int(raw_chunk))


static func _report_native_unavailable(layer: BuildingVisualLayer, reason: String) -> void:
	if layer._native_path_warning_emitted:
		return
	layer._native_path_warning_emitted = true
	push_warning("[building-visual] native layout cache unavailable (%s); geometry is disabled until the extension is rebuilt" % reason)


## Concatenates the chunk's cached cells (native memcpy) and swaps the buffers
## into the chunk's existing MultiMeshes. No layout work runs here.


static func _upload_chunk(layer: BuildingVisualLayer, chunk_id: int) -> void:
	if layer._visual_cache == null or layer._camera_zoom < 0.46:
		return
	var begin_usec := Time.get_ticks_usec()
	layer._upload_chunk_buffers(chunk_id)
	var elapsed := float(Time.get_ticks_usec() - begin_usec) / 1000.0
	layer._diagnostics.last_chunk_upload_ms = elapsed
	layer._diagnostics.max_chunk_upload_ms = maxf(float(layer._diagnostics.max_chunk_upload_ms), elapsed)


static func _upload_chunk_buffers(layer: BuildingVisualLayer, chunk_id: int) -> void:
	var current := int(layer._chunk_instance_counts.get(chunk_id, 0))
	var cap := maxi(0, int(BuildingVisualLayer.BODY_CAP[layer._visual_quality])
		- (int(layer._diagnostics.body_instances) - current))
	var result: Dictionary = layer._visual_cache.build_chunk(chunk_id, cap)
	if not bool(result.get("ok", false)):
		layer._diagnostics.native_failures = int(layer._diagnostics.native_failures) + 1
		layer._diagnostics.last_native_reason = String(result.get("reason", ""))
		return
	var buffer := PackedFloat32Array(result.get("buffer", PackedFloat32Array()))
	var instance_count := int(result.get("instance_count", 0))
	var decal_buffer := PackedFloat32Array(result.get("decal_buffer", PackedFloat32Array()))
	var decal_count := int(result.get("decal_instance_count", 0))
	layer._diagnostics.last_chunk_instance_count = instance_count
	layer._diagnostics.last_chunk_decal_count = decal_count
	layer._diagnostics.last_chunk_lot_count = int(result.get("lot_count", 0))
	layer._diagnostics.last_chunk = chunk_id
	layer._diagnostics.chunk_uploads = int(layer._diagnostics.chunk_uploads) + 1
	if instance_count <= 0 or buffer.size() < instance_count * 16:
		layer._remove_chunk(chunk_id)
		layer._recount_instances()
		return
	var nodes: Dictionary = layer._chunk_nodes.get(chunk_id, {})
	layer._put_batch(nodes, "body", "Body", layer._body_material, buffer, instance_count, null,
		BuildingVisualLayer.Z_BAND_BODY, BuildingVisualLayer.FogDrawBounds.Kind.BUILDING_BODY)
	var detailed := layer._visual_quality > 0
	if detailed and decal_count > 0 and decal_buffer.size() >= decal_count * 16:
		layer._put_batch(nodes, "decal", "GroundDecal", layer._decal_material,
			decal_buffer, decal_count, null, BuildingVisualLayer.Z_BAND_DECAL, BuildingVisualLayer.FogDrawBounds.Kind.BUILDING_DECAL)
	else:
		layer._drop_batch(nodes, "decal")
	if detailed and not DCFeatureFlags.is_mobile_web():
		# 投影必须留在贴花那一层（贴着地面、压在建筑主体之下）。跟着 body 一起
		# 抬到 2 会让深色壳体刷在屋顶上。
		layer._put_batch(nodes, "shadow", "Shadow", layer._shadow_material,
			buffer, instance_count, layer._shadow_hull_mesh, BuildingVisualLayer.Z_BAND_SHADOW,
			BuildingVisualLayer.FogDrawBounds.Kind.BUILDING_SHADOW, nodes.body.multimesh)
	else:
		layer._drop_batch(nodes, "shadow")
	layer._chunk_nodes[chunk_id] = nodes
	layer._chunk_instance_counts[chunk_id] = instance_count
	layer._recount_instances()


static func _put_batch(layer: BuildingVisualLayer, nodes: Dictionary, key: String, node_name: String, material: Material,
		buffer: PackedFloat32Array, instance_count: int, mesh: Mesh,
		layer_z: int, kind: BuildingVisualLayer.FogDrawBounds.Kind, same_geometry: MultiMesh = null) -> void:
	var node := nodes.get(key) as MultiMeshInstance2D
	if is_instance_valid(node) and node.multimesh != null:
		node.multimesh.instance_count = instance_count
		BuildingVisualLayer.FogDrawBounds.upload(node.multimesh, buffer, kind, same_geometry)
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh if mesh != null else layer._quad_mesh
	mm.instance_count = instance_count
	BuildingVisualLayer.FogDrawBounds.upload(mm, buffer, kind, same_geometry)
	node = MultiMeshInstance2D.new()
	node.name = node_name
	node.multimesh = mm
	node.material = material
	node.z_as_relative = false
	node.z_index = layer_z
	layer.add_child(node)
	nodes[key] = node


static func _drop_batch(layer: BuildingVisualLayer, nodes: Dictionary, key: String) -> void:
	var node = nodes.get(key)
	if node != null and is_instance_valid(node):
		node.queue_free()
	nodes.erase(key)


static func _aggregate_archetypes(layer: BuildingVisualLayer, row: Dictionary) -> Dictionary:
	var counts := PackedInt64Array()
	counts.resize(BuildingVisualLayer.ARCHETYPE_COUNT)
	counts.fill(0)
	var types := PackedInt32Array(row.get("type_indices", PackedInt32Array()))
	var source_counts := PackedInt64Array(row.get("counts", PackedInt64Array()))
	var total := 0
	for i in mini(types.size(), source_counts.size()):
		var type_idx := types[i]
		if type_idx < 0 or type_idx >= layer._type_to_archetype.size():
			continue
		var archetype := int(layer._type_to_archetype[type_idx])
		if archetype >= BuildingVisualLayer.ARCHETYPE_COUNT:
			continue
		counts[archetype] += source_counts[i]
		total += int(source_counts[i])
	return {"counts": counts, "total": total}
