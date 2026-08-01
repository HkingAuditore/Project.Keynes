class_name VegetationFamilyLayer
extends Node2D

## 将已有 ShrubLayer 的确定性 PCG payload 合并成五个逻辑渲染家族。
## source layer 仍负责生态适配度与原生编码；本节点只做 buffer 合并、LOD、
## 可见性、环绕副本和单一 Canopy shadow pass。

const FAMILY_GROUND := 1
const FAMILY_BRUSH := 2
const FAMILY_CANOPY := 3
const FAMILY_HARDSCAPE := 4
const FAMILY_AQUATIC := 5
const BUFFER_STRIDE := 16
const STYLE_LUT_WIDTH := 16
const STYLE_LUT_HEIGHT := 32

var _sources: Array = []
var _sources_by_family: Dictionary = {}
var _representatives: Dictionary = {}
var _materials: Dictionary = {}
var _shadow_materials: Dictionary = {}
var _near_meshes: Dictionary = {}
var _mid_meshes: Dictionary = {}
var _far_meshes: Dictionary = {}
var _family_lod_states: Dictionary = {}
var _entries: Dictionary = {}
var _wrap_entries: Dictionary = {}
var _shadow_entries: Dictionary = {}
var _shadow_wrap_entries: Dictionary = {}
var _pending_shadow_uploads: Dictionary = {}
var _dormant_since_msec: Dictionary = {}
var _style_lut: ImageTexture = null
var _camera_rect: Rect2 = Rect2()
var _camera_center: Vector2 = Vector2.ZERO
var _camera_zoom: float = 1.0
var _camera_initialized := false
var _budget_fraction := 1.0
var _enabled := false
var _instance_count := 0
var _visible_instances := 0
var _active_instance_count_cache := 0
var _active_instance_count_valid := false
var _active_instance_count_scans := 0
var _visible_batches := 0
var _shadow_batches := 0
var _wrap_batches := 0
var _last_rebuild_ms := 0.0
var _last_visibility_ms := 0.0
var _last_assemble_ms := 0.0
var _last_upload_ms := 0.0
var _last_wind_dir := Vector2(INF, INF)
var _last_wind_boost := INF


func configure(sources: Array, enabled: bool) -> void:
	_clear_entries()
	_sources = sources.duplicate()
	_enabled = enabled
	_active_instance_count_valid = false
	_sources_by_family.clear()
	_representatives.clear()
	_materials.clear()
	_shadow_materials.clear()
	_near_meshes.clear()
	_mid_meshes.clear()
	_far_meshes.clear()
	_family_lod_states.clear()
	for i in range(_sources.size()):
		var layer = _sources[i]
		if layer == null or not is_instance_valid(layer):
			continue
		if layer.has_method("set_family_style_id"):
			layer.set_family_style_id(i)
		var family := int(layer.detail_render_family()) if layer.has_method("detail_render_family") else 0
		if family <= 0:
			continue
		var family_sources: Array = _sources_by_family.get(family, [])
		family_sources.append(layer)
		_sources_by_family[family] = family_sources
	_style_lut = _build_style_lut()
	for raw_family in _sources_by_family.keys():
		var family := int(raw_family)
		var representative = _choose_representative(family, _sources_by_family[raw_family])
		if representative == null:
			continue
		_representatives[family] = representative
		_materials[family] = representative.detail_family_material(_style_lut)
		_near_meshes[family] = representative.detail_family_mesh()
		var source_quality := int(representative.detail_family_quality()) \
			if representative.has_method("detail_family_quality") else 1
		_mid_meshes[family] = representative.detail_family_mesh_for_quality(mini(source_quality, 1))
		_far_meshes[family] = representative.detail_family_mesh_for_quality(0)
		if family == FAMILY_CANOPY:
			_shadow_materials[family] = representative.detail_family_shadow_material()
	for layer in _sources:
		if layer != null and is_instance_valid(layer) and layer.has_method("set_family_batch_suppressed"):
			layer.set_family_batch_suppressed(_enabled)
	if _enabled:
		rebuild_all()
	_update_visibility()


func set_enabled(value: bool) -> void:
	if _enabled == value:
		return
	_enabled = value
	_active_instance_count_valid = false
	for layer in _sources:
		if layer != null and is_instance_valid(layer) and layer.has_method("set_family_batch_suppressed"):
			layer.set_family_batch_suppressed(_enabled)
	if _enabled and _entries.is_empty():
		rebuild_all()
	_update_visibility()


func rebuild_all() -> void:
	if not _enabled:
		return
	var t0 := Time.get_ticks_usec()
	var chunk_ids := {}
	for layer in _sources:
		if layer == null or not is_instance_valid(layer) or not layer.has_method("detail_family_chunk_ids"):
			continue
		for raw_chunk_id in layer.detail_family_chunk_ids():
			chunk_ids[int(raw_chunk_id)] = true
	for family in _sources_by_family.keys():
		for chunk_id in chunk_ids.keys():
			rebuild_family_chunk(int(family), int(chunk_id))
	_recount()
	_last_rebuild_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func rebuild_source_chunk(source, chunk_id: int) -> void:
	if not _enabled or source == null or not is_instance_valid(source):
		return
	var family := int(source.detail_render_family()) if source.has_method("detail_render_family") else 0
	if family > 0:
		rebuild_family_chunk(family, chunk_id)
		_recount()


func rebuild_family_chunk(family: int, chunk_id: int) -> void:
	var assemble_t0 := Time.get_ticks_usec()
	var sources: Array = _sources_by_family.get(family, [])
	if sources.is_empty() or not _representatives.has(family):
		return
	var payloads: Array = []
	var total := 0
	var max_count := 0
	for layer in sources:
		if layer == null or not is_instance_valid(layer):
			continue
		var payload: Dictionary = layer.detail_family_chunk_payload(chunk_id)
		var count := int(payload.get("instance_count", 0))
		var buffer: PackedFloat32Array = payload.get("buffer", PackedFloat32Array())
		if count <= 0 or buffer.size() < count * BUFFER_STRIDE:
			continue
		payloads.append(payload)
		total += count
		max_count = maxi(max_count, count)
	var key := _entry_key(family, chunk_id)
	if total <= 0 and not _entries.has(key):
		return
	var node := _ensure_entry(key, family, chunk_id)
	var mm: MultiMesh = node.multimesh
	var merged := PackedFloat32Array()
	if total > 0:
		merged.resize(total * BUFFER_STRIDE)
		var dst := 0
		# 每轮每个 style 取一个，避免 LOD prefix 被第一个 profile 独占。
		for rank in range(max_count):
			for payload in payloads:
				var count := int(payload.get("instance_count", 0))
				if rank >= count:
					continue
				var source_buffer: PackedFloat32Array = payload.get("buffer", PackedFloat32Array())
				var source_base := rank * BUFFER_STRIDE
				var dest_base := dst * BUFFER_STRIDE
				for k in range(BUFFER_STRIDE):
					merged[dest_base + k] = source_buffer[source_base + k]
				var style_id := int(payload.get("style_id", 0))
				var variant := clampf(source_buffer[source_base + 15], 0.0, 0.999999)
				merged[dest_base + 15] = float(style_id) + variant / 16.0
				dst += 1
	_last_assemble_ms = float(Time.get_ticks_usec() - assemble_t0) / 1000.0
	var upload_t0 := Time.get_ticks_usec()
	mm.instance_count = total
	mm.buffer = merged
	_active_instance_count_valid = false
	_last_upload_ms = float(Time.get_ticks_usec() - upload_t0) / 1000.0
	_update_entry_lod_and_visibility(key)
	if family == FAMILY_CANOPY:
		_pending_shadow_uploads[key] = {"family": family, "chunk_id": chunk_id}
	_sync_wrap_for_entry(key, false)


func set_camera_view(world_rect: Rect2, center: Vector2, zoom_value: float) -> void:
	_camera_rect = world_rect
	_camera_center = center
	_camera_zoom = clampf(zoom_value, 0.01, 16.0)
	_camera_initialized = world_rect.size.x > 0.0 and world_rect.size.y > 0.0
	_active_instance_count_valid = false
	if _camera_zoom >= 1.10:
		for key in _entries.keys():
			var entry: Dictionary = _entries[key]
			if int(entry.get("family", 0)) == FAMILY_CANOPY \
					and not _shadow_entries.has(key):
				_pending_shadow_uploads[key] = {
					"family": FAMILY_CANOPY,
					"chunk_id": int(entry.get("chunk_id", -1)),
				}
	_update_visibility()


func apply_visible_instance_fraction(value: float) -> void:
	_budget_fraction = clampf(value, 0.0, 1.0)
	_update_visibility()


func instance_count() -> int:
	return _instance_count


func active_instance_count() -> int:
	if _active_instance_count_valid:
		return _active_instance_count_cache
	var total := 0
	for key in _entries.keys():
		var entry: Dictionary = _entries[key]
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node == null or not is_instance_valid(node) or node.multimesh == null:
			continue
		var family := int(entry.family)
		var chunk_id := int(entry.chunk_id)
		var representative = _representatives.get(family, null)
		var in_view := true
		if representative != null and representative.has_method("detail_chunk_is_render_visible"):
			in_view = bool(representative.detail_chunk_is_render_visible(chunk_id))
		if _enabled and in_view:
			total += int(round(float(node.multimesh.instance_count) \
				* _lod_fraction(family, _camera_zoom)))
	_active_instance_count_cache = total
	_active_instance_count_valid = true
	_active_instance_count_scans += 1
	return _active_instance_count_cache


func diagnostics() -> Dictionary:
	return {
		"enabled": _enabled,
		"families": _sources_by_family.size(),
		"resident_superchunks": _resident_entry_count(),
		"resident_multimeshes": _resident_multimesh_count(),
		"instances": _instance_count,
		"visible_instances": _visible_instances,
		"active_instance_count_scans": _active_instance_count_scans,
		"visible_batches": _visible_batches,
		"shadow_batches": _shadow_batches,
		"wrap_batches": _wrap_batches,
		"lod0_batches": _lod_batch_count(0),
		"lod1_batches": _lod_batch_count(1),
		"lod2_batches": _lod_batch_count(2),
		"rebuild_ms": _last_rebuild_ms,
		"visibility_ms": _last_visibility_ms,
		"assemble_ms": _last_assemble_ms,
		"upload_ms": _last_upload_ms,
		"style_lut_bound": _style_lut != null,
		"pending_shadow_uploads": _pending_shadow_uploads.size(),
	}


func drain_one_shadow_upload() -> bool:
	if _pending_shadow_uploads.is_empty():
		return false
	var keys: Array = _pending_shadow_uploads.keys()
	keys.sort()
	var key := str(keys[0])
	var request: Dictionary = _pending_shadow_uploads[key]
	_pending_shadow_uploads.erase(key)
	var entry: Dictionary = _entries.get(key, {})
	var source: MultiMeshInstance2D = entry.get("node", null)
	if source == null or not is_instance_valid(source) or source.multimesh == null:
		return false
	_update_shadow_entry(
		int(request.get("family", 0)),
		int(request.get("chunk_id", -1)),
		source.multimesh)
	_sync_wrap_for_entry(key, true)
	return true


func evict_dormant_chunks(now_msec: int, retention_msec: int) -> int:
	var evicted := 0
	for key in _entries.keys():
		var entry: Dictionary = _entries[key]
		var family := int(entry.get("family", 0))
		var chunk_id := int(entry.get("chunk_id", -1))
		var representative = _representatives.get(family, null)
		var in_prefetch: bool = representative != null \
			and representative.has_method("detail_chunk_is_in_prefetch") \
			and bool(representative.detail_chunk_is_in_prefetch(chunk_id))
		if in_prefetch:
			_dormant_since_msec.erase(key)
			continue
		if not _dormant_since_msec.has(key):
			_dormant_since_msec[key] = now_msec
			continue
		if now_msec - int(_dormant_since_msec[key]) < retention_msec:
			continue
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node != null and is_instance_valid(node) and node.multimesh != null \
				and node.multimesh.instance_count > 0:
			node.visible = false
			node.multimesh.instance_count = 0
			var shadow: MultiMeshInstance2D = _shadow_entries.get(key, null)
			if shadow != null and is_instance_valid(shadow) and shadow.multimesh != null:
				shadow.visible = false
				shadow.multimesh.instance_count = 0
			evicted += 1
		_pending_shadow_uploads.erase(key)
		_dormant_since_msec.erase(key)
	if evicted > 0:
		_active_instance_count_valid = false
		_recount()
	return evicted


func _resident_entry_count() -> int:
	var chunks := {}
	for entry in _entries.values():
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node != null and is_instance_valid(node) and node.multimesh != null \
				and node.multimesh.instance_count > 0:
			chunks[int(entry.get("chunk_id", -1))] = true
	return chunks.size()


func _resident_multimesh_count() -> int:
	var count := 0
	for entry in _entries.values():
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node != null and is_instance_valid(node) and node.multimesh != null \
				and node.multimesh.instance_count > 0:
			count += 1
	return count


func _lod_batch_count(lod: int) -> int:
	var count := 0
	for entry in _entries.values():
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node != null and is_instance_valid(node) and node.visible \
				and int(entry.get("lod", 0)) == lod:
			count += 1
	return count


func sync_dynamic_materials() -> void:
	var params := [
		"world_time", "season_phase", "day_phase", "wind_dir", "weather_wind_boost",
		"axial_tilt_rad", "day_night_enabled", "tod_sun_dir", "tod_exposure",
		"tod_debug_sun_position_enabled", "tod_debug_sun_uv", "tod_debug_sun_height_scale",
	]
	for raw_family in _materials.keys():
		var family := int(raw_family)
		var target: ShaderMaterial = _materials[raw_family]
		var representative = _representatives.get(family, null)
		if target == null or representative == null or representative._material == null:
			continue
		for param in params:
			target.set_shader_parameter(param, representative._material.get_shader_parameter(param))


func set_frame_state(world_time: float, wind_dir: Vector2, wind_boost: float) -> void:
	var wind_changed := not wind_dir.is_equal_approx(_last_wind_dir) \
		or not is_equal_approx(wind_boost, _last_wind_boost)
	for target in _materials.values():
		if target == null:
			continue
		# world_time 是唯一每帧必变的植被 uniform；不再从 20 个隐藏 source
		# 材质读取并回写十余个参数。
		target.set_shader_parameter("world_time", world_time)
		if wind_changed:
			target.set_shader_parameter("wind_dir", wind_dir)
			target.set_shader_parameter("weather_wind_boost", wind_boost)
	if wind_changed:
		_last_wind_dir = wind_dir
		_last_wind_boost = wind_boost


func _build_style_lut() -> ImageTexture:
	var image := Image.create(STYLE_LUT_WIDTH, STYLE_LUT_HEIGHT, false, Image.FORMAT_RGBAF)
	image.fill(Color(0.0, 1.0, 1.0, 0.0))
	for layer in _sources:
		if layer == null or not is_instance_valid(layer):
			continue
		var profile = layer.profile
		var style_id := clampi(int(layer.family_style_id()), 0, STYLE_LUT_HEIGHT - 1)
		var wind := float(profile.get("wind_strength")) if profile != null else 1.0
		var shape := _style_shape_scale(int(profile.get("detail_kind")) if profile != null else 0)
		image.set_pixel(0, style_id, Color(wind, shape.x, shape.y,
			float(layer.detail_render_family()) / 5.0))
		var base := Color.WHITE
		if profile != null and bool(profile.get("base_color_override_enabled")):
			base = profile.get("base_color_override")
		image.set_pixel(1, style_id, base)
	return ImageTexture.create_from_image(image)


func _style_shape_scale(detail_kind: int) -> Vector2:
	match detail_kind:
		1, 3, 4, 10:
			return Vector2(0.92, 1.08)
		2, 7:
			return Vector2(1.08, 0.82)
		5, 6:
			return Vector2(0.82, 1.12)
		8, 9:
			return Vector2(1.10, 0.76)
	return Vector2.ONE


func _choose_representative(family: int, sources: Array):
	var preferred_kind: int = int({FAMILY_GROUND: 2, FAMILY_BRUSH: 0, FAMILY_CANOPY: 1,
		FAMILY_HARDSCAPE: 8, FAMILY_AQUATIC: 6}.get(family, -1))
	for layer in sources:
		if layer != null and is_instance_valid(layer) and layer.profile != null \
				and int(layer.profile.get("detail_kind")) == preferred_kind:
			return layer
	return sources[0] if not sources.is_empty() else null


func _ensure_entry(key: String, family: int, chunk_id: int) -> MultiMeshInstance2D:
	if _entries.has(key):
		var existing: MultiMeshInstance2D = _entries[key].get("node", null)
		if existing != null and is_instance_valid(existing):
			return existing
	var node := MultiMeshInstance2D.new()
	node.name = "VegetationFamily_%d_%d" % [family, chunk_id]
	node.z_index = _family_z(family)
	node.material = _materials.get(family, null)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true
	var lod := _lod_index_hysteretic(family, _camera_zoom)
	mm.mesh = _mesh_for_lod(family, lod)
	node.multimesh = mm
	add_child(node)
	_entries[key] = {"node": node, "family": family, "chunk_id": chunk_id, "lod": lod}
	return node


func _update_visibility() -> void:
	var t0 := Time.get_ticks_usec()
	_visible_instances = 0
	_visible_batches = 0
	_shadow_batches = 0
	_wrap_batches = 0
	for key in _entries.keys():
		_update_entry_lod_and_visibility(key)
		_sync_wrap_for_entry(key, false)
	for key in _shadow_entries.keys():
		_update_shadow_visibility(key)
		_sync_wrap_for_entry(key, true)
	_last_visibility_ms = float(Time.get_ticks_usec() - t0) / 1000.0


func _update_entry_lod_and_visibility(key: String) -> void:
	if not _entries.has(key):
		return
	var entry: Dictionary = _entries[key]
	var node: MultiMeshInstance2D = entry.get("node", null)
	if node == null or not is_instance_valid(node) or node.multimesh == null:
		return
	var family := int(entry.family)
	var chunk_id := int(entry.chunk_id)
	var fraction := _lod_fraction(family, _camera_zoom)
	var lod := _lod_index_hysteretic(family, _camera_zoom)
	entry["lod"] = lod
	_entries[key] = entry
	node.multimesh.mesh = _mesh_for_lod(family, lod)
	var target_visible := int(round(float(node.multimesh.instance_count) * fraction * _budget_fraction))
	if fraction > 0.0 and _budget_fraction > 0.0 and node.multimesh.instance_count > 0:
		target_visible = maxi(1, target_visible)
	node.multimesh.visible_instance_count = clampi(target_visible, 0, node.multimesh.instance_count)
	var representative = _representatives.get(family, null)
	var in_view := true
	if representative != null and representative.has_method("detail_chunk_is_render_visible"):
		in_view = bool(representative.detail_chunk_is_render_visible(chunk_id))
	node.visible = _enabled and in_view and node.multimesh.visible_instance_count > 0
	if node.visible:
		_visible_batches += 1
		_visible_instances += node.multimesh.visible_instance_count


func _update_shadow_entry(family: int, chunk_id: int, source_mm: MultiMesh) -> void:
	if family != FAMILY_CANOPY or not _representatives.has(family):
		return
	var key := _entry_key(family, chunk_id)
	var shadow: MultiMeshInstance2D = _shadow_entries.get(key, null)
	if shadow == null or not is_instance_valid(shadow):
		shadow = MultiMeshInstance2D.new()
		shadow.name = "VegetationFamilyShadow_%d" % chunk_id
		shadow.z_index = 1
		shadow.material = _shadow_materials.get(family, null)
		var smm := MultiMesh.new()
		smm.transform_format = MultiMesh.TRANSFORM_2D
		smm.use_colors = true
		smm.use_custom_data = true
		smm.mesh = _representatives[family].detail_family_shadow_mesh()
		shadow.multimesh = smm
		add_child(shadow)
		_shadow_entries[key] = shadow
	var mm := shadow.multimesh
	var upload_t0 := Time.get_ticks_usec()
	mm.instance_count = source_mm.instance_count
	mm.buffer = source_mm.buffer if source_mm.instance_count > 0 else PackedFloat32Array()
	_last_upload_ms = float(Time.get_ticks_usec() - upload_t0) / 1000.0
	_update_shadow_visibility(key)


func _update_shadow_visibility(key: String) -> void:
	var shadow: MultiMeshInstance2D = _shadow_entries.get(key, null)
	var entry: Dictionary = _entries.get(key, {})
	var source: MultiMeshInstance2D = entry.get("node", null)
	if shadow == null or not is_instance_valid(shadow) or shadow.multimesh == null \
			or source == null or not is_instance_valid(source):
		return
	shadow.multimesh.visible_instance_count = mini(
		source.multimesh.visible_instance_count, shadow.multimesh.instance_count)
	shadow.visible = _enabled and _camera_zoom >= 1.10 and source.visible \
		and shadow.multimesh.visible_instance_count > 0
	if shadow.visible:
		_shadow_batches += 1


func _sync_wrap_for_entry(key: String, shadow_pass: bool) -> void:
	var source: MultiMeshInstance2D
	var entry: Dictionary = _entries.get(key, {})
	if shadow_pass:
		source = _shadow_entries.get(key, null)
	else:
		source = entry.get("node", null)
	if source == null or not is_instance_valid(source) or source.multimesh == null:
		return
	var family := int(entry.get("family", 0))
	var chunk_id := int(entry.get("chunk_id", -1))
	var representative = _representatives.get(family, null)
	if representative == null:
		return
	var period := float(representative.call("_wrap_period_x"))
	var bounds: Rect2 = representative.call("_chunk_world_bounds", chunk_id)
	var groups := _shadow_wrap_entries if shadow_pass else _wrap_entries
	var nodes: Array = groups.get(key, [])
	var offsets := PackedFloat32Array([-period, period])
	var selected_wrap := -1
	if _enabled and source.visible and period > 0.0001 and _camera_initialized:
		var best_distance := INF
		for i in range(2):
			var shifted := Rect2(bounds.position + Vector2(offsets[i], 0.0), bounds.size)
			if not shifted.intersects(_camera_rect, true):
				continue
			var distance := shifted.get_center().distance_squared_to(_camera_center)
			if distance < best_distance:
				best_distance = distance
				selected_wrap = i
	for i in range(2):
		var show := i == selected_wrap
		var wrap_node: MultiMeshInstance2D = nodes[i] as MultiMeshInstance2D if i < nodes.size() else null
		if not show:
			if wrap_node != null and is_instance_valid(wrap_node):
				wrap_node.visible = false
			continue
		if wrap_node == null or not is_instance_valid(wrap_node):
			wrap_node = MultiMeshInstance2D.new()
			wrap_node.name = "%sWrap_%s" % [source.name, "L" if i == 0 else "R"]
			add_child(wrap_node)
			if i < nodes.size():
				nodes[i] = wrap_node
			else:
				nodes.append(wrap_node)
		wrap_node.position = Vector2(offsets[i], 0.0)
		wrap_node.z_index = source.z_index
		wrap_node.material = source.material
		wrap_node.multimesh = source.multimesh
		wrap_node.visible = true
		_wrap_batches += 1
	groups[key] = nodes


func _lod_fraction(family: int, zoom_value: float) -> float:
	match family:
		FAMILY_CANOPY:
			if zoom_value < 0.45: return 0.08
			if zoom_value < 0.55: return lerpf(0.08, 0.40, smoothstep(0.45, 0.55, zoom_value))
			if zoom_value < 0.85: return 0.40
			if zoom_value < 0.95: return lerpf(0.40, 1.0, smoothstep(0.85, 0.95, zoom_value))
			return 1.0
		FAMILY_BRUSH, FAMILY_HARDSCAPE:
			if zoom_value < 0.65: return 0.0
			if zoom_value < 0.75: return 0.35 * smoothstep(0.65, 0.75, zoom_value)
			if zoom_value < 1.15: return 0.35
			if zoom_value < 1.25: return lerpf(0.35, 1.0, smoothstep(1.15, 1.25, zoom_value))
			return 1.0
		FAMILY_GROUND, FAMILY_AQUATIC:
			if zoom_value < 1.00: return 0.0
			if zoom_value < 1.10: return 0.25 * smoothstep(1.00, 1.10, zoom_value)
			if zoom_value < 1.55: return 0.25
			if zoom_value < 1.65: return lerpf(0.25, 1.0, smoothstep(1.55, 1.65, zoom_value))
			return 1.0
	return 1.0


func _lod_index(family: int, zoom_value: float) -> int:
	match family:
		FAMILY_CANOPY:
			return 2 if zoom_value < 0.50 else (1 if zoom_value < 0.90 else 0)
		FAMILY_BRUSH, FAMILY_HARDSCAPE:
			return 1 if zoom_value < 1.20 else 0
		FAMILY_GROUND, FAMILY_AQUATIC:
			return 1 if zoom_value < 1.60 else 0
	return 0


func _lod_index_hysteretic(family: int, zoom_value: float) -> int:
	var desired := _lod_index(family, zoom_value)
	if not _family_lod_states.has(family):
		_family_lod_states[family] = desired
		return desired
	var current := int(_family_lod_states[family])
	# 阈值两侧各留 8%，相机在边界附近抖动时不反复切换几何资源。
	match family:
		FAMILY_CANOPY:
			if current == 2:
				if zoom_value >= 0.972:
					current = 0
				elif zoom_value >= 0.54:
					current = 1
			elif current == 1:
				if zoom_value < 0.46:
					current = 2
				elif zoom_value >= 0.972:
					current = 0
			elif current == 0:
				if zoom_value < 0.46:
					current = 2
				elif zoom_value < 0.828:
					current = 1
		FAMILY_BRUSH, FAMILY_HARDSCAPE:
			if current >= 1 and zoom_value >= 1.296:
				current = 0
			elif current == 0 and zoom_value < 1.104:
				current = 1
		FAMILY_GROUND, FAMILY_AQUATIC:
			if current >= 1 and zoom_value >= 1.728:
				current = 0
			elif current == 0 and zoom_value < 1.472:
				current = 1
	_family_lod_states[family] = current
	return current


func _mesh_for_lod(family: int, lod: int) -> Mesh:
	if lod >= 2:
		return _far_meshes.get(family, _mid_meshes.get(family, null))
	if lod == 1:
		return _mid_meshes.get(family, _near_meshes.get(family, null))
	return _near_meshes.get(family, null)


func _family_z(family: int) -> int:
	match family:
		FAMILY_GROUND: return 0
		FAMILY_CANOPY: return 2
		_: return 1


func _entry_key(family: int, chunk_id: int) -> String:
	return "%d:%d" % [family, chunk_id]


func _recount() -> void:
	_instance_count = 0
	for entry in _entries.values():
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node != null and is_instance_valid(node) and node.multimesh != null:
			_instance_count += node.multimesh.instance_count
	_update_visibility()


func _clear_entries() -> void:
	_active_instance_count_cache = 0
	_active_instance_count_valid = false
	for entry in _entries.values():
		var node: MultiMeshInstance2D = entry.get("node", null)
		if node != null and is_instance_valid(node):
			node.visible = false
			node.queue_free()
	for node in _shadow_entries.values():
		if node != null and is_instance_valid(node):
			node.visible = false
			node.queue_free()
	for groups in [_wrap_entries, _shadow_wrap_entries]:
		for nodes in groups.values():
			for node in nodes:
				if node != null and is_instance_valid(node):
					node.queue_free()
	_entries.clear()
	_shadow_entries.clear()
	_wrap_entries.clear()
	_shadow_wrap_entries.clear()
	_pending_shadow_uploads.clear()
	_dormant_since_msec.clear()
	_instance_count = 0
