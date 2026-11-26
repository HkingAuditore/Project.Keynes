extends RefCounted

## Applies render budgets and builds diagnostic reports for vegetation detail.

static func _detail_family_upload_has_pending_source(host, key: String) -> bool:

	var parts = key.split(":")
	if parts.size() != 2:
		return false
	var family = int(parts[0])
	var chunk_id = int(parts[1])
	for pending in host._detail_refresh_queue:
		if int(pending.get("chunk_id", -1)) == chunk_id \
				and int(pending.get("family", 0)) == family:
			return true
	return false



static func detail_scatter_refresh_report(host) -> Dictionary:

	var report = host._last_detail_refresh_report.duplicate(true)
	report["inflight_cells"] = host._scatter_inflight.size()
	report["enqueue_dedup_skips"] = host._scatter_enqueue_dedup_skips
	report["coalesced_cells"] = host._detail_coalesced_cells
	report["offscreen_deferred_cells"] = host._detail_offscreen_deferred_cells
	report["stale_superchunks"] = host._detail_deferred_chunks.size()
	report["render_superchunks"] = host._detail_render_chunk_count
	report["prefetch_superchunks"] = host._detail_prefetch_chunk_count
	report["affected_families"] = host._detail_affected_family_count
	report["visibility_ms"] = host._detail_visibility_last_ms
	report["queued_tasks"] = host._detail_refresh_queue.size()
	report["stale_generation_drops"] = host._detail_stale_generation_drops
	report["evicted_superchunks"] = host._detail_evicted_superchunks
	report["oldest_visible_wait_ms"] = _oldest_visible_detail_task_wait_ms(host)
	report["frame_tasks"] = host._last_detail_task_count
	report["frame_forced_tasks"] = host._last_detail_forced_task_count
	report["max_task_ms"] = host._last_detail_max_task_ms
	report["plan_ms"] = host._last_detail_plan_ms
	report["plan_active"] = host._detail_plan_phase != host.DETAIL_PLAN_IDLE
	report["encode_ms"] = host._last_detail_encode_ms
	report["cache_update_ms"] = host._last_detail_cache_update_ms
	report["assemble_ms"] = host._last_detail_assemble_ms
	report["upload_ms"] = host._last_detail_upload_ms
	if host._detail_family_layer != null and is_instance_valid(host._detail_family_layer):
		var family_diag: Dictionary = host._detail_family_layer.diagnostics()
		for key in family_diag.keys():
			report["family_%s" % str(key)] = family_diag[key]
	return report



static func _oldest_visible_detail_task_wait_ms(host) -> int:

	var oldest = 0
	var now_msec = Time.get_ticks_msec()
	for task in host._detail_refresh_queue:
		if not bool(task.get("visible_priority", true)):
			continue
		oldest = maxi(oldest, now_msec - int(task.get("enqueued_msec", now_msec)))
	return oldest



static func detail_scatter_layer_reports(host) -> Array:

	var out: Array = []
	for layer in host._detail_layers:
		if layer != null and layer.has_method("get_scatter_diagnostics"):
			out.append(layer.get_scatter_diagnostics())
	return out



static func _detail_total_instance_budget(host) -> int:
	var detail: int = host._graphics_details.vegetation_detail
	if OS.has_feature("mobile"):
		var mobile_high = maxi(0, host.detail_scatter_mobile_total_instance_budget)
		match detail if detail >= 0 else host._mobile_quality_tier_from_define(host._mobile_quality_tier_define):
			0:
				return mini(mobile_high, 5000)
			1:
				return mini(mobile_high, 8000)
			_:
				return mobile_high
	var desktop_high = maxi(0, host.detail_scatter_desktop_total_instance_budget)
	match host.visual_quality if detail < 0 else detail:
		0:
			return mini(desktop_high, 35000)
		1:
			return mini(desktop_high, 70000)
		_:
			return desktop_high



static func _detail_budget_fraction_needs_apply(host, next_fraction: float) -> bool:

	if host._detail_budget_applied_fraction < 0.0:
		return true
	var next_unclamped = next_fraction >= 1.0 - 0.000001
	var applied_unclamped = host._detail_budget_applied_fraction >= 1.0 - 0.000001
	if next_unclamped != applied_unclamped:
		return true
	return absf(next_fraction - host._detail_budget_applied_fraction) >= host.DETAIL_BUDGET_FRACTION_EPSILON



static func _begin_detail_budget_apply(host, fraction: float) -> void:

	host._detail_budget_apply_fraction = clampf(fraction, 0.0, 1.0)
	host._detail_budget_apply_cursor = 0
	host._detail_budget_apply_active = not host._detail_layers.is_empty()


## [viewport-budget 2026-11-03] 记下"这次预算是按哪个视野分的"。视口加权只看
## 相机视野内的 chunk，所以视野变了就必须重分，否则近处拿到的还是旧视野那份。

static func _note_detail_budget_applied_view(host) -> void:

	host._detail_budget_applied_view_center = host._camera_world_center
	host._detail_budget_applied_view_zoom = host._camera_zoom


## 视野是否已经偏离"上次分预算时的视野"超过阈值。首帧（zoom<0）恒 true。

static func _detail_budget_view_moved(host) -> bool:

	if host._detail_budget_applied_view_zoom < 0.0:
		return true
	if absf(host._camera_zoom - host._detail_budget_applied_view_zoom) \
			> host.DETAIL_BUDGET_ZOOM_EPSILON * maxf(host._detail_budget_applied_view_zoom, 0.01):
		return true
	var d = host._camera_world_center - host._detail_budget_applied_view_center
	return absf(d.x) > host.DETAIL_BUDGET_VIEW_EPSILON or absf(d.y) > host.DETAIL_BUDGET_VIEW_EPSILON


## [viewport-budget 2026-11-03] 单层预算下发。层若实现视口加权（视口内/近处保住
## 接近 100%、把裁剪压力转到视口外与远处），优先用它；否则退回原来的均匀抽稀。
## 加权不改变总预算上限，只是把有限的实例预算按"玩家正在看哪里"重新分配。
## 返回 true 表示这一层确实被下发过（用于沿用原来的分层进度统计）。

static func _apply_detail_budget_to_layer(host, layer, fraction: float) -> bool:

	if layer == null or not is_instance_valid(layer):
		return false
	if layer.has_method("apply_visible_instance_fraction_weighted"):
		var weighted = layer.apply_visible_instance_fraction_weighted(
			fraction, host._camera_world_rect, host._camera_zoom, host._pixel_world_size,
			host.detail_scatter_rebuild_log_enabled)
		if weighted is Dictionary and not (weighted as Dictionary).is_empty():
			host._last_detail_budget_weighted_report = weighted
		return true
	if layer.has_method("apply_visible_instance_fraction"):
		layer.apply_visible_instance_fraction(fraction)
		return true
	return false



static func _drain_detail_budget_apply(host, force_complete: bool) -> void:

	if not host._detail_budget_apply_active:
		return
	if host.detail_scatter_family_renderer_enabled and host._detail_family_layer != null \
			and is_instance_valid(host._detail_family_layer):
		var family_t0 = Time.get_ticks_usec()
		_apply_detail_budget_to_layer(host, host._detail_family_layer, host._detail_budget_apply_fraction)
		host._detail_budget_last_apply_ms = float(Time.get_ticks_usec() - family_t0) / 1000.0
		host._detail_budget_apply_ms_total += host._detail_budget_last_apply_ms
		host._detail_budget_apply_count += 1
		host._detail_budget_applied_fraction = host._detail_budget_apply_fraction
		_note_detail_budget_applied_view(host)
		host._detail_budget_apply_active = false
		host._detail_budget_apply_cursor = 0
		return
	var layer_budget = host._detail_layers.size() if force_complete else \
		maxi(1, host.detail_scatter_refresh_layers_per_frame)
	var applied_layers = 0
	var started_usec = Time.get_ticks_usec()
	while host._detail_budget_apply_cursor < host._detail_layers.size() and applied_layers < layer_budget:
		var layer = host._detail_layers[host._detail_budget_apply_cursor]
		host._detail_budget_apply_cursor += 1
		if _apply_detail_budget_to_layer(host, layer, host._detail_budget_apply_fraction):
			applied_layers += 1
	var apply_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	host._detail_budget_last_apply_ms = apply_ms
	host._detail_budget_apply_ms_total += apply_ms
	host._detail_budget_apply_count += applied_layers
	if host._detail_budget_apply_cursor >= host._detail_layers.size():
		host._detail_budget_applied_fraction = host._detail_budget_apply_fraction
		_note_detail_budget_applied_view(host)
		host._detail_budget_apply_active = false
		host._detail_budget_apply_cursor = 0



static func _apply_detail_global_budget(host, force_complete: bool = false, allow_apply: bool = true) -> void:

	if host._detail_layers.is_empty():
		host._last_detail_budget_report = {"total_instances": 0, "budget": _detail_total_instance_budget(host), "visible_fraction": 1.0}
		host._detail_budget_target_fraction = 1.0
		host._detail_budget_applied_fraction = 1.0
		host._detail_budget_apply_active = false
		host._detail_budget_apply_cursor = 0
		host._detail_budget_cached_total = 0
		host._detail_budget_total_dirty = false
		return
	if force_complete:
		host._detail_budget_total_dirty = true
	if host._detail_budget_total_dirty:
		var scan_t0 = Time.get_ticks_usec()
		var scanned_total = 0
		if host.detail_scatter_family_renderer_enabled and host._detail_family_layer != null \
				and is_instance_valid(host._detail_family_layer):
			scanned_total = int(host._detail_family_layer.active_instance_count())
		else:
			for layer in host._detail_layers:
				if layer != null and layer.has_method("active_instance_count"):
					scanned_total += int(layer.active_instance_count())
				elif layer != null and layer.has_method("instance_count"):
					scanned_total += int(layer.instance_count())
		host._detail_budget_cached_total = scanned_total
		host._detail_budget_total_dirty = false
		host._detail_budget_total_scan_count += 1
		host._detail_budget_last_scan_ms = float(Time.get_ticks_usec() - scan_t0) / 1000.0
	else:
		host._detail_budget_last_scan_ms = 0.0
	var total = host._detail_budget_cached_total
	var budget = _detail_total_instance_budget(host)
	var fraction = 1.0
	if budget > 0 and total > budget:
		fraction = float(budget) / float(total)
	host._detail_budget_target_fraction = fraction
	if force_complete:
		_begin_detail_budget_apply(host, fraction)
		_drain_detail_budget_apply(host, true)
	elif not host._detail_budget_apply_active \
			and (_detail_budget_fraction_needs_apply(host, fraction) or _detail_budget_view_moved(host)):
		_begin_detail_budget_apply(host, fraction)
	elif not host._detail_budget_apply_active:
		host._detail_budget_apply_skip_count += 1
	if allow_apply and host._detail_budget_apply_active:
		_drain_detail_budget_apply(host, false)
	var report = {
		"total_instances": total,
		"budget": budget,
		"visible_fraction": fraction,
		"applied_visible_fraction": host._detail_budget_applied_fraction,
		"budget_apply_fraction": host._detail_budget_apply_fraction,
		"budget_apply_active": host._detail_budget_apply_active,
		"budget_apply_cursor": host._detail_budget_apply_cursor,
		"budget_apply_count": host._detail_budget_apply_count,
		"budget_apply_skip_count": host._detail_budget_apply_skip_count,
		"budget_apply_last_ms": host._detail_budget_last_apply_ms,
		"budget_apply_ms_total": host._detail_budget_apply_ms_total,
		"budget_total_scan_count": host._detail_budget_total_scan_count,
		"budget_total_scan_ms": host._detail_budget_last_scan_ms,
		"budget_total_dirty": host._detail_budget_total_dirty,
		"layer_count": host._detail_layers.size(),
		"weighted": host._last_detail_budget_weighted_report.duplicate(true),
	}
	# [viewport-budget 2026-11-03] 把层的视口加权回执并进预算报告（viewport_ 前缀）：
	# 真机上能直接看到"预算削在哪、近处保了多少、有没有触发重新平衡"。
	for layer in host._detail_layers:
		if layer == null or not is_instance_valid(layer):
			continue
		var vp_report: Dictionary = {}
		if layer.has_method("viewport_budget_report"):
			vp_report = layer.viewport_budget_report()
		elif not host._last_detail_budget_weighted_report.is_empty():
			vp_report = host._last_detail_budget_weighted_report
		if vp_report.is_empty():
			continue
		for key in vp_report.keys():
			report["viewport_%s" % str(key)] = vp_report[key]
		break
	host._last_detail_budget_report = report
	if host.detail_scatter_rebuild_log_enabled and PKLog.enabled and budget > 0 and total > budget:
		print("[detail_scatter/BUDGET_CLAMP] total_inst=%d budget=%d visible_fraction=%.3f layers=%d" % [
			total,
			budget,
			fraction,
			host._detail_layers.size(),
		])



static func detail_scatter_budget_report(host) -> Dictionary:

	return host._last_detail_budget_report.duplicate(true)



static func _mark_detail_budget_total_dirty(host) -> void:

	host._detail_budget_total_dirty = true



static func _log_detail_scatter_rebuild_summary(host, reason: String) -> void:

	if not host.detail_scatter_rebuild_log_enabled or not PKLog.enabled:
		return
	var reports = detail_scatter_layer_reports(host)
	if reports.is_empty():
		print("[detail_scatter/REBUILD] reason=%s no_layers" % reason)
		return
	var total_ms = 0.0
	var total_inst = 0
	var total_cand = 0
	var slow: Array = []
	for d in reports:
		var ms = float(d.get("rebuild_ms", 0.0))
		total_ms += ms
		total_inst += int(d.get("instances", 0))
		total_cand += int(d.get("candidates", 0))
		if ms >= host.detail_scatter_slow_layer_ms:
			slow.append(d)
	slow.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("rebuild_ms", 0.0)) > float(b.get("rebuild_ms", 0.0))
	)
	print("[detail_scatter/REBUILD] reason=%s layers=%d total_rebuild_ms=%.2f total_inst=%d total_cand=%d budget=%s" % [
		reason,
		reports.size(),
		total_ms,
		total_inst,
		total_cand,
		str(host._last_detail_budget_report),
	])
	var limit = mini(5, slow.size())
	for i in range(limit):
		var d: Dictionary = slow[i]
		print("  [detail_scatter/TOP%d] name=%s rebuild=%.2fms path=%s inst=%d cand=%d wrap=%d reason=%s" % [
			i + 1,
			str(d.get("name", "")),
			float(d.get("rebuild_ms", 0.0)),
			str(d.get("path", "")),
			int(d.get("instances", 0)),
			int(d.get("candidates", 0)),
			int(d.get("wrap_edge_copies", 0)),
			str(d.get("reason", "")),
		])
	# 可见性现场：实例存在但屏幕无显示时，用每层 probe 区分 节点隐藏 / 可见数
	# 归零 / mesh 缺失 / profile 关闭（只读诊断，不改变状态）。
	for layer in host._detail_layers:
		if layer != null and layer.has_method("detail_visibility_probe"):
			print("  [detail_scatter/VIS] %s" % str(layer.detail_visibility_probe()))


# 加载期让帧节流（取代旧的"每层一帧"）：每 4 层或累计 12ms 让一帧，保证进度条
# 动画与 web 的主线程心跳。defer 之后单层只剩几毫秒的初始化，这个预算够用。

# 兜底救援窗口：defer 之后若运行期补齐在这么久之内一株都没建出来（而且刷新管线
# 已经空闲，说明不是"还在排队"），就退回老的"一次性全量构建"。宁可卡一下，
# 也不能让地图永远光秃秃。

# 受限平台判定覆盖：-1 = 跟随引擎特性；0 = 强制桌面；1 = 强制受限平台。
# 只给临时验证脚本 / A-B 调试用，正常游戏流程不会改它。
# 保留比例运行期覆盖：<0 = 用常量 WEB_MOBILE_DETAIL_LAYER_KEEP_RATIO。
# 只给临时验证脚本 / A-B 调试用，正常流程不会改它。
