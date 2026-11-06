extends RefCounted

## Passive preparation/stop adapter. No process loop, host pointer or retained resources.
## Host keeps cancellation state and signal emission; arguments live only for this call.
static func prepare_presentation(safe_area: Rect2, bind_renderer: Callable,
		is_active: Callable, failure: Callable, frames: RefCounted,
		advance_progress: Callable, loading_step: Callable,
		defer_catalog: Callable, refresh_catalog: Callable) -> Dictionary:
	# 生成器已返回（bake_progress "done"=96%）：从这里开始的渲染绑定、植被层构建、
	# 建筑外观目录刷新原先完全不发进度，进度条会钉在 98%。改由单调游标推进
	# 0.96 → 0.99（+ 逐层回调），1.0 仍然只由 hide_completed() 负责。
	advance_progress.call("bind", true)
	await bind_renderer.call(safe_area)
	if not is_active.call():
		return failure.call()
	loading_step.call("building_visual_setup")
	await frames.next_frame()
	if not is_active.call():
		return failure.call()
	var building_visual_setup: Dictionary
	if OS.has_feature("web"):
		# Web：这一步 = economy building_visual_catalog() + renderer.configure_building_visuals()，
		# 实测在浏览器里要 42s（MultiMesh/图集/首次 shader 编译），放进加载条等于把
		# "进世界"卡住。改成进世界后再补：加载条先走完，玩家先看到地图。
		building_visual_setup = {"ok": false, "deferred": true,
			"reason": "web_deferred_after_world_ready"}
		WebTelemetry.emit("bind_step", {"s": "building_visual_deferred"})
		defer_catalog.call()
	else:
		building_visual_setup = refresh_catalog.call()
	WebTelemetry.emit("bind_step", {"s": "post_building_visual_catalog"})
	if not bool(building_visual_setup.get("ok", false)) \
			and not bool(building_visual_setup.get("deferred", false)):
		push_warning("[building-visual] disabled: %s" % String(
			building_visual_setup.get("reason", "catalog audit failed")))
	# 目录刷新是这一步的真实耗时：跑完才推进游标（[loading-visual-substep] 会打出来）。
	loading_step.call("building_visual_ready")
	return {"ok": true}


static func stop_worker(generator: Object, next_frame: Callable) -> Dictionary:
	if generator == null or not generator.has_method("request_runtime_stop"):
		return {"ok": true}
	var stoppinggenerator = generator
	var stop_result: Dictionary = stoppinggenerator.request_runtime_stop()
	if not bool(stop_result.get("ok", false)):
		return stop_result
	if not bool(stop_result.get("pending", false)):
		return {"ok": true}
	# This is intentionally an async lifecycle wait, never a mutex/worker join.
	# FAULTED alone does not prove the worker has unwound its local resources.
	var report: Dictionary = stoppinggenerator.get_runtime_thread_report()
	while not bool(report.get("simulation_executor_exited", false)):
		if not report.has("simulation_executor_exited"):
			return {"ok": false, "code": "runtime_stop_ack_missing"}
		await next_frame.call()
		report = stoppinggenerator.get_runtime_thread_report()
	return {"ok": true}

