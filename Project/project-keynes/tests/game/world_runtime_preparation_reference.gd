extends RefCounted
var _session_prepare_options := {"safe_area": Rect2()}
var _session_frames: RefCounted
var bind_renderer: Callable
var is_active: Callable
var failure: Callable
var advance_progress: Callable
var loading_step: Callable
var defer_catalog: Callable
var refresh_catalog: Callable
var _generator: Object
var next_frame: Callable
func _advance_visual_progress(step, enabled): advance_progress.call(step, enabled)
func _bind_renderer_and_camera(area): await bind_renderer.call(area)
func _session_preparation_active(): return is_active.call()
func _session_preparation_failure(): return failure.call()
func _loading_visual_step(step): loading_step.call(step)
func _defer_building_visual_catalog_after_ready(): defer_catalog.call()
func refresh_building_visual_catalog(): return refresh_catalog.call()
func _prepare_world_presentation() -> Dictionary:
	var safe_area: Rect2 = _session_prepare_options.safe_area
	# 生成器已返回（bake_progress "done"=96%）：从这里开始的渲染绑定、植被层构建、
	# 建筑外观目录刷新原先完全不发进度，进度条会钉在 98%。改由单调游标推进
	# 0.96 → 0.99（+ 逐层回调），1.0 仍然只由 hide_completed() 负责。
	_advance_visual_progress("bind", true)
	await _bind_renderer_and_camera(safe_area)
	if not _session_preparation_active():
		return _session_preparation_failure()
	_loading_visual_step("building_visual_setup")
	await _session_frames.next_frame()
	if not _session_preparation_active():
		return _session_preparation_failure()
	var building_visual_setup: Dictionary
	if OS.has_feature("web"):
		# Web：这一步 = economy building_visual_catalog() + renderer.configure_building_visuals()，
		# 实测在浏览器里要 42s（MultiMesh/图集/首次 shader 编译），放进加载条等于把
		# "进世界"卡住。改成进世界后再补：加载条先走完，玩家先看到地图。
		building_visual_setup = {"ok": false, "deferred": true,
			"reason": "web_deferred_after_world_ready"}
		WebTelemetry.emit("bind_step", {"s": "building_visual_deferred"})
		_defer_building_visual_catalog_after_ready()
	else:
		building_visual_setup = refresh_building_visual_catalog()
	WebTelemetry.emit("bind_step", {"s": "post_building_visual_catalog"})
	if not bool(building_visual_setup.get("ok", false)) \
			and not bool(building_visual_setup.get("deferred", false)):
		push_warning("[building-visual] disabled: %s" % String(
			building_visual_setup.get("reason", "catalog audit failed")))
	# 目录刷新是这一步的真实耗时：跑完才推进游标（[loading-visual-substep] 会打出来）。
	_loading_visual_step("building_visual_ready")
	return {"ok": true}


func _stop_previous_runtime_worker() -> Dictionary:
	if _generator == null or not _generator.has_method("request_runtime_stop"):
		return {"ok": true}
	var stopping_generator = _generator
	var stop_result: Dictionary = stopping_generator.request_runtime_stop()
	if not bool(stop_result.get("ok", false)):
		return stop_result
	if not bool(stop_result.get("pending", false)):
		return {"ok": true}
	# This is intentionally an async lifecycle wait, never a mutex/worker join.
	# FAULTED alone does not prove the worker has unwound its local resources.
	var report: Dictionary = stopping_generator.get_runtime_thread_report()
	while not bool(report.get("simulation_executor_exited", false)):
		if not report.has("simulation_executor_exited"):
			return {"ok": false, "code": "runtime_stop_ack_missing"}
		await next_frame.call()
		report = stopping_generator.get_runtime_thread_report()
	return {"ok": true}

