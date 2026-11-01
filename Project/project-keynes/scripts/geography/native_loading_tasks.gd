extends RefCounted
class_name NativeLoadingTasks

## 冷路径原生计算的帧友好桥。
##
## [watchdog 2026-11-01] 安卓真机反馈「进游戏后完全卡死」：新重建的 arm64 库才第一次真正
## 暴露 `begin_loading_task` 线程化 API（旧库没有这个方法，一直走下面的同步 fallback）。
## 如果这条线程任务在某个平台上永远不 done，`await process_frame` 会无限循环——主线程还活着，
## 但加载条永远停在原处，表现就是「卡死」。
## 因此这里加两道闸：
##   1) 超时（LOADING_TASK_TIMEOUT_MS）→ cancel_loading_task() 后改走同步路径；
##   2) take() 返回空字典（极少数平台把结果丢了）→ 同样改走同步路径。
## 两条都会打一行 `[native-loading]` 警告，下次看日志就能确认是不是这条路出的问题。

## 单个原生任务的最长等待。桌面 40x28 生成约 2.6s，手机慢 10 倍也够；真卡住就 60s 后兜底。
const LOADING_TASK_TIMEOUT_MS := 60000

static func compute(ext: Object, operation: String, input: Dictionary) -> Dictionary:
	var tree := Engine.get_main_loop() as SceneTree
	if ext != null and ext.has_method("begin_loading_task") and tree != null:
		var handle: int = ext.begin_loading_task(operation, input)
		if handle > 0:
			var started_ms := Time.get_ticks_msec()
			while true:
				var status: Dictionary = ext.poll_loading_task(handle)
				if not bool(status.get("valid", false)) or bool(status.get("canceled", false)):
					return {"fallback": true, "canceled": true, "reason": "loading_canceled", "rc": -1}
				if bool(status.get("done", false)):
					var taken: Dictionary = ext.take_loading_task(handle)
					if not taken.is_empty():
						return taken
					push_warning("[native-loading] %s 完成但 take() 返回空；改走同步路径" % operation)
					break
				var waited_ms := Time.get_ticks_msec() - started_ms
				if waited_ms >= LOADING_TASK_TIMEOUT_MS:
					push_warning("[native-loading] %s 超时 %dms（原生线程任务未完成）；取消后改走同步路径"
						% [operation, waited_ms])
					print("[native-loading][watchdog] op=%s timeout_ms=%d platform=%s"
						% [operation, waited_ms, OS.get_name()])
					if ext.has_method("cancel_loading_task"):
						ext.cancel_loading_task(handle)
					break
				await tree.process_frame
	if ext == null:
		return {"fallback": true, "reason": "native_unavailable", "rc": -1}
	# Legacy binaries and no-thread targets retain the same authoritative kernels.
	match operation:
		"generate": return ext.run_native_world_generate_full_pass(input.seed, input.cfg, input.profile)
		"geometry": return ext.run_bake_geometry_fields_pass(input)
		"visual_tile": return ext.run_bake_visual_tile_layer_pass(input)
		"height_flow":
			return ext.encode_bake_height_flow_tex_data(input) if ext.has_method("encode_bake_height_flow_tex_data") else {"fallback": true}
		"normal": return ext.encode_bake_terrain_normal_tex_data(input)
		"detail_scatter": return ext.call("encode_detail_scatter", input)
		"catalog_manifest":
			for path in input.get("files", {}):
				if FileAccess.get_sha256(path) != input.files[path]:
					return {"valid": false}
				if tree != null:
					await tree.process_frame
			return {"valid": true}
	return {"fallback": true, "reason": "unsupported_loading_operation", "rc": -1}
