extends RefCounted
## Rain and snow batches keep the original cell order, seeds and wrap copies.

const CURTAIN_SHADER_PATH := "res://shaders/weather_cell_curtain.gdshader"
const _CURTAIN_PATCH_SCALE := 1.45
# MultiMesh 2D transforms use eight floats followed by four custom floats.
const _INSTANCE_STRIDE := 12
# These bits are also used by weather_cell_curtain.gdshader.
const _FLAG_LIGHTNING := 2
const _FLAG_SNOW := 4
const _FLAG_RAIN := 8
const _FLAG_FOG := 16

# [parallax-rain] 三层视差参数：每层独立的 z_offset（layer_depth 由层数自动计算）
# 索引 0=近景(z 高) / 1=中景 / 2=远景(z 低)
const _CURTAIN_PARALLAX_Z_OFFSETS := [2, 1, 0]
const _MAX_WEATHER_TYPES := 8

var root: Node2D
var _curtain_mesh: ArrayMesh
# [parallax-rain] 每层独立材质，支持 per-layer layer_depth uniform
var materials: Array[ShaderMaterial] = []
var layers: Array[MultiMeshInstance2D] = []
var multimeshes: Array[MultiMesh] = []
var _curtain_built_for_map: MapData = null
var _curtain_built_hex_size: float = -1.0
var _curtain_built_wrap_period: float = -1.0
var instance_count: int = 0
var _curtain_cells := PackedVector4Array() # center.xy, seed, original cell id
var draw_cells := PackedInt32Array() # indices into _curtain_cells, in draw order
var _curtain_offsets := PackedFloat32Array()
var _curtain_lut_update := -1
var _curtain_lut_blending := false
var _hex_size: float
var _buffer_hex_size: float
var _full_instance_buffers: Array[PackedFloat32Array] = []


func attach(parent: Node2D) -> void:
	root = Node2D.new()
	root.name = "CellWeatherCurtains"
	root.z_as_relative = true
	# 雨幕位于云层下、地表上；避免中等降水的雨线盖住云体，导致“只见雨不见云”。
	root.z_index = -1
	parent.add_child(root)


func load_materials(layer_count: int, shader_prefix: String) -> bool:
	var shader := ResourceLoader.load(CURTAIN_SHADER_PATH, "Shader",
		ResourceLoader.CACHE_MODE_IGNORE) as Shader
	if shader == null:
		push_warning("WeatherLayer: shader not found at %s" % CURTAIN_SHADER_PATH)
		return false
	if not shader_prefix.is_empty():
		var src: String = shader.code
		if not src.begins_with("#define"):
			shader = shader.duplicate() as Shader
			shader.code = "%s%s" % [shader_prefix, src]
	# [parallax-rain] 清空旧材质，按层数重建
	materials.clear()
	for layer_idx in range(layer_count):
		var mat := ShaderMaterial.new()
		mat.shader = shader
		# per-layer 的 layer_depth（0=近景，1=远景）
		var depth_val: float = 0.0
		if layer_count > 1:
			depth_val = float(layer_idx) / float(layer_count - 1)
		mat.set_shader_parameter("layer_depth", depth_val)
		materials.append(mat)
	# 重新绑定已存在的 layer 节点到新材质
	for i in range(layers.size()):
		var layer: MultiMeshInstance2D = layers[i]
		if layer != null and i < materials.size():
			layer.material = materials[i]
	return true

static func weather_profile_flags() -> PackedInt32Array:
	var flags := PackedInt32Array()
	flags.resize(_MAX_WEATHER_TYPES)
	for wt in range(_MAX_WEATHER_TYPES):
		var p := WeatherProfileRegistry.get_profile(wt)
		if p == null:
			flags[wt] = 0
			continue
		var f: int = 0
		if p.enables_lightning:
			f |= _FLAG_LIGHTNING
		if p.enables_snow_grain:
			f |= _FLAG_SNOW
		if p.enables_rain_streak:
			f |= _FLAG_RAIN
		if p.enables_fog_breathe:
			f |= _FLAG_FOG
		flags[wt] = f
	return flags

func _build_curtain_patch_mesh() -> ArrayMesh:
	var verts := PackedVector2Array([
		Vector2(-1.0, -1.0),
		Vector2(1.0, -1.0),
		Vector2(1.0, 1.0),
		Vector2(-1.0, 1.0),
	])
	var uvs := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(1.0, 0.0),
		Vector2(1.0, 1.0),
		Vector2(0.0, 1.0),
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

func rebuild(map: MapData, hex_size: float, wrap_period_x: float, max_layers: int) -> bool:
	_hex_size = hex_size
	if map == null or map.cell_count() <= 0 or max_layers <= 0:
		_clear_curtain_layers()
		return false
	if _curtain_built_for_map == map \
			and is_equal_approx(_curtain_built_hex_size, _hex_size) \
			and is_equal_approx(_curtain_built_wrap_period, wrap_period_x) \
			and layers.size() == max_layers:
		return false
	_clear_curtain_layers()
	if _curtain_mesh == null:
		_curtain_mesh = _build_curtain_patch_mesh()
	var cells: Array = map.iter_cells()
	if cells.is_empty():
		cells = map.all_cells()
	if cells.is_empty():
		return false
	_curtain_offsets = PackedFloat32Array([0.0])
	if wrap_period_x > 0.0001:
		_curtain_offsets = PackedFloat32Array([-wrap_period_x, 0.0, wrap_period_x])
	for order in range(cells.size()):
		var cell = cells[order]
		if cell == null:
			continue
		var id := int(cell.index)
		if id < 0:
			id = order
		if id >= 65536:
			continue
		var center := _curtain_cell_center(map, cell, id)
		_curtain_cells.append(Vector4(center.x, center.y, _curtain_seed(id, order), id))
	if _curtain_cells.is_empty():
		return false
	for layer_idx in range(max_layers):
		var mmi := MultiMeshInstance2D.new()
		mmi.name = "CellCurtainLayer_%d" % layer_idx
		mmi.z_as_relative = true
		# [parallax-rain] z_index 按视差配置：近景 z 高，远景 z 低
		var z_off: int = 0
		if layer_idx < _CURTAIN_PARALLAX_Z_OFFSETS.size():
			z_off = _CURTAIN_PARALLAX_Z_OFFSETS[layer_idx]
		mmi.z_index = z_off
		# 每层用独立材质和 layer_depth。
		if layer_idx < materials.size():
			mmi.material = materials[layer_idx]
		elif not materials.is_empty():
			mmi.material = materials[0]
		root.add_child(mmi)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = false
		mm.use_custom_data = true
		mm.mesh = _curtain_mesh
		# Allocate once for the map. Each publication submits only the compact prefix.
		mm.instance_count = _curtain_cells.size() * _curtain_offsets.size()
		mm.visible_instance_count = 0
		mmi.multimesh = mm
		layers.append(mmi)
		multimeshes.append(mm)
	_curtain_built_for_map = map
	_curtain_built_hex_size = _hex_size
	_curtain_built_wrap_period = wrap_period_x
	_build_instance_buffers()
	return true


func refresh_instances(update_usec: int, blending: bool, world: WorldData,
		lut_texture: Texture2D, lut_dims: Vector2i, shader_tier: String, active_layers: int) -> void:
	if multimeshes.is_empty():
		return
	if update_usec == _curtain_lut_update and blending == _curtain_lut_blending:
		return
	_curtain_lut_update = update_usec
	_curtain_lut_blending = blending

	var current := PackedByteArray()
	var previous := PackedByteArray()
	if world != null and lut_texture != null and lut_texture == world.weather_lut_tex \
			and lut_dims == world.lut_dims:
		var pair: Array = lut_texture.get_meta(DCCellLutBaker.WEATHER_CURTAIN_LUT_PAIR, [])
		if pair.size() == 2:
			previous = pair[0]
			current = pair[1]
	# The shader uses the current type throughout the blend. Rain and snow
	# still contribute at zero intensity. Fog and lightning need positive G.
	var intensity_effects := not DCFeatureFlags.uses_shader_quality_tier() \
			or shader_tier.is_empty() or shader_tier == "MOBILE_QUALITY_HIGH"
	var flags := weather_profile_flags()
	var next_cells := PackedInt32Array()
	for index in range(_curtain_cells.size()):
		var at := int(_curtain_cells[index].w) * 4
		# Standalone callers may supply a texture without CPU data. Keep those
		# instances and let the shader decide, including any out-of-range ids.
		if at + 3 < current.size():
			var type := current[at]
			var effects := flags[type] if type < flags.size() else 0
			var has_intensity := current[at + 1] > 0 or (blending and
					(at + 1 >= previous.size() or previous[at + 1] > 0))
			if (effects & (_FLAG_RAIN | _FLAG_SNOW)) == 0 and not (
					intensity_effects and has_intensity and (effects & (_FLAG_FOG | _FLAG_LIGHTNING)) != 0):
				continue
		next_cells.append(index)
	if next_cells == draw_cells:
		return
	draw_cells = next_cells
	_upload_curtain_instances()
	update_visibility(active_layers)


func _upload_curtain_instances() -> void:
	var count := draw_cells.size() * _curtain_offsets.size()
	if count > 0:
		if _full_instance_buffers.is_empty() or _buffer_hex_size != _hex_size:
			_build_instance_buffers()
		var cell_stride := _curtain_offsets.size() * _INSTANCE_STRIDE
		var runs := _active_cell_runs(cell_stride)
		# Copy whole spans so all layers retain the same cell and wrap order.
		for layer_index in multimeshes.size():
			var source := _full_instance_buffers[layer_index]
			var compact := PackedFloat32Array()
			for run in range(0, runs.size(), 2):
				compact.append_array(source.slice(runs[run], runs[run + 1]))
			var mm := multimeshes[layer_index]
			compact.resize(mm.instance_count * _INSTANCE_STRIDE)
			mm.buffer = compact
	for mm in multimeshes:
		mm.visible_instance_count = count
	instance_count = count * multimeshes.size()


func _active_cell_runs(cell_stride: int) -> PackedInt32Array:
	var runs := PackedInt32Array()
	var start := draw_cells[0]
	var end := start + 1
	for index in range(1, draw_cells.size()):
		var cell := draw_cells[index]
		if cell != end:
			runs.append(start * cell_stride)
			runs.append(end * cell_stride)
			start = cell
		end = cell + 1
	runs.append(start * cell_stride)
	runs.append(end * cell_stride)
	return runs


func _build_instance_buffers() -> void:
	# The geometry and seeds belong to the map. Daily updates select from them.
	_full_instance_buffers.clear()
	_buffer_hex_size = _hex_size
	var layer_count := multimeshes.size()
	for layer_index in layer_count:
		var depth := float(layer_index) / (layer_count - 1) if layer_count > 1 else 0.5
		var half_w := _hex_size * _CURTAIN_PATCH_SCALE * lerpf(0.96, 1.18, depth)
		var half_h := _hex_size * _CURTAIN_PATCH_SCALE * lerpf(1.10, 1.36, depth)
		var buffer := PackedFloat32Array()
		buffer.resize(multimeshes[layer_index].instance_count * _INSTANCE_STRIDE)
		var at := 0
		for cell in _curtain_cells:
			var custom := _curtain_custom_data(int(cell.w), cell.z, depth)
			for offset in _curtain_offsets:
				var point := Vector2(cell.x, cell.y) + Vector2(offset, 0.0)
				buffer[at] = half_w
				buffer[at + 3] = point.x
				buffer[at + 5] = half_h
				buffer[at + 7] = point.y
				buffer[at + 8] = custom.r
				buffer[at + 9] = custom.g
				buffer[at + 10] = custom.b
				buffer[at + 11] = custom.a
				at += _INSTANCE_STRIDE
		_full_instance_buffers.append(buffer)


func _clear_curtain_layers() -> void:
	for layer in layers:
		if layer != null:
			if layer.get_parent() != null:
				layer.get_parent().remove_child(layer)
			layer.queue_free()
	layers.clear()
	multimeshes.clear()
	_full_instance_buffers.clear()
	_curtain_cells.clear()
	draw_cells.clear()
	_curtain_lut_update = -1
	instance_count = 0
	_curtain_built_for_map = null

func invalidate_inputs() -> void:
	_curtain_lut_update = -1


func update_visibility(active_layers: int) -> void:
	for i in range(layers.size()):
		var layer := layers[i]
		if layer != null:
			layer.visible = i < active_layers
	if root != null:
		root.visible = active_layers > 0 and instance_count > 0

func _curtain_cell_center(map: MapData, cell, idx: int) -> Vector2:
	if map != null \
			and idx >= 0 \
			and idx < map.cell_pos_x_arr.size() \
			and idx < map.cell_pos_y_arr.size():
		return Vector2(map.cell_pos_x_arr[idx], map.cell_pos_y_arr[idx]) * _hex_size
	return HexUtils.cube_to_world(int(cell.q), int(cell.r), _hex_size)

func _curtain_custom_data(cell_id: int, seed: float, depth: float) -> Color:
	return Color(
		float(cell_id & 0xFF) / 255.0,
		float((cell_id >> 8) & 0xFF) / 255.0,
		clampf(seed, 0.0, 1.0),
		clampf(depth, 0.0, 1.0)
	)

func _curtain_seed(idx: int, order: int) -> float:
	return _hash_noise_2d(idx * 17 + 11, order * 31 + 7)

func _hash_noise_2d(ix: int, iy: int) -> float:
	var n: int = ix * 374761393 + iy * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / 2147483647.0

