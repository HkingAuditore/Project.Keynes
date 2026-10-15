extends RefCounted
class_name NativeLoadingTasks

## Frame-friendly bridge for cold native compute. Never wait on a running worker.
static func compute(ext: Object, operation: String, input: Dictionary) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if ext != null and ext.has_method("begin_loading_task") and tree != null:
		var handle: int = ext.begin_loading_task(operation, input)
		if handle > 0:
			while true:
				var status: Dictionary = ext.poll_loading_task(handle)
				if not bool(status.get("valid",false)) or bool(status.get("canceled",false)):
					return {"fallback":true,"canceled":true,"reason":"loading_canceled","rc":-1}
				if bool(status.get("done",false)):
					return ext.take_loading_task(handle)
				await tree.process_frame
	if ext == null:
		return {"fallback":true,"reason":"native_unavailable","rc":-1}
	# Legacy binaries and no-thread targets retain the same authoritative kernels.
	match operation:
		"generate": return ext.run_native_world_generate_full_pass(input.seed,input.cfg,input.profile)
		"geometry": return ext.run_bake_geometry_fields_pass(input)
		"visual_tile": return ext.run_bake_visual_tile_layer_pass(input)
		"height_flow":
			return ext.encode_bake_height_flow_tex_data(input) if ext.has_method("encode_bake_height_flow_tex_data") else {"fallback":true}
		"normal": return ext.encode_bake_terrain_normal_tex_data(input)
		"detail_scatter": return ext.call("encode_detail_scatter",input)
		"catalog_manifest":
			for path in input.get("files",{}):
				if FileAccess.get_sha256(path) != input.files[path]:
					return {"valid":false}
				if tree != null:
					await tree.process_frame
			return {"valid":true}
	return {"fallback":true,"reason":"unsupported_loading_operation","rc":-1}
