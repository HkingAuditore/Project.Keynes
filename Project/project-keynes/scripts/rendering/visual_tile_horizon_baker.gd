class_name VisualTileHorizonBaker
extends RefCounted

signal completed(success: bool, report: Dictionary)

const DECODE_SHADER := "res://shaders/compute/visual_tile_horizon_decode.glsl"
const PYRAMID_SHADER := "res://shaders/compute/visual_tile_horizon_pyramid.glsl"
const TRACE_SHADER := "res://shaders/compute/visual_tile_horizon_trace.glsl"
const WORKGROUP_SIZE := 8
const MAX_MIP_LEVELS := 16

var _cancelled: bool = false
var _generation_id: int = -1
var _rd: RenderingDevice
var _owned_rids: Array[RID] = []


func cancel() -> void:
	_cancelled = true


func start(tiles, generation_id: int, params: Dictionary = {}) -> void:
	_cancelled = false
	_generation_id = generation_id
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame
	if _cancelled or tiles == null or tiles.layout == null \
			or int(tiles.layout.generation_id) != generation_id:
		completed.emit(false, {"path": "cancelled", "reason": "stale_generation"})
		return
	var report := await _run_compute(tiles, params)
	completed.emit(bool(report.get("ok", false)), report)


func _run_compute(tiles, params: Dictionary) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var layout = tiles.layout
	if RenderingServer.get_current_rendering_method() == "gl_compatibility":
		return _failure("compatibility_renderer", t0)
	if tiles.height == null or layout.layer_count <= 0:
		return _failure("height_tiles_unavailable", t0)
	# [terrain-gi 2026-07-31] 遮挡源 cell id 需要 map_index 作为 trace 的第二个输入。
	# 它属于静态 bundle，走到这里时必然已经上传完毕（compute 在 static_ready 之后启动）。
	if tiles.map_index == null:
		return _failure("map_index_tiles_unavailable", t0)

	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		return _failure("local_rendering_device_create_failed", t0)

	var shader_bundle := _create_shader_bundle()
	var compile_ms := float(Time.get_ticks_usec() - t0) / 1000.0
	if not bool(shader_bundle.get("ok", false)):
		var failed := _failure(String(shader_bundle.get("reason", "shader_compile_failed")), t0)
		_cleanup()
		return failed

	var input_data: Array[PackedByteArray] = []
	input_data.resize(layout.layer_count)
	for layer_id in range(layout.layer_count):
		if _cancelled:
			_cleanup()
			return _failure("cancelled", t0)
		var image: Image = tiles.height.get_layer_data(layer_id)
		if image == null:
			_cleanup()
			return _failure("height_layer_readback_failed:%d" % layer_id, t0)
		# Horizon compute 只需要 RG16 elev；height 现为 RGBA8（B=flow），显式抽 RG。
		var rg_bytes: PackedByteArray
		if image.get_format() == Image.FORMAT_RGBA8:
			var src: PackedByteArray = image.get_data()
			var n: int = layout.layer_size.x * layout.layer_size.y
			rg_bytes = PackedByteArray()
			rg_bytes.resize(n * 2)
			for i in range(n):
				rg_bytes[i * 2] = src[i * 4]
				rg_bytes[i * 2 + 1] = src[i * 4 + 1]
		else:
			if image.get_format() != Image.FORMAT_RG8:
				image.convert(Image.FORMAT_RG8)
			rg_bytes = image.get_data()
		input_data[layer_id] = rg_bytes

	var texture_format := RDTextureFormat.new()
	texture_format.format = RenderingDevice.DATA_FORMAT_R8G8_UNORM
	texture_format.width = layout.layer_size.x
	texture_format.height = layout.layer_size.y
	texture_format.depth = 1
	texture_format.array_layers = layout.layer_count
	texture_format.mipmaps = 1
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var input_texture := _rd.texture_create(texture_format, RDTextureView.new(), input_data)
	if not input_texture.is_valid():
		_cleanup()
		return _failure("height_texture_create_failed", t0)
	_owned_rids.append(input_texture)
	input_data.clear()

	var map_index_data: Array[PackedByteArray] = []
	map_index_data.resize(layout.layer_count)
	for layer_id in range(layout.layer_count):
		if _cancelled:
			_cleanup()
			return _failure("cancelled", t0)
		var mi_image: Image = tiles.map_index.get_layer_data(layer_id)
		if mi_image == null:
			_cleanup()
			return _failure("map_index_layer_readback_failed:%d" % layer_id, t0)
		if mi_image.get_format() != Image.FORMAT_RGBA8:
			mi_image.convert(Image.FORMAT_RGBA8)
		map_index_data[layer_id] = mi_image.get_data()
	var map_index_format := RDTextureFormat.new()
	map_index_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	map_index_format.width = layout.layer_size.x
	map_index_format.height = layout.layer_size.y
	map_index_format.depth = 1
	map_index_format.array_layers = layout.layer_count
	map_index_format.mipmaps = 1
	map_index_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	map_index_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var map_index_texture := _rd.texture_create(
		map_index_format, RDTextureView.new(), map_index_data)
	if not map_index_texture.is_valid():
		_cleanup()
		return _failure("map_index_texture_create_failed", t0)
	_owned_rids.append(map_index_texture)
	map_index_data.clear()

	var mip_sizes: Array[Vector2i] = []
	var mip_offsets: PackedInt32Array = PackedInt32Array()
	# First 16 floats are an exactly representable mip-offset table consumed by trace.
	var total_height_values := MAX_MIP_LEVELS
	var mip_size: Vector2i = layout.logical_size
	while true:
		mip_offsets.append(total_height_values)
		mip_sizes.append(mip_size)
		total_height_values += mip_size.x * mip_size.y
		if mip_size == Vector2i.ONE or mip_sizes.size() >= MAX_MIP_LEVELS:
			break
		mip_size = Vector2i(maxi(1, (mip_size.x + 1) / 2),
			maxi(1, (mip_size.y + 1) / 2))

	var pyramid_buffer := _rd.storage_buffer_create(total_height_values * 4)
	var pyramid_header := PackedByteArray()
	pyramid_header.resize(MAX_MIP_LEVELS * 4)
	for level in range(mip_offsets.size()):
		pyramid_header.encode_float(level * 4, float(mip_offsets[level]))
	if pyramid_buffer.is_valid():
		_rd.buffer_update(pyramid_buffer, 0, pyramid_header.size(), pyramid_header)
	var physical_pixels: int = layout.layer_size.x * layout.layer_size.y * layout.layer_count
	var horizon_buffer := _rd.storage_buffer_create(physical_pixels * 4)
	var occluder_buffer := _rd.storage_buffer_create(physical_pixels * 4)
	var metrics_zero := PackedByteArray()
	metrics_zero.resize(16)
	var metrics_buffer := _rd.storage_buffer_create(16, metrics_zero)
	for rid in [pyramid_buffer, horizon_buffer, occluder_buffer, metrics_buffer]:
		if not rid.is_valid():
			_cleanup()
			return _failure("storage_buffer_create_failed", t0)
		_owned_rids.append(rid)

	var decode_set := _make_uniform_set(shader_bundle.decode_shader, [
		_make_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, input_texture),
		_make_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, pyramid_buffer),
	])
	var pyramid_set := _make_uniform_set(shader_bundle.pyramid_shader, [
		_make_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, pyramid_buffer),
	])
	var trace_set := _make_uniform_set(shader_bundle.trace_shader, [
		_make_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, pyramid_buffer),
		_make_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, horizon_buffer),
		_make_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, metrics_buffer),
		_make_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 3, map_index_texture),
		_make_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, occluder_buffer),
	])
	for rid in [decode_set, pyramid_set, trace_set]:
		if not rid.is_valid():
			_cleanup()
			return _failure("uniform_set_create_failed", t0)
		_owned_rids.append(rid)

	var command_t0 := Time.get_ticks_usec()
	var compute_list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(compute_list, shader_bundle.decode_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, decode_set, 0)
	var decode_push := PackedByteArray()
	decode_push.resize(48)
	_encode_vec2i(decode_push, 0, layout.logical_size)
	_encode_vec2i(decode_push, 8, layout.grid_size)
	_encode_vec2i(decode_push, 16, layout.interior_size)
	_encode_vec2i(decode_push, 24, layout.layer_size)
	decode_push.encode_s32(32, layout.gutter_px)
	decode_push.encode_s32(36, mip_offsets[0])
	decode_push.encode_float(40, clampf(float(params.get("sea_level", 0.0)), 0.0, 1.0))
	decode_push.encode_s32(44, clampi(int(params.get("lowpass_radius", 1)), 0, 1))
	_rd.compute_list_set_push_constant(compute_list, decode_push, decode_push.size())
	_rd.compute_list_dispatch(compute_list,
		_groups(layout.logical_size.x), _groups(layout.logical_size.y), 1)
	_rd.compute_list_add_barrier(compute_list)

	_rd.compute_list_bind_compute_pipeline(compute_list, shader_bundle.pyramid_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, pyramid_set, 0)
	for level in range(1, mip_sizes.size()):
		var pyramid_push := PackedByteArray()
		pyramid_push.resize(32)
		_encode_vec2i(pyramid_push, 0, mip_sizes[level - 1])
		_encode_vec2i(pyramid_push, 8, mip_sizes[level])
		pyramid_push.encode_s32(16, mip_offsets[level - 1])
		pyramid_push.encode_s32(20, mip_offsets[level])
		_rd.compute_list_set_push_constant(compute_list, pyramid_push, pyramid_push.size())
		_rd.compute_list_dispatch(compute_list,
			_groups(mip_sizes[level].x), _groups(mip_sizes[level].y), 1)
		_rd.compute_list_add_barrier(compute_list)

	var trace_push := PackedByteArray()
	trace_push.resize(80)
	_encode_vec2i(trace_push, 0, layout.logical_size)
	_encode_vec2i(trace_push, 8, layout.grid_size)
	_encode_vec2i(trace_push, 16, layout.interior_size)
	_encode_vec2i(trace_push, 24, layout.layer_size)
	trace_push.encode_s32(32, layout.gutter_px)
	trace_push.encode_s32(36, mip_sizes.size())
	trace_push.encode_s32(40, clampi(int(params.get("max_iterations", 2048)), 128, 8192))
	trace_push.encode_s32(44, 1 if layout.wrap_x else 0)
	var texel_world: Vector2 = layout.visual_domain.size / Vector2(layout.logical_size)
	trace_push.encode_float(48, texel_world.x)
	trace_push.encode_float(52, texel_world.y)
	trace_push.encode_float(56, float(params.get("height_world_scale", 176.0)))
	trace_push.encode_float(60, float(params.get("bias", 0.004)))
	trace_push.encode_float(64, float(params.get("max_horizon_angle", 1.309)))
	_rd.compute_list_bind_compute_pipeline(compute_list, shader_bundle.trace_pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, trace_set, 0)
	_rd.compute_list_set_push_constant(compute_list, trace_push, trace_push.size())
	_rd.compute_list_dispatch(compute_list,
		_groups(layout.layer_size.x), _groups(layout.layer_size.y), layout.layer_count)
	_rd.compute_list_end()
	var command_record_ms := float(Time.get_ticks_usec() - command_t0) / 1000.0
	var submit_t0 := Time.get_ticks_usec()
	_rd.submit()
	var submit_ms := float(Time.get_ticks_usec() - submit_t0) / 1000.0

	var tree := Engine.get_main_loop() as SceneTree
	if tree != null:
		await tree.process_frame
		await tree.process_frame
	if _cancelled or int(layout.generation_id) != _generation_id:
		_cleanup()
		return _failure("stale_generation", t0)
	var sync_t0 := Time.get_ticks_usec()
	_rd.sync()
	var sync_ms := float(Time.get_ticks_usec() - sync_t0) / 1000.0
	# Release large compute inputs before allocating the CPU readback buffer.
	_free_owned_rid(trace_set)
	_free_owned_rid(pyramid_set)
	_free_owned_rid(decode_set)
	_free_owned_rid(input_texture)
	_free_owned_rid(map_index_texture)
	_free_owned_rid(pyramid_buffer)
	var readback_t0 := Time.get_ticks_usec()
	var all_horizon_data: PackedByteArray = _rd.buffer_get_data(horizon_buffer)
	var all_occluder_data: PackedByteArray = _rd.buffer_get_data(occluder_buffer)
	var metrics_data: PackedByteArray = _rd.buffer_get_data(metrics_buffer)
	var readback_ms := float(Time.get_ticks_usec() - readback_t0) / 1000.0
	if all_horizon_data.size() != physical_pixels * 4:
		_cleanup()
		return _failure("horizon_readback_size_mismatch", t0)
	if all_occluder_data.size() != physical_pixels * 4:
		_cleanup()
		return _failure("occluder_readback_size_mismatch", t0)

	var layer_bytes: int = layout.layer_size.x * layout.layer_size.y * 4
	var upload_t0 := Time.get_ticks_usec()
	for layer_id in range(layout.layer_count):
		if _cancelled or int(layout.generation_id) != _generation_id:
			_cleanup()
			return _failure("stale_generation", t0)
		var begin := layer_id * layer_bytes
		if not tiles.upload_horizon_layer(layer_id,
				all_horizon_data.slice(begin, begin + layer_bytes)):
			_cleanup()
			return _failure("horizon_layer_upload_failed:%d" % layer_id, t0)
		if not tiles.upload_gi_occluder_layer(layer_id,
				all_occluder_data.slice(begin, begin + layer_bytes)):
			_cleanup()
			return _failure("gi_occluder_layer_upload_failed:%d" % layer_id, t0)
	var upload_ms := float(Time.get_ticks_usec() - upload_t0) / 1000.0
	var non_converged := metrics_data.decode_u32(0) if metrics_data.size() >= 4 else 0
	var conservative_tail_rays := metrics_data.decode_u32(4) if metrics_data.size() >= 8 else 0
	var global_fallback_rays := metrics_data.decode_u32(8) if metrics_data.size() >= 12 else 0
	var occluder_sentinel := metrics_data.decode_u32(12) if metrics_data.size() >= 16 else 0
	var total_rays: int = physical_pixels * 8
	var report := {
		"ok": true,
		"path": "gpu_compute_hierarchical",
		"gi_occluder_ok": true,
		"occluder_output_bytes": physical_pixels * 4,
		"occluder_hash": hash(all_occluder_data),
		# 哨兵占比：无有效遮挡源的 texel 比例。开阔地形天然偏高，但接近 1.0 说明
		# trace 的命中记录失效（例如全部落进 conservative tail），需要排查。
		"occluder_sentinel_texels": occluder_sentinel,
		"occluder_sentinel_ratio": float(occluder_sentinel) / maxf(float(physical_pixels), 1.0),
		"mip_levels": mip_sizes.size(),
		"compile_ms": compile_ms,
		"resource_setup_ms": float(command_t0 - t0) / 1000.0 - compile_ms,
		"command_record_ms": command_record_ms,
		"submit_ms": submit_ms,
		"gpu_wait_ms": sync_ms,
		"readback_ms": readback_ms,
		"upload_ms": upload_ms,
		"height_pyramid_bytes": total_height_values * 4,
		"physical_output_bytes": physical_pixels * 4,
		"hash": hash(all_horizon_data),
		"non_converged_rays": non_converged,
		"conservative_tail_rays": conservative_tail_rays,
		"conservative_tail_ratio": float(conservative_tail_rays) / maxf(float(total_rays), 1.0),
		"global_fallback_rays": global_fallback_rays,
		"total_rays": total_rays,
		"height_world_scale": float(params.get("height_world_scale", 176.0)),
		"sea_level": clampf(float(params.get("sea_level", 0.0)), 0.0, 1.0),
		"max_horizon_angle": float(params.get("max_horizon_angle", 1.309)),
		"total_ms": float(Time.get_ticks_usec() - t0) / 1000.0,
	}
	_cleanup()
	return report


func _create_shader_bundle() -> Dictionary:
	var out := {"ok": false, "reason": "shader_compile_failed"}
	for entry in [
		["decode", DECODE_SHADER],
		["pyramid", PYRAMID_SHADER],
		["trace", TRACE_SHADER],
	]:
		var source_text := FileAccess.get_file_as_string(String(entry[1]))
		if source_text.is_empty():
			out.reason = "shader_source_missing:%s" % String(entry[1])
			return out
		# RDShaderSource consumes GLSL directly; #[compute] is the resource importer tag.
		source_text = source_text.trim_prefix("#[compute]\r\n").trim_prefix("#[compute]\n")
		var source := RDShaderSource.new()
		source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, source_text)
		var spirv := _rd.shader_compile_spirv_from_source(source)
		var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not compile_error.is_empty():
			out.reason = "shader_compile:%s:%s" % [String(entry[0]), compile_error]
			return out
		var shader := _rd.shader_create_from_spirv(spirv, "visual_tile_horizon_%s" % entry[0])
		var pipeline := _rd.compute_pipeline_create(shader)
		if not shader.is_valid() or not pipeline.is_valid():
			out.reason = "pipeline_create_failed:%s" % String(entry[0])
			return out
		_owned_rids.append(shader)
		_owned_rids.append(pipeline)
		out["%s_shader" % entry[0]] = shader
		out["%s_pipeline" % entry[0]] = pipeline
	out.ok = true
	return out


func _make_uniform(uniform_type: RenderingDevice.UniformType, binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = uniform_type
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform


func _make_uniform_set(shader: RID, uniforms: Array) -> RID:
	return _rd.uniform_set_create(uniforms, shader, 0)


func _cleanup() -> void:
	if _rd != null:
		var reverse_index := _owned_rids.size() - 1
		while reverse_index >= 0:
			var rid: RID = _owned_rids[reverse_index]
			if rid.is_valid():
				_rd.free_rid(rid)
			reverse_index -= 1
	_owned_rids.clear()
	_rd = null


func _free_owned_rid(rid: RID) -> void:
	if _rd == null or not rid.is_valid():
		return
	var index := _owned_rids.find(rid)
	if index >= 0:
		_owned_rids.remove_at(index)
	_rd.free_rid(rid)


func _failure(reason: String, started_usec: int) -> Dictionary:
	return {
		"ok": false,
		"path": "gpu_compute_failed",
		"reason": reason,
		"total_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
	}


static func _groups(value: int) -> int:
	return maxi(1, (value + WORKGROUP_SIZE - 1) / WORKGROUP_SIZE)


static func _encode_vec2i(bytes: PackedByteArray, offset: int, value: Vector2i) -> void:
	bytes.encode_s32(offset, value.x)
	bytes.encode_s32(offset + 4, value.y)
