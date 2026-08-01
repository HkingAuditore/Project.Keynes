extends SceneTree

const FamilyLayerScript := preload("res://scripts/rendering/vegetation_family_layer.gd")
const ShrubLayerScript := preload("res://scripts/rendering/shrub_layer.gd")
const ProfileScript := preload("res://scripts/data/shrub_visual_profile.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	var tree = _make_source(ProfileScript.DetailKind.TREE, 3, 0.10)
	var conifer = _make_source(ProfileScript.DetailKind.CONIFER, 2, 0.60)
	var family = FamilyLayerScript.new()
	root.add_child(family)
	family.configure([tree, conifer], true)
	# 主 family buffer 与 Canopy shadow buffer 分帧上传。
	family.drain_one_shadow_upload()

	_expect("same-family profiles collapse into one superchunk batch", family._entries.size() == 1)
	var entry: Dictionary = family._entries.values()[0]
	var node: MultiMeshInstance2D = entry.node
	_expect("family batch concatenates all source instances",
		node.multimesh.instance_count == 5 and family.instance_count() == 5)
	var buffer := node.multimesh.buffer
	_expect("family buffer interleaves styles for deterministic LOD prefixes",
		floori(buffer[15]) == 0 and floori(buffer[31]) == 1)
	_expect("source profile draw nodes are suppressed", not tree._chunk_nodes[7].visible and not conifer._chunk_nodes[7].visible)
	_expect("style LUT is bound to the family material", bool(family.diagnostics().get("style_lut_bound", false)))

	family.set_camera_view(Rect2(Vector2(-100, -100), Vector2(200, 200)), Vector2.ZERO, 0.34)
	_expect("overview canopy keeps the sparse prefix",
		node.visible and node.multimesh.visible_instance_count == 1)
	family.set_camera_view(Rect2(Vector2(-100, -100), Vector2(200, 200)), Vector2.ZERO, 0.95)
	_expect("near canopy reveals the complete merged batch", node.multimesh.visible_instance_count == 5)
	_expect("canopy uses one consolidated shadow batch near zoom",
		family._shadow_entries.size() == 1 and family._shadow_entries.values()[0].visible == false)
	# 阴影门槛是 1.10；上面的 0.95 应保持隐藏。
	family.set_camera_view(Rect2(Vector2(-100, -100), Vector2(200, 200)), Vector2.ZERO, 1.20)
	_expect("consolidated canopy shadow enables at zoom 1.10+",
		family._shadow_entries.values()[0].visible)

	var cache_source = ShrubLayerScript.new()
	cache_source.profile = ProfileScript.new()
	cache_source.set_family_batch_suppressed(true)
	var cache_buffer := PackedFloat32Array()
	cache_buffer.resize(32)
	cache_buffer[0] = 1.0
	cache_buffer[5] = 1.0
	cache_buffer[16] = 1.0
	cache_buffer[21] = 1.0
	cache_source._apply_chunk_payload_direct(
		9, cache_buffer, PackedInt32Array([5, 6]), 2, 2)
	_expect("family source keeps CPU payloads without creating a GPU chunk node",
		cache_source._chunk_nodes.is_empty()
		and int(cache_source.detail_family_chunk_payload(9).instance_count) == 2)
	var replacement := PackedFloat32Array()
	replacement.resize(32)
	var replaced: Dictionary = cache_source._replace_chunk_cell_payloads(
		9, PackedInt32Array([5]), replacement, PackedInt32Array([5, 5]), 2)
	_expect("exact-cell cache replacement preserves untouched cells",
		int(replaced.instance_count) == 3
		and (replaced.cell_indices as PackedInt32Array).count(6) == 1)

	family._sources.clear()
	family.free()
	tree.free()
	conifer.free()
	cache_source.free()
	print("=== vegetation family layer: %d checks, %d failures ===" % [_checks, _failures])


func _make_source(detail_kind: int, count: int, seed_base: float):
	var layer = ShrubLayerScript.new()
	var profile = ProfileScript.new()
	profile.detail_kind = detail_kind
	profile.cast_shadow_enabled = true
	layer.profile = profile
	layer._ensure_resources()
	var mm: MultiMesh = layer._prepare_chunk_multimesh(7, count, count)
	var buffer := PackedFloat32Array()
	buffer.resize(count * 16)
	for i in range(count):
		var b := i * 16
		buffer[b + 0] = 1.0
		buffer[b + 5] = 1.0
		buffer[b + 3] = float(i * 4)
		buffer[b + 7] = float(detail_kind * 3)
		buffer[b + 8] = 0.4
		buffer[b + 9] = 0.7
		buffer[b + 10] = 0.3
		buffer[b + 11] = 1.0
		buffer[b + 12] = 0.5
		buffer[b + 13] = 0.5
		buffer[b + 14] = seed_base + float(i) * 0.01
		buffer[b + 15] = float(i) / maxf(float(count), 1.0)
	mm.buffer = buffer
	layer._instance_count = count
	return layer


func _expect(label: String, ok: bool) -> void:
	_checks += 1
	if ok:
		print("  [PASS] %s" % label)
	else:
		_failures += 1
		printerr("  [FAIL] %s" % label)
