extends SceneTree

const SHADERS := [
	"res://shaders/compute/visual_tile_horizon_decode.glsl",
	"res://shaders/compute/visual_tile_horizon_pyramid.glsl",
	"res://shaders/compute/visual_tile_horizon_trace.glsl",
]


func _init() -> void:
	var failures := 0
	var trace_code := FileAccess.get_file_as_string(SHADERS[2])
	var wraps_before_mip := trace_code.contains(
		"wrap_column(p.x, params.logical_size.x) / scale")
	var splits_periodic_span := trace_code.contains("bool crosses_seam") \
		and trace_code.contains("params.logical_size.x - 1")
	if not wraps_before_mip or not splits_periodic_span:
		push_error("trace shader must wrap level-0 X before mip reduction and split seam spans")
		failures += 1
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		print("visual_tile_horizon_shader_test: %s (GPU compile skipped; RenderingDevice unavailable)" % [
			"PASS" if failures == 0 else "FAIL"])
		quit(0 if failures == 0 else 1)
		return
	for path in SHADERS:
		var code := FileAccess.get_file_as_string(path)
		if code.is_empty():
			push_error("missing compute shader: %s" % path)
			failures += 1
			continue
		code = code.trim_prefix("#[compute]\r\n").trim_prefix("#[compute]\n")
		var source := RDShaderSource.new()
		source.set_stage_source(RenderingDevice.SHADER_STAGE_COMPUTE, code)
		var spirv := rd.shader_compile_spirv_from_source(source, false)
		var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not compile_error.is_empty():
			push_error("compute shader compile failed: %s\n%s" % [path, compile_error])
			failures += 1
			continue
		var shader := rd.shader_create_from_spirv(spirv)
		if not shader.is_valid():
			push_error("compute shader RID invalid: %s" % path)
			failures += 1
		else:
			print("  [PASS] %s" % path)
			rd.free_rid(shader)
	print("visual_tile_horizon_shader_test: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(0 if failures == 0 else 1)
